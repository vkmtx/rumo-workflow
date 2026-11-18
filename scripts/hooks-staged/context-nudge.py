#!/usr/bin/env python3
"""context-nudge: UserPromptSubmit. Measured 2026-10-28 (rumo #14): turns between 200k and 400k of
context were 50% of the main session's cost, and 5 of the 10 costliest sessions were not builds.
Context = input + cache_read + cache_creation tokens of the transcript's last assistant message.
Any prompt: nudges once per band, never blocks. Bands 200k/300k/400k/500k/800k (env
CONTEXT_NUDGE_LEVELS, comma list, for tests). The highest band already nudged lives in
$TMPDIR/context-nudge-<session_id>; context falling back (a compaction) lowers it, so the next
crossing nudges again. Only `/rumo build|wave` above CONTEXT_BUILD_MAX blocks (gate below).
Fail-open: any error -> exit 0 silently."""
import json, os, re, sys, tempfile

# A build or wave starts in a fresh window (rumo build.md): measured 2026-10-23, build sessions ran a
# median 115 turns at ~148k, the worst chaining several issues in one window (1384 turns, 289M tokens).
# A fresh session's first reply sits at 33k-82k, so the gate fires only above CONTEXT_BUILD_MAX (120k).
BUILD = re.compile(r'^\s*/rumo(:rumo)?\s+(build|wave)\b')

def levels():
    raw = os.environ.get('CONTEXT_NUDGE_LEVELS') or '200000,300000,400000,500000,800000'
    return sorted(int(x) for x in raw.split(',') if x.strip())

def last_context(path):
    ctx = None
    for line in open(path, errors='replace'):
        try:
            u = (json.loads(line).get('message') or {}).get('usage')
        except ValueError:
            continue
        if isinstance(u, dict) and (json.loads(line).get('message') or {}).get('role') == 'assistant':
            ctx = sum(int(u.get(k) or 0) for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
    return ctx

def main():
    d = json.load(sys.stdin)
    ctx = last_context(d.get('transcript_path') or '')
    if not ctx:
        return 0
    prompt = str(d.get('prompt') or '')
    if BUILD.match(prompt) and '#same-window' not in prompt and ctx >= int(os.environ.get('CONTEXT_BUILD_MAX') or 120000):
        reason = (f"A build starts in a fresh window: this one is already at ~{ctx // 1000}k tokens and every build turn "
                  f"would re-read all of it. Type /clear and repeat:\n  {prompt.strip()}\n"
                  "To keep this window on purpose, add #same-window.")
        print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
        return 0
    crossed = [l for l in levels() if ctx >= l]
    band = crossed[-1] if crossed else 0
    sid = ''.join(c for c in str(d.get('session_id') or 'x') if c.isalnum() or c in '-_')
    state = os.path.join(os.environ.get('TMPDIR') or tempfile.gettempdir(), 'context-nudge-' + sid)
    try:
        seen = int(open(state).read().strip() or 0)
    except Exception:
        seen = 0
    if band != seen:
        open(state, 'w').write(str(band))
    if band <= seen:
        return 0
    msg = (f"[context] Context at ~{ctx // 1000}k tokens: every turn now re-reads all of it. Suggest to the user: "
           "new task → /clear; same task → /rumo handoff, then /clear and resume from the handoff.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": msg}},
                     ensure_ascii=False))
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)

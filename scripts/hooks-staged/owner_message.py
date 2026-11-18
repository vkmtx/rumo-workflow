"""owner_message — the single rule for "which transcript text is the owner's own message".

Shared by pr-base-guard.sh (deploy words, `confirmo`, `#sem-review`) and worktree-guard.py
(`#env-ok`), and installed beside them in ~/.claude/hooks/; both import it, so the rule has one
source. A hook installed without this file fails closed: no override counts.

Why it exists (#97): a session opened by `orca agent launch` (a wave lane, a worker launcher) stores
its launch prompt as a user entry field-for-field identical to a message the owner typed
(`origin.kind: human`, `promptSource: typed`, `entrypoint: cli`). No structural field tells them
apart, so the text decides: a user message with any line starting `AUTHORIZED:`, `WAVE BRIEF:` or
`LAUNCHED-BY:` is a launch prompt and is discarded whole.

Stdlib only, Python 3.9-compatible.
"""
import re

LAUNCH_MARKERS = ('AUTHORIZED:', 'WAVE BRIEF:', 'LAUNCHED-BY:')

# Machine-written user entries (pr-base-guard.sh's old reader), plus messages another agent session
# writes into this one (`<agent-message`, `<cross-session-message`: queued_command, origin null).
SKIP = ('<local-command', '<task-notification', '<system-reminder', 'Caveat:', '[Request interrupted',
        'Stop hook feedback', '<bash-', '<user-prompt-submit-hook', '<agent-message', '<cross-session-message')

_COMMAND_ARGS = re.compile(r'<command-args>\s*')


def is_launch_prompt(text):
    """True when any line, left-stripped and with one leading `<command-args>` removed, starts with a
    launch marker (case-sensitive)."""
    for line in str(text or '').splitlines():
        line = line.lstrip()
        if line.startswith('<command-args>'):
            line = _COMMAND_ARGS.sub('', line, count=1)
        if line.startswith(LAUNCH_MARKERS):
            return True
    return False


def owner_text(text):
    """The part of `text` that is the owner's: '' for a launch prompt, else the text before any
    mid-line `AUTHORIZED:` (an orchestrator quotes the owner's go from there on)."""
    text = str(text or '')
    if is_launch_prompt(text):
        return ''
    return text.split('AUTHORIZED:', 1)[0]


def user_text(e):
    """Stripped text of a real user message entry, '' for anything else: non-dicts, machine origins
    (`origin.kind` other than `human`), meta / compact-summary / visible-only entries, tool results,
    non-user roles and SKIP-prefixed machine text. Entries without an origin (older transcripts) are
    judged by shape. A queued_command attachment counts as the prompt it carries — except a message
    from another agent session (`<agent-message …>`, `<cross-session-message …>`, stored as a
    queued_command with `origin: null`), which SKIP rejects: it is never the owner's."""
    if not isinstance(e, dict):
        return ''
    o = e.get('origin')
    if isinstance(o, dict) and o.get('kind') != 'human':
        return ''
    if e.get('isMeta') or e.get('isCompactSummary') or e.get('isVisibleInTranscriptOnly'):
        return ''
    text = ''
    a = e.get('attachment')
    if e.get('type') == 'attachment' and isinstance(a, dict) and a.get('type') == 'queued_command':
        text = str(a.get('prompt') or '')
    elif e.get('type') == 'user' and e.get('toolUseResult') is None:
        m = e.get('message')
        if isinstance(m, dict) and m.get('role') == 'user':
            c = m.get('content')
            if isinstance(c, str):
                text = c
            elif isinstance(c, list):
                text = '\n'.join(str(b.get('text') or '') for b in c
                                 if isinstance(b, dict) and b.get('type') == 'text')
    text = text.strip()
    if not text or text.startswith(SKIP):
        return ''
    return text

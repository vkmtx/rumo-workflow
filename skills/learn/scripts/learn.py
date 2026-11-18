#!/usr/bin/env python3
"""learn.py — the deterministic half of /learn. No model calls.

  harvest [--current | --session ID | --days N] [--cwd DIR] [--root DIR]
      Scan Claude Code transcripts for learning signals and print a compact report:
      user corrections (with the assistant text they answered), interrupts, hook blocks,
      repeated tool failures. --current = newest transcript of the project at --cwd.
  stats [--events FILE] [--days N]
      Summarise rumo build events: rungs per kind, first-try rate per model and per
      category (the Model-rule calibration), top repeated causes and files.
      Lines the event validator rejects are skipped and listed ("skipped N malformed (lines …)");
      paired findings with the same why count once;
      dismissed findings by axis x reason (no reason = legacy).
  event '<json object>' | - [--events FILE]
      Validate, scrub and append one build event (monthly rotation to events-YYYYMM.jsonl.gz).
      `-` reads stdin, one JSON object per line: all lines are validated before any is written
      (all-or-nothing; an invalid line exits 2 naming it).
      A finding event needs outcome (fixed|dismissed|open) and severity (blocker|major|minor|question);
      a dismissed finding also needs reason (pre-existing|by-design|owner-waived|wrong|unreplayed); reason on any other outcome is refused;
      axis (bugs|standards|spec|security|fix|visual), model (opus|sonnet|haiku|orchestrator) and paired (bool, historical)
      are optional and feed stats' axis x model table. A run event's steps/first_try are {model: int}
      objects (first_try <= steps), by_category keys are <category>[/risk], findings counts
      blocker|major|minor|question.
  normalize [--events FILE] [--out FILE]
      One-off history fix: copy FILE to FILE.bak-YYYYMMDD, write the normalized events to --out
      (default events.normalized.jsonl beside FILE) and print counts per mapping with
      before/after samples and the diff command to show. Never modifies FILE.
  scan FILE ...
      Exit 1 when any line looks like a secret (the scrub() patterns); prints file:line only.
  spend [--days N] [--root DIR]
      Token spend from transcripts: main session vs subagents, the main session's share above
      300k context, subagents by type x model (runs, tokens, median turns), heaviest runs.
  phases [--days N] [--root DIR]
      Wall-clock time of each /rumo build session from transcripts: critical path (every second
      to one category), active percentiles, phases, builder concurrency, review rounds, stalls.
      A session that invoked `/rumo wave` is a wave orchestrator: out of the build set, counted on
      its own line under the header. A wait goes to user-wait or, when the message that ended it is
      a launch prompt or an orchestrator relay (a line starting LAUNCHED-BY:, WAVE BRIEF:,
      AUTHORIZED:, Orquestrador:, PAUSA or CONTINUE), to launcher-wait — and only for the seconds
      with no subagent, Bash command or background task running; a pending AskUserQuestion
      (ask-user) outranks them all. Owner touches per build = the owner's own messages after the
      first planner/builder run started.
  budget FILE[:LIMIT_KB] ...
      Byte budget check. Exit 1 when any file is over its limit (default by name:
      CLAUDE.md 32, SKILL.md 8, agents/*.md 6, lessons.md 8, anything else 16).
"""
import argparse, collections, datetime, glob, gzip, json, os, re, shutil, sys, time

HOME = os.path.expanduser('~')
DEFAULT_ROOT = os.path.join(HOME, '.claude', 'projects')
DEFAULT_EVENTS = os.path.join(HOME, '.claude', 'learn', 'events.jsonl')

# A user message that pushes back on the previous turn. PT-BR first (the owner types corrections in
# Portuguese — these patterns match user input, so they stay Portuguese), EN second.
# Candidates only — /learn's model judges them. Words that also open ordinary requests
# ("para cada…" = "for each…", "no build…" = "in the build…", "roda de novo" = "run it again",
# "cadê o PR?" = "where's the PR?") are left out on purpose.
CORRECTION = re.compile(
    r"(^\s*(n[aã]o[,.!]|n[aã]o\s+(era|é|e|foi|quero|pedi|precisa|fa[cçz]a?|faz|mexe)\b|errado|errou|pare\b|no[,.!]|wrong|stop\b))"
    r"|(j[aá] (te )?(falei|disse|pedi))|(esqueceu)|(faltou)|(n[aã]o era isso)"
    r"|(n[aã]o (foi|é) (isso|o que))|(por ?que (vc|voc[eê]) )|(pq (vc|voc[eê]) )"
    r"|(i (already )?(told|said|asked))|(that'?s not what)|(you forgot)",
    re.I)

CATEGORIES = ("test", "ui-logic", "api", "db-migration", "data-model", "config", "build-tooling",
              "refactor", "integration", "auth", "perf", "docs", "visual", "other")
KINDS = ("revise", "escalate", "replan", "block", "scope", "finding", "run")
OUTCOMES = ("fixed", "dismissed", "open")
REASONS = ("pre-existing", "by-design", "owner-waived", "wrong", "unreplayed")
AXES = ("bugs", "standards", "spec", "security", "fix", "visual")
MODELS = ("opus", "sonnet", "haiku", "orchestrator")
SEVERITIES = ("blocker", "major", "minor", "question")
CAT_KEY = re.compile(r'(?:%s)(?:/risk)?' % '|'.join(map(re.escape, CATEGORIES)))

_SECRET_PATTERNS = (
    re.compile(r'sk-[A-Za-z0-9_-]{16,}'),
    re.compile(r'gh[pousr]_[A-Za-z0-9]{20,}'),
    re.compile(r'xox[baprs]-[A-Za-z0-9-]{10,}'),
    re.compile(r'AKIA[0-9A-Z]{16}'),
    re.compile(r'eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}'),
)
_URL_CREDS = re.compile(r'([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@')
_KEY_VALUE = re.compile(r'(?i)\b(password|passwd|secret|api[_-]?key|token|access[_-]?key)\b(\s*[=:]\s*)\S+')

def scrub(text):
    text = _URL_CREDS.sub(r'\1<redacted>@', text)
    for pat in _SECRET_PATTERNS:
        text = pat.sub('<redacted>', text)
    return _KEY_VALUE.sub(r'\1\2<redacted>', text)

def scrub_deep(v):
    if isinstance(v, str):
        return scrub(v)
    if isinstance(v, list):
        return [scrub_deep(x) for x in v]
    if isinstance(v, dict):
        return {k: scrub_deep(x) for k, x in v.items()}
    return v

def project_dir(cwd, root):
    return os.path.join(root, re.sub(r'[^A-Za-z0-9]', '-', os.path.abspath(cwd)))

def pick_files(args):
    if args.session:
        return glob.glob(os.path.join(args.root, '*', args.session + '.jsonl'))
    if args.current:
        files = glob.glob(os.path.join(project_dir(args.cwd, args.root), '*.jsonl'))
        return sorted(files, key=os.path.getmtime)[-1:]
    cutoff = time.time() - args.days * 86400
    return [f for f in glob.glob(os.path.join(args.root, '*', '*.jsonl')) if os.path.getmtime(f) >= cutoff]

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')
    return ''

def clip(s, n):
    s = ' '.join(str(s).split())
    return s if len(s) <= n else s[:n - 1] + '…'

def error_signature(body):
    # "Exit code N" alone says nothing; keep the first line of what the command printed.
    lines = [l for l in body.split('\n') if l.strip()]
    if lines and re.match(r'Exit code \d+$', lines[0].strip()) and len(lines) > 1:
        return clip(lines[0].strip() + ' · ' + lines[1], 110)
    return clip(lines[0] if lines else body, 110)

def harvest_file(path):
    out = {'corrections': [], 'interrupts': 0, 'rejections': 0, 'hook_blocks': [], 'tool_errors': collections.Counter()}
    last_assistant = ''
    for line in open(path, errors='replace'):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get('isSidechain'):
            continue
        t, m = d.get('type'), d.get('message') or {}
        if t == 'assistant':
            txt = text_of(m.get('content'))
            if txt.strip():
                last_assistant = txt
        elif t == 'attachment':
            att = d.get('attachment') or {}
            if att.get('type') == 'hook_blocking_error':
                be = att.get('blockingError') or {}
                msg = be.get('blockingError') if isinstance(be, dict) else be
                out['hook_blocks'].append((att.get('hookName', '?'), clip(msg, 160)))
        elif t == 'user' and not d.get('isMeta'):
            content = m.get('content')
            if isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get('type') == 'tool_result' and b.get('is_error'):
                        body = text_of(b.get('content')) or str(b.get('content'))
                        hm = re.match(r'\s*(PreToolUse:\w+) hook error:\s*(.*)', body, re.S)
                        if hm:
                            out['hook_blocks'].append((hm.group(1), clip(hm.group(2), 160)))
                        elif body.startswith("The user doesn't want to proceed"):
                            out['rejections'] += 1
                        else:
                            out['tool_errors'][error_signature(body)] += 1
            txt = text_of(content).strip()
            if not txt or txt.startswith('<'):
                continue
            if txt.startswith('[Request interrupted'):
                out['interrupts'] += 1
                continue
            if CORRECTION.search(txt[:400]):
                out['corrections'].append((clip(last_assistant[-220:], 220), clip(txt, 300)))
    return out

def cmd_harvest(args):
    files = pick_files(args)
    if not files:
        print('harvest: no transcripts matched'); return 0
    home_prefix = re.sub(r'[^A-Za-z0-9]', '-', HOME) + '-'
    corrections = {}  # user text -> [project, previous assistant text, sessions seen]
    interrupts = rejections = 0
    hook_blocks, tool_errors = collections.Counter(), collections.Counter()
    for f in files:
        r = harvest_file(f)
        proj = os.path.basename(os.path.dirname(f)).replace(home_prefix, '~/')
        for prev, user in r['corrections']:
            prev, user = scrub(prev), scrub(user)
            entry = corrections.setdefault(user, [proj, prev, set()])
            entry[2].add(f)  # a resumed/forked session repeats turns: count sessions, not lines
        interrupts += r['interrupts']
        rejections += r['rejections']
        hook_blocks.update((h, scrub(m)) for h, m in r['hook_blocks'])
        for k, n in r['tool_errors'].items():
            tool_errors[scrub(k)] += n
    print(f'# harvest — {len(files)} transcript(s)\n')
    print(f"## User corrections ({len(corrections)})")
    for user, (proj, prev, sessions) in list(corrections.items())[-args.limit:]:
        times = f' ×{len(sessions)} sessions' if len(sessions) > 1 else ''
        print(f'- [{proj}]{times} after: "{prev}"\n  user: "{user}"')
    print(f"\n## Interrupts: {interrupts} · rejected tool calls: {rejections}")
    print(f"\n## Hook blocks ({sum(hook_blocks.values())})")
    for (hook, msg), n in hook_blocks.most_common(args.limit):
        print(f'- ×{n} {hook}: {msg}')
    rep = [(k, n) for k, n in tool_errors.most_common(args.limit) if n >= 2]
    print(f"\n## Repeated tool failures ({len(rep)} signatures seen ≥2×)")
    for k, n in rep:
        print(f'- ×{n} {k}')
    return 0

def load_events(path, days):
    """Return (events, skipped): events in the window that pass validate_event, and the labels
    of lines that are unparsable or invalid ('N' in the main file, 'name.gz:N' in an archive)."""
    cutoff = time.time() - days * 86400
    ev, skipped = [], []
    sources = [(path, open)] if os.path.exists(path) else []
    oldest = time.strftime('%Y%m', time.gmtime(cutoff))
    sources += [(f, lambda p: gzip.open(p, 'rt', errors='replace'))
                for f in sorted(glob.glob(os.path.join(os.path.dirname(path), 'events-*.jsonl.gz')))
                if os.path.basename(f)[7:13] >= oldest]  # skip archived months wholly before the window
    for f, opener in sources:
        for n, line in enumerate(opener(f), 1):
            if not line.strip():
                continue
            label = str(n) if f == path else f'{os.path.basename(f)}:{n}'
            try:
                e = json.loads(line)
            except ValueError:
                e = None
            if not isinstance(e, dict):
                skipped.append(label); continue
            try:
                ts = time.mktime(time.strptime(str(e.get('ts', ''))[:19], '%Y-%m-%dT%H:%M:%S'))
            except (ValueError, TypeError):
                continue  # undated events would never age out of the window
            if ts < cutoff:
                continue
            if validate_event(e):
                skipped.append(label)
            else:
                ev.append(e)
    return ev, skipped

def cmd_stats(args):
    ev, skipped = load_events(args.events, args.days)
    shown = ', '.join(skipped[:20]) + (f', +{len(skipped) - 20} more' if len(skipped) > 20 else '')
    main_bad = any(':' not in l for l in skipped)
    note = f'skipped {len(skipped)} malformed (lines {shown}) — '
    if not main_bad:
        note += 'archive lines age out of the window; normalize reads only events.jsonl'
    else:
        note += 'learn.py normalize writes a fixed copy to review' + ('; archive lines age out' if any(':' in l for l in skipped) else '')
    if not ev:
        if skipped:
            print(note)
        print(f'stats: no events in {args.events} (last {args.days}d)'); return 0
    runs = [e for e in ev if e.get('kind') == 'run']
    kinds = collections.Counter(e.get('kind') for e in ev if e.get('kind') != 'run')
    print(f'# stats — {len(runs)} build run(s), last {args.days}d')
    print(note + '\n' if skipped else '')
    steps, first = collections.Counter(), collections.Counter()
    for r in runs:
        steps.update(r.get('steps') or {}); first.update(r.get('first_try') or {})
    print('## First-try success by model')
    for model in ('sonnet', 'opus'):
        if steps[model]:
            print(f'- {model}: {first[model]}/{steps[model]} = {100 * first[model] // steps[model]}%')
    print('\n## Rungs by kind')
    for k, n in kinds.most_common():
        print(f'- {k}: {n}')
    cat = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))  # cat -> model -> [steps, first_try]
    for r in runs:
        for c, models in (r.get('by_category') or {}).items():
            for model, v in (models or {}).items():
                cat[c][model][0] += v.get('steps', 0); cat[c][model][1] += v.get('first_try', 0)
    if cat:
        print('\n## First-try by category')
        for c in sorted(cat):
            for model in sorted(cat[c]):
                n, m = cat[c][model]
                if n:
                    print(f'- {c} · {model}: {m}/{n} = {100 * m // n}%' + (' (low n)' if n < 5 else ''))
    print('\n## Calibration candidates')
    cands, risk_keys, risk_n = [], [], 0
    for c in sorted(cat):
        if c.endswith('/risk'):  # risk, not category, routed these steps to opus
            risk_keys.append(c); risk_n += sum(v[0] for v in cat[c].values()); continue
        for model, (n, m) in sorted(cat[c].items()):
            if n < 5:
                continue
            pct = 100 * m // n
            if model == 'sonnet' and pct < 70:
                cands.append(f'- {c}: sonnet {pct}% over {n} — sharpen the planner brief or route to opus')
            elif model == 'opus' and pct >= 90:
                cands.append(f'- {c}: opus {pct}% over {n} — candidate to move to sonnet')
    print('\n'.join(cands) if cands else '- none (need n ≥ 5 per category)')
    if risk_keys:
        print(f"- risk-routed steps excluded: {risk_n} ({', '.join(risk_keys)})")
    model_fail = [e for e in ev if e.get('kind') in ('revise', 'escalate') and e.get('model') == 'sonnet']
    infra = [e for e in model_fail if e.get('env')]
    fails = collections.Counter(e.get('category', '?') for e in model_fail if not e.get('env'))
    if fails:
        print('\n## Sonnet failures by step category (calibrate the Model rule)')
        for c, n in fails.most_common(10):
            print(f'- {c}: {n}')
    if infra:
        print(f'\n## Infra failures (not the model): {len(infra)}')
    outcomes = collections.Counter(e.get('outcome', 'unknown') for e in ev if e.get('kind') == 'finding')
    if outcomes:
        print('\n## Findings by outcome: ' + ', '.join(f'{k} {n}' for k, n in outcomes.most_common()))
        dismissed = collections.Counter(e.get('category', '?') for e in ev
                                        if e.get('kind') == 'finding' and e.get('outcome') == 'dismissed')
        for c, n in dismissed.most_common(5):
            if n >= 3:
                print(f'- dismissed ×{n} in {c} — candidate reviewer rule (stop raising this class)')
    findings = [e for e in ev if e.get('kind') == 'finding']
    if any(e.get('axis') for e in findings):
        print('\n## Findings by axis × model')
        groups = collections.defaultdict(collections.Counter)
        for e in findings:
            groups[(e.get('axis') or '?', e.get('model') or '?', ' · paired' if e.get('paired') is True else '')][e.get('outcome')] += 1
        for (axis, model, paired), c in sorted(groups.items(), key=lambda kv: (-sum(kv[1].values()), kv[0])):
            n = sum(c.values())
            print(f"- {axis} · {model}{paired}: {n} findings — fixed {c['fixed']}, dismissed {c['dismissed']}, "
                  f"open {c['open']} (dismiss rate {round(100 * c['dismissed'] / n)}%)")
    dis = [e for e in findings if e.get('outcome') == 'dismissed']
    if dis:
        print('\n## Dismissed by axis × reason')
        by = collections.Counter((e.get('axis') or '?', e.get('reason') or 'legacy') for e in dis)
        for (axis, reason), n in sorted(by.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f'- {axis} · {reason}: {n}')
    sev = collections.Counter(e.get('severity', '?') for e in ev if e.get('kind') == 'finding')
    if sev:
        print('\n## Review findings: ' + ', '.join(f'{k} {n}' for k, n in sev.most_common()))
    why, seen = collections.Counter(), set()
    for e in ev:
        if not e.get('why'):
            continue
        w = clip(e['why'], 90)
        if e.get('paired') is True:  # the two models of a paired review report the same cause
            key = (e.get('repo'), e.get('issue'), w)
            if key in seen:
                continue
            seen.add(key)
        why[w] += 1
    print('\n## Repeated causes (≥2× → promotion candidates)')
    for w, n in why.most_common(10):
        if n >= 2:
            print(f'- ×{n} {w}')
    files = collections.Counter(f for e in ev if e.get('kind') != 'run' for f in e.get('files') or [])
    hot = [(f, n) for f, n in files.most_common(8) if n >= 2]
    if hot:
        print('\n## Hot files')
        for f, n in hot:
            print(f'- ×{n} {f}')
    return 0

def _count(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0

def _validate_run(e):
    shape = '{' + '|'.join(MODELS) + ': int >= 0}'
    for name in ('steps', 'first_try'):
        if name in e:
            v = e[name]
            if not (isinstance(v, dict) and all(k in MODELS and _count(n) for k, n in v.items())):
                return f'{name} must be an object {shape}'
    steps = e.get('steps') or {}
    for m, n in (e.get('first_try') or {}).items():
        if n > steps.get(m, 0):
            return f'first_try exceeds steps for {m}'
    if 'by_category' in e:
        bc = e['by_category']
        if not isinstance(bc, dict):
            return 'by_category must be an object'
        for key, cells in bc.items():
            if not isinstance(key, str) or not CAT_KEY.fullmatch(key):
                return f"by_category key {key!r} must be <category>[/risk] with category one of {', '.join(CATEGORIES)}"
            ok = isinstance(cells, dict)
            for m, c in (cells.items() if ok else ()):
                if not (m in MODELS and isinstance(c, dict) and set(c) == {'steps', 'first_try'}
                        and _count(c['steps']) and _count(c['first_try']) and c['first_try'] <= c['steps']):
                    return f'by_category[{key!r}][{m!r}] must be {{"steps": n, "first_try": m}} with 0 <= m <= n'
            if not ok:
                return f'by_category[{key!r}] must be an object of {{model: {{"steps": n, "first_try": m}}}}'
    if 'findings' in e:
        f = e['findings']
        if not (isinstance(f, dict) and all(k in SEVERITIES and _count(n) for k, n in f.items())):
            return 'findings must be an object {blocker|major|minor|question: int >= 0}'
    return None

def validate_event(e, write=False):
    """Return None when e is a valid build event, else the reason it is not."""
    if not isinstance(e, dict):
        return 'event must be a JSON object'
    if e.get('kind') not in KINDS:
        return f"kind must be one of {', '.join(KINDS)}"
    if not isinstance(e.get('repo'), str) or not e['repo'].strip():
        return 'repo must be a non-empty string'
    if e['kind'] != 'run' and e.get('category') not in CATEGORIES:
        return f"category is required and must be one of {', '.join(CATEGORIES)}"
    if e['kind'] == 'run':
        reason = _validate_run(e)
        if reason:
            return reason
    if e['kind'] == 'finding':
        ci = ' — a CI failure is a revise event with "env": true'
        if e.get('outcome') not in OUTCOMES:
            return f"finding outcome is required and must be one of {', '.join(OUTCOMES)}"
        if e.get('severity') not in SEVERITIES:
            return f"finding severity is required and must be one of {', '.join(SEVERITIES)}"
        if 'axis' in e and e['axis'] not in AXES:
            return f"axis must be one of {', '.join(AXES)}" + (ci if e['axis'] == 'ci' else '')
        if 'model' in e and e['model'] not in MODELS:
            return f"model must be one of {', '.join(MODELS)}" + (ci if e['model'] == 'ci' else '')
        if 'paired' in e and not isinstance(e['paired'], bool):
            return 'paired must be true or false'
        if 'reason' in e:
            if e['reason'] not in REASONS:
                return f"reason must be one of {', '.join(REASONS)}"
            if e['outcome'] != 'dismissed':
                return 'reason is only for a dismissed finding'
        elif write and e['outcome'] == 'dismissed':
            return f"a dismissed finding needs reason ({', '.join(REASONS)})"
    if 'env' in e and not isinstance(e['env'], bool):
        return 'env must be a boolean'
    if 'legacy' in e and not isinstance(e['legacy'], bool):
        return 'legacy must be true or false'
    return None

RUN_TEXT = re.compile(r'^\s*([a-z]+)\s+(\d+)\s*$')

def _map_cat(c):
    tag = None
    if ',' in c:
        c, tag = c.split(',')[0].strip(), 'category-comma'
    if c in CATEGORIES:
        return c, tag
    if c in ('layout', 'style') or c.startswith('ui'):
        return 'ui-logic', 'category-ui'
    if c == 'authz-race':
        return 'auth', 'category-authz-race'
    if c in ('bug', 'logic', 'observability'):
        return 'other', 'category-other'
    return 'other', 'category-unknown'

def _run_text(v):
    """'sonnet 0, opus 5' -> {'sonnet': 0, 'opus': 5}; None when any part does not parse."""
    if not isinstance(v, str):
        return None
    out = {}
    for part in v.split(','):
        m = RUN_TEXT.match(part)
        if not m or m.group(1) not in MODELS:
            return None
        out[m.group(1)] = int(m.group(2))
    return out

def normalize_event(e):
    """Map one historical event onto today's validator; return (new event, tags that fired)."""
    e = json.loads(json.dumps(e))
    tags = []
    if e.get('kind') == 'finding' and (e.get('axis') == 'ci' or e.get('model') == 'ci'):
        e['kind'], e['env'] = 'revise', True
        for k in ('axis', 'model', 'severity', 'outcome', 'paired'):
            e.pop(k, None)
        tags.append('ci-to-revise')
    if e.get('kind') != 'run' and isinstance(e.get('category'), str):
        e['category'], tag = _map_cat(e['category'])
        tags += [tag] if tag else []
    if e.get('kind') == 'run':
        if isinstance(e.get('by_category'), dict):
            merged = {}
            for key, cells in e['by_category'].items():
                base, risk = (key[:-5], '/risk') if key.endswith('/risk') else (key, '')
                base, tag = _map_cat(base)
                tags += [tag] if tag else []
                nk = base + risk
                if nk not in merged:
                    merged[nk] = cells
                    continue
                into = merged[nk]
                if not (isinstance(into, dict) and isinstance(cells, dict)):
                    if isinstance(into, dict):
                        merged[nk] = cells  # keep the malformed value so validate_event flags the line
                    continue
                for m, c in cells.items():
                    if m not in into:
                        into[m] = c
                    elif (isinstance(into[m], dict) and isinstance(c, dict)
                          and all(_count(into[m].get(k, 0)) and _count(c.get(k, 0)) for k in ('steps', 'first_try'))):
                        into[m] = {k: into[m].get(k, 0) + c.get(k, 0) for k in ('steps', 'first_try')}
                    elif isinstance(into[m], dict) and all(_count(into[m].get(k, 0)) for k in ('steps', 'first_try')):
                        into[m] = c  # keep the malformed cell so validate_event flags the line, never drop it
                    # else: the first cell is already malformed and validate_event reports it
            e['by_category'] = merged
        if isinstance(e.get('findings'), dict):
            f = e['findings']
            for old, new in (('medium', 'major'), ('low', 'minor')):
                if old in f and _count(f[old]) and _count(f.get(new, 0)):
                    f[new] = f.get(new, 0) + f.pop(old)
                    if 'findings-medium-low' not in tags:
                        tags.append('findings-medium-low')
        for name in ('steps', 'first_try'):
            if name in e and not isinstance(e[name], dict):
                parsed = _run_text(e[name])
                if parsed is not None:
                    e[name] = parsed
                    tags.append('run-text-to-object')
                else:
                    e['legacy_' + name], e['legacy'] = e.pop(name), True
                    tags.append('run-legacy-field')
        steps = e.get('steps') if isinstance(e.get('steps'), dict) else {}
        ft = e.get('first_try')
        if isinstance(ft, dict) and any(_count(n) and _count(steps.get(m, 0)) and n > steps.get(m, 0)
                                       for m, n in ft.items()):
            e['legacy_first_try'], e['legacy'] = e.pop('first_try'), True
            tags.append('run-legacy-field')
    if e.get('kind') == 'finding':
        for k in ('axis', 'model', 'severity', 'outcome'):
            if k in e and e[k] is None:
                del e[k]
        if e.get('severity') in ('medium', 'low'):
            e['severity'] = {'medium': 'major', 'low': 'minor'}[e['severity']]
            tags.append('severity-medium-low')
        if 'severity' not in e:
            e['severity'], e['legacy'] = 'minor', True
            tags.append('severity-missing')
        if 'outcome' not in e:
            e['outcome'], e['legacy'] = 'open', True
            tags.append('outcome-missing')
        if 'axis' not in e or 'model' not in e:
            e['legacy'] = True
            tags.append('legacy-axis-model')
    return e, tags

def cmd_normalize(args):
    events = args.events
    if not os.path.isfile(events):
        print(f'normalize: no file {events}', file=sys.stderr); return 2
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(events)), 'events.normalized.jsonl')
    backup = f'{events}.bak-{time.strftime("%Y%m%d")}'
    if os.path.exists(backup):
        backup += time.strftime('-%H%M%S')
    shutil.copy2(events, backup)
    read = changed = dropped = 0
    counts, samples, written = collections.Counter(), collections.defaultdict(list), []
    with open(backup, encoding='utf-8', errors='replace') as src:
        for line in src:
            text = line.rstrip('\n')
            if not text.strip():
                continue
            read += 1
            try:
                e = json.loads(text)
            except ValueError:
                e = None
            if not isinstance(e, dict):
                dropped += 1
                fired, after = ['dropped-unparseable'], '(dropped)'
            else:
                new, fired = normalize_event(e)
                if new == e:
                    after = text
                else:
                    changed += 1
                    after = json.dumps(new, ensure_ascii=False, separators=(',', ':'))
                written.append(after)
            for tag in set(fired):
                counts[tag] += 1
                if len(samples[tag]) < 2:
                    samples[tag].append((text, after))
    with open(out, 'w', encoding='utf-8') as f:
        f.writelines(l + '\n' for l in written)
    print(f'normalize: {read} lines read · {changed} changed · {dropped} dropped · '
          f'{read - changed - dropped} unchanged')
    print(f'backup: {backup}')
    print(f'out: {out}')
    for tag in sorted(counts):
        print(f'- {tag}: {counts[tag]}')
        for before, after in samples[tag]:
            print(f'    before: {clip(before, 200)}')
            print(f'    after:  {clip(after, 200)}')
    bad = 0
    for n, l in enumerate(written, 1):
        reason = validate_event(json.loads(l))
        if reason:
            bad += 1
            print(f'still invalid: line {n}: {reason}')
    if bad:
        return 1
    print(f'{events} untouched — show the user: diff {backup} {out}  (then replace only on their yes)')
    return 0

def cmd_event(args):
    def bad(msg):
        print(f'event: {msg}', file=sys.stderr); return 2
    batch = args.json == '-'
    if batch:
        raws = [(n, l) for n, l in enumerate(sys.stdin.read().splitlines(), 1) if l.strip()]
        if not raws:
            return bad('no events on stdin')
    else:
        raws = [(None, args.json)]
    events = []
    for n, raw in raws:
        where = f'line {n}: ' if batch else ''
        try:
            e = json.loads(raw)
        except ValueError as x:
            return bad(f'{where}invalid JSON ({x})')
        reason = validate_event(e, write=True)
        if reason:
            return bad(where + reason)
        e.setdefault('ts', time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        events.append(scrub_deep(e))
    path = args.events
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    if os.path.exists(path):
        with open(path) as f:
            first = f.readline()
        try:
            month = str(json.loads(first).get('ts', ''))[:7]
        except (ValueError, AttributeError):
            month = ''
        if re.match(r'\d{4}-\d{2}$', month) and month != time.strftime('%Y-%m', time.gmtime()):
            archive = os.path.join(os.path.dirname(os.path.abspath(path)), f"events-{month.replace('-', '')}.jsonl.gz")
            moving = f'{path}.rotating-{os.getpid()}'
            try:
                os.replace(path, moving)  # atomic: a concurrent writer starts a fresh file instead of racing
            except FileNotFoundError:
                moving = None             # another process rotated it first
            if moving:
                with open(moving, 'rb') as src, gzip.open(archive, 'ab') as dst:
                    dst.write(src.read())
                os.remove(moving)
    with open(path, 'a') as f:
        for e in events:
            f.write(json.dumps(e, ensure_ascii=False, separators=(',', ':')) + '\n')
    if batch:
        kinds = collections.Counter(e['kind'] for e in events)  # insertion order = first seen
        print(f"logged {len(events)} events ({', '.join(f'{k}×{n}' for k, n in kinds.items())})")
    else:
        print(f"logged {events[0]['kind']}")
    return 0

# Line rules for always-loaded index files: (max lines, max chars per line). MEMORY.md is cut by the
# harness past ~25 KB / 200 lines; the global CLAUDE.md keeps itself near 120 lines (hard cap 125).
LINE_RULES = {'MEMORY.md': (200, 150), 'CLAUDE.md': (125, 100)}

def limit_for(path):
    b = os.path.basename(path)
    if b == 'MEMORY.md': return 16
    if b == 'CLAUDE.md': return 32
    if b == 'SKILL.md': return 8
    if b.startswith('lessons'): return 8
    if os.path.basename(os.path.dirname(path)) == 'agents': return 6
    return 16

def cmd_budget(args):
    over = 0
    for spec in args.files:
        path, _, lim = spec.partition(':')
        if not os.path.exists(path):
            print(f'MISSING {path}'); over = 1; continue
        kb = int(lim) if lim else limit_for(path)
        size = os.path.getsize(path)
        ok = size <= kb * 1024
        note = ''
        rule = LINE_RULES.get(os.path.basename(path))
        if rule:
            lines = open(path, errors='replace').read().splitlines()
            long = sum(1 for l in lines if len(l) > rule[1])
            if len(lines) > rule[0] or long:
                ok = False
            note = f'  · {len(lines)}/{rule[0]} lines, {long} over {rule[1]} chars'
        over |= not ok
        print(f"{'ok  ' if ok else 'OVER'} {size / 1024:6.1f} / {kb} KB  {path}{note}")
    return 1 if over else 0

def cmd_scan(args):
    # Secret scan for files that get committed or always loaded (lessons.md, MEMORY.md): any line
    # scrub() would change is a hit. Prints file:line only, never the value.
    hits = 0
    for path in args.files:
        for n, line in enumerate(open(path, errors='replace'), 1):
            if scrub(line) != line:
                hits += 1
                print(f'SECRET? {path}:{n}')
    print('scan: clean' if not hits else f'scan: {hits} line(s) look like secrets — redact before committing')
    return 1 if hits else 0

BIG_CTX = 300_000

def fmt_tokens(n):
    return f'{n / 1e9:.2f}B' if n >= 1e9 else f'{n / 1e6:.1f}M' if n >= 1e6 else f'{n / 1e3:.1f}k'

def epoch(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except (AttributeError, ValueError):
        return None

def usage_of(path, cut=0):
    """(tokens, turns, tokens of turns above BIG_CTX, max context, model family) of one transcript.
    One API response spans several lines (thinking, text, tool_use) that repeat its usage while
    streaming: keep the last line per message.id (final output_tokens). Lines stamped before `cut`
    belong to an earlier window (resumed sessions)."""
    final = {}
    try:
        fh = open(path, errors='replace')
    except OSError:
        return 0, 0, 0, 0, '?'  # removed mid-scan (transcript cleanup)
    with fh:
        for n, line in enumerate(fh):
            try:
                d = json.loads(line)
                msg = d.get('message') or {}
            except (ValueError, AttributeError):
                continue
            u = msg.get('usage') if isinstance(msg, dict) else None
            if not u or (epoch(d.get('timestamp')) or cut) < cut:
                continue
            ctx = sum(u.get(k) or 0 for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
            final[msg.get('id') or d.get('requestId') or n] = (ctx, u.get('output_tokens') or 0, msg.get('model') or '')
    tokens = big = top = 0
    family = '?'
    for ctx, out, model in final.values():
        tokens += ctx + out
        top = max(top, ctx)
        big += ctx + out if ctx > BIG_CTX else 0
        family = next((f for f in ('opus', 'sonnet', 'haiku', 'fable') if f in model), family)
    return tokens, len(final), big, top, family

def cmd_spend(args):
    cut = time.time() - args.days * 86400
    def fresh(paths):
        keep = []
        for f in paths:
            try:
                if os.path.getmtime(f) >= cut:
                    keep.append(f)
            except OSError:
                pass
        return keep
    mains = fresh(glob.glob(os.path.join(args.root, '*', '*.jsonl')))
    subs = fresh(glob.glob(os.path.join(args.root, '*', '*', 'subagents', '**', '*.jsonl'), recursive=True))
    if not mains and not subs:
        print(f'spend: no transcripts in the last {args.days:g} days under {args.root}')
        return 0
    main_tok = main_big = 0
    for f in mains:
        t, _, b, _, _ = usage_of(f, cut)
        main_tok += t; main_big += b
    groups, runs = collections.defaultdict(list), []
    for f in subs:
        try:
            kind = json.load(open(f[:-len('.jsonl')] + '.meta.json')).get('agentType') or '?'
        except (OSError, ValueError):
            kind = '?'
        t, n, _, top, fam = usage_of(f, cut)
        if not n:
            continue  # empty transcript: a dispatch that never ran a turn
        project = os.path.relpath(f, args.root).split(os.sep)[0]
        groups[(kind, fam)].append((t, n))
        runs.append((t, n, top, kind, fam, project))
    sub_tok = sum(r[0] for r in runs)
    total = (main_tok + sub_tok) or 1
    print(f'spend, last {args.days:g} days: total {fmt_tokens(main_tok + sub_tok)} · main {fmt_tokens(main_tok)} '
          f'({main_tok / total:.0%}) · subagents {fmt_tokens(sub_tok)} ({sub_tok / total:.0%})')
    print(f'main session turns at >{BIG_CTX // 1000}k: {main_big / (main_tok or 1):.0%} of main tokens')
    print('\nsubagents by type x model (tokens · share of subagents · runs · median turns):')
    for (kind, fam), rs in sorted(groups.items(), key=lambda kv: -sum(r[0] for r in kv[1])):
        tok = sum(r[0] for r in rs)
        med = sorted(r[1] for r in rs)[len(rs) // 2]
        print(f'  {fmt_tokens(tok):>8}  {tok / (sub_tok or 1):>4.0%}  {len(rs):>4} runs  {med:>4} turns  {kind} · {fam}')
    print('\nheaviest subagent runs:')
    for t, n, top, kind, fam, project in sorted(runs, reverse=True)[:5]:
        print(f'  {fmt_tokens(t):>8}  {n} turns  max ctx {fmt_tokens(top)}  {kind} · {fam}  {project}')
    return 0

SUSPEND_S = 3600
STALL_S = 3600
ROUND_GAP_S = 300
PHASE_AGENTS = ('builder-opus', 'builder', 'planner', 'reviewer', 'reviewer-sonnet', 'visual-judge')
# Precedence, highest first: a second covered by two intervals goes to the earlier category. Work in
# flight (bash, agent, bg) outranks both waits — a message arriving while something runs does not turn
# that work into waiting; ask-user (a pending AskUserQuestion) outranks everything.
PHASE_CATS = (['ask-user', 'bash:test', 'bash:accept-step', 'bash:visual', 'bash:other']
              + ['agent:' + a for a in PHASE_AGENTS]
              + ['agent:other', 'bg:test', 'bg:wait', 'bg:other', 'user-wait', 'launcher-wait', 'generation'])
BUILD_AGENTS = ('planner', 'builder', 'builder-opus')
# Launch prompts: the three prefixes of scripts/hooks-staged/owner_message.py (LAUNCH_MARKERS,
# is_launch_prompt), copied because learn.py stays importable standalone — change both together.
LAUNCH_MARKERS = ('AUTHORIZED:', 'WAVE BRIEF:', 'LAUNCHED-BY:')
# What a wave orchestrator types into a lane after the launch (relay, load pause/resume).
RELAY_MARKERS = ('Orquestrador:', 'PAUSA', 'CONTINUE')
# Machine-written user entries (owner_message.py SKIP): never an owner touch.
_MACHINE_TEXT = ('<local-command', '<task-notification', '<system-reminder', 'Caveat:', '[Request interrupted',
                 'Stop hook feedback', '<bash-', '<user-prompt-submit-hook', '<agent-message', '<cross-session-message')
_COMMAND_ARGS = re.compile(r'<command-args>\s*')
_WAVE_CMD = re.compile(r'\s*/rumo(?::rumo)?\s+wave\b'
                       r'|[\s\S]*?<command-name>\s*/rumo(?::rumo)?\s*</command-name>\s*<command-args>\s*wave\b')
_TEST_FILE = re.compile(r'test-all\.sh|_test\.(?:py|sh)|\.test\.(?:sh|[cm]?[jt]sx?)')
_TEST_RUNNER = re.compile(r'\b(?:pytest|vitest|jest|go test|cargo test|make test|playwright test)\b'
                          r'|\b(?:npm|pnpm|yarn|bun)\b[^;&|\n]*?\btest\b')
_HEREDOC_OPEN = re.compile(r"""(?<!<)<<-?\s*(['"]?)([A-Za-z_]\w*)\1""")
_ASSIGN = r'[A-Za-z_]\w*=\S*(?:\s+|$)'
_FLAGS = r'(?:-\S+\s+(?:\d\S*\s+)?)*'
_SEG_LEAD = re.compile(r'^(?:[\s(!{]+|(?:do|then|else|if|elif|while|until)\s+|' + _ASSIGN
                       + r'|(?:time|env|command|exec|nice|nohup|caffeinate|npx|bunx|pnpx)\s+' + _FLAGS
                       + r'|timeout\s+' + _FLAGS + r'\S+\s+)*')
_SHELL, _PY, _NODE = r'(?:\S*/)?(?:ba|z)?sh', r'(?:\S*/)?python[0-9.]*', r'(?:\S*/)?node'
_TEST_INTERPRETER = re.compile('|'.join((_SHELL, _PY, _NODE, r'(?:\S*/)?(?:tsx|deno|bun)')))
_SYNTAX_ONLY = re.compile(_SHELL + r'\s+-[a-z]*n\b|' + _PY + r'\s+-m\s+(?:py_compile|compileall)\b|'
                          + _NODE + r'\s+(?:--check|-c)\b')
_SHELL_C = re.compile(_SHELL + r'\s+(?:-\w+\s+)*-\w*c\s+')
_WORD_PART = re.compile(r'"((?:\\.|[^"\\])*)"|\'([^\']*)\'|\\(.)|([^\s"\'\\]+)', re.S)
_SEG_SPLIT = re.compile(r'&&|\|\||[;|\n]')
_CODE_ARG = re.compile(r'\s-[cep]\s+(?:"[^"]*"|\'[^\']*\'|\S+)')
_ASSIGNED = re.compile(r'([A-Za-z_]\w*)=(\S*)')
_FOR = re.compile(r'for\s+([A-Za-z_]\w*)\s+in\s+(.*)', re.S)
_HIDE = {';': '\x00', '|': '\x01', '&': '\x02', '\n': '\x03'}
_UNHIDE = {v: k for k, v in _HIDE.items()}
_CITE_HEADS = frozenset('git gh sed cat grep rg head tail ls wc awk find echo printf cp mv rm diff orca'.split())

def _drop_heredocs(cmd):
    """Drop each heredoc body that has a terminator line, unless a shell reads it as commands."""
    lines, out, i = cmd.split('\n'), [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in _HEREDOC_OPEN.finditer(line):
            end = next((k for k in range(i, len(lines)) if lines[k].strip() == m.group(2)), None)
            if end is None:
                continue
            if re.fullmatch(_SHELL, _seg_head(_SEG_SPLIT.split(line[:m.start()])[-1])[1]):
                out.extend(lines[i:end])
            i = end + 1
    return '\n'.join(out)

def _seg_head(seg):
    """(the segment without its lead words, its command word)."""
    s = _SEG_LEAD.sub('', seg, count=1)
    return s, (s.split(None, 1) or [''])[0]

def _shell_word(text):
    """The shell word `text` starts with: quoted and bare parts joined, escapes resolved."""
    out, pos = [], 0
    for m in _WORD_PART.finditer(text):
        if m.start() != pos:
            break
        dq, sq, esc, bare = m.groups()
        out.append(re.sub(r'\\([\\"$`\n])', r'\1', dq) if dq is not None else sq if sq is not None else esc or bare)
        pos = m.end()
    return ''.join(out)

def _hide_quoted(cmd):
    """Mask separators inside complete quotes, drop # comments, join backslash-newlines."""
    out, i, n = [], 0, len(cmd)
    while i < n:
        c = cmd[i]
        if c == '\\':
            nxt = cmd[i + 1:i + 2]
            out.append(' ' if nxt == '\n' else '\\' + _HIDE.get(nxt, nxt))
            i += 2
            continue
        if c == '#' and (i == 0 or cmd[i - 1] in ' \t\n;&|('):
            j = cmd.find('\n', i)
            i = n if j < 0 else j
            continue
        if c in '\'"':
            j = i + 1
            while j < n and cmd[j] != c:
                j += 2 if c == '"' and cmd[j] == '\\' else 1
            if j >= n:
                out.append(c)
                i += 1
                continue
            body = cmd[i + 1:j].replace('\\\n', '') if c == '"' else cmd[i + 1:j]
            out.append(c + ''.join(_HIDE.get(ch, ch) for ch in body) + c)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)

def runs_tests(cmd):
    """Does a segment of `cmd` run tests? Citing a test file (git add, sed, a quoted script) does not."""
    test_vars = set()
    for seg in _SEG_SPLIT.split(_hide_quoted(_drop_heredocs(cmd))):
        s, head = _seg_head(seg)
        test_vars.update(v for v, val in _ASSIGNED.findall(seg[:len(seg) - len(s)]) if _TEST_FILE.search(val))
        if head in _CITE_HEADS or _SYNTAX_ONLY.match(s):
            continue
        loop = _FOR.match(s)
        if loop:
            if _TEST_FILE.search(loop.group(2)):
                test_vars.add(loop.group(1))
            continue
        inner = _SHELL_C.match(s)
        if inner:
            if runs_tests(_shell_word(''.join(_UNHIDE.get(ch, ch) for ch in s[inner.end():]))):
                return True
            continue
        if _TEST_RUNNER.search(s):
            return True
        interp = _TEST_INTERPRETER.fullmatch(head)
        args = _CODE_ARG.sub(' ', s) if interp and not re.fullmatch(_SHELL, head) else s
        if interp and test_vars and re.match(r'\S+\s+(?:-\S+\s+)*["\']?\$\{?(?:%s)\b' % '|'.join(test_vars), args):
            return True
        if _TEST_FILE.search(args) and (interp or (head.endswith(('.sh', '.py')) and _TEST_FILE.search(head))):
            return True
    return False

def bash_fg_kind(cmd):
    if re.search(r'accept-step\.sh', cmd):
        return 'accept-step'
    if runs_tests(cmd):
        return 'test'
    if re.search(r'visual-lint|screenshot|playwright-cli', cmd):
        return 'visual'
    return 'other'

def bash_bg_kind(cmd):
    if runs_tests(cmd):
        return 'test'
    if re.search(r'\b(?:sleep|until|wait|gh run watch|gh pr checks)\b', cmd):
        return 'wait'
    return 'other'

def read_events(path, cut):
    """[(epoch, line dict)] of the conversation lines of one transcript stamped at or after `cut`."""
    out = []
    try:
        fh = open(path, errors='replace')
    except OSError:
        return []
    with fh:
        try:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(d, dict) or d.get('type') not in ('user', 'assistant', 'system', 'attachment', 'queue-operation'):
                    continue
                ts = epoch(d.get('timestamp'))
                if ts is not None and ts >= cut:
                    out.append((ts, d))
        except OSError:
            pass
    return out

def _blocks(d):
    msg = d.get('message')
    content = msg.get('content') if isinstance(msg, dict) else None
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []

def _has_result(d):
    return any(b.get('type') == 'tool_result' for b in _blocks(d))

def _origin_kind(d):
    o = d.get('origin')
    return o.get('kind') if isinstance(o, dict) else None

def is_launcher_message(text):
    """True when any line, left-stripped and with one leading `<command-args>` removed, starts with a
    launch or relay marker (case-sensitive): the message came from a launcher, not from the owner."""
    for line in str(text or '').splitlines():
        line = line.lstrip()
        if line.startswith('<command-args>'):
            line = _COMMAND_ARGS.sub('', line, count=1)
        if line.startswith(LAUNCH_MARKERS + RELAY_MARKERS):
            return True
    return False

def _is_human(d):
    return not d.get('isMeta') and (_origin_kind(d) == 'human' or d.get('turnOrigin') == 'human')

def invokes_wave(d):
    """True when the line is the owner invoking `/rumo wave`: a typed or queued prompt that opens with
    the command (plain or expanded to <command-name>/<command-args>), or the Skill call `rumo` with
    args starting `wave`. A message that only mentions the command, or a lane's `/rumo build`, is not."""
    kind = d.get('type')
    if kind == 'assistant':
        for b in _blocks(d):
            i = b.get('input') if isinstance(b.get('input'), dict) else {}
            if (b.get('type') == 'tool_use' and b.get('name') == 'Skill' and i.get('skill') in ('rumo', 'rumo:rumo')
                    and str(i.get('args') or '').lstrip().startswith('wave')):
                return True
        return False
    if kind == 'user':
        if not _is_human(d) or _has_result(d):
            return False
        msg = d.get('message')
        text = text_of(msg.get('content') if isinstance(msg, dict) else None)
    elif kind == 'attachment':
        a = d.get('attachment')
        if not isinstance(a, dict) or a.get('type') != 'queued_command' or (_origin_kind(d) or 'human') != 'human':
            return False
        text = a.get('prompt') if isinstance(a.get('prompt'), str) else ''
    else:
        return False
    return bool(_WAVE_CMD.match(text))

def event_label(d):
    """What the event was, for a stall report. Scrubbed before clipped; a user line's text never enters."""
    kind = d.get('type')
    if kind == 'assistant':
        x = 'assistant'
        for b in reversed(_blocks(d)):
            if b.get('type') == 'tool_use':
                i = b.get('input') if isinstance(b.get('input'), dict) else {}
                x = '%s: %s' % (b.get('name'), i.get('command') or i.get('description') or '')
                break
            if b.get('type') == 'text':
                x = 'assistant: %s' % (b.get('text') or '')
                break
    elif kind == 'user':
        x = 'tool_result' if _has_result(d) else 'user(%s)' % (_origin_kind(d) or '?')
    else:
        x = d.get('subtype') or kind
    return clip(scrub(str(x)), 120)

def subagent_runs(events):
    """(start, end) of each run of one subagent transcript: a user prompt after a long pause is a resume."""
    runs, start, prev = [], None, None
    for ts, d in events:
        if start is None:
            start = ts
        elif d.get('type') == 'user' and not _has_result(d) and ts - prev > ROUND_GAP_S:
            runs.append((start, prev))
            start = ts
        prev = ts
    if start is not None:
        runs.append((start, prev))
    return runs

def session_timeline(main, cut):
    """Events, category intervals, subagent runs and message stamps of one session at or after `cut`.
    `wave` looks at the whole transcript: the invocation may be older than the window."""
    events, intervals, runs, pr_ts, owner_ts, launcher_ts = [], [], [], [], [], []
    pending, bg = {}, {}
    wave = False
    prev = seg = last_as = None
    def close_gen():
        if seg is not None and last_as is not None and last_as > seg:
            intervals.append((seg, last_as, 'generation'))
    def close_bg(ts, text):
        for tag in ('tool-use-id', 'task-id'):
            m = re.search(r'<%s>\s*([^<\s]+)\s*</%s>' % (tag, tag), text)
            if m and m.group(1) in bg:
                start, cmd = bg[m.group(1)]
                for k in [k for k, v in bg.items() if v == (start, cmd)]:
                    del bg[k]
                intervals.append((start, ts, 'bg:' + bash_bg_kind(cmd)))
                break
    for ts, d in read_events(main, float('-inf')):
        wave = wave or invokes_wave(d)
        if ts < cut:
            continue
        events.append((ts, event_label(d)))
        kind = d.get('type')
        if prev is None:
            prev = ts
        if kind == 'assistant':
            last_as = ts
            for b in _blocks(d):
                if b.get('type') != 'tool_use' or b.get('name') not in ('Bash', 'AskUserQuestion'):
                    continue
                i = b.get('input') if isinstance(b.get('input'), dict) else {}
                cmd = str(i.get('command') or '')
                pending[b.get('id')] = (ts, b['name'], cmd, bool(i.get('run_in_background')))
                if b['name'] == 'Bash' and re.search(r'\bgh pr create\b', cmd):
                    pr_ts.append(ts)
        elif kind == 'user':
            close_gen()
            seg, last_as = ts, None
            msg = d.get('message')
            content = msg.get('content') if isinstance(msg, dict) else None
            if _is_human(d):
                text = text_of(content)
                launcher = is_launcher_message(text)
                if prev is not None and ts > prev:
                    intervals.append((prev, ts, 'launcher-wait' if launcher else 'user-wait'))
                if launcher:
                    launcher_ts.append(ts)
                elif text.strip() and not text.lstrip().startswith(_MACHINE_TEXT) and not _has_result(d):
                    owner_ts.append(ts)
            tur = d.get('toolUseResult')
            task_id = tur.get('backgroundTaskId') if isinstance(tur, dict) else None
            for b in _blocks(d):
                if b.get('type') != 'tool_result':
                    continue
                p = pending.pop(b.get('tool_use_id'), None)
                if p is None:
                    continue
                start, name, cmd, in_bg = p
                if name == 'AskUserQuestion':
                    intervals.append((start, ts, 'ask-user'))
                    continue
                if not in_bg:
                    intervals.append((start, ts, 'bash:' + bash_fg_kind(cmd)))
                if in_bg or task_id:
                    rec = (ts, cmd)
                    bg[b.get('tool_use_id')] = rec
                    if task_id:
                        bg[task_id] = rec
            text = text_of(content)
            if _origin_kind(d) == 'task-notification' or '<task-notification>' in text:
                close_bg(ts, text)
        elif kind == 'queue-operation':
            text = text_of(d.get('content'))
            if '<task-notification>' in text:
                close_bg(ts, text)
        if kind == 'assistant' or (kind == 'user' and not d.get('isMeta') and not d.get('isCompactSummary')):
            prev = ts
    close_gen()
    for f in glob.glob(glob.escape(main[:-len('.jsonl')]) + '/subagents/**/*.jsonl', recursive=True):
        try:
            k = json.load(open(f[:-len('.jsonl')] + '.meta.json')).get('agentType')
            k = k[len('rumo:'):] if k.startswith('rumo:') else k
        except (OSError, ValueError, AttributeError):
            k = '?'
        sev = read_events(f, cut)
        for a, b in subagent_runs(sev):
            runs.append((a, b, k))
            intervals.append((a, b, 'agent:' + (k if k in PHASE_AGENTS else 'other')))
        events.extend((ts, '[%s] %s' % (k, event_label(d))) for ts, d in sev)
    events.sort(key=lambda e: e[0])
    return {'events': events, 'intervals': intervals, 'runs': runs, 'pr_ts': pr_ts,
            'owner_ts': owner_ts, 'launcher_ts': launcher_ts, 'wave': wave}

def attribute_seconds(events, intervals):
    """Every second between the first and last event goes to one category: a hole (no event for
    SUSPEND_S) first, else the covering interval of lowest PHASE_CATS index, else idle."""
    res = {'totals': collections.Counter(), 'holes': [], 'idle_gaps': []}
    stamps = sorted(ts for ts, _ in events)
    if len(stamps) < 2:
        return res
    lo, hi = stamps[0], stamps[-1]
    res['holes'] = [(a, b) for a, b in zip(stamps, stamps[1:]) if b - a > SUSPEND_S]
    deltas = collections.defaultdict(list)   # time -> [(category index or -1 for a hole, +1/-1)]
    for a, b in res['holes']:
        deltas[a].append((-1, 1)); deltas[b].append((-1, -1))
    for a, b, cat in intervals:
        a, b = max(a, lo), min(b, hi)
        if b > a:
            i = PHASE_CATS.index(cat)
            deltas[a].append((i, 1)); deltas[b].append((i, -1))
    deltas[lo]; deltas[hi]
    times = sorted(deltas)
    count = collections.Counter()
    for t, nxt in zip(times, times[1:]):
        for i, dl in deltas[t]:
            count[i] += dl
        if count[-1] > 0:
            cat = 'suspended'
        else:
            cat = next((PHASE_CATS[i] for i in range(len(PHASE_CATS)) if count[i] > 0), 'idle')
        res['totals'][cat] += nxt - t
        if cat == 'idle':
            gaps = res['idle_gaps']
            if gaps and gaps[-1][1] == t:
                gaps[-1] = (gaps[-1][0], nxt)
            else:
                gaps.append((t, nxt))
    return res

def session_metrics(tl, attr):
    holes = attr['holes']
    def net(a, b):
        return (b - a) - sum(max(0, min(b, hb) - max(a, ha)) for ha, hb in holes)
    totals = attr['totals']
    m = {'active': sum(v for k, v in totals.items() if k not in ('idle', 'suspended')),
         'idle_s': totals.get('idle', 0), 'hole_s': totals.get('suspended', 0),
         'plan': None, 'build': None, 'review': None}
    m['stalled'] = m['idle_s'] + m['hole_s'] > STALL_S
    runs = tl['runs']
    stamps = [ts for ts, _ in tl['events']]
    span_start = min(stamps) if stamps else 0
    revs = sorted(a for a, _, k in runs if k in ('reviewer', 'reviewer-sonnet'))
    first_rev = revs[0] if revs else None
    planners = [(a, b) for a, b, k in runs if k == 'planner']
    if first_rev is not None:
        planners = [r for r in planners if r[0] < first_rev]
    plan_end = max((b for _, b in planners), default=None)
    if plan_end is not None:
        m['plan'] = net(span_start, plan_end)
        if first_rev is not None and first_rev > plan_end:
            m['build'] = net(plan_end, first_rev)
    if first_rev is not None:
        pr = next((t for t in sorted(tl['pr_ts']) if t >= first_rev), None)
        if pr is not None:
            m['review'] = net(first_rev, pr)
    builders = sorted((a, b) for a, b, k in runs if k in ('builder', 'builder-opus'))
    edges = sorted([(a, 1) for a, _ in builders] + [(b, -1) for _, b in builders])
    cur = top = 0
    for _, dl in edges:
        cur += dl; top = max(top, cur)
    m['max_builders'] = top
    # The build starts with its first planner/builder run; an owner message after that is a touch.
    start = min((a for a, _, k in runs if k in BUILD_AGENTS), default=None)
    m['owner_touches'] = sum(1 for t in tl.get('owner_ts', ()) if start is not None and t > start)
    gaps, max_end = [], None
    for a, b in builders:
        if max_end is not None and a > max_end:
            gaps.append(net(max_end, a))
        max_end = b if max_end is None else max(max_end, b)
    m['builder_gaps'] = gaps
    m['rounds'] = (1 + sum(1 for x, y in zip(revs, revs[1:]) if y - x > ROUND_GAP_S)) if revs else 0
    m['stall_label'] = None
    if m['stalled']:
        cands = list(holes) + list(attr['idle_gaps'])
        if cands:
            a, _ = max(cands, key=lambda c: c[1] - c[0])
            label = None
            for ts, lab in tl['events']:
                if ts <= a:
                    label = lab
            m['stall_label'] = label
    return m

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0

def fmt_clock(s):
    s = int(round(s))
    return '%d:%02d:%02d' % (s // 3600, s % 3600 // 60, s % 60)

def cmd_phases(args):
    cut = time.time() - args.days * 86400
    rows, waves = [], []   # (sid, project, metrics, attribution) · active seconds of each wave orchestrator
    for f in glob.glob(os.path.join(args.root, '*', '*.jsonl')):
        try:
            if os.path.getmtime(f) < cut:
                continue
        except OSError:
            continue
        tl = session_timeline(f, cut)
        if len(tl['events']) < 2:
            continue
        if tl['wave']:
            totals = attribute_seconds(tl['events'], tl['intervals'])['totals']
            waves.append(sum(v for k, v in totals.items() if k not in ('idle', 'suspended')))
            continue
        if not any(k in BUILD_AGENTS for _, _, k in tl['runs']):
            continue
        attr = attribute_seconds(tl['events'], tl['intervals'])
        rows.append((os.path.basename(f)[:-len('.jsonl')], os.path.basename(os.path.dirname(f)), session_metrics(tl, attr), attr))
    ms = [r[2] for r in rows]
    act = [m['active'] for m in ms]
    print(f'phases, last {args.days:g} days: {len(rows)} build sessions · active p50 {fmt_clock(pct(act, .5))} '
          f'(p25 {fmt_clock(pct(act, .25))} · p75 {fmt_clock(pct(act, .75))} · p90 {fmt_clock(pct(act, .9))})')
    print(f'wave orchestrators, out of the build set: {len(waves)} sessions · {fmt_clock(sum(waves))} active')
    tot = collections.Counter()
    for r in rows:
        tot.update(r[3]['totals'])
    susp = tot.pop('suspended', 0)
    whole = sum(tot.values()) or 1
    print('\ncritical path (total · share of the sum):')
    for cat, v in sorted(((c, v) for c, v in tot.items() if v), key=lambda kv: -kv[1]):
        print(f'  {fmt_clock(v)}  {v / whole:>3.0%}  {cat}')
    print(f'  suspended, out of the sum: {fmt_clock(susp)}')
    touches = [m['owner_touches'] for m in ms]
    print(f'owner touches per build: p50 {pct(touches, .5)} · p90 {pct(touches, .9)}')
    print(f'builds with zero owner touches after start: {sum(1 for x in touches if not x)}/{len(touches)}')
    print('\nphases (p50 · p75 · p90 · sessions):')
    for name in ('plan', 'build', 'review'):
        xs = [m[name] for m in ms if m[name] is not None]
        print(f'  {name}  {fmt_clock(pct(xs, .5))} · {fmt_clock(pct(xs, .75))} · {fmt_clock(pct(xs, .9))} · {len(xs)} sessions')
    print('\nbuilder concurrency:')
    ks = collections.Counter(m['max_builders'] for m in ms)
    for k in sorted(ks):
        print(f'  max {k} together: {ks[k]} sessions')
    print(f'  never 2 together: {sum(1 for m in ms if m["max_builders"] < 2) / (len(ms) or 1):.0%}')
    gaps = [g for m in ms for g in m['builder_gaps']]
    print(f'  gap builder end → next start: p50 {fmt_clock(pct(gaps, .5))} · p90 {fmt_clock(pct(gaps, .9))} ({len(gaps)} gaps)')
    rounds = [m['rounds'] for m in ms if m['rounds']]
    print(f'\nreview rounds: p50 {pct(rounds, .5)} · 3 or more: {sum(1 for x in rounds if x >= 3) / (len(rounds) or 1):.0%} '
          f'({len(rounds)} sessions with a reviewer)')
    stalled = sorted((r for r in rows if r[2]['stalled']), key=lambda r: -(r[2]['idle_s'] + r[2]['hole_s']))
    print(f'\nstalls: {len(stalled)} sessions · {fmt_clock(sum(r[2]["idle_s"] + r[2]["hole_s"] for r in stalled))} total')
    for sid, project, m, _ in stalled:
        print(f'  {sid[:8]}  {project}  {fmt_clock(m["idle_s"] + m["hole_s"])}  last: {m["stall_label"]}')
    return 0

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    h = sub.add_parser('harvest')
    g = h.add_mutually_exclusive_group()
    g.add_argument('--current', action='store_true')
    g.add_argument('--session')
    h.add_argument('--days', type=float, default=7)
    h.add_argument('--cwd', default=os.getcwd())
    h.add_argument('--root', default=DEFAULT_ROOT)
    h.add_argument('--limit', type=int, default=25)
    s = sub.add_parser('stats')
    s.add_argument('--events', default=DEFAULT_EVENTS)
    s.add_argument('--days', type=float, default=30)
    ev = sub.add_parser('event')
    ev.add_argument('json')
    ev.add_argument('--events', default=DEFAULT_EVENTS)
    sc = sub.add_parser('scan')
    sc.add_argument('files', nargs='+')
    sp = sub.add_parser('spend')
    sp.add_argument('--days', type=float, default=7)
    sp.add_argument('--root', default=DEFAULT_ROOT)
    ph = sub.add_parser('phases')
    ph.add_argument('--days', type=float, default=14)
    ph.add_argument('--root', default=DEFAULT_ROOT)
    nm = sub.add_parser('normalize')
    nm.add_argument('--events', default=DEFAULT_EVENTS)
    nm.add_argument('--out', default=None)
    b = sub.add_parser('budget')
    b.add_argument('files', nargs='+')
    args = p.parse_args(argv)
    return {'harvest': cmd_harvest, 'stats': cmd_stats, 'event': cmd_event, 'budget': cmd_budget,
            'scan': cmd_scan, 'spend': cmd_spend, 'phases': cmd_phases, 'normalize': cmd_normalize}[args.cmd](args)

if __name__ == '__main__':
    sys.exit(main())

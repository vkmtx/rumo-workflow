#!/bin/bash
# Stop hook: if JS-family source files (ts tsx js jsx mjs cjs mts cts vue svelte astro) INSIDE the
# session's git repo (its toplevel or one of its worktrees; a worktree under a temp dir the toplevel is not under is scratch) were edited since the last real user
# message, the repo has an npm check script, and no PASSING verification command ran after the
# last edit, block ONCE with the exact command to run.
#
# Not counted, by design: files outside the repo (scratchpad, $TMPDIR, ~/Documents, downloads);
# write targets it cannot resolve ($VAR unknown, $(…), backticks, relative after an unresolvable
# cd) — treated as scratch; other languages (.py .sql .go …) — the npm gate is not their check;
# css belongs to render-verify.
#
# Sibling of render-verify.sh (same shape: anchor on last user message, block once,
# fail-open on any error). render-verify covers "did you look at it"; this covers
# "did you prove it still works".
#
# Fail-open: malformed/empty stdin, unreadable transcript, no package.json, or no check
# script -> exit 0 (allow). Never blocks twice (honours stop_hook_active).
# VERIFY_HOOK_EXPLAIN=<file>: append one JSON line with the classification (replay harness).
INPUT=$(cat)
/usr/bin/python3 - "$INPUT" <<'PY' 2>/dev/null || exit 0
import json, os, re, shlex, subprocess, sys

try:
    inp = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

# Already continued once this stop — never loop.
if inp.get("stop_hook_active"):
    sys.exit(0)

try:
    lines = open(inp["transcript_path"]).read().splitlines()
except Exception:
    sys.exit(0)

entries = []
for l in lines:
    try:
        entries.append(json.loads(l))
    except Exception:
        pass

JS = re.compile(r'\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte|astro)$')  # only these get the npm gate
# A command that produces a pass/fail signal.
VERIFY = re.compile(
    r'(npm|pnpm|yarn|bun)\s+(run\s+)?(test|lint|typecheck|type-check|check|build|tsc|verify)'
    r'|\b(npm|pnpm|yarn|bun)\b[^;&|\n]*?\s(run\s+)?(test|lint|typecheck|type-check|check|build|tsc|e2e|verify)(:[\w:-]+)?(?![\w-])'
    r'|npx\s+(tsc|vitest|jest|eslint)'
    r'|\bnpx\s+(-\S+\s+)*[\w@./-]+\s+(lint|check|test)\b'
    r'|\bbiome\s+(check|lint|ci)\b'
    r'|\bplaywright\s+test\b'
    r'|\bnode\b[^;&|\n]*?\s--test(?![\w-])'
    r'|accept-step\.sh'
    r'|\bpython3?\s+(-\S+\s+)*-m\s+(pytest|unittest|mypy)\b'
    r'|\b(bash|sh|python3?)\s+(-\S+\s+)*(\S*/)?(\w[\w.-]*_test\.(sh|py)|\w[\w.-]*\.test\.sh|test_\w+\.py)(?![\w.])'
    r'|\b(bash|sh)\s+(-\S+\s+)*(\S*/)?test-all\.sh(?![\w.])'
    r'|\b(pytest|vitest|jest|go\s+test|cargo\s+(test|check|clippy)|rspec|phpunit|mypy|ruff)\b'
    r'|\btsc\b'
    r'|\bvercel\s+(build|deploy)\b'
)
EXPLAIN = os.environ.get("VERIFY_HOOK_EXPLAIN")

# Anchor: last real user message (not a tool_result, not meta).
last_user = 0
for i, e in enumerate(entries):
    if e.get("type") != "user" or e.get("isMeta"):
        continue
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        last_user = i
    elif isinstance(c, list) and not any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in c
    ):
        last_user = i

# --- repo scope (keep byte-identical in check-verify.sh and render-verify.sh) ---
def _strip_heredocs(cmd, bodies=None):
    """Drop heredoc bodies (keep the rest of the line); unterminated ones are left alone.
    With a `bodies` list, each body is appended to it and its operator is rewritten to
    `<<__HD<index>__` so the caller can key the body to the command that owns it."""
    out, pos = [], 0
    for m in re.finditer(r'(?<!<)<<-?\s*([\'"]?)(\w+)\1', cmd):
        if m.start() < pos:
            continue
        nl = cmd.find('\n', m.end())
        if nl < 0:
            continue
        end = re.compile(r'^[ \t]*' + re.escape(m.group(2)) + r'[ \t]*$', re.M).search(cmd, nl + 1)
        if not end:
            continue
        head = cmd[pos:nl]
        if bodies is not None:
            head = head[:m.start() - pos] + '<<__HD%d__' % len(bodies) + head[m.end() - pos:]
            bodies.append(cmd[nl + 1:end.start()])
        out.append(head); pos = end.start()
    out.append(cmd[pos:])
    return '\n'.join(out)

def expand(w, env):
    """`~` and $VAR / ${VAR} from env -> str; None when anything stays unresolved (unknown
    or unresolvable var, $(...), backtick). Callers treat None as scratch."""
    if w == '~' or w.startswith('~/'):
        w = os.path.expanduser('~') + w[1:]
    miss = []
    def sub(m):
        v = env.get(m.group(1) or m.group(2))
        if v is None:
            miss.append(m.group(0))
            return ''
        return v
    w = re.sub(r'\$\{(\w+)\}|\$(\w+)', sub, w)
    return None if miss or '$' in w or '`' in w else w

def script_writes(text):
    """Literal write targets in a python/node script text (heredoc body or -c/-e argument).
    Only these shapes: open('p','w'|'a'|'x'), NAME='p' later used by open(NAME,'w') /
    NAME.write_text( / writeFileSync(NAME, Path('p').write_text( / writeFileSync('p', and
    `def f(a, ...)` whose body opens `a` for writing -> every f('p') call literal."""
    P, Q = r'[^\'"\n]+', r'[\'"]'
    out, seen = [], set()
    def add(x):
        if x not in seen:
            seen.add(x); out.append(x)
    for m in re.finditer(r'open\(\s*(' + Q + r')(' + P + r')\1\s*,\s*' + Q + r'[wax]', text):
        add(m.group(2))
    # Sink names first (last position of each), then one pass over the assignments: linear.
    sinks = {}
    for m in re.finditer(r'open\(\s*(\w+)\s*,\s*' + Q + r'[wax]|(?<![\w.])(\w+)\.write_text\('
                         r'|writeFileSync\(\s*(\w+)\b', text):
        sinks[m.group(1) or m.group(2) or m.group(3)] = m.start()
    for m in re.finditer(r'(\w+)\s*=\s*(' + Q + r')(' + P + r')\2', text):
        if sinks.get(m.group(1), -1) >= m.end():
            add(m.group(3))
    for m in re.finditer(r'Path\(\s*(' + Q + r')(' + P + r')\1\s*\)\.write_text\(', text):
        add(m.group(2))
    for m in re.finditer(r'writeFileSync\(\s*(' + Q + r')(' + P + r')\1', text):
        add(m.group(2))
    # Writer helpers first (def f(a): ... open(a, 'w')), then ONE pass over the calls: linear.
    dedent, writers = re.compile(r'\n(?=\S)'), set()
    for m in re.finditer(r'\bdef\s+(\w+)\(\s*(\w+)\b[^\n]*?\)\s*(?:->[^\n:]*)?:', text):
        stop = dedent.search(text, m.end())
        body = text[m.end():stop.start() if stop else len(text)]
        if re.search(r'open\(\s*' + re.escape(m.group(2)) + r'\s*,\s*' + Q + r'[wax]', body):
            writers.add(m.group(1))
    if writers:
        for c in re.finditer(r'(?<![\w.])(\w+)\(\s*(' + Q + r')(' + P + r')\2', text):
            if c.group(1) in writers:
                add(c.group(3))
    return out

def bash_writes(cmd, base=None):
    """Quote- and heredoc-aware scan -> (writes, cd dirs, git-write?, git -C dirs, removed, info).
    writes = [(raw target, absolute path or None)] for `> f` / `>> f`, `tee f`, `sed -i` /
    `perl -pi` file args, plus literal write targets inside python/node heredocs and -c/-e
    scripts (script_writes), and the paths `git checkout <rev> [--] p` / `git restore -s <rev> p`
    bring from a rev other than HEAD. removed = [(raw, absolute path or None)] for `rm` args and
    the paths of `git checkout [HEAD] [--] p` / `git restore [-s HEAD] p`. info = {"wseg": shell-segment index of each
    write, "rseg": the same for removed, "texts": the text of every segment, "wsrc": per write,
    None or (op, src raw, src abs|None) when it is a `cp`/`mv` destination, "hbody": per segment
    the heredoc bodies a `bash`/`sh`/`zsh`/`ssh` runs ('' otherwise)}.
    Relative targets resolve against base and the `cd`s before them;
    $VAR/${VAR} expand from `X=v` / `export X=v` earlier in the command, then os.environ
    (PWD = current dir). None = unresolvable -> scratch. Raises on unparsable input."""
    bodies = []
    cmd = _strip_heredocs(cmd, bodies).replace('\\\n', ' ').replace('\n', ' ; ')
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lx.whitespace_split, lx.commenters = True, ''
    segs, cur = [], []
    for t in lx:
        if re.fullmatch(r'[();&|]+', t):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    env = dict(os.environ)
    here = base
    if here:
        env['PWD'] = here
    def resolve(raw):
        p = expand(raw, env)
        if p is None:
            return None
        if os.path.isabs(p):
            return os.path.normpath(p)
        return os.path.normpath(os.path.join(here, p)) if here else None
    writes, cds, gitdirs, gitw, removed = [], [], [], False, []
    wseg, rseg, wsrc, hbody = [], [], [], [''] * len(segs)
    for si, seg in enumerate(segs):
        wseg += [si - 1] * (len(writes) - len(wseg))
        rseg += [si - 1] * (len(removed) - len(rseg))
        args, tgts, hd, i = [], [], [], 0
        while i < len(seg):
            t = seg[i]
            if t == '<<' and i + 1 < len(seg) and re.fullmatch(r'__HD\d+__', seg[i + 1]):
                hd.append(bodies[int(seg[i + 1][4:-2])])
            if re.fullmatch(r'(>>?|>\||&>>?)', t):
                if i + 1 < len(seg):
                    tgts.append(seg[i + 1])
                i += 2; continue
            if re.fullmatch(r'[<>&|]+', t):
                i += 2; continue
            args.append(t); i += 1
        assigns = []
        while args and re.match(r'^\w+=', args[0]):
            assigns.append(args.pop(0))
        if not args:
            for x in assigns:
                k, v = x.split('=', 1)
                env[k] = expand(v, env)
        writes += [(x, resolve(x)) for x in tgts]
        if not args:
            continue
        c, a = args[0], args[1:]
        if hd and os.path.basename(c) in ('bash', 'sh', 'zsh'):
            hbody[si] = '\n'.join(hd)   # a shell that runs its heredoc: the body is commands
        if c == 'export':
            for x in a:
                if re.match(r'^\w+=', x):
                    k, v = x.split('=', 1)
                    env[k] = expand(v, env)
        elif c == 'tee':
            writes += [(x, resolve(x)) for x in a if not x.startswith('-')]
        elif c == 'cd':
            d = os.path.expanduser('~') if not a else None if a[0] == '-' else expand(a[0], env)
            if d is not None and not os.path.isabs(d):
                d = os.path.join(here, d) if here else None
            here = os.path.normpath(d) if d is not None else None
            if here:
                env['PWD'] = here
            cds.append(a[0] if a else '~')
        elif c == 'git':
            j = 0
            while j < len(a) and a[j].startswith('-'):
                if a[j] in ('-C', '-c') and j + 1 < len(a):
                    if a[j] == '-C':
                        gitdirs.append(a[j + 1])
                    j += 1
                j += 1
            sub, rest = (a[j] if j < len(a) else ''), a[j + 1:]
            if sub in ('commit', 'add', 'merge', 'cherry-pick', 'rebase') \
               or (sub == 'checkout' and '-b' in rest) or (sub == 'switch' and '-c' in rest):
                gitw = True
            # A path brought from HEAD (or the index) is a removal; from any other rev, a write.
            if sub == 'checkout' and '--' in rest:
                revs = [x for x in rest[:rest.index('--')] if not x.startswith('-')]
                into = writes if revs and revs[0] != 'HEAD' else removed
                into += [(x, resolve(x)) for x in rest[rest.index('--') + 1:]]
            elif sub == 'checkout' and not any(x in ('-b', '-B', '--orphan') for x in rest):
                # no `--`: `<rev> <p…>` or `<p…>` (a first arg that is no existing path is the rev);
                # an arg that is no path in the edit set removes nothing
                ops = [x for x in rest if not x.startswith('-')]
                rev = ops[0] if len(ops) >= 2 and not os.path.exists(resolve(ops[0]) or '') else None
                into = writes if rev and rev != 'HEAD' else removed
                into += [(x, resolve(x)) for x in (ops[1:] if rev else ops)]
            elif sub == 'restore' and not (any(x in ('--staged', '-S') for x in rest)
                                           and not any(x in ('--worktree', '-W') for x in rest)):
                k, rev, ps = 0, None, []
                while k < len(rest):
                    x = rest[k]
                    if x in ('-s', '--source'):
                        rev = rest[k + 1] if k + 1 < len(rest) else None
                        k += 1
                    elif x.startswith('--source='):
                        rev = x.split('=', 1)[1]
                    elif x.startswith('-s') and len(x) > 2:
                        rev = x[2:]
                    elif x != '--' and not x.startswith('-'):
                        ps.append(x)
                    k += 1
                into = writes if rev and rev != 'HEAD' else removed
                into += [(x, resolve(x)) for x in ps]
        elif c in ('cp', 'mv'):
            if any(x.startswith('--target-directory') or re.match(r'^-[A-Za-z]*t', x) for x in a
                   if x.startswith('-') and x != '--'):
                continue
            ops = [x for x in a if x == '' or not x.startswith('-')]
            if len(ops) >= 2:
                dest, srcs = ops[-1], ops[:-1]
                wsrc += [None] * (len(writes) - len(wsrc))
                if dest.endswith('/') or not os.path.splitext(dest)[1]:
                    writes += [(os.path.join(dest, os.path.basename(x.rstrip('/'))),
                                resolve(os.path.join(dest, os.path.basename(x.rstrip('/'))))) for x in srcs]
                    wsrc += [(c, x, resolve(x)) for x in srcs]
                else:
                    writes.append((dest, resolve(dest)))
                    wsrc.append((c, srcs[-1], resolve(srcs[-1])) if len(srcs) == 1 else None)
        elif c == 'rm':
            removed += [(x, resolve(x)) for x in a if x != '--' and not x.startswith('-')]
        elif re.fullmatch(r'python3?(\.\d+)?|node', os.path.basename(c)):
            texts = list(hd)
            for k, x in enumerate(a):
                if x in ('-c', '-e') and k + 1 < len(a):
                    texts.append(a[k + 1])
            for tx in texts:
                writes += [(x, resolve(x)) for x in script_writes(tx)]
        elif c in ('sed', 'perl'):
            if not any(re.match(r'^-[A-Za-z]*i', x) or x.startswith('--in-place') for x in a
                       if not x.startswith('--') or x.startswith('--in-place')):
                continue
            script, k = c == 'perl', 0
            while k < len(a):
                x = a[k]
                if x in ('-e', '-f', '--expression', '--file'):
                    script = True; k += 2; continue
                if x.startswith('-') or x == '':
                    k += 1; continue
                if not script:
                    script = True
                else:
                    writes.append((x, resolve(x)))
                k += 1
    wseg += [len(segs) - 1] * (len(writes) - len(wseg))
    rseg += [len(segs) - 1] * (len(removed) - len(rseg))
    wsrc += [None] * (len(writes) - len(wsrc))
    return writes, cds, gitw, gitdirs, removed, {"wseg": wseg, "rseg": rseg, "wsrc": wsrc,
                                                 "texts": [' '.join(x) for x in segs],
                                                 "hbody": hbody}

TEMPNAME = re.compile(r'(^|[._-])(tmp|temp)([._-])')

def is_temp(path, tracked=()):
    """A scratch-named file (playwright.tmp.config.ts, .tmp-x.mjs, foo.temp.ts) that git does not
    track (tracked = tracked_set(...) of the earlier pass) is not repo code."""
    return bool(path) and bool(TEMPNAME.search(os.path.basename(path))) and path not in tracked

def toplevels(cwd):
    """Realpaths of cwd's git toplevel plus every worktree of that repo, except worktrees under a temp dir ($TMPDIR, /tmp, /private/tmp, /var/folders) that the toplevel is not under; [] outside a repo."""
    def git(*a):
        try:
            r = subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True,
                               timeout=5)
        except Exception:
            return ''
        return r.stdout if r.returncode == 0 else ''
    top = git('rev-parse', '--show-toplevel').strip() if cwd else ''
    if not top:
        return []
    tops = [os.path.realpath(top)]
    roots = []
    for r in (os.environ.get('TMPDIR'), '/tmp', '/private/tmp', '/var/folders', '/private/var/folders'):
        if r:
            r = os.path.realpath(r).rstrip(os.sep)
            if r and r not in roots:
                roots.append(r)
    under = lambda p, r: p == r or p.startswith(r + os.sep)
    for l in git('worktree', 'list', '--porcelain').splitlines():
        if l.startswith('worktree '):
            p = os.path.realpath(l[len('worktree '):])
            if any(under(p, r) and not under(tops[0], r) for r in roots):
                continue
            if p not in tops:
                tops.append(p)
    return tops

def in_repo(path, tops):
    """True when realpath(path) is one of tops or lies inside one of them."""
    if not path:
        return False
    rp = os.path.realpath(path)
    return any(rp == t or rp.startswith(t + os.sep) for t in tops)
def ignored_set(paths, tops):
    """Paths (of those given) that git ignores: one `git -C <top> check-ignore --stdin -z` per
    toplevel. Any git error -> that path is kept (not in the result)."""
    by = {}
    for p in paths:
        rp = os.path.realpath(p)
        best = max((t for t in tops if rp == t or rp.startswith(t + os.sep)), key=len, default=None)
        if best:
            by.setdefault(best, {})[rp] = p
    ign = set()
    for top, m in by.items():
        try:
            r = subprocess.run(['git', '-C', top, 'check-ignore', '--stdin', '-z'],
                               input='\0'.join(m) + '\0', capture_output=True, text=True, timeout=10)
        except Exception:
            continue
        if r.returncode == 0:
            ign.update(m[x] for x in r.stdout.split('\0') if x in m)
    return ign

def tracked_set(paths, tops):
    """Paths (of those given) that git tracks: one `git -C <top> ls-files -z -- <paths>` per
    toplevel. Any git error -> every path of that toplevel (it keeps counting)."""
    by = {}
    for p in paths:
        rp = os.path.realpath(p)
        best = max((t for t in tops if rp == t or rp.startswith(t + os.sep)), key=len, default=None)
        if best:
            by.setdefault(best, {})[rp] = p
    trk = set()
    for top, m in by.items():
        try:
            r = subprocess.run(['git', '-C', top, 'ls-files', '-z', '--'] + list(m),
                               capture_output=True, text=True, timeout=10)
        except Exception:
            trk.update(m.values()); continue
        if r.returncode != 0:
            trk.update(m.values()); continue
        trk.update(m[x] for x in (os.path.join(top, y) for y in r.stdout.split('\0') if y) if x in m)
    return trk
# --- end repo scope ---

INPLACE = re.compile(r'\b(sed\s+(-\S+\s+)*-\S*i|perl\s+(-\S+\s+)*-\S*i)')
CAP = 20000   # VERIFY / INPLACE search at most this many chars of a command or segment

def is_check(text, budget=None):
    """A shell segment that is a verification: matches VERIFY and is no in-place edit (a
    `sed -i 's/jest/vitest/'` names a test runner but writes). Searches at most CAP chars;
    `budget` (a one-item list) is the per-command total, spent across segments: once it is
    empty, nothing more is a check."""
    n = CAP if budget is None else min(CAP, budget[0])
    if budget is not None:
        budget[0] -= len(text[:n])
    text = text[:n]
    return bool(VERIFY.search(text)) and not INPLACE.search(text)

def result_ok(r):
    if r is None:
        return True  # no result recorded: can't tell, don't punish
    if r.get("is_error"):
        return False
    c = r.get("content")
    if isinstance(c, list):
        c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
    if isinstance(c, str) and 'hook error' in (c.strip().splitlines() or [''])[0]:
        return False  # a PreToolUse hook denied the command: it never ran
    if isinstance(c, str) and re.search(r'moved to the background|running in the background', c):
        return False  # Claude Code backgrounded a long command: the text is a placeholder, not a pass
    m = re.match(r'\s*Exit code\s+(-?\d+)', c if isinstance(c, str) else "")
    return not (m and m.group(1) != "0")

# Results by tool_use_id; events in transcript order.
results = {}
for e in entries[last_user:]:
    content = (e.get("message") or {}).get("content")
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") == "tool_result":
                results[c.get("tool_use_id")] = c

cwd = inp.get("cwd") or os.getcwd()
tops = toplevels(cwd)

def why(ap, tops):
    if not ap:
        return "unresolved"
    if not JS.search(ap):
        return "not-js"
    if not tops:
        return "no-repo"
    if not in_repo(ap, tops):
        return "out-of-repo"
    if is_temp(ap, trk):
        return "temp-name"
    return "ignored" if ap in ign else "in-repo"

# git-ignored paths; every path that passed the other tests (for the batch check); tracked
# temp-named paths; every temp-named in-repo path (for the tracked batch check)
ign, pre, trk, tmpc = set(), set(), set(), set()

def counts(ap):
    if not (ap and JS.search(ap) and in_repo(ap, tops)):
        return False
    if is_temp(ap, trk):
        tmpc.add(ap)
        return False
    pre.add(ap)
    return ap not in ign

def outside(ap):
    """A cp destination that is no repo file: outside every repo top, or unresolvable."""
    return not ap or not in_repo(ap, tops)

def key(raw, ap):
    """Identity of a backup copy: its resolved realpath, else its raw text."""
    return os.path.realpath(ap) if ap else raw

def scan():
    """Positions are (tool_use index, shell segment index), so one command's own order counts.
    file_last[F] = position of F's last counted write (F = realpath); a cp of F out of the repo
    is a backup, and copying that backup back onto F is no write: file_last[F] returns to its
    value at backup time and (backup, restore) becomes a window in which no check proves F."""
    file_last, shown, windows, backups = {}, {}, {}, {}
    verifs, pos, cands = [], 0, []
    def wrote(ap, at):
        rp = os.path.realpath(ap)
        file_last[rp], shown[rp] = at, ap
    for e in entries[last_user:]:
        content = (e.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        base = e.get("cwd") or cwd
        for c in content:
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            pos += 1
            name, ti = c.get("name", ""), c.get("input", {}) or {}
            if name in ("Edit", "Write", "MultiEdit"):
                fp = ti.get("file_path", "") or ""
                ap = fp if os.path.isabs(fp) else (os.path.join(base, fp) if fp else "")
                # Only files inside the session's repo (or one of its worktrees) count; scratch, $TMPDIR, ~/Documents and downloads live outside it.
                ok = counts(ap)
                cands.append({"path": fp, "abs": ap, "counted": ok, "why": why(ap, tops)})
                if ok:
                    wrote(ap, (pos, 0))
            elif name == "Bash":
                cmd = ti.get("command", "") or ""
                bg = bool(ti.get("run_in_background"))  # its result is a placeholder, not a pass
                try:
                    wr, _, _, _, rm, info = bash_writes(cmd, base)
                except Exception:
                    wr, rm, info = [], [], {"wseg": [], "rseg": [], "wsrc": [],
                                            "texts": [_strip_heredocs(cmd)], "hbody": [""]}
                # The body of a heredoc a shell runs (`bash <<EOF`) is commands: its writes land
                # at that segment, and it is a check only when a check comes after its last write.
                bodies = {}
                for si, body in enumerate(info["hbody"]):
                    if not body:
                        continue
                    try:
                        bw, _, _, _, _, bi = bash_writes(body, base)
                    except Exception:
                        continue
                    bodies[si] = (bi["texts"], {w for (_, ap), w in zip(bw, bi["wseg"]) if counts(ap)})
                    wr = wr + bw
                    info["wseg"] = info["wseg"] + [si] * len(bw)
                    info["wsrc"] = info["wsrc"] + bi["wsrc"]
                for raw, ap in wr:
                    cands.append({"path": raw, "abs": ap, "counted": counts(ap),
                                  "why": why(ap, tops)})
                # A segment that writes a counted file is a WRITE segment and never a check, even
                # when its text names a test runner (`sed -e … -i src/jest.setup.ts`); one command
                # that edits then verifies (`sed -i … && npx vitest run`, a python heredoc then
                # `pnpm typecheck` on a later line) is verified-after when its last check segment
                # comes after the file's WRITE segment. Only shell segments (heredoc bodies
                # stripped) are checks - a commit message that mentions `npm test` is none -
                # plus the body of a heredoc a shell runs (`bash <<EOF`). One CAP of text is
                # searched per command, from its last segment back to the last check.
                wset = {si for (_, ap), si in zip(wr, info["wseg"]) if counts(ap)}
                bud = [CAP]
                vlast = None   # position of the command's last check segment
                for si in range(len(info["texts"]) - 1, -1, -1):
                    if si in bodies:
                        btx, bset = bodies[si]
                        bc = next((b for b in range(len(btx) - 1, -1, -1)
                                   if b not in bset and is_check(btx[b], bud)), None)
                        if bc is not None and bc > max(bset, default=-1):
                            vlast = si + 0.5   # after the body's own writes at si
                            break
                    elif si not in wset and is_check(info["texts"][si], bud):
                        vlast = si
                        break
                for (raw, ap), si, src in zip(wr, info["wseg"], info["wsrc"]):
                    at = (pos, si)
                    if src and ap and counts(ap):
                        b = backups.get(key(src[1], src[2]))
                        rp = os.path.realpath(ap)
                        if b and b[0] == rp:   # restore from F's own backup: no net edit
                            if b[1] is None:
                                file_last.pop(rp, None)
                            else:
                                file_last[rp] = b[1]
                            windows.setdefault(rp, []).append((b[2], at))
                            continue
                    if src and src[0] == 'cp' and src[2] and counts(src[2]) and outside(ap):
                        f = os.path.realpath(src[2])
                        backups[key(raw, ap)] = (f, file_last.get(f), at)
                    if counts(ap):
                        wrote(ap, at)
                # Files removed or restored by this command stop counting (unless written again after).
                wlast = {}   # realpath of each write -> its last segment (computed once)
                if rm:
                    for (_, ap), wi in zip(wr, info["wseg"]):
                        if ap:
                            rp = os.path.realpath(ap)
                            wlast[rp] = max(wlast.get(rp, -1), wi)
                for (_, rap), ri in zip(rm, info["rseg"]):
                    if not rap:
                        continue
                    rr = os.path.realpath(rap)
                    if wlast.get(rr, -1) > ri:
                        continue
                    for x in [x for x in file_last if x == rr or x.startswith(rr + os.sep)]:
                        file_last.pop(x); windows.pop(x, None)
                if vlast is not None and not bg:
                    verifs.append(((pos, vlast), c.get("id"), cmd))
    edits = {f: (file_last[f], windows.get(f, [])) for f in file_last}
    last_edit = max(file_last.values()) if file_last else (-1, -1)
    return edits, last_edit, verifs, cands, shown

def proves(v, edits):
    """One check at position v proves every edited file: after its last write, in no window."""
    return all(v > last and not any(b < v < r for b, r in wins) for last, wins in edits.values())

edits, last_edit, verifs, cands, shown = scan()
if pre or tmpc:
    ign = ignored_set(pre, tops) if pre else set()
    trk = tracked_set(tmpc, tops) if tmpc else set()
    if ign or trk:
        pre.clear(); tmpc.clear()
        edits, last_edit, verifs, cands, shown = scan()

verified = any(proves(p, edits) and result_ok(results.get(i)) for p, i, _ in verifs)

def explain(decision):
    if not EXPLAIN:
        return
    try:
        with open(EXPLAIN, "a") as f:
            f.write(json.dumps({
                "hook": "check-verify", "tops": tops, "files": cands,
                "verify_after_last_edit": [{"cmd": cmd[:200], "ok": result_ok(results.get(i))}
                                           for p, i, cmd in verifs if p > last_edit],
                "decision": decision}) + "\n")
    except Exception:
        pass

if not edits or verified:
    explain("allow")
    sys.exit(0)

# Only nag where a check actually exists. Walk up from cwd looking for package.json.
scripts, d = {}, cwd
for _ in range(5):
    p = os.path.join(d, "package.json")
    if os.path.isfile(p):
        try:
            scripts = json.load(open(p)).get("scripts", {}) or {}
        except Exception:
            scripts = {}
        break
    nd = os.path.dirname(d)
    if nd == d:
        break
    d = nd

PREFERRED = ["check", "typecheck", "type-check", "test", "lint", "build"]
available = [s for s in PREFERRED if s in scripts]
if not available:
    explain("allow")
    sys.exit(0)  # nothing to run — don't invent a gate

explain("block")
cmd = f"npm run {available[0]}"
names = sorted(shown.get(f, f) for f in edits)
listed = ", ".join(names[:4]) + (" …" if len(names) > 4 else "")
print(json.dumps({
    "decision": "block",
    "reason": (
        f"Source files changed and nothing verified them: {listed}. "
        f"House rule (CLAUDE.md §Verification): give the work a check that returns "
        f"pass/fail before calling it done. Run `{cmd}` "
        f"(available here: {', '.join(available)}), paste the output as evidence, and fix "
        f"what it reports. If this diff genuinely has no runnable check, say so in one line "
        f"and continue."
    ),
}))
PY

#!/bin/bash
# Stop hook: if visual files (css/scss/sass/less/tsx/jsx/vue/svelte/astro/html)
# were edited since the last real user message but fewer than two screenshots (desktop+phone) were taken AND
# Read after the last such edit, block ONCE with instructions to render and self-review.
# Counts only files inside the session's git repo (toplevel or one of its worktrees; a worktree under a temp dir the toplevel is not under is scratch); a repo with .claude/no-render-verify is skipped (video compositions, print documents). Unresolvable write targets ($VAR unknown, $(…)) are scratch.
# Fail-open on any error (malformed/empty stdin, unreadable transcript, bad JSON).
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

# Parse lines individually so one truncated line mid-write doesn't disable the check.
entries = []
for l in lines:
    try:
        entries.append(json.loads(l))
    except Exception:
        pass

VISUAL = re.compile(r'\.(css|scss|sass|less|tsx|jsx|vue|svelte|astro|html)$')
TESTFILE = re.compile(r'\.(test|spec)\.(tsx|jsx)$')
IMG = re.compile(r'\.(png|jpe?g|webp)$')
PWSHOT = re.compile(r'(playwright-cli\s+\S*|orca\s+(exec\s+--command\s+["\']?)?(full-)?)screenshot')

# Anchor: last real user message. Real = type "user", not isMeta, and content is a
# str OR a list containing no tool_result blocks (image pastes / queued text are lists).
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

cwd = inp.get("cwd") or os.getcwd()
tops = toplevels(cwd)
marker = bool(tops) and os.path.isfile(os.path.join(tops[0], ".claude", "no-render-verify"))
EXPLAIN = os.environ.get("VERIFY_HOOK_EXPLAIN")

def classify(raw, ap):
    """-> (counted, why); first match wins."""
    if not ap:
        return False, "unresolved"
    if not VISUAL.search(ap):
        return False, "not-visual"
    if TESTFILE.search(ap):
        return False, "test-file"
    if not tops:
        return False, "no-repo"
    if not in_repo(ap, tops):
        return False, "out-of-repo"
    if is_temp(ap, trk):
        tmpc.add(ap)
        return False, "temp-name"
    pre.add(ap)
    return (False, "ignored") if ap in ign else (True, "in-repo")

# git-ignored paths; every path that passed the other tests (for the batch check); tracked
# temp-named paths; every temp-named in-repo path (for the tracked batch check)
ign, pre, trk, tmpc = set(), set(), set(), set()

def scan():
    cands = []   # every Edit/Write path and Bash write target, with why it did or did not count
    # file_last[F] = pos of F's last counted write (F = realpath; shown keeps the path as written).
    # A cp of F out of the repo is a backup; copying it back onto F is no write: file_last[F]
    # returns to its value at backup time and (backup, restore) becomes a window: what was
    # shot or Read inside it showed the variant, not the file.
    file_last, shown, backups, windows, pos = {}, {}, {}, {}, 0
    reads = []   # (pos, path) of image Reads
    shots = []   # (pos, command) of screenshot commands
    inline = []  # pos of inline-image screenshot tools (e.g. chrome-devtools take_screenshot)
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
            fp = ti.get("file_path", "") or ""
            if name in ("Edit", "Write", "MultiEdit"):
                ap = fp if os.path.isabs(fp) else (os.path.join(base, fp) if fp else "")
                counted, why = classify(fp, ap)
                cands.append({"path": fp, "abs": ap, "counted": counted, "why": why})
                if counted:
                    file_last[os.path.realpath(ap)], shown[os.path.realpath(ap)] = pos, ap
            elif name == "Bash":
                cmd = ti.get("command", "") or ""
                try:
                    wr, _, _, _, rm, info = bash_writes(cmd, base)
                except Exception:
                    wr, rm, info = [], [], {"wseg": [], "rseg": [], "texts": [], "wsrc": []}
                for (raw, ap), src in zip(wr, info["wsrc"]):
                    counted, why = classify(raw, ap)
                    cands.append({"path": raw, "abs": ap, "counted": counted, "why": why})
                    if src and counted:
                        b = backups.get(os.path.realpath(src[2]) if src[2] else src[1])
                        rp = os.path.realpath(ap)
                        if b and b[0] == rp:   # restore from F's own backup: no net edit
                            if b[1] is None:
                                file_last.pop(rp, None)
                            else:
                                file_last[rp] = b[1]
                            windows.setdefault(rp, []).append((b[2], pos))
                            continue
                    if src and src[0] == 'cp' and src[2] and classify(src[1], src[2])[0] \
                       and not (ap and in_repo(ap, tops)):
                        f = os.path.realpath(src[2])
                        backups[os.path.realpath(ap) if ap else raw] = (f, file_last.get(f), pos)
                    if counted:
                        file_last[os.path.realpath(ap)], shown[os.path.realpath(ap)] = pos, ap
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
                if "screenshot" in cmd:
                    shots.append((pos, cmd))
            elif "take_screenshot" in name:
                inline.append(pos)
            elif "screenshot" in name.lower():
                shots.append((pos, json.dumps(ti)))
            if name == "Read" and IMG.search(fp):
                reads.append((pos, fp))
    edits = {shown.get(f, f) for f in file_last}
    # Last edit after restores and removals: the latest write of a file still edited.
    last_edit = max(file_last.values(), default=-1)
    wins = [w for ws in windows.values() for w in ws]
    return edits, last_edit, reads, shots, inline, cands, wins

edits, last_edit, reads, shots, inline, cands, wins = scan()
if pre or tmpc:
    ign = ignored_set(pre, tops) if pre else set()
    trk = tracked_set(tmpc, tops) if tmpc else set()
    if ign or trk:
        pre.clear(); tmpc.clear()
        edits, last_edit, reads, shots, inline, cands, wins = scan()

def inwin(p):
    """Position p lies inside a backup..restore window (the page showed a variant)."""
    return any(b < p < r for b, r in wins)

def fresh(p):
    # Path named by some screenshot command: must have been shot after the last edit, outside
    # every mutation window. Never named by one (shot by a tool we can't see into): accept.
    mine = [sp for sp, cmd in shots if p in cmd]
    return not mine or any(sp > last_edit and not inwin(sp) for sp in mine)

seen = {p for rp, p in reads if rp > last_edit and not inwin(rp) and fresh(p)}
n_images = len(seen) + sum(1 for ip in inline if ip > last_edit and not inwin(ip))

def explain(decision):
    if not EXPLAIN:
        return
    try:
        with open(EXPLAIN, "a") as f:
            f.write(json.dumps({"hook": "render-verify", "tops": tops, "marker": marker,
                                "files": cands, "n_images": n_images, "decision": decision}) + "\n")
    except Exception:
        pass

if marker:
    explain("allow")
    sys.exit(0)

if edits and n_images < 2:
    files = ", ".join(sorted(edits)[:5])
    explain("block")
    print(json.dumps({
        "decision": "block",
        "reason": (
            f"Visual files changed ({files}) but only {n_images} image(s) were screenshotted and "
            f"Read AFTER the last visual edit (need 2 distinct "
            "images: desktop 1440 and phone 390). "
            "Load the design-taste skill, open the page with "
            "Orca's browser (orca tab create; recipe in toolbelt), screenshot desktop (1440px) and "
            "mobile (390px) AFTER the last edit, and Read both screenshots to check the result "
            "against the taste contract before finishing. If rendering is impossible (no "
            "dev server, non-web project) OR the edit has no visual effect "
            "(logic-only change), finish anyway and tell the user the change is "
            "visually unverified."
        ),
    }))
    sys.exit(0)
explain("allow")
sys.exit(0)
PY
exit 0

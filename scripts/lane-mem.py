# lane-mem.py <worktree>...: memory footprint of each wave lane, one line per argument, in order: <MB> or ? (#121).
# wave-status.sh runs this text with `python3 -I -c` on the lane's host (locally, or through remote_wrap), so it
# must stay self-contained: stdlib only, no imports from beside it.
# A lane = claude processes whose cwd is the worktree (or inside it), plus any process whose command line names the
# worktree path (a dev server reparented to launchd), plus every descendant of those.
# Memory = `top` MEM (the phys footprint, compressed pages included: RSS hides them); `ps` RSS when top fails.
# ? = the path is not a directory on this host. A worktree with no live process prints 0.
import os, re, subprocess, sys

def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return ''

paths = sys.argv[1:]
live = [os.path.realpath(p) for p in paths if os.path.isdir(p)]
procs, mem = {}, {}
if live:
    for line in run(['ps', '-axo', 'pid=,ppid=,rss=,command=']).splitlines():
        f = line.split(None, 3)
        if len(f) == 4 and f[0].isdigit() and f[1].isdigit():
            procs[int(f[0])] = (int(f[1]), f[3])
            if f[2].isdigit():
                mem[int(f[0])] = int(f[2]) / 1024
    unit = {'B': 1 / 1048576, 'K': 1 / 1024, 'M': 1, 'G': 1024}
    for line in run(['top', '-l', '1', '-stats', 'pid,mem']).splitlines():
        m = re.fullmatch(r'\s*(\d+)\s+([\d.]+)([BKMG])[+-]?\s*', line)
        if m:
            mem[int(m.group(1))] = float(m.group(2)) * unit[m.group(3)]
# a native install runs as `claude ...`; an npm one as `node .../bin/claude ...` or `node .../claude-code/cli.js ...`
CLAUDE = re.compile(r'((\S*/)?node\s+)?(\S*/)?(claude|claude-code/cli\.js)(\s|$)')
claude = [p for p, (_, c) in procs.items() if CLAUDE.match(c)]
cwd = {}
if claude:
    pid = None
    for line in run(['lsof', '-a', '-d', 'cwd', '-p', ','.join(map(str, claude)), '-Fpn']).splitlines():
        if line.startswith('p') and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith('n') and pid is not None:
            cwd[pid] = os.path.realpath(line[1:])
self_chain, q = set(), os.getpid()   # this probe and its callers name every path on their command lines
while q > 1 and q not in self_chain:
    self_chain.add(q)
    q = procs.get(q, (0, ''))[0]
kids = {}
for p, (pp, _) in procs.items():
    if p not in self_chain:
        kids.setdefault(pp, []).append(p)

def inside(path, root):
    return path == root or path.startswith(root.rstrip('/') + '/')

for p in paths:
    if not os.path.isdir(p):
        print('?')
        continue
    root = os.path.realpath(p)
    named = re.compile(r'(^|[\s=:"\'])(%s|%s)(/|[\s"\']|$)' % (re.escape(root), re.escape(p.rstrip('/'))))
    seeds = [q for q in claude if inside(cwd.get(q, ''), root)] + [q for q, (_, c) in procs.items() if named.search(c) and q not in self_chain]
    seen, stack = set(), seeds
    while stack:
        q = stack.pop()
        if q not in seen:
            seen.add(q)
            stack.extend(kids.get(q, []))
    print(int(round(sum(mem.get(q, 0) for q in seen))))

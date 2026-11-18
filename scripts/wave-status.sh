#!/usr/bin/env bash
# wave-status.sh <wave-name> [host…] — one read-only status of every wave slot (wave.md §5), one line each.
# Reads the launch results wave.md §4 saved as <state dir>/<lane>.json (local lane) or <lane>@<host>.json
# (remote lane; result.launch.outcome.handle or result.outcome.handle, and the matching worktreeId).
# <lane> = an issue number, or for a lane without an issue a slug [a-z][a-z0-9-]* not starting with wt (wt*.json are skipped);
# a slug file is skipped only when it is a saved worktree-create result (result.worktree without a launch handle, e.g. create-79.json);
# a failed or empty launch file still prints, session=no-handle.
# Per slot one `orca worktree show`, one `orca terminal show` (both with `--environment <host>` on a remote slot), one
# `gh pr list`; then per host one lane-mem.py run for its slots (ps, top, lsof) and its machine. Local: sysctl, memory_pressure, pgrep.
# Remote: two $WAVE_REMOTE_SH <host> calls per host (load, and mem when it has a slot), one more per remote slot for idle,
# wrapped by host-lib.sh's remote_wrap (default: host-lib.sh's REMOTE_SH_DEFAULT). Hosts = local, then every host in a slot file or a [host…] arg. Never sends.
# gh pr list gets --repo <owner/name> from <state dir>/repo when that file exists.
# <state dir> = ~/.claude/learn/waves/<name>.state (survives a reboot); when absent, the legacy ${TMPDIR:-/tmp}/wave-<name> (a wave launched before #59).
#   #<N>|lane:<slug> host=<h> pr=#<n>:<STATE>|none session=alive|disconnected|dead:<code>|chat|no-handle idle=<min>|? stalled=yes|no|? mem=<MB>|? branch=<branch> card="<comment>"
#   machine host=<h> load=<1m> <5m> <15m> cores=<n> free=<p>% vm=normal|warn|critical|? fit=<n>|? pressure=yes|no  (host=local adds a last field: awake=yes|no|?)
#   chat: outcome.kind=structured — a chat tab has no terminal handle; liveness comes from idle/stalled.
#   idle: whole minutes since the newest mtime of the lane's transcripts, subagent transcripts and background-task outputs, read on the lane's host. ? = no worktree path or no such file.
#   stalled: idle>=30 and pr=none → yes; idle<30 or a real PR → no; otherwise ?.
#   awake: pgrep -f '^caffeinate -i -w ' (wave.md §4 starts it). exit 0 → yes, 1 → no, else ?.
#   mem: the lane's footprint in MB (lane-mem.py, one run per host for all its slots: claude processes with cwd in the worktree,
#     processes naming its path, their descendants). ? = no worktree path, or not a directory on the lane's host.
#   vm: the kernel's own pressure level (sysctl kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical).
#   fit: how many more lanes the host takes now — (free − floor) ÷ lane size, lane size = max(1500 MB, largest mem= on that
#     host), floor = the pressure free floor below; 0 when vm=warn|critical or pressure=yes; ? when free or hw.memsize is unread.
#   pressure=yes: 1m load > 3×cores, or free < 10% on local / < 25% on any other host, or vm=critical
# A field that could not be read prints `?`. Exit 0 · 2 usage (no name, or neither state dir exists).
set -uo pipefail
. "$(dirname "$0")/host-lib.sh"
usage() { echo "usage: wave-status.sh <wave-name> [host…]  (reads ~/.claude/learn/waves/<wave-name>.state/<lane>[@<host>].json, lane = issue number or slug)" >&2; exit 2; }
[ $# -ge 1 ] || usage
wdir="$HOME/.claude/learn/waves/$1.state"
[ -d "$wdir" ] || wdir="${TMPDIR:-/tmp}/wave-$1"   # legacy: a wave launched before this dir existed
[ -d "$wdir" ] || usage
shift
export WAVE_REMOTE_SH="${WAVE_REMOTE_SH:-$REMOTE_SH_DEFAULT}"
export WAVE_LOAD_PROBE="$(remote_wrap 'sysctl -n vm.loadavg; sysctl -n hw.ncpu; memory_pressure | tail -n 1; sysctl -n hw.memsize; sysctl -n kern.memorystatus_vm_pressure_level')"
# lane-mem.py shipped as text, so it runs the same on a remote host; the paths follow as "$@" (`<probe> _ <path>…`).
export WAVE_MEM_PROBE="$(remote_wrap "python3 -I -c $(printf %q "$(cat "$(dirname "$0")/lane-mem.py")") \"\$@\"")"
# The worktree's idle minutes, run on the lane's host. WAVE_WT = worktree path; WAVE_TASKS_ROOT is a test seam. Only reads mtimes.
IDLE_PY='import glob,os,re,time; wt=os.environ.get("WAVE_WT",""); enc=re.sub("[^A-Za-z0-9]","-",wt); cc=os.path.expanduser("~/.claude/projects/")+enc; tasks=os.environ.get("WAVE_TASKS_ROOT") or "/tmp/claude-%d"%os.getuid(); ps=glob.glob(cc+"/*.jsonl")+glob.glob(cc+"/*/subagents/agent-*.jsonl")+glob.glob(cc+"/*/subagents/workflows/*/agent-*.jsonl")+glob.glob(tasks+"/"+enc+"/*/tasks/*.output"); ms=[os.path.getmtime(p) for p in ps if os.path.exists(p)]; print(max(0,int((time.time()-max(ms))//60)) if wt and ms else "?")'
export WAVE_IDLE_PROBE="$(remote_wrap "python3 -I -c $(printf %q "$IDLE_PY")")"
exec python3 -I - "$wdir" "$@" <<'PY'
import json, os, re, shlex, subprocess, sys

# A remote host may also run production in a small VM, so it pauses earlier than local (10%).
FREE_MIN_LOCAL = 10
FREE_MIN_REMOTE = 25
STALLED_MIN = 30   # minutes without growth before a PR-less lane counts as stalled
LANE_MB_MIN = 1500   # a lane's size for fit= until a live one measures more (#121: ~0.4 GB idle, 2–3.6 GB with tests + dev server)
VM_LEVEL = {'1': 'normal', '2': 'warn', '4': 'critical'}

def run(cmd, cwd=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=20, cwd=cwd)
        return p.stdout
    except Exception:
        return ''

def js(cmd, cwd=None):
    try:
        return json.loads(run(cmd, cwd))
    except ValueError:
        return None

def get(d, *path):
    for k in path:
        d = d.get(k) if isinstance(d, dict) else None
    return d

def remote(host, cmd):
    return run(shlex.split(os.environ['WAVE_REMOTE_SH']) + [host, cmd])

def awake():
    try:
        rc = subprocess.run(['pgrep', '-f', '^caffeinate -i -w '], capture_output=True, timeout=20).returncode
    except Exception:
        return '?'
    return {0: 'yes', 1: 'no'}.get(rc, '?')

def idle_min(host, path):
    if not (isinstance(path, str) and path):
        return '?'
    cmd = 'WAVE_WT=%s %s' % (shlex.quote(path), os.environ['WAVE_IDLE_PROBE'])
    out = (run(['bash', '-c', cmd]) if host == 'local' else remote(host, cmd)).strip()
    return out if re.fullmatch(r'\d+', out) else '?'

def stalled(idle, pr):
    if pr.startswith('#') or (idle != '?' and int(idle) < STALLED_MIN):
        return 'no'
    return 'yes' if idle != '?' and pr == 'none' else '?'

def lane_mem(host, paths):
    # {path: MB or '?'} from one lane-mem.py run on that host
    if not paths:
        return {}
    cmd = os.environ['WAVE_MEM_PROBE'] + ' _ ' + ' '.join(shlex.quote(p) for p in paths)
    out = (run(['bash', '-c', cmd]) if host == 'local' else remote(host, cmd)).split()
    return {p: (v if re.fullmatch(r'\d+', v) else '?') for p, v in zip(paths, out + ['?'] * len(paths))}

def machine(host, lanes_mb):
    if host == 'local':
        load, cores = run(['sysctl', '-n', 'vm.loadavg']), run(['sysctl', '-n', 'hw.ncpu'])
        mem_line = (run(['memory_pressure']).strip().splitlines() or [''])[-1]
        memsize, level = run(['sysctl', '-n', 'hw.memsize']), run(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'])
    else:
        lines = (remote(host, os.environ['WAVE_LOAD_PROBE']).splitlines() + [''] * 5)[:5]
        load, cores, mem_line, memsize, level = lines
    load = load.strip().strip('{}').split()
    cores = cores.strip()
    free_match = re.search(r'(\d+)%', mem_line)
    free = free_match.group(1) + '%' if free_match else '?'
    vm = VM_LEVEL.get(level.strip(), '?')
    floor = FREE_MIN_LOCAL if host == 'local' else FREE_MIN_REMOTE
    try:
        pressure = 'yes' if float(load[0]) > 3 * int(cores) or int(free.rstrip('%')) < floor or vm == 'critical' else 'no'
    except (ValueError, IndexError):
        pressure = 'yes' if vm == 'critical' else '?'
    if vm in ('warn', 'critical') or pressure == 'yes':
        fit = '0'
    else:
        try:
            room = (int(free.rstrip('%')) - floor) / 100 * int(memsize.strip()) / 1048576
            fit = str(max(0, int(room // max([LANE_MB_MIN] + lanes_mb))))
        except ValueError:
            fit = '?'
    print('machine host=%s load=%s cores=%s free=%s vm=%s fit=%s pressure=%s%s' % (host, ' '.join(load[:3]) or '?', cores or '?', free, vm, fit, pressure, ' awake=' + awake() if host == 'local' else ''))

wdir = sys.argv[1]
try:
    repo = open(os.path.join(wdir, 'repo')).read().strip()
except OSError:
    repo = ''
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
    repo = ''
def launch_of(d):
    # (result, launch) of a saved `orca agent launch` result; launch is result.launch when that is an object
    r = get(d, 'result') or {}
    return r, (r.get('launch') if isinstance(r.get('launch'), dict) else r)

def is_create_result(f):
    # a saved `orca worktree create` reply: result.worktree is an object and there is no launch handle
    try:
        d = json.load(open(os.path.join(wdir, f)))
        return isinstance(get(d, 'result', 'worktree'), dict) and not get(launch_of(d)[1], 'outcome', 'handle')
    except Exception:
        return False

slots = []
for f in os.listdir(wdir):
    mt = re.fullmatch(r'(\d+|[a-z][a-z0-9-]*)(?:@([A-Za-z0-9._-]+))?\.json', f)
    if not mt or mt.group(1).startswith('wt'):
        continue   # wt*.json: a worktree-create result, not a slot
    lane, host = mt.group(1), mt.group(2) or 'local'
    if not lane.isdigit() and is_create_result(f):
        continue   # create-79.json: a saved worktree-create result, not a lane
    # issue lanes first (by number), then slug lanes (by slug); host breaks ties
    slots.append(((0, int(lane), '') if lane.isdigit() else (1, 0, lane), host, f, '#' + str(int(lane)) if lane.isdigit() else 'lane:' + lane))
slots.sort(key=lambda x: (x[0], x[1]))
rows = []
for _, host, f, label in slots:
    env = [] if host == 'local' else ['--environment', host]
    try:
        d = json.load(open(os.path.join(wdir, f)))
    except Exception:
        d = {}
    r, launch = launch_of(d)
    handle = get(launch, 'outcome', 'handle')
    wt = launch.get('worktreeId') or r.get('worktreeId')
    branch = card = pr = '?'
    cwd = path = None
    if wt:
        w = get(js(['orca', 'worktree', 'show'] + env + ['--worktree', 'id:' + wt, '--json']), 'result', 'worktree')
        if isinstance(w, dict) and w.get('branch'):
            path = w.get('path')
            branch = re.sub(r'^refs/heads/', '', w['branch'])
            card = json.dumps(w.get('comment') or '', ensure_ascii=False)
            cwd = w.get('path') if host == 'local' and os.path.isdir(str(w.get('path'))) else None
    if get(launch, 'outcome', 'kind') == 'structured':
        session = 'chat'   # a chat tab has no terminal handle: terminal show would answer terminal_handle_stale
    elif handle:
        t = js(['orca', 'terminal', 'show'] + env + ['--terminal', handle, '--json'])
        if not isinstance(t, dict):
            session = '?'
        elif t.get('ok'):
            session = 'alive' if get(t, 'result', 'terminal', 'connected') else 'disconnected'
        else:
            session = 'dead:' + str(get(t, 'error', 'code') or 'unknown')
    else:
        session = 'no-handle'
    if branch != '?':
        p = js(['gh', 'pr', 'list', '--head', branch, '--state', 'all', '--json', 'number,state'] + (['--repo', repo] if repo else []), cwd)
        if isinstance(p, list):
            pr = '#%s:%s' % (p[0].get('number'), p[0].get('state')) if p else 'none'
    idle = idle_min(host, path)
    rows.append((label, host, pr, session, idle, stalled(idle, pr), path if isinstance(path, str) and path else None, branch, card))

hosts = sorted({h for _, h, _, _ in slots} | set(sys.argv[2:]) - {'local'})
hosts = ['local'] + [h for h in hosts if h != 'local']
mems = {h: lane_mem(h, sorted({r[6] for r in rows if r[1] == h and r[6]})) for h in hosts}
for label, host, pr, session, idle, st, path, branch, card in rows:
    print('%s host=%s pr=%s session=%s idle=%s stalled=%s mem=%s branch=%s card=%s' % (label, host, pr, session, idle, st, mems[host].get(path, '?'), branch, card))
for h in hosts:
    machine(h, [int(v) for v in mems[h].values() if v != '?'])
PY

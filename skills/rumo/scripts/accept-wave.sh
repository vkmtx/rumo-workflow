#!/usr/bin/env bash
# accept-wave.sh - accept every step of one build wave in one call: wave-wide scope check,
# then per step accept-step.sh, commit by path, and the `- Done: <sha>` line in the plan.
#
# Usage: accept-wave.sh <worktree> <plan.md> [--copy <plan copy path>]
#          <step>=<commit message> [<step>=<commit message> ...]
#   <step> is the id in the plan's `### Step <n>:` heading (fix steps: F1, F2 ...).
#   Run it only after every builder of the wave has reported.
#
# In order:
#   parse     each named step's Files, Verify (first backticked command), Type and the
#             optional `- Expect: <ERE>` line. Unknown step, or one that already carries
#             `- Done:` -> usage error.
#   scope     git status --porcelain --ignored --untracked-files=all (minus .rumo and
#             node_modules): every changed path must be in exactly one named step's Files.
#             A path in none, a path in two, or a NEW ignored .env* file -> one
#             `WAVE FAIL scope <path> — <reason>` line each, exit 1, nothing run or
#             committed. Other ignored paths are skipped.
#             New = born after the plan file: the env file's st_birthtime (st_mtime where
#             the platform has none) > the plan's st_birthtime, so the worktree's slot
#             .env.local, written before the plan, passes silently. No birth time for the
#             plan -> ignored env files are not checked, one stderr line says so.
#   per step  (in the order given) accept-step.sh <wt> '<Verify>' --code <changed non-test
#             Files> --tests <changed test Files> [--expect '<Expect>']. A step whose changed
#             Files are all tests, or of Type judgment/visual with no test file, runs its
#             Verify alone and is accepted on exit 0 (and Expect, when present).
#             accept -> git add + commit of that step's changed Files, `- Done: <short sha>`
#                       after the step's last field line (plan and --copy),
#                       `STEP <n> ACCEPT OK <short sha>`
#             reject -> `STEP <n> ACCEPT FAIL: <reason>` + the failing output indented;
#                       its files stay uncommitted and the next step runs.
#   last line `WAVE OK <k>/<k>` or `WAVE FAIL <ok>/<total> — rejected: <ids>`
#
# Exit codes:
#   0  every step accepted and committed
#   1  scope failure, or at least one step rejected
#   2  usage/internal error (including accept-step.sh's own exit 2, which stops the wave)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I - "$HERE" "$@" <<'PY'
import os
import re
import subprocess
import sys

USAGE = ("usage: accept-wave.sh <worktree> <plan.md> [--copy <plan copy path>] "
         "<step>=<commit message> [<step>=<commit message> ...]")
FIELDS = ["Files", "Does", "Test first", "Verify", "Type", "Risk", "Category",
          "Parallel with", "Model", "Expect", "Done"]
FIELD_RE = re.compile(
    r"^- (" + "|".join(re.escape(f) for f in FIELDS) + r")(?:[ \t]*\(.*?\))?[ \t]*:[ \t]*(.*)$")
STEP_RE = re.compile(r"^### Step ([0-9]+|F[0-9]+)(?::| [—–-])")
TEST_RE = re.compile(r"(^|/)(tests?|__tests__)/|\.(test|spec)\.[a-z]+$|_test\.[a-z]+$|(^|/)test_[^/]+$")


def usage(msg=None):
    if msg:
        print("accept-wave: " + msg, file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def parse(text):
    """{step id: {"f": {field: value}, "end": index of the step's last field line}} —
    the same line walk as plan-check.sh (fences, indented continuations, first field wins)."""
    steps = {}
    cur = None
    last = None
    in_fence = False
    for i, ln in enumerate(text.splitlines()):
        indented = ln[:1] in (" ", "\t") and bool(ln.strip())
        if ln.strip().startswith("```"):
            in_fence = not in_fence
            if cur is not None and last is not None and indented:
                cur["end"] = i
            continue
        if in_fence:
            if cur is not None and last is not None and indented:
                cur["f"][last] += "\n" + ln.strip()
                cur["end"] = i
            continue
        m = STEP_RE.match(ln)
        if m:
            cur = {"f": {}, "end": i}
            steps.setdefault(m.group(1), cur)
            last = None
            continue
        if ln.startswith("#"):
            cur = None
            last = None
            continue
        if cur is None:
            continue
        if indented:
            if last is not None:
                cur["f"][last] += "\n" + ln.strip()
                cur["end"] = i
            continue
        fm = FIELD_RE.match(ln)
        if fm:
            cur["end"] = i
            if fm.group(1) not in cur["f"]:
                cur["f"][fm.group(1)] = fm.group(2).strip()
                last = fm.group(1)
            else:
                last = None
        elif ln.strip():
            last = None
    return steps


def files_of(val):
    out = []
    # annotations only ("(create)"): a parenthetical after whitespace or a closing backtick
    val = re.sub(r"(?:(?<=\s)|(?<=`))\([^)]*\)", "", val)
    for part in val.replace("\n", ",").split(","):
        p = re.sub(r"^[-*+][ \t]+", "", part.strip()).replace("`", "").strip()
        if p.startswith("./"):
            p = p[2:]
        if p and p not in out:
            out.append(p)
    return out


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def add_done(path, sid, sha):
    text = read(path)
    step = parse(text).get(sid)
    if step is None:
        print(f"accept-wave: {path}: Step {sid} not found — Done line not written", file=sys.stderr)
        return
    lines = text.split("\n")
    lines.insert(step["end"] + 1, f"- Done: {sha}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def run(argv, cwd=None):
    p = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def tail(out, skip=None, n=20):
    rows = [r for r in out.splitlines() if r.strip() and r != skip]
    return ["    " + r for r in rows[-n:]]


# ---- arguments -------------------------------------------------------------------------
here = sys.argv[1]
argv = sys.argv[2:]
if len(argv) < 3:
    usage()
wt, plan = argv[0], argv[1]
copy = None
wave = []  # [(step id, commit message)]
rest = argv[2:]
i = 0
while i < len(rest):
    a = rest[i]
    if a == "--copy":
        if i + 1 >= len(rest):
            usage("--copy needs a path")
        copy = rest[i + 1]
        i += 2
        continue
    m = re.match(r"^(F?[0-9]+)=(.*)$", a, re.S)
    if not m or not m.group(2).strip():
        usage(f"expected <step>=<commit message>, got: {a}")
    if m.group(1) in [s for s, _ in wave]:
        usage(f"step {m.group(1)} named twice")
    wave.append((m.group(1), m.group(2)))
    i += 1
if not wave:
    usage("no step given")
if not os.path.isdir(wt):
    usage(f"worktree not found: {wt}")
wt = os.path.realpath(wt)
for p in [plan] + ([copy] if copy else []):
    if not os.path.isfile(p):
        usage(f"plan not found: {p}")
accept_step = os.path.join(here, "accept-step.sh")
if not os.path.isfile(accept_step):
    usage(f"accept-step.sh not found next to this script: {accept_step}")

# ---- 1. parse the named steps ------------------------------------------------------------
parsed = parse(read(plan))
info = {}
for sid, _ in wave:
    if sid not in parsed:
        usage(f"Step {sid} is not in {plan}")
    f = parsed[sid]["f"]
    if "Done" in f:
        usage(f"Step {sid} already has a Done line ({f['Done']})")
    files = files_of(f.get("Files", ""))
    if not files:
        usage(f"Step {sid}: no Files")
    vm = re.search(r"`([^`]+)`", f.get("Verify", ""))
    if not vm:
        usage(f"Step {sid}: Verify has no backticked command")
    tm = re.match(r"\w+", f.get("Type", ""))
    expect = f.get("Expect", "").strip()
    if len(expect) >= 2 and expect[0] == "`" and expect[-1] == "`":
        expect = expect[1:-1]
    info[sid] = {"files": files, "verify": vm.group(1), "type": tm.group(0) if tm else "",
                 "expect": expect}

# ---- 2. scope, for the whole wave --------------------------------------------------------
rc, top = run(["git", "-C", wt, "rev-parse", "--show-toplevel"])
if rc != 0 or os.path.realpath(top.strip()) != wt:
    usage(f"not the root of a git worktree: {wt}")
p = subprocess.run(["git", "-C", wt, "status", "--porcelain", "-z", "--ignored",
                    "--untracked-files=all", "--", ".", ":!.rumo", ":!node_modules"],
                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if p.returncode != 0:
    print("accept-wave: git status failed: " + p.stderr.decode("utf-8", "replace").strip(),
          file=sys.stderr)
    sys.exit(2)
toks = p.stdout.decode("utf-8", "surrogateescape").split("\0")
changed = []
scope_fails = []
# an ignored .env* is new when born after the plan file (the slot .env.local predates the plan)
plan_born = getattr(os.stat(plan), "st_birthtime", None)
k = 0
while k < len(toks):
    t = toks[k]
    k += 1
    if len(t) < 4:
        continue
    xy, path = t[:2], t[3:]
    paths = [path]
    if "R" in xy or "C" in xy:  # -z: the original path is the next token
        if k < len(toks):
            if "R" in xy:
                paths.append(toks[k])
            k += 1
    if xy == "!!":
        if plan_born is not None and os.path.basename(path.rstrip("/")).startswith(".env"):
            try:
                est = os.stat(os.path.join(wt, path))
                born = getattr(est, "st_birthtime", est.st_mtime)
            except OSError:
                born = None
            if born is not None and born > plan_born:
                scope_fails.append((path, "new ignored .env* file, created after the plan"))
        continue
    for q in paths:
        if q not in changed:
            changed.append(q)

if plan_born is None:
    print("accept-wave: no birth time on this platform — ignored env files not checked",
          file=sys.stderr)
owner = {}
for path in changed:
    owners = [sid for sid, _ in wave if path in info[sid]["files"]]
    if not owners:
        scope_fails.append((path, "in no step's Files (" + ", ".join(s for s, _ in wave) + ")"))
    elif len(owners) > 1:
        scope_fails.append((path, "in the Files of steps " + " and ".join(owners)))
    else:
        owner[path] = owners[0]
if scope_fails:
    for path, why in scope_fails:
        print(f"WAVE FAIL scope {path} — {why}")
    sys.exit(1)

# ---- 3. accept, commit, mark Done — per step ----------------------------------------------
accepted = []
rejected = []
abort = None
for sid, msg in wave:
    if abort is not None:
        print(f"STEP {sid} ACCEPT FAIL: not run — accept-step.sh error on step {abort}")
        rejected.append(sid)
        continue
    st = info[sid]
    mine = [f for f in st["files"] if owner.get(f) == sid]
    if not mine:
        print(f"STEP {sid} ACCEPT FAIL: none of the step's Files changed — nothing to accept or commit")
        rejected.append(sid)
        continue
    tests = [f for f in mine if TEST_RE.search(f)]
    code = [f for f in mine if f not in tests]
    reason = None
    detail = []
    if not code or (st["type"] in ("judgment", "visual") and not tests):
        rc, out = run(["bash", "-c", st["verify"]], cwd=wt)
        if rc != 0:
            reason, detail = f"verify failed (exit {rc})", tail(out)
        elif st["expect"]:
            g = subprocess.run(["grep", "-Eq", "--", st["expect"]], input=out.encode("utf-8"),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if g.returncode != 0:
                reason, detail = "verify output does not match --expect", tail(out)
    else:
        cmd = ["bash", accept_step, wt, st["verify"]]
        if st["expect"]:
            cmd += ["--expect", st["expect"]]
        cmd += ["--code"] + code
        if tests:
            cmd += ["--tests"] + tests
        rc, out = run(cmd)
        if rc != 0:
            rows = [r for r in out.splitlines() if r.strip()]
            line = next((r for r in rows if r.startswith(("ACCEPT FAIL:", "ACCEPT ERROR:"))),
                        rows[-1] if rows else f"accept-step.sh exit {rc}")
            reason = re.sub(r"^ACCEPT FAIL:\s*", "", line)
            detail = tail(out, skip=line)
            if rc != 1:
                abort = sid
    if reason is None:
        rc, out = run(["git", "-C", wt, "add", "--"] + mine)
        if rc == 0:
            rc, out = run(["git", "-C", wt, "commit", "-q", "-m", msg, "--"] + mine)
        if rc != 0:
            reason, detail = "git add/commit failed", tail(out)
    if reason is not None:
        print(f"STEP {sid} ACCEPT FAIL: {reason}")
        if detail:
            print("\n".join(detail))
        rejected.append(sid)
        continue
    sha = run(["git", "-C", wt, "rev-parse", "--short", "HEAD"])[1].strip()
    add_done(plan, sid, sha)
    if copy:
        add_done(copy, sid, sha)
    print(f"STEP {sid} ACCEPT OK {sha}")
    accepted.append(sid)

total = len(wave)
if rejected:
    print(f"WAVE FAIL {len(accepted)}/{total} — rejected: {', '.join(rejected)}")
    sys.exit(2 if abort is not None else 1)
print(f"WAVE OK {total}/{total}")
PY

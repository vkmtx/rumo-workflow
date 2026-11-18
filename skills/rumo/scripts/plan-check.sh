#!/usr/bin/env bash
# plan-check.sh [--small] <plan.md> — mechanical form check of a rumo plan (step fields, enums,
# Model rule, parallel-file overlap, step count, size ≤ 24000 characters, a push/merge/hook step is Risk security,
# security steps carry non-empty abuse cases). Prints PLAN FAIL lines (exit 1) or one
# PLAN OK line (exit 0). Usage error / missing file: stderr, exit 2.
# `--small`: ≤ 2 steps, ≤ 8000 characters.
set -uo pipefail
SMALL=0
if [ "${1:-}" = "--small" ]; then SMALL=1; shift; fi
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: plan-check.sh [--small] <plan.md>" >&2
  exit 2
fi
exec python3 -I - "$1" "$SMALL" <<'PY'
import re
import sys

FIELDS = ["Files", "Does", "Test first", "Verify", "Type", "Risk", "Category",
          "Parallel with", "Model"]
TYPES = {"cmd", "visual", "judgment"}
RISKS = {"none", "money", "auth", "data", "security", "prod"}
CATS = {"test", "ui-logic", "api", "db-migration", "data-model", "config",
        "build-tooling", "refactor", "integration", "auth", "perf", "docs", "other"}
MODELS = {"sonnet", "opus", "orchestrator"}
SMALL = sys.argv[2] == "1"
MAX_CHARS = 8000 if SMALL else 24000
MAX_STEPS = 2 if SMALL else 6
ABUSE_LABELS = ["hook:", "third-party input:", "check-to-use:", "deletion:"]


def abuse_case_filled(tf, label):
    """The text after label, up to the next label / happy: / end, holds a case or n/a — <why>."""
    def at(lb, pos=0):  # a label at a word start: "webhook:" is not "hook:"
        m = re.compile(r"(?<![\w-])" + re.escape(lb)).search(tf, pos)
        return m.start() if m else -1
    start = at(label)
    if start == -1:
        return False
    start += len(label)
    ends = [p for p in (at(x, start) for x in ABUSE_LABELS + ["happy:"]) if p != -1]
    seg = tf[start:min(ends)] if ends else tf[start:]
    seg = re.sub(r"<[^>]*>", " ", seg)  # template placeholders such as <why> are not content
    m = re.match(r"[\s`*_'\"(\[:\-—–]*n/a\b(.*)", seg, re.S)
    if m:
        seg = m.group(1)  # n/a needs a reason after it
    return re.search(r"[^\W_]", seg) is not None

TRIGGER_DOES = [re.compile(p, re.I) for p in (
    r"""\bgit\b(?:\s+-{1,2}[\w-]+(?:[ =](?:"[^"]*"|'[^']*'|[^\s-]\S*))?)*\s+(push|merge|clean|rm)(?![\w-])""",
    r"\bgit\s+reset\s+--hard\b", r"\bgit\b[^\n]*?\bworktree\s+remove\b", r"\bgit\b[^\n]*?\bbranch\s+-[dD]\b",
    r"\bgh\s+pr\s+(create|merge)\b", r"\bdeploy(s|ed|ing)?\b", r"\brm\s+-\w*[rf]", r"(?<!-)\brm\s+[\"$./~]",
    r"\bfind\b[^\n]*\s-delete\b", r"\bshred\b", r"\b(rmtree|rimraf|unlinkSync|unlink)\b", r"\bos\.remove\b",
    r"\bfs\.rm", r"\beval\s*[(\"$\x27]", r"shell\s*=\s*True", r"\b(sh|bash)\s+-c\b", r"\bexecSync\b",
    r"\bos\.system\b")]
TRIGGER_PATH = re.compile(r"(^|/)((\.claude/hooks|hooks-staged|\.husky|\.githooks|\.git/hooks)/"
                          r"|hooks/hooks\.json$|\.claude/settings(\.local)?\.json$)")

with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
lines = text.splitlines()

FIELD_RE = re.compile(
    r"^- (" + "|".join(re.escape(f) for f in FIELDS) + r")(?:[ \t]*\(.*?\))?[ \t]*:[ \t]*(.*)$")

steps = []  # (id, {field: value})
cur = None
last = None
in_fence = False
for ln in lines:
    if ln.strip().startswith("```"):
        in_fence = not in_fence
        continue
    if in_fence:
        if cur is not None and last is not None and ln[:1] in (" ", "\t") and ln.strip():
            cur[1][last] += "\n" + ln.strip()
        continue
    m = re.match(r"^### Step ([0-9]+|F[0-9]+)(?::| [—–-])", ln)
    if m:
        cur = (m.group(1), {})
        steps.append(cur)
        last = None
        continue
    if ln.startswith("#"):
        cur = None
        last = None
        continue
    if cur is None:
        continue
    if ln[:1] in (" ", "\t") and ln.strip():
        if last is not None:
            cur[1][last] += "\n" + ln.strip()
        continue
    fm = FIELD_RE.match(ln)
    if fm:
        if fm.group(1) not in cur[1]:
            cur[1][fm.group(1)] = fm.group(2).strip()
            last = fm.group(1)
        else:
            last = None
    elif ln.strip():
        last = None

fails = []


def fail(sid, field, why):
    fails.append(f"PLAN FAIL: Step {sid}: {field}: {why}")


def files_of(val):
    out = []
    # annotations only: a parenthetical after whitespace or a closing backtick, never inside a path
    val = re.sub(r"(?:(?<=\s)|(?<=`))\([^)]*\)", "", val)
    for part in val.replace("\n", ",").split(","):
        p = part.strip().replace("`", "").strip()
        if p:
            out.append(p)
    return out


def parallel_of(val):
    v = re.sub(r"\([^)]*\)", "", val).strip()
    if v in ("", "none") or v[0] in "—–-":
        return []
    v = re.split(r"\s[—–-](?:\s|$)", v)[0]
    v = re.sub(r"\b(\d+)(?:–|-|\.\.)(\d+)\b",
              lambda m: " ".join(str(n) for n in range(int(m.group(1)), int(m.group(2)) + 1)), v)
    return re.findall(r"\bF?\d+\b", v)


def kinds_of(val):
    head = val.split("\n")[0]
    head = re.split(r"\s\(|\s—|\s–|\s-\s|;", head)[0]
    return [t.strip() for t in head.split(",") if t.strip()]


ids = [s[0] for s in steps]
fileset = {}
par = {}
counts = {"sonnet": 0, "opus": 0, "orchestrator": 0}

for sid, f in steps:
    for name in FIELDS:
        if name not in f:
            fail(sid, name, "missing")
    if "Files" in f:
        fl = files_of(f["Files"])
        fileset[sid] = set(fl)
        if not fl:
            fail(sid, "Files", "empty")
        for p in fl:
            if any(c in p for c in "*?") or ".." in p or p.endswith("/"):
                fail(sid, "Files", f"bad path '{p}' (no globs, '..' or directories)")
    typ = ""
    if "Type" in f:
        tm = re.match(r"\w+", f["Type"])
        typ = tm.group(0) if tm else ""
        if typ not in TYPES:
            fail(sid, "Type", f"'{f['Type']}' not in cmd|visual|judgment")
    risks = []
    if "Risk" in f:
        risks = kinds_of(f["Risk"])
        bad = [t for t in risks if t not in RISKS]
        if bad or not risks:
            fail(sid, "Risk", f"'{f['Risk']}' has token outside none|money|auth|data|security|prod")
    trigger = None
    if "Files" in f and any(not p.endswith(".md") for p in files_of(f["Files"])):
        for pat in TRIGGER_DOES:
            tm = pat.search(f.get("Does", ""))
            if tm:
                trigger = tm.group(0)
                break
        if trigger is None:
            trigger = next((p for p in files_of(f["Files"]) if TRIGGER_PATH.search(p)), None)
    if trigger is not None and "Risk" in f and "security" not in risks:
        fail(sid, "Risk", f"push/merge/deploy/delete/shell/hook step ('{trigger}') needs security")
    if "security" in risks:
        tf = f.get("Test first", "").lower()
        missing = [lb for lb in ABUSE_LABELS if lb not in tf]
        if missing:
            fail(sid, "Test first", "security step lacks abuse cases " + ", ".join(missing))
        else:
            hp = tf.find("happy:")
            if hp != -1 and any(tf.find(lb) > hp for lb in ABUSE_LABELS):
                fail(sid, "Test first", "abuse cases must come before happy:")
            else:
                empty = [lb for lb in ABUSE_LABELS if not abuse_case_filled(tf, lb)]
                if empty:
                    fail(sid, "Test first", "empty abuse case " + ", ".join(empty) + " (each needs a case or n/a — <why>)")
    if "Category" in f:
        cats = kinds_of(f["Category"])
        if not cats or any(c not in CATS for c in cats):
            fail(sid, "Category", f"'{f['Category']}' not in the category list")
    if "Parallel with" in f:
        par[sid] = parallel_of(f["Parallel with"])
        for x in par[sid]:
            if x not in ids:
                fail(sid, "Parallel with", f"step {x} does not exist")
    model = ""
    if "Model" in f:
        mm = re.match(r"\w+", f["Model"])
        model = mm.group(0) if mm else ""
        if model not in MODELS:
            fail(sid, "Model", f"'{model}' not in sonnet|opus|orchestrator")
        else:
            counts[model] += 1
            has_risk = "Risk" in f and any(t != "none" for t in risks)
            if typ in ("visual", "judgment") and model != "orchestrator":
                fail(sid, "Model", f"Type {typ} requires orchestrator")
            if model == "sonnet" and has_risk:
                fail(sid, "Model", "sonnet with Risk ≠ none")
            if model == "opus":
                cites = set(re.findall(r"\(([1-4])\)", f["Model"]))
                if not cites:
                    fail(sid, "Model", "opus must cite the failed condition (1)-(4)")
                elif has_risk and "4" not in cites:
                    fail(sid, "Model", "opus with Risk ≠ none must cite (4)")
                elif "Risk" in f and not has_risk and "4" in cites:
                    fail(sid, "Model", "opus with Risk none cannot cite (4)")
    if "Verify" in f and model in ("sonnet", "opus"):
        v = f["Verify"]
        if not re.search(r"`[^`]+`", v):
            fail(sid, "Verify", "no backticked command")
        outside = re.sub(r"`[^`]*`", " ", v)
        if "→" not in v and "->" not in v and not re.search(
                r"\b(exit|exits|prints|passes|pass|ends|green)\b", outside, re.I):
            fail(sid, "Verify", "no expected result (→, or exit/prints/passes/green)")

seen = set()
for sid, _ in steps:
    for x in par.get(sid, []):
        if x not in fileset or sid not in fileset:
            continue
        key = frozenset((sid, x))
        if key in seen or x == sid:
            continue
        seen.add(key)
        shared = sorted(fileset[sid] & fileset[x])
        for p in shared:
            fails.append(f"PLAN FAIL: Step {sid}: Parallel with: shares {p} with Step {x}")

numeric = [i for i in ids if i.isdigit()]
if len(numeric) > MAX_STEPS:
    fails.append(f"PLAN FAIL: plan: {len(numeric)} steps (max {MAX_STEPS} — {'SIZE: small; needs more → NOT SMALL' if SMALL else 'split the issue'})")
if not steps:
    fails.append("PLAN FAIL: plan: no steps")
if len(text) > MAX_CHARS:
    fails.append(f"PLAN FAIL: plan: {len(text)} characters (max {MAX_CHARS} — Current state excerpts become a signature plus a few lines; plan-template.md)")

if fails:
    print("\n".join(fails))
    sys.exit(1)
print(f"PLAN OK: {len(steps)} steps — sonnet {counts['sonnet']} · opus {counts['opus']} · orchestrator {counts['orchestrator']}")
PY

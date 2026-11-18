#!/usr/bin/env bash
# smoke-agents — prove each rumo typed agent runs on the model its frontmatter pins.
# Run after `claude` updates (frontmatter semantics can change) or after editing agents/.
# Usage: smoke-agents.sh [--plugin-dir <rumo checkout>]   (default: the installed plugin)
# Dispatches every rumo:* agent once with a trivial prompt in a throwaway dir, then reads the
# subagent transcripts' message.model. Exit 0 = all match · 1 = mismatch/missing · 2 = run failed.
set -uo pipefail
# --plugin-dir loads the checkout's skills, but the installed rumo@rumo's cached agents shadow its
# agents (disabling rumo@rumo disables both — same name). A NEW agent therefore reads "not found"
# until it is installed: verify it with a bare run after `claude plugin update rumo@rumo`.
extra=(); [ "${1:-}" = "--plugin-dir" ] && extra=(--plugin-dir "$2")
expect="scout=haiku extractor=haiku collector=haiku planner=opus builder=sonnet builder-opus=opus reviewer=opus reviewer-sonnet=sonnet visual-judge=opus"
dir=$(mktemp -d); cd "$dir" || exit 2
prompt="Dispatch these nine subagents in ONE message, in parallel, each with exactly the prompt 'Reply with the single word OK. Use no tools.' and no model parameter: rumo:scout, rumo:extractor, rumo:collector, rumo:planner, rumo:builder, rumo:builder-opus, rumo:reviewer, rumo:reviewer-sonnet, rumo:visual-judge. Then reply DONE."
json=$(claude -p ${extra[@]+"${extra[@]}"} --model haiku --output-format json "$prompt" 2>/dev/null) || { echo "smoke: claude -p failed"; exit 2; }
sid=$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("session_id",""))')
slug=$(printf '%s' "$(pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')
sub="$HOME/.claude/projects/$slug/$sid/subagents"
[ -d "$sub" ] || { echo "smoke: no subagent transcripts at $sub"; exit 2; }
python3 -I - "$sub" "$expect" <<'PY'
import glob, json, os, sys
sub, expect = sys.argv[1], dict(p.split('=') for p in sys.argv[2].split())
seen = {}
for meta in glob.glob(os.path.join(sub, '*.meta.json')):
    t = json.load(open(meta)).get('agentType', '')
    models = set()
    for line in open(meta.replace('.meta.json', '.jsonl')):
        try: m = (json.loads(line).get('message') or {}).get('model')
        except ValueError: continue
        if m: models.add(m)
    seen[t.replace('rumo:', '')] = models
fail = 0
for agent, fam in expect.items():
    got = seen.get(agent)
    ok = bool(got) and all(fam in m for m in got)
    fail |= not ok
    print(f"{'PASS' if ok else 'FAIL'} rumo:{agent:13} expect {fam:6} got {', '.join(sorted(got)) if got else 'not dispatched'}")
sys.exit(1 if fail else 0)
PY

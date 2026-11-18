#!/usr/bin/env bash
# build-size.sh - decide a build's lane from the issue alone, so the orchestrator stops judging it.
#
# Usage: build-size.sh <issue.json>
#   <issue.json> is the file saved from `gh issue view N --json title,body,comments,labels`.
#   Criteria = lines matching `^\s*- \[[ xX]\] \[(cmd|visual|judgment)\]` in the body and in
#   every comment body. Prints exactly one line:
#     SIZE normal — <reason>   a `risk:` label, a ## Risk/## Risco section that is not none/
#                              nenhum/nada…, more than 3 criteria, or zero criteria
#     SIZE visual — <n> criteria, all visual/judgment   no [cmd]: build inline, no planner
#     SIZE fast — <n> criteria, all cmd                 every criterion [cmd], at most 2:
#                                                       no planner, a one-step plan
#     SIZE small — <n> criteria                         planner with SIZE: small
#   An empty ## Risk section counts as no risk declared (not normal on its own).
#
# Exit codes: 0 a line printed; 2 usage error, missing file or invalid JSON (message on stderr).
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: build-size.sh <issue.json>" >&2; exit 2; }
exec python3 -I - "$1" <<'PY'
import json
import re
import sys

path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        issue = json.load(f)
except (OSError, ValueError) as e:
    sys.stderr.write('build-size: cannot read %s: %s\n' % (path, e))
    sys.exit(2)
if not isinstance(issue, dict):
    sys.stderr.write('build-size: %s is not a JSON object\n' % path)
    sys.exit(2)


def text(v):
    return v if isinstance(v, str) else ''


body = text(issue.get('body'))
bodies = [body] + [text(c.get('body')) for c in (issue.get('comments') or []) if isinstance(c, dict)]
labels = [text(l.get('name')) if isinstance(l, dict) else text(l) for l in (issue.get('labels') or [])]

CRIT = re.compile(r'^\s*- \[[ xX]\] \[(cmd|visual|judgment)\]')
kinds = []
for b in bodies:
    for ln in b.splitlines():
        m = CRIT.match(ln)
        if m:
            kinds.append(m.group(1))
n = len(kinds)

HEAD = re.compile(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$')
NONE = re.compile(r'^[\s*_>`-]*(?:(?:none|nenhum|nenhuma)[\s.*_`]*|nada\b.*)$', re.I)


def risk_section():
    """First non-empty line of the ## Risk / ## Risco section, or None when absent/empty."""
    inside = False
    for ln in body.splitlines():
        h = HEAD.match(ln)
        if h:
            if inside:
                return None
            inside = h.group(1).strip().lower() in ('risk', 'risco')
            continue
        if inside and ln.strip():
            return ln
    return None


reason = None
risk_labels = [l for l in labels if l.startswith('risk:')]
first = risk_section()
if risk_labels:
    reason = 'label %s' % risk_labels[0]
elif first is not None and not NONE.match(first):
    reason = 'Risk section declares a risk'
elif n > 3:
    reason = '%d criteria' % n
elif n == 0:
    reason = 'no criteria'

if reason:
    print('SIZE normal — %s' % reason)
elif 'cmd' not in kinds:
    print('SIZE visual — %d criteria, all visual/judgment' % n)
elif all(k == 'cmd' for k in kinds) and n <= 2:
    print('SIZE fast — %d criteria, all cmd' % n)
else:
    print('SIZE small — %d criteria' % n)
PY

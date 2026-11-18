#!/usr/bin/env bash
# Run: bash tests/lane_mem_test.sh — offline: ps, top and lsof are PATH stubs over a fixed process table. Exit 1 on any FAIL.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/lane-mem.py"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/wt/a" "$T/wt/ab" "$T/wt/idle"; export T
# 100 claude in wt/a (cwd) → 101 tsserver → 102 typings; 103 a shell in wt/a → 104 vitest
# 200 claude in wt/ab (prefix of nothing, must not count toward wt/a)
# 300 next-server reparented to launchd, naming wt/a in its argv
# 400 claude elsewhere; 500 unrelated
cat > "$T/bin/ps" <<'EOF'
#!/bin/bash
cat <<P
  100     1 300000 claude --dangerously-skip-permissions /rumo build #1
  101   100 900000 node /x/tsserver.js
  102   101  40000 node /x/typingsInstaller.js
  103   100   2000 /bin/zsh -c npm test
  104   103 200000 node $T/wt/a/node_modules/.bin/vitest run
  200     1 300000 /Users/v/.local/bin/claude --resume
  300     1 120000 next-server (v16) $T/wt/a/apps/web
  400     1 300000 claude
  500     1 999999 /usr/bin/something $T/wt/abc
  600     1 250000 node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume
  601     1 260000 /opt/homebrew/bin/node /opt/homebrew/bin/claude
P
EOF
# top reports footprints larger than RSS for 100 and 101 (compressed pages); 104 and 300 missing → ps RSS
cat > "$T/bin/top" <<'EOF'
#!/bin/bash
[ -n "${STUB_TOP_FAIL:-}" ] && exit 1
printf 'Processes: 9 total\nPhysMem: 15G used\n\nPID    MEM\n100    400M\n101    1.5G+\n102    40M\n103    2048K\n200    350M-\n400    300M\n500    1G\n'
EOF
cat > "$T/bin/lsof" <<'EOF'
#!/bin/bash
echo "lsof $*" >> "$T/lsof.calls"
printf 'p100\nfcwd\nn%s\np200\nfcwd\nn%s\np400\nfcwd\nn/elsewhere\np600\nfcwd\nn%s\np601\nfcwd\nn/elsewhere\n' "$T/wt/a" "$T/wt/ab" "$T/wt/idle"
EOF
chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"
out=$(python3 -I -c "$(cat "$S")" "$T/wt/a" "$T/wt/ab" "$T/wt/idle" "$T/nope" | paste -sd' ' -)
# wt/a: 400 + 1536 + 40 + 2 + 195.3 (104 rss) + 117.2 (300 rss) = 2290.5 → 2290 or 2291
ok "one line per path, in order; ab not swallowed by a; npm claude in idle counted; missing ?" '[[ "$out" =~ ^229[01]\ 350\ 244\ \?$ ]]'
ok "lsof asked only for claude pids, npm installs included" 'grep -qx "lsof -a -d cwd -p 100,200,400,600,601 -Fpn" "$T/lsof.calls"'
out=$(STUB_TOP_FAIL=1 python3 -I -c "$(cat "$S")" "$T/wt/a" | paste -sd' ' -)
# RSS only: 292.97 + 878.9 + 39.06 + 1.95 + 195.3 + 117.2 = 1525.4
ok "top fails → ps RSS" '[ "$out" = 1525 ]'
rm -f "$T/lsof.calls"
out=$(python3 -I -c "$(cat "$S")" "$T/nope")
ok "no live path → no process reads" '[ "$out" = "?" ] && [ ! -e "$T/lsof.calls" ]'
ok "ASCII only: it travels through printf %q to remote shells" 'python3 -I -c "import sys; open(sys.argv[1], \"rb\").read().decode(\"ascii\")" "$S"'
exit $fail

#!/usr/bin/env bash
# Install (or update) the rumo plugin from this checkout.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
claude plugin validate "$DIR"
claude plugin marketplace add "$DIR" 2>/dev/null || true
claude plugin install rumo@rumo --scope user
echo "rumo installed. A behavior change bumps .claude-plugin/plugin.json version only in the pre-merge base-merge commit (see CLAUDE.md), then claude plugin update rumo@rumo."

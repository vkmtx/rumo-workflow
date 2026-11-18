# shellcheck shell=bash
# host-lib.sh — sourced (never run): sync-host.sh and wave-host.sh use all of it; wave-status.sh and wave-lane-prep.sh REMOTE_SH_DEFAULT and remote_wrap.
# The one place for the default remote shell, the host PATH prefix, the bash -c wrapper and the Orca repo registration.
REMOTE_SH_DEFAULT='ssh -o BatchMode=yes -o ConnectTimeout=10'   # run as: $REMOTE_SH_DEFAULT <host> "<one argument>"
# Prepended on the host ($HOME and $PATH expand there), so Homebrew git/gh/claude are found.
REMOTE_PATH_PREFIX='PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '
# remote_wrap "<shell string>" — the single argument the host's login shell receives: bash -c <prefix+string>,
# quoted with printf %q, so the string runs under bash whatever the login shell is (zsh, fish, …).
remote_wrap() { printf 'bash -c %q' "$REMOTE_PATH_PREFIX$1"; }
# orca_repo_add <environment> <host path> — register a repo in a host's Orca; exit status is orca's.
orca_repo_add() { orca repo add --environment "$1" --path "$2" --json >/dev/null 2>&1; }

# shellcheck shell=bash
# FLEETCOM/paths.sh — repo locations + shared helpers, sourced by every script.
# Defaults put every repo under ~/Development; local.conf (written by
# fleetcom-onboard.sh's prompt, gitignored, per-machine) overrides them.
# Re-run `fleetcom-onboard.sh --reconfigure` or hand-edit local.conf — every
# repo has its own variable and may live anywhere.
CASCADE_DIR="${CASCADE_DIR:-$HOME/Development/cascade}"
AB_BACKEND_DIR="${AB_BACKEND_DIR:-$HOME/Development/auditboard-backend}"
AB_FRONTEND_DIR="${AB_FRONTEND_DIR:-$HOME/Development/auditboard-frontend}"
AB_DEVENV_DIR="${AB_DEVENV_DIR:-$HOME/Development/auditboard-dev-env}"

_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_paths_dir/local.conf" ] && . "$_paths_dir/local.conf"

# midship repos — per-repo variables like everything else. MIDSHIP_DIR is
# honored only as a legacy parent fallback from older local.conf files.
_midship_parent="${MIDSHIP_DIR:-$HOME/Development}"
MIDSHIP_TURBO_BROCCOLI_DIR="${MIDSHIP_TURBO_BROCCOLI_DIR:-$_midship_parent/midship-turbo-broccoli}"
MIDSHIP_FRONTEND_DIR="${MIDSHIP_FRONTEND_DIR:-$_midship_parent/midship-frontend}"
MIDSHIP_ONYX_DIR="${MIDSHIP_ONYX_DIR:-$_midship_parent/midship-onyx}"

# machine-learning is cloned by start-background inside the dev-env checkout
ML_DIR="$AB_DEVENV_DIR/machine-learning"

# ---- shared helpers ---------------------------------------------------------
# ensure_tmux [purpose]: make tmux available, or report that it isn't. Returns
# 0 when tmux is on PATH — offering to `brew install tmux` first if it's missing
# and we're on an interactive terminal. Returns non-zero when tmux is absent and
# the user declined, the install failed, Homebrew is unavailable, or there's no
# TTY to ask at; callers use that to fall back to the separate-Terminal-windows
# log view. FLEETCOM_NONINTERACTIVE forces the no-prompt (fall-back) path.
# Always safe to call in a conditional (`ensure_tmux || fallback`), which also
# suspends the caller's set -e for the function body.
ensure_tmux() {
	command -v tmux >/dev/null 2>&1 && return 0
	local purpose="${1:-the tmux log view}" reply
	[ -n "${FLEETCOM_NONINTERACTIVE:-}" ] && return 1
	[ -t 0 ] || return 1
	if ! command -v brew >/dev/null 2>&1; then
		printf '[fleetcom] tmux is not installed, and Homebrew is not available to install it — using separate windows.\n' >&2
		return 1
	fi
	printf '[fleetcom] tmux is not installed (needed for %s).\n' "$purpose" >&2
	read -r -p "[fleetcom] Install it now with 'brew install tmux'? [Y/n] " reply || return 1
	case "$reply" in [Nn]*) return 1 ;; esac
	printf '[fleetcom] installing tmux via Homebrew...\n' >&2
	if brew install tmux >&2 && command -v tmux >/dev/null 2>&1; then
		printf '[fleetcom] tmux installed.\n' >&2
		return 0
	fi
	printf '[fleetcom] tmux install did not complete — using separate windows.\n' >&2
	return 1
}

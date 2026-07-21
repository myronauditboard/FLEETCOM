# shellcheck shell=bash
# FLEETCOM/paths.sh — repo locations, sourced by every script.
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

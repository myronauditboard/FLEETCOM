# FLEETCOM/paths.sh — repo locations, sourced by every script.
# Defaults below are overridden by local.conf (written by fleetcom-onboard.sh's
# prompts, gitignored — per-machine). Re-run `fleetcom-onboard.sh --reconfigure`
# to change paths, or hand-edit local.conf: every repo has its own variable and
# may live anywhere.
#
# MIDSHIP_DIR is only the default PARENT for the midship-* repos (a prompt
# convenience) — the per-repo variables below win when set in local.conf.
MIDSHIP_DIR="${MIDSHIP_DIR:-$HOME/Development}"
CASCADE_DIR="${CASCADE_DIR:-$HOME/Development/cascade}"
AB_BACKEND_DIR="${AB_BACKEND_DIR:-$HOME/Development/auditboard-backend}"
AB_FRONTEND_DIR="${AB_FRONTEND_DIR:-$HOME/Development/auditboard-frontend}"
AB_DEVENV_DIR="${AB_DEVENV_DIR:-$HOME/Development/auditboard-dev-env}"

_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_paths_dir/local.conf" ] && . "$_paths_dir/local.conf"

# per-repo midship locations — derived from MIDSHIP_DIR unless local.conf sets them
MIDSHIP_TURBO_BROCCOLI_DIR="${MIDSHIP_TURBO_BROCCOLI_DIR:-$MIDSHIP_DIR/midship-turbo-broccoli}"
MIDSHIP_FRONTEND_DIR="${MIDSHIP_FRONTEND_DIR:-$MIDSHIP_DIR/midship-frontend}"
MIDSHIP_ONYX_DIR="${MIDSHIP_ONYX_DIR:-$MIDSHIP_DIR/midship-onyx}"

# machine-learning is cloned by start-background inside the dev-env checkout
ML_DIR="$AB_DEVENV_DIR/machine-learning"

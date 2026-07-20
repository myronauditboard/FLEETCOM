# FLEETCOM/paths.sh — repo locations, sourced by every script.
# Defaults below are overridden by local.conf (written by onboard.sh's prompts,
# gitignored — per-machine). Re-run `onboard.sh --reconfigure` to change paths.
# MIDSHIP_DIR is the PARENT dir of the midship-* repos. Default: the same
# ~/Development as everything else (all repos as siblings); point it elsewhere
# (e.g. ~/midship) if your machine keeps them separate.
MIDSHIP_DIR="${MIDSHIP_DIR:-$HOME/Development}"
CASCADE_DIR="${CASCADE_DIR:-$HOME/Development/cascade}"
AB_BACKEND_DIR="${AB_BACKEND_DIR:-$HOME/Development/auditboard-backend}"
AB_FRONTEND_DIR="${AB_FRONTEND_DIR:-$HOME/Development/auditboard-frontend}"
AB_DEVENV_DIR="${AB_DEVENV_DIR:-$HOME/Development/auditboard-dev-env}"

_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_paths_dir/local.conf" ] && . "$_paths_dir/local.conf"

# machine-learning is cloned by start-background inside the dev-env checkout
ML_DIR="$AB_DEVENV_DIR/machine-learning"

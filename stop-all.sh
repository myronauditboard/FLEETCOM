#!/bin/bash
# FLEETCOM: stop AuditBoard + Cascade. Midship is left running unless
# invoked with --midship.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"

say() { printf '\033[36m[stop-all]\033[0m %s\n' "$*"; }
kill_port() { # gracefully TERM whatever listens on a port
	local pids
	pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null) || return 0
	[ -n "$pids" ] && kill $pids 2>/dev/null && say "stopped port $1 (pid $pids)"
}

say "cascade"
kill_port 8088                                     # parcel client
(cd "$CASCADE" && docker-compose -f docker-compose.yml -f docker-compose-build.yml \
	-f docker-compose.override.yml down 2>/dev/null)

say "auditboard"
kill_port 9002; kill_port 9006                     # caddy + vite client
kill_port 9001; kill_port 9003                     # api v1/v2 (turbo children follow)
(cd "$DEVENV" && abc run stop-background)          # supplement services + ML
(cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" down conductor integrations-extract 2>/dev/null) || true
brew services stop postgresql@17 >/dev/null 2>&1
brew services stop redis >/dev/null 2>&1

if [ "${1:-}" = "--midship" ] && [ -d "$MIDSHIP_DIR/midship-turbo-broccoli" ]; then
	say "midship (requested via --midship)"
	kill_port 8000; kill_port 5173
	(cd "$MIDSHIP_DIR/midship-turbo-broccoli" && docker compose down)
fi

say "done"

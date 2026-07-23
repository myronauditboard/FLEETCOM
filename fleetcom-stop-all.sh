#!/bin/bash
# FLEETCOM: stop AuditBoard + Cascade. Midship is left running unless
# invoked with --midship.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"

say() { printf '\033[36m[stop-all]\033[0m %s\n' "$*"; }
kill_port() { # gracefully TERM whatever listens on a port — but NEVER Docker:
	# on macOS, docker-published ports are held by Docker Desktop's backend
	# process; signalling it disrupts networking for every container.
	local pids safe="" p
	pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null) || return 0
	for p in $pids; do
		case "$(ps -p "$p" -o comm= 2>/dev/null)" in
			*[Dd]ocker*) say "port $1 is docker-published — stop the container, not the proxy (skipping pid $p)" ;;
			*) safe="$safe $p" ;;
		esac
	done
	[ -n "${safe// /}" ] && kill $safe 2>/dev/null && say "stopped port $1 (pid$safe)"
}
stop_containers_named() { # docker stop by name filter, quiet when none match
	local ids
	ids=$(docker ps -q --filter "name=$1" 2>/dev/null)
	[ -n "$ids" ] && docker stop $ids >/dev/null && say "stopped $1 container(s)"
}

say "cascade"
kill_port 8088                                     # parcel client
(cd "$CASCADE" && docker-compose -f docker-compose.yml -f docker-compose-build.yml \
	-f docker-compose.override.yml down 2>/dev/null)

say "auditboard"
stop_containers_named caddy                        # caddy runs in docker — 9002 is a proxied port
kill_port 9006; kill_port 9005                     # client + login vite (9005 orphans otherwise)
kill_port 9001; kill_port 9003                     # api v1/v2 (turbo children follow)
(cd "$DEVENV" && abc run stop-background)          # supplement services (+ ML in theory)
# upstream bug: machine-learning's bin/ml-stop never cds into its repo, so its
# 'docker compose stop' silently no-ops — stop the ML project ourselves
[ -d "$ML_DIR" ] && (cd "$ML_DIR" && docker compose stop 2>/dev/null) && say "machine-learning stopped"
# 'stop', not 'down': down would also remove the shared project network once
# nothing is running, leaving every stopped container pinned to a dead network
# ID — the next start-background then dies with "network ... not found"
(cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" -f "$HERE/extract.override.yml" stop conductor integrations-extract 2>/dev/null) \
	|| (cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" stop conductor 2>/dev/null) || true
brew services stop postgresql@17 >/dev/null 2>&1
brew services stop redis >/dev/null 2>&1

if [ "${1:-}" = "--midship" ] && [ -d "$MIDSHIP_TURBO_BROCCOLI_DIR" ]; then
	say "midship (requested via --midship)"
	kill_port 8000; kill_port 5173
	(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && docker compose down)
	stop_containers_named hatchet-cli               # separate compose project; restarted by fleetcom-start-all.sh
fi

tmux kill-session -t fleetcom-ab-api 2>/dev/null && say "AB API tmux session closed" || true
# FLEETCOM_KEEP_LOGS: fleetcom-start-claude.sh runs the restart INSIDE the log
# session's claude pane, so it sets this to stop us from tearing that session
# down mid-restart. Normal `stop` leaves it unset and closes the log view.
if [ -n "${FLEETCOM_KEEP_LOGS:-}" ]; then
	say "keeping the log session (FLEETCOM_KEEP_LOGS set)"
else
	"$HERE/fleetcom-logs.sh" --kill   # kills the logs tmux session and requests close on any spawned Terminal windows (may need a per-window click to confirm)
fi

say "done"

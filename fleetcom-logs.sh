#!/bin/bash
# FLEETCOM: live backend logs in a tmux 2x2 grid.
#   fleetcom-logs.sh          open (or reattach to) the log panes
#   fleetcom-logs.sh --kill   tear the session down
# Panes: optro-api | midship-api / cascade (docker) | alerts (ERROR/WARN only).
# Auto-opened by fleetcom-start-all.sh (skip with --no-logs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
CASCADE_COMPOSE="docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml"

say() { printf '\033[36m[logs]\033[0m %s\n' "$*"; }

if ! command -v tmux >/dev/null; then
	say "tmux not installed — get it with: brew install tmux"
	say "manual log commands meanwhile:"
	say "  tail -F $LOGS/ab-api.log"
	say "  tail -F $LOGS/midship-api.log"
	say "  cd $CASCADE_DIR && $CASCADE_COMPOSE logs -f web ws c3 c3manager"
	exit 0
fi

if [ "${1:-}" = "--kill" ]; then
	if tmux kill-session -t "$SESSION" 2>/dev/null; then say "log session closed"; else say "no log session running"; fi
	exit 0
fi

# already running? just (re)attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
	if [ ! -t 0 ]; then say "session already running — attach with ./fleetcom-logs.sh"; exit 0; fi
	if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$SESSION"; else exec tmux attach -t "$SESSION"; fi
fi

mkdir -p "$LOGS"
touch "$LOGS/ab-api.log" "$LOGS/midship-api.log"

# tail -F (capital) survives start-all truncating the logs on restart
OPTRO_CMD="tail -n 80 -F '$LOGS/ab-api.log'"
MIDSHIP_CMD="tail -n 80 -F '$LOGS/midship-api.log'"
CASCADE_CMD="cd '$CASCADE_DIR' && $CASCADE_COMPOSE logs -f --tail 80 web ws c3 c3manager"
ALERTS_CMD="{ tail -n 0 -F '$LOGS/ab-api.log' '$LOGS/midship-api.log' & { cd '$CASCADE_DIR' && $CASCADE_COMPOSE logs -f --tail 0 web ws c3 c3manager 2>&1; } & wait; } | grep --line-buffered -iE '(errors?|warn(ing)?|fatal|exceptions?|traceback)[: ]'"

wrap() { printf '%s; echo; echo "[pane exited — press Enter to close]"; read -r _' "$1"; }

# capture stable pane IDs — splits renumber positional indexes, IDs never change
P_OPTRO=$(tmux new-session  -d -s "$SESSION" -n backends -P -F '#{pane_id}' "$(wrap "$OPTRO_CMD")")
P_MIDSHIP=$(tmux split-window -h -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$MIDSHIP_CMD")")
P_CASCADE=$(tmux split-window -v -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$CASCADE_CMD")")
P_ALERTS=$(tmux split-window  -v -t "$P_MIDSHIP" -P -F '#{pane_id}' "$(wrap "$ALERTS_CMD")")
tmux select-layout -t "$SESSION:backends" tiled

tmux select-pane -t "$P_OPTRO"   -T "optro-api"
tmux select-pane -t "$P_MIDSHIP" -T "midship-api"
tmux select-pane -t "$P_CASCADE" -T "cascade"
tmux select-pane -t "$P_ALERTS"  -T "alerts (ERROR/WARN)"
tmux set-option  -t "$SESSION" pane-border-status top
tmux set-option  -t "$SESSION" mouse on
tmux set-option  -t "$SESSION" status-right-length 60
tmux set-option  -t "$SESSION" status-right "Ctrl-b d = detach · fleetcom-logs.sh --kill = close"

if [ ! -t 0 ]; then
	say "log session created — attach with ./fleetcom-logs.sh"
	exit 0
fi
if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$SESSION"; else exec tmux attach -t "$SESSION"; fi

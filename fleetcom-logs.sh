#!/bin/bash
# FLEETCOM: live backend logs — tmux 2x2 grid OR four separate Terminal windows.
#   fleetcom-logs.sh             open (first run asks which view you prefer)
#   fleetcom-logs.sh --tmux      switch to the tmux grid (persisted)
#   fleetcom-logs.sh --windows   switch to separate Terminal windows (persisted)
#   fleetcom-logs.sh --kill      tear the tmux session down (windows: close them)
# Streams: optro-api | midship-api | cascade (docker) | alerts (ERROR/WARN only).
# Auto-opened by fleetcom-start-all.sh (skip with --no-logs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
CASCADE_COMPOSE="docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml"

say() { printf '\033[36m[logs]\033[0m %s\n' "$*"; }

save_mode() { # persist LOGS_VIEW in local.conf
	if grep -q "^LOGS_VIEW=" "$HERE/local.conf" 2>/dev/null; then
		sed -i '' "s|^LOGS_VIEW=.*|LOGS_VIEW=\"$1\"|" "$HERE/local.conf"
	else
		printf 'LOGS_VIEW="%s"\n' "$1" >> "$HERE/local.conf"
	fi
}

MODE="${LOGS_VIEW:-}"
case "${1:-}" in
	--tmux)    MODE=tmux;    save_mode tmux;    say "log view set to tmux (saved to local.conf)" ;;
	--windows) MODE=windows; save_mode windows; say "log view set to separate windows (saved to local.conf)" ;;
	--kill)
		if tmux kill-session -t "$SESSION" 2>/dev/null; then say "tmux log session closed"; else say "no tmux log session running"; fi
		say "(windows mode: close the Terminal windows themselves — each stops its tail on close)"
		exit 0
	;;
esac

# first run: ask which view the user prefers, remember the answer
if [ -z "$MODE" ]; then
	if [ -t 0 ]; then
		read -r -p "[logs] View backend logs in [t]mux panes (one window, 2x2 grid) or separate Terminal [w]indows? [T/w] " v || true
		case "${v:-}" in [Ww]*) MODE=windows ;; *) MODE=tmux ;; esac
		save_mode "$MODE"
		say "saved to local.conf — switch anytime: fleetcom-logs.sh --tmux | --windows"
	else
		MODE=tmux
	fi
fi

# tmux view without tmux installed -> fall back to windows
if [ "$MODE" = "tmux" ] && ! command -v tmux >/dev/null; then
	say "tmux not installed — using separate Terminal windows instead (brew install tmux for the 2x2 grid)"
	MODE=windows
fi

mkdir -p "$LOGS"
touch "$LOGS/ab-api.log" "$LOGS/midship-api.log"

# tail -F (capital) survives start-all truncating the logs on restart
OPTRO_CMD="tail -n 80 -F '$LOGS/ab-api.log'"
MIDSHIP_CMD="tail -n 80 -F '$LOGS/midship-api.log'"
CASCADE_CMD="cd '$CASCADE_DIR' && $CASCADE_COMPOSE logs -f --tail 80 web ws c3 c3manager"
ALERTS_CMD="{ tail -n 0 -F '$LOGS/ab-api.log' '$LOGS/midship-api.log' & { cd '$CASCADE_DIR' && $CASCADE_COMPOSE logs -f --tail 0 web ws c3 c3manager 2>&1; } & wait; } | grep --line-buffered -iE '(errors?|warn(ing)?|fatal|exceptions?|traceback)[: ]'"

wrap() { printf '%s; echo; echo "[exited — press Enter to close]"; read -r _' "$1"; }

# ---------------------------------------------------------------- windows ---
if [ "$MODE" = "windows" ]; then
	open_win() { # name, command
		local f="$LOGS/win-$1.command"
		{
			printf '#!/bin/bash\n'
			printf 'printf "\\033]0;%s\\007"\n' "$1"   # window title
			printf 'clear\n'
			printf '%s\n' "$(wrap "$2")"
		} > "$f"
		chmod +x "$f"
		open "$f"
	}
	open_win optro-api   "$OPTRO_CMD"
	open_win midship-api "$MIDSHIP_CMD"
	open_win cascade     "$CASCADE_CMD"
	open_win alerts      "$ALERTS_CMD"
	say "opened 4 Terminal windows (re-open any later from $LOGS/win-*.command; close a window to stop its tail)"
	exit 0
fi

# ------------------------------------------------------------------- tmux ---
# already running? just (re)attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
	if [ ! -t 0 ]; then say "session already running — attach with ./fleetcom-logs.sh"; exit 0; fi
	if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$SESSION"; else exec tmux attach -t "$SESSION"; fi
fi

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

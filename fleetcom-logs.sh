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

# Close any spawned Terminal.app windows: the tmux grid's outer window
# (titled "$SESSION") and/or the four separate-window titles. Killing the
# tmux session alone doesn't close the window that was attached to it
# (depends on Terminal's "when the shell exits" preference). Matches on the
# exact win-<name>.command filename Terminal shows for the running script,
# NOT the bare label — a bare label like "cascade" or "optro-api" can
# collide with an unrelated window/tab you've named that yourself. Terminal
# shows its own "still running — terminate?" confirmation per window when
# closed this way; you'll need to click through it for each one (confirmed
# acceptable — there's no way to auto-dismiss it without granting
# Accessibility/UI-scripting access, which this doesn't ask for). Skip
# entirely if Terminal.app isn't even running, so we don't launch it just to
# find nothing.
close_terminal_windows() {
	pgrep -xq Terminal || return 0
	local filter="" t
	for t in "$@"; do
		filter="${filter:+$filter or }name contains \"$t\""
	done
	osascript -e "
tell application \"Terminal\"
	set winList to every window whose ($filter)
	repeat with w in winList
		close w
	end repeat
end tell" >/dev/null 2>&1 || true
}

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
		close_terminal_windows "$SESSION" win-optro-api.command win-midship-api.command win-cascade.command win-alerts.command
		say "requested close on any spawned log windows (tmux grid or separate Terminal windows) — click 'Terminate'/'Close' on each if Terminal asks"
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

# Wrap a stream command so the pane/window stays usable instead of dying:
#  - cd into the stream's repo first, so you land somewhere you can work
#  - trap INT so Ctrl-C stops the stream and drops into an interactive shell
#    in that repo, rather than killing the pane (a non-interactive shell
#    aborts its whole command list when its foreground child dies on SIGINT,
#    which is why an un-trapped pane closes on Ctrl-C)
#  - after the stream ends (or Ctrl-C), exec the user's interactive shell in
#    the repo dir; type `exit` there to actually close the pane/window
# The exec reconnects std{in,out,err} to /dev/tty: a piped stream (alerts)
# otherwise leaves the shell's stdout pointing at the dead pipe, so its
# prompt hooks (vcs_info/direnv) spew "broken pipe". $SHELL is resolved at
# runtime inside the pane (the user's login shell).
wrap() { # cmd, workdir
	local dir="${2:-$HOME}"
	printf "cd '%s' 2>/dev/null || true; trap 'exec \"\${SHELL:-/bin/bash}\" </dev/tty >/dev/tty 2>&1' INT; %s; echo; echo '[stream ended — shell in %s; type exit to close]'; exec \"\${SHELL:-/bin/bash}\" </dev/tty >/dev/tty 2>&1" "$dir" "$1" "$dir"
}

# ---------------------------------------------------------------- windows ---
if [ "$MODE" = "windows" ]; then
	open_win() { # name, command, workdir
		local f="$LOGS/win-$1.command"
		{
			printf '#!/bin/bash\n'
			printf 'printf "\\033]0;%s\\007"\n' "$1"   # window title
			printf 'clear\n'
			printf '%s\n' "$(wrap "$2" "$3")"
		} > "$f"
		chmod +x "$f"
		open "$f"
	}
	open_win optro-api   "$OPTRO_CMD"   "$AB_BACKEND_DIR"
	open_win midship-api "$MIDSHIP_CMD" "$MIDSHIP_TURBO_BROCCOLI_DIR"
	open_win cascade     "$CASCADE_CMD" "$CASCADE_DIR"
	open_win alerts      "$ALERTS_CMD"  "$HERE"
	say "opened 4 Terminal windows (re-open any later from $LOGS/win-*.command; Ctrl-C drops to a shell in that repo, type exit to close)"
	exit 0
fi

# ------------------------------------------------------------------- tmux ---
# already running? just (re)attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
	if [ ! -t 0 ]; then say "session already running — attach with ./fleetcom-logs.sh"; exit 0; fi
	if [ -n "${TMUX:-}" ]; then
		exec tmux switch-client -t "$SESSION"
	else
		printf '\033]0;%s\007' "$SESSION"   # outer window title, so --kill/stop-all can find and close it
		exec tmux attach -t "$SESSION"
	fi
fi

# capture stable pane IDs — splits renumber positional indexes, IDs never change
P_OPTRO=$(tmux new-session  -d -s "$SESSION" -n backends -P -F '#{pane_id}' "$(wrap "$OPTRO_CMD"   "$AB_BACKEND_DIR")")
P_MIDSHIP=$(tmux split-window -h -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$MIDSHIP_CMD" "$MIDSHIP_TURBO_BROCCOLI_DIR")")
P_CASCADE=$(tmux split-window -v -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$CASCADE_CMD" "$CASCADE_DIR")")
P_ALERTS=$(tmux split-window  -v -t "$P_MIDSHIP" -P -F '#{pane_id}' "$(wrap "$ALERTS_CMD"  "$HERE")")
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

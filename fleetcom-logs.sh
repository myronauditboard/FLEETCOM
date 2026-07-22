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
# Capture an explicit env LOGS_VIEW BEFORE sourcing paths.sh — paths.sh sources
# local.conf, which assigns LOGS_VIEW and would otherwise clobber a caller's
# `LOGS_VIEW=tmux fleetcom-logs.sh` override (fleetcom-start-claude.sh relies on
# this to force tmux without persisting the choice to local.conf).
_ENV_LOGS_VIEW="${LOGS_VIEW:-}"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
CASCADE_COMPOSE="docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml"

say() { printf '\033[36m[logs]\033[0m %s\n' "$*"; }

# Close any spawned Terminal.app windows: the tmux grid's outer window
# (titled "$SESSION") and/or the four separate-window titles. Each arg is a
# window-name substring to match — the exact win-<name>.command filename
# Terminal shows for the running script, NOT the bare label ("cascade",
# "optro-api"), which could collide with an unrelated window/tab you named
# yourself.
#
# We show our OWN confirmation naming the windows first, because Terminal's
# own close sheet lists running *process* names ("tail", "grep"), never the
# window title — and its text can't be customized. After you confirm here,
# Terminal still shows that per-window sheet (unavoidable without granting
# Accessibility/UI-scripting access, which this doesn't ask for); this dialog
# just tells you up front which windows are in scope. Labels are derived from
# the match terms (which we control), not parsed from Terminal's generated
# window names (whose em-dash separators don't survive macOS sed reliably).
# Skip entirely if Terminal.app isn't running, or if none of the windows are
# actually open.
close_terminal_windows() {
	# FLEETCOM_NONINTERACTIVE: automated callers (e.g. fleetcom-start-claude.sh's
	# full restart) set this so we DON'T pop a blocking GUI dialog mid-flow. The
	# tmux session is already killed by the --kill path before this runs; skipping
	# here just leaves any Terminal windows for the user to close, rather than
	# hanging on a confirmation that no one is watching for.
	[ -n "${FLEETCOM_NONINTERACTIVE:-}" ] && return 0
	pgrep -xq Terminal || return 0
	local filter="" t label matched present=()
	for t in "$@"; do
		filter="${filter:+$filter or }name contains \"$t\""
		matched=$(osascript -e "tell application \"Terminal\" to get (count of (every window whose name contains \"$t\"))" 2>/dev/null)
		case "$matched" in ''|*[!0-9]*) matched=0 ;; esac
		if [ "$matched" -gt 0 ]; then
			label="${t#win-}"; label="${label%.command}"
			[ "$label" = "$SESSION" ] && label="log grid ($SESSION)"
			present+=("$label")
		fi
	done
	[ ${#present[@]} -eq 0 ] && return 0
	local list; printf -v list '%s, ' "${present[@]}"; list="${list%, }"
	local choice
	choice=$(osascript \
		-e 'tell application "Terminal"' \
		-e 'activate' \
		-e "set r to display dialog \"Close these FLEETCOM log windows: $list?\" & return & return & \"Terminal will then ask you to confirm terminating each window's processes — that system prompt lists process names, not the window title.\" buttons {\"Keep open\", \"Close them\"} default button \"Close them\" with title \"FLEETCOM stop-all\"" \
		-e 'return button returned of r' \
		-e 'end tell' 2>/dev/null)
	[ "$choice" = "Close them" ] || { say "left the log windows open ($list)"; return 0; }
	osascript -e "tell application \"Terminal\" to close (every window whose ($filter))" >/dev/null 2>&1 || true
}

save_mode() { # persist LOGS_VIEW in local.conf
	if grep -q "^LOGS_VIEW=" "$HERE/local.conf" 2>/dev/null; then
		sed -i '' "s|^LOGS_VIEW=.*|LOGS_VIEW=\"$1\"|" "$HERE/local.conf"
	else
		printf 'LOGS_VIEW="%s"\n' "$1" >> "$HERE/local.conf"
	fi
}

MODE="${_ENV_LOGS_VIEW:-${LOGS_VIEW:-}}"   # env override wins over local.conf's saved value
case "${1:-}" in
	--tmux)    MODE=tmux;    save_mode tmux;    say "log view set to tmux (saved to local.conf)" ;;
	--windows) MODE=windows; save_mode windows; say "log view set to separate windows (saved to local.conf)" ;;
	--kill)
		if tmux kill-session -t "$SESSION" 2>/dev/null; then say "tmux log session closed"; else say "no tmux log session running"; fi
		close_terminal_windows "$SESSION" win-optro-api.command win-midship-api.command win-cascade.command win-alerts.command
		say "log window teardown done — click 'Terminate'/'Close' on each Terminal prompt if asked"
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

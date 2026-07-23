#!/bin/bash
# FLEETCOM: full restart (fleetcom-stop-all.sh then fleetcom-start-all.sh),
# plus a large Claude Code pane added to the tmux 'backends' window, alongside
# (not hidden behind) the 4 log panes — Claude gets ~70% width, logs are
# squeezed into a strip on the right. Claude pulls logs on demand
# (tmux capture-pane) rather than tailing continuously.
#   fleetcom-start-claude.sh              stop + boot + add claude pane
#   fleetcom-start-claude.sh --midship    also stop/restart midship
#   fleetcom-start-claude.sh --no-restart  skip stop/start; just add the claude
#                                          pane to a running (or freshly built)
#                                          tmux log session
# Requires tmux and the claude CLI. This script always uses the tmux log view,
# regardless of the LOGS_VIEW saved in local.conf — it forces it via an env
# override (fleetcom-logs.sh honors an explicit LOGS_VIEW env over local.conf),
# and does NOT persist the choice.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
MAP="$LOGS/tmux-panes.md"

say() { printf '\033[36m[start-claude]\033[0m %s\n' "$*"; }

# Reorder the right-hand log column (top→bottom) after main-vertical. main-vertical
# stacks the non-main panes by internal order, which the earlier splits + swap
# leave in an arbitrary sequence; a selection sort with swap-pane (which
# physically moves a pane's position) puts them where we want, no re-layout
# needed. Titles are matched by prefix so "alerts (ERROR/WARN)" matches "alerts".
reorder_backends() { # window
	local win="$1" i want slot want_id
	local -a order=(doctor midship-api optro-api cascade alerts)
	for i in "${!order[@]}"; do
		want="${order[$i]}"
		slot=$(tmux list-panes -t "$win" -F '#{pane_top}|#{pane_id}|#{pane_title}' \
			| grep -v '|claude$' | sort -n -t'|' -k1,1 | awk -F'|' -v n="$i" 'NR==n+1{print $2}')
		want_id=$(tmux list-panes -t "$win" -F '#{pane_id}|#{pane_title}' \
			| awk -F'|' -v t="$want" 'index($2,t)==1{print $1; exit}')
		[ -n "$slot" ] && [ -n "$want_id" ] && [ "$slot" != "$want_id" ] && tmux swap-pane -s "$want_id" -t "$slot"
	done
}

command -v claude >/dev/null || { say "ERROR: claude CLI not found on PATH"; exit 1; }
command -v tmux   >/dev/null || { say "ERROR: tmux not found — this script requires the tmux log view (brew install tmux)"; exit 1; }

# Don't run from inside the log session we're about to tear down: the restart
# kills the 'fleetcom-logs' tmux session, which would pull the rug out from
# under this very script (dead pty -> writes fail under set -e). Run it from a
# separate terminal window instead. (This is cleaner than trapping SIGHUP and
# hoping subsequent output still lands somewhere.)
if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#S' 2>/dev/null)" = "$SESSION" ]; then
	say "ERROR: don't run this from inside the '$SESSION' tmux session — it gets torn down during the restart."
	say "       Detach (Ctrl-b d) or open a separate terminal window, then re-run."
	exit 1
fi

# --- arg parsing: --no-restart is ours; everything else forwards to stop/start
RESTART=1
FWD=()
for a in "$@"; do
	case "$a" in
		--no-restart) RESTART=0 ;;
		*) FWD+=("$a") ;;
	esac
done
FWD_STR=""
[ ${#FWD[@]} -gt 0 ] && FWD_STR=" ${FWD[*]}"

# Attach-first: build the tmux log session (+ claude pane) BEFORE the restart,
# then run the restart INSIDE the claude pane. The panes come up immediately and
# you watch the boot happen in them, instead of staring at a blank terminal
# while a slow (or wedged) start-all blocks — the old flow only attached after
# start-all returned, so a hung boot left you with no panes at all. On a restart
# we rebuild the session fresh; on --no-restart we reuse any existing one.
if [ "$RESTART" = 1 ]; then
	tmux kill-session -t "$SESSION" 2>/dev/null || true
fi
if tmux has-session -t "$SESSION" 2>/dev/null; then
	say "reusing existing tmux log session"
else
	say "building tmux log session"
	LOGS_VIEW=tmux "$HERE/fleetcom-logs.sh" < /dev/null
fi

# --- claude pane -----------------------------------------------------------
# Lives in the same window as the 4 log panes (not a separate window you have
# to switch to). main-vertical layout: pane index 0 is the big "main" pane on
# the left (claude, 70% width), the rest tile in a strip on the right.
WINDOW="$SESSION:backends"
# Detect an existing claude pane by its title, not by pane count — the log
# window's pane count varies (4 log streams + a doctor pane, and more could be
# added later), so a count threshold is brittle.
CLAUDE_PANE=$(tmux list-panes -t "$WINDOW" -F '#{pane_id}:#{pane_title}' 2>/dev/null | awk -F: '$2=="claude"{print $1; exit}')
CLAUDE_PANE_IS_NEW=false
if [ -z "$CLAUDE_PANE" ]; then
	say "adding claude pane -> $WINDOW"
	CLAUDE_PANE=$(tmux split-window -t "$WINDOW" -c "$HERE" -P -F '#{pane_id}')
	FIRST_PANE=$(tmux list-panes -t "$WINDOW" -F '#{pane_id}' | head -1)
	# swap-pane moves the pane_id (and its content) together, not content-in-place —
	# so CLAUDE_PANE still identifies the claude pane after this, unchanged.
	if [ "$CLAUDE_PANE" != "$FIRST_PANE" ]; then
		tmux swap-pane -s "$CLAUDE_PANE" -t "$FIRST_PANE"
	fi
	tmux select-pane -t "$CLAUDE_PANE" -T "claude"
	tmux set-window-option -t "$WINDOW" main-pane-width 70%
	tmux select-layout -t "$WINDOW" main-vertical
	reorder_backends "$WINDOW"   # right column top→bottom: doctor, midship, optro, cascade, alerts
	CLAUDE_PANE_IS_NEW=true
else
	say "claude pane already present — reusing it (not re-launching claude)"
fi

# --- pane map: what each tmux pane exposes, for claude to read on startup ---
{
	printf '# FLEETCOM tmux pane map (generated %s)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	printf 'Pull a pane snapshot on demand — do not tail continuously:\n'
	printf '  tmux capture-pane -p -t <pane_id> -S -   (full scrollback)\n'
	printf '  tmux capture-pane -p -t <pane_id>        (visible screen only)\n\n'
	printf '## session: %s, window: backends (shares this window with the claude pane)\n' "$SESSION"
	tmux list-panes -t "$WINDOW" -F '- #{pane_id}  #{pane_title}' 2>/dev/null | grep -v '  claude$' || true
	printf '\n'
	if tmux has-session -t fleetcom-ab-api 2>/dev/null; then
		printf '## session: fleetcom-ab-api\n'
		tmux list-panes -t fleetcom-ab-api -F '- #{pane_id}  AB API (migrations + api/worker/cron)' 2>/dev/null || true
		printf '\n'
	fi
	printf '## log files (read directly, no tmux needed)\n'
	printf -- '- %s/ab-api.log\n' "$LOGS"
	printf -- '- %s/midship-api.log\n' "$LOGS"
	printf -- '- %s/midship-frontend.log\n' "$LOGS"
	printf -- '- %s/ab-client.log\n' "$LOGS"
	printf -- '- %s/cascade-client.log\n' "$LOGS"
	printf '\n(cascade web/ws/c3/c3manager have no log file — read via the "cascade" pane above,\nor: docker compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml logs --tail 200 web)\n'
} > "$MAP"
say "pane map -> $MAP"

if [ "$CLAUDE_PANE_IS_NEW" = true ]; then
	CLAUDE_PROMPT="Read $MAP for the FLEETCOM tmux session/pane layout. Pull pane output on demand with tmux capture-pane -p -t <pane_id> instead of tailing continuously."
	# On a restart, run stop+start IN the claude pane first (visible, with the log
	# panes showing the boot), then launch Claude. FLEETCOM_KEEP_LOGS keeps the log
	# session we're attached to alive through stop-all (it would otherwise kill it).
	# ';' not '&&' so a non-zero stop still proceeds to start, matching old behavior.
	PANE_CMD=""
	if [ "$RESTART" = 1 ]; then
		PANE_CMD="FLEETCOM_KEEP_LOGS=1 '$HERE/fleetcom-stop-all.sh'$FWD_STR; '$HERE/fleetcom-start-all.sh' --no-logs$FWD_STR; "
	fi
	PANE_CMD="${PANE_CMD}cd '$HERE' && claude \"$CLAUDE_PROMPT\""
	tmux send-keys -t "$CLAUDE_PANE" "$PANE_CMD" C-m
fi

say "done — attaching now; the restart (if any) runs live in the claude pane. Reattach later: tmux attach -t $SESSION"
if [ -t 0 ]; then
	printf '\033]0;%s\007' "$SESSION"   # window title, so a later fleetcom-stop-all can find/close it
	if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$WINDOW"; else exec tmux attach -t "$WINDOW"; fi
fi

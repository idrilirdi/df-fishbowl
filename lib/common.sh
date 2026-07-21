# shellcheck shell=bash
# Backend-agnostic helpers for df_fishbowl.
# Sourced by bin/df_fishbowl after the config has been loaded, so it may
# rely on: DF_HOME LOG_FILE SESSION TERMINAL NEW_FORT_CHANCE SAVE_MAX_AGE_DAYS
#          FORTRESS_MODE SAVE_FLUSH_SECS STOP_TIMEOUT

log_msg() { printf '[df_fishbowl] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Save management
# ---------------------------------------------------------------------------

# Print the basename of a random existing save, or nothing to request a NEW
# fortress. A new fortress is requested with probability NEW_FORT_CHANCE% (and
# also whenever no existing save is available).
pick_save() {
	local exclude="${1:-}"   # anchored regex of save names NOT to pick (multi)
	local roll
	roll=$(shuf -i 1-100 -n1)
	if [ "$roll" -le "$NEW_FORT_CHANCE" ]; then
		log_msg "rolled $roll <= ${NEW_FORT_CHANCE}%: generating a NEW fortress"
		return 0
	fi
	local saves save
	saves=$(find "$DF_HOME/data/save" -mindepth 1 -maxdepth 1 -type d \
		! -name current -printf '%f\n' 2>/dev/null)
	[ -n "$exclude" ] && saves=$(printf '%s\n' "$saves" | grep -vxE "$exclude" || true)
	save=$(printf '%s\n' "$saves" | grep -v '^$' | shuf -n1)
	if [ -n "$save" ]; then
		log_msg "loading existing save: $save"
		printf '%s\n' "$save"
	else
		log_msg "no (unclaimed) save available: generating a NEW fortress"
	fi
}

# Delete saved fortresses older than SAVE_MAX_AGE_DAYS. `current` is preserved.
cleanup_saves() {
	local dir="$DF_HOME/data/save"
	[ -d "$dir" ] || return 0
	local old
	old=$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name current \
		-mtime +"$SAVE_MAX_AGE_DAYS" -printf '%f ' 2>/dev/null)
	if [ -n "$old" ]; then
		log_msg "cleaning up saves older than ${SAVE_MAX_AGE_DAYS}d: $old"
		find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name current \
			-mtime +"$SAVE_MAX_AGE_DAYS" -exec rm -rf {} + 2>/dev/null || true
	fi
}

# ---------------------------------------------------------------------------
# DF process lifecycle (tmux)
# ---------------------------------------------------------------------------

# tmux session name for a given output ("" => the shared/default session).
# single mode always uses $SESSION; multi mode uses a per-output session.
df_session_name() {
	if [ "$FORTRESS_MODE" = multi ] && [ -n "${1:-}" ]; then
		printf '%s_%s\n' "$SESSION" "$1"
	else
		printf '%s\n' "$SESSION"
	fi
}

df_session_running() { tmux has-session -t "$1" 2>/dev/null; }

# Start DF (if not already running) in a detached tmux session named $1.
# df-ai plays autonomously; a new fortress is launched with no +load-save so
# df-ai's random_embark takes over.
ensure_df_running() {
	local sess="$1"
	df_session_running "$sess" && return 0

	[ -x "$DF_HOME/dfhack" ] || {
		log_msg "ERROR: $DF_HOME/dfhack not found or not executable"
		return 1
	}

	cleanup_saves
	# $2 (if passed, even empty) is an explicit save: the caller has already
	# chosen it (multi mode, to keep each fortress distinct). Otherwise pick one
	# here (single mode). An empty save means "new fortress".
	local save load=""
	if [ "$#" -ge 2 ]; then save="$2"; else save="$(pick_save)"; fi
	[ -n "$save" ] && load="+load-save $save"

	log_msg "starting DF in tmux session '$sess' ${load:-(new fortress)}"
	# exec replaces the shell so the pane PID *is* the dfhack/DF process.
	tmux new-session -d -s "$sess" -x 250 -y 70 \
		"cd '$DF_HOME' && exec ./dfhack $load"
	# The mirrored fortress shares ONE tmux grid across screens. With foot the
	# render step pads every fortress terminal down to the smallest fortress
	# output's grid, so all fortress grids are near-identical; window-size=largest
	# then trims the ±1-cell rounding differences as invisible edge clipping
	# instead of leaving tmux dot bands (which =smallest produces, since the min
	# columns and min rows can come from different screens). For terminals that
	# can't pad, =largest fills the biggest and clips smaller ones, while
	# =smallest keeps small screens whole with filler dots on bigger ones.
	local wsize="${MIRROR_SIZE:-largest}"
	[ "$TERMINAL" = foot ] && wsize=largest
	tmux set-option -t "$sess" window-size "$wsize" >/dev/null 2>&1 || true
}

# Signal an entire process group (negative PID). DF reparents to init (PPID 1)
# but keeps the pane's process-group id, so a parent-tree walk misses it — a
# group signal does not.
_kill_group() {
	local sig="$1" pgid="$2"
	[ -n "$pgid" ] && kill -"$sig" -- "-$pgid" 2>/dev/null || true
}

# Are any DF processes from this session still alive? Checks the process group
# first, then falls back to the (relative) DF binary name.
_df_alive() {
	local pgid="$1"
	[ -n "$pgid" ] && pgrep -g "$pgid" >/dev/null 2>&1 && return 0
	pgrep -f 'libs/Dwarf_Fortress' >/dev/null 2>&1
}

# Gracefully stop DF: quicksave (preserve progress) -> SIGTERM -> wait -> SIGKILL.
# Called on every unlock so df-ai stops consuming CPU immediately.
stop_df_session() {
	local sess="$1"
	df_session_running "$sess" || return 0

	local ppid pgid=""
	ppid=$(tmux list-panes -t "$sess" -F '#{pane_pid}' 2>/dev/null | head -1)
	[ -n "$ppid" ] && pgid=$(ps -o pgid= -p "$ppid" 2>/dev/null | tr -d ' ')

	# 1. graceful save via DFHack's RPC client (works without the console).
	if [ -x "$DF_HOME/dfhack-run" ]; then
		log_msg "quicksaving session '$sess'"
		"$DF_HOME/dfhack-run" quicksave >/dev/null 2>&1 || true
		sleep "$SAVE_FLUSH_SECS"
	fi

	# 2. graceful quit: signal the whole process group.
	_kill_group TERM "$pgid"

	# 3. wait, then escalate to a strong kill.
	local waited=0
	while _df_alive "$pgid" && [ "$waited" -lt "$STOP_TIMEOUT" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if _df_alive "$pgid"; then
		log_msg "graceful quit timed out after ${STOP_TIMEOUT}s: hard-killing '$sess'"
		_kill_group KILL "$pgid"
	fi
	tmux kill-session -t "$sess" 2>/dev/null || true
}

# Stop every df_fishbowl DF session (shared + any per-output ones) and sweep
# stragglers. Backend-agnostic teardown.
stop_all_df() {
	local s
	for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null \
		| grep -E "^${SESSION}(_|$)" || true); do
		stop_df_session "$s"
	done
	# Final safety sweep by binary name (cmdline is the relative ./libs/... path,
	# so an absolute-path match would miss it).
	pkill -9 -f 'libs/Dwarf_Fortress' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Output classification (Wayland; X11 backend overrides this)
# ---------------------------------------------------------------------------

# Emit "NAME ROLE W H" per active output, applying the df_fishbowl role rules:
#   * a single output is ALWAYS the fortress (even if portrait);
#   * otherwise portrait outputs show the log, landscape ones the fortress;
#   * special case, LOG_ON_SMALLER_HORIZONTAL=1 (default): when there is no
#     portrait output but two or more landscape ones, the smallest landscape
#     shows the log and the rest show the fortress.
# Uses post-transform logical rects (portrait = height > width).
assign_roles() {
	swaymsg -t get_outputs 2>/dev/null | jq -r \
		--argjson smh "${LOG_ON_SMALLER_HORIZONTAL:-1}" '
		[ .[] | select(.active) | {name:.name, w:.rect.width, h:.rect.height} ] as $o
		| ($o | length) as $n
		| ($o | map(select(.w >= .h))) as $land
		| ($o | map(select(.w <  .h))) as $port
		| ( $land | min_by(.w * .h) | .name ) as $small_land
		| $o[]
		| ( if $n == 1 then "fortress"
		    elif .w < .h then "log"
		    elif ($smh == 1 and ($port | length) == 0
		          and ($land | length) >= 2 and .name == $small_land) then "log"
		    else "fortress" end ) as $role
		| "\(.name) \($role) \(.w) \(.h)"'
}

# Emit "NAME ROLE" per active output (used by the `classify` command).
classify_outputs() { assign_roles | awk '{print $1, $2}'; }

# Role (fortress|log) for a single output name. Defaults to fortress when the
# name is empty/unknown. Used by the per-output lock render.
output_role() {
	local name="$1" role=""
	[ -n "$name" ] && role="$(assign_roles | awk -v n="$name" '$1==n{print $2; exit}')"
	printf '%s\n' "${role:-fortress}"
}

# Size in (logical) pixels of the SMALLEST fortress output, as "WxH". This is the
# reference grid every mirrored fortress terminal renders, so the shared tmux
# session has one consistent size; larger fortress outputs pad around it (the
# render step computes the padding) to show it centered.
smallest_fortress_pixels() {
	assign_roles | awk '$2=="fortress"{a=$3*$4; if(m==""||a<m){m=a;w=$3;h=$4}}
		END{if(w!="")printf "%dx%d\n",w,h}'
}

# Size in (logical) pixels of a named output as "WxH", or empty if unknown.
output_pixels() {
	assign_roles | awk -v n="$1" '$1==n{printf "%dx%d\n",$3,$4; exit}'
}

# Build the full terminal argv for a role into the global array TERM_ARGV.
#   fortress -> attach (read-only) to the live tmux DF session
#   log      -> follow the df-ai narration log
# Terminals differ on how the child command is passed: foot/xterm/alacritty/
# urxvt/st accept "-e cmd args"; kitty takes the command directly.
build_term_argv() {
	local role="$1" sess="$2"
	local -a inner
	case "$role" in
	log) inner=(tail -n 200 -F "$LOG_FILE") ;;
	*) inner=(tmux attach -r -t "$sess") ;;
	esac
	case "$TERMINAL" in
	kitty) TERM_ARGV=("$TERMINAL" "${inner[@]}") ;;
	*) TERM_ARGV=("$TERMINAL" -e "${inner[@]}") ;;
	esac
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		log_msg "ERROR: required command '$1' not found in PATH"
		return 1
	}
}

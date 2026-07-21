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

# Align df-ai's embark settings with our load decision, in place in df-ai.json.
# df-ai's `random_embark` auto-embarks a NEW fort at startup, which OVERWRITES
# whatever save was loaded — so continuing an existing fortress requires it OFF
# (df-ai then just plays the loaded fort), and a genuinely new fortress requires
# it ON with an empty `random_embark_world` (generate a fresh world) rather than
# a fixed one (which would re-embark in the same world every time). df-ai.json
# has // comments so jq can't parse it; edit the two fields with sed.
#   configure_dfai continue [WORLD]   # play the loaded save, do not re-embark
#   configure_dfai new                # generate a new world and embark
configure_dfai() {
	local mode="$1" world="${2:-}" json="$DF_HOME/hack/df-ai.json"
	[ -f "$json" ] || return 0
	local embark ew
	if [ "$mode" = new ]; then embark=true; ew=""; else embark=false; ew="$world"; fi
	sed -i -E \
		-e "s/(\"random_embark\"[[:space:]]*:[[:space:]]*)(true|false)/\1${embark}/" \
		-e "s/(\"random_embark_world\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\1\"${ew}\"/" \
		"$json" 2>/dev/null || true
	log_msg "df-ai: random_embark=$embark random_embark_world=\"$ew\" ($mode)"
}

# Start DF (if not already running) in a detached tmux session named $1. df-ai
# plays autonomously; configure_dfai makes it continue a loaded save or embark a
# brand-new world, matching pick_save's choice.
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

	# Continue the chosen save (don't let df-ai re-embark over it), or generate a
	# fresh world when starting a new fortress.
	if [ -n "$save" ]; then configure_dfai continue "$save"; else configure_dfai new; fi

	log_msg "starting DF in tmux session '$sess' ${load:-(new fortress)}"
	# exec replaces the shell so the pane PID *is* the dfhack/DF process.
	tmux new-session -d -s "$sess" -x 250 -y 70 \
		"cd '$DF_HOME' && exec ./dfhack $load"
	# No status bar — this is a screensaver, so the fortress fills the terminal
	# with no tmux chrome.
	tmux set-option -t "$sess" status off >/dev/null 2>&1 || true
	# The mirrored fortress shares ONE tmux grid across screens. With foot the
	# render step pads every fortress terminal down to the smallest fortress
	# output's grid, so all fortress grids are near-identical (±1-2 cells, since
	# outputs can differ in scale). window-size=smallest makes the session the
	# SMALLEST of those grids: no screen is ever larger than the session, so
	# nothing is clipped/cut off — a screen whose grid is a touch bigger shows a
	# thin band of filler dots instead (added space, never lost content). Prefer
	# this over =largest, which fills the biggest grid but cuts off the others.
	tmux set-option -t "$sess" window-size "${MIRROR_SIZE:-smallest}" >/dev/null 2>&1 || true
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

# Emit "NAME ROLE W H" per active output, applying the fishbowl role rules:
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

# The largest (logical-pixel) rectangle that fits inside EVERY fortress output,
# as "WxH" — the per-axis minimum of their widths and heights. Every mirrored
# fortress terminal is padded/centered to this, so the shared tmux grid stays
# consistent even when outputs differ in aspect ratio: a per-axis minimum always
# fits inside each output, whereas the smallest-area output might be wider or
# taller than another and not fit.
fortress_ref_pixels() {
	assign_roles | awk '$2=="fortress"{
			if (w == "" || $3 < w) w = $3
			if (h == "" || $4 < h) h = $4
		} END { if (w != "") printf "%dx%d\n", w, h }'
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

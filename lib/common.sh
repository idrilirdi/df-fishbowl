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
		log_msg "rolled $roll <= ${NEW_FORT_CHANCE}%: generating a NEW world"
		return 0
	fi
	# A RESUMABLE fort is a regionN folder that contains a completed world.sav;
	# folders with only world.dat are un-started worlds df-ai can't continue (it
	# would embark fresh). Pick a resumable one at random to continue; if there is
	# none, generate a new world.
	local saves save
	saves=$(find "$DF_HOME/data/save" -mindepth 1 -maxdepth 1 -type d ! -name current \
		-exec test -f '{}/world.sav' ';' -printf '%f\n' 2>/dev/null)
	[ -n "$exclude" ] && saves=$(printf '%s\n' "$saves" | grep -vxE "$exclude" || true)
	save=$(printf '%s\n' "$saves" | grep -v '^$' | shuf -n1)
	if [ -n "$save" ]; then
		log_msg "continuing existing fort: $save"
		printf '%s\n' "$save"
	else
		log_msg "no resumable fort found: generating a NEW world"
	fi
}

# Prune saved fortresses: first by age (SAVE_MAX_AGE_DAYS), then by count
# (MAX_SAVES, keeping the most recently played). `current` is always preserved,
# as is the world df-ai is configured to play. A fort is ~20-60MB, so an
# unattended screensaver that rolls new worlds will otherwise fill the disk.
cleanup_saves() {
	local dir="$DF_HOME/data/save"
	[ -d "$dir" ] || return 0

	# Never prune while a fortress is live: DF holds the save dir open and
	# deleting under it can corrupt the world.
	if pgrep -f 'libs/Dwarf_Fortress' >/dev/null 2>&1; then
		log_msg "skipping save cleanup: DF is running"
		return 0
	fi

	# The world df-ai is pointed at must survive even if it is the oldest.
	local keep=""
	keep=$(sed -nE 's/.*"random_embark_world"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
		"$DF_HOME/dfhack-config/df-ai.json" 2>/dev/null | head -1)

	# --- by age ---
	local old
	old=$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name current \
		-mtime +"$SAVE_MAX_AGE_DAYS" -printf '%f ' 2>/dev/null)
	if [ -n "$old" ]; then
		local o
		for o in $old; do
			[ "$o" = "$keep" ] && continue
			log_msg "cleaning up save older than ${SAVE_MAX_AGE_DAYS}d: $o"
			rm -rf -- "$dir/$o" 2>/dev/null || true
		done
	fi

	# --- by count: keep the MAX_SAVES most recently played ---
	local max="${MAX_SAVES:-0}"
	case "$max" in '' | *[!0-9]*) return 0 ;; esac
	[ "$max" -le 0 ] && return 0

	local all n
	# newest first, so anything past the cap is the least recently played
	all=$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name current \
		-printf '%T@ %f\n' 2>/dev/null | sort -rn | awk '{print $2}')
	n=0
	local r
	for r in $all; do
		[ "$r" = "$keep" ] && continue
		n=$((n + 1))
		if [ "$n" -gt "$max" ]; then
			log_msg "pruning excess save (over MAX_SAVES=$max, least recently played): $r"
			rm -rf -- "$dir/$r" 2>/dev/null || true
		fi
	done
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

# --- Serialised start/stop --------------------------------------------------
# A start and a stop must never overlap. On unlock the lock shell tears DF down
# while swayidle's `resume` hook may run `df_fishbowl stop` and the next idle
# lock may already be starting DF: without a lock the new lock adopts a
# fortress that is about to be killed. Every start/stop runs under this lock
# (fd 8), so a start waits for an in-flight stop and then starts fresh.
_LIFECYCLE_LOCK="${XDG_RUNTIME_DIR:-/tmp}/df_fishbowl-lifecycle.lock"
with_lifecycle_lock() {
	if command -v flock >/dev/null 2>&1; then
		(
			# No `2>/dev/null` on a bare exec: it would redirect THIS shell's
			# stderr for good, swallowing every log_msg (and error) from the
			# start/stop below. That hid "dfhack not found" for a week (2026-11).
			{ exec 8>>"$_LIFECYCLE_LOCK"; } 2>/dev/null || exec 8>/dev/null
			flock -w "${LIFECYCLE_LOCK_WAIT:-120}" 8 \
				|| log_msg "WARNING: start/stop lock still busy after ${LIFECYCLE_LOCK_WAIT:-120}s — proceeding anyway"
			"$@"
		)
	else
		"$@"
	fi
}

# Call DFHack's RPC client with a hard time limit. dfhack-run blocks until DF's
# main loop services the request, so a frozen DF (stuck save, modal dialog,
# world-gen) would otherwise block the caller FOREVER — which is exactly how
# unlocks used to leave DF running: the stop never got past the quicksave.
# Returns 124 on timeout; any other dfhack-run status is ignored (as before).
_rpc() {
	[ -x "$DF_HOME/dfhack-run" ] || return 1
	local rc=0
	timeout -k 2 "${RPC_TIMEOUT:-10}" "$DF_HOME/dfhack-run" "$@" >/dev/null 2>&1 8>&- || rc=$?
	case "$rc" in 124 | 137) return 124 ;; esac
	return 0
}

# Align df-ai's embark settings with our load decision, in place in df-ai.json.
# df-ai's `random_embark` auto-embarks a NEW fort at startup, which OVERWRITES
# whatever save was loaded — so continuing an existing fortress requires it OFF
# (df-ai then just plays the loaded fort), and a genuinely new fortress requires
# it ON with an empty `random_embark_world` (generate a fresh world) rather than
# a fixed one (which would re-embark in the same world every time). df-ai.json
# has // comments so jq can't parse it; edit the two fields with sed.
#   configure_dfai continue [WORLD]   # play the loaded save, do not re-embark
#   configure_dfai new                # generate a new world and embark
# Point df-ai at the world to play. At the title screen df-ai chooses "Continue
# Game" when data/save/<random_embark_world>/world.sav exists (resume), else
# "Start Game"/"New World" (fresh). So $1 = a regionN to continue, or "" for a
# brand-new world. random_embark stays TRUE — it only controls auto-picking the
# embark tile for a new fort, NOT whether to continue. df-ai reads
# dfhack-config/df-ai.json (older layouts also keep hack/df-ai.json); write both.
configure_dfai() {
	local world="${1:-}"
	local json wrote=0
	for json in "$DF_HOME/dfhack-config/df-ai.json" "$DF_HOME/hack/df-ai.json"; do
		[ -f "$json" ] || continue
		sed -i -E \
			-e "s/(\"random_embark\"[[:space:]]*:[[:space:]]*)(true|false)/\1true/" \
			-e "s/(\"random_embark_world\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\1\"${world}\"/" \
			"$json" 2>/dev/null && wrote=$((wrote + 1))
	done
	log_msg "df-ai: random_embark_world=\"${world:-(new world)}\" ($wrote file[s])"
}

# Start DF (if not already running) in a detached tmux session named $1. df-ai
# plays autonomously; configure_dfai makes it continue a loaded save or embark a
# brand-new world, matching pick_save's choice.
ensure_df_running() { with_lifecycle_lock _ensure_df_running_locked "$@"; }
_ensure_df_running_locked() {
	local sess="$1"
	df_session_running "$sess" && return 0

	[ -x "$DF_HOME/dfhack" ] || {
		log_msg "ERROR: $DF_HOME/dfhack not found or not executable"
		return 1
	}

	cleanup_saves
	# Choose the world df-ai should play: a resumable regionN to continue, or ""
	# for a new world. In multi mode $2 pre-selects it (distinct per output).
	local world
	if [ "$#" -ge 2 ]; then world="$2"; else world="$(pick_save)"; fi
	configure_dfai "$world"

	log_msg "starting DF in tmux session '$sess' (${world:+continuing }${world:-new world})"
	# Launch PLAIN — NOT +load-save. df-ai (enabled via dfhack.init) drives the
	# title screen itself and picks Continue Game vs new world from
	# random_embark_world; loading a fort with +load-save lands df-ai in an
	# "unknown viewscreen" it can't play. exec makes the pane PID the DF process.
	tmux new-session -d -s "$sess" -x 250 -y 70 \
		"cd '$DF_HOME' && exec ./dfhack" 8>&-
	# No status bar — this is a screensaver, so the fortress fills the terminal
	# with no tmux chrome.
	tmux set-option -t "$sess" status off >/dev/null 2>&1 || true
	# The mirrored fortress shares ONE tmux grid across screens. The render step
	# equalises the grids (FORTRESS_FIT: scale the font per output, then pad the
	# remainder), so all fortress grids are near-identical (±1-2 cells from
	# integer cell rounding). window-size=smallest makes the session the
	# SMALLEST of those grids: no screen is ever larger than the session, so
	# nothing is clipped/cut off — a screen whose grid is a touch bigger shows a
	# thin band of filler dots instead (added space, never lost content). Prefer
	# this over =largest, which fills the biggest grid but cuts off the others.
	# Viewers MUST attach with `-f read-only`, never `-r`: `-r` also sets
	# ignore-size, and tmux skips ignore-size clients whenever any normal client
	# is attached anywhere on the server — the window then stays at a stale size,
	# pushed into the top-left corner with filler dots around it.
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

	# 1. graceful save via DFHack's RPC client. quicksave is ASYNCHRONOUS (it flags
	#    a save DF writes over subsequent frames) and does nothing while the game
	#    is paused, so: unpause, request the save, then WAIT until current/world.sav
	#    is actually rewritten and stops changing — never a blind sleep that could
	#    SIGTERM a large fort mid-write. Capped by SAVE_MAX_WAIT.
	if [ -x "$DF_HOME/dfhack-run" ]; then
		log_msg "quicksaving session '$sess'"
		# df-ai plays the region named by random_embark_world; the save is written
		# there (that's the resumable save the next launch continues). Watch its
		# world.sav — fall back to current if unknown.
		local rw
		rw=$(sed -nE 's/.*"random_embark_world"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
			"$DF_HOME/dfhack-config/df-ai.json" 2>/dev/null | head -1)
		local sav="$DF_HOME/data/save/${rw:-current}/world.sav"
		local before=0
		[ -f "$sav" ] && before=$(stat -c %Y "$sav" 2>/dev/null || echo 0)
		local rpc_ok=1
		_rpc lua 'df.global.pause_state=false' && _rpc quicksave || rpc_ok=0
		if [ "$rpc_ok" = 0 ]; then
			log_msg "WARNING: DF did not answer dfhack-run within ${RPC_TIMEOUT:-10}s (frozen?) — skipping the save, stopping anyway"
		fi
		local waited=0 now=0 last=-1 stable=0
		while [ "$rpc_ok" = 1 ] && [ "$waited" -lt "${SAVE_MAX_WAIT:-30}" ]; do
			sleep 1
			waited=$((waited + 1))
			now=$(stat -c %Y "$sav" 2>/dev/null || echo 0)
			# Once world.sav has been rewritten (mtime past pre-save), wait for it
			# to hold steady for 2 checks (= the write has finished).
			if [ "$now" -gt "$before" ]; then
				if [ "$now" = "$last" ]; then
					stable=$((stable + 1))
					[ "$stable" -ge 2 ] && break
				else
					stable=0
				fi
			fi
			last="$now"
		done
		if [ "$now" -gt "$before" ]; then
			log_msg "save written and settled after ${waited}s ($sav)"
		elif [ "$rpc_ok" = 1 ]; then
			log_msg "WARNING: $sav not updated in ${waited}s — save may not have happened (paused/stuck?)"
		fi
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
stop_all_df() { with_lifecycle_lock _stop_all_df_locked; }
_stop_all_df_locked() {
	local s
	for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null \
		| grep -E "^${SESSION}(_|$)" || true); do
		stop_df_session "$s"
	done
	# Final safety sweep by binary name (cmdline is the relative ./libs/... path,
	# so an absolute-path match would miss it).
	pkill -9 -f 'libs/Dwarf_Fortress' 2>/dev/null || true
	# ...and any dfhack-run client still waiting on a DF that no longer answers.
	pkill -9 -f 'hack/dfhack-run' 2>/dev/null || true

	# Janitor: reap orphaned lock renderers. swaylock-plugin does not reliably
	# kill its --command-each children when a lock ends abnormally, so `_render`
	# trees reparent to init and accumulate (observed: 45 across ~15 locks).
	# Only when NO locker is running — never touch a live lock's renderers.
	if ! pgrep -x swaylock-plugin >/dev/null 2>&1; then
		local rpid rpgid mypg
		mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
		for rpid in $(pgrep -f 'df_fishbowl _render' 2>/dev/null); do
			[ "$(awk '{print $4}' "/proc/$rpid/stat" 2>/dev/null)" = 1 ] || continue
			# The orphan's process group leader (the dead locker) is gone, so a
			# group signal cleans the whole render tree (terminal included).
			rpgid=$(ps -o pgid= -p "$rpid" 2>/dev/null | tr -d ' ')
			if [ -n "$rpgid" ] && [ "$rpgid" != 1 ] && [ "$rpgid" != "$mypg" ]; then
				kill -TERM -- "-$rpgid" 2>/dev/null || true
			else
				kill -TERM "$rpid" 2>/dev/null || true
			fi
		done
	fi
	return 0
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
# The pixel box every mirrored fortress output is fitted to (see FORTRESS_FIT).
# FORTRESS_REF picks which output defines the shared grid:
#   smallest - per-axis MIN over the fortress outputs: the largest box that fits
#              inside all of them. Bigger screens scale UP from it, so glyphs are
#              comfortable everywhere and the grid stays modest.
#   largest  - per-axis MAX: the grid is set by the biggest screen (which then
#              fills completely and shows the most map), and smaller screens
#              scale DOWN — their glyphs get small.
fortress_ref_pixels() {
	assign_roles | awk -v mode="${FORTRESS_REF:-largest}" '$2=="fortress"{
			if (mode == "largest") {
				if (w == "" || $3 > w) w = $3
				if (h == "" || $4 > h) h = $4
			} else {
				if (w == "" || $3 < w) w = $3
				if (h == "" || $4 < h) h = $4
			}
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
	*) inner=(tmux attach -f read-only -t "$sess") ;;
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

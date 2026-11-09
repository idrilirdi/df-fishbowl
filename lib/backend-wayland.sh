# shellcheck shell=bash
# Wayland / Sway backend for df_fishbowl.
#
# Secure locking with live content is provided by swaylock-plugin, an
# ext-session-lock-v1 client that composites a per-output background command.
# Its background command must be a wlr-layer-shell client, so each terminal is
# wrapped with `windowtolayer`, which can bind a specific output via
# --output-name. We use a single --command that fans out to one windowtolayer
# per output (swaylock-plugin does not tell --command-each which output it is).
#
# Requires: swaylock-plugin, windowtolayer, $TERMINAL (Wayland-native), tmux,
#           swaymsg, jq.

# Point swaymsg at a LIVE sway. We inherit our environment from whatever ran
# the lock hook; when that is a swayidle respawn loop that outlived a re-login,
# SWAYSOCK still names the previous session's socket (WAYLAND_DISPLAY is reused
# as "wayland-1", so swayidle itself keeps working). swaymsg then fails
# silently, assign_roles yields nothing, every output falls back to "fortress"
# and no grid fitting happens: the portrait screen showed a third, unscaled
# fortress (2026-10-29). Verify SWAYSOCK and, if dead, pick a live socket.
_wl_fix_swaysock() {
	local s
	if [ -n "${SWAYSOCK:-}" ] && swaymsg -s "$SWAYSOCK" -q -t get_version >/dev/null 2>&1; then
		return 0
	fi
	for s in $(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/sway-ipc.*.sock 2>/dev/null); do
		if swaymsg -s "$s" -q -t get_version >/dev/null 2>&1; then
			log_msg "SWAYSOCK '${SWAYSOCK:-}' is not a live sway; using $s"
			export SWAYSOCK="$s"
			return 0
		fi
	done
	log_msg "WARNING: no live sway IPC socket found; outputs cannot be classified"
	return 1
}
_wl_fix_swaysock || true

# Ensure the fortress process(es) are running before we lock, so the view is
# already live when the lock surfaces attach.
_wl_ensure_fortresses() {
	if [ "$FORTRESS_MODE" = multi ]; then
		# One DF per fortress output, each on a distinct save: accumulate the
		# saves already claimed this round and exclude them from the next pick so
		# two fortresses never open the same region (which would corrupt it).
		local name role sess save claimed=""
		while read -r name role; do
			[ "$role" = fortress ] || continue
			sess="$(df_session_name "$name")"
			df_session_running "$sess" && continue
			save="$(pick_save "$claimed")"
			[ -n "$save" ] && claimed="${claimed:+$claimed|}$save"
			ensure_df_running "$sess" "$save" || true
		done < <(classify_outputs)
		# Guarantee at least one session exists (feeds the log outputs too).
		tmux list-sessions -F '#{session_name}' 2>/dev/null \
			| grep -qE "^${SESSION}(_|$)" || ensure_df_running "$(df_session_name)" || true
	else
		ensure_df_running "$(df_session_name)" || true
	fi
}

backend_lock() {
	require_cmd swaylock-plugin || {
		log_msg "swaylock-plugin missing — run install.sh"
		return 1
	}
	require_cmd windowtolayer || {
		log_msg "windowtolayer missing — run install.sh"
		return 1
	}

	_wl_ensure_fortresses

	# Watchdog: while locked, revive DF if its tmux session dies (e.g. a DF
	# crash, or a stop fired by a stray idle-resume event such as
	# wake-from-suspend). _wl_ensure_fortresses is a cheap no-op while the
	# session is alive; the renderers' re-attach loop then picks DF back up.
	(
		while sleep 20; do
			_wl_ensure_fortresses >/dev/null 2>&1 || true
		done
	) &
	local watchdog=$!

	# GUARANTEED teardown: if this process is killed (wrapper restarts,
	# compositor crash, OOM of the shell — anything that skips the normal
	# post-unlock path), still reap the watchdog and stop DF. Without this,
	# a hard-killed lock chain leaves the watchdog resurrecting DF and/or DF
	# playing unattended for hours. Each signal logs which path fired.
	# Signals with a default-terminate action that nothing legitimate sends us
	# are ignored outright (PIPE/USR1/USR2) — an untrapped one would kill this
	# shell WITHOUT running the EXIT trap.
	# (every command here tolerates failure — the CLI runs under set -e, and an
	# errexit inside a trap aborts the teardown mid-way)
	trap '' PIPE USR1 USR2
	trap 'log_msg "teardown via EXIT trap"; kill "$watchdog" 2>/dev/null || true; stop_all_df' EXIT
	trap 'log_msg "teardown via SIGTERM"; kill "$watchdog" 2>/dev/null || true; stop_all_df; exit 143' TERM
	trap 'log_msg "teardown via SIGINT";  kill "$watchdog" 2>/dev/null || true; stop_all_df; exit 130' INT
	trap 'log_msg "teardown via SIGHUP";  kill "$watchdog" 2>/dev/null || true; stop_all_df; exit 129' HUP

	# swaylock-plugin runs in the foreground; it returns only once the session
	# is unlocked (correct password).
	log_msg "locking session (swaylock-plugin) [lock-shell pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ') watchdog=$watchdog]"
	# --command-each runs our renderer once per output, each with its own
	# nested-compositor connection already bound to that output.
	# Permit a core dump: if the locker ever segfaults again we want a
	# post-mortem (build is -O0 -g). Guaranteed capture also needs a
	# file-based kernel core_pattern; Ubuntu pipes to apport, which discards
	# cores from unpackaged binaries.
	ulimit -c unlimited 2>/dev/null || true

	local slp_rc=0
	swaylock-plugin \
		--command-each "$SELF _render" \
		"$@" || slp_rc=$?
	log_msg "swaylock-plugin returned rc=$slp_rc"

	# RECOVERY NET: rc >= 128 means the locker was killed by a signal, i.e. it
	# died WITHOUT releasing the ext-session-lock. The session therefore stays
	# locked with no client attached, which is exactly sway's red "lock failed"
	# screen — no password prompt, recoverable only from another TTY. Any
	# ext-session-lock client reclaims it, so hand over to plain swaylock: the
	# session stays securely locked but gets a working prompt back.
	if [ "$slp_rc" -ge 128 ]; then
		log_msg "LOCKER CRASHED (rc=$slp_rc, signal $((slp_rc - 128))) — session still locked with no client (sway red screen); handing over to plain swaylock"
		if command -v swaylock >/dev/null 2>&1; then
			swaylock -f -c 101010 >/dev/null 2>&1 \
				&& log_msg "fallback swaylock took over the lock" \
				|| log_msg "WARNING: fallback swaylock failed; recover from another TTY with: swaylock"
		else
			log_msg "WARNING: plain swaylock not installed; recover from another TTY"
		fi
	fi

	# Did we fail to lock because ANOTHER locker already holds the session
	# (swaylock-plugin rc!=0 + a live locker)? Then the session's DF belongs
	# to that locker — do NOT tear it down from this losing instance.
	if [ "$slp_rc" -ne 0 ] && pgrep -x swaylock-plugin >/dev/null 2>&1; then
		log_msg "another locker owns the session (rc=$slp_rc) — leaving DF alone"
		trap - EXIT TERM INT HUP
		kill "$watchdog" 2>/dev/null || true
		return 0
	fi

	# Unlocked: stop the watchdog first so it cannot resurrect DF mid-teardown,
	# then quicksave and tear DF down so df-ai stops using CPU. The EXIT trap
	# above covers abnormal exits; clear it so teardown runs exactly once.
	#
	# `|| true` on kill AND wait is LOAD-BEARING: under the CLI's set -e, the
	# TERM-killed watchdog makes `wait` return 143, which silently killed this
	# shell right here — one line after the trap was cleared — so teardown
	# never ran and DF strayed after every unlock. (The original stray-DF bug.)
	trap - EXIT TERM INT HUP
	kill "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	log_msg "unlocked — stopping DF"
	stop_all_df
}

# Exact shared grid for foot under FORTRESS_FIT=scale.
# Scaling a POINT size per screen cannot give every screen the same grid: the
# cell is the font's metrics rounded to whole pixels, and the rounding differs
# per size (unscii measured 9x10 px at 7pt and 14x15 px at 10.5pt, so the
# laptop drew 284 columns against the 4K's 274 and showed a filler band).
# foot can pin the cell instead: `font=F:pixelsize=W` sets a square font's
# advance to exactly W px (independent of DPI and dpi-aware) and
# `line-height=Wpx` the row height, so every cell is W x W and the grid is a
# plain integer division. The reference screen picks the grid from the base
# size; every other screen takes the largest W that still fits that grid and
# pads the remainder to centre it. Exact at integer output scale.
# The base size only sets a TARGET cell: the grid it implies may divide the
# other screens badly (a 14px 4K grid of 274x154 forced 9px cells on a
# 2560x1600 laptop with a 47x107 border; 15px gives 256x144, which is exactly
# 10px cells there and only the 16:9-vs-16:10 band remains). So nearby cell
# sizes (+-20%, at least +-2px) are tried and the one wasting the least screen
# area summed over all fortress outputs wins; ties go to the size nearest the
# target.
#   $1 reference WxH  $2 smallest fortress WxH  $3 this output WxH
#   $4 base point size on the smallest screen (FORTRESS_BASE_FONT_SIZE)
#   $5 every fortress output as "WxH WxH ..." (space separated)
# Prints "W px py cols rows".
_wl_exact_fit() {
	awk -v ref="$1" -v sm="$2" -v this="$3" -v base="$4" -v all="$5" 'BEGIN{
		split(ref, r, "x"); split(sm, s, "x"); split(this, o, "x")
		if (r[1] <= 0 || r[2] <= 0 || o[1] <= 0 || o[2] <= 0) exit 1
		n = split(all, a, " ")
		# pt -> px at 96 dpi, the size the smallest screen renders at
		wmin = int(base * 96 / 72 + 0.5); if (wmin < 1) wmin = 1
		kx = s[1] / r[1]; ky = s[2] / r[2]; kmin = (kx < ky ? kx : ky)
		if (kmin <= 0) kmin = 1
		wref = int(wmin / kmin + 0.5); if (wref < 1) wref = 1
		# Try reference cells near the target; keep the least wasted area.
		span = int(wref * 0.2 + 0.5); if (span < 2) span = 2
		lo = wref - span; if (lo < 1) lo = 1
		best = -1
		for (c = lo; c <= wref + span; c++) {
			cols = int(r[1] / c); rows = int(r[2] / c)
			if (cols < 1 || rows < 1) continue
			waste = 0
			for (i = 1; i <= n; i++) {
				split(a[i], q, "x")
				if (q[1] <= 0 || q[2] <= 0) continue
				w = int(q[1] / cols); wy = int(q[2] / rows); if (wy < w) w = wy
				if (w < 1) { waste = 1e9; break }
				waste += 1 - (cols * rows * w * w) / (q[1] * q[2])
			}
			d = (c > wref ? c - wref : wref - c)
			if (best < 0 || waste < bestw - 1e-9 || (waste < bestw + 1e-9 && d < bestd)) {
				best = c; bestw = waste; bestd = d
			}
		}
		if (best < 0) best = wref
		cols = int(r[1] / best); rows = int(r[2] / best)
		if (cols < 1) cols = 1; if (rows < 1) rows = 1
		w = int(o[1] / cols); wy = int(o[2] / rows); if (wy < w) w = wy
		if (w < 1) w = 1
		px = int((o[1] - cols * w) / 2); py = int((o[2] - rows * w) / 2)
		if (px < 0) px = 0; if (py < 0) py = 0
		printf "%d %d %d %d %d", w, px, py, cols, rows }'
}

# Runs as swaylock-plugin's --command-each child: one nested-compositor
# connection (WAYLAND_SOCKET fd) already bound to a single output.
#
# SAFETY CONTRACT: this function must NEVER exit uncleanly while locked. If DF,
# foot, or windowtolayer dies, we fall through to a long sleep so the process
# stays alive — swaylock-plugin then keeps its background client and, crucially,
# remains a working locker (password prompt) instead of collapsing. A dead
# fortress must never take down the lock. swaylock-plugin kills this process on
# unlock.
backend_render() {
	# Tolerate any shell error/unset var — never let a scripting slip kill the lock.
	set +e +u

	local rlog="${DF_RENDER_LOG:-$HOME/.cache/df_fishbowl-render.log}"
	mkdir -p "$(dirname "$rlog")" 2>/dev/null
	{
		echo "==== _render(each) $(date '+%F %T') pid=$$ ===="
		env | sort | grep -iE 'wayland|output|swaylock|swaysock|display|geometry'
	} >>"$rlog" 2>&1

	# swaylock-plugin --command-each sets SWAYLOCK_PLUGIN_OUTPUT_NAME per output,
	# so each instance knows which output it is drawing and can pick its role:
	# fortress on landscape outputs, the df-ai log on portrait (rotated) ones.
	local out="${SWAYLOCK_PLUGIN_OUTPUT_NAME:-}"
	local role; role="$(output_role "$out")"
	local sess; sess="$(df_session_name "$out")"
	echo ">> output=$out role=$role session=$sess" >>"$rlog"

	# The inner command is kept alive on failure so the terminal (and thus the
	# layer surface) persists rather than tearing the background down.
	local inner
	if [ "$role" = log ]; then
		# tail -F retries a missing/rotated file, so it never exits on its own.
		inner="printf '\n  df-ai log\n'; exec tail -n 200 -F \"$LOG_FILE\""
	else
		# Re-attach loop: if the DF tmux session dies (crash, or a stray stop)
		# while locked, keep retrying — the lock-side watchdog in backend_lock
		# revives DF, and this picks the new session up instead of tombstoning
		# on tmux's '[exited]' message. Never exits WHILE LOCKED (safety
		# contract) — but does exit once no locker is running, so an abnormal
		# lock teardown can't leave orphaned renderers idling forever.
		# Draw SOMETHING immediately: swaylock-plugin gives each plugin client a
		# deadline to commit its first frame ("Client failed to redraw output NN
		# in time; falling back to a client-less mode"), and DF+tmux can take
		# seconds to produce output. An instant banner commits a frame right
		# away, keeping the locker out of its fallback path — which is where a
		# 1-in-37 segfault was observed on the 1.8.7 subsurface build.
		inner="printf '\n  Dwarf Fortress fishbowl - attaching...\n'; while :; do pgrep -x swaylock-plugin >/dev/null 2>&1 || { sleep 3; pgrep -x swaylock-plugin >/dev/null 2>&1 || exit 0; }; tmux attach -f read-only -t ${sess} 2>/dev/null; printf '\n  Dwarf Fortress screensaver - waiting for DF...\n'; sleep 5; done"
	fi

	# Build the terminal argv and windowtolayer flags. Terminals fill their
	# output under the lock (a requested -w/-W size is ignored, so we always
	# --maximize), and the exec flag differs: kitty/havoc take the program
	# directly; foot/xterm/alacritty/urxvt use -e.
	local -a term wtl=(--maximized) footopts=()

	# A mirrored fortress (FORTRESS_MODE=single) shares ONE tmux session, so every
	# fortress output must end up with the SAME character grid — tmux sizes the
	# session to the smallest attached client, and whatever a bigger client has
	# beyond that is filler. FORTRESS_FIT decides how we equalise the grids:
	#
	#   scale (default) - SCALE then PAD. First scale the font by the largest
	#       factor that still fits (k = min of the axis ratios), so a screen with
	#       1.6x the reference's pixels renders the same grid with 1.6x bigger
	#       cells: the fortress fills the screen and glyphs stay square (nothing
	#       is stretched, unlike a surface-level stretch). Whatever is left over
	#       on the axis where the aspect ratios differ is then padded away, so the
	#       grid is CENTRED instead of anchored top-left. The residual pad is
	#       small (a few hundred px at most), which also keeps it inside
	#       alacritty's u8 padding limit.
	#   pad - no font scaling: inset each terminal's grid straight to the
	#       reference pixel box and centre it. Exact, but the extra area of a
	#       bigger screen is wasted as a border (a 3840x2160 next to a 2133x1333
	#       loses ~70% of its area), and the large pads exceed alacritty's u8
	#       limit, so it is foot-only in practice.
	#
	# The reference is fortress_ref_pixels: a per-axis min over the fortress
	# outputs, i.e. the largest box that fits inside all of them. The log output
	# is never scaled or padded — prose should fill its screen.
	local fit="${FORTRESS_FIT:-scale}"
	local fontscale="" px=0 py=0 dopad=0
	local cellpx="" gcols="" grows=""
	local ref="" this="" rw="" rh="" ow="" oh=""
	if [ "$role" != log ] && [ "$FORTRESS_MODE" != multi ]; then
		ref="$(fortress_ref_pixels)"
		this="$(output_pixels "$out")"
		if [ -n "$ref" ] && [ -n "$this" ]; then
			rw="${ref%x*}"; rh="${ref#*x}"; ow="${this%x*}"; oh="${this#*x}"
			case "$fit" in
			scale)
				if [ "$TERMINAL" = foot ] && [ -n "$FORTRESS_FONT" ]; then
					# foot pins the cell to W x W px, so the grid is exact on
					# every screen (see _wl_exact_fit). fontscale stays empty:
					# the point-size path below is for the other terminals.
					local smallest base allfort
					smallest="$(FORTRESS_REF=smallest fortress_ref_pixels)"
					base="${FORTRESS_FONT_SIZE:-${FORTRESS_BASE_FONT_SIZE:-12}}"
					allfort="$(assign_roles | awk '$2=="fortress"{printf "%s%dx%d", (n++?" ":""), $3, $4}')"
					read -r cellpx px py gcols grows < <(_wl_exact_fit "$ref" "$smallest" "$this" "$base" "$allfort")
					if [ -n "$cellpx" ]; then
						dopad=1
						echo ">> fitting fortress: ${cellpx}px cells, grid ${gcols}x${grows}, pad ${px}x${py} (ref=$ref smallest=$smallest out=$this base=${base}pt)" >>"$rlog"
					fi
				fi
				if [ -z "$cellpx" ]; then
					# k = largest factor that keeps rw x rh inside ow x oh; the residual
					# is what the scaled reference box leaves on the looser axis.
					# k may be <1 when FORTRESS_REF=largest (the grid is set by the
					# biggest screen and smaller ones scale DOWN), so it is NOT clamped
					# to >=1; only floored to keep the font from collapsing to nothing.
					read -r fontscale px py < <(awk -v ow="$ow" -v oh="$oh" -v rw="$rw" -v rh="$rh" 'BEGIN{
						kx=ow/rw; ky=oh/rh; k=(kx<ky?kx:ky); if(k<0.1)k=0.1
						px=int((ow-rw*k)/2); py=int((oh-rh*k)/2)
						if(px<0)px=0; if(py<0)py=0
						printf "%.2f %d %d", k, px, py }')
					dopad=1
					echo ">> fitting fortress: font x$fontscale + pad ${px}x${py} (ref=$ref out=$this)" >>"$rlog"
				fi
				;;
			pad)
				px=$(((ow - rw) / 2)); py=$(((oh - rh) / 2))
				[ "$px" -lt 0 ] && px=0
				[ "$py" -lt 0 ] && py=0
				dopad=1
				echo ">> fitting fortress: pad-only ${px}x${py} (ref=$ref out=$this)" >>"$rlog"
				;;
			esac
		fi
	fi

	# Apply the centring pad (shared by both fit modes).
	if [ "$dopad" = 1 ] && { [ "$px" -gt 0 ] || [ "$py" -gt 0 ]; }; then
		case "$TERMINAL" in
		foot) footopts=(-o "pad=${px}x${py} center") ;;
		alacritty)
			# window.padding.{x,y} is a u8: >255 is a CONFIG ERROR (red banner
			# in-window and the padding is dropped entirely, so nothing centres).
			# dynamic_padding spreads leftover sub-cell pixels evenly, alacritty's
			# equivalent of foot's `center`.
			local apx=$px apy=$py
			[ "$apx" -gt 255 ] && apx=255
			[ "$apy" -gt 255 ] && apy=255
			if [ "$apx" != "$px" ] || [ "$apy" != "$py" ]; then
				echo ">> WARNING: alacritty pad clamped ${px}x${py} -> ${apx}x${apy} (u8 limit); not fully centred — FORTRESS_FIT=scale keeps the pad small, or use foot" >>"$rlog"
			fi
			footopts=(
				-o "window.padding.x=$apx"
				-o "window.padding.y=$apy"
				-o "window.dynamic_padding=true"
			)
			;;
		esac
	fi

	# Per-invocation font for the FORTRESS terminal only (never the user's global
	# config, and not the log — prose reads better in a normal font). A square
	# font (e.g. unscii) renders DF's CP437 map with correct proportions; a normal
	# 1:2 monospace looks vertically stretched. foot/kitty take it as -o; other
	# terminals are left alone. Missing glyphs fall back to the system default.
	local -a fontopts=()
	# FORTRESS_FIT=scale needs an explicit base size to scale FROM (the terminal's
	# own default is unknown to us), so fall back to FORTRESS_BASE_FONT_SIZE. The
	# reference output gets the base size unchanged (fontscale=1.00).
	local fsize="$FORTRESS_FONT_SIZE"
	if [ -n "$fontscale" ]; then
		local base="${FORTRESS_FONT_SIZE:-${FORTRESS_BASE_FONT_SIZE:-12}}"
		# The base size is defined on the SMALLEST fortress output, NOT on the
		# reference: that way flipping FORTRESS_REF changes only which screen
		# fills exactly (and the grid's aspect), not how big the glyphs are.
		# With FORTRESS_REF=largest the reference box is bigger than the
		# smallest screen, so the reference's own size is scaled up by 1/kmin
		# first — otherwise the small screen would collapse to a few points.
		local smallest kmin
		smallest="$(FORTRESS_REF=smallest fortress_ref_pixels)"
		kmin=$(awk -v sm="$smallest" -v rw="$rw" -v rh="$rh" 'BEGIN{
			split(sm, a, "x"); if (rw+0<=0 || rh+0<=0) { print 1; exit }
			kx=a[1]/rw; ky=a[2]/rh; k=(kx<ky?kx:ky); if(k<=0)k=1; printf "%.4f", k }')
		fsize=$(awk -v b="$base" -v k="$fontscale" -v kmin="$kmin" \
			'BEGIN{ printf "%.1f", b*k/kmin }')
		echo ">> fortress font size: $fsize (base $base on smallest, x$fontscale, kmin=$kmin)" >>"$rlog"
	fi
	if [ "$role" != log ] && [ -n "$FORTRESS_FONT" ]; then
		case "$TERMINAL" in
		foot)
			if [ -n "$cellpx" ]; then
				# Exact square cell: pixelsize fixes the advance, line-height the row.
				fontopts=(-o "font=${FORTRESS_FONT}:pixelsize=$cellpx" -o "line-height=${cellpx}px")
			else
				fontopts=(-o "font=${FORTRESS_FONT}${fsize:+:size=$fsize}")
			fi
			;;
		kitty)
			fontopts=(-o "font_family=$FORTRESS_FONT")
			[ -n "$fsize" ] && fontopts+=(-o "font_size=$fsize")
			;;
		alacritty)
			# Dotted config keys (alacritty 0.12 YAML / 0.13+ TOML both accept
			# these); the bold/italic faces follow the normal family by default.
			fontopts=(-o "font.normal.family=$FORTRESS_FONT")
			[ -n "$fsize" ] && fontopts+=(-o "font.size=$fsize")
			;;
		esac
	fi

	case "$TERMINAL" in
	havoc) term=("$TERMINAL" sh -c "$inner") ;;
	kitty) term=("$TERMINAL" "${fontopts[@]}" sh -c "$inner") ;;
	foot | alacritty) term=("$TERMINAL" "${footopts[@]}" "${fontopts[@]}" -e sh -c "$inner") ;;
	*) term=("$TERMINAL" -e sh -c "$inner") ;;
	esac

	if command -v windowtolayer >/dev/null 2>&1 && command -v "$TERMINAL" >/dev/null 2>&1; then
		echo ">> windowtolayer ${wtl[*]} -- ${term[*]}" >>"$rlog"
		# `--` stops windowtolayer parsing the terminal's own flags (e.g. -e).
		windowtolayer "${wtl[@]}" -- "${term[@]}" >>"$rlog" 2>&1
		echo ">> windowtolayer exited (rc=$?); holding instance alive" >>"$rlog"
	else
		echo ">> windowtolayer or \$TERMINAL missing; holding instance alive" >>"$rlog"
	fi

	# Whatever happened above, do not let the --command-each instance exit while
	# the session is locked. swaylock-plugin does NOT reap --command-each
	# children on unlock, so a bare `sleep infinity` here leaks one orphan per
	# output per unlock (observed: dozens, each pinning inherited fds such as
	# the idle daemon's single-instance flock). Instead, find the locker in our
	# ancestry and stay alive exactly as long as it does.
	local anc=$PPID lockerpid=""
	while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
		if [ "$(cat /proc/$anc/comm 2>/dev/null)" = swaylock-plugin ]; then
			lockerpid=$anc
			break
		fi
		anc=$(awk '{print $4}' "/proc/$anc/stat" 2>/dev/null)
	done
	if [ -n "$lockerpid" ]; then
		echo ">> holding alive while locker (pid $lockerpid) lives" >>"$rlog"
		while kill -0 "$lockerpid" 2>/dev/null; do
			sleep 5
		done
		echo ">> locker gone — exiting cleanly $(date '+%F %T')" >>"$rlog"
		exit 0
	fi
	# Locker not found in ancestry (should not happen under swaylock-plugin):
	# fall back to the old hold-alive so a dead fortress still can't take down
	# an active lock.
	exec sleep 2147483647
}

# ---------------------------------------------------------------------------
# Non-secure "screensaver" mode
# ---------------------------------------------------------------------------
# DF shown fullscreen on each output with NO lock and NO password gate, dismissed
# with Ctrl-C (or by an idle daemon's `resume`). It never touches your
# environment's real locker, needs neither swaylock-plugin nor windowtolayer, and
# works on any Wayland compositor — so it's the easiest way to try fishbowl out
# before committing to the secure-lock setup, and a sane option on desktops where
# replacing the native locker isn't wanted. On Sway each terminal is placed on
# its output and fullscreened via swaymsg; elsewhere the compositor/terminal
# handles fullscreen.
_ss_pids=()
_ss_cleanup() {
	trap - INT TERM EXIT
	log_msg "screensaver: tearing down"
	# Remove the temporary Esc-to-quit binding we added on Sway.
	if command -v swaymsg >/dev/null 2>&1 && [ -n "${SWAYSOCK:-}" ]; then
		swaymsg 'unbindsym Escape' >/dev/null 2>&1 || true
	fi
	local p
	for p in "${_ss_pids[@]}"; do kill "$p" 2>/dev/null || true; done
	stop_all_df
}

# Launch one fullscreen terminal (replacing this subshell) for a role.
#   $1 app-id  $2 inner command  $3.. extra terminal opts (foot only)
_ss_spawn() {
	local app="$1" inner="$2"
	shift 2
	case "$TERMINAL" in
	foot) exec foot --app-id="$app" "$@" -e sh -c "$inner" ;;
	kitty) exec kitty --class="$app" --start-as=fullscreen sh -c "$inner" ;;
	alacritty) exec alacritty --class "$app" -o window.startup_mode='"Fullscreen"' -e sh -c "$inner" ;;
	*) exec "$TERMINAL" -e sh -c "$inner" ;;
	esac
}

backend_screensaver() {
	_wl_ensure_fortresses

	local app="df_fishbowl-saver" have_sway=0
	if command -v swaymsg >/dev/null 2>&1 && [ -n "${SWAYSOCK:-}" ]; then
		have_sway=1
		swaymsg "for_window [app_id=\"$app\"] fullscreen enable" >/dev/null 2>&1 || true
		# Esc anywhere sends us SIGTERM (the fullscreen fortress otherwise has the
		# keyboard focus, so a plain Ctrl-C wouldn't reach us). Removed on cleanup.
		swaymsg "bindsym Escape exec kill -TERM $$" >/dev/null 2>&1 || true
	fi

	# Announce how to quit, then pause 2s so it's readable before the fullscreen
	# fortress covers this terminal.
	if [ "$have_sway" = 1 ]; then
		log_msg "screensaver starting in 2s — press Esc (anywhere) or Ctrl+C (in this terminal) to exit"
	else
		log_msg "screensaver starting in 2s — press Ctrl+C in this terminal to exit"
	fi
	sleep 2

	trap '_ss_cleanup; exit 0' INT TERM
	trap '_ss_cleanup' EXIT

	# Same reference grid + centering the lock uses, so the fortress fills/centres
	# consistently across mismatched screens.
	local ref rw rh
	ref="$(fortress_ref_pixels)"
	rw="${ref%x*}"
	rh="${ref#*x}"

	local name role w h sess inner
	while read -r name role w h; do
		sess="$(df_session_name "$name")"
		if [ "$role" = log ]; then
			inner="printf '\n  df-ai log\n'; exec tail -n 200 -F \"$LOG_FILE\""
		else
			inner="exec tmux attach -f read-only -t ${sess}"
		fi
		local -a opts=()
		if [ "$role" != log ] && [ "$TERMINAL" = foot ]; then
			[ -n "$FORTRESS_FONT" ] && opts+=(-o "font=${FORTRESS_FONT}${FORTRESS_FONT_SIZE:+:size=$FORTRESS_FONT_SIZE}")
			if [ -n "$ref" ]; then
				local px=$(((w - rw) / 2)) py=$(((h - rh) / 2))
				[ "$px" -lt 0 ] && px=0
				[ "$py" -lt 0 ] && py=0
				opts+=(-o "pad=${px}x${py} center")
			fi
		fi
		[ "$have_sway" = 1 ] && swaymsg "focus output \"$name\"" >/dev/null 2>&1 || true
		_ss_spawn "$app" "$inner" "${opts[@]}" &
		_ss_pids+=($!)
		sleep 0.3
	done < <(assign_roles)

	log_msg "screensaver running on ${#_ss_pids[@]} output(s) — Ctrl-C to stop"
	wait
}

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

	# swaylock-plugin runs in the foreground; it returns only once the session
	# is unlocked (correct password).
	log_msg "locking session (swaylock-plugin)"
	# --command-each runs our renderer once per output, each with its own
	# nested-compositor connection already bound to that output.
	swaylock-plugin \
		--command-each "$SELF _render" \
		"$@" || true

	# Unlocked: quicksave and tear DF down so df-ai stops using CPU.
	log_msg "unlocked — stopping DF"
	stop_all_df
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
		env | sort | grep -iE 'wayland|output|swaylock|display|geometry'
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
		inner="exec tail -n 200 -F \"$LOG_FILE\""
	else
		inner="tmux attach -r -t ${sess} 2>/dev/null; printf '\n  Dwarf Fortress screensaver\n'; exec sleep 2147483647"
	fi

	# Build the terminal argv and windowtolayer flags. Terminals fill their
	# output under the lock (a requested -w/-W size is ignored, so we always
	# --maximize), and the exec flag differs: kitty/havoc take the program
	# directly; foot/xterm/alacritty/urxvt use -e.
	local -a term wtl=(--maximized) footopts=()

	# Center the mirrored fortress on every screen. foot fills each output, but
	# `pad` insets its grid WITHIN that surface, so we pad every fortress foot down
	# to the largest rectangle common to all fortress outputs (fortress_ref_pixels;
	# a per-axis min that fits inside each one regardless of aspect ratio). Every
	# fortress foot then renders one identical grid, centered, so the shared tmux
	# session is consistent and no screen is cut off. foot-only; the log fills.
	if [ "$role" != log ] && [ "$TERMINAL" = foot ] && [ "$FORTRESS_MODE" != multi ]; then
		local ref this rw rh ow oh px py
		ref="$(fortress_ref_pixels)"
		this="$(output_pixels "$out")"
		if [ -n "$ref" ] && [ -n "$this" ]; then
			rw="${ref%x*}"; rh="${ref#*x}"; ow="${this%x*}"; oh="${this#*x}"
			px=$(((ow - rw) / 2)); py=$(((oh - rh) / 2))
			[ "$px" -lt 0 ] && px=0
			[ "$py" -lt 0 ] && py=0
			footopts=(-o "pad=${px}x${py} center")
			echo ">> centering fortress: pad=${px}x${py} (ref=$ref out=$this)" >>"$rlog"
		fi
	fi

	# Per-invocation font for the FORTRESS terminal only (never the user's global
	# config, and not the log — prose reads better in a normal font). A square
	# font (e.g. unscii) renders DF's CP437 map with correct proportions; a normal
	# 1:2 monospace looks vertically stretched. foot/kitty take it as -o; other
	# terminals are left alone. Missing glyphs fall back to the system default.
	local -a fontopts=()
	if [ "$role" != log ] && [ -n "$FORTRESS_FONT" ]; then
		case "$TERMINAL" in
		foot)
			fontopts=(-o "font=${FORTRESS_FONT}${FORTRESS_FONT_SIZE:+:size=$FORTRESS_FONT_SIZE}")
			;;
		kitty)
			fontopts=(-o "font_family=$FORTRESS_FONT")
			[ -n "$FORTRESS_FONT_SIZE" ] && fontopts+=(-o "font_size=$FORTRESS_FONT_SIZE")
			;;
		esac
	fi

	case "$TERMINAL" in
	havoc) term=("$TERMINAL" sh -c "$inner") ;;
	kitty) term=("$TERMINAL" "${fontopts[@]}" sh -c "$inner") ;;
	foot) term=("$TERMINAL" "${footopts[@]}" "${fontopts[@]}" -e sh -c "$inner") ;;
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
	# the session is locked; swaylock-plugin will terminate us on unlock.
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
			inner="exec tail -n 200 -F \"$LOG_FILE\""
		else
			inner="exec tmux attach -r -t ${sess}"
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

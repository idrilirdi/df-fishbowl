# shellcheck shell=bash
# X11 backend for fishbowl.  ***STRUCTURED BUT UNTESTED*** — written on a
# Wayland-only host; validate on a real X11 session before relying on it.
#
# The secure-lock-with-live-content analog of swaylock-plugin on X11 is
# `xsecurelock`: it locks the session and spawns a saver executable per monitor,
# handing it a window id in $XSCREENSAVER_WINDOW sized to that monitor. Our saver
# (`fishbowl _render`) embeds a terminal into that window with the same
# fortress/log split, decided from the window's geometry.
#
# Requires: xsecurelock, an X terminal that can embed into a foreign window
#           (xterm `-into`, urxvt `-embed`, st `-w`), tmux, xrandr, xwininfo.

# Override the Wayland classifier: enumerate connected X outputs via xrandr.
classify_outputs() {
	xrandr --query 2>/dev/null | awk '
		/ connected/ {
			name=$1
			# geometry token looks like 1920x1080+0+0 (skip "primary")
			for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { geom=$i; break }
			split(geom, a, /[x+]/)
			role=(a[2] > a[1]) ? "log" : "fortress"
			print name, role
		}'
}

_x11_ensure_fortresses() { ensure_df_running "$(df_session_name)" || true; }

backend_lock() {
	require_cmd xsecurelock || {
		log_msg "xsecurelock missing — install it (see README)"
		return 1
	}
	_x11_ensure_fortresses

	log_msg "locking session (xsecurelock)"
	XSECURELOCK_SAVER="$SELF _render" xsecurelock || true

	log_msg "unlocked — stopping DF"
	stop_all_df
}

# xsecurelock saver: draw into $XSCREENSAVER_WINDOW. Classify by that window's
# geometry (portrait => log), then embed the appropriate terminal into it.
backend_render() {
	local win="${XSCREENSAVER_WINDOW:-}"
	[ -n "$win" ] || {
		log_msg "no XSCREENSAVER_WINDOW — not an xsecurelock saver context"
		return 1
	}

	# Window geometry -> role.
	local w h role
	w=$(xwininfo -id "$win" 2>/dev/null | awk '/Width:/{print $2}')
	h=$(xwininfo -id "$win" 2>/dev/null | awk '/Height:/{print $2}')
	if [ -n "$h" ] && [ -n "$w" ] && [ "$h" -gt "$w" ]; then role=log; else role=fortress; fi

	local sess; sess="$(df_session_name)"
	local -a inner
	case "$role" in
	log) inner=(tail -n 200 -F "$LOG_FILE") ;;
	*) inner=(tmux attach -r -t "$sess") ;;
	esac

	# Terminal embedding is terminal-specific.
	case "$TERMINAL" in
	xterm) exec xterm -into "$win" -e "${inner[@]}" ;;
	urxvt | rxvt-unicode) exec urxvt -embed "$win" -e "${inner[@]}" ;;
	st) exec st -w "$win" -e "${inner[@]}" ;;
	*)
		log_msg "TERMINAL=$TERMINAL cannot embed into an X window; use xterm/urxvt/st"
		exec xterm -into "$win" -e "${inner[@]}"
		;;
	esac
}

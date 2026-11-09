#!/bin/bash
# Dwarf Fortress-style surroundings for the mirrored fortress.
#
# Runs as the single pane of a per-output tmux "frame" session whose client is
# the full-screen fortress terminal (see backend_render). It draws a DF cross
# section on the whole grid -- sky, grass and trees above, raw stone with ore
# and gem veins on the sides and below, magma at the very bottom, and a ring of
# smoothed double-line walls around the fortress -- and then hosts the live
# fortress in a BORDERLESS tmux popup of exactly COLS x ROWS cells, centred.
# Every fortress output shares the same COLS x ROWS, so the popups are what
# tmux sizes the shared DF session to; the frame around them differs per
# screen and is just scenery.
#
#   frame.sh COLS ROWS SESSION
#
# Glyphs are CP437 classics (all in unscii-8): ░▒▓ stone, £ ore, * gems,
# • boulders, ≈ magma, ♠♣♀ trees, ☺ dwarves. ☼ is not in unscii, so it is
# avoided (a fallback font would break the square cell).
cols="${1:?cols}" rows="${2:?rows}" sess="${3:?session}"

draw() {
	local msg="$1" W H
	W=$(tput cols) H=$(tput lines)
	awk -v W="$W" -v H="$H" -v C="$cols" -v R="$rows" -v msg="$msg" -v seed="$RANDOM" '
	function sgr(code) { if (code != cur) { out = out "\033[" code "m"; cur = code } }
	function put(code, ch) { sgr(code); out = out ch }
	function rock(   r) {
		r = rand()
		if (r < 0.62) put("90", "\xe2\x96\x92")        # ▒ stone
		else if (r < 0.80) put("90", "\xe2\x96\x91")   # ░
		else if (r < 0.92) put("37", "\xe2\x96\x93")   # ▓
		else if (r < 0.96) put("1;33", "\xc2\xa3")     # £ ore vein
		else if (r < 0.98) put("1;35", "*")            # * gem cluster
		else put("37", "\xe2\x80\xa2")                 # • boulder
	}
	function ground(   r) {
		r = rand()
		if (r < 0.015) put("1;33", "\xe2\x98\xba")     # ☺ a dwarf about
		else if (r < 0.06) put("1;32", "\xe2\x99\xa0") # ♠ tree
		else if (r < 0.10) put("32", "\xe2\x99\xa3")   # ♣ shrub
		else if (r < 0.13) put("1;32", "\xe2\x99\x80") # ♀ sapling
		else if (r < 0.60) put("32", "\"")             # grass
		else if (r < 0.80) put("2;32", "\x27")
		else if (r < 0.90) put("2;32", ",")
		else put("2;32", ".")
	}
	BEGIN {
		srand(seed)
		x0 = int((W - C) / 2); y0 = int((H - R) / 2)
		x1 = x0 + C - 1;      y1 = y0 + R - 1
		# Title and status live in the sky when there is room for them.
		title = "\xe2\x98\xba Dwarf Fortress fishbowl \xe2\x98\xba"
		tlen = 27
		trow = (y0 >= 5) ? int((y0 - 2) / 2) : -1
		tcol = int((W - tlen) / 2)
		out = ""; cur = ""
		for (y = 0; y < H; y++) {
			out = out "\033[" (y + 1) ";1H"
			if (y == trow && msg == "") {
				# the title row: sky, title, sky
				x = 0
				for (; x < tcol; x++) put("0", " ")
				put("1;33", title); x += tlen
				for (; x < W; x++) put("0", " ")
				continue
			}
			for (x = 0; x < W; x++) {
				if (x >= x0 && x <= x1 && y >= y0 && y <= y1) { put("0", " "); continue }   # under the popup
				# smoothed walls: the ring one cell outside the fortress
				if (x >= x0 - 1 && x <= x1 + 1 && y >= y0 - 1 && y <= y1 + 1) {
					if (y == y0 - 1 && x == x0 - 1) put("1;37", "\xe2\x95\x94")        # ╔
					else if (y == y0 - 1 && x == x1 + 1) put("1;37", "\xe2\x95\x97")   # ╗
					else if (y == y1 + 1 && x == x0 - 1) put("1;37", "\xe2\x95\x9a")   # ╚
					else if (y == y1 + 1 && x == x1 + 1) put("1;37", "\xe2\x95\x9d")   # ╝
					else if (y == y0 - 1 || y == y1 + 1) put("1;37", "\xe2\x95\x90")   # ═
					else put("1;37", "\xe2\x95\x91")                                  # ║
					continue
				}
				if (y < y0 - 1) {
					# the surface: sky, then one row of grass and trees on the wall
					if (y == y0 - 2) ground()
					else put("0", " ")
				} else if (y == H - 1 && y > y1 + 2) {
					put("1;31", "\xe2\x89\x88")                                        # ≈ magma sea
				} else rock()
			}
		}
		if (msg != "") { out = out "\033[1;1H"; sgr("1;33"); out = out " " msg " " }
		sgr("0")
		printf "%s", out
	}'
}

# Hide the cursor; the pane only ever shows scenery.
printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

while :; do
	draw ""
	# Borderless popup of exactly the shared grid, centred: this client is what
	# the DF session is sized to. -E closes the popup when the attach ends (DF
	# session gone); then show the scenery with a status line and retry.
	tmux display-popup -E -b none -x C -y C -w "$cols" -h "$rows" \
		"env -u TMUX tmux attach -f read-only -t '$sess' 2>/dev/null"
	draw "Dwarf Fortress screensaver - waiting for DF..."
	sleep 5
done

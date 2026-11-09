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
# The strata read top-down: sky with multi-tile trees (│ trunk, ♠ canopy), a
# grass row, brown soil, grey stone, darker stone with more £ ore and * gem
# veins the deeper it goes, then ≈ magma. Glyphs are CP437 classics present in
# unscii-8; ☼ is not, so it is avoided (a fallback font would break the square
# cell).
# Test hook: `frame.sh --draw W H COLS ROWS [MSG]` prints one frame for a
# W x H terminal to stdout and exits, without tmux (tests/frame.py).
if [ "${1:-}" = --draw ]; then
	FRAME_W="$2" FRAME_H="$3" cols="$4" rows="$5"
	draw_only=1
	shift 5
	msg="${1:-}"
else
	cols="${1:?cols}" rows="${2:?rows}" sess="${3:?session}"
fi

draw() {
	local msg="$1" W H
	W="${FRAME_W:-$(tput cols)}" H="${FRAME_H:-$(tput lines)}"
	awk -v W="$W" -v H="$H" -v C="$cols" -v R="$rows" -v msg="$msg" -v seed="$RANDOM" '
	function sgr(code) { if (code != cur) { out = out "\033[" code "m"; cur = code } }
	function put(code, ch) { sgr(code); out = out ch }
	# Strata, by depth d in rows below the grass. Each layer has its own colour
	# so the cross section reads top-down at a glance: brown soil, grey stone,
	# darker stone with more ore and gems the deeper it goes, magma.
	function soil(   r) {
		r = rand()
		if (r < 0.70) put("33", "\xe2\x96\x92")        # ▒ brown soil
		else if (r < 0.92) put("33", "\xe2\x96\x91")   # ░
		else if (r < 0.97) put("2;33", "\xe2\x96\x93") # ▓ clay
		else put("37", "\xe2\x80\xa2")                 # • boulder
	}
	function stone(deep,   r, ore, gem) {
		ore = deep ? 0.06 : 0.03; gem = deep ? 0.04 : 0.01
		r = rand()
		if (r < 0.60) put(deep ? "90" : "37", "\xe2\x96\x92")        # ▒ stone
		else if (r < 0.80) put(deep ? "2;90" : "90", "\xe2\x96\x91") # ░
		else if (r < 0.90) put(deep ? "90" : "1;37", "\xe2\x96\x93") # ▓
		else if (r < 0.90 + ore) put("1;33", "\xc2\xa3")             # £ ore vein
		else if (r < 0.90 + ore + gem) put("1;35", "*")              # * gem cluster
		else put(deep ? "90" : "37", "\xe2\x96\x92")
	}
	function magma(   r) {
		r = rand()
		if (r < 0.85) put("1;31", "\xe2\x89\x88")      # ≈ magma sea
		else put("31", "\xe2\x89\x88")
	}
	function ground(   r) {
		r = rand()
		if (r < 0.02) put("1;33", "\xe2\x98\xba")      # ☺ a dwarf about
		else if (r < 0.07) put("32", "\xe2\x99\xa3")   # ♣ shrub
		else if (r < 0.10) put("1;32", "\xe2\x99\x80") # ♀ sapling
		else if (r < 0.60) put("32", "\"")             # grass
		else if (r < 0.80) put("2;32", "\x27")
		else if (r < 0.90) put("2;32", ",")
		else put("2;32", ".")
	}
	# Underground: strata by depth below the grass row (d >= 1).
	function under(d, bottom) {
		if (bottom - d < 2 && bottom >= 4) magma()
		else if (d <= 2) soil()
		else stone(d > 2 + int((bottom - 2) / 2))
	}
	BEGIN {
		srand(seed)
		x0 = int((W - C) / 2); y0 = int((H - R) / 2)
		x1 = x0 + C - 1;      y1 = y0 + R - 1
		gy = y0 - 2                      # grass row (the wall is y0-1)
		bottom = H - 1 - gy              # depth of the last row
		# Title and status live in the sky when there is room for them.
		title = "\xe2\x98\xba Dwarf Fortress fishbowl \xe2\x98\xba"
		tlen = 27
		trow = (gy >= 4) ? 1 : -1
		tcol = int((W - tlen) / 2)
		# Multi-tile trees: a trunk standing on the grass with a ♠ canopy,
		# 2-4 rows tall, in the sky rows between the title and the grass.
		top = (trow >= 0) ? trow + 2 : 0
		if (gy - top >= 2) {
			for (x = 1; x < W - 1; x++) {
				if (rand() > 0.045) continue
				h = 2 + int(rand() * 3); if (h > gy - top) h = gy - top
				ty = gy - h                       # canopy top row
				for (y = ty + 1; y < gy; y++) tree[y, x] = "T"            # trunk
				tree[ty, x] = "C"
				if (h >= 3) { tree[ty + 1, x - 1] = "C"; tree[ty + 1, x + 1] = "C" }
				if (h >= 4) { tree[ty, x - 1] = "c"; tree[ty, x + 1] = "c" }
				x += 3
			}
		}
		out = ""; cur = ""
		for (y = 0; y < H; y++) {
			out = out "\033[" (y + 1) ";1H"
			if (y == trow && msg == "") {
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
				if (y < gy) {
					t = tree[y, x]
					if (t == "T") put("33", "\xe2\x94\x82")                            # │ trunk
					else if (t == "C") put("1;32", "\xe2\x99\xa0")                     # ♠ canopy
					else if (t == "c") put("32", "\xe2\x99\xa0")
					else put("0", " ")                                                # sky
				} else if (y == gy) ground()
				else under(y - gy, bottom)
			}
		}
		if (msg != "") { out = out "\033[1;1H"; sgr("1;33"); out = out " " msg " " }
		sgr("0")
		printf "%s", out
	}'
}

if [ "${draw_only:-0}" = 1 ]; then
	draw "$msg"
	printf '\n'
	exit 0
fi

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

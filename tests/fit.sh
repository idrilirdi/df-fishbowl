#!/bin/bash
# Unit tests for _wl_exact_fit (lib/backend-wayland.sh): the shared grid every
# mirrored fortress screen renders under FORTRESS_FIT=scale with foot.
#
# Invariants checked for each screen set, over every fortress output in it:
#   same    - every output gets the SAME cols x rows (that is the whole point)
#   fits    - cols*w <= width and rows*w <= height, so nothing is clipped
#   centred - the pad is exactly half the remainder on each axis
#   df-min  - the grid is at least 80x25 (DF refuses to start below that)
#   waste   - the unused area never exceeds the aspect-ratio floor by more
#             than one cell band on each axis (the search found a tight fit)
# plus the known-good office numbers, which are what the user looked at.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. lib/backend-wayland.sh 2>/dev/null

fails=0
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }

# fit_set "NAME" BASE REF WxH WxH ...  -> checks the invariants over the set;
# expect=<percent> in the environment also pins the summed waste.
fit_set() {
	local name="$1" base="$2" refmode="$3" expect="${expect:-}"; shift 3
	local all="$*" ref smallest o
	ref=$(printf '%s\n' "$@" | awk -F x -v m="$refmode" '{ if (m=="largest") { if ($1>w) w=$1; if ($2>h) h=$2 } else { if (w=="" || $1<w) w=$1; if (h=="" || $2<h) h=$2 } } END { printf "%dx%d", w, h }')
	smallest=$(printf '%s\n' "$@" | awk -F x '{ if (w=="" || $1<w) w=$1; if (h=="" || $2<h) h=$2 } END { printf "%dx%d", w, h }')
	local grid="" w px py cols rows ow oh waste total=0
	for o in "$@"; do
		read -r w px py cols rows < <(_wl_exact_fit "$ref" "$smallest" "$o" "$base" "$all")
		ow=${o%x*}; oh=${o#*x}
		[ -z "$grid" ] && grid="${cols}x${rows}"
		[ "${cols}x${rows}" = "$grid" ] || fail "$name $o: grid ${cols}x${rows} != $grid (same)"
		[ $((cols * w)) -le "$ow" ] && [ $((rows * w)) -le "$oh" ] || fail "$name $o: ${cols}x${rows} at ${w}px does not fit (fits)"
		[ "$px" = $(((ow - cols * w) / 2)) ] && [ "$py" = $(((oh - rows * w) / 2)) ] || fail "$name $o: pad ${px}x${py} not centred"
		[ "$cols" -ge 80 ] && [ "$rows" -ge 25 ] || fail "$name $o: grid ${cols}x${rows} below DF's 80x25"
		[ "$w" -ge 1 ] || fail "$name $o: cell ${w}px"
		# Maximal cell: one pixel more would overflow an axis, so the grid is
		# pushed against the screen on its tight axis; what is left on the
		# other axis is the aspect-ratio band no shared grid can remove.
		[ $((cols * (w + 1))) -gt "$ow" ] || [ $((rows * (w + 1))) -gt "$oh" ] || fail "$name $o: ${cols}x${rows} at ${w}px is not the largest cell that fits"
		waste=$(awk -v a="$((ow * oh))" -v u="$((cols * rows * w * w))" 'BEGIN{ printf "%4.1f", 100 * (1 - u / a) }')
		printf '  %-28s %-10s %3dpx grid %sx%s pad %sx%s waste %s%%\n' "$name" "$o" "$w" "$cols" "$rows" "$px" "$py" "$waste"
		total=$(awk -v t="$total" -v x="$waste" 'BEGIN{ print t + x }')
	done
	# Expected total waste (sum over the set, percent) when given: documents the
	# known optimum for the set, so a search regression shows up as a number.
	if [ -n "$expect" ]; then
		awk -v t="$total" -v e="$expect" 'BEGIN{ exit !(t <= e + 0.05) }' || fail "$name: total waste ${total}% > expected ${expect}%"
	fi
}

echo "- office (what the user verified): 10px/15px, 256x144, laptop pad 0x80"
read -r w px py cols rows < <(_wl_exact_fit 3840x2160 2560x1600 2560x1600 7 "2560x1600 3840x2160")
[ "$w $px $py $cols $rows" = "10 0 80 256 144" ] || fail "office laptop: got '$w $px $py $cols $rows'"
read -r w px py cols rows < <(_wl_exact_fit 3840x2160 2560x1600 3840x2160 7 "2560x1600 3840x2160")
[ "$w $px $py $cols $rows" = "15 0 0 256 144" ] || fail "office 4K: got '$w $px $py $cols $rows'"

echo "- invariants over screen sets (FORTRESS_REF=largest, base 7 unless noted)"
# Single screens fill to within a cell on both axes.
expect=1   fit_set "laptop alone"            7 largest 2560x1600
expect=1   fit_set "laptop scale 1.2 alone"  7 largest 2133x1333
expect=0   fit_set "same twice"              7 largest 2560x1440 2560x1440
# 16:10 beside 16:9: the 10% band on the 16:10 screen is the aspect floor.
expect=10  fit_set "office"                  7 largest 2560x1600 3840x2160
expect=10  fit_set "office base 9"           9 largest 2560x1600 3840x2160
expect=10  fit_set "office base 12"         12 largest 2560x1600 3840x2160
# FORTRESS_REF is honoured when the alternatives are within 5 points: the
# preferred screen fills (1440p over 1200p; the laptop under ref=smallest, even
# though a 4K-cut grid would waste 3 points less).
expect=10.5 fit_set "1200p + 1440p"          7 largest 1920x1200 2560x1440
expect=13.5 fit_set "office ref=smallest"    7 smallest 2560x1600 3840x2160
expect=10  fit_set "small laptop + 4K"       7 largest 1280x800 3840x2160
expect=10  fit_set "three screens"           7 largest 2560x1600 2560x1440 3840x2160
# Same aspect: exact or within a cell everywhere.
expect=0.5 fit_set "1080p + 4K"              7 largest 1920x1080 3840x2160
expect=1   fit_set "1080p + 1440p"           7 largest 1920x1080 2560x1440
expect=1   fit_set "5K + 1080p"              7 largest 5120x2880 1920x1080
# 21:9 beside 16:10: a third of the 16:10 screen is the aspect floor.
expect=34  fit_set "ultrawide + 1200p"       7 largest 3440x1440 1920x1200
# Per-axis reference box 2560x1454 matches neither screen; the grid must come
# from a real screen instead (256x144 fills the 1440p, 16:10 band on the other).
expect=12  fit_set "home 1.1 scale + 1440p"  7 largest 2327x1454 2560x1440

echo "- degenerate inputs do not explode"
out=$(_wl_exact_fit 0x0 0x0 2560x1600 7 "2560x1600"); [ -z "$out" ] || fail "zero reference should print nothing, got '$out'"
read -r w px py cols rows < <(_wl_exact_fit 2560x1600 2560x1600 2560x1600 7 "")
[ "$cols" -gt 0 ] && [ "$rows" -gt 0 ] || fail "empty output list: got '$w $px $py $cols $rows'"
read -r w px py cols rows < <(_wl_exact_fit 400x300 400x300 400x300 7 "400x300")
[ "$w" -ge 1 ] && [ $((cols * w)) -le 400 ] || fail "tiny screen: got '$w $px $py $cols $rows'"

if [ "$fails" = 0 ]; then echo "fit: OK"; else echo "fit: $fails failure(s)"; exit 1; fi

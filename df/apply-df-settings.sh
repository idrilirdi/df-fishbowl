#!/usr/bin/env bash
#
# Apply the Dwarf Fortress settings df_fishbowl needs, editing YOUR OWN DF install
# in place. df_fishbowl deliberately does not redistribute Bay 12's (init.txt /
# d_init.txt) or DFHack's (dfhack.init) files — it only adjusts the copies you
# already have. The one file it does ship is df-ai's config (df/df-ai.json).
#
# Usage: df/apply-df-settings.sh [DF_HOME]
set -euo pipefail

DF_HOME="${1:-${DF_HOME:-$HOME/DwarfFortressFishbowl/df_linux}}"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
init="$DF_HOME/data/init/init.txt"
dfhack_init="$DF_HOME/dfhack.init"
d_init="$DF_HOME/data/init/d_init.txt"
onmapload="$DF_HOME/onMapLoad.init"

[ -f "$init" ] || { echo "No $init — is DF_HOME ($DF_HOME) correct?" >&2; exit 1; }

# Set [KEY:VALUE] in a DF init file: rewrite the existing line, or append it.
set_opt() {
	local f="$1" k="$2" v="$3"
	if grep -q "^\[$k:" "$f"; then
		sed -i "s/^\[$k:[^]]*\]/[$k:$v]/" "$f"
	else
		printf '[%s:%s]\n' "$k" "$v" >>"$f"
	fi
}

# 1. Run DF as a terminal program, silent, and skip the intro movies.
set_opt "$init" PRINT_MODE TEXT
set_opt "$init" SOUND NO
set_opt "$init" INTRO NO
echo "init.txt: PRINT_MODE:TEXT, SOUND:NO, INTRO:NO"

# 2. Never pause on load (df-ai would sit on a paused fort until someone
#    presses a key), and keep seasonal saves so a killed DF loses little.
set_opt "$d_init" PAUSE_ON_LOAD NO
set_opt "$d_init" AUTOSAVE SEASONAL
set_opt "$d_init" INITIAL_SAVE YES
echo "d_init.txt: PAUSE_ON_LOAD:NO, AUTOSAVE:SEASONAL, INITIAL_SAVE:YES"

# 3. Make sure df-ai is enabled. DFHack ships its own dfhack.init; only add the
#    enable line if it isn't already there.
if [ -f "$dfhack_init" ] && grep -qE '^[[:space:]]*enable[[:space:]]+df-ai' "$dfhack_init"; then
	echo "dfhack.init: df-ai already enabled"
else
	printf '\n# df_fishbowl: let df-ai play the fortress autonomously\nenable df-ai\n' >>"$dfhack_init"
	echo "dfhack.init: added 'enable df-ai'"
fi

# 4. Install df-ai's configuration (autonomous random embarks + logging). df-ai
#    reads dfhack-config/df-ai.json; older layouts also keep hack/df-ai.json.
mkdir -p "$DF_HOME/dfhack-config"
install -m644 "$REPO/df/df-ai.json" "$DF_HOME/dfhack-config/df-ai.json"
install -m644 "$REPO/df/df-ai.json" "$DF_HOME/hack/df-ai.json"
echo "dfhack-config/df-ai.json and hack/df-ai.json installed"

# 5. Watchdog freeing df-ai from modal screens it cannot handle (the fort
#    otherwise freezes forever). Runs on a frame-based repeat from
#    onMapLoad.init, so it keeps ticking while the game is paused.
mkdir -p "$DF_HOME/hack/scripts"
install -m644 "$REPO/df/fishbowl-unstick.lua" "$DF_HOME/hack/scripts/fishbowl-unstick.lua"
if [ -f "$onmapload" ] && grep -q 'fishbowl-unstick' "$onmapload"; then
	echo "onMapLoad.init: fishbowl-unstick already scheduled"
else
	printf '\n# df_fishbowl: dismiss modal screens df-ai cannot handle (hack/scripts/fishbowl-unstick.lua)\nrepeat -name fishbowl-unstick -time 500 -timeUnits frames -command [ fishbowl-unstick ]\n' >>"$onmapload"
	echo "onMapLoad.init: scheduled fishbowl-unstick"
fi

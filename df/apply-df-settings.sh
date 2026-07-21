#!/usr/bin/env bash
#
# Apply the Dwarf Fortress settings fishbowl needs, editing YOUR OWN DF install
# in place. fishbowl deliberately does not redistribute Bay 12's (init.txt /
# d_init.txt) or DFHack's (dfhack.init) files — it only adjusts the copies you
# already have. The one file it does ship is df-ai's config (df/df-ai.json).
#
# Usage: df/apply-df-settings.sh [DF_HOME]
set -euo pipefail

DF_HOME="${1:-${DF_HOME:-$HOME/DwarfFortressFishbowl/df_linux}}"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
init="$DF_HOME/data/init/init.txt"
dfhack_init="$DF_HOME/dfhack.init"

[ -f "$init" ] || { echo "No $init — is DF_HOME ($DF_HOME) correct?" >&2; exit 1; }

# 1. Run DF as a terminal program, silent, and skip the intro movies. Rewrites
#    the [KEY:...] line in your init.txt (or appends it if absent).
set_opt() {
	local k="$1" v="$2"
	if grep -q "^\[$k:" "$init"; then
		sed -i "s/^\[$k:[^]]*\]/[$k:$v]/" "$init"
	else
		printf '[%s:%s]\n' "$k" "$v" >>"$init"
	fi
}
set_opt PRINT_MODE TEXT
set_opt SOUND NO
set_opt INTRO NO
echo "init.txt: PRINT_MODE:TEXT, SOUND:NO, INTRO:NO"

# 2. Make sure df-ai is enabled. DFHack ships its own dfhack.init; only add the
#    enable line if it isn't already there.
if [ -f "$dfhack_init" ] && grep -qE '^[[:space:]]*enable[[:space:]]+df-ai' "$dfhack_init"; then
	echo "dfhack.init: df-ai already enabled"
else
	printf '\n# fishbowl: let df-ai play the fortress autonomously\nenable df-ai\n' >>"$dfhack_init"
	echo "dfhack.init: added 'enable df-ai'"
fi

# 3. Install df-ai's configuration (autonomous random embarks + logging).
install -m644 "$REPO/df/df-ai.json" "$DF_HOME/hack/df-ai.json"
echo "hack/df-ai.json installed"

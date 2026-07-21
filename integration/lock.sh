#!/bin/bash
# Example lock hook. On sway/swaylock setups that run a user script
# (~/.config/swaylock/lock.sh), point that at this so the bar "Lock" button and
# the lock keybind start the df_fishbowl secure lock instead of plain swaylock.
export PATH="$HOME/.local/bin:$PATH"
exec df_fishbowl lock

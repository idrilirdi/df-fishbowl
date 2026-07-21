# bash completion for df_fishbowl.
# Enable by sourcing this file, e.g. add to ~/.bashrc:
#   source /path/to/screensaver/completions/df_fishbowl.bash
# or copy it to a completion dir:
#   ~/.local/share/bash-completion/completions/df_fishbowl
#   /usr/share/bash-completion/completions/df_fishbowl   (system-wide)

_df_screensaver() {
	local cur cmds
	cur="${COMP_WORDS[COMP_CWORD]}"
	cmds="lock screensaver start stop classify cleanup"
	# Only the first argument is a subcommand; nothing takes further arguments.
	if [ "$COMP_CWORD" -eq 1 ]; then
		mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
	fi
}
complete -F _df_screensaver df_fishbowl

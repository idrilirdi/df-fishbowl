#!/usr/bin/env bash
#
# Interactive installer for dwarf_fortress_fishbowl.
#
# It walks through the pieces and asks before each one, so you can install only
# what you need on your machine. Nothing here is mandatory except the CLI link.
#
# Non-interactive use: set FISHBOWL_YES=1 to accept every default.
# Package installs assume Debian/Ubuntu (apt); adapt the package step for other
# distros — every other step is distro-agnostic.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
SRCDIR="${FISHBOWL_SRC:-$HOME/.cache/fishbowl/src}"
YES="${FISHBOWL_YES:-0}"

# --- pretty + prompts --------------------------------------------------------
c() { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
ask() { # ask "Question?" [Y|N]  -> 0 = yes
	local q="$1" def="${2:-Y}" ans
	if [ "$YES" = 1 ]; then [ "$def" = Y ]; return; fi
	read -r -p "$q $([ "$def" = Y ] && echo '[Y/n]' || echo '[y/N]') " ans || true
	ans="${ans:-$def}"
	[ "${ans,,}" = y ] || [ "${ans,,}" = yes ]
}
askval() { # askval "Prompt" "default" -> echoes chosen value
	local q="$1" def="$2" ans
	if [ "$YES" = 1 ]; then printf '%s\n' "$def"; return; fi
	read -r -p "$q [$def]: " ans || true
	printf '%s\n' "${ans:-$def}"
}

# --- environment detection ---------------------------------------------------
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
	ENV=wayland
else
	ENV=x11
fi
c "== dwarf_fortress_fishbowl installer =="
echo "Detected session: $ENV    prefix: $PREFIX"
echo

# --- URLs (DF 0.47.05 + DFHack r1 + BenLubar df-ai) --------------------------
DF_ROOT="${DF_ROOT:-$HOME/DwarfFortressFishbowl}"
DF_HOME="$DF_ROOT/df_linux"
DF_URL="https://www.bay12games.com/dwarves/df_47_05_linux.tar.bz2"
DFHACK_URL="https://github.com/DFHack/dfhack/releases/download/0.47.05-r1/dfhack-0.47.05-r1-Linux-64bit-gcc-7.tar.bz2"
DFAI_ASSETS_URL="https://github.com/BenLubar/df-ai/releases/download/0.47.05-r1/df-ai-assets.zip"
DFAI_PLUGIN_URL="https://github.com/BenLubar/df-ai/releases/download/0.47.05-r1/df-ai-0.47.05-r1-linux-64.tar.gz"

# =============================================================================
step_deps() {
	ask "Install build/runtime dependencies via apt (needs sudo)?" Y || return 0
	local pkgs=(tmux jq git wget bzip2 unzip)
	[ "$ENV" = wayland ] && pkgs+=(foot build-essential meson ninja-build pkg-config
		cargo python3 libwayland-dev wayland-protocols scdoc libcairo2-dev
		libgdk-pixbuf-2.0-dev libxkbcommon-dev libpam0g-dev libsystemd-dev)
	c "Installing: ${pkgs[*]}"
	sudo apt-get update && sudo apt-get install -y "${pkgs[@]}"
}

# swaylock-plugin needs wayland-protocols >= 1.47; build a newer one into
# $PREFIX if the distro's is too old (data + a .pc, no scanner needed).
ensure_wayland_protocols() {
	export PKG_CONFIG_PATH="$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
	pkg-config --atleast-version=1.47 wayland-protocols && return 0
	c "Building a newer wayland-protocols into $PREFIX"
	mkdir -p "$SRCDIR"
	[ -d "$SRCDIR/wayland-protocols" ] || git clone https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$SRCDIR/wayland-protocols"
	( cd "$SRCDIR/wayland-protocols" && git checkout "$(git tag | sort -V | tail -1)" )
	meson setup --prefix "$PREFIX" -Dtests=false --wipe "$SRCDIR/wayland-protocols/build" "$SRCDIR/wayland-protocols"
	ninja -C "$SRCDIR/wayland-protocols/build" install
}

_ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
ensure_rust() { # windowtolayer needs rustc >= 1.80; bootstrap rustup if too old
	local have; have=$(rustc --version 2>/dev/null | awk '{print $2}')
	{ [ -n "$have" ] && _ver_ge "$have" 1.80.0; } && return 0
	[ -x "$HOME/.cargo/bin/rustc" ] && { export PATH="$HOME/.cargo/bin:$PATH"; _ver_ge "$(rustc --version|awk '{print $2}')" 1.80.0 && return 0; }
	c "Installing rustup (distro rust ${have:-none} < 1.80)"
	command -v rustup >/dev/null 2>&1 || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
	export PATH="$HOME/.cargo/bin:$PATH"; rustup default stable >/dev/null 2>&1 || true
}

step_swaylock_plugin() {
	[ "$ENV" = wayland ] || return 0
	command -v swaylock-plugin >/dev/null 2>&1 || [ -x "$BINDIR/swaylock-plugin" ] && {
		ask "swaylock-plugin already present — rebuild it?" N || return 0; }
	ask "Build patched swaylock-plugin (secure lock with a live terminal background)?" Y || return 0
	mkdir -p "$SRCDIR" "$BINDIR"
	[ -d "$SRCDIR/swaylock-plugin" ] || git clone https://github.com/mstoeckl/swaylock-plugin.git "$SRCDIR/swaylock-plugin"
	(
		cd "$SRCDIR/swaylock-plugin"
		git fetch --tags -q || true
		git checkout -q "$(git tag | grep -E '^(v)?1\.8\.7$' | head -1 || echo main)"
		git checkout -q -B fishbowl-build
		# Apply the fishbowl patches unless upstream already has them.
		if git apply --check "$REPO"/patches/*.patch 2>/dev/null; then
			git am "$REPO"/patches/*.patch
			echo "Applied fishbowl patches."
		else
			warn "Patches did not apply cleanly (already upstream, or version drift?) — building as-is."
		fi
		ensure_wayland_protocols
		meson setup --prefix "$PREFIX" --wipe build . 2>/dev/null || meson setup --prefix "$PREFIX" build .
		ninja -C build
		# Copy only the binaries (ninja install would write to system dirs).
		install -m755 build/swaylock-plugin "$BINDIR/swaylock-plugin"
		install -m755 build/swaylock-sleep-watcher "$BINDIR/" 2>/dev/null || true
	)
	[ -f /etc/pam.d/swaylock ] || warn "No /etc/pam.d/swaylock — install the distro 'swaylock' package so unlocking (PAM) works."
}

step_windowtolayer() {
	[ "$ENV" = wayland ] || return 0
	command -v windowtolayer >/dev/null 2>&1 || [ -x "$BINDIR/windowtolayer" ] && {
		ask "windowtolayer already present — rebuild it?" N || return 0; }
	ask "Build windowtolayer (wraps a terminal as a lock-screen layer surface)?" Y || return 0
	ensure_rust
	mkdir -p "$SRCDIR" "$BINDIR"
	[ -d "$SRCDIR/windowtolayer" ] || git clone https://gitlab.freedesktop.org/mstoeckl/windowtolayer.git "$SRCDIR/windowtolayer"
	( cd "$SRCDIR/windowtolayer" && cargo build --release )
	install -m755 "$SRCDIR/windowtolayer/target/release/windowtolayer" "$BINDIR/windowtolayer"
}

step_havoc() {
	[ "$ENV" = wayland ] || return 0
	ask "Build havoc (a minimal terminal that works with an UNPATCHED swaylock-plugin)?" N || return 0
	mkdir -p "$SRCDIR" "$BINDIR"
	[ -d "$SRCDIR/havoc" ] || git clone --depth 1 https://github.com/ii8/havoc.git "$SRCDIR/havoc"
	( cd "$SRCDIR/havoc" && make )
	install -m755 "$SRCDIR/havoc/havoc" "$BINDIR/havoc"
	warn "To use it, set TERMINAL=havoc in your fishbowl config."
}

step_download_df() {
	if [ -x "$DF_HOME/dfhack" ]; then
		echo "Dwarf Fortress already at $DF_HOME — skipping download."
		return 0
	fi
	ask "Download Dwarf Fortress 0.47.05 + DFHack + df-ai into $DF_ROOT (~200 MB)?" Y || return 0
	mkdir -p "$DF_ROOT/dl"
	_get() { [ -f "$2" ] || wget -O "$2" "$1"; }
	_get "$DF_URL" "$DF_ROOT/dl/df.tar.bz2"
	_get "$DFHACK_URL" "$DF_ROOT/dl/dfhack.tar.bz2"
	_get "$DFAI_ASSETS_URL" "$DF_ROOT/dl/df-ai-assets.zip"
	_get "$DFAI_PLUGIN_URL" "$DF_ROOT/dl/df-ai-plugin.tar.gz"
	tar -C "$DF_ROOT" -xf "$DF_ROOT/dl/df.tar.bz2"
	tar -C "$DF_HOME" -xf "$DF_ROOT/dl/dfhack.tar.bz2"
	( cd "$DF_HOME" && unzip -o "$DF_ROOT/dl/df-ai-assets.zip" )
	tar -C "$DF_HOME/hack/plugins" -xf "$DF_ROOT/dl/df-ai-plugin.tar.gz"
}

# DF 0.47.05-specific compatibility fixes. Optional and explained in the README.
step_df_fixes() {
	[ -d "$DF_HOME" ] || return 0
	ask "Apply Dwarf Fortress 0.47.05 compatibility fixes (PRINT_MODE:TEXT + df-ai + ncurses symlinks)? See README." Y || return 0
	# 1. Edit your own DF init/dfhack.init in place + install df-ai's config.
	#    (fishbowl does not redistribute Bay 12's or DFHack's files.)
	DF_HOME="$DF_HOME" "$REPO/df/apply-df-settings.sh" "$DF_HOME"
	# 2. ncurses compat: DF dlopens libncursesw.so / .so.5, absent on modern
	#    distros; symlink to .so.6 inside DF's own LD_LIBRARY_PATH (hack/libs).
	local sysdir libdir="$DF_HOME/hack/libs"
	for sysdir in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
		[ -e "$sysdir/libncursesw.so.6" ] && break
	done
	mkdir -p "$libdir"
	ln -sf "$sysdir/libncursesw.so.6" "$libdir/libncursesw.so"
	ln -sf "$sysdir/libncursesw.so.6" "$libdir/libncursesw.so.5"
	ln -sf "$sysdir/libncurses.so.6"  "$libdir/libncurses.so"
	ln -sf "$sysdir/libncurses.so.6"  "$libdir/libncurses.so.5"
	warn "DF also needs SDL 1.2 runtime libs (see README): sudo apt install libsdl1.2debian libsdl-image1.2 libsdl-ttf2.0-0"
}

# A square font so DF's TEXT-mode CP437 map isn't vertically stretched. unscii-8
# is square, public domain, and covers CP437 + semigraphics. Installed per-user
# (no sudo); FONT_FAMILY is set on success so the written config points at it.
FONT_FAMILY=""
step_font() {
	[ "$ENV" = wayland ] || return 0
	echo "DF runs in TEXT mode and draws with the terminal font. A SQUARE font"
	echo "renders its map with correct proportions; a normal monospace looks"
	echo "vertically stretched. unscii-8 (square, public domain) fixes that."
	ask "Install the unscii font into ~/.local/share/fonts (per-user, no sudo)?" Y || return 0
	if fc-list 2>/dev/null | grep -qi 'unscii'; then
		echo "unscii already installed."; FONT_FAMILY="unscii"; return 0
	fi
	local dir="$HOME/.local/share/fonts" url="http://viznut.fi/unscii/unscii-8.ttf"
	mkdir -p "$dir"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSLo "$dir/unscii-8.ttf" "$url" || { warn "Download failed; see FORTRESS_FONT in config/fishbowl.conf for a manual install."; return 0; }
	else
		wget -qO "$dir/unscii-8.ttf" "$url" || { warn "Download failed; see FORTRESS_FONT in config/fishbowl.conf."; return 0; }
	fi
	fc-cache -f "$dir" >/dev/null 2>&1 || fc-cache -f >/dev/null 2>&1 || true
	if fc-list 2>/dev/null | grep -qi 'unscii'; then
		FONT_FAMILY="unscii"; c "Installed unscii → ~/.local/share/fonts/unscii-8.ttf"
	else
		warn "unscii downloaded but fontconfig can't see it yet; check ~/.local/share/fonts."
	fi
}

step_config_and_link() {
	mkdir -p "$BINDIR"
	ln -sf "$REPO/bin/fishbowl" "$BINDIR/fishbowl"
	c "Linked $BINDIR/fishbowl"
	if ask "Write a personal config to ~/.config/fishbowl/config?" Y; then
		mkdir -p "$HOME/.config/fishbowl"
		local df term font
		df="$(askval 'Dwarf Fortress install dir (DF_HOME)' "$DF_HOME")"
		term="$(askval 'Terminal to display the fortress (TERMINAL)' "$([ "$ENV" = wayland ] && echo foot || echo xterm)")"
		# Default the fortress font to whatever step_font installed (blank = the
		# terminal's own font, i.e. no un-stretching).
		font="$(askval 'Font for the fortress terminal (FORTRESS_FONT, blank = terminal default)' "$FONT_FAMILY")"
		cat >"$HOME/.config/fishbowl/config" <<EOF
# Personal fishbowl config (overrides config/fishbowl.conf). See that file for
# all options and the README for details.
DF_HOME="$df"
TERMINAL="$term"
FORTRESS_FONT="$font"
EOF
		echo "Wrote ~/.config/fishbowl/config"
	fi
}

# =============================================================================
main() {
	step_deps
	step_swaylock_plugin
	step_windowtolayer
	step_havoc
	step_download_df
	step_df_fixes
	step_font
	step_config_and_link
	echo
	c "Done."
	cat <<EOF
Next:
  * Ensure $BINDIR is on PATH.
  * Try it:   fishbowl classify      # shows each output's role (fortress|log)
              fishbowl start-df       # launch DF in tmux; tmux attach -t \$SESSION
              fishbowl lock           # secure lock with the live fortress
  * Wire it into swayidle / your bar — see README.md and integration/.
EOF
}
main "$@"

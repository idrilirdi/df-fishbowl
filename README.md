# dwarf_fortress_fishbowl

*Watch a Dwarf Fortress play itself, as your screen locker.*

A fishbowl for [Dwarf Fortress](https://www.bay12games.com/dwarves/): the game
plays itself via [BenLubar's **df-ai**](https://github.com/BenLubar/df-ai) while
your session is **securely locked**, shown live across your monitors — the
fortress on landscape screens, df-ai's running narration on portrait ones. On
unlock it quicksaves and stops so it isn't burning CPU behind your back.

- Runs DF as a real terminal program (`PRINT_MODE:TEXT`) inside `tmux`.
- ~10% of the time a brand-new fortress is embarked; otherwise a random save is
  loaded. Saves older than ~1 month are pruned.
- Auto-adapts to however many screens you have and how they're oriented.

> **Status:** works on **Sway/Wayland**. An X11 backend is included but
> **untested** — treat it as a starting point.

`tests/run.sh` runs the unit tests (bash + python3, no other dependencies):
the shared-grid fit across screen combinations and the scenery frame across
terminal shapes.

---

## How it works

The hard part is showing a *live terminal* behind a *secure* lock. On Wayland
that means an `ext-session-lock` client that can composite a per-output live
background:

| Layer | What | Project |
|-------|------|---------|
| Secure lock + live background | `swaylock-plugin` (`--command-each`) | [mstoeckl/swaylock-plugin](https://github.com/mstoeckl/swaylock-plugin) |
| Wrap a terminal as a layer-shell surface | `windowtolayer` | [mstoeckl/windowtolayer](https://gitlab.freedesktop.org/mstoeckl/windowtolayer) |
| Terminal | `foot` / `havoc` / `alacritty` | — |
| Fortress | `tmux attach` to a detached DF (`PRINT_MODE:TEXT`) | DF + DFHack + df-ai |
| Log | `tail -F df-ai.log` | df-ai |

`df_fishbowl lock` starts DF, then runs `swaylock-plugin` once per output;
each instance picks its role from the output's orientation, wraps the right
terminal with `windowtolayer`, and renders. If a terminal or DF dies, the
instance is kept alive so swaylock-plugin degrades to a plain password lock
rather than failing — **a dead fortress never locks you out**.

### swaylock-plugin patches

Running a *terminal* (rather than a simple wallpaper program) as a
swaylock-plugin background needs three fixes to swaylock-plugin. They live in
[`patches/`](patches/) and the installer applies them on top of `v1.8.7`; each
is also submitted upstream:

1. **Scale mismatched plugin surfaces to the exact lock size** — terminals
   round their size to a whole character-cell grid, which violates
   `ext-session-lock`'s exact-size rule. Scales via the lock surface viewport
   instead of rejecting. *(Needed by every terminal.)*
2. **Advertise `wl_subcompositor` to plugins** — foot/alacritty require it at
   startup. *(Not needed by havoc.)*
3. **Advertise a minimal `wl_seat` to plugins** — foot refuses to start without
   a seat. *(Not needed by havoc.)*

If/when these merge upstream, the installer detects that the patches no longer
apply and builds stock swaylock-plugin.

---

## Terminals

Pick with `TERMINAL=` in your config. On the swaylock-plugin backend:

| Terminal | Works | Needs |
|----------|:-----:|-------|
| **havoc** | ✅ | patch **1** only (single `wl_shm` surface — no subcompositor/seat) |
| **foot** (default) | ✅ | patches **1 + 2 + 3** |
| **alacritty** | ✅ | patches **1 + 2** |
| **kitty** | ☠️ | **dangerous — do not use.** Its GL/EGL init crashes swaylock-plugin's compositor, which abandons the `ext-session-lock` (sway shows its red recovery screen). |

Use **havoc** if you'd rather run an unpatched swaylock-plugin. Use **foot** for
the nicest text — and for the mirrored-fortress centering (see *Multiple
displays*), which is `foot`-only.

---

## Requirements

`tmux` (>= 3.2), `jq`, a terminal (above), and — built from source by the installer —
`swaylock-plugin` + `windowtolayer` (and optionally `havoc`). swaylock-plugin
authenticates via the distro **`swaylock` PAM service**, so keep the `swaylock`
package installed (`/etc/pam.d/swaylock`). Build deps (Debian/Ubuntu) are listed
in and installed by [`install.sh`](install.sh).

## Install

```sh
./install.sh          # interactive — asks before each step
DF_FISHBOWL_YES=1 ./install.sh   # accept every default (non-interactive)
```

It walks through: dependencies · patched swaylock-plugin · windowtolayer ·
(optional) havoc · downloading DF 0.47.05 + DFHack + df-ai · (optional) the DF
0.47.05 compatibility fixes · (optional) a square fortress font (unscii) ·
linking the `df_fishbowl` CLI and writing a personal config. Skip anything you
already have. Ensure `~/.local/bin` is on your `PATH`.

## Usage

```sh
df_fishbowl lock       # start DF (if needed) + secure lock with the live view
df_fishbowl start-df   # start DF in tmux only (then: tmux attach -t "$SESSION")
df_fishbowl stop       # quicksave + stop all DF sessions
df_fishbowl classify   # print each active output's role (fortress|log)
df_fishbowl cleanup    # prune saves older than SAVE_MAX_AGE_DAYS
```

## Configuration

Defaults are in [`config/df_fishbowl.conf`](config/df_fishbowl.conf); override them in
`~/.config/df_fishbowl/config` (the installer can write one for you). The full
surface:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DF_HOME` | `~/DwarfFortressFishbowl/df_linux` | extracted DF tree (has `dfhack`/`dfhack-run`); a dedicated dir so it never touches a DF install you play on |
| `LOG_FILE` | `$DF_HOME/df-ai.log` | df-ai narration log (shown on log outputs) |
| `SESSION` | `df_fishbowl` | tmux session name for the running DF |
| `TERMINAL` | `foot` | display terminal (see Terminals) |
| `FORTRESS_FONT` | `unscii` | font for the fortress terminal only, set per-invocation; a square font un-stretches the map (see *Font*). Blank = terminal default |
| `FORTRESS_FONT_SIZE` | *(empty)* | point size for `FORTRESS_FONT` on the smallest fortress screen; empty = use `FORTRESS_BASE_FONT_SIZE` |
| `FORTRESS_FIT` | `scale` | how mirrored screens share one grid: `scale` = size the font per screen so all share the reference grid, then pad the remainder; `pad` = no scaling, inset every grid to the smallest screen (see *Multiple displays*) |
| `FORTRESS_REF` | `largest` | with `FORTRESS_FIT=scale`, which screen fills edge to edge: `largest` or `smallest` |
| `FORTRESS_BASE_FONT_SIZE` | `9` | the main tile-size dial: point size on the smallest fortress screen; others scale from it |
| `FORTRESS_FRAME` | `1` | draw Dwarf Fortress scenery (surface, stone, magma, walls) around the fortress where a screen's aspect leaves room; `0` = plain border |
| `FORTRESS_BACKGROUND` | `000000` | background of the fortress terminal (sky / plain border), hex RGB |
| `NEW_FORT_CHANCE` | `10` | % chance to embark a new fort vs. load a save |
| `SAVE_MAX_AGE_DAYS` | `30` | prune saves older than this |
| `MAX_SAVES` | `10` | keep only this many most recently played forts (0 = no cap) |
| `FORTRESS_MODE` | `single` | `single` = one sim mirrored to all fortress outputs; `multi` = one sim per fortress output |
| `LOG_ON_SMALLER_HORIZONTAL` | `1` | with 2+ landscape outputs and no portrait one, put the log on the smallest landscape |
| `MIRROR_SIZE` | `smallest` | shared tmux grid: `smallest` never cuts content off (a thin filler band at worst); `largest` fills the biggest screen and clips the others |
| `SAVE_FLUSH_SECS` | `3` | wait after quicksave before quitting |
| `STOP_TIMEOUT` | `15` | grace period before SIGKILL on stop |
| `RPC_TIMEOUT` | `10` | seconds to wait for DF to answer `dfhack-run` (quicksave) before stopping it anyway |
| `LIFECYCLE_LOCK_WAIT` | `120` | starts and stops are serialised; seconds one waits for the other |
| `DF_FISHBOWL_BACKEND` | *(auto)* | force `wayland` or `x11` |

### Multiple displays

Roles are assigned from output orientation:

- **One output** → always the **fortress**.
- **Portrait** outputs → **log**; **landscape** → **fortress**.
- **Two+ landscape and no portrait** → smallest landscape shows the **log**,
  the rest the fortress (disable with `LOG_ON_SMALLER_HORIZONTAL=0`).

In `single` mode all fortress outputs mirror one simulation via tmux. A terminal
fills each output under the lock and can't be pixel-scaled, so the fortresses
share **one** grid. With the default `FORTRESS_FIT=scale` the render step
sizes the font per screen so every fortress terminal gets the same grid, then
pads the remainder to centre it: the `FORTRESS_REF` screen fills edge to edge
and the others are centred with a thin border. With `foot` the grid is exact:
the cell is pinned to a whole number of pixels (`pixelsize` for the advance,
`line-height` for the row), so the grid is plain integer division and every
screen shows the identical fortress. Where a screen's aspect leaves room
around that grid, a per-output tmux session draws a Dwarf Fortress cross
section there (grass and trees above, stone with ore and gem veins beside and
below, magma at the bottom, smoothed walls around the fort) and hosts the
fortress in a borderless popup (`FORTRESS_FRAME`, `lib/frame.sh`). Other terminals get a scaled point size,
and the font's metric rounding can leave their grids a cell or two apart; the
shared session uses tmux `window-size=smallest` (`MIRROR_SIZE`), so a screen
with a slightly larger grid shows a thin band of filler dots rather than losing
content.
`FORTRESS_FIT=pad` skips the scaling and insets every grid to the smallest
screen — exact, but a much bigger screen is mostly border, and the large pads
need `foot` (alacritty's padding is capped at 255px). Because
differently-sized/aspected screens can't all be *filled* by one text grid, use
**`FORTRESS_MODE=multi`** for an independent, natively-full fortress on each
screen (one df-ai simulation per fortress screen — more CPU, but every screen is
crisp and complete).

### Font (un-stretching the map)

In `PRINT_MODE:TEXT` DF has **no tileset** — it draws with the *terminal's font*.
A normal monospace cell is about 1:2 (twice as tall as wide), but DF's world
assumes **square** tiles, so the map looks vertically stretched. The fix is a
square font: set `FORTRESS_FONT` to one and fishbowl passes it to the fortress
terminal **per-invocation** (your global terminal config and the log are left
alone). [`unscii`](http://viznut.fi/unscii/) (unscii-8 — square, public domain,
CP437 + semigraphics) is an excellent fit and is what `install.sh` offers to
fetch into `~/.local/share/fonts`; install it by hand with:

```sh
mkdir -p ~/.local/share/fonts &&
curl -fsSLo ~/.local/share/fonts/unscii-8.ttf http://viznut.fi/unscii/unscii-8.ttf &&
fc-cache -f
```

Only `foot` applies `FORTRESS_FONT` safely. Any glyphs the font lacks fall back
to the system default. (`foot` has no cell-height control, so a naturally square
font is the only clean fix there — which is exactly what unscii is.)

## Integration (idle / bar / keybind)

See [`integration/`](integration/):

- `integration/lock.sh` — drop at `~/.config/swaylock/lock.sh` so a sway "Lock"
  button / keybind starts fishbowl.
- `integration/swayidle.conf` — how to point an idle-lock timeout at
  `df_fishbowl lock` (with `resume 'df_fishbowl stop'`), keeping your dim/suspend
  timeouts.
- `integration/sway-portals.conf` — drop at
  `~/.config/xdg-desktop-portal/sway-portals.conf` (then
  `systemctl --user restart xdg-desktop-portal` and restart Firefox) so a
  playing video keeps the fishbowl away. Without it, Firefox's "Playing video"
  idle inhibit goes to xdg-desktop-portal-gtk, which reports success but only
  creates an inhibitor on its own hidden window — sway ignores inhibitors on
  invisible surfaces — so swayidle locks in the middle of a YouTube video. With
  no Inhibit backend the portal call fails and Firefox falls back to the native
  Wayland idle-inhibit protocol on its own (visible) window, which sway honours.
  Check with `swaymsg -t get_tree | grep inhibit_idle` while a video plays.

## Dwarf Fortress 0.47.05 compatibility notes

DF 0.47.05 is from 2021 and needs a few tweaks on a modern distro. The installer
applies these when you opt in; you can also run them yourself with
[`df/apply-df-settings.sh`](df/apply-df-settings.sh) `[DF_HOME]`, which edits
**your own** DF files in place (fishbowl ships neither Bay 12's nor DFHack's
files):

- **`PRINT_MODE:TEXT`** (also `SOUND:NO`, `INTRO:NO`) is set in your
  `data/init/init.txt` so DF runs as a terminal program. DFHack's interactive
  console is disabled in TEXT mode, but df-ai plays regardless.
- **`enable df-ai`** is appended to your `dfhack.init` if not already present.
- **`PAUSE_ON_LOAD:NO`** (also `AUTOSAVE:SEASONAL`, `INITIAL_SAVE:YES`) is set in
  `data/init/d_init.txt`, so a loaded fort plays on instead of waiting for a key.
- **df-ai's config** — [`df/df-ai.json`](df/df-ai.json) (autonomous random
  embarks + logging) is copied to `dfhack-config/df-ai.json`, which df-ai reads,
  and to the legacy `hack/df-ai.json`.
- **Unstick watchdog** — df-ai 0.47.05 freezes the fort forever on modal screens
  it doesn't know (e.g. a diplomat meeting). [`df/fishbowl-unstick.lua`](df/fishbowl-unstick.lua)
  is copied to `hack/scripts/` and scheduled from `onMapLoad.init` every ~500
  frames; it dismisses a screen that stays up across two checks.
- **SDL 1.2 runtime libraries** — the DF binary links them even in TEXT mode:
  `sudo apt install libsdl1.2debian libsdl-image1.2 libsdl-ttf2.0-0`.
- **ncurses symlinks** — DF `dlopen`s `libncursesw.so`/`.so.5`, absent on
  modern distros. The installer symlinks them to `.so.6` inside
  `$DF_HOME/hack/libs` (on DF's own `LD_LIBRARY_PATH`); no root needed.

## Troubleshooting

- **Grey lock, no fortress** — the terminal failed to start; swaylock-plugin
  fell back to a plain (still working) password lock. Check
  `~/.cache/df_fishbowl-render.log`. Common causes: missing swaylock-plugin patch
  for your terminal, or DF not running.
- **Fortress small in the top-left corner, dots around it** — the shared tmux
  window is stuck at a stale size. fishbowl's viewers attach with
  `tmux attach -f read-only` (needs tmux >= 3.2); never `-r`, which also sets
  `ignore-size`, and tmux skips such clients whenever any normal client is
  attached anywhere on the same server.
- **Fortress off-centre / thin dot band** — check the `fitting fortress` lines in
  `~/.cache/df_fishbowl-render.log`. A band of a cell or two is expected rounding
  (see *Multiple displays*); more than that usually means an old swaylock-plugin
  without patch #1, or a non-`foot` terminal under `FORTRESS_FIT=pad`.
- **Can't unlock** — your password always works even when the background fails;
  the lock never depends on DF.

## Credits

Built entirely on other people's work:

- **Dwarf Fortress** — Tarn & Zach Adams / [Bay 12 Games](https://www.bay12games.com/).
- **DFHack** — the [DFHack team](https://github.com/DFHack/dfhack).
- **df-ai** (the self-playing AI) — [BenLubar](https://github.com/BenLubar/df-ai).
- **swaylock-plugin** and **windowtolayer** — Manuel Stoeckl ([mstoeckl](https://github.com/mstoeckl)).
- **havoc** — [ii8](https://github.com/ii8/havoc); **foot** — Daniel Eklöf; **alacritty** — the Alacritty project.
- **sway** / **wlroots** and the Wayland `ext-session-lock` / `wlr-layer-shell` protocols.

`df_fishbowl` itself just wires these together.

## License

[MIT](LICENSE) © 2026 Idril Geer. The bundled `patches/` are derivative of
swaylock-plugin and carry that project's (also MIT) copyright. fishbowl does not
redistribute Dwarf Fortress's or DFHack's own files — it edits the copies in
your own install (see below).

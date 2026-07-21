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

`fishbowl lock` starts DF, then runs `swaylock-plugin` once per output;
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

`tmux`, `jq`, a terminal (above), and — built from source by the installer —
`swaylock-plugin` + `windowtolayer` (and optionally `havoc`). swaylock-plugin
authenticates via the distro **`swaylock` PAM service**, so keep the `swaylock`
package installed (`/etc/pam.d/swaylock`). Build deps (Debian/Ubuntu) are listed
in and installed by [`install.sh`](install.sh).

## Install

```sh
./install.sh          # interactive — asks before each step
FISHBOWL_YES=1 ./install.sh   # accept every default (non-interactive)
```

It walks through: dependencies · patched swaylock-plugin · windowtolayer ·
(optional) havoc · downloading DF 0.47.05 + DFHack + df-ai · (optional) the DF
0.47.05 compatibility fixes · (optional) a square fortress font (unscii) ·
linking the `fishbowl` CLI and writing a personal config. Skip anything you
already have. Ensure `~/.local/bin` is on your `PATH`.

## Usage

```sh
fishbowl lock       # start DF (if needed) + secure lock with the live view
fishbowl start-df   # start DF in tmux only (then: tmux attach -t "$SESSION")
fishbowl stop       # quicksave + stop all DF sessions
fishbowl classify   # print each active output's role (fortress|log)
fishbowl cleanup    # prune saves older than SAVE_MAX_AGE_DAYS
```

## Configuration

Defaults are in [`config/fishbowl.conf`](config/fishbowl.conf); override them in
`~/.config/fishbowl/config` (the installer can write one for you). The full
surface:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DF_HOME` | `~/DwarfFortress/df_linux` | extracted DF tree (has `dfhack`/`dfhack-run`) |
| `LOG_FILE` | `$DF_HOME/df-ai.log` | df-ai narration log (shown on log outputs) |
| `SESSION` | `fishbowl` | tmux session name for the running DF |
| `TERMINAL` | `foot` | display terminal (see Terminals) |
| `FORTRESS_FONT` | `unscii` | font for the fortress terminal only, set per-invocation; a square font un-stretches the map (see *Font*). Blank = terminal default |
| `FORTRESS_FONT_SIZE` | *(empty)* | point size for `FORTRESS_FONT`; empty = terminal default |
| `NEW_FORT_CHANCE` | `10` | % chance to embark a new fort vs. load a save |
| `SAVE_MAX_AGE_DAYS` | `30` | prune saves older than this |
| `FORTRESS_MODE` | `single` | `single` = one sim mirrored to all fortress outputs; `multi` = one sim per fortress output |
| `LOG_ON_SMALLER_HORIZONTAL` | `1` | with 2+ landscape outputs and no portrait one, put the log on the smallest landscape |
| `MIRROR_SIZE` | `largest` | shared tmux grid for non-`foot` terminals; `foot` pads/centers the fortress and always uses `largest` (see *Multiple displays*) |
| `SAVE_FLUSH_SECS` | `3` | wait after quicksave before quitting |
| `STOP_TIMEOUT` | `15` | grace period before SIGKILL on stop |
| `FISHBOWL_BACKEND` | *(auto)* | force `wayland` or `x11` |

### Multiple displays

Roles are assigned from output orientation:

- **One output** → always the **fortress**.
- **Portrait** outputs → **log**; **landscape** → **fortress**.
- **Two+ landscape and no portrait** → smallest landscape shows the **log**,
  the rest the fortress (disable with `LOG_ON_SMALLER_HORIZONTAL=0`).

In `single` mode all fortress outputs mirror one simulation via tmux. A terminal
fills each output under the lock and can't be pixel-scaled, so the fortresses
share **one** grid. With the default `foot`, the render step pads every fortress
terminal down to the smallest fortress output's grid: that screen fills exactly
and larger screens show the same grid **centered** (padding around it). Because
the per-screen grids can still differ by a cell or two (rounding), the shared
session uses tmux `window-size=largest`, which trims that as invisible edge
clipping rather than leaving asymmetric dot bands. `MIRROR_SIZE` selects the
shared grid only for terminals that can't pad. Because
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
  `fishbowl lock` (with `resume 'fishbowl stop'`), keeping your dim/suspend
  timeouts.

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
- **df-ai's config** — the one file fishbowl provides, [`df/df-ai.json`](df/df-ai.json)
  (autonomous random embarks + logging), is copied to `hack/df-ai.json`.
- **SDL 1.2 runtime libraries** — the DF binary links them even in TEXT mode:
  `sudo apt install libsdl1.2debian libsdl-image1.2 libsdl-ttf2.0-0`.
- **ncurses symlinks** — DF `dlopen`s `libncursesw.so`/`.so.5`, absent on
  modern distros. The installer symlinks them to `.so.6` inside
  `$DF_HOME/hack/libs` (on DF's own `LD_LIBRARY_PATH`); no root needed.

## Troubleshooting

- **Grey lock, no fortress** — the terminal failed to start; swaylock-plugin
  fell back to a plain (still working) password lock. Check
  `~/.cache/fishbowl-render.log`. Common causes: missing swaylock-plugin patch
  for your terminal, or DF not running.
- **Fortress off-centre / dots around it** — with `foot` the fortress is padded
  to a shared grid and centered; if it isn't, you're likely on an old
  swaylock-plugin without patch #1 (rebuild with the patches), or on a non-`foot`
  terminal (which can't pad — pick the trade-off with `MIRROR_SIZE`).
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

`fishbowl` itself just wires these together.

## License

[MIT](LICENSE) © 2026 Idril Geer. The bundled `patches/` are derivative of
swaylock-plugin and carry that project's (also MIT) copyright. fishbowl does not
redistribute Dwarf Fortress's or DFHack's own files — it edits the copies in
your own install (see below).

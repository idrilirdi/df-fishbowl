#!/usr/bin/env python3
"""Unit tests for lib/frame.sh --draw: the Dwarf Fortress scenery drawn around
the fortress popup, across screen shapes.

Checked for every (terminal W x H, popup COLS x ROWS) shape:
  shape   - exactly H rows, every row exactly W cells wide after stripping
            SGR/cursor escapes (a wrong width shifts every later row)
  width   - every glyph is single-width (a double-width one would break the
            square cell: the sun U+263C is not in unscii-8 and must never show)
  popup   - the popup rectangle, centred the way tmux centres `-x C -y C`, is
            blank, so nothing of the scenery leaks through under the fortress
  walls   - the smoothed-wall ring sits one cell outside the popup wherever it
            is on screen, with corners in the corners
  strata  - top-down: trees only in the sky, a grass row right above the top
            wall, soil (brown) directly under the grass, stone below that,
            magma only on the bottom rows and only when there is room
  title   - shown only when the sky has room, status message only when asked
"""
import re, subprocess, sys, unicodedata, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAME = os.path.join(ROOT, "lib", "frame.sh")
ESC = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
WALL = set("╔╗╚╝═║")
TREE = set("│♠")
GRASS = set("\"',.☺♣♀")
SOIL_GLYPHS = set("░▒▓•")
STONE_GLYPHS = set("░▒▓£*•")
MAGMA = "≈"
SUN = "☼"

fails = 0
def fail(msg):
    global fails
    fails += 1
    print("  FAIL:", msg)

def draw(W, H, C, R, msg=""):
    """Render one frame and return (rows, colour-per-cell rows)."""
    out = subprocess.run([FRAME, "--draw", str(W), str(H), str(C), str(R), msg],
                         capture_output=True, text=True, env={**os.environ, "TERM": "xterm"})
    if out.returncode != 0:
        fail(f"{W}x{H}/{C}x{R}: frame.sh exited {out.returncode}: {out.stderr.strip()}")
        return None, None
    # Replay the cursor-positioning and SGR stream into a cell grid + colour grid.
    rows = [[" "] * W for _ in range(H)]
    cols = [[""] * W for _ in range(H)]
    y = x = 0
    cur = ""
    pos = 0
    s = out.stdout
    token = re.compile(r"\x1b\[(\d+);(\d+)H|\x1b\[([0-9;]*)m")
    while pos < len(s):
        m = token.match(s, pos)
        if m:
            if m.group(1):
                y, x = int(m.group(1)) - 1, int(m.group(2)) - 1
            else:
                cur = m.group(3)
            pos = m.end()
            continue
        ch = s[pos]; pos += 1
        if ch == "\n":
            continue
        if 0 <= y < H and 0 <= x < W:
            rows[y][x] = ch; cols[y][x] = cur
        elif ch != " " or x >= W:
            fail(f"{W}x{H}/{C}x{R}: glyph {ch!r} written outside the grid at {x},{y}")
        x += 1
    return ["".join(r) for r in rows], cols

def check(W, H, C, R, msg=""):
    rows, colr = draw(W, H, C, R, msg)
    if rows is None:
        return
    tag = f"{W}x{H} popup {C}x{R}"
    x0, y0 = (W - C) // 2, (H - R) // 2
    x1, y1 = x0 + C - 1, y0 + R - 1
    gy = y0 - 2
    text = "".join(rows)
    for ch in set(text):
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            fail(f"{tag}: double-width glyph {ch!r}")
    if SUN in text:
        fail(f"{tag}: sun glyph present (not in unscii-8)")
    # popup area blank
    for y in range(y0, y1 + 1):
        if rows[y][x0:x1 + 1].strip():
            fail(f"{tag}: scenery under the popup on row {y}: {rows[y][x0:x1+1]!r}")
            break
    # wall ring where on screen
    def expect(y, x, glyphs, what):
        if 0 <= y < H and 0 <= x < W and rows[y][x] not in glyphs:
            fail(f"{tag}: {what} at {x},{y} is {rows[y][x]!r}")
    expect(y0 - 1, x0 - 1, "╔", "top-left corner"); expect(y0 - 1, x1 + 1, "╗", "top-right corner")
    expect(y1 + 1, x0 - 1, "╚", "bottom-left corner"); expect(y1 + 1, x1 + 1, "╝", "bottom-right corner")
    for x in range(x0, x1 + 1):
        expect(y0 - 1, x, "═", "top wall"); expect(y1 + 1, x, "═", "bottom wall")
    for y in range(y0, y1 + 1):
        expect(y, x0 - 1, "║", "left wall"); expect(y, x1 + 1, "║", "right wall")
    # strata, in the columns beside/above/below the popup
    titled = gy >= 4 and not msg
    for y in range(H):
        row = rows[y]
        if msg and y == 0:
            continue                      # the status line overwrites row 0
        outside = [(x, ch) for x, ch in enumerate(row) if not (x0 - 1 <= x <= x1 + 1 and y0 - 1 <= y <= y1 + 1)]
        glyphs = {ch for _, ch in outside}
        if y < gy:
            if titled and y == 1:
                if "Dwarf Fortress fishbowl" not in row:
                    fail(f"{tag}: title missing from the sky row")
                continue
            bad = glyphs - TREE - {" "}
            if bad:
                fail(f"{tag}: sky row {y} has non-tree glyphs {bad}")
        elif y == gy:
            bad = glyphs - GRASS
            if bad:
                fail(f"{tag}: grass row has {bad}")
            if " " in glyphs:
                fail(f"{tag}: grass row has gaps")
        elif y > gy and outside:
            d = y - gy
            bottom = H - 1 - gy
            if bottom - d < 2 and bottom >= 4:
                bad = glyphs - {MAGMA}
                if bad:
                    fail(f"{tag}: magma row {y} has {bad}")
            elif MAGMA in glyphs:
                fail(f"{tag}: magma above the bottom rows, row {y}")
            elif d <= 2:
                bad = glyphs - SOIL_GLYPHS
                if bad:
                    fail(f"{tag}: soil row {y} has {bad}")
                browns = {colr[y][x] for x, ch in outside if ch in "░▒"}
                if browns - {"33", "2;33"}:
                    fail(f"{tag}: soil row {y} not brown: {browns}")
            else:
                bad = glyphs - STONE_GLYPHS
                if bad:
                    fail(f"{tag}: stone row {y} has {bad}")
                if {colr[y][x] for x, ch in outside if ch == "▒"} & {"33"}:
                    fail(f"{tag}: brown soil in the stone, row {y}")
    # trees stand on the grass: every trunk column continues down to the grass row
    for y in range(max(0, (3 if titled else 0)), gy):
        for x, ch in enumerate(rows[y]):
            if ch == "│" and y + 1 < gy and rows[y + 1][x] not in "│":
                fail(f"{tag}: floating trunk at {x},{y}")
            if ch == "♠" and y + 1 < gy and rows[y + 1][x] not in "│♠" and rows[y + 1][x] != " ":
                fail(f"{tag}: canopy over non-tree at {x},{y}")
    if "Dwarf Fortress fishbowl" in text and not titled:
        fail(f"{tag}: title shown without room (gy={gy}, msg={msg!r})")
    if msg and msg not in rows[0]:
        fail(f"{tag}: status message missing from row 0")
    print(f"  ok  {tag:28s} sky {max(gy,0):2d} rows, below {max(H-1-y1-1,0):2d} rows, beside {x0:3d} cols")

# Shapes: (terminal grid, popup) in cells, as the exact fit produces them.
check(256, 160, 256, 144)       # laptop 2560x1600 at 10px, office grid (no side margin)
check(256, 144, 256, 144)       # 4K at 15px: popup covers everything
check(284, 177, 284, 177)       # laptop alone
check(320, 180, 284, 177)       # 4K under FORTRESS_REF=smallest: side margins
check(80, 30, 60, 20)           # small, margins all round
check(80, 32, 50, 14)           # big margins: title + tall trees + magma
check(100, 26, 90, 24)          # one-row margins: wall only, no grass
check(100, 28, 90, 24)          # two-row margins: wall + grass, no sky
check(101, 29, 90, 24)          # odd remainders
check(120, 40, 80, 25)          # DF minimum grid in a large terminal
check(80, 30, 60, 20, "Dwarf Fortress screensaver - waiting for DF...")

if fails:
    print(f"frame: {fails} failure(s)"); sys.exit(1)
print("frame: OK")

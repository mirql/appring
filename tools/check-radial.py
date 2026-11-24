#!/usr/bin/env python3
"""What the gallery's scene must show (tools/gallery.sh): the exact item
highlighted at several angles including a slice boundary, the dead zone, a
group's satellite opening three ways with the main ring still showing the
group, the satellite staying open through small jitters on its own button
and closing only two ways (back toward the main centre, or the main angle
clearly on another item) and only after a real grace, committing on its own
button going back to the main ring, commit by IPC and by click (arguments
passed exactly), Esc and a right click closing everything, the config re-read
on every open, named menus (a missing one is an empty ring), the centre
exactly on the cursor even at a corner, no in-between centre between two
opens, and the style cascade with one warning per unknown key.

    check-radial.py RADIAL.LOG RUNS.LOG QUICKSHELL.LOG GRACE_TIMING.LOG

RADIAL.LOG: lines of "STEP <state JSON>", from the scene's dump() helpers.
RUNS.LOG: one JSON argv array a line, from tools/fake-app.py.
QUICKSHELL.LOG: the ring's own log (its `appring state` lines, warnings).
GRACE_TIMING.LOG: one line "MOVE_T0 PENDING_T CLOSED_T" (epoch ms).

Exits 1, saying what differs, if a step, the runs, or the timing is wrong.
"""

import json
import re
import sys

# ── resolved styles (Radial.qml's `_baseStyle`/`_effectiveStyle`) ─────────
# In step with Theme.qml's defaults (radialButtonSize 48, radialGlowPad 10,
# radialMinRadius 110 (4 items or fewer), fontSmall 11, radialCornerFraction
# 0.14, radialSatelliteScale 0.8) and Radial.qml's `_baseStyle` (glowColor "auto",
# caption "none", backdrop false): if those change, this changes too.
def style(in_satellite=False, **overrides):
    if in_satellite:
        s = {"shape": "rounded-square", "cornerRadius": 0.14, "size": 38,
             "glowColor": "auto", "glowSize": 8, "ringRadius": 88,
             "captionSize": 9, "caption": "none", "backdrop": False}
    else:
        s = {"shape": "rounded-square", "cornerRadius": 0.14, "size": 48,
             "glowColor": "auto", "glowSize": 10, "ringRadius": 110,
             "captionSize": 11, "caption": "none", "backdrop": False}
    s.update(overrides)
    return s


def item(label, icon, kind, **style_overrides):
    return {"label": label, "icon": icon, "kind": kind, "style": style(**style_overrides)}


def sat_item(label, icon, kind, **style_overrides):
    return {"label": label, "icon": icon, "kind": kind, "style": style(in_satellite=True, **style_overrides)}


# appring/default.json's items: no style anywhere, so all plain defaults.
ROOT = [
    item("Firefox", "firefox", "leaf"),
    item("Terminal", "utilities-terminal", "leaf"),
    item("Files", "system-file-manager", "leaf"),
    item("Tools", "applications-utilities", "group"),
]

# The same, with the "labels": "all" setting.
ROOT_ALL = [dict(i, style=dict(i["style"], caption="all")) for i in ROOT]

# Tools' items, in order, at the satellite's scaled defaults.
TOOLS_SAT = [
    sat_item("Say hello", "dialog-information", "leaf"),
    sat_item("Calculator", "accessories-calculator", "leaf"),
    sat_item("System monitor", "utilities-system-monitor", "leaf"),
]

SOLO = [item("Solo", "applications-system", "leaf")]
SUB1 = [item("Sub1", "applications-utilities", "leaf")]

# menu-style.json's items: the global style sets glowColor "warn" and
# cornerRadius 0.3 (plus an unknown key, ignored); Danger and Round override
# glowColor and shape; Weird's style has only the unknown key.
STYLE_ROOT = [
    item("Safe", "applications-system", "leaf", cornerRadius=0.3, glowColor="warn"),
    item("Danger", "dialog-warning", "leaf", cornerRadius=0.3, glowColor="error"),
    item("Round", "applications-utilities", "leaf", cornerRadius=0.3, glowColor="warn", shape="circle"),
    item("Weird", "folder", "group", cornerRadius=0.3, glowColor="warn"),
]
# Weird's items: Child A gets the global style, Child B overrides glowColor.
WEIRD_SAT = [
    sat_item("Child A", "text-x-generic", "leaf", cornerRadius=0.3, glowColor="warn"),
    sat_item("Child B", "text-x-generic", "leaf", cornerRadius=0.3, glowColor="ok"),
]

# The scene's screen is 2400x1500 logical; every session except the corner
# and jump ones is opened with the cursor at its centre.
CX, CY = 1200, 750
# A satellite centres on its group's button: index 3 of 4 (270deg) at
# radius 110 is (CX - 110, CY), gallery.sh's ($satL, $cy).
SAT_CX, SAT_CY = CX - 110, CY
# Corner: opened right at (20, 15) — the centre, exactly, never clamped.
CORNER_X, CORNER_Y = 20, 15
# The jump test's two centres, used nowhere else in the scene.
JUMP_A = (1500, 500)
JUMP_B = (700, 1100)
SENTINEL = (-1, -1)   # Radial.qml's _close(): off-screen, unmistakable


def at(items, highlighted, dead_zone, cx=CX, cy=CY, visible=True, satellite=None):
    return {"visible": visible, "items": items, "highlighted": highlighted,
            "deadZone": dead_zone, "centreX": cx, "centreY": cy, "satellite": satellite}


def closed():
    return at([], -1, True, cx=SENTINEL[0], cy=SENTINEL[1], visible=False, satellite=None)


def sat(parent_index, items, highlighted, dead_zone, cx=SAT_CX, cy=SAT_CY):
    return {"parentIndex": parent_index, "items": items, "highlighted": highlighted,
            "deadZone": dead_zone, "centreX": cx, "centreY": cy}


# step -> expected state (tools/gallery.sh has the moves behind each one).
EXPECT = {
    "open-dead-zone": at(ROOT, -1, True),
    "highlight-firefox": at(ROOT, 0, False),
    "highlight-terminal": at(ROOT, 1, False),
    "highlight-files": at(ROOT, 2, False),
    "highlight-tools": at(ROOT, 3, False),
    "boundary-before": at(ROOT, 0, False),
    "boundary-after": at(ROOT, 1, False),
    "labels-all": at(ROOT_ALL, -1, True),
    "slice-gap": at(ROOT_ALL, -1, False),
    "slice-gap-cancelled": closed(),
    "dead-zone": at(ROOT, -1, True),
    "dead-zone-cancelled": closed(),
    "esc-cancelled": closed(),
    "right-click-cancelled": closed(),

    "satellite-opened-outer-radius": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),

    "satellite-jitter-1": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-jitter-2": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-jitter-3": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-jitter-4": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-jitter-5": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),

    "satellite-child-hello": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, 0, False)),
    "satellite-child-calculator": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, 1, False)),
    "satellite-child-monitor": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, 2, False)),

    "satellite-close-pending": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, 2, False)),
    "satellite-closed-via-main-deadzone": at(ROOT, -1, True, satellite=None),

    "satellite-opened-for-angle-close": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-closed-via-different-item": at(ROOT, 1, False, satellite=None),

    "satellite-opened-click": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-leaf-committed-ipc-setup": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, 0, False)),
    "satellite-leaf-committed-ipc": closed(),

    "satellite-opened-rest": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-leaf-committed-click": closed(),

    "satellite-stays-open-at-own-button": at(ROOT, 3, False, satellite=sat(3, TOOLS_SAT, -1, True)),
    "satellite-ascended-without-moving": at(ROOT, 3, False, satellite=None),
    "ascended-esc-cancelled": closed(),

    "leaf-committed-click": closed(),
    "leaf-committed-ipc-setup": at(ROOT, 0, False),
    "leaf-committed-ipc": closed(),

    "reread-custom": at(SOLO, -1, True),
    "named-menu": at(SUB1, -1, True),
    "named-missing": at([], -1, True),
    "closed-by-old-target": closed(),
    # No APPRING_CONFIG_DIR: only the old ~/.config/ring-app -> read; both -> appring wins.
    "old-config-folder": at([item("Old", "folder", "leaf")], -1, True),
    "new-config-folder-wins": at([item("New", "folder", "leaf")], -1, True),

    "corner-open-exact-centre": at(ROOT, -1, True, cx=CORNER_X, cy=CORNER_Y),
    "corner-highlight-right": at(ROOT, 1, False, cx=CORNER_X, cy=CORNER_Y),

    "jump-open-a": at(ROOT, -1, True, cx=JUMP_A[0], cy=JUMP_A[1]),
    "jump-closed": closed(),
    "jump-open-b": at(ROOT, -1, True, cx=JUMP_B[0], cy=JUMP_B[1]),

    "style-safe": at(STYLE_ROOT, 0, False),
    "style-danger": at(STYLE_ROOT, 1, False),
    "style-round": at(STYLE_ROOT, 2, False),
    "style-weird": at(STYLE_ROOT, 3, False),
    "style-weird-satellite-opened": at(STYLE_ROOT, 3, False, satellite=sat(3, WEIRD_SAT, -1, True)),
    "style-child-a": at(STYLE_ROOT, 3, False, satellite=sat(3, WEIRD_SAT, 0, False)),
    "style-child-b": at(STYLE_ROOT, 3, False, satellite=sat(3, WEIRD_SAT, 1, False)),
}

# The runs the commits must have made, in order: "Say hello" (IPC; its
# arguments contain spaces and must arrive as they are), "System monitor"
# (click), then "Firefox" twice (click, then IPC). Nothing in default.json
# changes anything on the machine: a gesture menu's default must be safe to
# fire by accident.
EXPECTED_RUNS = [
    ["notify-send", "appring", "Hello from the ring"],
    ["gnome-system-monitor"],
    ["firefox"],
    ["firefox"],
]


def check_no_transitional_centre(quickshell_text):
    """The centre is never animated: between the jump test's close and its
    second open, the log's centres are only the sentinel and the new value,
    never an in-between one."""
    states = [json.loads(m) for m in re.findall(r"appring state (\{.*\})", quickshell_text)]
    centres = [(s["centreX"], s["centreY"]) for s in states]   # tuples of ints throughout
    try:
        a_at = centres.index(JUMP_A)
    except ValueError:
        return False, "JUMP_A's own centre was never logged"
    try:
        sentinel_at = next(i for i in range(a_at, len(centres)) if centres[i] == SENTINEL)
    except StopIteration:
        return False, "the sentinel (-1, -1) was never logged after jump-open-a"
    try:
        b_at = next(i for i in range(sentinel_at, len(centres)) if centres[i] == JUMP_B)
    except StopIteration:
        return False, "JUMP_B's own centre was never logged after the sentinel"
    between = centres[sentinel_at:b_at + 1]
    stray = set(between) - {SENTINEL, JUMP_B}
    if stray:
        return False, f"a third centre appeared between the sentinel and jump-open-b: {sorted(stray)}"
    return True, f"{len(between)} states between the sentinel and jump-open-b, only {{{SENTINEL}, {JUMP_B}}}"


def check_unknown_key_warning(quickshell_text):
    """An unknown key gives one warning, never a crash. "notAKey" appears
    twice in menu-style.json, so this also proves one warning per key per
    load, not per occurrence."""
    hits = re.findall(r'appring: unknown style key "notAKey"', quickshell_text)
    if len(hits) != 1:
        return False, f"expected exactly one \"notAKey\" warning, found {len(hits)}"
    return True, "exactly one warning for a key that appears twice in the config"


# RING_APP_CLOSE_MS (the old name of APPRING_CLOSE_MS) as tools/gallery.sh sets it (the default is 150).
GRACE_MS = 2000


def check_close_grace(timing_path):
    """The close grace is a real delay: "satellite-close-pending" (still
    open, checked in EXPECT) landed inside it, the closed checkpoint after."""
    try:
        with open(timing_path) as f:
            move_t0, pending_t, closed_t = (int(x) for x in f.read().split())
    except (FileNotFoundError, ValueError) as e:
        return False, f"{timing_path} missing or malformed ({e})"
    pending_elapsed = pending_t - move_t0
    closed_elapsed = closed_t - move_t0
    if pending_elapsed >= GRACE_MS:
        return False, (f"the pending checkpoint itself arrived at +{pending_elapsed}ms, "
                        f"already past the {GRACE_MS}ms grace -- not a real proof, rerun")
    if closed_elapsed < GRACE_MS:
        return False, f"closed at +{closed_elapsed}ms, before the {GRACE_MS}ms grace elapsed -- closed too early"
    return True, f"pending at +{pending_elapsed}ms (< {GRACE_MS}ms), closed at +{closed_elapsed}ms (>= {GRACE_MS}ms)"


def main(radial_path, runs_path, quickshell_path, timing_path):
    got = {}
    with open(radial_path) as f:
        for line in f:
            step, _, data = line.strip().partition(" ")
            if step:
                got[step] = data

    bad = 0
    for step, want in EXPECT.items():
        raw = got.get(step)
        try:
            have = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            have = raw
        if have != want:
            bad += 1
            print(f"radial: step {step} differs\n  want {json.dumps(want)}\n  have {json.dumps(have)}")
        else:
            print(f"radial: step {step} ok")

    missing_steps = [s for s in EXPECT if s not in got]
    if missing_steps:
        bad += 1
        print(f"radial: steps never logged: {missing_steps}")

    try:
        with open(runs_path) as f:
            runs = [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        runs = []
    if runs != EXPECTED_RUNS:
        bad += 1
        print(f"radial: runs differ\n  want {EXPECTED_RUNS}\n  have {runs}")
    else:
        print("radial: runs ok (arguments exact, nothing else started)")

    quickshell_text = open(quickshell_path).read()

    ok, detail = check_no_transitional_centre(quickshell_text)
    if ok:
        print(f"radial: no transitional centre between two opens ({detail})")
    else:
        bad += 1
        print(f"radial: transitional centre check failed: {detail}")

    ok, detail = check_unknown_key_warning(quickshell_text)
    if ok:
        print(f"radial: unknown style key warning ok ({detail})")
    else:
        bad += 1
        print(f"radial: unknown style key warning check failed: {detail}")

    hints = len(re.findall(r"appring: reading the old config folder", quickshell_text))
    if hints != 1:
        bad += 1
        print(f"radial: expected the old-folder hint exactly once (only the old folder there), found {hints}")
    else:
        print("radial: the old config folder hint shows once, and only with the old folder alone")

    ok, detail = check_close_grace(timing_path)
    if ok:
        print(f"radial: close grace is real, not a no-op ({detail})")
    else:
        bad += 1
        print(f"radial: close grace check failed: {detail}")

    errors = re.findall(r".*(?:TypeError|ReferenceError|Unable to assign|Failed to load|binding loop).*",
                         quickshell_text)
    if errors:
        bad += 1
        print("radial: QML errors logged:\n" + "\n".join(errors))
    else:
        print("radial: no QML errors")

    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]))

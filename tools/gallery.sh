#!/usr/bin/env bash
# The gallery: draw the ring off-screen, drive it with a virtual pointer,
# take screenshots, and check every step (tools/check-radial.py).
#
# Never the real desktop. The scene gets its own everything: a headless sway
# (one output) in a private XDG_RUNTIME_DIR, so its Wayland socket cannot be
# the session's; a private D-Bus (dbus-run-session); a fake Hyprland IPC
# (tools/fake-hyprland.py) under a made-up signature, so the ring's
# "which monitor is focused" reads a fixture. Every session variable that
# could reach the desktop is replaced, and the scene aborts if the display
# it got is not inside its own runtime dir. Every app a commit runs is a
# fake (tools/fake-app.py) that only logs its argv.
#
#   nix develop -c ./tools/gallery.sh           # -> /tmp/appring-gallery/*.png
#   GALLERY_OUT=/tmp/g2 ./tools/gallery.sh      # a parallel run needs its own dir
#
# Needs, from `nix develop`: quickshell, sway, grim, wtype, python3 with
# pywayland, and RING_GALLERY_WLR_PROTOCOLS, RING_GALLERY_WAYLAND_XML,
# RING_GALLERY_FONTS, RING_GALLERY_ICONS.
#
# What the scene covers: angles including a slice boundary, the dead zone,
# a group's satellite opening three ways (resting, a click, past the outer
# radius) with the main ring dimmed behind it, the satellite staying open
# through small jitters and closing only after its grace, commit by IPC and
# by click (arguments passed exactly), Esc and right-click cancel, the
# config re-read on every open, named menus, the centre exactly on the
# cursor (never clamped, no in-between frame between two opens), and the
# style cascade.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${GALLERY_OUT:-/tmp/appring-gallery}"

# Bound the whole run and reap every helper, even on an interruption.
if [ "${1:-}" != --scene ] && [ "${1:-}" != --supervised ]; then
  exec python3 "$HERE/tools/check-process.py" --timeout 1800 bash "$0" --supervised "$@"
fi
[ "${1:-}" != --supervised ] || shift

if [ "${1:-}" != "--scene" ]; then
  for tool in quickshell sway grim wtype python3 dbus-run-session; do
    command -v "$tool" >/dev/null || { echo "gallery: $tool not on PATH (run inside 'nix develop')" >&2; exit 2; }
  done
  for var in RING_GALLERY_WLR_PROTOCOLS RING_GALLERY_WAYLAND_XML RING_GALLERY_FONTS RING_GALLERY_ICONS; do
    [ -n "${!var:-}" ] || { echo "gallery: $var is not set (run inside 'nix develop')" >&2; exit 2; }
  done
  python3 -c 'import pywayland' 2>/dev/null || { echo "gallery: python3 has no pywayland (run inside 'nix develop')" >&2; exit 2; }

  # The private bus uses dbus's own session config, next to its binary:
  # not every system (or sandbox) has /etc/dbus-1.
  DBUS_CONF="$(dirname "$(readlink -f "$(command -v dbus-run-session)")")/../share/dbus-1/session.conf"
  [ -f "$DBUS_CONF" ] || DBUS_CONF=/etc/dbus-1/session.conf

  rm -rf "$OUT"; mkdir -p "$OUT/radial"
  echo "── scene radial"
  # A clean environment: nothing of the session's comes through but PATH,
  # HOME, the locale and the dev shell's data paths.
  fail=0
  env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
    RING_GALLERY_WLR_PROTOCOLS="$RING_GALLERY_WLR_PROTOCOLS" RING_GALLERY_WAYLAND_XML="$RING_GALLERY_WAYLAND_XML" \
    RING_GALLERY_FONTS="$RING_GALLERY_FONTS" RING_GALLERY_ICONS="$RING_GALLERY_ICONS" \
    G_HERE="$HERE" G_OUT="$OUT" QT_LOGGING_RULES="${QT_LOGGING_RULES:-}" \
    python3 "$HERE/tools/check-process.py" --timeout 1800 \
    dbus-run-session --config-file="$DBUS_CONF" -- "$0" --scene radial || { echo "scene radial failed"; fail=1; }
  echo "screenshots: $OUT"
  ls "$OUT"/*.png 2>/dev/null | sed 's/^/  /'
  exit $fail
fi

# ── the scene, inside its private bus ─────────────────────────────────────
SCENE="$2"
D="$G_OUT/$SCENE"
RUN="$D/run"; mkdir -p "$RUN"; chmod 700 "$RUN"
export XDG_RUNTIME_DIR="$RUN"
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK
case "${DBUS_SESSION_BUS_ADDRESS:-}" in
  *"/run/user/"*|"") echo "ABORT: not on a private bus"; exit 1 ;;
esac

export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
# The runtime dir already includes the scene; keep Unix socket paths below 108 bytes.
SIG="gallery_$$"
HYPR="$RUN/hypr/$SIG"
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Fonts and icons from the dev shell, whatever the machine has installed.
cat > "$D/fonts.conf" <<EOF
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>$(for f in ${RING_GALLERY_FONTS//:/ }; do echo "<dir>$f/share/fonts</dir>"; done)
<cachedir>$D/fontcache</cachedir></fontconfig>
EOF
export FONTCONFIG_FILE="$D/fonts.conf"
export XDG_DATA_DIRS="$RING_GALLERY_ICONS/share"
export QS_ICON_THEME="Papirus-Dark"
export XDG_DATA_HOME="$D/data" XDG_STATE_HOME="$D/state" XDG_CONFIG_HOME="$D/config"

# ── the fake Hyprland ───────────────────────────────────────────────────
python3 "$G_HERE/tools/fake-hyprland.py" "$G_HERE/tools/fixtures/one.json" "$HYPR" \
  > "$D/fake-hyprland.log" 2>&1 &
pids+=($!)
for _ in $(seq 40); do [ -S "$HYPR/.socket2.sock" ] && break; sleep 0.1; done

# ── the headless sway ────────────────────────────────────────────────────
# One output, the size the coordinates below and check-radial.py assume
# (2880x1800 at 1.2 = 2400x1500 logical). A mid-tone background so the
# ring's translucency shows.
{
  echo "output HEADLESS-1 resolution 2880x1800 position 0 0 scale 1.2 bg #4c566a solid_color"
  echo "default_border none"
  echo "exec env > $D/sway.env"
} > "$D/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
  sway --config "$D/sway.conf" > "$D/sway.log" 2>&1 &
pids+=($!)
disp=""
for _ in $(seq 60); do
  disp=$(sed -n 's/^WAYLAND_DISPLAY=//p' "$D/sway.env" 2>/dev/null || true)
  [ -n "$disp" ] && break; sleep 0.25
done
# Fail closed: the display must be a socket in this scene's own runtime dir.
if [ -z "$disp" ] || [ ! -S "$RUN/$disp" ]; then echo "ABORT: no isolated display"; exit 1; fi
export WAYLAND_DISPLAY="$disp"
export SWAYSOCK; SWAYSOCK=$(sed -n 's/^SWAYSOCK=//p' "$D/sway.env")

# ── the ring's settings for this scene ───────────────────────────────────
# Its own config directory, empty at first (no menu.json: the default.json
# fallback), and a fake for every app default.json runs, first on PATH.
mkdir -p "$D/ring-config" "$D/bin"
export APPRING_CONFIG_DIR="$D/ring-config"
# Groups open as satellites for most of the scene (the "groups" setting): the
# satellite steps below test that mode; the nested-ring part near the end
# switches to the default, "rotate".
printf '{ "groups": "satellite" }\n' > "$APPRING_CONFIG_DIR/appearance.json"
case "$APPRING_CONFIG_DIR" in "$D/"*) ;; *) echo "ABORT: APPRING_CONFIG_DIR is not the scene's own"; exit 1 ;; esac
# Far past a synthetic pointer's move+click latency (~0.3-0.5s through
# tools/pointer.py), so "a click opens a group" and "resting opens it" test
# two different triggers, not a race the 250ms default would always win.
export APPRING_REST_MS=1500
# The same for the satellite's close grace: a checkpoint right after a
# closing move proves it is still open, a later one that it closed. Kept
# in step with check-radial.py's GRACE_MS. Set under its old name on
# purpose: the old RING_APP_* names must keep working.
export RING_APP_CLOSE_MS=2000
# And the ghost ring's delay, far past the pointer's latency, so a step right
# after pointing at a group still sees no ghost, and a later one sees it.
export APPRING_GHOST_MS=1500
for app in firefox xdg-terminal-exec nautilus notify-send gnome-calculator gnome-system-monitor; do
  printf '#!/bin/sh\nexec python3 "%s" %s "$@"\n' "$G_HERE/tools/fake-app.py" "$app" > "$D/bin/$app"
  chmod +x "$D/bin/$app"
done
export PATH="$D/bin:$PATH"
export FAKE_APP_LOG="$D/radial-runs.log"
: > "$FAKE_APP_LOG"
: > "$D/radial.log"

# ── the ring ──────────────────────────────────────────────────────────────
ROOT="$G_HERE/appring"
HYPRLAND_INSTANCE_SIGNATURE="$SIG" APPRING_DUMP=1 QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
  quickshell -p "$ROOT" > "$D/quickshell.log" 2>&1 &
QS_PID=$!
pids+=($!)
sleep 4

shot() { grim -g "$2" "$G_OUT/$1.png"; }
# One virtual pointer for the whole scene, fed through a pipe.
mkfifo "$D/pointer.in"
python3 "$G_HERE/tools/pointer.py" "$RING_GALLERY_WLR_PROTOCOLS" "$RING_GALLERY_WAYLAND_XML" 2400 1500 \
  < "$D/pointer.in" > "$D/pointer.log" 2>&1 &
pids+=($!)
exec 3> "$D/pointer.in"
ptr() { echo "$*" >&3; sleep 0.15; }
at() { ptr move "$1" "$2"; sleep 0.2; }
click() { ptr click "$1"; }

# A fresh `quickshell ipc` call per step. dump() appends the last state line
# the ring logged (APPRING_DUMP=1) under a step name; check-radial.py holds
# what each step must show.
ipc() { quickshell ipc -p "$ROOT" call appring "$@" >/dev/null 2>&1; sleep 0.3; }
last_state() { grep -o 'appring state .*' "$D/quickshell.log" | tail -n 1 | sed 's/^appring state //' || echo; }
dump() { sleep 0.6; { printf '%s ' "$1"; last_state; } >> "$D/radial.log"; }
# For checkpoints that must land inside the (raised) close grace: a much
# shorter, but still real, settle.
quick_dump() { sleep 0.1; { printf '%s ' "$1"; last_state; } >> "$D/radial.log"; }
key() { wtype -s 150 "$@" -s 100; sleep 0.3; }

# HEADLESS-1's logical centre (2400x1500).
cx=1200; cy=750
up=$((cy - 150)); down=$((cy + 150)); left=$((cx - 150)); right=$((cx + 150))
farleft=$((cx - 300))            # past the outer radius (110+70=180): opens a group by itself
# Firefox's and Terminal's sectors (4 items: 90deg each), 18deg either side
# of their border at 45deg, at radius ~150: still inside them when the
# "Gap between slices" setting is on (below).
b0x=$((cx + 68)); b0y=$((cy - 134))   # 27deg: still Firefox
b1x=$((cx + 134)); b1y=$((cy - 68))   # 63deg: Terminal
# A group's satellite centres on its own button: with 4 items the ring's
# radius is 110 (its minimum), so the item at index 3 (270deg) sits at
# ($satL, $cy). The points below were worked out against Radial.qml's angle
# formula: each stays inside the main ring's "still this group" sector,
# except satClose, which lands inside the main ring's dead zone on purpose.
satL=$((cx - 110))
satUp=$((cy - 90))                       # satellite 0deg: its first item
satMidX=$((satL + 60)); satMidY=$((cy + 60))   # satellite ~135deg: its second item
satLastX=$((satL - 64)); satLastY=$((cy + 64))   # satellite 225deg: its last item (3 items: 240deg, 2 items: 180deg)
satCloseX=$((cx - 30))                   # 30px left of the main centre: inside its dead zone (40px)
# A throwaway move used right after a satellite opens (see below): outside
# both dead zones, still in the main ring's Tools sector.
satDispX=$((cx - 250)); satDispY=$cy

# Open by IPC: no menu.json yet, so default.json's items; nothing highlighted
# before the pointer moves.
at $cx $cy
ipc open ""
# Move again once the window is surely listening: a layer surface's first
# pointer-enter is not reliable for an exact position.
at $cx $cy
dump open-dead-zone
shot radial-open "900,375 600x750"

# One angle per item (0 up, clockwise), then both sides of a boundary.
at $cx $up;    dump highlight-firefox
shot radial-highlight "900,375 600x750"
at $right $cy; dump highlight-terminal
at $cx $down;  dump highlight-files
at $left $cy;  dump highlight-tools
at $b0x $b0y;  dump boundary-before
at $b1x $b1y;  dump boundary-after
# The appearance settings (appearance.json, read when it changes): labels
# for every slice show in the resolved style; with a gap between slices,
# exactly on a border (45deg) nothing is highlighted, and committing there
# runs nothing. Then back to the defaults.
ipc cancel
printf '{ "labels": "all", "sliceGap": 0.33, "groups": "satellite" }\n' > "$APPRING_CONFIG_DIR/appearance.json"
sleep 1
at $cx $cy
ipc open ""
at $cx $cy
dump labels-all
at $((cx + 106)) $((cy - 106)); dump slice-gap
ipc commit
dump slice-gap-cancelled
printf '{ "labels": "none", "sliceGap": 0, "groups": "satellite" }\n' > "$APPRING_CONFIG_DIR/appearance.json"
sleep 1
at $cx $cy
ipc open ""
at $cx $cy

# The dead zone: nothing highlighted; committing there cancels, nothing runs.
at $((cx + 20)) $cy; dump dead-zone
ipc commit
dump dead-zone-cancelled

# Esc and a right click cancel too; still nothing runs.
ipc open ""
at $cx $cy
at $cx $up
key -k Escape
dump esc-cancelled
ipc open ""
at $cx $cy
at $cx $up
click right
dump right-click-cancelled

# The satellite, first way in: past the main ring's outer radius.
ipc open ""
at $cx $cy
at $farleft $cy
dump satellite-opened-outer-radius
# The first pointer move right after the satellite's items are built is
# sometimes lost by the synthetic pointer: a throwaway move first, never
# asserted.
at $satDispX $satDispY

# On or near the group's own button (1.2x its size), the satellite stays
# open and nothing inside is highlighted, across several 1-5px jitters.
at $((satL + 2)) $cy;              dump satellite-jitter-1
at $((satL - 3)) $((cy + 1));      dump satellite-jitter-2
at $((satL + 1)) $((cy - 2));      dump satellite-jitter-3
at $((satL - 2)) $((cy + 4));      dump satellite-jitter-4
at $satL $cy;                      dump satellite-jitter-5

at $satL $satUp;              dump satellite-child-hello
shot radial-satellite-open "900,375 600x750"
at $satMidX $satMidY;         dump satellite-child-calculator
at $satLastX $satLastY;           dump satellite-child-monitor

# Back toward the main centre closes it, but only once the grace has passed:
# one checkpoint inside the grace (still open), one well past it (closed).
graceT0=$(date +%s%3N)
at $satCloseX $cy
quick_dump satellite-close-pending
pendingT=$(date +%s%3N)
sleep 2.5
dump satellite-closed-via-main-deadzone
closedT=$(date +%s%3N)
printf '%s %s %s\n' "$graceT0" "$pendingT" "$closedT" > "$D/radial-grace-timing.log"

# The other way it closes: the main angle clearly on another item.
# ($b1x, $b1y) is in Terminal's slice, ~140deg from Tools' 270deg (past the
# 45+15=60deg margin), at radius ~150, so only the angle condition holds.
ipc open ""
at $cx $cy
at $left $cy
click left
dump satellite-opened-for-angle-close
at $satDispX $satDispY   # throwaway, as above
at $b1x $b1y
sleep 2.5
dump satellite-closed-via-different-item

# Second way in: a click on the group. Committing a satellite item by IPC
# runs it (its arguments contain spaces: they must arrive as they are).
ipc open ""
at $cx $cy
at $left $cy
click left
dump satellite-opened-click
at $satDispX $satDispY   # throwaway, as above
at $satL $satUp
dump satellite-leaf-committed-ipc-setup
ipc commit
dump satellite-leaf-committed-ipc
sleep 0.3

# Third way in: resting on the group past APPRING_REST_MS, with neither a
# click nor crossing the outer radius. A click commits the highlighted item.
ipc open ""
at $cx $cy
at $left $cy
sleep 1.8
dump satellite-opened-rest
at $satDispX $satDispY   # throwaway
at $satLastX $satLastY
click left
dump satellite-leaf-committed-click
sleep 0.3

# Hovering the satellite's own button keeps it open, nothing inside
# highlighted...
ipc open ""
at $cx $cy
at $farleft $cy
at $satDispX $satDispY   # throwaway, as above
at $satL $cy
dump satellite-stays-open-at-own-button

# ...and committing there goes back to the main ring (the menu stays open),
# while Esc closes everything.
ipc commit
dump satellite-ascended-without-moving
key -k Escape
dump ascended-esc-cancelled

# A plain item commits by click and by IPC. `ipc open` rebuilds the main
# ring's items too: a throwaway move after each open, as above.
ipc open ""
at $cx $cy
at $right $cy   # throwaway
at $cx $up
click left
dump leaf-committed-click
sleep 0.3
ipc open ""
at $cx $cy
at $right $cy   # throwaway
at $cx $up
dump leaf-committed-ipc-setup
ipc commit
dump leaf-committed-ipc
sleep 0.3

# The config is re-read on every open: a file written now is what the next
# open shows.
cat > "$APPRING_CONFIG_DIR/menu.json" <<'MENUJSON'
[{ "label": "Solo", "icon": "applications-system", "run": ["echo", "solo item"] }]
MENUJSON
at $cx $cy
ipc open ""
at $cx $cy
dump reread-custom

# Named menus: open("sub") reads menu-sub.json; open("missing") with no file
# is an empty ring, never default.json and never a crash.
cat > "$APPRING_CONFIG_DIR/menu-sub.json" <<'MENUJSON'
[{ "label": "Sub1", "icon": "applications-utilities", "run": ["true"] }]
MENUJSON
at $cx $cy
ipc open "sub"
at $cx $cy
dump named-menu
at $cx $cy
ipc open "missing"
at $cx $cy
dump named-missing
# through the old IPC target "ring" (from the old name): key binds keep working
quickshell ipc -p "$ROOT" call ring cancel >/dev/null 2>&1; sleep 0.3
dump closed-by-old-target

# The centre is exactly the cursor, never clamped: opened at a corner, part
# of the ring is off-screen, and a direction reachable from there still
# selects. Back to default.json first (four items, to have an angle at all).
rm -f "$APPRING_CONFIG_DIR/menu.json"
at 20 15
ipc open ""
at 20 15
dump corner-open-exact-centre
at $((20 + 150)) 15
dump corner-highlight-right
ipc cancel

# The centre jumps straight to a new position between two opens: no
# animation of the centre, reset to (-1, -1) on close. These two centres are
# used nowhere else, so check-radial.py can read the raw log's sequence.
at 1500 500
ipc open ""
at 1500 500
dump jump-open-a
ipc cancel
dump jump-closed
at 700 1100
ipc open ""
at 700 1100
dump jump-open-b
ipc cancel

# The style cascade: a global style, per-item overrides (glow colour,
# shape), a group's style reaching its satellite's items unless they set
# their own, and one unknown key ("notAKey", twice) giving exactly one
# warning. Same 4-item geometry as default.json, so the satellite points
# above still apply.
cat > "$APPRING_CONFIG_DIR/menu-style.json" <<'MENUJSON'
{
  "style": { "glowColor": "warn", "cornerRadius": 0.3, "notAKey": 1 },
  "items": [
    { "label": "Safe", "icon": "applications-system", "run": ["true"] },
    { "label": "Danger", "icon": "dialog-warning", "run": ["true"], "style": { "glowColor": "error" } },
    { "label": "Round", "icon": "applications-utilities", "run": ["true"], "style": { "shape": "circle" } },
    { "label": "Weird", "icon": "folder", "run": ["true"], "style": { "notAKey": 123 }, "items": [
        { "label": "Child A", "icon": "text-x-generic", "run": ["true"] },
        { "label": "Child B", "icon": "text-x-generic", "run": ["true"], "style": { "glowColor": "ok" } }
    ] }
  ]
}
MENUJSON
at $cx $cy
ipc open "style"
at $cx $cy
at $cx $up;    dump style-safe
at $right $cy; dump style-danger
at $cx $down;  dump style-round
at $left $cy;  dump style-weird
shot radial-style "900,375 600x750"
at $farleft $cy
# quick_dump: a single move can arrive as more than one event under load,
# and a later look may already see the settled position.
quick_dump style-weird-satellite-opened
at $satDispX $satDispY   # throwaway, as above
at $satL $satUp;     dump style-child-a
shot radial-satellite-style "900,375 600x750"
at $satLastX $satLastY;  dump style-child-b
ipc cancel

# Nested rings, the default ("groups": "rotate"), pointing at Tools' own
# button ($satL: further out is "past" it): the Tools group shows one
# of its items (its face) and runs it; resting on it shows the ghost ring;
# the wheel turns to the next item; the face stays for the next open; the
# middle button jumps into the group (the ring switches to its items) and Esc
# goes back, then closes.
printf '{ "groups": "rotate" }\n' > "$APPRING_CONFIG_DIR/appearance.json"
sleep 1
at $cx $cy
ipc open ""
at $cx $cy
at $right $cy   # throwaway: the first move after an open
at $satL $cy;  quick_dump rotate-face
sleep 1.6;     dump rotate-ghost
shot nested-ghost "700,375 900x750"
ptr scroll 1
dump rotate-wheel
# Out past Tools' button into its ghost ring (3 items: radius 34, centre
# 147px left of the main centre; its first slot, pointing back, is Tools'
# own button), at its second slot (210deg): System monitor, after the turn.
at $((cx - 164)) $((cy + 29)); dump ghost-pick
shot nested-ghost-pick "700,375 900x750"
ipc commit
dump ghost-ran
sleep 0.3
at $cx $cy
ipc open ""
at $cx $cy
at $right $cy   # throwaway
at $satL $cy;  dump rotate-remembered
click middle
dump jumped
shot nested-jumped "900,375 600x750"
key -k Escape
dump jumped-back
key -k Escape
dump nested-closed
# releasing on the group runs its face
at $cx $cy
ipc open ""
at $cx $cy
at $right $cy   # throwaway
at $satL $cy
ipc commit
dump face-ran
# Two groups with the same label keep their own faces (a face is kept by the
# group's place); a group inside a group, with a bad entry, still opens.
cat > "$APPRING_CONFIG_DIR/menu-nest.json" <<'MENUJSON'
[
  { "label": "Plain", "icon": "folder", "run": ["notify-send", "plain"] },
  { "label": "Twin", "icon": "folder", "items": [
    { "label": "Inner", "icon": "folder", "items": [
      null,
      { "label": "Leaf", "icon": "text-x-generic", "run": ["notify-send", "leaf"] }
    ] },
    { "label": "B", "icon": "text-x-generic", "run": ["notify-send", "b"] }
  ] },
  { "label": "Plain 2", "icon": "folder", "run": ["notify-send", "plain 2"] },
  { "label": "Twin", "icon": "folder", "items": [
    { "label": "C", "icon": "text-x-generic", "run": ["notify-send", "c"] },
    { "label": "D", "icon": "text-x-generic", "run": ["notify-send", "d"] }
  ] }
]
MENUJSON
at $cx $cy
ipc open "nest"
at $cx $cy
at $cx $down   # throwaway
at $satL $cy
ptr scroll 1
dump twin-turned
at $right $cy
click middle
at $cx $up
dump twin-jumped
click middle
dump inner-jumped
key -k Escape
key -k Escape
key -k Escape
dump nest-closed
# A group picked from a ghost ring opens: the first Twin (right) turned to B,
# so its ghost ring (2 slots, radius 34, centre 147px right of the main
# centre; slot 0 points back) holds Inner, 181px right of the centre.
at $cx $cy
ipc open "nest"
at $cx $cy
at $cx $down   # throwaway
at $((cx + 110)) $cy
ptr scroll 1
sleep 1.6
at $((cx + 181)) $cy; dump ghost-group-pick
ipc commit
dump ghost-group-jumped
key -k Escape
at $cx $down;  dump ghost-group-back
key -k Escape
key -k Escape
dump ghost-group-closed
# toggle closes from inside a group, not one ring back
at $cx $cy
ipc open "nest"
at $cx $cy
at $cx $down   # throwaway
at $right $cy
click middle
at $cx $up;  dump toggle-jumped
ipc toggle ""
dump toggle-closed
printf '{ "groups": "satellite" }\n' > "$APPRING_CONFIG_DIR/appearance.json"
sleep 1

# The settings window: opens over IPC, draws its preview, closes again.
ipc settings
sleep 1.5
shot settings "0,0 2400x1500"
ipc settings

# Which config folder, with no APPRING_CONFIG_DIR: the ring is restarted
# twice, each time reading a folder of its own config home. With only the old
# ~/.config/ring-app it reads that (and says once it can be moved); with both,
# ~/.config/appring wins.
restart_with_config_home() {
  kill "$QS_PID" 2>/dev/null || true; wait "$QS_PID" 2>/dev/null || true
  env -u APPRING_CONFIG_DIR XDG_CONFIG_HOME="$1" HYPRLAND_INSTANCE_SIGNATURE="$SIG" APPRING_DUMP=1 \
    QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
    quickshell -p "$ROOT" >> "$D/quickshell.log" 2>&1 &
  QS_PID=$!
  pids+=($!)
  sleep 4
}
mkdir -p "$D/home-old/ring-app" "$D/home-both/ring-app" "$D/home-both/appring"
echo '[{ "label": "Old", "icon": "folder", "run": ["true"] }]' > "$D/home-old/ring-app/menu.json"
echo '[{ "label": "Old", "icon": "folder", "run": ["true"] }]' > "$D/home-both/ring-app/menu.json"
echo '[{ "label": "New", "icon": "folder", "run": ["true"] }]' > "$D/home-both/appring/menu.json"
restart_with_config_home "$D/home-old"
at $cx $cy
ipc open ""
at $cx $cy
dump old-config-folder
ipc cancel
restart_with_config_home "$D/home-both"
at $cx $cy
ipc open ""
at $cx $cy
dump new-config-folder-wins
ipc cancel
# A menu read while open (here: ~/.config/appring appears, so the folder
# changes) starts at the new menu's top: the ghost ring showing, or the ring
# jumped into, goes, and Esc cannot go back into the old menu.
mkdir -p "$D/home-late/ring-app"
cat > "$D/home-late/ring-app/menu.json" <<'MENUJSON'
[
  { "label": "Old", "icon": "folder", "run": ["true"] },
  { "label": "Old group", "icon": "folder", "items": [
    { "label": "Old A", "icon": "text-x-generic", "run": ["true"] },
    { "label": "Old B", "icon": "text-x-generic", "run": ["true"] }
  ] }
]
MENUJSON
new_menu() {
  mkdir -p "$D/home-late/appring"
  echo '[{ "label": "New", "icon": "folder", "run": ["true"] }]' > "$D/home-late/appring/menu.json"
}
restart_with_config_home "$D/home-late"
at $cx $cy
ipc open ""
at $cx $cy
at $right $cy   # throwaway
at $cx $down
sleep 1.6;  dump late-ghost
new_menu
sleep 1;    dump late-read-ghost
rm -rf "$D/home-late/appring"
sleep 1
click middle
dump late-jumped
new_menu
sleep 1;    dump late-read-jumped
key -k Escape
dump late-closed

cp "$D/radial.log" "$G_OUT/radial.log"
cp "$FAKE_APP_LOG" "$G_OUT/radial-runs.log"
cp "$D/radial-grace-timing.log" "$G_OUT/radial-grace-timing.log"
python3 "$G_HERE/tools/check-radial.py" "$D/radial.log" "$FAKE_APP_LOG" "$D/quickshell.log" "$D/radial-grace-timing.log"

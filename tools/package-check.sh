#!/usr/bin/env bash
# Check a built package (nix build: ./result): the `appring` command, the desktop
# entry and the icons, with the ring running in a headless sway of its own. Never
# the real desktop: a private runtime dir, a private bus, an empty config home.
#
#   nix build && nix develop -c tools/package-check.sh result      # or: just test-package
set -euo pipefail

pkg="$(realpath "${1:?usage: package-check.sh PACKAGE_DIR}")"
bin="$pkg/bin/appring"
shell="$pkg/share/appring/appring"
fail=0
ok() { echo "package: ok   $*"; }
bad() { echo "package: FAIL $*"; fail=1; }

if [ "${2:-}" != --scene ]; then
  for tool in sway quickshell desktop-file-validate dbus-run-session; do
    command -v "$tool" >/dev/null || { echo "package-check: $tool not on PATH (run inside 'nix develop')" >&2; exit 2; }
  done
  # files first: no compositor needed
  [ -x "$bin" ] && ok "bin/appring" || bad "no bin/appring"
  [ -f "$shell/shell.qml" ] && ok "share/appring/appring/shell.qml" || bad "no share/appring/appring/shell.qml"
  for f in scalable/apps/com.mirql.appring.svg 48x48/apps/com.mirql.appring.png symbolic/apps/com.mirql.appring-symbolic.svg; do
    [ -f "$pkg/share/icons/hicolor/$f" ] && ok "icon $f" || bad "no icon $f"
  done
  desktop-file-validate "$pkg/share/applications/com.mirql.appring.desktop" && ok "desktop entry valid" || bad "desktop entry"
  [ "$("$bin" version)" = "appring $(basename "$pkg" | sed 's/^[^-]*-appring-//')" ] && ok "version: $("$bin" version)" || bad "version: $("$bin" version)"

  run=$(mktemp -d /tmp/apc.XXXXXX); chmod 700 "$run"
  DC="$(dirname "$(readlink -f "$(command -v dbus-run-session)")")/../share/dbus-1/session.conf"
  [ -f "$DC" ] || DC=/etc/dbus-1/session.conf
  env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 XDG_RUNTIME_DIR="$run" XDG_CONFIG_HOME="$run/config" \
    XDG_DATA_DIRS="${RING_GALLERY_ICONS:-/nonexistent}/share" QT_PLUGIN_PATH=/nonexistent \
    dbus-run-session --config-file="$DC" -- "$0" "$pkg" --scene || fail=1
  rm -rf "$run"
  [ $fail = 0 ] && echo "package: all ok" || echo "package: failures above"
  exit $fail
fi

# ── inside the private bus and runtime dir ──────────────────────────────
printf 'output HEADLESS-1 resolution 1600x1000\nexec env > %s/sway.env\n' "$XDG_RUNTIME_DIR" > "$XDG_RUNTIME_DIR/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway --config "$XDG_RUNTIME_DIR/sway.conf" > "$XDG_RUNTIME_DIR/sway.log" 2>&1 &
sway_pid=$!
trap 'kill $sway_pid 2>/dev/null || true' EXIT
for _ in $(seq 40); do grep -q ^WAYLAND_DISPLAY= "$XDG_RUNTIME_DIR/sway.env" 2>/dev/null && break; sleep 0.25; done
export WAYLAND_DISPLAY; WAYLAND_DISPLAY=$(sed -n 's/^WAYLAND_DISPLAY=//p' "$XDG_RUNTIME_DIR/sway.env")
export APPRING_DUMP=1 QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software

running() { quickshell ipc -p "$shell" show >/dev/null 2>&1; }
last_state() { quickshell log -p "$shell" 2>/dev/null | grep -o 'appring state .*' | tail -n 1; }

running && bad "running before start" || ok "not running before start"
"$bin" open && sleep 1.5
running && ok "open started it" || bad "open did not start it"
last_state | grep -q '"visible":true' && ok "open shows the menu" || bad "open: $(last_state | cut -c1-120)"
"$bin" cancel && sleep 0.8
last_state | grep -q '"visible":false' && ok "cancel closes it" || bad "cancel: $(last_state | cut -c1-120)"
"$bin" settings && sleep 1 && "$bin" settings && sleep 0.5 && ok "settings opens and closes" || bad "settings"
"$bin" commit && ok "commit with nothing open is harmless" || bad "commit"
errors=$(quickshell log -p "$shell" 2>/dev/null | grep -E "TypeError|ReferenceError|Unable to assign|Failed to load|binding loop" || true)
[ -z "$errors" ] && ok "no QML errors" || bad "QML errors: $errors"
"$bin" stop && sleep 0.8
running && bad "stop did not stop it" || ok "stop stops it"
exit $fail

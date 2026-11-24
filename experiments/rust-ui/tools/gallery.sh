#!/usr/bin/env bash
# The three spikes, off-screen: a private headless sway (never the live
# desktop, like the repo's own tools/gallery.sh), a stand-in
# hyprctl (tools/fake-hyprctl.sh), release binaries, screenshots, and the
# numbers README.md reports (idle/shown RSS, show-to-first-frame median of
# 10, binary size).
#
#   ./tools/gallery.sh            # every toolkit that builds (iced: build
#                                  # fails upstream today, see README.md;
#                                  # skipped automatically)
#   ./tools/gallery.sh egui cxx-qt
#   GALLERY_OUT=/tmp/g2 ./tools/gallery.sh egui
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${GALLERY_OUT:-/tmp/appring-experiments-gallery}"
mkdir -p "$OUT"

TOOLKITS=("$@")
[ ${#TOOLKITS[@]} -gt 0 ] || TOOLKITS=(egui cxx-qt egui-layershell)

for tool in sway grim; do
  command -v "$tool" >/dev/null || { echo "gallery: $tool not on PATH (run inside 'nix develop')" >&2; exit 2; }
done

bin_for() {
  case "$1" in
    egui) echo "$HERE/egui/target/release/ring-egui" ;;
    cxx-qt) echo "$HERE/cxx-qt/target/release/ring-cxxqt" ;;
    iced) echo "$HERE/iced/target/release/ring-iced" ;;
    egui-layershell) echo "$HERE/egui-layershell/target/release/ring-eguilayershell" ;;
  esac
}

# The socket name each binary actually opens (socket_path() in its own
# main.rs) -- cxx-qt's has no hyphen ("cxxqt"), unlike its toolkit/folder
# name ("cxx-qt") used everywhere else in this script. Checked by testing:
# an earlier version of this script used "$tk" directly and never found
# the (correctly open, working) socket because of this mismatch.
# egui-layershell deliberately kept its own hyphen in its socket name
# (appring-spike-egui-layershell.sock), precisely so it needs no entry
# here -- the default branch below already echoes "$1" verbatim.
sock_suffix_for() {
  case "$1" in
    cxx-qt) echo "cxxqt" ;;
    *) echo "$1" ;;
  esac
}

rss_kib() {
  # VmRSS of a pid, in KiB, or empty if it has already exited.
  awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || true
}

median() {
  # stdin: one number per line -> prints the median
  sort -n | awk '{a[NR]=$1} END{if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

run_one() {
  local tk="$1"
  local bin; bin="$(bin_for "$tk")"
  if [ ! -x "$bin" ]; then
    echo "== $tk: no release binary at $bin (build failed or not built) =="
    echo "$tk builds=no" >> "$OUT/summary.txt"
    return 0
  fi
  echo "== $tk =="
  local D="$OUT/$tk"; rm -rf "$D"; mkdir -p "$D/run"; chmod 700 "$D/run"

  # Private runtime dir + headless sway, same isolation convention as the
  # main repo's gallery: a Wayland socket that cannot be the session's.
  (
    export XDG_RUNTIME_DIR="$D/run"
    unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK DBUS_SESSION_BUS_ADDRESS
    # Qt's default message handler silently redirects qWarning/qDebug to
    # journald instead of stderr when JOURNAL_STREAM is set (inherited from
    # a systemd user session) -- caught by testing: the cxx-qt
    # spike went completely silent on a load failure until this was unset.
    unset JOURNAL_STREAM
    echo "output HEADLESS-1 resolution 2880x1800 position 0 0 scale 1.2 bg #335577 solid_color" > "$D/sway.conf"
    echo "default_border none" >> "$D/sway.conf"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
      sway --config "$D/sway.conf" > "$D/sway.log" 2>&1 &
    echo $! > "$D/sway.pid"
    disp=""
    for _ in $(seq 60); do
      disp=$(sed -n 's/^WAYLAND_DISPLAY=//p' <(env) 2>/dev/null || true)
      [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && disp="wayland-1" && break
      sleep 0.2
    done
    if [ -z "$disp" ]; then echo "ABORT: sway did not come up for $tk"; exit 1; fi
    export WAYLAND_DISPLAY="$disp"
    export MIRQL_RING_HYPRCTL="$HERE/tools/fake-hyprctl.sh"
    export QT_QPA_PLATFORM=wayland
    export QML2_IMPORT_PATH="${QML2_IMPORT_PATH:-}"

    "$bin" > "$D/daemon.log" 2>&1 &
    daemon_pid=$!
    echo "$daemon_pid" > "$D/daemon.pid"
    sock="$XDG_RUNTIME_DIR/appring-spike-$(sock_suffix_for "$tk").sock"
    # cxx-qt (QML/shader setup on first run) can take noticeably longer to
    # open its socket than egui under load on a shared host -- checked.
    for _ in $(seq 200); do [ -S "$sock" ] && break; sleep 0.1; done
    if [ ! -S "$sock" ]; then
      echo "ABORT: $tk daemon never opened its socket"; cat "$D/daemon.log"; kill "$daemon_pid" 2>/dev/null; exit 1
    fi
    sleep 0.3
    idle_rss=$(rss_kib "$daemon_pid")

    : > "$D/timings.log"
    for i in $(seq 1 10); do
      line=$("$bin" show)
      echo "$line" >> "$D/timings.log"
      if [ "$i" = 1 ]; then
        sleep 0.2
        shown_rss=$(rss_kib "$daemon_pid")
        grim "$OUT/$tk.png" 2>>"$D/grim.log" || echo "grim failed for $tk" >> "$D/grim.log"
      fi
      "$bin" hide >/dev/null
      sleep 0.1
    done

    ms_median=$(grep -o '[0-9.]\+ ms' "$D/timings.log" | awk '{print $1}' | median)
    {
      echo "$tk builds=yes"
      echo "$tk idle_rss_kib=${idle_rss:-unknown}"
      echo "$tk shown_rss_kib=${shown_rss:-unknown}"
      echo "$tk show_to_first_frame_ms_median=${ms_median:-unknown}"
      echo "$tk binary_size_bytes=$(stat -c%s "$bin")"
    } >> "$OUT/summary.txt"

    kill "$daemon_pid" 2>/dev/null
    kill "$(cat "$D/sway.pid")" 2>/dev/null
    wait 2>/dev/null
  )
}

: > "$OUT/summary.txt"
for tk in "${TOOLKITS[@]}"; do run_one "$tk"; done
echo "--- summary ($OUT/summary.txt) ---"
cat "$OUT/summary.txt"
echo "screenshots: $OUT/*.png"

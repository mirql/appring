#!@bash@/bin/bash
# appring: the radial menu's command (installed by nix/package.nix).
set -euo pipefail

quickshell=@quickshell@/bin/quickshell
flock=@flock@/bin/flock
shell=@out@/share/appring/appring    # the app: a Quickshell root
version=@version@

# On NixOS, the system's Qt plugins carry the platform theme that tells Qt the
# user's icon theme; without them, icons by name can come out blank.
if [ -z "${QT_PLUGIN_PATH:-}" ] && [ -d /run/current-system/sw/lib/qt-6/plugins ]; then
  export QT_PLUGIN_PATH=/run/current-system/sw/lib/qt-6/plugins
fi

usage() {
  cat <<EOF
appring $version: a radial menu for the desktop. Hold a key, point, release to run.

usage: appring [COMMAND]

  run           start it, hidden until opened (the default)
  open [NAME]   show the menu: menu.json, or menu-NAME.json (starts it if needed)
  commit        run the highlighted item and close (bind to the key's release)
  cancel        close without running anything
  toggle [NAME] open, or close if open
  settings      the appearance window (again: closes it)
  stop          stop it
  restart       stop, then start
  version       print the version

Menus and appearance: \${XDG_CONFIG_HOME:-~/.config}/appring/. On Hyprland
(with appring installed, so the command is on PATH):
  exec-once = appring run
  bind = SUPER, grave, global, appring:ring    # press opens, release runs
Elsewhere, bind the key to \`appring open\` and its release to \`appring commit\`.
EOF
}

running() { "$quickshell" ipc -p "$shell" show >/dev/null 2>&1; }
# Start it unless it runs, and wait until it answers. A lock makes two callers at
# once (a key pressed while the session starts it) start one instance, not two:
# the second waits, then finds it running.
start() {
  running && return 0
  local lock
  lock="${XDG_RUNTIME_DIR:-/tmp}/appring-$(id -u).lock"
  (
    "$flock" 9
    if ! running; then
      "$quickshell" -p "$shell" -d >/dev/null 9>&-   # it must not hold the lock
      for _ in $(seq 50); do running && break; sleep 0.1; done
    fi
  ) 9>"$lock"
}
call() { "$quickshell" ipc -p "$shell" call appring "$@"; }
# a call that also starts appring first when it is not running
call_started() {
  start
  call "$@"
}

cmd="${1:-run}"
[ $# -gt 0 ] && shift
case "$cmd" in
  run) start ;;
  open) call_started open "${1:-}" ;;
  toggle) call_started toggle "${1:-}" ;;
  settings) call_started settings ;;
  commit | cancel) call "$cmd" ;;
  stop) "$quickshell" kill -p "$shell" >/dev/null 2>&1 || true ;;
  restart) "$quickshell" kill -p "$shell" >/dev/null 2>&1 || true; start ;;
  version | --version) echo "appring $version" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac

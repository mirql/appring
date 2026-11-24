//@ pragma UseQApplication
// ring-app: a radial menu as its own Quickshell root.
//
//   quickshell -p ring            (from the repository's root)
//
// Quickshell resolves imports only inside the folder of its root file, so
// everything the ring needs lives in this folder.
//
// IPC, target "ring" (Radial.qml's IpcHandler):
//   quickshell ipc -p ring call ring open ""         # the default menu
//   quickshell ipc -p ring call ring open "tools"    # menu-tools.json
//   quickshell ipc -p ring call ring commit          # for a key-release bind
//   quickshell ipc -p ring call ring cancel
//   quickshell ipc -p ring call ring toggle ""
//   quickshell ipc -p ring call ring settings        # the appearance window (again: closes)
// Quickshell's IPC caller does not fill in a missing argument: pass "" for
// the default menu, never omit it.
//
// Appearance settings: appearance.json next to the menus (Settings.qml),
// changed by the settings window.
//
// Environment:
//   RING_APP_CONFIG_DIR    where menu.json / menu-<name>.json are read from
//                          (default: $XDG_CONFIG_HOME/ring-app, or ~/.config/ring-app)
//   RING_APP_RELEASE_KEY   Alt, Ctrl, Shift or Super (default): releasing it
//                          inside the window commits
//   RING_APP_REST_MS       how long resting on a group opens it (default 250)
//   RING_APP_CLOSE_MS      how long a satellite's close condition must hold
//                          before it closes (default 150)
//   RING_APP_REDUCED_MOTION=1   no animations, whatever the settings say
//   RING_APP_DUMP=1        log one `ring-app state <json>` line per change,
//                          for the tests (tools/check-radial.py)

import Quickshell

ShellRoot {
    // No reloading on file changes: a running ring keeps what it started
    // with (restart it to pick up a change).
    settings.watchFiles: false

    Radial {
        id: radial
        onSettingsRequested: settings.toggle()
    }
    SettingsWindow {
        id: settings
        radial: radial
    }
}

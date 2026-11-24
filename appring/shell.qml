//@ pragma UseQApplication
// appring: a radial menu as its own Quickshell root.
//
//   quickshell -p appring         (from the repository's root)
//
// Quickshell resolves imports only inside the folder of its root file, so
// everything the ring needs lives in this folder.
//
// IPC, target "appring" (Radial.qml's IpcHandler; the old target "ring" still answers):
//   quickshell ipc -p appring call appring open ""         # the default menu
//   quickshell ipc -p appring call appring open "tools"    # menu-tools.json
//   quickshell ipc -p appring call appring commit          # for a key-release bind
//   quickshell ipc -p appring call appring cancel
//   quickshell ipc -p appring call appring toggle ""
//   quickshell ipc -p appring call appring settings        # the appearance window (again: closes)
// Quickshell's IPC caller does not fill in a missing argument: pass "" for
// the default menu, never omit it.
//
// Appearance settings: appearance.json next to the menus (Settings.qml),
// changed by the settings window.
//
// Environment (each also read under its old name, RING_APP_*; with both set, APPRING_* wins):
//   APPRING_CONFIG_DIR    where menu.json / menu-<name>.json are read from
//                          (default: $XDG_CONFIG_HOME/appring, or ~/.config/appring;
//                          the old ~/.config/ring-app while there is no appring)
//   APPRING_RELEASE_KEY   Alt, Ctrl, Shift or Super (default): releasing it
//                          inside the window commits
//   APPRING_REST_MS       how long resting on a group opens it (default 250)
//   APPRING_GHOST_MS       how long resting on a group shows its ghost ring (default 250)
//   APPRING_CLOSE_MS      how long a satellite's close condition must hold
//                          before it closes (default 150)
//   APPRING_REDUCED_MOTION=1   no animations, whatever the settings say
//   APPRING_DUMP=1        log one `appring state <json>` line per change,
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

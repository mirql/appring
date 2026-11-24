pragma Singleton

// The appearance settings: appearance.json next to the menus (APPRING_CONFIG_DIR,
// default $XDG_CONFIG_HOME/appring). The settings window writes it; the ring
// re-reads it when it changes, so changes show at once. A missing file means
// the defaults below; it is written the first time a setting changes.

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // An environment setting: APPRING_<name>, or its old name RING_APP_<name>
    // (the app was called ring-app before; the old names still work).
    function env(name) {
        return Quickshell.env("APPRING_" + name) ?? Quickshell.env("RING_APP_" + name) ?? null;
    }

    readonly property string _home: Quickshell.env("HOME") ?? ""
    readonly property string _xdgConfig: Quickshell.env("XDG_CONFIG_HOME") ?? ""
    readonly property string _configBase: _xdgConfig !== "" ? _xdgConfig : _home + "/.config"
    readonly property string _configDirOverride: env("CONFIG_DIR") ?? ""
    // The old folder, ~/.config/ring-app, is still read while there is no
    // ~/.config/appring (with a hint, once, to move it).
    readonly property bool _legacyDir: {
        if (_configFolders.status !== FolderListModel.Ready)
            return false;
        let hasNew = false, hasOld = false;
        for (let i = 0; i < _configFolders.count; i++) {
            const n = _configFolders.get(i, "fileName");
            hasNew = hasNew || n === "appring";
            hasOld = hasOld || n === "ring-app";
        }
        return hasOld && !hasNew;
    }
    on_LegacyDirChanged: if (_legacyDir && _configDirOverride === "")
        console.warn("appring: reading the old config folder " + _configBase + "/ring-app; move it to " + _configBase + "/appring");
    FolderListModel {
        id: _configFolders
        // a file URL, with "#", "?" and "%" in the path encoded
        folder: "file://" + encodeURI(root._configBase).replace(/#/g, "%23").replace(/\?/g, "%3F")
        showDirs: true
        showFiles: false
        showHidden: true
        nameFilters: ["appring", "ring-app"]
    }
    // where menu.json, menu-<name>.json and appearance.json live
    readonly property string configDir: _configDirOverride !== "" ? _configDirOverride
        : _configBase + (_legacyDir ? "/ring-app" : "/appring")

    // Ring scale: every size of the ring and the centre, 0.5 to 2.
    property alias scale: adapter.scale
    // Open the ring at the cursor; off: at the middle of the screen.
    property alias atCursor: adapter.atCursor
    // Animate transitions (opening, closing, the spin, the glow).
    property alias animate: adapter.animate
    // How the ring goes away: "fade" (in place), "zoom" (shrinks to the
    // centre), "spiral" (the buttons swirl outward), "none" (at once).
    property alias closing: adapter.closing
    // Running an item: its button flashes briefly before the ring goes.
    property alias flash: adapter.flash
    // The chevron jumps to the cursor's direction instead of swinging round to it.
    property alias instantPointer: adapter.instantPointer
    // The highlighted button grows a little.
    property alias enlargeSelected: adapter.enlargeSelected
    // Slice labels under the buttons: "none", "selected" or "all".
    property alias labels: adapter.labels
    // Slice colours from each icon's own colours; off: a fixed palette by position.
    property alias iconColors: adapter.iconColors
    // Seconds for one turn of the centre ring; 0: it stands still.
    property alias spinSeconds: adapter.spinSeconds
    // A gap between two neighbouring slices where nothing is selected, as a
    // fraction of each slice (0 to 0.5).
    property alias sliceGap: adapter.sliceGap

    // Animation speeds, in milliseconds (0: instant).
    property alias openMs: adapter.openMs       // opening: the ring zooms in
    property alias closeMs: adapter.closeMs     // closing (fade, zoom or spiral)
    property alias flashMs: adapter.flashMs     // the run flash
    property alias stateMs: adapter.stateMs     // the centre changing colour, one item to the next
    property alias glowMs: adapter.glowMs       // the centre's glow fading in and out
    property alias growMs: adapter.growMs       // the highlighted button growing
    // How fast the chevron swings round to the cursor (1: as the reference).
    property alias pointerSpeed: adapter.pointerSpeed

    // Effects.
    property alias glowStrength: adapter.glowStrength   // the centre's glow, 0 to 1
    property alias flashPop: adapter.flashPop           // how much the run flash pops the button bigger
    property alias deadZone: adapter.deadZone           // px around the centre where nothing is picked

    FileView {
        id: file
        path: root.configDir + "/appearance.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter {
            id: adapter
            property real scale: 1.0
            property bool atCursor: true
            property bool animate: true
            property string closing: "fade"
            property bool flash: true
            property bool instantPointer: false
            property bool enlargeSelected: true
            property string labels: "none"
            property bool iconColors: true
            property real spinSeconds: 4
            property real sliceGap: 0
            property int openMs: 250
            property int closeMs: 180
            property int flashMs: 300
            property int stateMs: 180
            property int glowMs: 300
            property int growMs: 100
            property real pointerSpeed: 1.0
            property real glowStrength: 0.75
            property real flashPop: 0.3
            property int deadZone: 40
        }
    }

    // Back to the defaults (the settings window's "Reset").
    function reset() {
        adapter.scale = 1.0;
        adapter.atCursor = true;
        adapter.animate = true;
        adapter.closing = "fade";
        adapter.flash = true;
        adapter.instantPointer = false;
        adapter.enlargeSelected = true;
        adapter.labels = "none";
        adapter.iconColors = true;
        adapter.spinSeconds = 4;
        adapter.sliceGap = 0;
        adapter.openMs = 250;
        adapter.closeMs = 180;
        adapter.flashMs = 300;
        adapter.stateMs = 180;
        adapter.glowMs = 300;
        adapter.growMs = 100;
        adapter.pointerSpeed = 1.0;
        adapter.glowStrength = 0.75;
        adapter.flashPop = 0.3;
        adapter.deadZone = 40;
    }
}

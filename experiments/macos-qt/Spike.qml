// The spike's window: appring's ring (RingLayer, unchanged) on a borderless,
// transparent, always-on-top window over the whole screen, centred on the
// cursor. Point to highlight; a click prints what it would run and quits; Esc
// or a right click quits.
import QtQuick
import QtQuick.Window
import appring
import SpikeHelper

Window {
    id: win
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
    // almost transparent, not fully: macOS passes clicks and hovers on fully
    // transparent pixels through to the windows below
    color: Qt.rgba(0, 0, 0, 0.004)
    x: Screen.virtualX
    y: Screen.virtualY
    width: Screen.width
    height: Screen.height
    visible: true

    readonly property var sample: [
        { label: "Browser", icon: "firefox" },
        { label: "Terminal", icon: "utilities-terminal" },
        { label: "Files", icon: "system-file-manager" },
        { label: "Music", icon: "multimedia-audio-player" },
        { label: "Mail", icon: "internet-mail" },
        { label: "Tools", icon: "applications-utilities", items: [{ label: "x", icon: "folder" }] }
    ]
    // appring's default style (Radial.qml's _baseStyle), per item
    readonly property var styles: sample.map(() => ({
        shape: "rounded-square", cornerRadius: Theme.radialCornerFraction,
        size: Math.round(Theme.radialButtonSize), glowColor: "auto",
        glowSize: Math.round(Theme.radialGlowPad), ringRadius: Math.round(Theme.ringRadiusFor(sample.length)),
        captionSize: Theme.fontSmall, caption: "none", backdrop: false
    }))

    property real cx: width / 2
    property real cy: height / 2
    property int highlighted: -1
    property bool deadZone: true
    property real pointerAngle: 0
    property bool shown: false
    // where the cursor is not known (Wayland gives (0, 0)): the first move
    property bool centreKnown: false

    Component.onCompleted: {
        const c = SpikeEnv.cursor();
        if (c.x !== 0 || c.y !== 0) {
            cx = c.x - x;
            cy = c.y - y;
            centreKnown = true;
            shown = true;
        }
        // SPIKE_AT=x,y and SPIKE_POINT=x,y: the centre and a pointer, for a
        // run without a cursor (screenshots from afar)
        const at = SpikeEnv.env("SPIKE_AT");
        if (at) {
            const [ax, ay] = at.split(",").map(Number);
            cx = ax; cy = ay; centreKnown = true; shown = true;
        }
        const pt = SpikeEnv.env("SPIKE_POINT");
        if (pt) {
            const [px, py] = pt.split(",").map(Number);
            track(px, py);
        }
        requestActivate();
    }
    // SPIKE_SHOT=file: after 2.5 s, save what the window shows (no screen
    // recording permission needed: Qt grabs its own window)
    Timer {
        running: SpikeEnv.env("SPIKE_SHOT") !== undefined
        interval: 2500
        onTriggered: win.contentItem.grabToImage(r => {
            r.saveToFile(SpikeEnv.env("SPIKE_SHOT"));
            console.log("appring-spike: saved", SpikeEnv.env("SPIKE_SHOT"), r.image ? "" : "");
        })
    }
    // SPIKE_QUIT_AFTER=ms: quit by itself (a run started from afar)
    Timer {
        running: SpikeEnv.env("SPIKE_QUIT_AFTER") !== undefined
        interval: parseInt(SpikeEnv.env("SPIKE_QUIT_AFTER") ?? "0")
        onTriggered: Qt.quit()
    }

    function track(px, py) {
        const dx = px - cx, dy = py - cy;
        deadZone = Math.hypot(dx, dy) < Theme.radialDeadZone;
        if (deadZone) {
            highlighted = -1;
            return;
        }
        const a = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
        pointerAngle = a;
        const step = 360 / sample.length;
        highlighted = Math.floor(((a + step / 2) % 360) / step);
    }

    RingLayer {
        anchors.fill: parent
        items: win.sample
        styles: win.styles
        highlighted: win.highlighted
        deadZone: win.deadZone
        centreX: win.cx
        centreY: win.cy
        pointerAngle: win.pointerAngle
        ringVisible: win.shown
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        // a fixed pointer (SPIKE_POINT) ignores the mouse
        enabled: SpikeEnv.env("SPIKE_POINT") === undefined
        onPositionChanged: mouse => {
            if (!win.centreKnown) {
                win.cx = mouse.x;
                win.cy = mouse.y;
                win.centreKnown = true;
                win.shown = true;
            }
            win.track(mouse.x, mouse.y);
        }
        onClicked: mouse => {
            if (mouse.button === Qt.LeftButton && !win.deadZone && win.highlighted >= 0)
                console.log("appring-spike: would run", win.sample[win.highlighted].label);
            Qt.quit();
        }
    }
    Shortcut { sequence: "Escape"; onActivated: Qt.quit() }
}

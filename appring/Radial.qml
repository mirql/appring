// The radial menu: a full-screen, transparent, keyboard-exclusive layer-shell
// overlay on the focused monitor.
//
// Selection by angle, over the whole screen: the window tracks the pointer
// everywhere, and the active item is the one whose sector the pointer's
// direction from the centre falls in (0 = up, clockwise; `_sliceOf`). Each
// sector is 360/N wide, a fraction of it (Theme.radialSliceGap) a gap at its
// borders: pointing between two items selects nothing. A dead zone
// (Theme.radialDeadZone, a radius around the centre) is never active either:
// committing there, or in a gap, cancels.
//
// The centre is the cursor: the first real pointer position after `open()`
// becomes the ring's centre for that session, exactly, never clamped. Near
// a corner part of the ring lands off-screen; the angle math still works.
// `centreX`/`centreY` are never animated and are reset to (-1, -1) on
// close, so the next open jumps straight to its own centre.
//
// Groups open as a satellite: a smaller ring centred on the group's own
// button (clamped on-screen), with the main ring still visible and dimmed
// behind it. Selection inside it is the angle from its own centre. Three
// ways open it: resting on the group (`groupTimer`), a click, or moving
// past the main ring's outer radius. Near the group's own button nothing
// inside is highlighted. It closes when the pointer is back near the main
// centre, or when the main angle clearly points at another item, and only
// once that holds for a short grace (`satCloseTimer`), so a jitter never
// closes it. Depth 2 is the limit: a satellite's items do not open further.
//
// Commit: IPC `commit()` (for a key-release bind), releasing the opening key
// inside the window (APPRING_RELEASE_KEY, Super by default), or a left
// click. Cancel: IPC `cancel()`, Esc, or a right click, always closing
// everything. Committing a leaf runs its `run` argv directly (no shell);
// committing a group opens its satellite; committing in the satellite's
// centre goes back to the main ring.
//
// Config: a JSON file, re-read on every open. `open("")` reads menu.json,
// `open("tools")` reads menu-tools.json, both in APPRING_CONFIG_DIR
// (default $XDG_CONFIG_HOME/appring). The default menu falls back to this
// folder's default.json; a named menu with no file is an empty ring. The
// file is either an array of items or `{"style": {...}, "items": [...]}`.
//
// Look: a global style at the config's top level, a per-item "style" on
// top, a group's style cascading to its satellite's items unless they set
// their own (`_effectiveStyle`). Unknown style keys log one warning each
// per config load, never a crash.
//
// APPRING_DUMP=1: one `appring state <json>` line per change to what is
// shown, highlighted, the dead zone or the satellite, read by the tests
// (tools/check-radial.py).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets

PanelWindow {
    id: root

    visible: false
    color: "transparent"
    exclusiveZone: 0
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    WlrLayershell.namespace: "appring"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // ── settings ──────────────────────────────────────────────────────
    readonly property string _configDir: Settings.configDir
    // The folder is found asynchronously at start (Settings.qml): an open that
    // came first reads the menu again from the right one.
    on_ConfigDirChanged: if (root._open) root._reloadConfig()
    readonly property string _defaultConfigPath: Quickshell.shellDir + "/default.json"
    readonly property bool _dump: Settings.env("DUMP") === "1"

    function _pathFor(name) {
        return _configDir + "/" + (name ? ("menu-" + name + ".json") : "menu.json");
    }

    // The key whose release inside the window commits. The compositor's own
    // bind is not visible from here, so it is a setting.
    readonly property string _releaseKey: Settings.env("RELEASE_KEY") ?? "Super"

    // How long resting on a group opens it. The tests raise it far above a
    // synthetic pointer's latency, so "a click opened it" and "it rested
    // open" are told apart.
    readonly property int _restMs: parseInt(Settings.env("REST_MS") ?? "250")

    // How long a satellite's close condition must hold before it closes.
    // The tests raise it to prove the delay is real.
    readonly property int _satCloseGraceMs: parseInt(Settings.env("CLOSE_MS") ?? "150")

    // ── state ─────────────────────────────────────────────────────────
    property string menuName: ""
    property var items: []        // the main ring
    property var mainStyles: []   // one resolved style per item in `items`, same order
    // null, or the open satellite (see `_openSatellite`). Always replaced
    // as a whole object, so it changes in one step.
    property var satellite: null
    property int highlightedIndex: -1
    property bool deadZone: true
    property real _pointerX: 0
    property real _pointerY: 0
    property real _pointerAngle: 0   // the last angle (the centre's arrow); meaningless in the dead zone
    // The ring's centre: set from the first real pointer position after
    // open(), while `_centreEstablished` is false.
    property real centreX: width / 2
    property real centreY: height / 2
    property bool _centreEstablished: false
    // False until a real pointer position arrives after open(). On the
    // first show the window may not be sized yet, so a guessed centre would
    // be (0, 0); until then it is simply the dead zone.
    property bool _hasPointer: false
    property bool _pastOuterHandled: false

    // The config's global style, not merged with defaults (a satellite's
    // defaults differ, see `_baseStyle`).
    property var _globalStyleRaw: ({})
    readonly property var _styleKeys: ["shape", "cornerRadius", "size", "glowColor", "glowSize", "ringRadius", "captionSize", "caption", "backdrop"]
    property var _unknownWarned: null   // a Set, reset on every config parse

    // `ipc call appring settings`: shell.qml opens or closes the settings window.
    signal settingsRequested()

    readonly property var _current: (highlightedIndex >= 0 && highlightedIndex < items.length) ? items[highlightedIndex] : null

    // Open or closed, as far as picking goes. The window stays up a moment
    // longer after a close, while the ring fades away (`_fade`).
    property bool _open: false
    // What was on screen when the ring closed, drawn fading out by its own
    // Ring (closing animation); null when nothing is fading.
    property var _fade: null
    property real _fadeT: 0
    // one clock for the centre ring's turn, shared by the live ring and the
    // closing copy, so the turn carries on when the ring closes
    property real spinAngle: 0
    NumberAnimation on spinAngle {
        from: 0
        to: 360
        duration: Math.max(1, Theme.centreSpinMs)
        loops: Animation.Infinite
        running: root.visible && !Theme.reducedMotion && Theme.centreSpinMs > 0
    }
    NumberAnimation {
        id: fadeOut
        target: root
        property: "_fadeT"
        from: 0
        to: 1
        duration: 1
        onFinished: root._endFade()
    }
    function _endFade() {
        fadeOut.stop();
        _fade = null;
        _fadeT = 0;
        if (!_open)
            visible = false;
    }

    // ── opening / closing ────────────────────────────────────────────
    // Quickshell can list a placeholder screen with no name and no size.
    function _realScreens() {
        return Quickshell.screens.filter(s => !(s.name === "" && s.width === 0 && s.height === 0));
    }

    // The focused monitor on Hyprland; the first screen elsewhere.
    function _focusedScreen() {
        const real = _realScreens();
        if (!real.length)
            return null;
        const focusedName = Hyprland.focusedMonitor?.name ?? "";
        const target = real.find(s => (Hyprland.monitorFor(s)?.name ?? s.name) === focusedName);
        return target ?? real[0];
    }

    function open(name) {
        const target = _focusedScreen();
        if (!target)
            return;
        _endFade();
        _open = true;
        screen = target;
        menuName = name ?? "";
        satellite = null;
        highlightedIndex = -1;
        deadZone = true;
        _pastOuterHandled = false;
        groupTimer.stop();
        satCloseTimer.stop();
        // Nothing is highlighted until a real pointer position arrives, and
        // every open re-centres on the cursor.
        _hasPointer = false;
        _centreEstablished = false;
        visible = true;
        _reloadConfig();
        Qt.callLater(() => content.forceActiveFocus());
    }

    function toggle(name) {
        if (_open)
            cancel();
        else
            open(name);
    }

    function cancel() {
        _close();
    }

    function commit() {
        if (!_open)
            return;
        if (satellite) {
            if (!satellite.deadZone && satellite.highlighted < 0) {
                // In a gap between the satellite's items: nothing to run.
                cancel();
                return;
            }
            if (satellite.deadZone) {
                // On the group's own button: back to the main ring, not a
                // cancel of the whole menu.
                satellite = null;
                satCloseTimer.stop();
                _dumpState();
                return;
            }
            _run(satellite.items[satellite.highlighted]);
            _close({ sat: satellite.highlighted });
            return;
        }
        if (deadZone || !_current) {
            cancel();
            return;
        }
        if (_current.items) {
            _openSatellite(highlightedIndex);
            return;
        }
        _run(_current);
        _close({ main: highlightedIndex });
    }

    // `ran`: the item just run, { main: index } or { sat: index }: it flashes.
    function _close(ran) {
        const flashing = !!ran && Theme.flashMs > 0;
        const ms = Math.max(Theme.closeMs, flashing ? Theme.flashMs : 0);
        if (_open && _centreEstablished && items.length > 0 && ms > 0) {
            // keep drawing what was there, going away, while picking is over
            _fade = {
                items: items, styles: mainStyles, highlighted: highlightedIndex, deadZone: deadZone,
                centreX: centreX, centreY: centreY, pointerAngle: liveRing.chevronAngle, satellite: satellite,
                mainColours: liveRing.mainColours, satColours: liveRing.satColours,
                ms: ms,
                flashMain: flashing && ran.main !== undefined ? ran.main : -1,
                flashSat: flashing && ran.sat !== undefined ? ran.sat : -1
            };
            _open = false;
            fadeOut.duration = ms;
            fadeOut.restart();
        } else {
            _open = false;
            _endFade();
        }
        items = [];
        mainStyles = [];
        satellite = null;
        highlightedIndex = -1;
        deadZone = true;
        groupTimer.stop();
        satCloseTimer.stop();
        // An off-screen sentinel, so nothing is ever drawn from a stale
        // centre between sessions.
        centreX = -1;
        centreY = -1;
        _centreEstablished = false;
        _hasPointer = false;
        _dumpState();
    }

    // Runs an item's argv as it is: no shell, so no quoting problems. The
    // first element is looked up on PATH.
    function _run(item) {
        if (!item || !Array.isArray(item.run) || !item.run.length || !item.run[0])
            return;
        Quickshell.execDetached(item.run.map(String));
    }

    // ── the satellite ring ────────────────────────────────────────────

    // Where the main-ring button at `index` sits, by its own ringRadius.
    function _mainButtonPos(index) {
        const angleRad = (index * (360 / items.length)) * Math.PI / 180;
        const r = mainStyles[index]?.ringRadius ?? Theme.ringRadiusFor(items.length);
        return { x: centreX + r * Math.sin(angleRad), y: centreY - r * Math.cos(angleRad) };
    }

    // Past this distance a group opens on its own.
    function _outerThreshold(ringRadius) {
        return ringRadius + Theme.radialOuterMargin;
    }

    function _openSatellite(index) {
        const item = items[index];
        if (!item || !Array.isArray(item.items) || !item.items.length)
            return;
        const pos = _mainButtonPos(index);
        const groupStyleRaw = (item.style && typeof item.style === "object") ? item.style : {};
        const styles = item.items.map(child => _effectiveStyle(child, true, groupStyleRaw, item.items.length));
        const margin = Theme.radialDeadZone + Math.max(...styles.map(s => s.ringRadius + s.size)) + 20;
        // The main ring's resolved style for the button that opened this
        // satellite, kept on the frame so every later check uses the same
        // numbers.
        const mainStyle = mainStyles[index] ?? _baseStyle(false, items.length);
        const mainRingRadius = mainStyle.ringRadius ?? Theme.ringRadiusFor(items.length);
        const sliceWidth = items.length > 0 ? 360 / items.length : 360;
        satellite = {
            parentIndex: index,
            items: item.items,
            styles: styles,
            groupStyleRaw: groupStyleRaw,
            // Clamped on-screen, unlike the main centre: the group button's
            // spot can land off-screen near an edge.
            centreX: Math.max(margin, Math.min(width - margin, pos.x)),
            centreY: Math.max(margin, Math.min(height - margin, pos.y)),
            highlighted: -1,
            deadZone: true,
            pointerAngle: 0,
            // Near the group's own button: nothing inside is highlighted.
            buttonRadius: mainStyle.size * Theme.radialSatelliteButtonZoneScale,
            // Closes when back within this distance of the main centre...
            closeRadius: mainRingRadius * Theme.radialSatelliteCloseFraction,
            // ...or when the main angle is this far from the group's own.
            parentAngle: index * sliceWidth,
            closeAngleThreshold: sliceWidth / 2 + Theme.radialSatelliteAngleMargin
        };
        highlightedIndex = index;
        _pastOuterHandled = false;
        groupTimer.stop();
        satCloseTimer.stop();
        _dumpState();
    }

    // ── style cascade ─────────────────────────────────────────────────

    // `count`: how many buttons share the ring (its radius grows with them).
    function _baseStyle(inSatellite, count) {
        const scale = inSatellite ? Theme.radialSatelliteScale : 1;
        return {
            shape: "rounded-square",
            cornerRadius: Theme.radialCornerFraction,
            size: Math.round(Theme.radialButtonSize * scale),
            glowColor: "auto",
            glowSize: Math.round(Theme.radialGlowPad * scale),
            ringRadius: Math.round(Theme.ringRadiusFor(count) * scale),
            captionSize: Math.round(Theme.fontSmall * Theme.s * scale),
            caption: Settings.labels,
            backdrop: false
        };
    }

    // Only the known keys `override` actually sets replace `base`'s.
    function _mergeStyle(base, override) {
        if (!override || typeof override !== "object")
            return base;
        const out = Object.assign({}, base);
        for (const k of _styleKeys) {
            if (Object.prototype.hasOwnProperty.call(override, k))
                out[k] = override[k];
        }
        return out;
    }

    function _warnUnknownKeys(obj, context) {
        if (!obj || typeof obj !== "object")
            return;
        for (const k of Object.keys(obj)) {
            if (_styleKeys.indexOf(k) === -1 && !_unknownWarned.has(k)) {
                _unknownWarned.add(k);
                console.warn("appring: unknown style key \"" + k + "\" (" + context + "), ignored");
            }
        }
    }

    // Defaults, then the global style, then (in a satellite) the opening
    // group's style, then the item's own.
    function _effectiveStyle(item, inSatellite, groupStyleRaw, count) {
        let s = _baseStyle(inSatellite, count);
        s = _mergeStyle(s, _globalStyleRaw);
        if (inSatellite && groupStyleRaw)
            s = _mergeStyle(s, groupStyleRaw);
        s = _mergeStyle(s, item && item.style);
        return s;
    }

    // ── angle math ────────────────────────────────────────────────────

    // 0deg = up, clockwise: atan2(dx, -dy) measures from "up", positive to
    // the right. Used by the main ring and the satellite alike. `idx` is -1
    // in the gap between two items.
    function _sliceOf(dx, dy, count) {
        const angle = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
        const sliceWidth = 360 / count;
        const idx = Math.floor(((angle + sliceWidth / 2) % 360) / sliceWidth);
        let off = Math.abs(angle - idx * sliceWidth);
        if (off > 180)
            off = 360 - off;
        const inGap = count > 1 && off > sliceWidth / 2 * (1 - Theme.radialSliceGap);
        return { angle: angle, idx: inGap ? -1 : idx };
    }

    function _recomputeHighlight() {
        if (!_hasPointer) {
            if (highlightedIndex !== -1)
                highlightedIndex = -1;
            deadZone = true;
            _dumpState();
            return;
        }
        if (width <= 0 || height <= 0)
            return;

        // The main ring's highlight, computed even while a satellite is
        // open: the satellite's close check needs it.
        const mdx = _pointerX - centreX;
        const mdy = _pointerY - centreY;
        const mdist = Math.hypot(mdx, mdy);
        const mainDeadZone = mdist < Theme.radialDeadZone;
        let mainIdx = -1;
        let mainAngle = _pointerAngle;
        if (!mainDeadZone && items.length > 0) {
            const r = _sliceOf(mdx, mdy, items.length);
            mainIdx = r.idx;
            mainAngle = r.angle;
        }

        if (satellite) {
            const sdx = _pointerX - satellite.centreX;
            const sdy = _pointerY - satellite.centreY;
            const sdist = Math.hypot(sdx, sdy);
            // Near the group's own button: nothing inside is highlighted,
            // but the satellite stays open (the pointer is right here the
            // moment it opens).
            const nearButton = sdist < satellite.buttonRadius;

            // Close only when back toward the main centre, or when the main
            // angle clearly reads as another item (past the group's sector
            // plus a margin).
            const towardCentre = mdist < satellite.closeRadius;
            let angleDiff = Math.abs(mainAngle - satellite.parentAngle);
            if (angleDiff > 180)
                angleDiff = 360 - angleDiff;
            const differentItem = angleDiff > satellite.closeAngleThreshold;
            const shouldClose = towardCentre || differentItem;

            // Only `satCloseTimer` closes it; the timer stops as soon as the
            // condition stops holding.
            if (shouldClose) {
                if (!satCloseTimer.running)
                    satCloseTimer.start();
            } else {
                satCloseTimer.stop();
            }

            if (!shouldClose) {
                let idx = -1;
                let angle = satellite.pointerAngle;
                if (!nearButton) {
                    const r = _sliceOf(sdx, sdy, satellite.items.length);
                    idx = r.idx;
                    angle = r.angle;
                }
                if (idx !== satellite.highlighted || nearButton !== satellite.deadZone || angle !== satellite.pointerAngle)
                    satellite = Object.assign({}, satellite, { highlighted: idx, deadZone: nearButton, pointerAngle: angle });
                // The main ring keeps showing this group while its
                // satellite is open.
                if (highlightedIndex !== satellite.parentIndex)
                    highlightedIndex = satellite.parentIndex;
                if (deadZone)
                    deadZone = false;
                _pointerAngle = mainAngle;
                _dumpState();
                return;
            }
            // Closing: the satellite stays as it is until the timer fires.
            _pointerAngle = mainAngle;
            _dumpState();
            return;
        }

        // The main ring alone.
        deadZone = mainDeadZone;
        if (deadZone || items.length === 0) {
            if (highlightedIndex !== -1) {
                highlightedIndex = -1;
                groupTimer.stop();
            }
            _dumpState();
            return;
        }
        _pointerAngle = mainAngle;
        if (mainIdx !== highlightedIndex) {
            highlightedIndex = mainIdx;
            _pastOuterHandled = false;
            groupTimer.restart();
        }
        const cur = items[mainIdx];
        const ringRadius = mainStyles[mainIdx]?.ringRadius ?? Theme.ringRadiusFor(items.length);
        if (cur && cur.items && mdist > _outerThreshold(ringRadius) && !_pastOuterHandled) {
            _pastOuterHandled = true;
            _openSatellite(mainIdx);
            return;   // _openSatellite already dumped
        }
        _dumpState();
    }

    // ── config loading ────────────────────────────────────────────────

    // Keeps only objects with a string `label`, one level of children deep
    // (a satellite's items do not open further), warning about unknown
    // style keys on the way.
    function _sanitizeItems(rawItems, context) {
        if (!Array.isArray(rawItems))
            return [];
        return rawItems.filter(it => it && typeof it.label === "string").map(it => {
            if (it.style && typeof it.style === "object")
                _warnUnknownKeys(it.style, "item \"" + it.label + "\"" + context);
            if (Array.isArray(it.items)) {
                const children = it.items.filter(c => c && typeof c.label === "string").map(c => {
                    if (c.style && typeof c.style === "object")
                        _warnUnknownKeys(c.style, "item \"" + c.label + "\" (child of \"" + it.label + "\")");
                    return c;
                });
                return Object.assign({}, it, { items: children });
            }
            return it;
        });
    }

    // A plain array (no global style), or `{"style": {...}, "items": [...]}`.
    function _parseConfig(text) {
        _unknownWarned = new Set();
        try {
            const data = JSON.parse(text);
            let styleRaw = {};
            let rawItems = [];
            if (Array.isArray(data)) {
                rawItems = data;
            } else if (data && typeof data === "object") {
                styleRaw = (data.style && typeof data.style === "object") ? data.style : {};
                rawItems = Array.isArray(data.items) ? data.items : [];
            }
            _warnUnknownKeys(styleRaw, "global style");
            return { styleRaw: styleRaw, items: _sanitizeItems(rawItems, "") };
        } catch (e) {
            console.warn("appring: unreadable config", e);
            return { styleRaw: {}, items: [] };
        }
    }

    function _applyConfig(parsed) {
        _globalStyleRaw = parsed.styleRaw;
        items = parsed.items;
        mainStyles = items.map(it => _effectiveStyle(it, false, null, items.length));
        satellite = null;
        highlightedIndex = -1;
        deadZone = true;
        _pastOuterHandled = false;
        _recomputeHighlight();
        _dumpState();
    }

    function _reloadConfig() {
        const path = _pathFor(menuName);
        if (configFile.path === path)
            configFile.reload();
        else
            configFile.path = path;
    }

    FileView {
        id: configFile
        printErrors: false // a missing file is not an error
        onLoaded: root._applyConfig(root._parseConfig(text()))
        onLoadFailed: {
            // The default menu falls back to default.json; a named menu
            // with no file is an empty ring.
            if (root.menuName === "")
                root._applyConfig(root._parseConfig(defaultConfigFile.text()));
            else
                root._applyConfig({ styleRaw: {}, items: [] });
        }
    }

    FileView {
        id: defaultConfigFile
        path: root._defaultConfigPath
        printErrors: false
    }

    // ── state dump, for the tests ─────────────────────────────────────

    function _styleDump(s) {
        return {
            shape: s.shape, cornerRadius: s.cornerRadius, size: s.size,
            glowColor: s.glowColor, glowSize: s.glowSize, ringRadius: s.ringRadius,
            captionSize: s.captionSize, caption: s.caption, backdrop: s.backdrop
        };
    }

    function _itemsDump(its, styles) {
        return its.map((it, i) => ({
            label: it.label,
            icon: it.icon ?? "",
            kind: it.items ? "group" : "leaf",
            style: _styleDump(styles[i] ?? _baseStyle(false, its.length))
        }));
    }

    // Called by hand at the end of every function that changes several of
    // these properties together, never from a property-change handler:
    // a handler would fire after the first property changes and log a
    // half-updated state.
    function _dumpState() {
        if (!root._dump)
            return;
        console.info("appring state " + JSON.stringify({
            visible: root._open,
            items: root._itemsDump(root.items, root.mainStyles),
            highlighted: root.highlightedIndex,
            deadZone: root.deadZone,
            centreX: Math.round(root.centreX),
            centreY: Math.round(root.centreY),
            satellite: root.satellite ? {
                parentIndex: root.satellite.parentIndex,
                items: root._itemsDump(root.satellite.items, root.satellite.styles),
                highlighted: root.satellite.highlighted,
                deadZone: root.satellite.deadZone,
                centreX: Math.round(root.satellite.centreX),
                centreY: Math.round(root.satellite.centreY)
            } : null
        }));
    }

    // Its screen going away while open closes it.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (root._open && !root._realScreens().includes(root.screen))
                root.cancel();
        }
    }

    IpcHandler {
        target: "appring"
        function open(name: string): void { root.open(name); }
        function commit(): void { root.commit(); }
        function cancel(): void { root.cancel(); }
        function toggle(name: string): void { root.toggle(name); }
        function settings(): void { root.settingsRequested(); }
    }
    // the old target, from when the app was called ring-app: key binds keep working
    IpcHandler {
        target: "ring"
        function open(name: string): void { root.open(name); }
        function commit(): void { root.commit(); }
        function cancel(): void { root.cancel(); }
        function toggle(name: string): void { root.toggle(name); }
        function settings(): void { root.settingsRequested(); }
    }

    Timer {
        id: groupTimer
        interval: root._restMs
        onTriggered: {
            if (root.satellite)
                return;
            const cur = root._current;
            if (cur && cur.items && !root._pastOuterHandled) {
                root._pastOuterHandled = true;
                root._openSatellite(root.highlightedIndex);
            }
        }
    }

    // The satellite's close grace: started when a close condition first
    // holds, stopped when it stops holding. When it fires, the highlight is
    // recomputed at once, so the main ring takes over without another move.
    Timer {
        id: satCloseTimer
        interval: root._satCloseGraceMs
        onTriggered: {
            if (!root.satellite)
                return;
            root.satellite = null;
            root._pastOuterHandled = false;
            groupTimer.stop();
            root._recomputeHighlight();
        }
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                event.accepted = true;
                root.cancel();
            }
        }
        Keys.onReleased: event => {
            if (root._matchesReleaseKey(event.key)) {
                event.accepted = true;
                root.commit();
            }
        }

        // the ring that just closed, fading away
        Ring {
            anchors.fill: parent
            visible: !!root._fade
            items: root._fade ? root._fade.items : []
            styles: root._fade ? root._fade.styles : []
            highlighted: root._fade ? root._fade.highlighted : -1
            deadZone: root._fade ? root._fade.deadZone : true
            centreX: root._fade ? root._fade.centreX : -1
            centreY: root._fade ? root._fade.centreY : -1
            pointerAngle: root._fade ? root._fade.pointerAngle : 0
            ringVisible: !!root._fade
            satellite: root._fade ? root._fade.satellite : null
            closeT: root._fadeT
            closeMs: root._fade ? root._fade.ms : 0
            flashMain: root._fade ? root._fade.flashMain : -1
            flashSat: root._fade ? root._fade.flashSat : -1
            presetMain: root._fade ? root._fade.mainColours : ({})
            presetSat: root._fade ? root._fade.satColours : ({})
            spin: root.spinAngle
        }

        // the live ring: hidden the moment the menu closes (the fading copy
        // above takes over), so nothing is drawn from its reset centre
        Ring {
            id: liveRing
            anchors.fill: parent
            visible: root._open
            spin: root.spinAngle
            items: root.items
            styles: root.mainStyles
            highlighted: root.highlightedIndex
            deadZone: root.deadZone
            centreX: root.centreX
            centreY: root.centreY
            pointerAngle: root._pointerAngle
            ringVisible: root._centreEstablished
            satellite: root.satellite
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPositionChanged: mouse => {
                root._pointerX = mouse.x;
                root._pointerY = mouse.y;
                if (!root._open)
                    return;   // closed, the ring fading away
                if (!root._centreEstablished) {
                    // The first position this session is the centre, exactly
                    // (or the middle of the screen, "Open at the cursor" off).
                    root.centreX = Settings.atCursor ? mouse.x : root.width / 2;
                    root.centreY = Settings.atCursor ? mouse.y : root.height / 2;
                    root._centreEstablished = true;
                    root._dumpState();
                }
                root._hasPointer = true;
                root._recomputeHighlight();
            }
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    root.cancel();
                    return;
                }
                root.commit();
            }
        }
    }

    function _matchesReleaseKey(key) {
        switch (root._releaseKey) {
        case "Alt":
            return key === Qt.Key_Alt;
        case "Ctrl":
            return key === Qt.Key_Control;
        case "Shift":
            return key === Qt.Key_Shift;
        default:
            return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta;
        }
    }
}

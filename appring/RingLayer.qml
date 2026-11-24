// Drawing only: one ring's buttons and its centre indicator. Used twice
// (Ring.qml): for the main ring and for a satellite. It draws "a ring of
// items with resolved styles, a highlight, a centre and a direction",
// exactly what Radial.qml hands it.
//
// The look follows the classic radial action menus of games: square icon
// buttons floating on an invisible circle, no backdrop, no captions; each
// slice has its own colour (`style.glowColor`), shown as the button's thin
// border; the highlighted button grows a little and its border brightens.
// The centre is a spinning ring in two halves, glowing outside in the
// highlighted slice's colour, with a chevron chasing the cursor.
//
// Every size and colour a button uses comes from its own resolved style
// (`styles[index]`, Radial.qml's cascade): `shape` ("rounded-square" or
// "circle"), `cornerRadius`, `size`, `glowColor`, `glowSize`, `ringRadius`,
// `captionSize`, `caption` ("none", "selected", "all"), `backdrop`.
// `brightIndex`/`dimOpacity` let Ring.qml dim the other main-ring buttons
// while a satellite is open.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Widgets

Item {
    id: ringLayer
    property var items: []
    property var styles: []        // parallel to `items`: one resolved style object each
    property int highlighted: -1
    property bool deadZone: true
    property real centreX: width / 2
    property real centreY: height / 2
    property real pointerAngle: 0
    // False until this ring has a real centre: the layer stays invisible
    // until then, so it never jumps once the centre lands.
    property bool ringVisible: false
    // The one index kept at full opacity (the open group's button while
    // its satellite is up); -1: none.
    property int brightIndex: -1
    // Applied to every button except `brightIndex`; 1.0: nothing dimmed.
    property real dimOpacity: 1.0
    // The centre ring and chevron. A satellite has none: its centre
    // is its group's own button, which must stay visible.
    property bool showCentre: true
    // Closing: `closeT` runs 0 to 1 over `closeMs` while the ring goes away,
    // by the "closing" setting ("fade", "zoom", "spiral", "none"); the item
    // just run (`flashIndex`) flashes meanwhile, then goes too.
    property real closeT: 0
    property int closeMs: 0
    property int flashIndex: -1
    readonly property real _elapsed: closeT * closeMs
    // how far everything but the flashing button has gone (0 to 1)
    readonly property real _gone: closeT <= 0 ? 0 : (Theme.closeMs > 0 ? Math.min(1, _elapsed / Theme.closeMs) : 1)
    readonly property real _goneEased: _gone * _gone
    readonly property string _closing: Settings.closing
    readonly property bool _spiral: _closing === "spiral"
    readonly property bool _zoom: _closing === "zoom"

    // Colours taken from the icons, by index (see the sampler in each button);
    // `presetColours`: ones already known (the closing copy gets the live
    // ring's), used until this layer has sampled its own.
    property var iconColours: ({})
    property var presetColours: ({})

    // The centre ring's turn, in degrees. Its own clock by default; the ring
    // passes one shared clock to its live and its closing copy, so the turn
    // carries on when the ring closes.
    property real spin: _ownSpin
    property real _ownSpin: 0
    NumberAnimation on _ownSpin {
        from: 0
        to: 360
        duration: Math.max(1, Theme.centreSpinMs)
        loops: Animation.Infinite
        running: ringLayer.ringVisible && ringLayer.showCentre && !Theme.reducedMotion && Theme.centreSpinMs > 0
    }
    // where the chevron points now (it swings round to the cursor)
    readonly property real chevronAngle: (Theme.reducedMotion || Settings.instantPointer) ? pointerAngle : centre.pointerShown

    // A slice's colour: "auto" takes it from the icon (the "Colours from
    // icons" setting; else, or while the icon loads, Theme.slicePalette by
    // position), a role name picks that Theme role, "#rrggbb" is used as is.
    function sliceColor(index) {
        const name = styles[index]?.glowColor ?? "auto";
        if (name === "auto" && Settings.iconColors && iconColours[index] !== undefined)
            return iconColours[index];
        if (name === "auto" && Settings.iconColors && presetColours[index] !== undefined)
            return presetColours[index];
        if (typeof name === "string" && name.startsWith("#"))
            return name;
        switch (name) {
        case "accent": return Theme.accent;
        case "warn": return Theme.warn;
        case "error": return Theme.error;
        case "ok": return Theme.ok;
        case "muted": return Theme.muted;
        case "dim": return Theme.dim;
        case "text": return Theme.text;
        default: return Theme.slicePalette[Math.max(0, index) % Theme.slicePalette.length];
        }
    }

    // The slots: by default one per item, the first straight up. A ghost ring
    // has one slot more than items (its first is the group's own button) and
    // starts pointing back at the main ring.
    property var faces: []          // what each button shows (a group's face), parallel to `items`
    property int slotCount: 0       // 0: one slot per item
    property int slotOffset: 0      // the first item's slot
    property real startAngle: 0     // the first slot's angle, degrees, 0 = up, clockwise
    function _angleOf(index) {
        const n = slotCount > 0 ? slotCount : items.length;
        return n ? startAngle + (index + slotOffset) * (360 / n) : 0;
    }

    // Grows from 0 to 1 when the ring opens: the buttons come out from the
    // centre. Animate in, snap out: closing (ringVisible -> false) disables
    // the Behavior, so nothing lingers at the old centre when the next open
    // lands somewhere else.
    // Set by hand, not bound: it zooms in when the ring shows and again when an
    // open ring gets new items (a jump, or back); it snaps back when hidden.
    property real spread: 1
    Component.onCompleted: spread = ringVisible ? 1 : Theme.zoomFrom
    onRingVisibleChanged: {
        if (!ringVisible) {
            rezoom.stop();
            spread = Theme.zoomFrom;
        } else if (Theme.open > 0) {
            rezoom.restart();
        } else {
            spread = 1;
        }
    }
    onItemsChanged: iconColours = ({})   // other items: their colours are sampled afresh
    // a jump into a group, or back (Ring.zoomKey): zoom in again
    property int zoomKey: 0
    onZoomKeyChanged: if (ringVisible && Theme.open > 0) rezoom.restart()
    NumberAnimation {
        id: rezoom
        target: ringLayer
        property: "spread"
        from: Theme.zoomFrom
        to: 1
        duration: Theme.open
        easing.type: Easing.OutQuad
    }

    // An optional soft halo around the ring (`style.backdrop: true` on any
    // item): a radial gradient fading to transparent. Off by default.
    Shape {
        id: backdrop
        readonly property bool _wanted: ringLayer.styles.some(s => s && s.backdrop === true)
        readonly property real _maxRing: ringLayer.styles.length ? Math.max(...ringLayer.styles.map(s => s.ringRadius ?? Theme.ringRadiusFor(ringLayer.items.length))) : Theme.ringRadiusFor(ringLayer.items.length)
        readonly property real d: (_maxRing + 70) * 2
        visible: _wanted
        x: ringLayer.centreX - d / 2
        y: ringLayer.centreY - d / 2
        width: d
        height: d
        opacity: ringLayer.ringVisible ? 1 : 0
        Behavior on opacity {
            enabled: ringLayer.ringVisible
            NumberAnimation { duration: Theme.fast }
        }
        ShapePath {
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: backdrop.width / 2
                centerY: backdrop.height / 2
                centerRadius: backdrop.width / 2
                focalX: centerX
                focalY: centerY
                GradientStop { position: 0.0; color: Qt.rgba(Theme.popup.r, Theme.popup.g, Theme.popup.b, 0.6) }
                GradientStop { position: 0.6; color: Qt.rgba(Theme.popup.r, Theme.popup.g, Theme.popup.b, 0.32) }
                GradientStop { position: 1.0; color: Qt.rgba(Theme.popup.r, Theme.popup.g, Theme.popup.b, 0) }
            }
            startX: 0
            startY: 0
            PathLine { x: backdrop.width; y: 0 }
            PathLine { x: backdrop.width; y: backdrop.height }
            PathLine { x: 0; y: backdrop.height }
            PathLine { x: 0; y: 0 }
        }
    }

    Text {
        visible: ringLayer.items.length === 0 && ringLayer.ringVisible
        anchors.centerIn: parent
        text: "No items in this menu"
        color: Theme.text
        style: Text.Outline
        styleColor: "#000000"
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }

    // ── the centre: a thick ring in two halves, with two small notches
    // between them (narrower inside than outside), spinning; a soft glow
    // outside it, missing in a wedge at each notch; a chevron that chases
    // the cursor. Focused: the ring, glow and chevron in the slice's colour;
    // nothing focused: the ring and chevron faint white, no glow.
    Item {
        id: centre
        visible: ringLayer.showCentre
        readonly property real ro: Theme.centreOuter
        readonly property real ri: Theme.centreOuter - Theme.centreWidth
        readonly property bool _active: !ringLayer.deadZone && ringLayer.highlighted >= 0
        readonly property color target: _active ? Qt.lighter(ringLayer.sliceColor(ringLayer.highlighted), Theme.centreLit) : Theme.centreIdle
        // the colour, the glow and how solid the ring is: all ease between states
        property color c: target
        Behavior on c { ColorAnimation { duration: Theme.state; easing.type: Easing.OutQuad } }
        property real glowShown: _active ? 1 : 0
        Behavior on glowShown { NumberAnimation { duration: Theme.glowFade; easing.type: Easing.OutQuad } }
        property real ringAlpha: _active ? Theme.centreActiveAlpha : Theme.centreIdleAlpha
        Behavior on ringAlpha { NumberAnimation { duration: Theme.state; easing.type: Easing.OutQuad } }
        property real chevronAlpha: _active ? Theme.centreActiveAlpha : Theme.chevronIdleAlpha
        Behavior on chevronAlpha { NumberAnimation { duration: Theme.state; easing.type: Easing.OutQuad } }
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real spin: ringLayer.spin
        // where the first notch is (the other is opposite): 3 o'clock, turning
        readonly property real phi: 90 + spin
        width: (ro + 120) * 2
        height: width
        x: ringLayer.centreX - width / 2
        y: ringLayer.centreY - height / 2
        scale: (ringLayer.ringVisible ? 1 : Theme.zoomFrom) * (ringLayer._spiral ? 1 + 0.25 * ringLayer._goneEased : ringLayer._zoom ? 1 - ringLayer._goneEased : 1)
        opacity: (ringLayer.ringVisible ? 1 : 0) * (1 - ringLayer._goneEased)
        Behavior on scale {
            enabled: ringLayer.ringVisible
            NumberAnimation { duration: Theme.open; easing.type: Easing.OutQuad }
        }
        Behavior on opacity {
            enabled: ringLayer.ringVisible
            NumberAnimation { duration: Theme.open * 0.6 }
        }

        // The chevron's angle chases the cursor's: the further behind, the
        // faster (degrees per second), so it swings round smoothly.
        property real pointerShown: ringLayer.pointerAngle
        Connections {
            target: ringLayer
            function onRingVisibleChanged() { centre.pointerShown = ringLayer.pointerAngle; }
            function onDeadZoneChanged() { if (ringLayer.deadZone) centre.pointerShown = ringLayer.pointerAngle; }
        }
        FrameAnimation {
            running: centre.visible && ringLayer.ringVisible && !ringLayer.deadZone && !Theme.reducedMotion && !Settings.instantPointer
            onTriggered: {
                const want = ringLayer.pointerAngle;
                const d = ((want - centre.pointerShown) % 360 + 540) % 360 - 180;
                const ad = Math.abs(d);
                const rad = Math.PI / 180;
                const rate = ad > 60 ? 420 + 120 * Math.sin(Math.min(90, ad - 60) * rad)
                           : ad > 15 ? 180 + 240 * Math.sin(Math.min(90, (ad - 15) * 2) * rad)
                           : 20 + 160 * Math.sin(Math.min(90, ad * 6) * rad);
                const step = 1.25 * rate * Math.max(0.05, Settings.pointerSpeed) * frameTime;
                centre.pointerShown = ad <= step ? want : (centre.pointerShown + Math.sign(d) * step + 360) % 360;
            }
        }

        // angles in degrees, 0 = up, clockwise
        function px(rho, deg) { return cx + rho * Math.sin(deg * Math.PI / 180); }
        function py(rho, deg) { return cy - rho * Math.cos(deg * Math.PI / 180); }

        // Two halves of a band between radii `inner` and `outer`, the two
        // notches at `phi` and opposite, `gIn`/`gOut` degrees wide (each
        // side) at the inner and outer edge. Filled with `fill`, or `grad`.
        component Halves: Shape {
            id: band
            property real inner
            property real outer
            property real gIn
            property real gOut
            property color fill: "transparent"
            property ShapeGradient grad: null
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: "transparent"
                fillColor: band.fill
                fillGradient: band.grad
                startX: centre.px(band.outer, centre.phi + band.gOut)
                startY: centre.py(band.outer, centre.phi + band.gOut)
                PathArc {
                    x: centre.px(band.outer, centre.phi + 180 - band.gOut); y: centre.py(band.outer, centre.phi + 180 - band.gOut)
                    radiusX: band.outer; radiusY: band.outer; direction: PathArc.Clockwise
                }
                PathLine { x: centre.px(band.inner, centre.phi + 180 - band.gIn); y: centre.py(band.inner, centre.phi + 180 - band.gIn) }
                PathArc {
                    x: centre.px(band.inner, centre.phi + band.gIn); y: centre.py(band.inner, centre.phi + band.gIn)
                    radiusX: band.inner; radiusY: band.inner; direction: PathArc.Counterclockwise
                }
                PathLine { x: centre.px(band.outer, centre.phi + band.gOut); y: centre.py(band.outer, centre.phi + band.gOut) }
            }
            ShapePath {
                strokeColor: "transparent"
                fillColor: band.fill
                fillGradient: band.grad
                startX: centre.px(band.outer, centre.phi + 180 + band.gOut)
                startY: centre.py(band.outer, centre.phi + 180 + band.gOut)
                PathArc {
                    x: centre.px(band.outer, centre.phi + 360 - band.gOut); y: centre.py(band.outer, centre.phi + 360 - band.gOut)
                    radiusX: band.outer; radiusY: band.outer; direction: PathArc.Clockwise
                }
                PathLine { x: centre.px(band.inner, centre.phi + 360 - band.gIn); y: centre.py(band.inner, centre.phi + 360 - band.gIn) }
                PathArc {
                    x: centre.px(band.inner, centre.phi + 180 + band.gIn); y: centre.py(band.inner, centre.phi + 180 + band.gIn)
                    radiusX: band.inner; radiusY: band.inner; direction: PathArc.Counterclockwise
                }
                PathLine { x: centre.px(band.outer, centre.phi + 180 + band.gOut); y: centre.py(band.outer, centre.phi + 180 + band.gOut) }
            }
        }

        // the glow: from the ring's outer edge outward, fading; missing in a
        // wedge at each notch
        Halves {
            id: glow
            visible: centre.glowShown > 0.001
            readonly property real reach: centre.ro * Theme.centreGlowReach
            readonly property real edge: centre.ro / reach
            readonly property real a: Theme.centreGlowAlpha * centre.glowShown
            inner: centre.ro - 0.5
            outer: reach
            gIn: Theme.glowNotchIn
            gOut: Theme.glowNotchOut
            grad: RadialGradient {
                centerX: centre.cx
                centerY: centre.cy
                centerRadius: glow.reach
                focalX: centerX
                focalY: centerY
                GradientStop { position: 0.0; color: Qt.rgba(centre.c.r, centre.c.g, centre.c.b, glow.a) }
                GradientStop { position: glow.edge; color: Qt.rgba(centre.c.r, centre.c.g, centre.c.b, glow.a) }
                GradientStop { position: glow.edge + (1 - glow.edge) * 0.25; color: Qt.rgba(centre.c.r, centre.c.g, centre.c.b, glow.a * 0.5) }
                GradientStop { position: glow.edge + (1 - glow.edge) * 0.6; color: Qt.rgba(centre.c.r, centre.c.g, centre.c.b, glow.a * 0.15) }
                GradientStop { position: 1.0; color: Qt.rgba(centre.c.r, centre.c.g, centre.c.b, 0) }
            }
        }
        // the ring
        Halves {
            inner: centre.ri
            outer: centre.ro
            gIn: Theme.ringNotchIn
            gOut: Theme.ringNotchOut
            fill: centre.c
            opacity: centre.ringAlpha
        }

        // The chevron: a shallow "^" well outside the ring, toward the cursor.
        // Hidden in the dead zone.
        Item {
            anchors.fill: parent
            visible: !ringLayer.deadZone
            rotation: ringLayer.chevronAngle
            opacity: centre.chevronAlpha
            Shape {
                id: chevron
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property real tipY: centre.cy - Theme.chevronDistance
                readonly property real arm: Theme.chevronArm
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: centre.c
                    strokeWidth: Theme.chevronWidth
                    capStyle: ShapePath.FlatCap
                    joinStyle: ShapePath.MiterJoin
                    startX: centre.cx - chevron.arm
                    startY: chevron.tipY + chevron.arm * Theme.chevronRise
                    PathLine { x: centre.cx; y: chevron.tipY }
                    PathLine { x: centre.cx + chevron.arm; y: chevron.tipY + chevron.arm * Theme.chevronRise }
                }
            }
        }
    }

    // ── the buttons ──────────────────────────────────────────────────────
    Repeater {
        model: ringLayer.items
        delegate: Item {
            id: button
            required property var modelData
            required property int index
            readonly property var _style: ringLayer.styles[index] ?? ({})
            readonly property real _angleDeg: ringLayer._angleOf(index)
            // what it shows: the item, or a group's face (the item it would run)
            readonly property var _face: ringLayer.faces[index] ?? modelData
            readonly property real _angleRad: _angleDeg * Math.PI / 180
            readonly property bool _active: index === ringLayer.highlighted && !ringLayer.deadZone
            readonly property bool _isGroup: !!button.modelData.items
            readonly property real _ringRadius: _style.ringRadius ?? Theme.ringRadiusFor(ringLayer.items.length)
            readonly property real _size: _style.size ?? Theme.radialButtonSize
            readonly property real _glowPad: _style.glowSize ?? Theme.radialGlowPad
            readonly property real _captionSize: _style.captionSize ?? Theme.fontSmall
            readonly property string _caption: _style.caption ?? "none"
            readonly property color _c: ringLayer.sliceColor(index)
            readonly property real _dim: index === ringLayer.brightIndex ? 1 : ringLayer.dimOpacity

            // The corner radius for a rectangle of `sizePx` in this button's shape.
            function radiusFor(sizePx) {
                return (_style.shape === "circle") ? sizePx / 2 : sizePx * (_style.cornerRadius ?? Theme.radialCornerFraction);
            }

            width: _size
            height: width
            // closing: turn and drift outward (spiral), or shrink to the centre
            readonly property bool _flashing: index === ringLayer.flashIndex && ringLayer.closeMs > 0
            // The flash, 0 to 1 over Theme.flashMs, like an arcade hit: the
            // button pops up fast with a little overshoot, a white light peaks
            // early, a shockwave outline rings outward, then it fades.
            readonly property real _fp: _flashing && Theme.flashMs > 0 ? Math.min(1, ringLayer._elapsed / Theme.flashMs) : 0
            readonly property real _rise: Math.min(1, _fp / 0.22)
            readonly property real _pop: _flashing ? 1 + 2.70158 * Math.pow(_rise - 1, 3) + 1.70158 * Math.pow(_rise - 1, 2) : 0
            readonly property real _peak: !_flashing ? 0 : _fp < 0.18 ? _fp / 0.18 : Math.max(0, 1 - (_fp - 0.18) / 0.5)
            readonly property real _g: _flashing ? 0 : ringLayer._goneEased   // the flashing button stays put
            readonly property real _a: (_angleDeg + (ringLayer._spiral ? Theme.spiralTurn * _g : 0)) * Math.PI / 180
            readonly property real _r: ringLayer._spiral ? _ringRadius * ringLayer.spread + Theme.spiralOut * _g
                                     : ringLayer._zoom ? _ringRadius * ringLayer.spread * (1 - _g)
                                     : _ringRadius * ringLayer.spread
            x: ringLayer.centreX + _r * Math.sin(_a) - width / 2
            y: ringLayer.centreY - _r * Math.cos(_a) - height / 2
            z: _active ? 1 : 0
            scale: (ringLayer.ringVisible ? (_active ? Theme.radialHighlightScale : 1) : Theme.zoomFrom) * (1 + Theme.flashPop * _pop)
            // closing: gone with the rest; the flashing button after its flash peaks
            opacity: (ringLayer.ringVisible ? 1 : 0) * _dim
                     * (_flashing ? (_fp < 0.55 ? 1 : 1 - (_fp - 0.55) / 0.45) : 1 - _g)
            Behavior on scale {
                enabled: ringLayer.ringVisible
                NumberAnimation { duration: Theme.fast; easing.type: Theme.easing }
            }
            Behavior on opacity {
                enabled: ringLayer.ringVisible
                NumberAnimation { duration: Theme.open * 0.6 }
            }

            // a dark outline, so the button reads on any background
            Rectangle {
                anchors.fill: parent
                anchors.margins: -1.5
                radius: button.radiusFor(button.width) + 1.5
                color: "#000000"
                opacity: 0.8
            }
            // the tile: dark, a little lighter at the top
            Rectangle {
                anchors.fill: parent
                radius: button.radiusFor(width)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.tileTop }
                    GradientStop { position: 1.0; color: Theme.tileBottom }
                }
            }
            // The icon's own colour, for "auto" slice colours: drawn small,
            // its pixels averaged, the vivid ones counting most.
            Canvas {
                id: sampler
                visible: false
                width: 24
                height: 24
                renderStrategy: Canvas.Immediate
                readonly property string src: button._face.icon ? Quickshell.iconPath(button._face.icon, true) : ""
                onSrcChanged: if (src !== "") { loadImage(src); if (isImageLoaded(src)) requestPaint(); }
                Component.onCompleted: if (src !== "") loadImage(src)
                onImageLoaded: requestPaint()
                onPaint: {
                    if (src === "" || !isImageLoaded(src))
                        return;
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(src, 0, 0, width, height);
                    const d = ctx.getImageData(0, 0, width, height).data;
                    let r = 0, g = 0, b = 0, w = 0;
                    for (let i = 0; i < d.length; i += 4) {
                        const a = d[i + 3] / 255;
                        if (a < 0.5)
                            continue;
                        const R = d[i] / 255, G = d[i + 1] / 255, B = d[i + 2] / 255;
                        const mx = Math.max(R, G, B), mn = Math.min(R, G, B);
                        const sat = mx > 0 ? (mx - mn) / mx : 0;
                        const k = a * (0.05 + sat * sat) * (0.3 + mx);
                        r += R * k; g += G * k; b += B * k; w += k;
                    }
                    if (w <= 0)
                        return;
                    // the average, then made vivid and bright like a border light
                    const c = Qt.rgba(r / w, g / w, b / w, 1);
                    const h = c.hslHue < 0 ? 0 : c.hslHue;
                    if (c.hslSaturation < 0.12)
                        return;   // a grey icon: the palette colour stays
                    const col = Qt.hsla(h, Math.max(0.55, c.hslSaturation), 0.6, 1);
                    const next = Object.assign({}, ringLayer.iconColours);
                    next[button.index] = col;
                    ringLayer.iconColours = next;
                }
            }

            // the icon fills the tile
            IconImage {
                anchors.centerIn: parent
                implicitSize: Math.round(button._size * Theme.radialIconFill)
                source: button._face.icon ? Quickshell.iconPath(button._face.icon, true) : ""
                asynchronous: true
            }
            // the run flash's shockwave: an outline in the slice's colour,
            // ringing outward and fading
            Rectangle {
                visible: button._flashing && button._fp < 1
                anchors.centerIn: parent
                width: parent.width * (1 + Theme.flashWave * (1 - Math.pow(1 - button._fp, 3)))
                height: width
                radius: button.radiusFor(width)
                color: "transparent"
                border.width: 3 * Theme.s
                border.color: Qt.lighter(button._c, 1.3)
                opacity: 0.9 * (1 - button._fp)
            }
            // the run flash: a white light over the tile
            Rectangle {
                visible: button._peak > 0.001
                anchors.fill: parent
                radius: button.radiusFor(width)
                color: "#ffffff"
                opacity: Theme.flashLight * button._peak
            }
            // the slice's colour as the border; brighter when highlighted
            Rectangle {
                anchors.fill: parent
                radius: button.radiusFor(width)
                color: "transparent"
                border.width: 2
                border.color: button._active ? Qt.lighter(button._c, 1.2) : Qt.darker(button._c, 1.25)
                Behavior on border.color {
                    ColorAnimation { duration: Theme.fast }
                }
            }

            // A group: a small arrow on the button's outer edge, pointing
            // away from the centre (a flyout).
            Item {
                visible: button._isGroup
                width: parent.width
                height: parent.height
                rotation: button._angleDeg
                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: Qt.rgba(0, 0, 0, 0.8)
                        strokeWidth: 1
                        fillColor: button._c
                        startX: button.width / 2 - 6
                        startY: -3
                        PathLine { x: button.width / 2; y: -10 }
                        PathLine { x: button.width / 2 + 6; y: -3 }
                        PathLine { x: button.width / 2 - 6; y: -3 }
                    }
                }
            }

            // The caption: none by default; `style.caption` "selected" shows
            // the highlighted one, "all" every one (a group's with a "›").
            Text {
                visible: button._caption === "all" || (button._caption === "selected" && button._active)
                anchors.top: parent.bottom
                anchors.topMargin: 5
                anchors.horizontalCenter: parent.horizontalCenter
                text: (button._face.label ?? "") + (button._isGroup ? " \u203a" : "")
                color: Theme.text
                style: Text.Outline
                styleColor: "#000000"
                font.family: Theme.font
                font.pixelSize: button._captionSize
                font.bold: button._active
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}

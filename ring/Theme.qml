pragma Singleton

// Colours, fonts, motion and the ring's sizes. The palette is Catppuccin
// Mocha.

import QtQuick
import Quickshell

Singleton {
    // ── colour roles ────────────────────────────────────────────────────
    readonly property color text: "#cdd6f4"
    readonly property color dim: "#a6adc8"
    readonly property color muted: "#6c7086"
    readonly property color accent: "#b4a1db"
    readonly property color ok: "#a6e3a1"
    readonly property color warn: "#f9e2af"
    readonly property color error: "#f38ba8"

    readonly property color popup: "#1e1e2e"
    readonly property color popupEdge: "#45475a"

    readonly property string font: "JetBrainsMono Nerd Font"
    readonly property int fontSize: 13
    readonly property int fontSmall: 11

    // A state change moves, at rest it is calm. No animation with the
    // "Animate transitions" setting off, or RING_APP_REDUCED_MOTION=1.
    readonly property bool reducedMotion: Quickshell.env("RING_APP_REDUCED_MOTION") === "1" || !Settings.animate
    // (the speeds are settings: see Settings.qml)
    function _ms(v) { return reducedMotion ? 0 : Math.max(0, Math.round(v)); }
    readonly property int fast: _ms(Settings.growMs)      // the highlighted button growing
    readonly property int open: _ms(Settings.openMs)      // opening: the ring zooms in
    readonly property int state: _ms(Settings.stateMs)    // active <-> inactive, one item to the next
    readonly property int glowFade: _ms(Settings.glowMs)  // the centre's glow fading in and out
    readonly property int easing: Easing.OutCubic

    // Every size below follows the "Ring scale" setting.
    readonly property real s: Math.max(0.25, Settings.scale)

    // ── the ring ────────────────────────────────────────────────────────
    readonly property real radialDeadZone: Math.max(0, Settings.deadZone) * s   // px from centre: nothing is active; committing here cancels
    readonly property real radialOuterMargin: 70 * s    // moving this far past a group's button opens it
    readonly property real radialMinRadius: 110 * s     // the buttons' circle, at least this big...
    readonly property real radialSlotSize: 54 * s       // ...and big enough for this much room per button
    readonly property real radialButtonSize: 48 * s
    readonly property real radialIconFill: 60 / 64      // the icon's size, as a fraction of the button's
    readonly property real radialGlowPad: 10 * s        // the selected button's glow, past its own edge
    readonly property real radialHighlightScale: Settings.enlargeSelected ? 1.1 : 1
    readonly property real radialCornerFraction: 0.14   // "rounded-square" corner, as a fraction of the size
    readonly property real radialSatelliteScale: 0.8    // a satellite ring is this much smaller
    // the buttons' circle for `count` buttons
    function ringRadiusFor(count) {
        return Math.max(radialMinRadius, count * radialSlotSize / (2 * Math.PI));
    }

    // ── the look: tiles, slice colours, the centre ring ────────────────────
    readonly property color tileTop: "#2b2e38"
    readonly property color tileBottom: "#121318"
    // slice colours by position, when a colour cannot come from the icon
    readonly property var slicePalette: ["#e8c33a", "#d93a3a", "#4bbf2f", "#3a86e0", "#9d4fe6", "#e8792a", "#2ab3a3", "#e05fa5"]
    readonly property real zoomFrom: 1.35         // opening: the ring starts this much bigger and shrinks in
    readonly property real spiralTurn: 45         // closing with the spiral: degrees the buttons turn
    readonly property real spiralOut: 40 * s      // and px they drift outward
    // closing, by the "closing" setting: how long it takes
    readonly property int closeMs: Settings.closing === "none" ? 0 : _ms(Settings.closeMs)
    // running an item: its button's flash
    readonly property int flashMs: Settings.flash ? _ms(Settings.flashMs) : 0
    readonly property real flashPop: Math.max(0, Settings.flashPop)   // the flashing button pops this much bigger
    readonly property real flashLight: 0.65       // a white light over it, this strong at its peak
    readonly property real flashWave: 0.9         // its shockwave outline grows to this much bigger
    // the centre ring
    readonly property real centreOuter: 31 * s    // outer radius
    readonly property real centreWidth: 7.5 * s   // thickness
    readonly property real ringNotchIn: 1.8       // degrees, each side of a notch, at the inner edge
    readonly property real ringNotchOut: 2.7      // and at the outer edge (wider outside)
    readonly property int centreSpinMs: Math.round(Math.max(0, Settings.spinSeconds) * 1000)   // one turn, clockwise; 0: still
    readonly property real centreActiveAlpha: 0.9 // the ring and chevron with an item focused
    readonly property real centreIdleAlpha: 0.3   // the ring with nothing focused
    readonly property real chevronIdleAlpha: 0.15 // the chevron with nothing focused
    readonly property real centreLit: 1.1         // focused, the ring's colour this much lighter
    readonly property color centreIdle: "#ffffff" // the ring and chevron with nothing focused
    // the glow outside the ring, an item focused
    readonly property real centreGlowReach: 2.05  // to this many times the ring's outer radius
    readonly property real centreGlowAlpha: Math.min(1, Math.max(0, Settings.glowStrength))   // strength at the ring
    readonly property real glowNotchIn: 2         // degrees, each side of its wedge, at the ring
    readonly property real glowNotchOut: 5        // and at its outer edge
    // the chevron
    readonly property real chevronDistance: 66 * s   // px from the centre to its tip
    readonly property real chevronArm: 23 * s        // half its width
    readonly property real chevronRise: 0.45         // how far its arms drop, per px of arm
    readonly property real chevronWidth: 4.5 * s
    // Pointing between two items selects nothing: this fraction of each
    // item's sector, half on each side, is the gap (the "Gap between
    // slices" setting; 0 by default).
    readonly property real radialSliceGap: Math.min(0.5, Math.max(0, Settings.sliceGap))

    // ── when a satellite (a group's own small ring) closes ──────────────
    // Near the group's own button nothing inside is highlighted: a multiple
    // of that button's own size.
    readonly property real radialSatelliteButtonZoneScale: 1.2
    // It closes once the pointer is back within this fraction of the main
    // ring's radius for that item, measured from the main centre...
    readonly property real radialSatelliteCloseFraction: 0.6
    // ...or once the main angle is this many degrees past the group's own
    // half-sector.
    readonly property real radialSatelliteAngleMargin: 15
}

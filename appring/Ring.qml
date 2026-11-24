// Two RingLayers: the main ring (dimmed while a satellite is open, its
// open group's button kept bright), and the satellite, visible only while
// one is open. Radial.qml decides what is shown; this file only wires it.

import QtQuick

Item {
    id: root
    property var items: []
    property var styles: []
    property int highlighted: -1
    property bool deadZone: true
    property real centreX: width / 2
    property real centreY: height / 2
    property real pointerAngle: 0
    property bool ringVisible: false
    // null, or Radial.qml's satellite frame (see `_openSatellite` there).
    property var satellite: null
    // 0, or the closing animation's progress (0 to 1), its length, and the
    // item that was run (flashes): see RingLayer
    property real closeT: 0
    property int closeMs: 0
    property int flashMain: -1
    property int flashSat: -1
    // a shared clock for the centre ring's turn (see RingLayer.spin); -1: its own
    property real spin: -1
    // what the closing copy takes over from the live ring
    readonly property real chevronAngle: mainLayer.chevronAngle
    readonly property var mainColours: mainLayer.iconColours
    readonly property var satColours: satLayer.iconColours
    property var presetMain: ({})
    property var presetSat: ({})

    RingLayer {
        id: mainLayer
        anchors.fill: parent
        presetColours: root.presetMain
        spin: root.spin >= 0 ? root.spin : _ownSpin
        items: root.items
        styles: root.styles
        highlighted: root.highlighted
        deadZone: root.deadZone
        centreX: root.centreX
        centreY: root.centreY
        pointerAngle: root.pointerAngle
        ringVisible: root.ringVisible
        closeT: root.closeT
        closeMs: root.closeMs
        flashIndex: root.flashMain
        brightIndex: root.satellite ? root.satellite.parentIndex : -1
        dimOpacity: root.satellite ? 0.55 : 1.0
    }

    RingLayer {
        id: satLayer
        anchors.fill: parent
        presetColours: root.presetSat
        visible: !!root.satellite
        items: root.satellite ? root.satellite.items : []
        styles: root.satellite ? root.satellite.styles : []
        highlighted: root.satellite ? root.satellite.highlighted : -1
        deadZone: root.satellite ? root.satellite.deadZone : true
        showCentre: false   // its centre is the group's own button, which stays visible
        centreX: root.satellite ? root.satellite.centreX : 0
        centreY: root.satellite ? root.satellite.centreY : 0
        pointerAngle: root.satellite ? root.satellite.pointerAngle : 0
        ringVisible: root.ringVisible && !!root.satellite
        closeT: root.closeT
        closeMs: root.closeMs
        flashIndex: root.flashSat
        brightIndex: -1
        dimOpacity: 1.0
    }
}

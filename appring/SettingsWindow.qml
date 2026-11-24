// The appearance settings window: the settings in Settings.qml, saved to
// appearance.json at once, with a live preview of a ring next to them.
// Opened with `quickshell ipc -p appring call appring settings` (again: closes).

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell

FloatingWindow {
    id: win
    // the ring itself: its style rules are used for the preview
    required property var radial

    title: "appring: appearance"
    visible: false
    implicitWidth: 980
    implicitHeight: 680
    color: Theme.popup

    function toggle() {
        visible = !visible;
    }

    // ── the preview's ring: a few sample items, one highlighted after the
    // other, every fourth step nothing (the idle look) ──────────────────
    readonly property var sample: [
        { label: "Browser", icon: "firefox" },
        { label: "Terminal", icon: "utilities-terminal" },
        { label: "Files", icon: "system-file-manager" },
        { label: "Music", icon: "multimedia-audio-player" },
        { label: "Mail", icon: "internet-mail" },
        { label: "Tools", icon: "applications-utilities", items: [{ label: "x", icon: "folder" }] }
    ]
    readonly property var sampleStyles: {
        // re-resolved when a setting changes
        Settings.scale; Settings.labels;
        return sample.map(() => win.radial._baseStyle(false, sample.length));
    }
    // "Play close": the preview runs its focused item (flash) and closes, then
    // comes back
    property real closing: 0
    readonly property int closeLength: Math.max(Theme.closeMs, Theme.flashMs, 1)
    SequentialAnimation {
        id: playClose
        NumberAnimation { target: win; property: "closing"; from: 0; to: 1; duration: win.closeLength }
        PauseAnimation { duration: 600 }
        PropertyAction { target: win; property: "closing"; value: 0 }
    }

    property int step: 0
    readonly property bool idle: step % 4 === 3
    readonly property int pick: Math.floor(step * 0.75) % sample.length
    Timer {
        interval: 1300
        running: win.visible && !playClose.running
        repeat: true
        onTriggered: win.step++
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 24

        // ── the settings, in sections, scrolling ─────────────────────────
        ColumnLayout {
            Layout.preferredWidth: 420
            Layout.maximumWidth: 420
            Layout.fillWidth: false
            Layout.fillHeight: true
            spacing: 10

            Label {
                text: "Appearance"
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 18
                font.bold: true
            }

            component Section: Label {
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: Theme.fontSize
                font.bold: true
                topPadding: 10
            }
            component Row: RowLayout {
                property alias text: caption.text
                default property alias control: holder.data
                Layout.fillWidth: true
                Label {
                    id: caption
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize
                    Layout.fillWidth: true
                }
                Item {
                    id: holder
                    implicitWidth: childrenRect.width
                    implicitHeight: childrenRect.height
                }
            }
            component Value: Label {
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSmall
                Layout.preferredWidth: 52
                horizontalAlignment: Text.AlignRight
            }
            // a setting's slider, with its value shown by `show`
            component Amount: RowLayout {
                property real from
                property real to
                property real stepSize
                property real value
                property var show: v => v.toFixed(2)
                signal moved(real v)
                Slider {
                    from: parent.from; to: parent.to; stepSize: parent.stepSize
                    value: parent.value
                    onMoved: parent.moved(value)
                    implicitWidth: 150
                }
                Value { text: parent.show(parent.value) }
            }
            component Choice: ComboBox {
                property string current
                signal chose(string v)
                currentIndex: Math.max(0, model.indexOf(current))
                onActivated: index => chose(model[index])
                implicitWidth: 150
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: parent.width - 14
                    spacing: 8

                    Section { text: "Size and position" }
                    Row {
                        text: "Ring scale"
                        Amount { from: 0.5; to: 2; stepSize: 0.05; value: Settings.scale; onMoved: v => Settings.scale = v }
                    }
                    Row {
                        text: "Dead zone (px)"
                        Amount { from: 0; to: 120; stepSize: 2; value: Settings.deadZone; show: v => Math.round(v); onMoved: v => Settings.deadZone = v }
                    }
                    Row {
                        text: "Open at the cursor"
                        Switch { checked: Settings.atCursor; onToggled: Settings.atCursor = checked }
                    }

                    Section { text: "Behaviour" }
                    Row {
                        text: "Gap between slices"
                        Amount { from: 0; to: 0.5; stepSize: 0.05; value: Settings.sliceGap; show: v => Math.round(v * 100) + "%"; onMoved: v => Settings.sliceGap = v }
                    }
                    Row {
                        text: "Instant pointer rotation"
                        Switch { checked: Settings.instantPointer; onToggled: Settings.instantPointer = checked }
                    }
                    Row {
                        text: "Enlarge selected slice"
                        Switch { checked: Settings.enlargeSelected; onToggled: Settings.enlargeSelected = checked }
                    }
                    Row {
                        text: "Colours from icons"
                        Switch { checked: Settings.iconColors; onToggled: Settings.iconColors = checked }
                    }
                    Row {
                        text: "Slice labels"
                        Choice { model: ["none", "selected", "all"]; current: Settings.labels; onChose: v => Settings.labels = v }
                    }

                    Section { text: "Animation" }
                    Row {
                        text: "Animate transitions"
                        Switch { checked: Settings.animate; onToggled: Settings.animate = checked }
                    }
                    Row {
                        text: "Closing"
                        Choice { model: ["fade", "zoom", "spiral", "none"]; current: Settings.closing; onChose: v => Settings.closing = v }
                    }
                    Row {
                        text: "Flash on run"
                        Switch { checked: Settings.flash; onToggled: Settings.flash = checked }
                    }
                    Row {
                        text: "Opening (ms)"
                        Amount { from: 0; to: 1000; stepSize: 10; value: Settings.openMs; show: v => Math.round(v); onMoved: v => Settings.openMs = v }
                    }
                    Row {
                        text: "Closing (ms)"
                        Amount { from: 0; to: 1000; stepSize: 10; value: Settings.closeMs; show: v => Math.round(v); onMoved: v => Settings.closeMs = v }
                    }
                    Row {
                        text: "Run flash (ms)"
                        Amount { from: 0; to: 1000; stepSize: 10; value: Settings.flashMs; show: v => Math.round(v); onMoved: v => Settings.flashMs = v }
                    }
                    Row {
                        text: "Focus change (ms)"
                        Amount { from: 0; to: 800; stepSize: 10; value: Settings.stateMs; show: v => Math.round(v); onMoved: v => Settings.stateMs = v }
                    }
                    Row {
                        text: "Glow fade (ms)"
                        Amount { from: 0; to: 1000; stepSize: 10; value: Settings.glowMs; show: v => Math.round(v); onMoved: v => Settings.glowMs = v }
                    }
                    Row {
                        text: "Button grow (ms)"
                        Amount { from: 0; to: 500; stepSize: 10; value: Settings.growMs; show: v => Math.round(v); onMoved: v => Settings.growMs = v }
                    }
                    Row {
                        text: "Chevron speed"
                        Amount { from: 0.25; to: 4; stepSize: 0.25; value: Settings.pointerSpeed; show: v => v.toFixed(2) + "x"; onMoved: v => Settings.pointerSpeed = v }
                    }
                    Row {
                        text: "Centre spin (s per turn)"
                        Amount { from: 0; to: 10; stepSize: 0.5; value: Settings.spinSeconds; show: v => v > 0 ? v.toFixed(1) : "still"; onMoved: v => Settings.spinSeconds = v }
                    }

                    Section { text: "Effects" }
                    Row {
                        text: "Glow strength"
                        Amount { from: 0; to: 1; stepSize: 0.05; value: Settings.glowStrength; onMoved: v => Settings.glowStrength = v }
                    }
                    Row {
                        text: "Flash pop"
                        Amount { from: 0; to: 1; stepSize: 0.05; value: Settings.flashPop; show: v => "+" + Math.round(v * 100) + "%"; onMoved: v => Settings.flashPop = v }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: Settings.configDir + "/appearance.json"
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSmall
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Button { text: "Reset"; onClicked: Settings.reset() }
                Button { text: "Close"; onClicked: win.visible = false }
            }
        }

        // ── the preview ─────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            color: "#3b4252"
            clip: true

            RingLayer {
                anchors.fill: parent
                items: win.sample
                styles: win.sampleStyles
                highlighted: win.idle ? -1 : win.pick
                deadZone: false
                centreX: width / 2
                centreY: height / 2
                pointerAngle: win.idle ? (win.pick + 0.5) * 360 / win.sample.length : win.pick * 360 / win.sample.length
                ringVisible: win.visible && (win.closing < 1 || win.closeLength <= 1)
                closeT: win.closing
                closeMs: win.closing > 0 ? win.closeLength : 0
                flashIndex: win.idle ? -1 : win.pick
            }
            Button {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 10
                text: "Play close"
                enabled: !playClose.running
                onClicked: playClose.restart()
            }
            Label {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: 10
                text: win.idle ? "nothing focused" : "focused: " + win.sample[win.pick].label
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSmall
            }
        }
    }
}

pragma Singleton
// Stand-in for Quickshell's singleton: what appring's drawing files use of it.
import QtQuick
import SpikeHelper

QtObject {
    function env(name) { return SpikeEnv.env(name); }
    // icons by name, from the bundled icon theme (main.cpp's image provider)
    function iconPath(name, check) { return name ? "image://icon/" + name : ""; }
    readonly property string shellDir: SpikeEnv.shellDir
}

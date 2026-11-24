// Stand-in for Quickshell's FileView: reads and writes nothing (the spike runs
// with the default appearance settings).
import QtQuick

QtObject {
    property string path
    property bool watchChanges
    property bool printErrors
    default property QtObject adapter
    signal fileChanged()
    signal adapterUpdated()
    signal loaded()
    signal loadFailed(var error)
    function reload() {}
    function writeAdapter() {}
    function text() { return ""; }
}

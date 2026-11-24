// Stand-in for Quickshell's IconImage.
import QtQuick

Image {
    property real implicitSize: 0
    width: implicitSize
    height: implicitSize
    sourceSize: Qt.size(implicitSize * 2, implicitSize * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The dark header of a drawer: title, optional controls, and Close.
Rectangle {
    id: header

    property string title: ""
    default property alias content: contentRow.data
    signal closeRequested()

    Layout.fillWidth: true
    Layout.preferredHeight: Theme.headerHeight
    implicitHeight: Theme.headerHeight
    color: Theme.header

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        spacing: 12

        Label {
            text: header.title
            color: "white"
            font.bold: true
            font.pixelSize: 16
        }

        // Takes all free width even without a filling child, so Close always
        // sits at the right edge.
        RowLayout {
            id: contentRow
            Layout.fillWidth: true
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: 9
        }

        TileButton {
            text: "Close"
            onClicked: header.closeRequested()
        }
    }
}

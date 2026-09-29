import QtQuick

// One tile for a two-state setting: both option names are always shown,
// the active one highlighted, so the tile never changes size. A click
// emits toggled(); the caller switches the state.
Rectangle {
    id: button

    property string first: ""
    property string second: ""
    property bool secondActive: false
    property string shortcut: ""
    property bool dark: true
    signal toggled()

    implicitWidth: row.implicitWidth + 12
    implicitHeight: Theme.tileHeight
    radius: Theme.tileRadius
    opacity: enabled ? 1.0 : 0.45
    color: dark
           ? (mouseArea.containsMouse ? Theme.tileDarkHover : Theme.tileDark)
           : (mouseArea.containsMouse ? Theme.tileLightHover : Theme.tileLight)
    border.width: 1
    border.color: dark ? Theme.tileDarkBorder : Theme.tileLightBorder

    component Option: Rectangle {
        property string text: ""
        property bool active: false
        width: optionText.implicitWidth + 14
        height: Theme.tileHeight - 8
        radius: Theme.tileRadius - 1
        color: active ? (button.dark ? Theme.accent : Theme.tileLightChecked) : "transparent"

        Text {
            id: optionText
            anchors.centerIn: parent
            text: parent.text
            font.bold: parent.active
            color: parent.active
                   ? (button.dark ? "white" : Theme.tileLightCheckedText)
                   : (button.dark ? "#aab3bf" : Theme.mutedText)
        }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2

        Option {
            text: button.first
            active: !button.secondActive
        }

        Text {
            height: Theme.tileHeight - 8
            verticalAlignment: Text.AlignVCenter
            text: "/"
            color: button.dark ? "#aab3bf" : Theme.mutedText
        }

        Option {
            text: button.second
            active: button.secondActive
        }

        Text {
            visible: button.shortcut.length > 0
            height: Theme.tileHeight - 8
            leftPadding: 4
            rightPadding: 2
            verticalAlignment: Text.AlignVCenter
            text: "[" + button.shortcut + "]"
            color: button.dark ? Theme.accentBorder : Theme.mutedText
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: button.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.toggled()
    }
}

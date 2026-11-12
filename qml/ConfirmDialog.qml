import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Asks before an action that replaces or removes a file. Only the confirm
// button goes ahead; Esc, Cancel or a click outside leave everything as it is.
Popup {
    id: dialog

    property string title: ""
    property string message: ""
    property string confirmText: "OK"
    // A TileButton tone for the confirm button, e.g. "danger".
    property string confirmTone: "accent"
    signal confirmed()

    function confirm() {
        close()
        confirmed()
    }

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 40 : 460, 460)
    padding: 14
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        color: Theme.panel
        border.color: Theme.panelBorder
        border.width: 1
        radius: Theme.tileRadius
    }

    contentItem: ColumnLayout {
        spacing: 10

        Label {
            text: dialog.title
            color: Theme.text
            font.bold: true
        }

        Label {
            Layout.fillWidth: true
            text: dialog.message
            color: Theme.text
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Item { Layout.fillWidth: true }

            TileButton {
                dark: false
                text: "Cancel"
                onClicked: dialog.close()
            }

            TileButton {
                tone: dialog.confirmTone
                text: dialog.confirmText
                onClicked: dialog.confirm()
            }
        }
    }
}

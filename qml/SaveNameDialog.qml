import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Asks for the name of a save. Enter confirms, Esc cancels; an empty name is
// fine, the date is always part of the file name.
Popup {
    id: dialog

    property string title: "Save"
    signal confirmed(string name)

    function confirm() {
        const name = nameField.text
        close()
        confirmed(name)
    }

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 40 : 420, 420)
    padding: 14
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    onOpened: {
        nameField.text = ""
        nameField.forceActiveFocus()
    }

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

        TextField {
            id: nameField
            Layout.fillWidth: true
            selectByMouse: true
            placeholderText: "Name (optional)"
            onAccepted: dialog.confirm()
            Keys.onEscapePressed: dialog.close()
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
                tone: "accent"
                text: "Save"
                onClicked: dialog.confirm()
            }
        }
    }
}

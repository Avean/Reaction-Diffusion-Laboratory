import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import jlqml

// Asks for the name and an optional description of a series preset. The file
// name follows from the name; the line under the fields shows it and whether
// a file of that name is already there. Enter confirms, Esc cancels.
Popup {
    id: dialog

    property string title: "Save preset"
    // What will be saved, shown under the title.
    property string subject: ""
    signal confirmed(string name, string description)

    readonly property bool nameGiven: nameField.text.trim().length > 0
    readonly property var target: {
        try {
            return JSON.parse(Julia.seriesPresetTargetJson(nameField.text))
        } catch (error) {
            return { file: "", exists: false }
        }
    }

    function confirm() {
        if (!nameGiven)
            return
        const name = nameField.text
        const description = descriptionField.text
        close()
        confirmed(name, description)
    }

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 40 : 460, 460)
    padding: 14
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    onOpened: {
        nameField.text = ""
        descriptionField.text = ""
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

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.subject
            color: Theme.mutedText
            wrapMode: Text.WordWrap
        }

        TextField {
            id: nameField
            Layout.fillWidth: true
            selectByMouse: true
            placeholderText: "Name"
            onAccepted: dialog.confirm()
            Keys.onEscapePressed: dialog.close()
        }

        TextField {
            id: descriptionField
            Layout.fillWidth: true
            selectByMouse: true
            placeholderText: "Description (optional)"
            onAccepted: dialog.confirm()
            Keys.onEscapePressed: dialog.close()
        }

        Label {
            Layout.fillWidth: true
            visible: dialog.target.file.length > 0
            text: dialog.target.exists
                  ? "Replaces " + dialog.target.file + " after confirmation"
                  : "Saved as " + dialog.target.file
            color: dialog.target.exists ? Theme.attention : Theme.mutedText
            wrapMode: Text.WrapAnywhere
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
                enabled: dialog.nameGiven
                onClicked: dialog.confirm()
            }
        }
    }
}

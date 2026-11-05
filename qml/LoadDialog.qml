import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import jlqml

// The saves of the active model, newest first, with a preview of the selected
// one. A save that cannot be loaded says why and keeps Load disabled.
Popup {
    id: dialog

    property string selectedFile: ""
    property var listing: {
        try {
            return JSON.parse(ui.simulationSavesJson)
        } catch (error) {
            return { saves: [], skipped: [] }
        }
    }
    property var details: {
        try {
            return JSON.parse(ui.simulationSaveDetailsJson)
        } catch (error) {
            return {}
        }
    }
    readonly property var shownDetails: details.file === selectedFile ? details : ({})
    readonly property bool loadable: selectedFile.length > 0 &&
                                     shownDetails.file === selectedFile &&
                                     shownDetails.error === "" &&
                                     !ui.graphicsBusy &&
                                     !ui.seriesRunning

    function select(file) {
        selectedFile = file
        Julia.selectSimulationSave(file)
    }

    function selectNewestIfNone() {
        if (opened && selectedFile === "" && listing.saves.length > 0)
            select(listing.saves[0].file)
    }

    function load() {
        if (!loadable)
            return
        Julia.loadSimulationSave(selectedFile)
        close()
    }

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: parent ? Math.min(parent.width - 60, 1000) : 1000
    height: parent ? Math.min(parent.height - 60, 660) : 660
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    onOpened: {
        selectedFile = ""
        Julia.refreshSimulationSaves()
        Qt.callLater(selectNewestIfNone)
    }
    onListingChanged: Qt.callLater(selectNewestIfNone)

    background: Rectangle {
        color: Theme.panel
        border.color: Theme.panelBorder
        border.width: 1
        radius: Theme.tileRadius
    }

    contentItem: ColumnLayout {
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerHeight
            color: Theme.header

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8

                Label {
                    Layout.fillWidth: true
                    text: "Load: " + ui.modelName
                    color: "white"
                    font.bold: true
                    elide: Text.ElideRight
                }

                TileButton {
                    text: "Close"
                    onClicked: dialog.close()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // -------------------------------------------------- list
            Rectangle {
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                color: "#f3f5f8"
                border.color: "#c4ccd7"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 1
                    spacing: 0

                    Label {
                        Layout.fillWidth: true
                        Layout.margins: 14
                        visible: dialog.listing.saves.length === 0
                        text: "This model has no saves yet."
                        color: Theme.mutedText
                        wrapMode: Text.WordWrap
                    }

                    ListView {
                        id: saveList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: dialog.listing.saves

                        ScrollBar.vertical: ScrollBar {}

                        delegate: Rectangle {
                            required property var modelData

                            readonly property bool selected: modelData.file === dialog.selectedFile

                            width: ListView.view.width
                            implicitHeight: saveLabels.implicitHeight + 14
                            color: selected
                                   ? Theme.tileLightChecked
                                   : saveMouse.containsMouse ? Theme.tileLightHover : "transparent"

                            Column {
                                id: saveLabels
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 2

                                Label {
                                    width: parent.width
                                    text: modelData.name.length > 0 ? modelData.name : modelData.savedAt
                                    color: Theme.text
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Label {
                                    width: parent.width
                                    text: (modelData.name.length > 0 ? modelData.savedAt + "   " : "") +
                                          "t = " + modelData.time + "   " +
                                          (modelData.panels === 1 ? "1 panel" : modelData.panels + " panels")
                                    color: Theme.mutedText
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: saveMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dialog.select(modelData.file)
                                onDoubleClicked: {
                                    dialog.select(modelData.file)
                                    dialog.load()
                                }
                            }
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        Layout.margins: 10
                        visible: dialog.listing.skipped.length > 0
                        text: "Skipped, cannot be read: " + dialog.listing.skipped.join(", ")
                        color: Theme.danger
                        wrapMode: Text.Wrap
                    }
                }
            }

            // -------------------------------------------------- preview
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 12
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    visible: dialog.selectedFile.length === 0
                    text: "Select a save to see it."
                    color: Theme.mutedText
                }

                Label {
                    Layout.fillWidth: true
                    visible: (dialog.shownDetails.error || "").length > 0
                    text: "Cannot be loaded: " + (dialog.shownDetails.error || "")
                    color: Theme.danger
                    wrapMode: Text.Wrap
                }

                Label {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: dialog.shownDetails.savedAt === undefined ? "" :
                          "Saved " + dialog.shownDetails.savedAt +
                          "     t = " + dialog.shownDetails.time +
                          "     " + dialog.shownDetails.boundary +
                          "     domain " + dialog.shownDetails.domainLength +
                          "     panels " + dialog.shownDetails.panels +
                          " (" + dialog.shownDetails.gridPoints + " points)" +
                          (dialog.shownDetails.profileSet.length > 0
                           ? "     profile " + dialog.shownDetails.profileSet : "")
                    color: Theme.text
                    wrapMode: Text.Wrap
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: availableWidth
                    clip: true

                    ColumnLayout {
                        width: parent.width
                        spacing: 8

                        Repeater {
                            model: dialog.shownDetails.charts || []

                            SaveProfileChart {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 120
                                title: modelData.variable
                                panels: modelData.panels
                            }
                        }

                        Label {
                            Layout.topMargin: 4
                            visible: (dialog.shownDetails.parameters || []).length > 0
                            text: "Parameters"
                            color: Theme.text
                            font.bold: true
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 4
                            columnSpacing: 12
                            rowSpacing: 2

                            Repeater {
                                model: dialog.shownDetails.parameters || []

                                Label {
                                    required property var modelData
                                    text: modelData.key + " = " + modelData.value
                                    color: Theme.text
                                }
                            }
                        }

                        Repeater {
                            model: dialog.shownDetails.warnings || []

                            Label {
                                required property var modelData
                                Layout.fillWidth: true
                                text: modelData
                                color: Theme.warning
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    Item { Layout.fillWidth: true }

                    TileButton {
                        tone: "accent"
                        enabled: dialog.loadable
                        text: "Load"
                        onClicked: dialog.load()
                    }
                }
            }
        }
    }
}

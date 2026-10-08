import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQml.Models
import jlqml
import Makie

ApplicationWindow {
    id: window

    // Keep the native window transparent until Makie has rendered its first
    // frame, avoiding a white flash; the splash closes at that point.
    visible: true
    // Keep a tiny non-zero opacity so Qt still renders the Makie viewport and
    // can signal that its first frame is ready.
    opacity: ui.mainWindowVisible ? 1.0 : 0.01
    visibility: Window.Maximized
    width: 1500
    height: 900
    minimumWidth: 980
    minimumHeight: 650
    title: "Reaction-Diffusion Laboratory"
    color: "#eef1f5"

    property var modelCatalog: JSON.parse(ui.modelCatalogJson)
    property var variables: JSON.parse(ui.variablesJson)
    property var equationImages: JSON.parse(ui.equationImagesJson)
    property string modelParametersJson: ui.modelParametersJson
    property bool textEditorFocused: false
    property int selectedFamilyIndex: 0
    property int activeFamilyIndex: findFamilyIndex(ui.activeModelKey)
    property string bottomPanel: ""
    // In series mode every main-window control except the Series toggle is
    // disabled; the series window owns all interaction.
    property bool controlsEnabled: !ui.graphicsBusy && !ui.seriesMode

    // The parameter fields are updated in place: rebuilding them after every
    // edit would destroy the field being edited, losing its focus and
    // breaking Tab navigation between the fields.
    ListModel {
        id: parameterModel
    }

    function syncParameterModel() {
        const items = JSON.parse(modelParametersJson)
        let sameParameters = items.length === parameterModel.count
        for (let index = 0; sameParameters && index < items.length; ++index)
            sameParameters = parameterModel.get(index).key === items[index].key

        if (!sameParameters)
            parameterModel.clear()

        for (let index = 0; index < items.length; ++index) {
            const item = items[index]
            const entry = {
                key: item.key,
                label: item.label,
                value: item.value,
                displayText: item.display
            }
            if (sameParameters)
                parameterModel.set(index, entry)
            else
                parameterModel.append(entry)
        }
    }

    onModelParametersJsonChanged: syncParameterModel()

    function findFamilyIndex(modelKey) {
        for (let familyIndex = 0; familyIndex < modelCatalog.length; ++familyIndex) {
            const models = modelCatalog[familyIndex].models
            for (let modelIndex = 0; modelIndex < models.length; ++modelIndex) {
                if (models[modelIndex].key === modelKey)
                    return familyIndex
            }
        }
        return 0
    }

    function selectedFamilyModels() {
        if (selectedFamilyIndex < 0 || selectedFamilyIndex >= modelCatalog.length)
            return []
        return modelCatalog[selectedFamilyIndex].models
    }

    function activeModelIndexInSelectedFamily() {
        const models = selectedFamilyModels()
        for (let index = 0; index < models.length; ++index) {
            if (models[index].key === ui.activeModelKey)
                return index
        }
        return -1
    }

    function dtMatchesExponent(exponent) {
        const dt = Number(ui.dtmax)
        return dt > 0
                && Math.abs(Math.log(dt) / Math.LN10 - exponent) < 0.0001
    }

    function openModelDrawer() {
        controlDrawer.close()
        bottomDrawer.close()
        modelDrawer.open()
    }

    function openControlDrawer() {
        modelDrawer.close()
        bottomDrawer.close()
        controlDrawer.open()
    }

    function toggleSeriesMode() {
        if (ui.seriesMode) {
            if (!ui.seriesRunning)
                Julia.setSeriesMode(false)
            return
        }

        modelDrawer.close()
        controlDrawer.close()
        closeBottomPanel()
        Julia.setSeriesMode(true)
    }

    function toggleBottomPanel(panelName) {
        modelDrawer.close()
        controlDrawer.close()

        if (bottomDrawer.opened && bottomPanel === panelName) {
            closeBottomPanel()
        } else {
            bottomPanel = panelName
            if (!bottomDrawer.opened)
                bottomDrawer.open()
        }
    }

    function closeBottomPanel() {
        perturbationWidthField.focus = false
        perturbationHeightField.focus = false
        textEditorFocused = false
        bottomDrawer.close()
    }

    onActiveFamilyIndexChanged: selectedFamilyIndex = activeFamilyIndex

    Component.onCompleted: {
        selectedFamilyIndex = activeFamilyIndex
        syncParameterModel()
    }

    palette.window: "#eef1f5"
    palette.windowText: "#20252d"
    palette.button: "#f5f7fa"
    palette.buttonText: "#20252d"
    palette.highlight: "#3b82f6"
    palette.highlightedText: "white"

    header: ToolBar {
        id: topBar
        height: 52

        background: Rectangle {
            color: "#20252d"
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 6

            TileButton {
                text: "Models: " + ui.modelName
                checked: modelDrawer.opened
                enabled: window.controlsEnabled
                onClicked: modelDrawer.opened ? modelDrawer.close() : window.openModelDrawer()
            }

            TileButton {
                id: stateButton
                text: ui.checkpointAvailable ? "State  •" : "State"
                checked: stateMenu.opened
                enabled: window.controlsEnabled
                onClicked: stateMenu.open()

                Menu {
                    id: stateMenu
                    y: stateButton.height

                    MenuItem {
                        text: "Save current state"
                        enabled: window.controlsEnabled
                        onTriggered: Julia.saveCurrentState()
                    }

                    MenuItem {
                        text: "Restore saved state"
                        enabled: ui.checkpointAvailable && window.controlsEnabled
                        onTriggered: Julia.restoreSavedState()
                    }
                }
            }

            // Both states have the width of the longer label.
            TextMetrics {
                id: seriesLabelMetrics
                font.bold: true
                text: "Series mode: ON"
            }

            TileButton {
                id: seriesButton
                minimumTextWidth: seriesLabelMetrics.width
                text: ui.seriesRunning
                      ? "Series " + ui.seriesCompletedRuns + "/" + ui.seriesTotalRuns
                      : ui.seriesMode ? "Series mode: ON" : "Series mode"
                checked: ui.seriesMode
                enabled: ui.seriesMode || !ui.graphicsBusy
                onClicked: window.toggleSeriesMode()

                ToolTip.visible: hovered && ui.seriesRunning
                ToolTip.text: "Stop the series to leave series mode"
            }

            // Always available, also in series mode.
            TileButton {
                text: "Save"
                onClicked: Julia.saveParameters()

                ToolTip.visible: hovered
                ToolTip.text: "Append the model, domain and series parameters to parameters_history.txt"
            }

            Item {
                Layout.fillWidth: true
            }

            TileButton {
                id: runningButton
                Layout.preferredWidth: 92
                tone: ui.running ? "success" : "danger"
                text: ui.running ? "Running" : "Stopped"
                enabled: window.controlsEnabled
                onClicked: Julia.toggleRunning()
            }

            Item {
                Layout.preferredWidth: 5
            }

            Label {
                text: "Speed"
                color: "white"
                font.bold: true
            }

            Repeater {
                model: [
                    { key: "1", exponent: -3, description: "Slow: maximum dt = 1e-3" },
                    { key: "2", exponent: -1, description: "Medium: maximum dt = 1e-1" },
                    { key: "3", exponent: 1, description: "Fast: maximum dt = 1e1" },
                    { key: "4", exponent: 5, description: "Very fast: maximum dt = 1e5" }
                ]

                TileButton {
                    required property var modelData
                    Layout.preferredWidth: 30
                    text: modelData.key
                    checked: window.dtMatchesExponent(modelData.exponent)
                    enabled: window.controlsEnabled
                    onClicked: Julia.setDtExponent(modelData.exponent)

                    ToolTip.visible: hovered
                    ToolTip.text: modelData.description + "  [" + modelData.key + "]"
                }
            }

            Label {
                text: window.width < 1150 ? "Max dt" : "Maximum dt"
                color: "white"
                font.bold: true
            }

            Slider {
                Layout.preferredWidth: Math.min(
                    210,
                    Math.max(110, window.width * 0.13)
                )
                enabled: window.controlsEnabled
                from: -5
                to: 5
                stepSize: 1
                value: Math.log(Number(ui.dtmax)) / Math.LN10
                onMoved: Julia.setDtExponent(Math.round(value))
            }

            Label {
                Layout.preferredWidth: 62
                text: Number(ui.dtmax).toExponential(1)
                color: "white"
                font.family: "Consolas"
            }

            TileButton {
                text: ui.graphicsBusy ? "Wait..." : "Reset  [R]"
                enabled: window.controlsEnabled
                onClicked: Julia.resetSimulation()

                ToolTip.visible: hovered
                ToolTip.text: "Restart from the initial condition, keeping parameters and panels"
            }
        }
    }

    footer: ToolBar {
        id: bottomBar
        height: 48

        background: Rectangle {
            color: "#20252d"
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 8

            Item {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.minimumWidth: 230

                RowLayout {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    TileButton {
                        text: "Split / Merge"
                        checked: bottomDrawer.opened && window.bottomPanel === "partition"
                        enabled: window.controlsEnabled
                        onClicked: window.toggleBottomPanel("partition")
                    }

                    TileButton {
                        text: "Perturbations"
                        checked: bottomDrawer.opened && window.bottomPanel === "perturbations"
                        enabled: window.controlsEnabled
                        onClicked: window.toggleBottomPanel("perturbations")
                    }
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 8

                Label {
                    text: "Domain rescale"
                    color: "white"
                    font.bold: true
                }

                Repeater {
                    model: [
                        { key: "1", resolution: 16 },
                        { key: "2", resolution: 40 },
                        { key: "3", resolution: 100 }
                    ]

                    TileButton {
                        required property var modelData
                        Layout.preferredWidth: 30
                        text: modelData.key
                        checked: Number(ui.domainResolution) === modelData.resolution
                        enabled: window.controlsEnabled
                        onClicked: Julia.setDomainResolution(modelData.resolution)
                    }
                }

                Slider {
                    id: domainRescaleSlider
                    Layout.preferredWidth: Math.min(300, window.width * 0.24)
                    enabled: window.controlsEnabled
                    from: 0
                    to: 3
                    stepSize: 3 / Math.max(1, Number(ui.domainResolution) - 1)
                    value: 2 * Math.log(Number(ui.domainLength)) / Math.LN10
                    onMoved: Julia.setDomainExponent(value)

                    WheelHandler {
                        onWheel: function(event) {
                            if (!domainRescaleSlider.enabled || event.angleDelta.y === 0)
                                return
                            const step = domainRescaleSlider.stepSize
                            const next = Math.max(domainRescaleSlider.from,
                                                  Math.min(domainRescaleSlider.to,
                                                           domainRescaleSlider.value + (event.angleDelta.y > 0 ? step : -step)))
                            Julia.setDomainExponent(next)
                            event.accepted = true
                        }
                    }
                }

                Label {
                    Layout.preferredWidth: 72
                    text: Number(ui.domainLength).toPrecision(3)
                    color: "white"
                    font.family: "Consolas"
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.minimumWidth: 230

                TileButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Set steady state"
                    checked: controlDrawer.opened
                    enabled: window.controlsEnabled
                    onClicked: controlDrawer.opened ? controlDrawer.close() : window.openControlDrawer()
                }
            }
        }
    }

    MakieArea {
        id: plotArea
        anchors.fill: parent
        scene: plot
    }

    Popup {
        id: bottomDrawer
        // Positioned in the window overlay, just above the bottom bar.
        readonly property real bottomEdge: parent.height - bottomBar.height
        parent: Overlay.overlay
        x: 0
        y: bottomEdge - height
        // The slide-in animation replaces the y binding, so the drawer is
        // re-anchored to the bottom bar whenever its size or the window
        // changes (e.g. Split / Merge grows upwards after a split).
        onHeightChanged: if (visible) y = bottomEdge - height
        onBottomEdgeChanged: if (visible) y = bottomEdge - height
        width: parent.width
        // Fits its content: Split / Merge grows once Merge and Swap appear.
        // Row heights are fixed here rather than read from the layouts: a
        // hidden page of the StackLayout is not laid out, so its implicit
        // height is stale until it is shown.
        readonly property int rowHeight: 42
        height: Theme.headerHeight + 2 + 20 + (
            window.bottomPanel === "partition"
            ? (ui.segmentCount > 1 ? 2 * rowHeight + 8 : rowHeight)
            : Theme.cardHeight
        )
        modal: true
        dim: false
        focus: true
        padding: 0
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

        enter: Transition {
            NumberAnimation {
                property: "y"
                from: bottomDrawer.bottomEdge
                to: bottomDrawer.bottomEdge - bottomDrawer.height
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        exit: Transition {
            NumberAnimation {
                property: "y"
                from: bottomDrawer.bottomEdge - bottomDrawer.height
                to: bottomDrawer.bottomEdge
                duration: 150
                easing.type: Easing.InCubic
            }
        }

        onClosed: {
            perturbationWidthField.focus = false
            perturbationHeightField.focus = false
            window.textEditorFocused = false
            window.bottomPanel = ""
        }

        background: Rectangle {
            color: Theme.panel
            border.color: Theme.panelBorder
            border.width: 1
        }

        contentItem: StackLayout {
            currentIndex: window.bottomPanel === "partition" ? 1 : 0

            ColumnLayout {
                spacing: 0

                // The drawer is modal, which blocks the window shortcuts, so
                // it repeats the ones that belong to it.
                Shortcut {
                    sequence: "Z"
                    enabled: bottomDrawer.opened && !window.textEditorFocused && window.controlsEnabled
                    autoRepeat: false
                    onActivated: Julia.toggleRandomMode()
                }

                Shortcut {
                    sequence: "X"
                    enabled: bottomDrawer.opened && !window.textEditorFocused && window.controlsEnabled
                    autoRepeat: false
                    onActivated: Julia.toggleAbsoluteMode()
                }

                DrawerHeader {
                    title: "Perturbations"
                    onCloseRequested: window.closeBottomPanel()

                    Row {
                        spacing: 6

                        BistableButton {
                            first: "Constant"
                            second: "Random"
                            secondActive: ui.randomMode
                            shortcut: "Z"
                            enabled: window.controlsEnabled
                            onToggled: Julia.toggleRandomMode()
                        }

                        BistableButton {
                            first: "Relative"
                            second: "Absolute"
                            secondActive: ui.absoluteMode
                            shortcut: "X"
                            enabled: window.controlsEnabled
                            onToggled: Julia.toggleAbsoluteMode()
                        }
                    }
                }

                RowLayout {
                    id: perturbationBody
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.cardHeight
                    Layout.margins: 10
                    spacing: 10

                    FieldCard {
                        title: "Width"
                        implicitWidth: 180

                        TextField {
                            id: perturbationWidthField
                            Layout.fillWidth: true
                            selectByMouse: true
                            // Validators use the "C" locale: the fields show and
                            // Julia parses a decimal point, which a system locale
                            // such as pl_PL rejects.
                            validator: DoubleValidator {
                                bottom: 0.0000000001
                                top: 1.0
                                notation: DoubleValidator.ScientificNotation
                                locale: "C"
                            }
                            onActiveFocusChanged: window.textEditorFocused = activeFocus
                            onEditingFinished: Julia.setPerturbationWidth(text)

                            Binding on text {
                                value: Number(ui.perturbationWidth).toFixed(2)
                                when: !perturbationWidthField.activeFocus
                                restoreMode: Binding.RestoreBindingOrValue
                            }
                        }
                    }

                    FieldCard {
                        title: "Height"
                        implicitWidth: 180
                        visible: ui.absoluteMode

                        TextField {
                            id: perturbationHeightField
                            Layout.fillWidth: true
                            selectByMouse: true
                            validator: DoubleValidator {
                                notation: DoubleValidator.ScientificNotation
                                locale: "C"
                            }
                            onActiveFocusChanged: window.textEditorFocused = activeFocus
                            onEditingFinished: Julia.setPerturbationHeight(text)

                            Binding on text {
                                value: Number(ui.perturbationHeight).toString()
                                when: !perturbationHeightField.activeFocus
                                restoreMode: Binding.RestoreBindingOrValue
                            }
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        text: ui.absoluteMode
                              ? "Scroll: width   |   Ctrl + scroll: height"
                              : "Scroll: width   |   Ctrl + scroll: relative preview scale"
                        color: Theme.mutedText
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                    }
                }
            }

            ColumnLayout {
                spacing: 0

                DrawerHeader {
                    title: "Split / Merge"
                    onCloseRequested: window.closeBottomPanel()

                    ScrollView {
                        Layout.preferredWidth: Math.min(window.width * 0.45, partitionPanels.implicitWidth)
                        Layout.preferredHeight: Theme.headerHeight
                        contentHeight: availableHeight
                        ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                        ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                        clip: true

                        PanelSelector {
                            id: partitionPanels
                            y: (parent.height - height) / 2
                            count: ui.segmentCount
                            current: ui.selectedSegment
                            enabled: window.controlsEnabled
                            onActivated: panel => Julia.selectSplitSegment(panel)
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    TileButton {
                        Layout.preferredWidth: 136
                        visible: ui.segmentCount > 1
                        tone: ui.synchronizationStatus === "Synchronized"
                              ? "success"
                              : ui.synchronizationStatus === "Synchronizing..." ? "warning" : "attention"
                        text: ui.synchronizationStatus
                        enabled: window.controlsEnabled
                        onClicked: Julia.synchronizeDomains()
                    }
                }

                ColumnLayout {
                    id: partitionBody
                    Layout.fillWidth: true
                    Layout.margins: 10
                    Layout.leftMargin: 16
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: bottomDrawer.rowHeight
                        spacing: 8

                        Label {
                            text: "Split point: " + ui.splitIndex
                        }

                        Slider {
                            Layout.preferredWidth: Math.min(360, window.width * 0.28)
                            enabled: window.controlsEnabled
                            from: 2
                            to: Math.max(2, ui.splitMaximum)
                            stepSize: 1
                            value: ui.splitIndex
                            onMoved: Julia.setSplitIndex(Math.round(value))
                        }

                        TileButton {
                            dark: false
                            enabled: window.controlsEnabled
                            text: ui.graphicsBusy ? "Updating..." : "Split selected panel"
                            onClicked: Julia.splitSelectedSegment()
                        }

                        TileButton {
                            dark: false
                            enabled: ui.segmentCount > 1 && window.controlsEnabled
                            text: "Delete selected panel"
                            onClicked: Julia.deleteSelectedSegment()
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        Label {
                            visible: ui.segmentCount <= 1
                            text: "Split the domain to enable Merge, Swap and Delete."
                            color: Theme.mutedText
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: bottomDrawer.rowHeight
                        visible: ui.segmentCount > 1
                        spacing: 8

                        Label {
                            text: "Merge:"
                            font.bold: true
                        }

                        // As wide as its buttons, so the group grows with
                        // the panel count; scrolls only when space runs out.
                        ScrollView {
                            Layout.preferredWidth: Math.min(window.width * 0.4, mergeButtons.implicitWidth)
                            Layout.preferredHeight: 42
                            contentHeight: availableHeight
                            ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                            ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                            clip: true

                            Row {
                                id: mergeButtons
                                spacing: 6

                                Repeater {
                                    model: Math.max(0, ui.segmentCount - 1)

                                    TileButton {
                                        required property int index
                                        y: 6
                                        dark: false
                                        enabled: window.controlsEnabled
                                        text: (index + 1) + " | " + (index + 2)
                                        onClicked: Julia.mergeBoundary(index + 1)
                                    }
                                }
                            }
                        }

                        Label {
                            Layout.leftMargin: 14
                            text: "Swap:"
                            font.bold: true
                        }

                        ScrollView {
                            Layout.preferredWidth: Math.min(window.width * 0.4, swapButtons.implicitWidth)
                            Layout.preferredHeight: 42
                            contentHeight: availableHeight
                            ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                            ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                            clip: true

                            Row {
                                id: swapButtons
                                spacing: 6

                                Repeater {
                                    model: Math.max(0, ui.segmentCount - 1)

                                    TileButton {
                                        required property int index
                                        y: 6
                                        dark: false
                                        enabled: window.controlsEnabled
                                        text: (index + 1) + " ↔ " + (index + 2)
                                        onClicked: Julia.swapBoundary(index + 1)
                                    }
                                }
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }

    SeriesWindow {
        id: seriesWindow
    }

    Rectangle {
        id: leftEdgeHotspot
        z: 20
        width: 9
        color: "transparent"
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        visible: !modelDrawer.opened && !ui.seriesMode

        HoverHandler {
            id: leftEdgeHover
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onHoveredChanged: hovered ? modelOpenDelay.restart() : modelOpenDelay.stop()
        }
    }

    Timer {
        id: modelOpenDelay
        interval: 350
        repeat: false
        onTriggered: {
            if (leftEdgeHover.hovered && !modelDrawer.opened && !ui.seriesMode)
                window.openModelDrawer()
        }
    }

    Drawer {
        id: modelDrawer

        edge: Qt.LeftEdge
        width: Math.min(
            window.width * 0.90,
            Math.max(410, Number(ui.equationPreferredWidth) + 58)
        )
        height: window.height - topBar.height - bottomBar.height
        y: topBar.height
        modal: true
        dim: false
        interactive: true
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

        Behavior on width {
            NumberAnimation {
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        background: Rectangle {
            color: "#f3f5f8"
            border.color: "#aab3bf"
            border.width: 1
        }

        contentItem: Rectangle {
            color: "#f3f5f8"

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                DrawerHeader {
                    title: "Models and equations"
                    onCloseRequested: modelDrawer.close()
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: availableWidth
                    clip: true

                    ColumnLayout {
                        width: parent.width
                        spacing: 9

                        Item {
                            Layout.preferredHeight: 2
                        }

                        ControlSection {
                            title: "Model selection"
                            Layout.leftMargin: 9
                            Layout.rightMargin: 9

                            Label {
                                Layout.fillWidth: true
                                text: "Model family"
                            }

                            ComboBox {
                                id: familyCombo
                                Layout.fillWidth: true
                                enabled: window.controlsEnabled
                                model: window.modelCatalog.map(function(item) { return item.family })
                                currentIndex: window.selectedFamilyIndex
                                popup.height: Math.min(
                                    popup.implicitContentHeight + popup.topPadding + popup.bottomPadding,
                                    320
                                )
                                onActivated: {
                                    window.selectedFamilyIndex = currentIndex
                                    const entries = window.selectedFamilyModels()
                                    if (entries.length > 0)
                                        Julia.selectModel(entries[0].key)
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                text: "Model"
                            }

                            ComboBox {
                                id: modelCombo
                                property var entries: window.selectedFamilyModels()
                                Layout.fillWidth: true
                                enabled: window.controlsEnabled
                                model: entries.map(function(item) { return item.label })
                                currentIndex: window.activeModelIndexInSelectedFamily()
                                displayText: currentIndex >= 0 ? currentText : "Select model"
                                popup.height: Math.min(
                                    popup.implicitContentHeight + popup.topPadding + popup.bottomPadding,
                                    360
                                )
                                onActivated: Julia.selectModel(entries[currentIndex].key)
                            }
                        }

                        ControlSection {
                            title: "About this model"
                            visible: ui.modelDescription.length > 0
                            Layout.leftMargin: 9
                            Layout.rightMargin: 9

                            Label {
                                Layout.fillWidth: true
                                text: ui.modelDescription
                                wrapMode: Text.WordWrap
                                color: "#3f4a59"
                            }
                        }

                        ControlSection {
                            title: "Equations"
                            Layout.leftMargin: 9
                            Layout.rightMargin: 9

                            Switch {
                                Layout.fillWidth: true
                                text: "Show current parameter values"
                                checked: ui.equationValuesVisible
                                enabled: window.controlsEnabled
                                onToggled: Julia.setEquationValuesVisible(checked)
                            }

                            Repeater {
                                model: window.equationImages

                                Image {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: implicitWidth > 0
                                                            ? Math.max(90, Math.min(620, width * implicitHeight / implicitWidth))
                                                            : 90
                                    source: modelData
                                    sourceSize.width: Math.max(
                                        2400,
                                        Math.ceil(width * window.screen.devicePixelRatio * 2.5)
                                    )
                                    fillMode: Image.PreserveAspectFit
                                    horizontalAlignment: Image.AlignLeft
                                    asynchronous: false
                                    cache: true
                                    smooth: true
                                    mipmap: true
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                visible: window.equationImages.length === 0
                                text: "No equations specified for this model."
                                color: "#68717d"
                            }
                        }

                        ControlSection {
                            title: "Boundary conditions"
                            Layout.leftMargin: 9
                            Layout.rightMargin: 9

                            RowLayout {
                                Layout.fillWidth: true

                                TileButton {
                                    Layout.fillWidth: true
                                    dark: false
                                    text: "Neumann"
                                    checked: ui.boundaryName === text
                                    enabled: window.controlsEnabled
                                    onClicked: Julia.selectBoundaryCondition(text)
                                }

                                TileButton {
                                    Layout.fillWidth: true
                                    dark: false
                                    text: "Periodic"
                                    checked: ui.boundaryName === text
                                    enabled: window.controlsEnabled
                                    onClicked: Julia.selectBoundaryCondition(text)
                                }
                            }
                        }

                        ControlSection {
                            title: "Model parameters"
                            expanded: false
                            Layout.leftMargin: 9
                            Layout.rightMargin: 9

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Repeater {
                                    model: parameterModel

                                    RowLayout {
                                        id: parameter
                                        required property string key
                                        required property string label
                                        required property real value
                                        required property string displayText
                                        Layout.fillWidth: true

                                        Label {
                                            Layout.preferredWidth: 74
                                            text: parameter.label
                                            color: "#20252d"
                                        }

                                        TextField {
                                            // Shows the rounded preview, and the full value used
                                            // by the solver while focused. Only typed text is
                                            // sent, so entering and leaving the field without
                                            // typing never rounds the parameter.
                                            property bool edited: false

                                            function commit() {
                                                if (!edited || !acceptableInput)
                                                    return
                                                edited = false
                                                Julia.setModelParameter(parameter.key, text)
                                            }

                                            Layout.fillWidth: true
                                            selectByMouse: true
                                            enabled: window.controlsEnabled
                                            validator: DoubleValidator { notation: DoubleValidator.ScientificNotation; locale: "C" }
                                            text: parameter.displayText
                                            onTextEdited: edited = true
                                            onEditingFinished: commit()
                                            onActiveFocusChanged: {
                                                if (!activeFocus)
                                                    commit()
                                                edited = false
                                                text = activeFocus ? String(parameter.value) : parameter.displayText
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Item {
                            Layout.preferredHeight: 8
                        }
                    }
                }
            }
        }
    }

    Popup {
        id: controlDrawer
        // Positioned in the window overlay, just above the bottom bar.
        readonly property real bottomEdge: parent.height - bottomBar.height
        parent: Overlay.overlay
        x: 0
        y: bottomEdge - height
        // The slide-in animation replaces the y binding, so the drawer is
        // re-anchored to the bottom bar whenever its size or the window
        // changes (e.g. Split / Merge grows upwards after a split).
        onHeightChanged: if (visible) y = bottomEdge - height
        onBottomEdgeChanged: if (visible) y = bottomEdge - height
        width: parent.width
        height: 132
        modal: true
        dim: false
        focus: true
        padding: 0
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

        enter: Transition {
            NumberAnimation {
                property: "y"
                from: controlDrawer.bottomEdge
                to: controlDrawer.bottomEdge - controlDrawer.height
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        exit: Transition {
            NumberAnimation {
                property: "y"
                from: controlDrawer.bottomEdge - controlDrawer.height
                to: controlDrawer.bottomEdge
                duration: 150
                easing.type: Easing.InCubic
            }
        }

        onClosed: window.textEditorFocused = false

        background: Rectangle {
            color: Theme.panel
            border.color: Theme.panelBorder
            border.width: 1
        }

        contentItem: ColumnLayout {
            anchors.fill: parent
            spacing: 0

            DrawerHeader {
                title: "Set steady state"
                onCloseRequested: controlDrawer.close()

                ScrollView {
                    Layout.preferredWidth: Math.min(window.width * 0.45, steadyPanels.implicitWidth)
                    Layout.preferredHeight: Theme.headerHeight
                    contentHeight: availableHeight
                    ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                    ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                    clip: true

                    PanelSelector {
                        id: steadyPanels
                        y: (parent.height - height) / 2
                        count: ui.segmentCount
                        current: ui.selectedSegment
                        enabled: window.controlsEnabled
                        onActivated: panel => Julia.selectSegment(panel)
                    }
                }
            }

            ScrollView {
                id: steadyValuesScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentHeight: availableHeight
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                clip: true

                Row {
                    spacing: 10

                    Item {
                        width: 6
                        height: 1
                    }

                    Repeater {
                        model: window.variables

                        FieldCard {
                            required property int index
                            required property var modelData
                            title: modelData
                            y: Math.max(0, (steadyValuesScroll.availableHeight - height) / 2)

                            TextField {
                                id: constantValue
                                Layout.fillWidth: true
                                text: "0.0"
                                selectByMouse: true
                                validator: DoubleValidator { locale: "C" }
                                onActiveFocusChanged: window.textEditorFocused = activeFocus
                                onAccepted: {
                                    if (window.controlsEnabled)
                                        Julia.applyConstantInitialCondition(index, text)
                                }
                            }

                            TileButton {
                                dark: false
                                text: "Apply"
                                enabled: window.controlsEnabled
                                onClicked: Julia.applyConstantInitialCondition(index, constantValue.text)
                            }
                        }
                    }

                    Item {
                        width: 6
                        height: 1
                    }
                }
            }
        }
    }

    Rectangle {
        id: messageBanner
        z: 60
        visible: ui.message.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.max(
            bottomDrawer.visible ? bottomDrawer.height : 0,
            controlDrawer.visible ? controlDrawer.height : 0
        )
        width: Math.min(parent.width - 40, 760)
        implicitHeight: messageText.implicitHeight + 18
        color: "#fff0f0"
        border.color: "#c63f45"
        radius: 5

        Label {
            id: messageText
            anchors.fill: parent
            anchors.margins: 9
            text: ui.message
            color: "#9f252b"
            wrapMode: Text.Wrap
        }
    }

    // Short confirmation (e.g. after Save) under the top bar; fades out.
    Rectangle {
        id: noticeToast
        property string notice: ui.notice
        z: 61
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 10
        width: noticeText.implicitWidth + 28
        height: Theme.tileHeight + 4
        radius: Theme.tileRadius
        color: Theme.success
        opacity: 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: 250
            }
        }

        onNoticeChanged: {
            if (notice.length === 0)
                return
            opacity = 1
            noticeTimer.restart()
        }

        Text {
            id: noticeText
            anchors.centerIn: parent
            text: noticeToast.notice
            color: "white"
            font.bold: true
        }

        Timer {
            id: noticeTimer
            interval: 3000
            onTriggered: noticeToast.opacity = 0
        }
    }

    Shortcut {
        sequence: "Space"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.toggleRunning()
    }

    Shortcut {
        sequence: "R"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.resetSimulation()
    }

    Shortcut {
        sequence: "T"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.hardReset()
    }

    Shortcut {
        sequence: "1"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.setDtExponent(-3)
    }

    Shortcut {
        sequence: "2"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.setDtExponent(-1)
    }

    Shortcut {
        sequence: "3"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.setDtExponent(1)
    }

    Shortcut {
        sequence: "4"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.setDtExponent(5)
    }

    Shortcut {
        sequence: "Z"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.toggleRandomMode()
    }

    Shortcut {
        sequence: "X"
        context: Qt.WindowShortcut
        enabled: window.active && !window.textEditorFocused && window.controlsEnabled
        autoRepeat: false
        onActivated: Julia.toggleAbsoluteMode()
    }

    Timer {
        interval: 33
        running: true
        repeat: true
        onTriggered: {
            Julia.refreshUI()
            plotArea.update()
        }
    }

    Timer {
        interval: Math.max(1, ui.autoCloseMs)
        running: ui.autoCloseMs > 0
        repeat: false
        onTriggered: window.close()
    }

    onClosing: function(close) {
        Julia.requestClose()
    }
}

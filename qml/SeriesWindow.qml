import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import jlqml

// Series mode window: series setup on the left, head statistics on the right.
// It is visible exactly while ui.seriesMode is on; closing it leaves series
// mode, which is refused while a series is running.
Window {
    id: seriesWindow

    // A complete light palette. Roles left unset come from the desktop: on a
    // Linux desktop in dark mode the Basic style then draws black fields with
    // white text and white list items on the light popups.
    palette {
        window: "#eef1f5"
        windowText: "#20252d"
        base: "#ffffff"
        alternateBase: "#f3f5f8"
        text: "#20252d"
        placeholderText: "#8a939e"
        button: "#f5f7fa"
        buttonText: "#20252d"
        brightText: "#ffffff"
        // The Basic style draws the highlighted row of lists and menus in
        // light, with highlightedText on top.
        light: "#3b82f6"
        midlight: "#e3e7ec"
        mid: "#b8c0ca"
        dark: "#7f8a96"
        shadow: "#5f6874"
        highlight: "#3b82f6"
        highlightedText: "#ffffff"
        link: "#2563eb"
        linkVisited: "#7c3aed"
        toolTipBase: "#20252d"
        toolTipText: "#ffffff"
        disabled.text: "#8a939e"
        disabled.buttonText: "#8a939e"
    }

    // Input controls sized for the numbers they hold; the default size of the
    // Basic style is 200 x 40 (fields) and 140 x 40 (combo boxes).
    component CompactField: TextField {
        implicitWidth: 64
        implicitHeight: 30
        topPadding: 3
        bottomPadding: 3
    }
    component SettingsField: CompactField {
        implicitWidth: 110
    }
    // A number on a perturbation card. It is sent only when it differs from the
    // stored value, so entering and leaving the field changes nothing, and the
    // field then returns to the stored value, also when the value was refused.
    // A value outside the allowed range turns red and is dropped on leaving.
    component PerturbationField: CompactField {
        id: perturbationField
        required property string shown
        signal committed(string value)

        function showStoredValue() {
            text = Qt.binding(function() { return perturbationField.shown })
        }

        selectByMouse: true
        enabled: !ui.seriesRunning
        text: shown
        color: acceptableInput ? palette.text : "#b91c1c"
        onEditingFinished: {
            if (Number(text) !== Number(shown))
                committed(text)
            showStoredValue()
        }
        onActiveFocusChanged: {
            if (!activeFocus && !acceptableInput)
                showStoredValue()
        }
    }
    component CompactComboBox: ComboBox {
        implicitWidth: 90
        implicitHeight: 30
    }

    readonly property string initialConditionLabel: "Initial condition"
    readonly property string currentStateLabel: "Current state"
    readonly property string presetInitialLabel: "Preset"

    property var variables: JSON.parse(ui.variablesJson)
    property var perturbations: JSON.parse(ui.seriesPerturbationsJson)
    property var presets: JSON.parse(ui.seriesPresetsJson)
    // ui.seriesSelectedPreset follows the selected panel, so this does too.
    property string selectedPresetDescription: {
        for (const preset of presets) {
            if (preset.key === ui.seriesSelectedPreset)
                return preset.description || ""
        }
        return ""
    }
    property var results: {
        try {
            return JSON.parse(ui.seriesResultsJson)
        } catch (error) {
            return []
        }
    }
    property var panelNames: Array.from({length: ui.segmentCount}, (_, index) => String(index + 1))
    property var panelPerturbationCounts: {
        const counts = Array.from({length: ui.segmentCount}, () => 0)
        for (const perturbation of perturbations) {
            if (perturbation.panel >= 1 && perturbation.panel <= counts.length)
                counts[perturbation.panel - 1] += 1
        }
        return counts
    }
    property string perturbationsJson: ui.seriesPerturbationsJson
    property int selectedPanel: ui.seriesSelectedSegment

    // The perturbation cards are updated in place: rebuilding them after
    // every edit would destroy the field being edited, losing its focus and
    // breaking Tab navigation between the fields.
    ListModel {
        id: perturbationModel
    }

    // Only the cards of the selected panel are shown.
    function syncPerturbationModel() {
        const items = JSON.parse(perturbationsJson).filter(item => item.panel === selectedPanel)
        let sameCards = items.length === perturbationModel.count
        for (let index = 0; sameCards && index < items.length; ++index)
            sameCards = perturbationModel.get(index).perturbationId === items[index].id

        if (!sameCards)
            perturbationModel.clear()

        for (let index = 0; index < items.length; ++index) {
            const item = items[index]
            const entry = {
                perturbationId: item.id,
                panel: item.panel,
                variable: item.variable,
                position: item.position,
                widthMin: item.widthMin,
                widthMax: item.widthMax,
                heightMin: item.heightMin,
                heightMax: item.heightMax
            }
            if (sameCards)
                perturbationModel.set(index, entry)
            else
                perturbationModel.append(entry)
        }
    }

    onPerturbationsJsonChanged: syncPerturbationModel()
    onSelectedPanelChanged: syncPerturbationModel()
    Component.onCompleted: syncPerturbationModel()

    // Not transient for the main window: it has to be able to come to the front
    // too, since its plots and controls stay in use in series mode.
    transientParent: null
    visible: ui.seriesMode
    width: 1400
    height: 820
    minimumWidth: 900
    minimumHeight: 600
    title: ui.seriesRunning
           ? "Series — " + ui.seriesCompletedRuns + " / " + ui.seriesTotalRuns
           : "Series"
    color: "#eef1f5"

    onClosing: function(close) {
        close.accepted = false
        if (!ui.seriesRunning)
            Julia.setSeriesMode(false)
    }

    function commitSeriesSettings() {
        const fields = [
            runCountField,
            maximumTimeField,
            checkIntervalField,
            toleranceField,
            requiredChecksField,
            dtmaxField,
            maximumStepsField,
            seedField
        ]

        for (let index = 0; index < fields.length; ++index) {
            if (!fields[index].acceptableInput) {
                fields[index].forceActiveFocus()
                return false
            }
        }

        Julia.setSeriesRunCount(runCountField.text)
        Julia.setSeriesMaximumTime(maximumTimeField.text)
        Julia.setSeriesCheckInterval(checkIntervalField.text)
        Julia.setSeriesTolerance(toleranceField.text)
        Julia.setSeriesRequiredChecks(requiredChecksField.text)
        Julia.setSeriesDtmax(dtmaxField.text)
        Julia.setSeriesMaximumSteps(maximumStepsField.text)
        Julia.setSeriesSeed(seedField.text)
        return true
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            color: Theme.bar

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8

                Label {
                    text: "Simulation series"
                    color: "white"
                    font.bold: true
                    font.pixelSize: 16
                }

                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    text: ui.seriesStatus
                    color: ui.seriesRunning ? "#93c5fd" : "#cbd3dc"
                    elide: Text.ElideRight
                }

                // Also during a run: the results so far, with their count.
                TileButton {
                    text: "Save series"
                    enabled: ui.seriesCompletedRuns >= 1
                    onClicked: saveSeriesDialog.open()

                    ToolTip.visible: hovered
                    ToolTip.text: ui.seriesCompletedRuns >= 1
                                  ? "Save the settings, perturbations and head statistics of this series to a file in saves/series"
                                  : "Available after the first completed realization"
                }

                TileButton {
                    text: "Close series mode"
                    enabled: !ui.seriesRunning
                    onClicked: Julia.setSeriesMode(false)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // -------------------------------------------------- setup
            Rectangle {
                Layout.preferredWidth: 540
                Layout.fillHeight: true
                color: "#f3f5f8"
                border.color: "#c4ccd7"
                border.width: 1

                ScrollView {
                    anchors.fill: parent
                    contentWidth: availableWidth
                    clip: true

                    ColumnLayout {
                        width: parent.width
                        spacing: 9

                        TileButton {
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 12
                            Layout.fillWidth: true
                            Layout.preferredHeight: 56
                            fontPixelSize: 18
                            tone: ui.seriesRunning ? "danger" : "success"
                            enabled: ui.seriesRunning || (seriesWindow.perturbations.length > 0 && !ui.graphicsBusy)
                            text: !ui.seriesRunning
                                  ? "Start series"
                                  : "Stop series   (" + ui.seriesCompletedRuns + " / " + ui.seriesTotalRuns + ")"
                            onClicked: {
                                if (ui.seriesRunning) {
                                    Julia.stopSeries()
                                    return
                                }

                                // A value that cannot be used stays in its field, in red.
                                const focused = seriesWindow.activeFocusItem
                                if (focused && focused.acceptableInput === false)
                                    return

                                // This tile takes no focus by itself: end the edit in
                                // progress, so that what was typed counts for this run.
                                forceActiveFocus()
                                if (seriesWindow.commitSeriesSettings())
                                    Julia.startSeries()
                            }
                        }

                        Label {
                            Layout.leftMargin: 14
                            Layout.rightMargin: 14
                            Layout.fillWidth: true
                            text: !ui.seriesRunning && seriesWindow.perturbations.length === 0
                                  ? "Add at least one perturbation to start a series."
                                  : ui.seriesStatus
                            color: ui.seriesRunning ? "#2563eb" : "#4b5563"
                            wrapMode: Text.WordWrap
                        }

                        ControlSection {
                            title: "Series settings"
                            expanded: false
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            enabled: !ui.seriesRunning

                            GridLayout {
                                Layout.fillWidth: true
                                columns: 2
                                columnSpacing: 8
                                rowSpacing: 7

                                // Keep the visible value while a field has
                                // focus. Start explicitly commits all fields
                                // before creating a solver task.
                                // Validators use the "C" locale: the fields
                                // show and Julia parses a decimal point, which
                                // a system locale such as pl_PL rejects.
                                Label { text: "Number of runs" }
                                SettingsField {
                                    id: runCountField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: String(ui.seriesRunCount)
                                    onEditingFinished: Julia.setSeriesRunCount(text)
                                }

                                Label { text: "Maximum time / panel" }
                                SettingsField {
                                    id: maximumTimeField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesMaximumTime).toExponential()
                                    onEditingFinished: Julia.setSeriesMaximumTime(text)
                                }

                                Label { text: "Check interval (time)" }
                                SettingsField {
                                    id: checkIntervalField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesCheckInterval).toExponential()
                                    onEditingFinished: Julia.setSeriesCheckInterval(text)
                                }

                                Label { text: "Tolerance on R" }
                                SettingsField {
                                    id: toleranceField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.000000000000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesTolerance).toExponential()
                                    onEditingFinished: Julia.setSeriesTolerance(text)
                                }

                                Label { text: "Consecutive passed checks" }
                                SettingsField {
                                    id: requiredChecksField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: String(ui.seriesRequiredChecks)
                                    onEditingFinished: Julia.setSeriesRequiredChecks(text)
                                }

                                Label { text: "Series dtmax" }
                                SettingsField {
                                    id: dtmaxField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesDtmax).toExponential()
                                    onEditingFinished: Julia.setSeriesDtmax(text)
                                }

                                Label { text: "Safety step limit / panel" }
                                SettingsField {
                                    id: maximumStepsField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesMaximumSteps).toExponential()
                                    onEditingFinished: Julia.setSeriesMaximumSteps(text)
                                }

                                Label { text: "Random seed" }
                                SettingsField {
                                    id: seedField
                                    implicitWidth: 160
                                    selectByMouse: true
                                    validator: RegularExpressionValidator { regularExpression: /[0-9]{1,19}/ }
                                    text: ui.seriesSeed
                                    onEditingFinished: Julia.setSeriesSeed(text)
                                }

                                Label { text: "Head detection variable" }
                                CompactComboBox {
                                    model: seriesWindow.variables
                                    currentIndex: Math.max(0, ui.seriesHeadVariable - 1)
                                    onActivated: Julia.setSeriesHeadVariable(currentIndex + 1)
                                }
                            }

                            Switch {
                                Layout.topMargin: 5
                                text: "Live simulation preview"
                                checked: ui.seriesLivePreview
                                onToggled: Julia.setSeriesLivePreview(checked)
                            }
                        }

                        // The panel selected here is also the panel whose
                        // results are shown; every panel keeps its own preset.
                        ControlSection {
                            title: "Perturbations"
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.bottomMargin: 12

                            // Stays enabled during a run to switch the results.
                            PanelSelector {
                                Layout.fillWidth: true
                                count: ui.segmentCount
                                current: ui.seriesSelectedSegment
                                dark: false
                                badges: seriesWindow.panelPerturbationCounts
                                onActivated: panel => Julia.selectSeriesSegment(panel)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                enabled: !ui.seriesRunning

                                Label {
                                    Layout.topMargin: 6
                                    text: "Preset"
                                    font.bold: true
                                }

                                CompactComboBox {
                                    id: presetComboBox
                                    Layout.fillWidth: true
                                    model: seriesWindow.presets
                                    textRole: "name"
                                    currentIndex: {
                                        for (let index = 0; index < seriesWindow.presets.length; ++index) {
                                            if (seriesWindow.presets[index].key === ui.seriesSelectedPreset)
                                                return index
                                        }
                                        return 0
                                    }
                                    onActivated: {
                                        if (currentIndex >= 0 && currentIndex < seriesWindow.presets.length)
                                            Julia.selectSeriesPreset(seriesWindow.presets[currentIndex].key)
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: seriesWindow.selectedPresetDescription
                                    color: "#68717d"
                                    wrapMode: Text.WordWrap
                                }

                                // Without initial values in the preset there is
                                // only the live state to start from.
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Label { text: seriesWindow.initialConditionLabel }

                                    TileButton {
                                        dark: false
                                        text: seriesWindow.currentStateLabel
                                        checked: !ui.seriesUsePresetInitial
                                        onClicked: Julia.setSeriesUsePresetInitial(false)
                                    }

                                    TileButton {
                                        dark: false
                                        enabled: ui.seriesPresetInitialAvailable
                                        text: seriesWindow.presetInitialLabel
                                        checked: ui.seriesUsePresetInitial
                                        onClicked: Julia.setSeriesUsePresetInitial(true)
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                Label {
                                    Layout.topMargin: 6
                                    text: "New perturbation"
                                    font.bold: true
                                }

                                RowLayout {
                                    Layout.fillWidth: true

                                    Label { text: "Variable" }

                                    CompactComboBox {
                                        model: seriesWindow.variables
                                        currentIndex: Math.max(0, ui.seriesSelectedVariable - 1)
                                        onActivated: Julia.selectSeriesVariable(currentIndex + 1)
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                RowLayout {
                                    Layout.fillWidth: true

                                    Label {
                                        text: "Position (relative): " + Number(ui.seriesPosition).toFixed(3)
                                        Layout.preferredWidth: 170
                                    }

                                    Slider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 1
                                        value: Number(ui.seriesPosition)
                                        onMoved: Julia.setSeriesPosition(value)
                                    }
                                }

                                TileButton {
                                    Layout.alignment: Qt.AlignRight
                                    dark: false
                                    text: "Add perturbation"
                                    onClicked: Julia.addSeriesPerturbation()
                                }
                            }

                            Label {
                                Layout.topMargin: 6
                                text: "Perturbations in panel " + ui.seriesSelectedSegment
                                font.bold: true
                            }

                            Label {
                                Layout.fillWidth: true
                                visible: perturbationModel.count === 0
                                text: "No perturbations in panel " + ui.seriesSelectedSegment + "."
                                color: "#68717d"
                            }

                            Repeater {
                                model: perturbationModel

                                Rectangle {
                                    id: perturbationCard
                                    required property int perturbationId
                                    required property int panel
                                    required property int variable
                                    required property real position
                                    required property real widthMin
                                    required property real widthMax
                                    required property real heightMin
                                    required property real heightMax

                                    function commitField(field, value) {
                                        Julia.updateSeriesPerturbation(perturbationId, field, value)
                                    }

                                    Layout.fillWidth: true
                                    implicitHeight: perturbationCardLayout.implicitHeight + 16
                                    color: "#e6eaf0"
                                    radius: 5
                                    border.color: "#bdc6d2"
                                    border.width: 1

                                    ColumnLayout {
                                        id: perturbationCardLayout
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 5

                                        RowLayout {
                                            Layout.fillWidth: true

                                            Label {
                                                Layout.fillWidth: true
                                                text: "Perturbation " + perturbationCard.perturbationId
                                                font.bold: true
                                            }

                                            TileButton {
                                                dark: false
                                                enabled: !ui.seriesRunning
                                                text: "Delete"
                                                onClicked: Julia.deleteSeriesPerturbation(perturbationCard.perturbationId)
                                            }
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true

                                            Label { text: "Panel" }
                                            CompactComboBox {
                                                Layout.preferredWidth: 75
                                                enabled: !ui.seriesRunning
                                                focusPolicy: Qt.ClickFocus
                                                model: seriesWindow.panelNames
                                                currentIndex: Math.max(0, perturbationCard.panel - 1)
                                                onActivated: perturbationCard.commitField("panel", currentIndex + 1)
                                            }

                                            Label { text: "Variable" }
                                            CompactComboBox {
                                                enabled: !ui.seriesRunning
                                                focusPolicy: Qt.ClickFocus
                                                model: seriesWindow.variables
                                                currentIndex: Math.max(0, perturbationCard.variable - 1)
                                                onActivated: perturbationCard.commitField("variable", currentIndex + 1)
                                            }

                                            Item { Layout.fillWidth: true }
                                        }

                                        GridLayout {
                                            Layout.fillWidth: true
                                            columns: 5
                                            columnSpacing: 6

                                            Label { text: "Position (relative)" }
                                            PerturbationField {
                                                validator: DoubleValidator { bottom: 0; top: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                shown: Number(perturbationCard.position).toFixed(3)
                                                onCommitted: value => perturbationCard.commitField("position", value)
                                            }
                                            Item { Layout.columnSpan: 2 }
                                            // Takes the spare card width, so the
                                            // fields keep their size.
                                            Item {
                                                Layout.fillWidth: true
                                                Layout.rowSpan: 3
                                            }

                                            Label { text: "Width min (0–1)" }
                                            PerturbationField {
                                                validator: DoubleValidator { bottom: 0; top: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                shown: Number(perturbationCard.widthMin).toFixed(2)
                                                onCommitted: value => perturbationCard.commitField("widthMin", value)
                                            }
                                            Label { text: "Width max (0–1)" }
                                            PerturbationField {
                                                validator: DoubleValidator { bottom: 0; top: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                shown: Number(perturbationCard.widthMax).toFixed(2)
                                                onCommitted: value => perturbationCard.commitField("widthMax", value)
                                            }

                                            Label { text: "Height min" }
                                            PerturbationField {
                                                validator: DoubleValidator { notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                shown: Number(perturbationCard.heightMin).toFixed(1)
                                                onCommitted: value => perturbationCard.commitField("heightMin", value)
                                            }
                                            Label { text: "Height max" }
                                            PerturbationField {
                                                validator: DoubleValidator { notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                shown: Number(perturbationCard.heightMax).toFixed(1)
                                                onCommitted: value => perturbationCard.commitField("heightMax", value)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // -------------------------------------------------- results
            ColumnLayout {
                id: resultsColumn
                property var current: {
                    const results = seriesWindow.results
                    for (let index = 0; index < results.length; ++index) {
                        if (results[index].panel === ui.seriesSelectedSegment)
                            return results[index]
                    }
                    return results.length > 0 ? results[0] : null
                }
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 12
                spacing: 8

                PanelSelector {
                    Layout.fillWidth: true
                    visible: ui.segmentCount > 1
                    dark: false
                    count: ui.segmentCount
                    current: ui.seriesSelectedSegment
                    onActivated: panel => Julia.selectSeriesSegment(panel)
                }

                // Plain column, no scroll container: sizing charts from a
                // ScrollView's height feeds the content height back into its
                // implicit height and loops the layout once the content is
                // tall enough for a scrollbar.
                SeriesBarChart {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: resultsColumn.current !== null
                    title: "Head locations"
                    values: resultsColumn.current === null ? [] : resultsColumn.current.locationCounts
                    labels: []
                    xMinimum: resultsColumn.current === null ? NaN : Number(resultsColumn.current.xMin)
                    xMaximum: resultsColumn.current === null ? NaN : Number(resultsColumn.current.xMax)
                    barColor: "#2563eb"
                }

                SeriesBarChart {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: resultsColumn.current !== null
                    title: "Number of heads"
                    values: resultsColumn.current === null ? [] : resultsColumn.current.headCounts
                    labels: resultsColumn.current === null ? [] : resultsColumn.current.headLabels
                    barColor: "#7c3aed"
                }

                SeriesConfigurationChart {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: resultsColumn.current !== null
                    title: "Head configurations"
                    labels: resultsColumn.current === null ? [] : resultsColumn.current.configLabels
                    counts: resultsColumn.current === null ? [] : resultsColumn.current.configCounts
                    heads: resultsColumn.current === null ? [] : resultsColumn.current.configHeads
                    notConverged: resultsColumn.current === null ? 0 : resultsColumn.current.notConverged
                }

                SeriesLineChart {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: resultsColumn.current !== null
                    title: "Patterns"
                    xValues: resultsColumn.current === null ? [] : resultsColumn.current.patternX
                    profiles: resultsColumn.current === null ? [] : resultsColumn.current.patterns
                    converged: resultsColumn.current === null ? [] : resultsColumn.current.patternConverged
                }

                Label {
                    Layout.fillWidth: true
                    visible: resultsColumn.current === null
                    text: "Results will appear after the first completed realization."
                    color: "#68717d"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignTop
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            visible: ui.message.length > 0
            implicitHeight: seriesMessageText.implicitHeight + 18
            color: "#fff0f0"
            border.color: "#c63f45"

            Label {
                id: seriesMessageText
                anchors.fill: parent
                anchors.margins: 9
                text: ui.message
                color: "#9f252b"
                wrapMode: Text.Wrap
            }
        }
    }

    SaveNameDialog {
        id: saveSeriesDialog
        title: "Save series"
        onConfirmed: name => Julia.saveSeries(name)
    }

    // Short confirmation (e.g. after Save series) under the header bar.
    NoticeToast {
        z: 10
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 60
    }
}

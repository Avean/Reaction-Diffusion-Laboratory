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

    property var variables: JSON.parse(ui.variablesJson)
    property var perturbations: JSON.parse(ui.seriesPerturbationsJson)
    property var presets: JSON.parse(ui.seriesPresetsJson)
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
                            enabled: ui.seriesRunning || seriesWindow.perturbations.length > 0
                            text: !ui.seriesRunning
                                  ? "Start series"
                                  : ui.seriesSingleRun
                                    ? "Stop run one"
                                    : "Stop series   (" + ui.seriesCompletedRuns + " / " + ui.seriesTotalRuns + ")"
                            onClicked: {
                                if (ui.seriesRunning)
                                    Julia.stopSeries()
                                else if (seriesWindow.commitSeriesSettings())
                                    Julia.startSeries()
                            }
                        }

                        // Diagnostics: add one realization to the statistics,
                        // then restore the state captured on entering Series.
                        TileButton {
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            fontPixelSize: 15
                            tone: "accent"
                            enabled: !ui.seriesRunning && seriesWindow.perturbations.length > 0
                            text: "Run one"
                            onClicked: {
                                if (seriesWindow.commitSeriesSettings())
                                    Julia.runOneSeries()
                            }

                            ToolTip.visible: hovered
                            ToolTip.text: "Run one realization, add it to the statistics, then restore the original state on the main plots"
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
                                // focus. Start and Run one explicitly commit
                                // all fields before creating a solver task.
                                // Validators use the "C" locale: the fields
                                // show and Julia parses a decimal point, which
                                // a system locale such as pl_PL rejects.
                                Label { text: "Number of runs" }
                                TextField {
                                    id: runCountField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: String(ui.seriesRunCount)
                                    onEditingFinished: Julia.setSeriesRunCount(text)
                                }

                                Label { text: "Maximum time / panel" }
                                TextField {
                                    id: maximumTimeField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesMaximumTime).toExponential()
                                    onEditingFinished: Julia.setSeriesMaximumTime(text)
                                }

                                Label { text: "Check interval (time)" }
                                TextField {
                                    id: checkIntervalField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesCheckInterval).toExponential()
                                    onEditingFinished: Julia.setSeriesCheckInterval(text)
                                }

                                Label { text: "Tolerance on R" }
                                TextField {
                                    id: toleranceField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.000000000000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesTolerance).toExponential()
                                    onEditingFinished: Julia.setSeriesTolerance(text)
                                }

                                Label { text: "Consecutive passed checks" }
                                TextField {
                                    id: requiredChecksField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: String(ui.seriesRequiredChecks)
                                    onEditingFinished: Julia.setSeriesRequiredChecks(text)
                                }

                                Label { text: "Series dtmax" }
                                TextField {
                                    id: dtmaxField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 0.0000000001; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesDtmax).toExponential()
                                    onEditingFinished: Julia.setSeriesDtmax(text)
                                }

                                Label { text: "Safety step limit / panel" }
                                TextField {
                                    id: maximumStepsField
                                    selectByMouse: true
                                    validator: DoubleValidator { bottom: 1; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                    text: Number(ui.seriesMaximumSteps).toExponential()
                                    onEditingFinished: Julia.setSeriesMaximumSteps(text)
                                }

                                Label { text: "Random seed" }
                                TextField {
                                    id: seedField
                                    selectByMouse: true
                                    validator: RegularExpressionValidator { regularExpression: /[0-9]{1,19}/ }
                                    text: ui.seriesSeed
                                    onEditingFinished: Julia.setSeriesSeed(text)
                                }

                                Label { text: "Head detection variable" }
                                ComboBox {
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

                                ComboBox {
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
                                    Layout.topMargin: 6
                                    text: "New perturbation"
                                    font.bold: true
                                }

                                RowLayout {
                                    Layout.fillWidth: true

                                    Label { text: "Variable" }

                                    ComboBox {
                                        Layout.fillWidth: true
                                        model: seriesWindow.variables
                                        currentIndex: Math.max(0, ui.seriesSelectedVariable - 1)
                                        onActivated: Julia.selectSeriesVariable(currentIndex + 1)
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true

                                    Label {
                                        text: "Position: " + Number(ui.seriesPosition).toFixed(2)
                                        Layout.preferredWidth: 138
                                    }

                                    Slider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: Math.max(0.000001, Number(ui.seriesSelectedPanelLength))
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
                                                text: "Perturbation " + perturbationCard.perturbationId + "   ·   x = " + Number(perturbationCard.position).toFixed(2)
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
                                            ComboBox {
                                                Layout.preferredWidth: 75
                                                enabled: !ui.seriesRunning
                                                focusPolicy: Qt.ClickFocus
                                                model: seriesWindow.panelNames
                                                currentIndex: Math.max(0, perturbationCard.panel - 1)
                                                onActivated: perturbationCard.commitField("panel", currentIndex + 1)
                                            }

                                            Label { text: "Variable" }
                                            ComboBox {
                                                Layout.fillWidth: true
                                                enabled: !ui.seriesRunning
                                                focusPolicy: Qt.ClickFocus
                                                model: seriesWindow.variables
                                                currentIndex: Math.max(0, perturbationCard.variable - 1)
                                                onActivated: perturbationCard.commitField("variable", currentIndex + 1)
                                            }
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true

                                            Label { text: "Position" }

                                            TextField {
                                                Layout.fillWidth: true
                                                selectByMouse: true
                                                enabled: !ui.seriesRunning
                                                validator: DoubleValidator { bottom: 0; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                text: Number(perturbationCard.position).toFixed(2)
                                                onEditingFinished: perturbationCard.commitField("position", text)
                                            }
                                        }

                                        GridLayout {
                                            Layout.fillWidth: true
                                            columns: 4
                                            columnSpacing: 6

                                            Label { text: "Width min" }
                                            TextField {
                                                selectByMouse: true
                                                enabled: !ui.seriesRunning
                                                validator: DoubleValidator { bottom: 0; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                text: Number(perturbationCard.widthMin).toFixed(2)
                                                onEditingFinished: perturbationCard.commitField("widthMin", text)
                                            }
                                            Label { text: "Width max" }
                                            TextField {
                                                selectByMouse: true
                                                enabled: !ui.seriesRunning
                                                validator: DoubleValidator { bottom: 0; notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                text: Number(perturbationCard.widthMax).toFixed(2)
                                                onEditingFinished: perturbationCard.commitField("widthMax", text)
                                            }

                                            Label { text: "Height min" }
                                            TextField {
                                                selectByMouse: true
                                                enabled: !ui.seriesRunning
                                                validator: DoubleValidator { notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                text: Number(perturbationCard.heightMin).toFixed(1)
                                                onEditingFinished: perturbationCard.commitField("heightMin", text)
                                            }
                                            Label { text: "Height max" }
                                            TextField {
                                                selectByMouse: true
                                                enabled: !ui.seriesRunning
                                                validator: DoubleValidator { notation: DoubleValidator.ScientificNotation; locale: "C" }
                                                text: Number(perturbationCard.heightMax).toFixed(1)
                                                onEditingFinished: perturbationCard.commitField("heightMax", text)
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

                ControlSection {
                    title: "Domain rescale"
                    enabled: !ui.seriesRunning

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 7

                        Repeater {
                            model: [
                                { key: "1", resolution: 16 },
                                { key: "2", resolution: 40 },
                                { key: "3", resolution: 100 }
                            ]

                            TileButton {
                                required property var modelData
                                Layout.preferredWidth: 30
                                dark: false
                                text: modelData.key
                                checked: Number(ui.domainResolution) === modelData.resolution
                                enabled: !ui.seriesRunning
                                onClicked: Julia.setDomainResolution(modelData.resolution)
                            }
                        }

                        Slider {
                            id: seriesDomainSlider
                            Layout.fillWidth: true
                            from: 0
                            to: 3
                            stepSize: 3 / Math.max(1, Number(ui.domainResolution) - 1)
                            value: 2 * Math.log(Number(ui.domainLength)) / Math.LN10
                            onMoved: Julia.setDomainExponent(value)
                            WheelHandler {
                                onWheel: function(event) {
                                    if (!seriesDomainSlider.enabled || event.angleDelta.y === 0)
                                        return
                                    const next = Math.max(seriesDomainSlider.from,
                                                          Math.min(seriesDomainSlider.to,
                                                                   seriesDomainSlider.value +
                                                                   (event.angleDelta.y > 0 ? seriesDomainSlider.stepSize : -seriesDomainSlider.stepSize)))
                                    Julia.setDomainExponent(next)
                                    event.accepted = true
                                }
                            }
                        }

                        Label {
                            Layout.preferredWidth: 58
                            text: Number(ui.domainLength).toPrecision(3)
                            font.family: "Consolas"
                        }
                    }
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
}

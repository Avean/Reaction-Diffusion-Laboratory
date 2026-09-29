import QtQuick

// The application's shared button. Built from plain items: the native
// Windows style ignores custom backgrounds of the standard Button.
//
//   dark:    true on a dark bar or header (default), false on a light panel.
//   checked: highlighted state; blue on a dark surface, light blue on a
//            light one.
//   tone:    "neutral", or a filled status colour: "accent", "success",
//            "danger", "warning", "attention".
//   detail:  optional muted text after the label, e.g. a count.
Rectangle {
    id: tile

    property string text: ""
    property string detail: ""
    property bool checked: false
    property bool dark: true
    property string tone: "neutral"
    property real minimumTextWidth: 0
    property int fontPixelSize: 0
    signal clicked()

    readonly property bool hovered: mouseArea.containsMouse
    readonly property color toneColor: {
        switch (tone) {
        case "accent": return Theme.accent
        case "success": return Theme.success
        case "danger": return Theme.danger
        case "warning": return Theme.warning
        case "attention": return Theme.attention
        default: return "transparent"
        }
    }

    implicitWidth: Math.max(labels.implicitWidth, minimumTextWidth) + 24
    implicitHeight: Theme.tileHeight
    radius: Theme.tileRadius
    opacity: enabled ? 1.0 : 0.45

    color: tone !== "neutral"
           ? (mouseArea.pressed ? Qt.darker(toneColor, 1.2)
              : hovered ? Qt.lighter(toneColor, 1.12) : toneColor)
           : dark
             ? (checked ? (hovered ? Theme.accentHover : Theme.accent)
                        : (hovered ? Theme.tileDarkHover : Theme.tileDark))
             : (checked ? Theme.tileLightChecked
                        : (hovered ? Theme.tileLightHover : Theme.tileLight))
    border.width: 1
    border.color: tone !== "neutral"
                  ? Qt.darker(toneColor, 1.15)
                  : dark
                    ? (checked ? Theme.accentBorder : Theme.tileDarkBorder)
                    : (checked ? Theme.tileLightCheckedBorder : Theme.tileLightBorder)

    Row {
        id: labels
        anchors.centerIn: parent
        spacing: 6

        Text {
            id: label
            text: tile.text
            font.bold: true
            color: tile.dark || tile.tone !== "neutral"
                   ? "white"
                   : (tile.checked ? Theme.tileLightCheckedText : Theme.text)

            // The default font size is kept unless a button asks for its own.
            Binding on font.pixelSize {
                when: tile.fontPixelSize > 0
                value: tile.fontPixelSize
            }
        }

        Text {
            visible: tile.detail.length > 0
            text: tile.detail
            color: tile.dark || tile.tone !== "neutral"
                   ? (tile.checked ? "#c7d7fb" : "#aab3bf")
                   : (tile.checked ? "#6b8fd6" : Theme.mutedText)
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: tile.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.clicked()
    }
}

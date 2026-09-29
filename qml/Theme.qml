pragma Singleton
import QtQuick

// The application's colours and control sizes, defined once.
QtObject {
    // Surfaces
    readonly property color bar: "#20252d"
    readonly property color header: "#2b313b"
    readonly property color panel: "#f3f5f8"
    readonly property color panelBorder: "#aab3bf"
    readonly property color text: "#20252d"
    readonly property color mutedText: "#68717d"

    // Tiles on a dark surface (bars and headers)
    readonly property color tileDark: "#46515f"
    readonly property color tileDarkHover: "#56626f"
    readonly property color tileDarkBorder: "#697586"
    readonly property color accent: "#3b82f6"
    readonly property color accentHover: "#2563eb"
    readonly property color accentBorder: "#93c5fd"

    // Tiles on a light surface (drawers and panels)
    readonly property color tileLight: "#e7ebf0"
    readonly property color tileLightHover: "#dde3ea"
    readonly property color tileLightBorder: "#c3cad4"
    readonly property color tileLightChecked: "#dbeafe"
    readonly property color tileLightCheckedBorder: "#93c5fd"
    readonly property color tileLightCheckedText: "#1e40af"

    // Status tones
    readonly property color success: "#26945b"
    readonly property color danger: "#c63f45"
    readonly property color warning: "#d79a22"
    readonly property color attention: "#e06a2f"

    // Sizes
    readonly property int tileHeight: 30
    readonly property int tileRadius: 4
    readonly property int headerHeight: 46
    readonly property int cardHeight: 54
    readonly property int cardRadius: 5
}

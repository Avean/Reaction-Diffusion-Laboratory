import QtQuick

// The shared panel selector: one tile per domain panel, the current one
// highlighted. Optional badges (for example perturbation counts) are shown
// next to the panel name when they are positive.
Flow {
    id: selector

    property int count: 0
    property int current: 1
    property bool dark: true
    property var badges: []
    signal activated(int panel)

    spacing: 6

    Repeater {
        model: selector.count

        TileButton {
            required property int index
            readonly property int badge: index < selector.badges.length ? selector.badges[index] : 0
            dark: selector.dark
            text: "Panel " + (index + 1)
            detail: badge > 0 ? "· " + badge : ""
            checked: selector.current === index + 1
            onClicked: selector.activated(index + 1)
        }
    }
}

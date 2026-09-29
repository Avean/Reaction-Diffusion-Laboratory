import QtQuick

// The shared panel selector: one pill per domain panel, the current one
// highlighted. Optional badges (for example perturbation counts) are shown
// next to the panel name when they are positive.
Flow {
    id: selector

    property int count: 0
    property int current: 1
    property var badges: []
    signal activated(int panel)

    spacing: 6

    Repeater {
        model: selector.count

        PillButton {
            required property int index
            readonly property int badge: index < selector.badges.length ? selector.badges[index] : 0
            text: "Panel " + (index + 1) + (badge > 0 ? "  ·  " + badge : "")
            checked: selector.current === index + 1
            onClicked: selector.activated(index + 1)
        }
    }
}

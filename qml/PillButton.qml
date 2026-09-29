import QtQuick

// The application's shared pill button, used for panel selection and for
// small on/off toggles. Built from plain items: the native Windows style
// ignores custom backgrounds of the standard Button.
Rectangle {
    id: pill

    property string text: ""
    property bool checked: false
    signal clicked()

    implicitWidth: label.implicitWidth + 28
    implicitHeight: 30
    radius: height / 2
    opacity: enabled ? 1.0 : 0.45
    color: checked
           ? (mouseArea.pressed ? "#1d4ed8" : "#2563eb")
           : (mouseArea.pressed ? "#dbeafe" : mouseArea.containsMouse ? "#eff6ff" : "#ffffff")
    border.width: 1
    border.color: checked ? "#1d4ed8"
                  : mouseArea.containsMouse ? "#2563eb" : "#c4ccd7"

    Text {
        id: label
        anchors.centerIn: parent
        text: pill.text
        color: pill.checked ? "#ffffff" : "#20252d"
        font.bold: pill.checked
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: pill.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.clicked()
    }
}

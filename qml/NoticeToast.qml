import QtQuick

// Short confirmation (e.g. after Save) shown whenever ui.notice changes; fades
// out after a few seconds. The window places it, usually under its top bar.
Rectangle {
    id: toast

    property string notice: ui.notice

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
        text: toast.notice
        color: "white"
        font.bold: true
    }

    Timer {
        id: noticeTimer
        interval: 3000
        onTriggered: toast.opacity = 0
    }
}

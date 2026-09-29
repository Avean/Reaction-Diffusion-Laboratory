import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A framed card holding one labelled value: the title on the left, then the
// card's children (a field, a button...) in a row.
Rectangle {
    id: card

    property string title: ""
    default property alias content: row.data

    implicitWidth: 260
    implicitHeight: Theme.cardHeight
    radius: Theme.cardRadius
    color: Theme.tileLight
    border.color: Theme.tileLightBorder

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 6
        anchors.leftMargin: 10
        spacing: 7

        Label {
            text: card.title
            font.bold: true
            Layout.preferredWidth: 46
            elide: Text.ElideRight
        }
    }
}

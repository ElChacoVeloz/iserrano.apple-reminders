import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: row

  property var item: null
  property bool hasCursor: false
  property bool busy: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal completeRequested()
  signal entered()

  readonly property bool hot: hasCursor || mouse.containsMouse
  readonly property string metaText: item ? Model.meta(item) : ""

  implicitHeight: Style.space(26)

  Rectangle {
    anchors.fill: parent
    radius: Style.space(2)
    color: row.hot ? Util.alpha(row.foreground, 0.1) : "transparent"
    border.width: row.hot ? Style.normalBorderWidth : 0
    border.color: Util.alpha(row.foreground, 0.45)

    Behavior on color { ColorAnimation { duration: 120 } }
  }

  MouseArea {
    id: mouse

    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.entered()
    onClicked: row.completeRequested()
  }

  Rectangle {
    id: check

    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(10)
    height: width
    radius: width / 2
    color: row.hot ? Util.alpha(row.foreground, 0.18) : "transparent"
    border.width: Style.normalBorderWidth
    border.color: row.item && row.item.color !== "" ? row.item.color
      : (row.hot ? row.foreground : Util.alpha(row.foreground, 0.55))
    opacity: row.busy ? 0.4 : 1
  }

  Text {
    anchors.left: check.right
    anchors.leftMargin: Style.space(8)
    anchors.right: meta.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: row.item ? (row.item.flagged ? Model.glyph.flag + " " : "") + row.item.content : ""
    color: row.foreground
    font.family: row.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    opacity: row.busy ? 0.45 : 1
  }

  Text {
    id: meta

    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, row.width * 0.4)
    text: row.metaText
    color: row.item && row.item.overdue ? row.urgent : Qt.darker(row.foreground, 1.6)
    font.family: row.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideLeft
    opacity: row.busy ? 0.45 : 1
  }
}

import QtQuick
import qs.Commons

// X-axis labels shared by the charts: `ticks` is [{ fraction, text }] across
// this item's width. Labels are kept inside the edges instead of clipping.
Item {
  id: root

  property var ticks: []
  property bool centered: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitHeight: Style.font.caption + Style.space(2)

  Repeater {
    model: root.ticks
    Text {
      required property var modelData
      x: Math.max(0, Math.min(root.width - width, modelData.fraction * root.width - (root.centered ? width / 2 : 0)))
      text: modelData.text
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}

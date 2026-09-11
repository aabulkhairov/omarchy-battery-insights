import QtQuick
import qs.Commons
import "Model.js" as Model

// Battery used per hour (24h) or per day (7d/30d), stacked: awake use
// solid, drain while asleep faded on top. Hovering a bar reports its numbers.
Item {
  id: root

  property var report: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property var buckets: report ? report.buckets : []
  property int hoverIndex: -1

  readonly property string readout: {
    if (hoverIndex < 0 || hoverIndex >= buckets.length) return ""
    var b = buckets[hoverIndex]
    var parts = [Model.formatBucketLabel(b, report.unit)]
    parts.push(Math.round(b.awake) + "% used")
    if (b.batterySec >= 300) parts.push((b.awakeWh / (b.batterySec / 3600)).toFixed(1) + " W")
    if (b.sleep >= 0.5) parts.push(Math.round(b.sleep) + "% asleep")
    return parts.join(" · ")
  }

  // Round the scale up to a readable step so the top label is a clean number.
  readonly property real scaleMax: {
    var m = report ? report.maxUse : 0
    var steps = [5, 10, 20, 25, 40, 50, 75, 100, 150, 200]
    for (var i = 0; i < steps.length; i++) if (m <= steps[i]) return steps[i]
    return Math.ceil(m / 100) * 100
  }

  readonly property real axisWidth: Style.space(30)
  readonly property real axisHeight: Style.font.caption + Style.space(6)
  readonly property real plotWidth: Math.max(1, width - axisWidth)
  readonly property real plotHeight: Math.max(1, height - axisHeight)
  readonly property real slot: buckets.length ? plotWidth / buckets.length : plotWidth

  Rectangle {
    width: root.plotWidth
    height: 1
    y: 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  }

  Rectangle {
    width: root.plotWidth
    height: 1
    y: root.plotHeight - 1
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
  }

  Repeater {
    model: root.buckets

    Item {
      id: slotItem
      required property var modelData
      required property int index
      readonly property bool hovered: root.hoverIndex === index
      readonly property bool future: root.report && modelData.start > root.report.now
      x: index * root.slot
      width: root.slot
      height: root.plotHeight

      readonly property real barWidth: Math.max(2, Math.min(root.slot * 0.68, Style.space(22)))
      readonly property real awakeHeight: Math.min(1, modelData.awake / root.scaleMax) * (height - 1)
      readonly property real sleepHeight: Math.min(1, (modelData.awake + modelData.sleep) / root.scaleMax) * (height - 1) - awakeHeight

      // Hover band so empty buckets are still inspectable.
      Rectangle {
        anchors.fill: parent
        visible: slotItem.hovered && !slotItem.future
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      }

      Rectangle {
        width: slotItem.barWidth
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 1 - slotItem.awakeHeight - height
        height: Math.max(0, slotItem.sleepHeight)
        visible: height >= 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
      }

      Rectangle {
        width: slotItem.barWidth
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 1 - height
        height: slotItem.awakeHeight
        visible: height >= 1
        color: root.foreground
        opacity: slotItem.hovered || root.hoverIndex < 0 ? 0.9 : 0.55
      }
    }
  }

  MouseArea {
    width: root.plotWidth
    height: root.plotHeight
    hoverEnabled: true
    onPositionChanged: function(mouse) {
      var i = Math.floor(mouse.x / root.slot)
      root.hoverIndex = root.report && i >= 0 && i < root.buckets.length && root.buckets[i].start <= root.report.now ? i : -1
    }
    onExited: root.hoverIndex = -1
  }

  Repeater {
    model: [root.scaleMax, 0]
    Text {
      required property real modelData
      required property int index
      x: root.plotWidth + Style.space(6)
      y: index === 0 ? 0 : root.plotHeight - height
      text: Math.round(modelData) + "%"
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  AxisLabels {
    y: root.plotHeight + Style.space(4)
    width: root.plotWidth
    ticks: root.report ? root.report.ticks : []
    centered: root.report ? root.report.unit !== "hour" : false
    foreground: root.foreground
    fontFamily: root.fontFamily
  }
}

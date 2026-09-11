import QtQuick
import qs.Commons
import "Model.js" as Model

// Maximum capacity over the battery's life: the average decline since it
// was made (faded), the days this plugin has tracked (solid), and where the
// current rate lands against the 80% service threshold (dotted).
Item {
  id: root

  property var health: null
  property real nowSec: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color warning: Color.urgent
  property string fontFamily: Style.font.family

  readonly property real year: 365.25 * 86400
  readonly property var history: health ? health.history : []
  readonly property bool drawable: !!health && (health.manufactured > 0 || history.length >= 2)

  readonly property real xStart: {
    if (!health) return 0
    if (health.manufactured > 0) return health.manufactured
    return history.length ? history[0].t : nowSec
  }
  // Leave room ahead of today for the projection: until the 80% crossing,
  // at least six months, at most three years.
  readonly property real xEnd: {
    var past = Math.max(nowSec - xStart, 30 * 86400)
    var ahead = health && health.yearsTo80 ? health.yearsTo80 * year * 1.15 : past * 0.25
    return nowSec + Math.max(0.5 * year, Math.min(3 * year, ahead))
  }
  readonly property real yMin: {
    var low = Math.min(Model.HEALTH_SERVICE_THRESHOLD, health ? health.capacity : 100)
    for (var i = 0; i < history.length; i++) low = Math.min(low, history[i].capacity)
    return Math.floor((low - 5) / 10) * 10
  }
  readonly property real yMax: {
    var high = 100
    for (var i = 0; i < history.length; i++) high = Math.max(high, history[i].capacity)
    return Math.ceil(high / 5) * 5
  }
  readonly property real crossing: health && health.yearsTo80 ? nowSec + health.yearsTo80 * year : 0

  readonly property real axisWidth: Style.space(30)
  readonly property real axisHeight: Style.font.caption + Style.space(6)
  readonly property real plotWidth: Math.max(1, width - axisWidth)
  readonly property real plotHeight: Math.max(1, height - axisHeight)

  function xFor(t) {
    return (t - xStart) / (xEnd - xStart) * plotWidth
  }

  function yFor(v) {
    return 2 + (1 - (v - yMin) / (yMax - yMin)) * (plotHeight - 4)
  }

  function rgba(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function monthYear(t) {
    var d = new Date(t * 1000)
    return Model.MONTH_NAMES[d.getMonth()] + " " + d.getFullYear()
  }

  onHealthChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    width: root.plotWidth
    height: root.plotHeight
    antialiasing: true
    visible: root.drawable

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (!root.drawable) return
      var w = width, h = height
      var health = root.health

      ctx.lineWidth = 1
      ctx.strokeStyle = root.rgba(root.foreground, 0.12)
      var top = Math.round(root.yFor(root.yMax)) + 0.5
      ctx.beginPath(); ctx.moveTo(0, top); ctx.lineTo(w, top); ctx.stroke()

      var th = Math.round(root.yFor(Model.HEALTH_SERVICE_THRESHOLD)) + 0.5
      ctx.strokeStyle = root.rgba(root.warning, 0.7)
      ctx.setLineDash([4, 3])
      ctx.beginPath(); ctx.moveTo(0, th); ctx.lineTo(w, th); ctx.stroke()
      ctx.setLineDash([])

      var nx = Math.round(root.xFor(root.nowSec)) + 0.5
      ctx.strokeStyle = root.rgba(root.foreground, 0.15)
      ctx.beginPath(); ctx.moveTo(nx, 0); ctx.lineTo(nx, h); ctx.stroke()

      var nowY = root.yFor(health.capacity)
      if (health.manufactured > 0) {
        ctx.strokeStyle = root.rgba(root.foreground, 0.45)
        ctx.lineWidth = 1.5
        ctx.beginPath()
        ctx.moveTo(root.xFor(health.manufactured), root.yFor(100))
        ctx.lineTo(root.xFor(root.nowSec), nowY)
        ctx.stroke()
      }

      if (health.rate > 0) {
        var endT = root.xEnd
        var endV = health.capacity - health.rate * (endT - root.nowSec) / root.year
        ctx.strokeStyle = root.rgba(root.foreground, 0.5)
        ctx.lineWidth = 1.2
        ctx.setLineDash([2, 3])
        ctx.beginPath()
        ctx.moveTo(root.xFor(root.nowSec), nowY)
        ctx.lineTo(root.xFor(endT), root.yFor(Math.max(root.yMin, endV)))
        ctx.stroke()
        ctx.setLineDash([])
      }

      var history = root.history
      if (history.length >= 2) {
        ctx.strokeStyle = root.foreground
        ctx.lineWidth = 2
        ctx.beginPath()
        ctx.moveTo(root.xFor(history[0].t), root.yFor(history[0].capacity))
        for (var i = 1; i < history.length; i++) ctx.lineTo(root.xFor(history[i].t), root.yFor(history[i].capacity))
        ctx.stroke()
      }

      if (root.crossing > 0 && root.crossing <= root.xEnd) {
        ctx.fillStyle = root.warning
        ctx.beginPath()
        ctx.arc(root.xFor(root.crossing), th, 3, 0, Math.PI * 2)
        ctx.fill()
      }

      ctx.fillStyle = root.accent
      ctx.beginPath()
      ctx.arc(root.xFor(root.nowSec), nowY, 3.5, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  Repeater {
    // The bottom label steps aside when it would crowd the 80% one.
    model: {
      if (!root.drawable) return []
      var labels = [root.yMax, Model.HEALTH_SERVICE_THRESHOLD]
      if (root.yFor(root.yMin) - root.yFor(Model.HEALTH_SERVICE_THRESHOLD) > Style.font.caption * 1.6) labels.push(root.yMin)
      return labels
    }
    Text {
      required property real modelData
      x: root.plotWidth + Style.space(6)
      y: Math.max(0, Math.min(root.plotHeight - height, root.yFor(modelData) - height / 2))
      text: modelData + "%"
      textFormat: Text.PlainText
      color: modelData === Model.HEALTH_SERVICE_THRESHOLD ? root.warning : root.foreground
      opacity: modelData === Model.HEALTH_SERVICE_THRESHOLD ? 0.9 : 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  AxisLabels {
    visible: root.drawable
    y: root.plotHeight + Style.space(4)
    width: root.plotWidth
    centered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    ticks: {
      if (!root.drawable) return []
      var span = root.xEnd - root.xStart
      var out = [{ fraction: 0, text: root.monthYear(root.xStart) }]
      var nowFraction = (root.nowSec - root.xStart) / span
      out.push({ fraction: nowFraction, text: "Now" })
      if (root.crossing > 0 && root.crossing <= root.xEnd && (root.crossing - root.nowSec) / span > 0.12)
        out.push({ fraction: (root.crossing - root.xStart) / span, text: "80% ≈ " + root.monthYear(root.crossing) })
      return out
    }
  }

  Text {
    visible: !root.drawable
    anchors.centerIn: parent
    text: "Capacity trend appears after a few days of tracking"
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}

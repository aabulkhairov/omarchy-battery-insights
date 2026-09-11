import QtQuick
import qs.Commons
import "Model.js" as Model

// Battery level across the report window. Discharge draws in the bar
// foreground, charging in `accent` (the theme's green), and a dotted line
// bridges time spent asleep. Hovering reports the reading under the cursor.
Item {
  id: root

  property var report: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Text for the section header while hovering; empty otherwise.
  readonly property string readout: {
    var p = hoverPoint
    if (!p) return ""
    var state = p.s === "C" ? "charging" : (p.s === "D" ? "on battery" : "plugged in")
    return Model.formatWhen(p.t, report.now) + " · " + Math.round(p.p) + "% · " + state
  }

  readonly property real axisWidth: Style.space(30)
  readonly property real axisHeight: Style.font.caption + Style.space(6)
  readonly property real plotWidth: Math.max(1, width - axisWidth)
  readonly property real plotHeight: Math.max(1, height - axisHeight)
  property real hoverX: -1
  readonly property var hoverPoint: hoverX < 0 || !report ? null : nearestPoint(hoverX)

  function xFor(t) {
    return (t - report.from) / (report.to - report.from) * plotWidth
  }

  function yFor(p) {
    // 1px inset keeps a 0% or 100% line from being clipped in half.
    return 1 + (1 - Math.max(0, Math.min(100, p)) / 100) * (plotHeight - 2)
  }

  function nearestPoint(x) {
    var pts = report.level
    if (!pts.length) return null
    var t = report.from + x / plotWidth * (report.to - report.from)
    if (t > report.now) return null
    var lo = 0, hi = pts.length - 1
    while (lo < hi) {
      var mid = (lo + hi) >> 1
      if (pts[mid].t < t) lo = mid + 1
      else hi = mid
    }
    if (lo > 0 && t - pts[lo - 1].t < pts[lo].t - t) lo--
    // Nothing logged near the cursor (before tracking started, or asleep).
    if (Math.abs(pts[lo].t - t) > Math.max(Model.GAP_SEC, (report.to - report.from) / plotWidth * 4)) return null
    return pts[lo]
  }

  function rgba(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  onReportChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onHoverXChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    width: root.plotWidth
    height: root.plotHeight
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height

      ctx.lineWidth = 1
      ctx.strokeStyle = root.rgba(root.foreground, 0.12)
      for (var g = 0; g <= 2; g++) {
        var gy = Math.round(root.yFor(g * 50)) + 0.5
        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
      }
      if (!root.report) return
      var ticks = root.report.ticks
      ctx.strokeStyle = root.rgba(root.foreground, 0.06)
      for (var k = 0; k < ticks.length; k++) {
        if (root.report.unit !== "hour") break
        var tx = Math.round(ticks[k].fraction * w) + 0.5
        ctx.beginPath(); ctx.moveTo(tx, 0); ctx.lineTo(tx, h); ctx.stroke()
      }

      var pts = root.report.level
      if (pts.length < 2) return

      // One area under the whole series, sleeps included, so short
      // stretches between sleeps do not turn into slivers.
      ctx.beginPath()
      ctx.moveTo(root.xFor(pts[0].t), h)
      for (var a = 0; a < pts.length; a++) ctx.lineTo(root.xFor(pts[a].t), root.yFor(pts[a].p))
      ctx.lineTo(root.xFor(pts[pts.length - 1].t), h)
      ctx.closePath()
      ctx.fillStyle = root.rgba(root.foreground, 0.1)
      ctx.fill()

      // Segments are batched by style so a long range costs a handful of
      // paths rather than one per reading.
      function styleOf(a, b) { return b.gap ? "sleep" : (a.s === "C" ? "charge" : "use") }
      function draw(style, run) {
        if (run.length < 2) return
        if (style === "charge") {
          ctx.beginPath()
          ctx.moveTo(root.xFor(run[0].t), h)
          for (var i = 0; i < run.length; i++) ctx.lineTo(root.xFor(run[i].t), root.yFor(run[i].p))
          ctx.lineTo(root.xFor(run[run.length - 1].t), h)
          ctx.closePath()
          ctx.fillStyle = root.rgba(root.accent, 0.25)
          ctx.fill()
        }
        ctx.beginPath()
        ctx.setLineDash(style === "sleep" ? [2, 3] : [])
        ctx.lineWidth = style === "sleep" ? 1 : 1.6
        ctx.strokeStyle = style === "charge" ? root.accent
          : (style === "sleep" ? root.rgba(root.foreground, 0.4) : root.foreground)
        ctx.moveTo(root.xFor(run[0].t), root.yFor(run[0].p))
        for (var j = 1; j < run.length; j++) ctx.lineTo(root.xFor(run[j].t), root.yFor(run[j].p))
        ctx.stroke()
        ctx.setLineDash([])
      }

      var run = [pts[0]]
      var style = ""
      for (var n = 1; n < pts.length; n++) {
        var next = styleOf(pts[n - 1], pts[n])
        if (style && next !== style) {
          draw(style, run)
          run = [pts[n - 1]]
        }
        style = next
        run.push(pts[n])
      }
      draw(style, run)

      var hp = root.hoverPoint
      if (root.hoverX >= 0) {
        ctx.strokeStyle = root.rgba(root.foreground, 0.35)
        ctx.lineWidth = 1
        var hx = Math.round(hp ? root.xFor(hp.t) : root.hoverX) + 0.5
        ctx.beginPath(); ctx.moveTo(hx, 0); ctx.lineTo(hx, h); ctx.stroke()
      }
      if (hp) {
        ctx.fillStyle = hp.s === "C" ? root.accent : root.foreground
        ctx.beginPath()
        ctx.arc(root.xFor(hp.t), root.yFor(hp.p), 3, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  MouseArea {
    anchors.fill: canvas
    hoverEnabled: true
    onPositionChanged: function(mouse) { root.hoverX = mouse.x }
    onExited: root.hoverX = -1
  }

  // Y-axis labels on the right, as on macOS.
  Repeater {
    model: [100, 50, 0]
    Text {
      required property int modelData
      x: root.plotWidth + Style.space(6)
      y: Math.max(0, Math.min(root.plotHeight - height, root.yFor(modelData) - height / 2))
      text: modelData + "%"
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

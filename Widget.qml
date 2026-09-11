import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus the Battery Insights panel: battery level and usage for
// the last 24 hours, 7 days or 30 days, and battery health over its life.
// Data comes from the log Service.qml keeps; this side only reads it.
Panel {
  id: root
  moduleName: "aabulkhairov.battery-insights"
  ipcTarget: "aabulkhairov.battery-insights"
  // The panel owns its IpcHandler so it can add `range` to the stock verbs.
  manageIpc: false

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/battery-insights"
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/battery-insights").toString().replace(/^file:\/\//, ""))

  readonly property var rangeOptions: [
    { value: "24h", label: "24 hours" },
    { value: "7d", label: "7 days" },
    { value: "30d", label: "30 days" }
  ]
  property string range: "24h"
  property var samples: []
  property var healthRows: []
  property var info: ({})
  property var report: null
  property var health: null

  readonly property bool showRate: setting("showRate", false) === true

  // ---- live readings for the bar button and hero
  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  readonly property real percent: batteryPresent ? Math.max(0, Math.min(1, device.percentage)) * 100 : 0
  readonly property bool onBattery: batteryPresent && UPower.onBattery
  readonly property bool charging: batteryPresent && device.state === UPowerDeviceState.Charging
  readonly property real rateW: batteryPresent ? Math.abs(Number(device.changeRate) || 0) : 0
  readonly property bool showRateNow: showRate && onBattery && rateW > 0 && !vertical
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string statusText: {
    if (!batteryPresent) return "No battery"
    if (onBattery) {
      var left = device.timeToEmpty > 0 ? " · " + Model.formatDuration(device.timeToEmpty) + " left" : ""
      return "On battery · " + rateW.toFixed(1) + " W" + left
    }
    if (charging) {
      var full = device.timeToFull > 0 ? " · " + Model.formatDuration(device.timeToFull) + " to full" : ""
      return "Charging · " + rateW.toFixed(1) + " W" + full
    }
    if (device.state === UPowerDeviceState.FullyCharged) return "Fully charged"
    return "Plugged in · not charging"
  }

  function service() {
    return bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor(moduleName) : null
  }

  function rebuild() {
    var now = Math.floor(Date.now() / 1000)
    report = Model.buildReport(samples, range, now)
    health = Model.healthReport(info, healthRows, now)
  }

  function setRange(value) {
    if (value === range) return
    range = value
    rebuild()
  }

  function stepRange(delta) {
    var i = 0
    for (var k = 0; k < rangeOptions.length; k++) if (rangeOptions[k].value === range) i = k
    setRange(rangeOptions[(i + delta + rangeOptions.length) % rangeOptions.length].value)
  }

  function refresh() {
    samplesFile.reload()
    healthFile.reload()
    if (!infoProc.running) infoProc.running = true
    var s = service()
    if (s && s.sampleNow) s.sampleNow()
  }

  function toggleRate() {
    root.settings = Object.assign({}, root.settings, { showRate: !root.showRate })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // omarchy-shell aabulkhairov.battery-insights <open|close|toggle|range 7d>
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function range(value: string): void {
      if (Model.RANGES[value]) root.setRange(value)
      root.open()
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      // A month of minute readings is a few MB once parsed; only hold it
      // while the panel is up.
      samples = []
    }
  }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  FileView {
    id: samplesFile
    path: root.opened ? root.stateDir + "/samples.csv" : ""
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { root.samples = Model.parseSamples(text()); root.rebuild() }
    onLoadFailed: { root.samples = []; root.rebuild() }
  }

  FileView {
    id: healthFile
    path: root.opened ? root.stateDir + "/health.csv" : ""
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { root.healthRows = Model.parseHealth(text()); root.rebuild() }
    onLoadFailed: { root.healthRows = []; root.rebuild() }
  }

  // Charging draws in the theme's green, as macOS draws it, falling back to
  // the accent for themes without one.
  property color chargeColor: Color.accent

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var m = /^\s*(?:green|color2)\s*=\s*"(#[0-9a-fA-F]{6,8})"/m.exec(text())
      root.chargeColor = m ? m[1] : Color.accent
    }
  }

  Process {
    id: infoProc
    command: ["bash", root.helper, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.info = Model.parseInfo(text); root.rebuild() }
    }
  }

  // Keep "now" moving while the panel stays open.
  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.rebuild()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showRateNow ? root.rateW.toFixed(1) + "W 󰄪" : "󰄪"
    slotSize: Style.bar.iconSlot * (root.showRateNow ? 2.6 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleRate()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepRange(dx)
        else scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, scroll.contentY + dy * Style.space(60)))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "1") root.setRange("24h")
        else if (t === "2") root.setRange("7d")
        else if (t === "3") root.setRange("30d")
        else if (t === "r") root.refresh()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroLabels.implicitHeight, heroPercent.implicitHeight)

            Column {
              id: heroLabels
              anchors.left: parent.left
              anchors.right: heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Battery"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.statusText.toUpperCase()
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Text {
              id: heroPercent
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Math.round(root.percent) + "%"
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }
          }

          ButtonGroup {
            options: root.rangeOptions
            value: root.range
            focusable: false
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(value) { root.setRange(value) }
          }

          // ---------- Battery level ----------
          SectionRow {
            title: "BATTERY LEVEL"
            detail: levelChart.readout
          }

          LevelChart {
            id: levelChart
            width: parent.width
            height: Style.space(112)
            report: root.report
            foreground: root.bar.foreground
            accent: root.chargeColor
            fontFamily: root.bar.fontFamily
          }

          // ---------- Usage ----------
          SectionRow {
            title: root.report && root.report.unit === "hour" ? "USAGE PER HOUR" : "USAGE PER DAY"
            detail: usageChart.readout
            legend: usageChart.readout === ""
          }

          UsageChart {
            id: usageChart
            width: parent.width
            height: Style.space(76)
            report: root.report
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: !!root.report && !root.report.hasData
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No readings in this range yet. The log fills in once a minute while the widget is in your bar."
            textFormat: Text.PlainText
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Range stats ----------
          Grid {
            visible: !!root.report
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap
            readonly property real cellWidth: (width - columnSpacing) / 2

            Stat {
              width: parent.cellWidth
              label: "On battery"
              value: root.report ? Model.formatDuration(root.report.totals.batterySec) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Used"
              value: root.report ? Math.round(root.report.totals.awake + root.report.totals.sleep) + "% · "
                + (root.report.totals.awakeWh + root.report.totals.sleepWh).toFixed(1) + " Wh" : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Avg drain"
              value: root.report && root.report.drainW !== null
                ? root.report.drainW.toFixed(1) + " W · " + root.report.drainPctH.toFixed(1) + "%/h" : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Full charge lasts"
              value: root.report && root.report.runtimeH !== null ? "~" + Model.formatHours(root.report.runtimeH) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Sleep drain"
              value: root.report && root.report.sleepPctH !== null ? root.report.sleepPctH.toFixed(2) + "%/h" : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Last charged"
              value: {
                var c = root.report ? root.report.lastCharge : null
                if (!c) return "—"
                if (c.charging) return "Charging now"
                return Math.round(c.p) + "% · " + Model.formatWhen(c.t, root.report.now)
              }
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          // ---------- Health ----------
          SectionRow {
            title: "BATTERY HEALTH"
            detail: root.health ? root.health.condition : ""
            detailColor: root.health && root.health.capacity < Model.HEALTH_SERVICE_THRESHOLD ? Color.urgent : root.bar.foreground
          }

          Item {
            visible: !!root.health
            width: parent.width
            implicitHeight: Math.max(capacityValue.implicitHeight, capacityLabels.implicitHeight)

            Text {
              id: capacityValue
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.health ? Model.formatPercent(root.health.capacity, 1) : ""
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
            }

            Column {
              id: capacityLabels
              anchors.left: capacityValue.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                text: "Maximum capacity"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: root.health ? root.health.fullWh.toFixed(1) + " of " + root.health.designWh.toFixed(1)
                  + " Wh design · " + Model.formatPercent(root.health.loss, 1) + " lost" : ""
                textFormat: Text.PlainText
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          HealthChart {
            visible: !!root.health
            width: parent.width
            height: Style.space(84)
            health: root.health
            nowSec: root.report ? root.report.now : Date.now() / 1000
            foreground: root.bar.foreground
            accent: Color.accent
            warning: Color.urgent
            fontFamily: root.bar.fontFamily
          }

          Grid {
            visible: !!root.health
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap
            readonly property real cellWidth: (width - columnSpacing) / 2

            Stat {
              width: parent.cellWidth
              label: "Cycle count"
              value: root.health && root.health.cycles > 0 ? String(root.health.cycles) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Battery age"
              value: root.health ? Model.formatYears(root.health.ageYears) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Loss per 100 cycles"
              value: root.health ? Model.formatPercent(root.health.per100Cycles, 1) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Loss per year"
              value: root.health ? Model.formatPercent(root.health.perYear, 1) : "—"
            }
            Stat {
              width: parent.cellWidth
              label: "Measured trend"
              value: {
                var h = root.health
                if (!h) return "—"
                if (h.trend) return "−" + h.trend.perYear.toFixed(1) + "%/yr"
                return "tracking " + Math.min(h.trackedDays, Model.TREND_MIN_DAYS) + "/" + Model.TREND_MIN_DAYS + " d"
              }
            }
            Stat {
              width: parent.cellWidth
              label: "Reaches 80%"
              value: {
                var h = root.health
                if (!h) return "—"
                if (h.capacity < Model.HEALTH_SERVICE_THRESHOLD) return "already below"
                return h.yearsTo80 !== null ? "in ~" + Model.formatYears(h.yearsTo80) : "—"
              }
            }
          }
        }
      }
    }
  }

  // Section title with a right-aligned detail: a chart's hover readout, or
  // the usage legend when nothing is hovered.
  component SectionRow: Item {
    property string title: ""
    property string detail: ""
    property bool legend: false
    property color detailColor: root.bar.foreground

    width: parent.width
    implicitHeight: header.implicitHeight

    PanelSectionHeader {
      id: header
      text: parent.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Text {
      visible: !parent.legend && parent.detail !== ""
      anchors.right: parent.right
      anchors.baseline: header.baseline
      width: Math.min(implicitWidth, parent.width - header.implicitWidth - Style.space(12))
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      text: parent.detail
      textFormat: Text.PlainText
      color: parent.detailColor
      opacity: 0.8
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      visible: parent.legend
      anchors.right: parent.right
      anchors.verticalCenter: header.verticalCenter
      spacing: Style.space(10)

      LegendKey { label: "Awake"; swatchOpacity: 0.9 }
      LegendKey { label: "Asleep"; swatchOpacity: 0.3 }
    }
  }

  component LegendKey: Row {
    property string label: ""
    property real swatchOpacity: 1
    spacing: Style.space(4)

    Rectangle {
      width: Style.space(8)
      height: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      color: root.bar.foreground
      opacity: parent.swatchOpacity
    }
    Text {
      text: parent.label
      textFormat: Text.PlainText
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Stat: Item {
    property string label: ""
    property string value: ""
    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      anchors.left: parent.left
      text: parent.label
      textFormat: Text.PlainText
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: statValue
      anchors.right: parent.right
      anchors.left: statLabel.right
      anchors.leftMargin: Style.space(8)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      text: parent.value
      textFormat: Text.PlainText
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}

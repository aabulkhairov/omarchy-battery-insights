import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// Headless logger: one battery reading a minute through bin/battery-insights,
// so the charts have history whether or not the panel was ever opened. The
// shell loads it while the widget is enabled.
Item {
  id: root

  property var shell: null

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/battery-insights").toString().replace(/^file:\/\//, ""))
  // The first run also imports UPower's recent history into the log.
  property bool backfilled: false
  property bool pending: false

  signal sampled()

  function sampleNow() {
    if (sampleProc.running) {
      pending = true
      return
    }
    sampleProc.command = ["bash", helper, "sample"].concat(backfilled ? [] : ["--backfill"])
    sampleProc.running = true
  }

  Process {
    id: sampleProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) console.warn("battery-insights: " + text.trim())
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.backfilled = true
        root.sampled()
      } else if (exitCode === 2) {
        // No system battery (a desktop): nothing to log, stop asking.
        sampleTimer.running = false
        root.pending = false
        return
      }
      if (root.pending) {
        root.pending = false
        root.sampleNow()
      }
    }
  }

  Timer {
    id: sampleTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sampleNow()
  }

  // Plugging in or out gets its own reading so the charts show the switch
  // at the moment it happened, not up to a minute later.
  Connections {
    target: UPower
    function onOnBatteryChanged() { root.sampleNow() }
  }
}

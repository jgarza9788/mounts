import QtQuick
import Quickshell.Io
import qs.Ui

// Bar icon for jgarza.mounts: a network-drive glyph plus how many saved
// connections are mounted. Click opens the Mounts window (middle-click: refresh).
// Dimmed = nothing mounted; accent = at least one mounted.
BarWidget {
  id: root
  moduleName: "jgarza.mounts"

  property int mounted: 0
  property int total: 0
  readonly property bool showCount: setting("showCount", true) !== false
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true
  readonly property int pollMs: Math.max(5, Number(setting("pollIntervalSec", 15)) || 15) * 1000
  readonly property string ctl: String(Qt.resolvedUrl("bin/mountsctl")).replace(/^file:\/\//, "")

  visible: !(hideWhenEmpty && total === 0)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { if (!lister.running) lister.running = true }

  Process {
    id: lister
    command: [root.ctl, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var list = JSON.parse(text).connections || []
          root.total = list.length
          root.mounted = list.filter(function (c) { return c.mounted }).length
        } catch (e) { /* helper not built yet: keep the last numbers */ }
      }
    }
  }

  Timer { interval: root.pollMs; running: root.visible; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋊" + (root.showCount && root.total > 0 ? " " + root.mounted : "")
    active: root.mounted > 0
    dimmed: root.mounted === 0
    tooltipText: root.total === 0 ? "Mounts — no connections yet"
      : "Mounts — " + root.mounted + " of " + root.total + " mounted"
    onPressed: function (b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.bar.run("omarchy-shell shell toggle jgarza.mounts")
    }
  }
}

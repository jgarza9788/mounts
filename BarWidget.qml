import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon for jgarza.mounts: a network-drive glyph plus how many saved
// connections are mounted. Click opens the Mounts window (middle-click: refresh).
// Normal = something mounted; dimmed = nothing mounted; red (the bar's "active"
// colour, which Omarchy uses for urgent) = a connection's last mount failed.
BarWidget {
  id: root
  moduleName: "jgarza.mounts"

  property int mounted: 0
  property int total: 0
  property var failedNames: []
  property string errorText: ""    // mountsctl can't read the saved connections
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
          var reply = JSON.parse(text)
          root.errorText = reply.error || ""
          if (reply.error) return
          var list = reply.connections || []
          root.total = list.length
          root.mounted = list.filter(function (c) { return c.mounted }).length
          root.failedNames = list.filter(function (c) { return !c.mounted && c.last_error }).map(function (c) { return c.name })
        } catch (e) { /* helper not built yet: keep the last numbers */ }
      }
    }
  }

  Timer { interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  // WidgetButton at the standard bar icon font, like jgarza.drives. BarIconButton
  // draws inside an optical canvas that shrinks the glyph and count.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontSize: Style.bar.iconFont
    horizontalMargin: 5
    text: "󰋊" + (root.showCount && root.total > 0 ? " " + root.mounted : "")
    active: root.failedNames.length > 0 || root.errorText !== ""
    dimmed: root.mounted === 0 && root.failedNames.length === 0
    tooltipText: root.errorText !== "" ? "Mounts — " + root.errorText : (root.total === 0 ? "Mounts — no connections yet"
      : "Mounts — " + root.mounted + " of " + root.total + " mounted")
      + (root.failedNames.length > 0 ? "\nFailed: " + root.failedNames.join(", ") + " — open Mounts → Log" : "")
    onPressed: function (b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.bar.run("omarchy-shell shell toggle jgarza.mounts")
    }
  }
}

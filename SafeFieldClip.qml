import QtQuick
import Quickshell.Io

// One clipboard transfer for SafeField, run out of process so the shell never
// reads clipboard data itself.
//   paste: `wl-paste` under a 2 s timeout, cut to byteLimit bytes by `head`,
//          so a huge or never-ending clipboard offer cannot stall the shell.
//   copy:  `wl-copy` reads the text from stdin (never from argv, which other
//          local accounts could read from the process list).
// Emits done(text) once (text is "" for copy, a failure or an empty paste).
Item {
  id: root

  property string mode: "paste"
  property int byteLimit: 4096
  property string payload: ""
  property bool _finished: false

  signal done(string text)

  function start() {
    proc.command = mode === "copy"
      ? ["wl-copy", "--type", "text/plain;charset=utf-8"]
      : ["sh", "-c", "timeout -k 1 2 wl-paste --no-newline --type text/plain 2>/dev/null | head -c \"$1\"", "sh", String(Math.max(1, byteLimit))]
    proc.running = true
    guard.start()
  }

  function _finish(text) {
    if (_finished) return
    _finished = true
    guard.stop()
    done(text)
  }

  Process {
    id: proc
    stdinEnabled: root.mode === "copy"
    // Setting stdinEnabled to false closes stdin, so wl-copy sees EOF.
    onStarted: if (root.mode === "copy") {
      write(root.payload)
      root.payload = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: if (root.mode === "paste") root._finish(String(text).substring(0, root.byteLimit))
    }
    onExited: if (root.mode === "copy") root._finish("")
  }

  // The helper is already bounded by `timeout`; this only makes sure done()
  // fires if the process never reports back.
  Timer {
    id: guard
    interval: 4000
    onTriggered: { proc.running = false; root._finish("") }
  }
}

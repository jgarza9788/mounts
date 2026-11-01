import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mounts — saved network connections (SMB / SFTP / NFS) with mount, unmount,
// auto-mount at login and keyring-stored passwords. All real work happens in
// bin/mountsctl (Rust); this file is the UI and talks to it with JSON.
//
// Lifecycle verbs (open/close/toggle/summon/hide/dismiss + writable `opened`)
// follow the Omarchy overlay-plugin contract; the surface is a FloatingWindow.
Item {
  id: root

  // ── Injected by the Omarchy shell loader ─────────────────────────────────
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: String((manifest && manifest.id) || "jgarza.mounts")

  readonly property string ctl: Qt.resolvedUrl("bin/mountsctl").toString().replace(/^file:\/\//, "")

  // ── State ────────────────────────────────────────────────────────────────
  property bool opened: false
  property bool closing: false
  readonly property bool revealed: opened && !closing

  property var connections: []
  property var busy: ({})          // id -> true while a mount/unmount runs
  property bool saving: false
  property bool loaded: false
  property string toastText: ""
  property bool toastError: false
  property string confirmDeleteId: ""
  property var form: null          // null = list view; object = add/edit form
  property var deps: ({})          // result of `mountsctl deps`
  property bool depsLoaded: false

  // Warnings about missing tools that matter for the saved connections.
  readonly property var depWarnings: {
    var w = [];
    if (!root.depsLoaded) return w;
    var d = root.deps, used = {}, i;
    for (i = 0; i < root.connections.length; i++) {
      used[root.connections[i].protocol] = true;
      if (root.connections[i].backend === "sshfs") used.sshfs = true;
    }
    if (!d.gio) w.push("gio is missing (install glib2)");
    if (!d.secret_tool) w.push("secret-tool is missing — passwords can't be stored (install libsecret)");
    if (used.sftp && !d.gvfs_sftp) w.push("SFTP via gio needs the gvfs package");
    if (used.smb && !d.gvfs_smb) w.push("SMB needs gvfs-smb");
    if (used.nfs && !d.gvfs_nfs) w.push("NFS needs gvfs-nfs");
    if (used.sshfs && !d.sshfs) w.push("sshfs is not installed — run setup.sh --install (or sudo pacman -S sshfs)");
    if (used.sshfs && d.sshfs && !d.fusermount) w.push("fusermount is missing — can't unmount sshfs (install fuse3)");
    return w;
  }

  // First problem with the form, or "" when it can be saved. Mirrors the checks
  // in mountsctl so the person sees the reason before pressing Save.
  function formProblem(f) {
    if (!f) return "";
    var host = String(f.host || "").trim();
    var path = String(f.path || "").trim();
    if (!String(f.name || "").trim()) return "Give it a name.";
    if (!host) return "Enter a host.";
    if (host.charAt(0) === "-" || /[\s\/@]/.test(host)) return "Host can't contain spaces, / or @ (put the user in User).";
    if (/[\s\/@]/.test(String(f.user || "")) || String(f.user || "").charAt(0) === "-") return "User can't contain spaces, / or @.";
    if (f.port !== "" && !(/^\d+$/.test(f.port) && Number(f.port) >= 1 && Number(f.port) <= 65535)) return "Port must be a number from 1 to 65535.";
    if (f.protocol === "smb" && path.replace(/^\/+|\/+$/g, "") === "") return "SMB needs a share name.";
    if (path.split("/").indexOf("..") !== -1) return "Path can't contain '..'.";
    return "";
  }
  readonly property string formError: root.formProblem(root.form)

  function toast(t, isError) {
    root.toastText = t; root.toastError = !!isError; toastTimer.restart();
  }
  Timer { id: toastTimer; interval: 5000; onTriggered: root.toastText = "" }

  // ── Talking to mountsctl ─────────────────────────────────────────────────
  // One Process per call so slow mounts never block each other. `stdinJson`
  // (optional) is piped in; the reply is always one JSON object.
  Component {
    id: procFactory
    Process {
      id: p
      property var done: null
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var r;
          try { r = JSON.parse(String(text || "{}")); } catch (e) {
            r = { error: String(text || "").trim() === ""
                  ? "mountsctl didn't answer — build it with ./build.sh in the plugin folder"
                  : "unreadable reply from mountsctl" };
          }
          if (p.done) p.done(r);
          p.destroy();
        }
      }
    }
  }
  function ctlRun(args, stdinJson, done) {
    var cmd = stdinJson === undefined
      ? [root.ctl].concat(args)
      : ["bash", "-c", 'printf %s "$1" | "$2" "${@:3}"', "_", stdinJson, root.ctl].concat(args);
    var p = procFactory.createObject(root, { command: cmd, done: done });
    p.running = true;
  }

  function refresh() {
    ctlRun(["list"], undefined, function (r) {
      if (r.error) { root.toast(r.error, true); return; }
      var list = (r.connections || []).slice();
      list.sort(function (a, b) {
        if (a.mounted !== b.mounted) return a.mounted ? -1 : 1;
        return String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1;
      });
      root.connections = list;
      root.loaded = true;
    });
  }
  function refreshDeps() {
    ctlRun(["deps"], undefined, function (r) {
      if (r.error) return;
      root.deps = r; root.depsLoaded = true;
    });
  }

  readonly property int mountedCount: root.connections.filter(function (c) { return c.mounted; }).length
  function mountAll(on) {
    root.connections.forEach(function (c) {
      if (!!c.mounted !== on && !root.busy[c.id]) root.mountOrUnmount(c);
    });
  }

  function setBusy(id, on) {
    var b = Object.assign({}, root.busy);
    if (on) b[id] = true; else delete b[id];
    root.busy = b;
  }

  function mountOrUnmount(c) {
    var verb = c.mounted ? "unmount" : "mount";
    root.setBusy(c.id, true);
    ctlRun([verb, c.id], undefined, function (r) {
      root.setBusy(c.id, false);
      if (r.error) root.toast(c.name + ": " + r.error, true);
      else root.toast(c.name + (c.mounted ? " unmounted" : " mounted"), false);
      root.refresh();
    });
  }

  function openFolder(c) {
    Quickshell.execDetached(["xdg-open", c.mountpoint || c.uri]);
  }

  function toggleAutostart(c) {
    root.saving = true;
    ctlRun(["autostart", c.autostart ? "disable" : "enable", c.id], undefined, function (r) {
      root.saving = false;
      if (r.error) root.toast(r.error, true);
      root.refresh();
    });
  }

  function deleteConnection(c) {
    root.confirmDeleteId = "";
    root.saving = true;
    ctlRun(["delete", c.id], undefined, function (r) {
      root.saving = false;
      if (r.error) root.toast(r.error, true); else root.toast(c.name + " deleted", false);
      root.refresh();
    });
  }

  function newForm() {
    root.form = { id: "", name: "", protocol: "smb", host: "", user: "", port: "", path: "",
                  backend: "gio", autostart: false, password: "", clearPassword: false, hasPassword: false };
    Qt.callLater(function () { nameField.forceActiveFocus(); });
  }
  function editForm(c) {
    root.form = { id: c.id, name: c.name, protocol: c.protocol, host: c.host, user: c.user || "",
                  port: c.port ? String(c.port) : "", path: c.path || "", backend: c.backend,
                  autostart: !!c.autostart, password: "", clearPassword: false, hasPassword: !!c.has_password };
    Qt.callLater(function () { nameField.forceActiveFocus(); });
  }
  function setForm(key, value) {
    var f = Object.assign({}, root.form);
    f[key] = value;
    if (key === "protocol" && value !== "sftp" && f.backend === "sshfs") f.backend = "gio";
    root.form = f;
  }

  function saveForm() {
    var f = root.form;
    if (!f || root.saving) return;
    if (root.formError !== "") { root.toast(root.formError, true); return; }
    var port = parseInt(f.port, 10);
    var body = { id: f.id, name: f.name, protocol: f.protocol, host: f.host, user: f.user,
                 path: f.path, backend: f.backend, autostart: f.autostart };
    if (isFinite(port) && port > 0) body.port = port;
    if (f.password) body.password = f.password;
    if (f.clearPassword) body.clearPassword = true;
    root.saving = true;
    ctlRun(["save"], JSON.stringify(body), function (r) {
      root.saving = false;
      if (r.error) { root.toast(r.error, true); return; }
      // Autostart is a separate flag handled by `save` only through the body,
      // but the unit needs syncing; mountsctl does that on every save.
      root.form = null;
      root.toast("Saved " + (r.connection ? r.connection.name : ""), false);
      root.refresh();
    });
  }

  // ── Lifecycle verbs (overlay contract) ──────────────────────────────────
  function open(payloadJson) {
    closeTimer.stop();
    root.closing = false;
    root.opened = true;
    root.form = null;
    root.confirmDeleteId = "";
    refresh();
    refreshDeps();
    Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
  }
  function close() { closeTimer.stop(); root.opened = false; root.closing = false; }
  function dismiss() {
    if (!root.opened && !root.closing) {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
      return;
    }
    if (root.closing) return;
    root.closing = true;
    root.opened = false;
    closeTimer.restart();
  }
  function finishClose() {
    root.close();
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
  }
  function toggle() {
    if (root.opened && !root.closing) root.dismiss();
    else if (!root.closing) root.open("{}");
  }
  function summon(payloadJson) { root.open(payloadJson || "{}"); }
  function hide() { root.dismiss(); }
  Timer { id: closeTimer; interval: 200; onTriggered: root.finishClose() }

  // Keep the status dots honest while the window is up.
  Timer {
    interval: 5000; repeat: true
    running: root.opened && !root.form
    onTriggered: root.refresh()
  }

  // ── The overlay surface ─────────────────────────────────────────────────
  // A normal, resizable Hyprland window (title bar, tiling/floating rules
  // apply) rather than a fullscreen layer-shell overlay.
  FloatingWindow {
    id: win
    title: "Mounts"
    visible: root.opened
    color: Color.background
    implicitWidth: Style.space(820)
    implicitHeight: Style.space(620)
    minimumSize: Qt.size(Style.space(560), Style.space(420))

    // The window manager closed it (e.g. super+Q): sync state, then restore
    // the binding in case the close broke it so the window can reopen.
    onVisibleChanged: {
      if (!visible && root.opened) {
        root.dismiss();
        Qt.callLater(function () { win.visible = Qt.binding(function () { return root.opened; }); });
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.form) root.form = null; else root.dismiss();
          event.accepted = true;
        } else if (!root.form && event.text === "n") {
          root.newForm(); event.accepted = true;
        } else if (!root.form && event.text === "r") {
          root.refresh(); event.accepted = true;
        } else if (!root.form && event.text === "q") {
          root.dismiss(); event.accepted = true;
        }
      }

      Rectangle {
        id: card
        anchors.fill: parent
        color: Color.background

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(14)
          spacing: Style.space(10)

          // ── Header ──────────────────────────────────────────────────────
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text {
              text: root.form ? (root.form.id ? "Edit connection" : "New connection") : "Mounts"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { Layout.fillWidth: true; implicitHeight: 1 }
            Button {
              visible: !root.form
              text: "New"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Add a connection (n)"
              onClicked: root.newForm()
            }
            Button {
              visible: !root.form && root.connections.length > root.mountedCount
              text: "Mount all"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Mount every saved connection"
              onClicked: root.mountAll(true)
            }
            Button {
              visible: !root.form && root.mountedCount > 0
              text: "Unmount all"; bordered: true; fontSize: Style.font.caption
              onClicked: root.mountAll(false)
            }
            Button {
              visible: !root.form
              text: "Refresh"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Re-check status (r)"
              onClicked: root.refresh()
            }
            Button {
              text: "Close"; bordered: true; fontSize: Style.font.caption
              onClicked: root.form ? (root.form = null) : root.dismiss()
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // Missing tools
          Rectangle {
            Layout.fillWidth: true
            visible: root.depWarnings.length > 0
            implicitHeight: warnCol.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.10)
            border.width: 1
            border.color: Color.urgent
            Column {
              id: warnCol
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(2)
              Repeater {
                model: root.depWarnings
                delegate: Text {
                  required property string modelData
                  width: warnCol.width
                  text: "⚠ " + modelData
                  color: Color.foreground
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ── List ────────────────────────────────────────────────────────
          ListView {
            id: list
            visible: !root.form
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(6)
            model: root.connections

            delegate: Rectangle {
              id: row
              required property var modelData
              readonly property bool working: !!root.busy[modelData.id]
              width: list.width
              height: rowLayout.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Util.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: Util.alpha(Color.foreground, modelData.mounted ? 0.35 : 0.12)

              RowLayout {
                id: rowLayout
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(10)

                Rectangle {
                  Layout.alignment: Qt.AlignVCenter
                  width: 10; height: 10; radius: 5
                  color: row.modelData.mounted ? Color.accent : "transparent"
                  border.width: 1
                  border.color: row.modelData.mounted ? Color.accent : Color.muted
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    Layout.fillWidth: true
                    text: row.modelData.name
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    text: row.modelData.uri + "  ·  " + row.modelData.backend
                          + (row.modelData.autostart ? "  ·  at login" : "")
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                Button {
                  visible: row.modelData.mounted && !!row.modelData.mountpoint
                  text: "Open"; bordered: true; fontSize: Style.font.caption
                  onClicked: root.openFolder(row.modelData)
                }
                Button {
                  text: row.working ? "…" : (row.modelData.mounted ? "Unmount" : "Mount")
                  bordered: true; fontSize: Style.font.caption
                  active: row.modelData.mounted
                  enabled: !row.working
                  onClicked: root.mountOrUnmount(row.modelData)
                }
                Button {
                  text: "At login"; bordered: true; fontSize: Style.font.caption
                  active: !!row.modelData.autostart
                  enabled: !root.saving
                  tooltipText: "Mount automatically when you log in"
                  onClicked: root.toggleAutostart(row.modelData)
                }
                Button {
                  text: "Edit"; bordered: true; fontSize: Style.font.caption
                  onClicked: root.editForm(row.modelData)
                }
                Button {
                  text: root.confirmDeleteId === row.modelData.id ? "Sure?" : "Delete"
                  bordered: true; fontSize: Style.font.caption
                  active: root.confirmDeleteId === row.modelData.id
                  enabled: !root.saving
                  onClicked: {
                    if (root.confirmDeleteId === row.modelData.id) root.deleteConnection(row.modelData);
                    else root.confirmDeleteId = row.modelData.id;
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(10)
              visible: root.loaded && root.connections.length === 0
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No connections yet."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "New connection"; bordered: true; active: true
                onClicked: root.newForm()
              }
            }
          }

          // ── Form ────────────────────────────────────────────────────────
          Flickable {
            visible: !!root.form
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: formCol.implicitHeight

            ColumnLayout {
              id: formCol
              width: parent.width
              spacing: Style.space(8)

              Text { text: "Name"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: "NAS"
                text: root.form ? root.form.name : ""
                onTextEdited: root.setForm("name", text)
                KeyNavigation.tab: hostField
              }

              Text { text: "Protocol"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              RowLayout {
                spacing: Style.space(6)
                Repeater {
                  model: [{ id: "smb", label: "SMB" }, { id: "sftp", label: "SFTP / SSH" }, { id: "nfs", label: "NFS" }]
                  delegate: Button {
                    required property var modelData
                    text: modelData.label; bordered: true; fontSize: Style.font.caption
                    active: root.form && root.form.protocol === modelData.id
                    onClicked: root.setForm("protocol", modelData.id)
                  }
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)
                  Text { text: "Host"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  TextField {
                    id: hostField
                    Layout.fillWidth: true
                    placeholderText: "nas.local"
                    text: root.form ? root.form.host : ""
                    onTextEdited: root.setForm("host", text)
                    KeyNavigation.tab: portField
                  }
                }
                ColumnLayout {
                  Layout.preferredWidth: Style.space(90)
                  spacing: Style.space(4)
                  Text { text: "Port"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  TextField {
                    id: portField
                    Layout.fillWidth: true
                    placeholderText: "default"
                    inputMethodHints: Qt.ImhDigitsOnly
                    text: root.form ? root.form.port : ""
                    onTextEdited: root.setForm("port", text)
                    KeyNavigation.tab: userField
                  }
                }
              }

              Text { text: "User"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                id: userField
                Layout.fillWidth: true
                placeholderText: "optional"
                text: root.form ? root.form.user : ""
                onTextEdited: root.setForm("user", text)
                KeyNavigation.tab: pathField
              }

              Text {
                text: root.form && root.form.protocol === "smb" ? "Share (and optional subfolder)" : "Remote path"
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              TextField {
                id: pathField
                Layout.fillWidth: true
                placeholderText: root.form && root.form.protocol === "smb" ? "media" : "/home/you"
                text: root.form ? root.form.path : ""
                onTextEdited: root.setForm("path", text)
                KeyNavigation.tab: passwordField
              }

              Text {
                text: root.form && root.form.hasPassword ? "Password (stored — leave blank to keep)" : "Password"
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              TextField {
                id: passwordField
                Layout.fillWidth: true
                password: true
                placeholderText: root.form && root.form.protocol === "sftp" ? "optional — SSH keys need none" : "kept in your keyring"
                text: root.form ? root.form.password : ""
                onTextEdited: root.setForm("password", text)
                onAccepted: root.saveForm()
              }
              Text {
                Layout.fillWidth: true
                visible: root.form && root.form.protocol === "smb"
                wrapMode: Text.WordWrap
                text: "SMB shares need a saved password to mount from here."
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              Button {
                visible: root.form && root.form.hasPassword
                text: root.form && root.form.clearPassword ? "Password will be removed" : "Remove stored password"
                bordered: true; fontSize: Style.font.caption
                active: root.form && root.form.clearPassword
                onClicked: root.setForm("clearPassword", !root.form.clearPassword)
              }

              Text { text: "Mount with"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              RowLayout {
                spacing: Style.space(6)
                Button {
                  text: "gio (Nautilus-style)"; bordered: true; fontSize: Style.font.caption
                  active: root.form && root.form.backend === "gio"
                  onClicked: root.setForm("backend", "gio")
                }
                Button {
                  text: "sshfs"; bordered: true; fontSize: Style.font.caption
                  enabled: root.form && root.form.protocol === "sftp"
                  tooltipText: root.depsLoaded && !root.deps.sshfs
                    ? "sshfs is not installed — run setup.sh --install"
                    : "FUSE mount under ~/Mounts — SFTP only"
                  active: root.form && root.form.backend === "sshfs"
                  onClicked: root.setForm("backend", "sshfs")
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Mount at login"
                description: "Adds a systemd user service that mounts this at login"
                checked: root.form ? root.form.autostart : false
                onClicked: root.setForm("autostart", !root.form.autostart)
              }

              Text {
                Layout.fillWidth: true
                visible: root.formError !== ""
                text: root.formError
                color: Color.urgent
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              RowLayout {
                spacing: Style.space(8)
                Button {
                  text: root.saving ? "Saving…" : "Save"
                  bordered: true; active: true
                  enabled: !root.saving && root.formError === ""
                  onClicked: root.saveForm()
                }
                Button {
                  text: "Cancel"; bordered: true
                  onClicked: root.form = null
                }
              }
            }
          }

          // ── Footer ──────────────────────────────────────────────────────
          Text {
            Layout.fillWidth: true
            visible: !root.form
            text: "n new  ·  r refresh  ·  esc close  ·  " + root.mountedCount + " of " + root.connections.length + " mounted"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Toast
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(30)
          visible: root.toastText !== ""
          width: Math.min(parent.width - Style.space(40), toastLabel.implicitWidth + Style.space(24))
          height: toastLabel.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: Color.background
          border.width: 1
          border.color: root.toastError ? Color.urgent : Color.accent
          Text {
            id: toastLabel
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            text: root.toastText
            color: root.toastError ? Color.urgent : Color.foreground
            wrapMode: Text.WordWrap
            maximumLineCount: 4
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}

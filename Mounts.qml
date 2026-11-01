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
  property var lastError: ({})     // id -> message from the last failed mount/unmount
  property bool saving: false
  property bool testing: false
  property var testResult: null    // {ok, message, fix} from the last Test, cleared on edit
  property bool loaded: false
  property string toastText: ""
  property bool toastError: false
  property string confirmDeleteId: ""
  // An armed Delete disarms itself after a few seconds.
  Timer { interval: 4000; running: root.confirmDeleteId !== ""; onTriggered: root.confirmDeleteId = "" }
  property var form: null          // null = list view; object = add/edit form
  property string formBase: ""     // the form as it was opened, to spot unsaved changes
  readonly property bool formDirty: !!root.form && JSON.stringify(root.form) !== root.formBase
  // NFS has no login, and neither does SMB guest access.
  readonly property bool formNoLogin: !!root.form && (root.form.protocol === "nfs" || (root.form.protocol === "smb" && !!root.form.guest))
  property bool discardArmed: false
  Timer { interval: 4000; running: root.discardArmed; onTriggered: root.discardArmed = false }
  property int testSeq: 0          // a Test reply only counts if the form hasn't changed since
  property int refreshSeq: 0       // only the newest list reply counts
  property string connectionsJson: ""
  property string listError: ""    // mountsctl can't read the saved connections
  property string forceId: ""      // connection whose unmount failed because it's in use
  onFormChanged: {
    root.testSeq++;
    if (!root.form && root.opened) Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
  }
  property bool showLog: false     // true = log view
  property string logText: ""
  property string logPath: ""
  property string logQuery: ""     // search text
  property string listQuery: ""    // main-list search: every word must match some field
  readonly property var shownConnections: root.filterConnections(root.connections, root.listQuery)
  property bool logRegex: false    // treat logQuery as a regular expression
  property bool logCase: false     // case-sensitive search

  // Log split into entries (an entry starts with a "YYYY-MM-DD HH:MM:SS" line),
  // filtered by the search and rendered as HTML with matches highlighted.
  readonly property var logResult: root.searchLog(root.logText, root.logQuery, root.logRegex, root.logCase)

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function searchLog(text, query, isRegex, matchCase) {
    var lines = String(text || "").split("\n"), entries = [], cur = null;
    for (var i = 0; i < lines.length; i++) {
      if (cur === null || /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(lines[i])) { cur = []; entries.push(cur); }
      cur.push(lines[i]);
    }
    entries = entries.map(function (e) { return e.join("\n"); }).filter(function (e) { return e.trim() !== ""; });

    var re = null, error = "";
    if (query !== "") {
      try {
        re = new RegExp(isRegex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), matchCase ? "g" : "gi");
        if (re.test("")) { re = null; error = "pattern matches empty text"; }
      } catch (e) { error = "invalid regex: " + e.message; }
    }
    var shown = re ? entries.filter(function (e) { re.lastIndex = 0; return re.test(e); }) : (error ? [] : entries);

    var hl = Color.accent;
    var html = shown.map(function (e) {
      var out = "", last = 0, m;
      if (re) {
        re.lastIndex = 0;
        while ((m = re.exec(e)) !== null) {
          out += root.escapeHtml(e.slice(last, m.index))
               + "<span style=\"background-color:" + hl + "; color:" + Color.background + ";\">"
               + root.escapeHtml(m[0]) + "</span>";
          last = m.index + m[0].length;
        }
      }
      out += root.escapeHtml(e.slice(last));
      // Make each entry's header line stand out (ERROR in the urgent colour).
      out = out.replace(/^(\S+ \S+)(\s+)(ERROR|INFO)/, function (_, ts, sp, lvl) {
        return "<span style=\"color:" + Color.muted + ";\">" + ts + "</span>" + sp
             + "<b style=\"color:" + (lvl === "ERROR" ? Color.urgent : Color.accent) + ";\">" + lvl + "</b>";
      });
      return out;
    }).join("<br><br>");
    return { html: "<div style=\"white-space: pre-wrap;\">" + html + "</div>",
             shown: shown.length, total: entries.length, error: error };
  }
  function filterConnections(list, query) {
    var words = query.toLowerCase().split(/\s+/).filter(function (w) { return w !== ""; });
    if (words.length === 0) return list;
    return list.filter(function (c) {
      var hay = [c.name, c.id, c.host, c.user, c.port ? String(c.port) : "", c.path, c.protocol, c.backend,
                 c.uri, c.location, c.mountpoint, root.stateOf(c).text, c.autostart ? "at login autostart" : ""]
                .join("\n").toLowerCase();
      return words.every(function (w) { return hay.indexOf(w) >= 0; });
    });
  }
  readonly property real btnFullW: measureFull.implicitWidth
  readonly property real btnIconW: measureIcons.implicitWidth
  readonly property bool listView: !root.form && !root.showLog
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

  readonly property var banners: (root.listError !== "" ? [root.listError] : []).concat(root.depWarnings)

  // First problem with the form, or "" when it can be saved. Mirrors the checks
  // in mountsctl so the person sees the reason before pressing Save.
  function formProblem(f) {
    if (!f) return "";
    var host = String(f.host || "").trim();
    var path = String(f.path || "").trim();
    if (!String(f.name || "").trim()) return "Give it a name.";
    if (!host) return "Enter a host.";
    if (host.charAt(0) === "-" || /[\s\/@?#%\[\]\\,;"'<>=&|`$()]/.test(host)) return "Host can't contain spaces, / or @ or other URL characters (put the user in User, and write IPv6 without brackets).";
    if (host.indexOf(":") !== -1 && !/^[0-9a-fA-F:.]+$/.test(host)) return "Put the port in Port; a : in Host is only for IPv6 addresses.";
    if (/[\s\/@]/.test(String(f.user || "")) || String(f.user || "").charAt(0) === "-") return "User can't contain spaces, / or @.";
    if (f.port !== "" && !(/^\d+$/.test(f.port) && Number(f.port) >= 1 && Number(f.port) <= 65535)) return "Port must be a number from 1 to 65535.";
    if (f.protocol === "smb" && path.replace(/^\/+|\/+$/g, "") === "") return "SMB needs a share name.";
    if (path.split("/").indexOf("..") !== -1) return "Path can't contain '..'.";
    if (f.protocol === "sftp" && f.backend === "gio" && path !== "" && path.charAt(0) !== "/") return "With gio, the path must start with / (sshfs also takes a path relative to your home).";
    if (/[\/@\\:]/.test(String(f.domain || ""))) return "Domain can't contain / \\ @ or :.";
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
      // Request body (may hold a password): written to stdin, never put in argv,
      // where any local user could read it with `ps`. Closing stdin sends EOF.
      property var input: undefined
      stdinEnabled: input !== undefined
      // Exactly one answer per call, even if the helper never started and so never
      // produced any output for the collector below.
      property bool answered: false
      property int idleTicks: 0
      function finish(r) {
        if (p.answered) return;
        p.answered = true;
        p.watchdog.stop();
        if (p.done) p.done(r);
        p.destroy();
      }
      property Timer watchdog: Timer {
        interval: 300; repeat: true
        onTriggered: {
          if (p.running) { p.idleTicks = 0; return; }
          // Two ticks, so output still on its way after the exit gets to arrive first.
          if (++p.idleTicks >= 2) p.finish({ error: "mountsctl couldn't run — build it with ./build.sh in the plugin folder" });
        }
      }
      onStarted: {
        if (p.input === undefined) return;
        p.write(p.input);
        p.input = undefined;
        p.stdinEnabled = false;
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var r;
          try { r = JSON.parse(String(text || "{}")); } catch (e) {
            r = { error: String(text || "").trim() === ""
                  ? "mountsctl didn't answer — build it with ./build.sh in the plugin folder"
                  : "unreadable reply from mountsctl" };
          }
          p.finish(r);
        }
      }
    }
  }
  function ctlRun(args, stdinJson, done) {
    var p = procFactory.createObject(root, { command: [root.ctl].concat(args), done: done, input: stdinJson });
    p.running = true;
    p.watchdog.start();
  }

  function refresh() {
    var seq = ++root.refreshSeq;
    ctlRun(["list"], undefined, function (r) {
      if (seq !== root.refreshSeq) return;
      root.listError = r.error ? String(r.error) : "";
      if (r.error) return;
      var list = (r.connections || []).slice();
      list.sort(function (a, b) {
        if (a.mounted !== b.mounted) return a.mounted ? -1 : 1;
        return String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1;
      });
      // Replacing the model rebuilds every row, so only do it when something changed.
      var json = JSON.stringify(list);
      if (json !== root.connectionsJson) { root.connectionsJson = json; root.connections = list; }
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
  // Hosts run side by side, but each host gets one login at a time: a burst of logins
  // is what gets a computer blocked (OpenSSH PerSourcePenalties, fail2ban).
  function mountAll(on) {
    var todo = root.connections.filter(function (c) { return !!c.mounted !== on && !root.busy[c.id]; });
    if (todo.length === 0) return;
    var hosts = {}, left = todo.length, failed = [];
    todo.forEach(function (c) {
      var h = String(c.host).toLowerCase();
      (hosts[h] = hosts[h] || []).push(c);
      root.setBusy(c.id, true);
    });
    function next(queue) {
      var c = queue.shift();
      if (!c) return;
      root.mountOrUnmount(c, function (ok) {
        if (!ok) failed.push(c.name);
        if (--left === 0) {
          var done = (todo.length - failed.length) + (on ? " mounted" : " unmounted");
          root.toast(failed.length ? done + ", failed: " + failed.join(", ") + " — click Log for how to fix" : done, failed.length > 0);
        }
        next(queue);
      });
    }
    Object.keys(hosts).forEach(function (h) { next(hosts[h]); });
  }

  function setBusy(id, on) {
    var b = Object.assign({}, root.busy);
    if (on) b[id] = true; else delete b[id];
    root.busy = b;
  }

  function setLastError(id, msg) {
    var e = Object.assign({}, root.lastError);
    if (msg) e[id] = msg; else delete e[id];
    root.lastError = e;
  }

  // One-line state for a row: what is happening with this connection right now.
  function stateOf(c) {
    if (root.busy[c.id]) return { text: c.mounted ? "Unmounting…" : "Mounting…", color: Color.foreground };
    if (c.stale) return { text: "⚠ Disconnected — the server stopped answering. Use Remount.", color: Color.urgent };
    if (c.mounted) return { text: "● Mounted", color: Color.accent };
    var err = root.lastError[c.id] || c.last_error;
    if (err) return { text: "✕ Failed: " + err + "  — see Log", color: Color.urgent };
    return { text: "○ Not mounted", color: Color.muted };
  }

  // `finished(ok)` replaces the toast, for callers that report on their own.
  function mountOrUnmount(c, finished) {
    var verb = c.stale ? "remount" : (c.mounted ? "unmount" : "mount");
    root.setBusy(c.id, true);
    ctlRun([verb, c.id], undefined, function (r) {
      root.setBusy(c.id, false);
      root.setLastError(c.id, r.error ? String(r.error) : "");
      if (root.forceId === c.id) root.forceId = "";
      if (r.error && verb === "unmount" && String(r.error).indexOf(" is in use") >= 0) root.forceId = c.id;
      if (finished) finished(!r.error);
      else if (r.error) root.toast(c.name + ": " + r.error + " — click Log for how to fix", true);
      else root.toast(c.name + (verb === "unmount" ? " unmounted" : " mounted"), false);
      root.refresh();
    });
  }
  function forceUnmount(c) {
    root.forceId = "";
    root.setBusy(c.id, true);
    ctlRun(["unmount", c.id, "--force"], undefined, function (r) {
      root.setBusy(c.id, false);
      root.setLastError(c.id, r.error ? String(r.error) : "");
      if (r.error) root.toast(c.name + ": " + r.error, true); else root.toast(c.name + " force unmounted", false);
      root.refresh();
    });
  }

  // Show the log inside the window (newest at the bottom).
  function openLog() {
    root.logClearArmed = false;
    root.form = null;
    root.showLog = true;
    reloadLog();
    Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
  }
  function reloadLog() {
    ctlRun(["log"], undefined, function (r) {
      if (r.error) { root.toast(r.error, true); return; }
      root.logText = String(r.text || "");
      root.logPath = String(r.path || "");
      Qt.callLater(function () { logFlick.toBottom(); });
    });
  }
  property bool logClearArmed: false
  Timer { interval: 4000; running: root.logClearArmed; onTriggered: root.logClearArmed = false }
  function clearLog() {
    if (!root.logClearArmed) { root.logClearArmed = true; return; }
    root.logClearArmed = false;
    ctlRun(["log", "clear"], undefined, function (r) {
      if (r.error) { root.toast(r.error, true); return; }
      root.toast("Log cleared — the old one is kept as mounts.log.old", false);
      root.reloadLog();
    });
  }
  // Full file in a pager (xdg-open would pick nvim, which has no terminal to run in here).
  function openLogInTerminal() {
    if (root.logPath) Quickshell.execDetached(["omarchy-launch-terminal", "-e", "less", "+G", root.logPath]);
  }

  function openFolder(c) {
    Quickshell.execDetached(["xdg-open", c.mountpoint || c.location || c.uri]);
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
      if (r.error) root.toast(r.error, true);
      else { root.setLastError(c.id, ""); root.toast(c.name + " deleted", false); }
      root.refresh();
    });
  }

  function newForm() {
    root.testResult = null;
    root.form = { id: "", name: "", protocol: "smb", host: "", user: "", port: "", path: "",
                  domain: "", guest: false, backend: "gio", autostart: false, password: "",
                  clearPassword: false, hasPassword: false };
    root.formBase = JSON.stringify(root.form);
    Qt.callLater(function () { nameField.forceActiveFocus(); });
  }
  function editForm(c) {
    root.testResult = null;
    root.form = { id: c.id, name: c.name, protocol: c.protocol, host: c.host, user: c.user || "",
                  port: c.port ? String(c.port) : "", path: c.path || "", domain: c.domain || "",
                  guest: !!c.guest, backend: c.backend, autostart: !!c.autostart, password: "",
                  clearPassword: false, hasPassword: !!c.has_password };
    root.formBase = JSON.stringify(root.form);
    Qt.callLater(function () { nameField.forceActiveFocus(); });
  }
  // Same settings as `c`, as a new connection. The stored password is copied by
  // mountsctl (copyPasswordFrom) so it never passes through the UI.
  function duplicateForm(c) {
    root.editForm(c);
    var names = root.connections.map(function (x) { return x.name.toLowerCase(); });
    var name = c.name + " copy", n = 2;
    while (names.indexOf(name.toLowerCase()) >= 0) name = c.name + " copy " + n++;
    var f = Object.assign({}, root.form);
    f.id = ""; f.name = name; f.autostart = false; f.copyFrom = c.has_password ? c.id : ""; f.copyFromName = c.name;
    root.form = f;
    root.formBase = JSON.stringify(f);
    Qt.callLater(function () { nameField.selectAll(); });
  }
  function setForm(key, value) {
    var f = Object.assign({}, root.form);
    f[key] = value;
    root.testResult = null;
    root.discardArmed = false;
    if (key === "protocol" && value !== "sftp" && f.backend === "sshfs") f.backend = "gio";
    root.form = f;
  }
  // Leave the form; with unsaved changes, only on the second try.
  function leaveForm() {
    if (root.formDirty && !root.discardArmed) {
      root.discardArmed = true;
      root.toast("Unsaved changes — press again to discard them", true);
      return;
    }
    root.discardArmed = false;
    root.form = null;
  }

  // Body shared by Save and Test (Test stores nothing).
  function formBody(f) {
    var port = parseInt(f.port, 10);
    var noLogin = f.protocol === "nfs" || (f.protocol === "smb" && f.guest);
    var body = { id: f.id, name: f.name, protocol: f.protocol, host: f.host, user: noLogin ? "" : f.user,
                 path: f.path, backend: f.backend, autostart: f.autostart };
    if (isFinite(port) && port > 0) body.port = port;
    if (f.protocol === "smb" && f.guest) body.guest = true;
    else if (f.protocol === "smb" && f.domain) body.domain = f.domain;
    if (noLogin) {
      if (f.hasPassword) body.clearPassword = true;
      return body;
    }
    if (f.password) body.password = f.password;
    if (f.clearPassword) body.clearPassword = true;
    else if (!f.password && f.copyFrom) body.copyPasswordFrom = f.copyFrom;
    return body;
  }
  function testForm() {
    var f = root.form;
    if (!f || root.testing) return;
    if (root.formError !== "") { root.toast(root.formError, true); return; }
    root.testing = true;
    root.testResult = null;
    var seq = root.testSeq;
    ctlRun(["test"], JSON.stringify(root.formBody(f)), function (r) {
      root.testing = false;
      if (!root.form || seq !== root.testSeq) return;
      root.testResult = r.error ? { ok: false, message: r.error, fix: "" }
                                : { ok: !!r.ok, message: r.message || "", fix: r.fix || "" };
    });
  }

  function saveForm() {
    var f = root.form;
    if (!f || root.saving) return;
    if (root.formError !== "") { root.toast(root.formError, true); return; }
    root.saving = true;
    ctlRun(["save"], JSON.stringify(root.formBody(f)), function (r) {
      root.saving = false;
      if (r.error) { root.toast(r.error, true); return; }
      // Autostart is a separate flag handled by `save` only through the body,
      // but the unit needs syncing; mountsctl does that on every save.
      root.form = null;
      if (r.connection) root.setLastError(r.connection.id, "");
      root.toast("Saved " + (r.connection ? r.connection.name : ""), false);
      root.refresh();
    });
  }

  // ── Lifecycle verbs (overlay contract) ──────────────────────────────────
  function open(payloadJson) {
    closeTimer.stop();
    root.closing = false;
    root.opened = true;
    // Coming back to a half-filled form picks up where it was left.
    if (!root.formDirty) root.form = null;
    root.showLog = false;
    root.confirmDeleteId = "";
    refresh();
    refreshDeps();
    if (!root.form) Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
    // Optional payload: {"view":"log","search":"...","regex":true} opens straight into the log.
    var p = {};
    try { p = JSON.parse(payloadJson || "{}") || {}; } catch (e) {}
    // {"search":"..."} pre-fills the list search.
    if (p.view !== "log" && typeof p.search === "string") root.listQuery = p.search;
    if (p.view === "log") {
      if (typeof p.search === "string") root.logQuery = p.search;
      if (p.regex !== undefined) root.logRegex = !!p.regex;
      root.openLog();
    } else if (p.view === "new") {
      root.newForm();
    } else if (typeof p.edit === "string" || typeof p.duplicate === "string") {
      // {"edit":"<id>"} / {"duplicate":"<id>"} open that form ({"test":true} also runs Test).
      var want = p.edit || p.duplicate;
      ctlRun(["list"], undefined, function (r) {
        root.connections = r.connections || root.connections;
        var c = (r.connections || []).filter(function (x) { return x.id === want; })[0];
        if (!c) { root.toast("No connection '" + want + "'", true); return; }
        if (p.duplicate) root.duplicateForm(c); else root.editForm(c);
        if (p.test) root.testForm();
      });
    }
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
    running: root.opened && root.listView
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
          if (root.form) root.leaveForm(); else if (root.showLog) root.showLog = false; else root.dismiss();
          event.accepted = true;
        } else if (root.listView && event.text === "n") {
          root.newForm(); event.accepted = true;
        } else if (root.listView && event.text === "l") {
          root.openLog(); event.accepted = true;
        } else if (!root.form && (event.text === "/" || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)))) {
          var field = root.showLog ? logSearch : listSearch;
          field.forceActiveFocus(); field.selectAll(); event.accepted = true;
        } else if (!root.form && event.text === "r") {
          if (root.showLog) root.reloadLog(); else root.refresh();
          event.accepted = true;
        } else if (!root.form && event.text === "q") {
          root.dismiss(); event.accepted = true;
        }
      }

      Rectangle {
        id: card
        anchors.fill: parent
        color: Color.background

        // Hidden: widths of a row's buttons with labels and icon-only (picks each row's layout).
        Row {
          id: measureFull
          visible: false
          spacing: Style.space(6)
          Repeater {
            model: ["Open", "Unmount", "At login", "Edit", "Duplicate", "Delete"]
            delegate: Button { required property string modelData; iconText: "󰏫"; iconSize: Style.font.body + 3; text: modelData; bordered: true; fontSize: Style.font.caption }
          }
        }
        Row {
          id: measureIcons
          visible: false
          spacing: Style.space(6)
          Repeater {
            model: 6
            delegate: Button { iconText: "󰏫"; iconSize: Style.font.body + 3; bordered: true; fontSize: Style.font.caption }
          }
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(14)
          spacing: Style.space(10)

          // ── Header ──────────────────────────────────────────────────────
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              text: root.form ? (root.form.id ? "Edit connection" : (root.form.copyFromName ? "Duplicate of " + root.form.copyFromName : "New connection")) : (root.showLog ? "Mounts log" : "Mounts")
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { Layout.fillWidth: true; implicitHeight: 1 }
            Button {
              visible: root.listView
              iconText: "󰐕"; iconSize: Style.font.body + 3
              text: "New"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Add a connection (n)"
              onClicked: root.newForm()
            }
            Button {
              visible: root.listView && root.connections.length > root.mountedCount
              iconText: "󰌘"; iconSize: Style.font.body + 3
              text: "Mount all"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Mount every saved connection"
              onClicked: root.mountAll(true)
            }
            Button {
              visible: root.listView && root.mountedCount > 0
              iconText: "󰌙"; iconSize: Style.font.body + 3
              text: "Unmount all"; bordered: true; fontSize: Style.font.caption
              onClicked: root.mountAll(false)
            }
            Button {
              visible: root.listView
              iconText: "󰈙"; iconSize: Style.font.body + 3
              text: "Log"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Show the log: what went wrong and how to fix it (l)"
              onClicked: root.openLog()
            }
            Button {
              visible: root.listView
              iconText: "󰑐"; iconSize: Style.font.body + 3
              text: "Refresh"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Re-check status (r)"
              onClicked: root.refresh()
            }
            Button {
              visible: root.showLog
              iconText: "󰑐"; iconSize: Style.font.body + 3
              text: "Reload"; bordered: true; fontSize: Style.font.caption
              tooltipText: "Read the log again (r)"
              onClicked: root.reloadLog()
            }
            Button {
              // Red outline; first click arms ("Sure?", solid red), second click clears.
              visible: root.showLog
              iconText: "󰗩"; iconSize: Style.font.body + 3
              text: root.logClearArmed ? "Sure?" : "Clear"
              bordered: true; fontSize: Style.font.caption
              tooltipText: root.logClearArmed ? "Click again to clear the log (the old one is kept as mounts.log.old)" : "Clear the log"
              foreground: root.logClearArmed ? Color.background : Color.urgent
              accent: Color.urgent
              borderSpec: Border.flat(Color.urgent, Math.max(1, Style.normalBorderWidth))
              color: root.logClearArmed ? (hot ? Qt.lighter(Color.urgent, 1.15) : Color.urgent)
                                        : (hot ? Util.alpha(Color.urgent, 0.15) : "transparent")
              onClicked: root.clearLog()
            }
            Button {
              visible: root.showLog && root.logPath !== ""
              iconText: "󰆍"; iconSize: Style.font.body + 3
              text: "Open in terminal"; bordered: true; fontSize: Style.font.caption
              tooltipText: root.logPath
              onClicked: root.openLogInTerminal()
            }
            Button {
              iconText: root.listView ? "󰅖" : "󰁍"; iconSize: Style.font.body + 3
              text: root.listView ? "Close" : "Back"; bordered: true; fontSize: Style.font.caption
              // Close (list view) is red like the other "leave/destroy" buttons; Back stays neutral.
              foreground: root.listView ? Color.urgent : Color.foreground
              accent: root.listView ? Color.urgent : Color.accent
              borderSpec: root.listView ? Border.flat(Color.urgent, Math.max(1, Style.normalBorderWidth)) : _borderSpec
              color: hot ? (root.listView ? Util.alpha(Color.urgent, 0.15) : Style.hoverFillFor(Color.foreground, Color.accent)) : "transparent"
              onClicked: root.form ? root.leaveForm() : (root.showLog ? (root.showLog = false) : root.dismiss())
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // Missing tools
          Rectangle {
            Layout.fillWidth: true
            visible: root.banners.length > 0
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
                model: root.banners
                delegate: Text {
                  required property string modelData
                  width: warnCol.width
                  text: "⚠ " + modelData
                  textFormat: Text.PlainText
                  color: Color.foreground
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ── List ────────────────────────────────────────────────────────
          RowLayout {
            visible: root.listView && root.connections.length > 0
            Layout.fillWidth: true
            spacing: Style.space(6)
            TextField {
              id: listSearch
              Layout.fillWidth: true
              placeholderText: "Search name, host, user, path, state…  ( / )"
              text: root.listQuery
              onTextChanged: root.listQuery = text
              Keys.onEscapePressed: function (event) {
                if (text !== "") text = "";
                else keyCatcher.forceActiveFocus();
                event.accepted = true;
              }
              // Enter with a single match mounts / unmounts it.
              onAccepted: if (root.shownConnections.length === 1) root.mountOrUnmount(root.shownConnections[0])
            }
            Text {
              visible: root.listQuery.trim() !== ""
              text: root.shownConnections.length + " of " + root.connections.length
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ListView {
            id: list
            visible: root.listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(6)
            model: root.shownConnections

            delegate: Rectangle {
              id: row
              required property var modelData
              readonly property bool working: !!root.busy[modelData.id]
              width: list.width
              height: rowLayout.implicitHeight + Style.space(16)
              // Narrow window: buttons drop below the details and wrap; long lines wrap too.
              // full: icon + label beside the details; icons: icon-only beside them;
              // stacked: icon-only buttons on their own line (and long lines wrap).
              readonly property real avail: width - Style.space(16) - 20 - Style.space(20)
              readonly property string mode: avail - root.btnFullW >= Style.space(300) ? "full"
                : (avail - root.btnIconW >= Style.space(220) ? "icons" : "stacked")
              readonly property bool narrow: mode === "stacked"
              readonly property bool compact: mode !== "full"
              radius: Style.cornerRadius
              color: Util.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: Util.alpha(Color.foreground, modelData.mounted ? 0.35 : 0.12)

              GridLayout {
                id: rowLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                columns: row.narrow ? 2 : 3
                columnSpacing: Style.space(10)
                rowSpacing: Style.space(6)

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
                    textFormat: Text.PlainText
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: row.modelData.uri + "  ·  " + row.modelData.backend
                          + (row.modelData.autostart ? "  ·  at login" : "")
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: row.narrow ? Text.WrapAnywhere : Text.NoWrap
                    elide: row.narrow ? Text.ElideNone : Text.ElideMiddle
                  }
                  // Current state (mounted / mounting / failed with why / not mounted).
                  Text {
                    readonly property var st: root.stateOf(row.modelData)
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(3)
                    text: st.text
                    textFormat: Text.PlainText
                    color: st.color
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: !!row.modelData.mounted
                  }
                  // Where it is on this computer: a link while mounted, plain text otherwise.
                  Text {
                    readonly property string loc: row.modelData.location || ""
                    readonly property bool live: !!row.modelData.mounted
                    Layout.fillWidth: true
                    visible: loc !== ""
                    textFormat: Text.StyledText
                    text: live
                      ? "󰉋 <a href=\"open\">" + loc.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</a>"
                      : "󰉋 " + loc.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "  (available after mounting)"
                    color: Color.muted
                    linkColor: Color.accent
                    wrapMode: row.narrow ? Text.WrapAnywhere : Text.NoWrap
                    elide: row.narrow ? Text.ElideNone : Text.ElideMiddle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    onLinkActivated: root.openFolder(row.modelData)
                    HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
                  }
                }

                Flow {
                  id: btns
                  // Width of all buttons on one line (what the wide layout reserves).
                  readonly property real natural: {
                    var w = 0, n = 0;
                    for (var i = 0; i < children.length; i++) {
                      var ch = children[i];
                      if (ch.visible && ch.implicitWidth > 0) { w += ch.implicitWidth; n++; }
                    }
                    return w + Math.max(0, n - 1) * spacing;
                  }
                  Layout.columnSpan: row.narrow ? 2 : 1
                  Layout.fillWidth: row.narrow
                  Layout.leftMargin: row.narrow ? 20 : 0
                  Layout.preferredWidth: row.narrow ? -1 : natural
                  Layout.alignment: Qt.AlignVCenter
                  spacing: Style.space(6)

                Button {
                  visible: row.modelData.mounted && !!row.modelData.mountpoint
                  iconText: "󰝰"; iconSize: Style.font.body + 3
                  text: row.compact ? "" : "Open"
                  tooltipText: "Open the folder"
                  bordered: true; fontSize: Style.font.caption
                  onClicked: root.openFolder(row.modelData)
                }
                Button {
                  readonly property string label: row.working ? (row.modelData.stale ? "Remounting…" : (row.modelData.mounted ? "Unmounting…" : "Mounting…"))
                                                              : (row.modelData.stale ? "Remount" : (row.modelData.mounted ? "Unmount" : "Mount"))
                  iconText: row.working ? "󰔟" : (row.modelData.mounted ? "󰌙" : "󰌘")
                  iconSize: Style.font.body + 3
                  text: row.compact ? "" : label
                  tooltipText: label
                  bordered: true; fontSize: Style.font.caption
                  active: row.modelData.mounted
                  enabled: !row.working
                  onClicked: root.mountOrUnmount(row.modelData)
                }
                Button {
                  // Only after an unmount failed because something is using the folder.
                  visible: root.forceId === row.modelData.id && !row.working
                  iconText: "󰅙"; iconSize: Style.font.body + 3
                  text: row.compact ? "" : "Force unmount"
                  tooltipText: "Detach it anyway: programs using it will get errors, and unsaved work there can be lost"
                  bordered: true; fontSize: Style.font.caption
                  foreground: Color.urgent
                  accent: Color.urgent
                  borderSpec: Border.flat(Color.urgent, Math.max(1, Style.normalBorderWidth))
                  onClicked: root.forceUnmount(row.modelData)
                }
                Button {
                  iconText: "󰍂"; iconSize: Style.font.body + 3
                  text: row.compact ? "" : "At login"
                  bordered: true; fontSize: Style.font.caption
                  active: !!row.modelData.autostart
                  enabled: !root.saving
                  tooltipText: row.modelData.autostart ? "Mounts at login (click to stop)" : "Mount automatically when you log in"
                  onClicked: root.toggleAutostart(row.modelData)
                }
                Button {
                  iconText: "󰏫"; iconSize: Style.font.body + 3
                  text: row.compact ? "" : "Edit"
                  tooltipText: "Edit"
                  bordered: true; fontSize: Style.font.caption
                  onClicked: root.editForm(row.modelData)
                }
                Button {
                  iconText: "󰆏"; iconSize: Style.font.body + 3
                  text: row.compact ? "" : "Duplicate"
                  tooltipText: "Duplicate: new connection with these settings (and password)"
                  bordered: true; fontSize: Style.font.caption
                  onClicked: root.duplicateForm(row.modelData)
                }
                Button {
                  // Red outline; armed (first click) = solid red "Sure?", second click deletes.
                  readonly property bool armed: root.confirmDeleteId === row.modelData.id
                  iconText: "󰆴"; iconSize: Style.font.body + 3
                  text: armed ? "Sure?" : (row.compact ? "" : "Delete")
                  tooltipText: armed ? "Click again to delete " + row.modelData.name : "Delete"
                  bordered: true; fontSize: Style.font.caption
                  foreground: armed ? Color.background : Color.urgent
                  accent: Color.urgent
                  borderSpec: Border.flat(Color.urgent, Math.max(1, Style.normalBorderWidth))
                  color: armed ? (hot ? Qt.lighter(Color.urgent, 1.15) : Color.urgent)
                               : (hot ? Util.alpha(Color.urgent, 0.15) : "transparent")
                  enabled: !root.saving
                  onClicked: {
                    if (armed) root.deleteConnection(row.modelData);
                    else root.confirmDeleteId = row.modelData.id;
                  }
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
            Text {
              anchors.centerIn: parent
              visible: root.connections.length > 0 && root.shownConnections.length === 0
              textFormat: Text.PlainText
              text: "Nothing matches \u201c" + root.listQuery.trim() + "\u201d — Esc clears the search."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // ── Log ─────────────────────────────────────────────────────────
          RowLayout {
            visible: root.showLog
            Layout.fillWidth: true
            spacing: Style.space(6)
            TextField {
              id: logSearch
              Layout.fillWidth: true
              placeholderText: root.logRegex ? "Search the log (regex, e.g. MZ101.*(reset|denied))" : "Search the log  ( / )"
              text: root.logQuery
              onTextChanged: root.logQuery = text
              Keys.onEscapePressed: function (event) {
                if (text !== "") { text = ""; event.accepted = true; }
                else { keyCatcher.forceActiveFocus(); event.accepted = false; }
              }
            }
            Button {
              iconText: "󰑑"; iconSize: Style.font.body + 3
              text: "Regex"; bordered: true; fontSize: Style.font.caption
              active: root.logRegex
              tooltipText: "Treat the search as a regular expression"
              onClicked: root.logRegex = !root.logRegex
            }
            Button {
              iconText: "󰬴"; iconSize: Style.font.body + 3
              text: "Case"; bordered: true; fontSize: Style.font.caption
              active: root.logCase
              tooltipText: "Match case"
              onClicked: root.logCase = !root.logCase
            }
            Text {
              text: root.logResult.error !== "" ? root.logResult.error
                    : (root.logQuery !== "" ? root.logResult.shown + " of " + root.logResult.total + " entries"
                                            : root.logResult.total + " entries")
              color: root.logResult.error !== "" ? Color.urgent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            visible: root.showLog
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: Util.alpha(Color.foreground, 0.04)
            border.width: 1
            border.color: Util.alpha(Color.foreground, 0.12)

            Flickable {
              id: logFlick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              clip: true
              contentWidth: width
              contentHeight: logEdit.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              // Newest entries (and newest matches) are at the bottom: jump there whenever
              // the content changes (reload, new search) — after layout, not before.
              function toBottom() { contentY = Math.max(0, contentHeight - height); }
              onContentHeightChanged: toBottom()
              onHeightChanged: toBottom()

              TextEdit {
                id: logEdit
                width: logFlick.width
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                text: root.logResult.total === 0 ? "Nothing logged yet — failed mounts show up here with what to fix."
                      : (root.logResult.shown === 0 ? (root.logResult.error !== "" ? "Fix the search pattern above." : "No entries match the search.")
                                                    : root.logResult.html)
                color: Color.foreground
                selectionColor: Util.alpha(Color.accent, 0.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
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
                    KeyNavigation.tab: root.formNoLogin ? pathField : userField
                  }
                }
              }

              Toggle {
                Layout.fillWidth: true
                visible: !!root.form && root.form.protocol === "smb"
                label: "Guest access"
                description: "Connect with no user or password"
                checked: root.form ? !!root.form.guest : false
                onClicked: root.setForm("guest", !root.form.guest)
              }

              Text { visible: !root.formNoLogin; text: "User"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                id: userField
                visible: !root.formNoLogin
                Layout.fillWidth: true
                placeholderText: "optional"
                text: root.form ? root.form.user : ""
                onTextEdited: root.setForm("user", text)
                KeyNavigation.tab: domainField.visible ? domainField : pathField
              }

              Text { visible: domainField.visible; text: "Domain or workgroup"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                id: domainField
                visible: !!root.form && root.form.protocol === "smb" && !root.form.guest
                Layout.fillWidth: true
                placeholderText: "optional"
                text: root.form ? (root.form.domain || "") : ""
                onTextEdited: root.setForm("domain", text)
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
                KeyNavigation.tab: root.formNoLogin ? nameField : passwordField
              }

              Text {
                textFormat: Text.PlainText
                visible: !root.formNoLogin
                text: root.form && root.form.hasPassword ? (root.form.copyFrom ? "Password (copied from " + root.form.copyFromName + " — leave blank to keep)" : "Password (stored — leave blank to keep)") : "Password"
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              TextField {
                id: passwordField
                visible: !root.formNoLogin
                Layout.fillWidth: true
                password: true
                placeholderText: root.form && root.form.protocol === "sftp" ? "optional — SSH keys need none" : "kept in your keyring"
                text: root.form ? root.form.password : ""
                onTextEdited: root.setForm("password", text)
                onAccepted: root.saveForm()
              }
              Text {
                Layout.fillWidth: true
                visible: !!root.form && root.form.protocol === "smb" && !root.form.guest
                wrapMode: Text.WordWrap
                text: "SMB shares need a saved password to mount from here, or Guest access."
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
              }
              Button {
                visible: !!root.form && root.form.hasPassword && !root.formNoLogin
                text: root.form && root.form.copyFrom ? (root.form.clearPassword ? "Password won't be copied" : "Don't copy the password")
                  : (root.form && root.form.clearPassword ? "Password will be removed" : "Remove stored password")
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

              Text {
                Layout.fillWidth: true
                visible: !!root.form
                wrapMode: Text.WordWrap
                text: root.form && root.form.backend === "sshfs"
                  ? "Mounted at ~/Mounts/" + (root.form.id || "<name>") + " — a normal folder any program can use."
                  : "Mounted by GVfs under /run/user/<your id>/gvfs/ (hidden folder). Use Open, or find it in the Nautilus sidebar; some non-GTK programs can't see it — use sshfs for those."
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
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

              Text {
                Layout.fillWidth: true
                visible: root.testing || !!root.testResult
                textFormat: Text.PlainText
                text: root.testing ? "Testing… (mounting temporarily, then unmounting)"
                  : root.testResult ? (root.testResult.ok ? "✓ " : "✕ ") + root.testResult.message
                      + (root.testResult.fix ? "\nTo fix: " + root.testResult.fix : "") : ""
                color: root.testing ? Color.muted : (root.testResult && root.testResult.ok ? Color.accent : Color.urgent)
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              RowLayout {
                spacing: Style.space(8)
                Button {
                  text: root.testing ? "Testing…" : "Test"
                  bordered: true
                  tooltipText: "Try to connect with these settings without saving"
                  enabled: !root.testing && !root.saving && root.formError === ""
                  onClicked: root.testForm()
                }
                Button {
                  text: root.saving ? "Saving…" : "Save"
                  bordered: true; active: true
                  enabled: !root.saving && root.formError === ""
                  onClicked: root.saveForm()
                }
                Button {
                  text: "Cancel"; bordered: true
                  onClicked: root.leaveForm()
                }
              }
            }
          }

          // ── Footer ──────────────────────────────────────────────────────
          Text {
            Layout.fillWidth: true
            visible: !root.form
            text: root.showLog
              ? "/ search  ·  r reload  ·  esc back  ·  " + root.logPath
              : "/ search  ·  n new  ·  l log  ·  r refresh  ·  esc close  ·  " + root.mountedCount + " of " + root.connections.length + " mounted"
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
            textFormat: Text.PlainText
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

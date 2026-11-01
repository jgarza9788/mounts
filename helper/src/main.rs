//! mountsctl — backend for the jgarza.mounts Omarchy plugin.
//!
//! Saved network connections (SMB / SFTP / NFS) live in a TOML file; passwords
//! live in the Secret Service keyring (via `secret-tool`). Mounting goes through
//! either gio/GVfs (no root, visible in Nautilus) or sshfs (FUSE).
//!
//! Every command prints one JSON object on stdout: `{"ok":true,...}` or
//! `{"error":"..."}` (exit status 1).

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const SERVICE: &str = "jgarza.mounts";
const UNIT_NAME: &str = "jgarza-mounts-autostart.service";

// ── Model ────────────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
struct Connection {
    #[serde(default)]
    id: String,
    name: String,
    /// smb | sftp | nfs
    protocol: String,
    host: String,
    #[serde(default)]
    user: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    port: Option<u16>,
    /// SMB: share name (+ subpath). SFTP/NFS: remote path.
    #[serde(default)]
    path: String,
    /// gio | sshfs
    #[serde(default = "default_backend")]
    backend: String,
    #[serde(default)]
    autostart: bool,
    /// A password is stored in the keyring for this connection.
    #[serde(default)]
    has_password: bool,
}

fn default_backend() -> String {
    "gio".into()
}

#[derive(Serialize, Deserialize, Default)]
struct Config {
    #[serde(default, rename = "connection")]
    connections: Vec<Connection>,
}

type Res<T> = Result<T, String>;

// ── Paths ────────────────────────────────────────────────────────────────────

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

fn config_dir() -> PathBuf {
    match std::env::var("MOUNTSCTL_CONFIG_DIR") {
        Ok(d) if !d.is_empty() => PathBuf::from(d),
        _ => home().join(".config/omarchy/jgarza.mounts"),
    }
}

fn config_path() -> PathBuf {
    config_dir().join("connections.toml")
}

fn mount_root() -> PathBuf {
    match std::env::var("MOUNTSCTL_MOUNT_ROOT") {
        Ok(d) if !d.is_empty() => PathBuf::from(d),
        _ => home().join("Mounts"),
    }
}

fn mountpoint(c: &Connection) -> PathBuf {
    mount_root().join(&c.id)
}

fn load() -> Res<Config> {
    match fs::read_to_string(config_path()) {
        Ok(s) => toml::from_str(&s).map_err(|e| format!("bad connections.toml: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(format!("cannot read connections.toml: {e}")),
    }
}

fn store(cfg: &Config) -> Res<()> {
    let dir = config_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let body = toml::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    let tmp = dir.join("connections.toml.tmp");
    fs::write(&tmp, body).map_err(|e| e.to_string())?;
    fs::rename(&tmp, config_path()).map_err(|e| e.to_string())
}

// ── Validation & naming ──────────────────────────────────────────────────────

fn slug(name: &str) -> String {
    let mut out = String::new();
    for ch in name.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "mount".into()
    } else {
        out
    }
}

fn unique_id(base: &str, taken: &[String]) -> String {
    if !taken.iter().any(|t| t == base) {
        return base.to_string();
    }
    (2..)
        .map(|n| format!("{base}-{n}"))
        .find(|c| !taken.contains(c))
        .unwrap()
}

fn has_ctl(s: &str) -> bool {
    s.chars().any(|c| c.is_control())
}

/// Reject anything that could be read as an option or smuggle extra arguments.
fn validate(c: &Connection) -> Res<()> {
    if c.name.trim().is_empty() {
        return Err("name is required".into());
    }
    if !matches!(c.protocol.as_str(), "smb" | "sftp" | "nfs") {
        return Err("protocol must be smb, sftp or nfs".into());
    }
    if !matches!(c.backend.as_str(), "gio" | "sshfs") {
        return Err("backend must be gio or sshfs".into());
    }
    if c.backend == "sshfs" && c.protocol != "sftp" {
        return Err("the sshfs backend only works with sftp".into());
    }
    let host = c.host.trim();
    if host.is_empty() || host.starts_with('-') || host.chars().any(|ch| ch.is_whitespace() || ch == '/' || ch == '@') || has_ctl(host) {
        return Err("host is invalid".into());
    }
    if c.user.starts_with('-') || c.user.chars().any(|ch| ch.is_whitespace() || ch == '@' || ch == '/') || has_ctl(&c.user) {
        return Err("user is invalid".into());
    }
    if has_ctl(&c.path) || c.path.split('/').any(|seg| seg == "..") {
        return Err("path is invalid".into());
    }
    if c.protocol == "smb" && smb_share(c).is_empty() {
        return Err("smb needs a share name in path".into());
    }
    if c.port == Some(0) {
        return Err("port is invalid".into());
    }
    Ok(())
}

// ── URIs & backend command lines (pure, unit-tested) ─────────────────────────

fn pct(s: &str, keep_slash: bool) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        let ch = b as char;
        if ch.is_ascii_alphanumeric() || "-._~".contains(ch) || (keep_slash && ch == '/') {
            out.push(ch);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn smb_share(c: &Connection) -> &str {
    c.path.trim_matches('/').split('/').next().unwrap_or("")
}

fn uri(c: &Connection) -> String {
    let user = if c.user.is_empty() { String::new() } else { format!("{}@", pct(&c.user, false)) };
    let port = c.port.map(|p| format!(":{p}")).unwrap_or_default();
    let path = c.path.trim_matches('/');
    match c.protocol.as_str() {
        "smb" => format!("smb://{user}{}{port}/{}", c.host, pct(path, true)),
        "sftp" => format!("sftp://{user}{}{port}/{}", c.host, pct(path, true)),
        _ => format!("nfs://{}{port}/{}", c.host, pct(path, true)),
    }
}

fn sshfs_args(c: &Connection, mp: &str, use_password: bool) -> Vec<String> {
    let user = if c.user.is_empty() { String::new() } else { format!("{}@", c.user) };
    let mut opts = String::from("reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,ConnectTimeout=15");
    if use_password {
        opts.push_str(",password_stdin");
    } else {
        opts.push_str(",BatchMode=yes");
    }
    let mut args = vec![format!("{user}{}:{}", c.host, c.path), mp.to_string(), "-o".into(), opts];
    if let Some(p) = c.port {
        args.push("-p".into());
        args.push(p.to_string());
    }
    args
}

/// Does a `/run/user/UID/gvfs/` entry (e.g. `smb-share:server=nas,share=media`) belong to `c`?
fn gvfs_matches(c: &Connection, entry: &str) -> bool {
    let Some((kind, rest)) = entry.split_once(':') else { return false };
    let p: HashMap<&str, &str> = rest.split(',').filter_map(|kv| kv.split_once('=')).collect();
    let host_is = |k: &str| p.get(k).map_or(false, |v| v.eq_ignore_ascii_case(&c.host));
    match (c.protocol.as_str(), kind) {
        ("smb", "smb-share") => {
            host_is("server") && p.get("share").map_or(false, |s| s.eq_ignore_ascii_case(smb_share(c)))
        }
        ("sftp", "sftp") => {
            host_is("host")
                && (c.user.is_empty() || p.get("user").map_or(true, |u| *u == c.user))
                && c.port.map_or(true, |n| p.get("port").map_or(false, |v| *v == n.to_string()))
        }
        ("nfs", "nfs") => host_is("host") || host_is("server"),
        _ => false,
    }
}

// ── Process helpers ──────────────────────────────────────────────────────────

struct Out {
    ok: bool,
    text: String,
}

/// Run a command with optional stdin, killing it after `secs`.
fn run(prog: &str, args: &[String], stdin: Option<&str>, secs: u64) -> Out {
    let mut cmd = Command::new(prog);
    cmd.args(args)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Out { ok: false, text: format!("cannot run {prog}: {e}") },
    };
    if let (Some(data), Some(mut si)) = (stdin, child.stdin.take()) {
        let _ = si.write_all(data.as_bytes());
    }
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if start.elapsed() > Duration::from_secs(secs) => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(80)),
            Err(_) => break None,
        }
    };
    let mut text = String::new();
    if let Some(mut o) = child.stdout.take() {
        let _ = o.read_to_string(&mut text);
    }
    if let Some(mut e) = child.stderr.take() {
        let _ = e.read_to_string(&mut text);
    }
    match status {
        Some(s) => Out { ok: s.success(), text: text.trim().to_string() },
        None => Out { ok: false, text: format!("{prog} timed out after {secs}s") },
    }
}

fn sv(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| s.to_string()).collect()
}

// ── Keyring (secret-tool) ────────────────────────────────────────────────────

fn secret_store(c: &Connection, password: &str) -> Res<()> {
    let label = format!("Mounts: {}", c.name);
    let o = run(
        "secret-tool",
        &sv(&["store", "--label", &label, "service", SERVICE, "id", &c.id]),
        Some(password),
        30,
    );
    if o.ok { Ok(()) } else { Err(format!("keyring: {}", o.text)) }
}

fn secret_lookup(c: &Connection) -> Option<String> {
    if !c.has_password {
        return None;
    }
    let o = run("secret-tool", &sv(&["lookup", "service", SERVICE, "id", &c.id]), None, 30);
    (o.ok && !o.text.is_empty()).then_some(o.text)
}

fn secret_clear(c: &Connection) {
    let _ = run("secret-tool", &sv(&["clear", "service", SERVICE, "id", &c.id]), None, 30);
}

// ── Status ───────────────────────────────────────────────────────────────────

fn gvfs_dir() -> PathBuf {
    let uid = fs::metadata("/proc/self").map(|m| {
        use std::os::unix::fs::MetadataExt;
        m.uid()
    });
    PathBuf::from(format!("/run/user/{}/gvfs", uid.unwrap_or(1000)))
}

/// Where `c` is mounted right now, if it is.
fn mounted_at(c: &Connection) -> Option<String> {
    if c.backend == "sshfs" {
        let mp = mountpoint(c);
        let mounts = fs::read_to_string("/proc/self/mounts").unwrap_or_default();
        return mounts
            .lines()
            .filter_map(|l| {
                let mut f = l.split_whitespace();
                let (_, at, ty) = (f.next()?, f.next()?, f.next()?);
                Some((at.to_string(), ty.to_string()))
            })
            .any(|(at, ty)| at == mp.to_string_lossy() && ty.starts_with("fuse"))
            .then(|| mp.to_string_lossy().into_owned());
    }
    let dir = gvfs_dir();
    if let Ok(rd) = fs::read_dir(&dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if gvfs_matches(c, &name) {
                return Some(e.path().to_string_lossy().into_owned());
            }
        }
        return None;
    }
    // gvfsd-fuse not running: fall back to the mount list.
    let o = run("gio", &sv(&["mount", "-l"]), None, 15);
    let want = format!("{}://{}", c.protocol, c.host.to_lowercase());
    o.text
        .lines()
        .any(|l| l.to_lowercase().contains(&want))
        .then(|| String::new())
}

fn view(c: &Connection) -> Value {
    let at = mounted_at(c);
    let mut v = serde_json::to_value(c).unwrap_or(Value::Null);
    if let Value::Object(m) = &mut v {
        m.insert("uri".into(), json!(uri(c)));
        m.insert("mounted".into(), json!(at.is_some()));
        m.insert("mountpoint".into(), json!(at.unwrap_or_default()));
    }
    v
}

/// Turn raw gio / sshfs output into something a person can act on.
fn friendly(raw: &str) -> String {
    let t = raw.trim();
    let l = t.to_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| l.contains(n));
    let msg = if has(&["password required", "authentication", "permission denied", "invalid password", "logon failure", "access denied"]) {
        "authentication failed — check the user and password"
    } else if has(&["could not resolve", "name or service not known", "failed to resolve", "host not found", "no such host", "unable to locate"]) {
        "can't find that host — check the name or your network"
    } else if has(&["connection refused"]) {
        "connection refused — is the service running on that host and port?"
    } else if has(&["connection reset", "broken pipe", "connection closed", "closed by remote"]) {
        "the host closed the connection — check the address, port and that SSH/SFTP is enabled"
    } else if has(&["sshfs timed out after", "gio timed out after"]) {
        "connected, but the server never answered — if the host is up, its SSH/SFTP setup may be broken (login scripts like ~/.bashrc that print output break SFTP)"
    } else if has(&["timed out", "timeout", "no route to host", "network is unreachable"]) {
        "can't reach the host (timed out) — is it online?"
    } else if has(&["bad share name", "no such file", "not found", "does not exist"]) {
        "the share or path wasn't found on the host"
    } else if has(&["operation not supported", "volume doesn't implement mount", "not supported"]) {
        "this protocol isn't supported on this system (is the gvfs package installed?)"
    } else if has(&["fuse"]) && has(&["device", "permission"]) {
        "FUSE isn't usable (check that /dev/fuse exists and fuse3 is installed)"
    } else {
        return t.to_string();
    };
    if t.is_empty() { msg.to_string() } else { format!("{msg} ({})", t.lines().next().unwrap_or("")) }
}

// ── Mount / unmount ──────────────────────────────────────────────────────────

fn do_mount(c: &Connection) -> Res<()> {
    if mounted_at(c).is_some() {
        return Ok(());
    }
    let password = secret_lookup(c);
    if c.backend == "sshfs" {
        let mp = mountpoint(c);
        fs::create_dir_all(&mp).map_err(|e| format!("cannot create {}: {e}", mp.display()))?;
        let args = sshfs_args(c, &mp.to_string_lossy(), password.is_some());
        let stdin = password.as_ref().map(|p| format!("{p}\n"));
        let o = run("sshfs", &args, stdin.as_deref(), 60);
        if o.ok {
            return Ok(());
        }
        if o.text.starts_with("cannot run sshfs") {
            // Nothing was mounted; don't leave an empty mountpoint dir behind.
            let _ = fs::remove_dir(&mp);
            return Err("sshfs is not installed (sudo pacman -S sshfs, or run setup.sh --install)".into());
        }
        // A timed-out sshfs can leave a dead FUSE mount behind; detach it, then drop the empty folder.
        let mps = mp.to_string_lossy().into_owned();
        if run("fusermount3", &sv(&["-uz", &mps]), None, 10).ok == false {
            let _ = run("fusermount", &sv(&["-uz", &mps]), None, 10);
        }
        let _ = fs::remove_dir(&mp);
        return Err(friendly(&o.text));
    }
    // gio asks User, Domain, Password (in that order) when it needs them.
    let stdin = match (c.protocol.as_str(), &password) {
        ("smb", Some(p)) => Some(format!("{}\n\n{p}\n", c.user)),
        (_, Some(p)) => Some(format!("{p}\n")),
        _ => None,
    };
    let o = run("gio", &sv(&["mount", &uri(c)]), stdin.as_deref(), 60);
    if o.ok || o.text.contains("already mounted") { Ok(()) } else { Err(friendly(&o.text)) }
}

fn do_unmount(c: &Connection) -> Res<()> {
    if mounted_at(c).is_none() {
        return Ok(());
    }
    if c.backend == "sshfs" {
        let mp = mountpoint(c).to_string_lossy().into_owned();
        let mut o = run("fusermount3", &sv(&["-u", &mp]), None, 30);
        if !o.ok {
            o = run("fusermount", &sv(&["-u", &mp]), None, 30);
        }
        return if o.ok { Ok(()) } else { Err(o.text) };
    }
    let o = run("gio", &sv(&["mount", "-u", &uri(c)]), None, 30);
    if o.ok { Ok(()) } else { Err(o.text) }
}

// ── Autostart (systemd --user) ───────────────────────────────────────────────

fn systemd_enabled() -> bool {
    std::env::var("MOUNTSCTL_NO_SYSTEMD").is_err()
}

fn unit_text(exe: &str) -> String {
    format!(
        "[Unit]\nDescription=Mount saved network shares (jgarza.mounts)\nAfter=network-online.target graphical-session.target\nWants=network-online.target\n\n\
         [Service]\nType=oneshot\nExecStart={exe} autostart-run\n\n[Install]\nWantedBy=default.target\n"
    )
}

fn sync_unit(cfg: &Config) -> Res<()> {
    if !systemd_enabled() {
        return Ok(());
    }
    let unit = home().join(".config/systemd/user").join(UNIT_NAME);
    if cfg.connections.iter().any(|c| c.autostart) {
        let exe = std::env::current_exe()
            .and_then(|p| p.canonicalize())
            .map_err(|e| e.to_string())?;
        fs::create_dir_all(unit.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(&unit, unit_text(&exe.to_string_lossy())).map_err(|e| e.to_string())?;
        let _ = run("systemctl", &sv(&["--user", "daemon-reload"]), None, 30);
        let o = run("systemctl", &sv(&["--user", "enable", UNIT_NAME]), None, 30);
        if !o.ok {
            return Err(format!("systemctl enable: {}", o.text));
        }
    } else if unit.exists() {
        let _ = run("systemctl", &sv(&["--user", "disable", UNIT_NAME]), None, 30);
        let _ = fs::remove_file(&unit);
        let _ = run("systemctl", &sv(&["--user", "daemon-reload"]), None, 30);
    }
    Ok(())
}

fn autostart_run(cfg: &Config) -> Value {
    let mut results = Vec::new();
    for c in cfg.connections.iter().filter(|c| c.autostart) {
        let mut last = Err("not tried".to_string());
        for attempt in 0..5 {
            last = do_mount(c);
            if last.is_ok() {
                break;
            }
            if attempt < 4 {
                std::thread::sleep(Duration::from_secs(5));
            }
        }
        results.push(json!({"id": c.id, "ok": last.is_ok(), "error": last.err()}));
    }
    notify_autostart(&results);
    json!({"ok": true, "results": results})
}

/// One desktop notification summarising a login auto-mount run.
fn notify_autostart(results: &[Value]) {
    if results.is_empty() || !on_path("notify-send") {
        return;
    }
    let failed: Vec<String> = results
        .iter()
        .filter(|r| r["ok"] != json!(true))
        .map(|r| format!("{}: {}", r["id"].as_str().unwrap_or("?"), r["error"].as_str().unwrap_or("failed")))
        .collect();
    let (urgency, body) = if failed.is_empty() {
        ("low", format!("{} mounted at login", results.len()))
    } else {
        ("normal", format!("Could not mount at login:\n{}", failed.join("\n")))
    };
    let _ = run("notify-send", &sv(&["-a", "Mounts", "-u", urgency, "Mounts", &body]), None, 10);
}

// ── Commands ─────────────────────────────────────────────────────────────────

fn find<'a>(cfg: &'a Config, id: &str) -> Res<&'a Connection> {
    cfg.connections.iter().find(|c| c.id == id).ok_or_else(|| format!("no connection '{id}'"))
}

fn read_stdin() -> Res<String> {
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s).map_err(|e| e.to_string())?;
    Ok(s)
}

fn cmd_save(cfg: &mut Config, input: &str) -> Res<Value> {
    let raw: Value = serde_json::from_str(input).map_err(|e| format!("bad JSON: {e}"))?;
    let password = raw.get("password").and_then(Value::as_str).filter(|p| !p.is_empty()).map(String::from);
    let clear = raw.get("clearPassword").and_then(Value::as_bool).unwrap_or(false);
    let mut c: Connection = serde_json::from_value(raw).map_err(|e| format!("bad connection: {e}"))?;
    c.name = c.name.trim().to_string();
    c.host = c.host.trim().to_string();
    c.user = c.user.trim().to_string();
    c.path = c.path.trim().to_string();
    validate(&c)?;
    if cfg.connections.iter().any(|x| x.id != c.id && x.name.eq_ignore_ascii_case(&c.name)) {
        return Err(format!("a connection named '{}' already exists", c.name));
    }

    let existing = cfg.connections.iter().position(|x| x.id == c.id && !c.id.is_empty());
    match existing {
        Some(i) => c.has_password = cfg.connections[i].has_password,
        None => {
            let taken: Vec<String> = cfg.connections.iter().map(|x| x.id.clone()).collect();
            c.id = unique_id(&slug(&c.name), &taken);
            c.has_password = false;
        }
    }
    if let Some(p) = &password {
        secret_store(&c, p)?;
        c.has_password = true;
    } else if clear && c.has_password {
        secret_clear(&c);
        c.has_password = false;
    }
    match existing {
        Some(i) => cfg.connections[i] = c.clone(),
        None => cfg.connections.push(c.clone()),
    }
    store(cfg)?;
    sync_unit(cfg)?;
    Ok(json!({"ok": true, "connection": view(&c)}))
}

fn run_cmd(args: &[String]) -> Res<Value> {
    let sub = args.first().map(String::as_str).unwrap_or("");
    let arg = |i: usize| args.get(i).map(String::as_str).ok_or_else(|| "missing argument".to_string());
    let mut cfg = load()?;
    match sub {
        "list" | "status" => {
            Ok(json!({"ok": true, "connections": cfg.connections.iter().map(view).collect::<Vec<_>>()}))
        }
        "mount" => {
            let c = find(&cfg, arg(1)?)?.clone();
            do_mount(&c)?;
            Ok(json!({"ok": true, "connection": view(&c)}))
        }
        "unmount" => {
            let c = find(&cfg, arg(1)?)?.clone();
            do_unmount(&c)?;
            Ok(json!({"ok": true, "connection": view(&c)}))
        }
        "save" => cmd_save(&mut cfg, &read_stdin()?),
        "delete" => {
            let c = find(&cfg, arg(1)?)?.clone();
            let _ = do_unmount(&c);
            if c.backend == "sshfs" {
                let _ = fs::remove_dir(mountpoint(&c)); // only succeeds when empty
            }
            if c.has_password {
                secret_clear(&c);
            }
            cfg.connections.retain(|x| x.id != c.id);
            store(&cfg)?;
            sync_unit(&cfg)?;
            Ok(json!({"ok": true}))
        }
        "autostart" => {
            let on = match arg(1)? {
                "enable" => true,
                "disable" => false,
                _ => return Err("autostart takes enable|disable".into()),
            };
            let id = arg(2)?.to_string();
            find(&cfg, &id)?;
            for c in cfg.connections.iter_mut().filter(|c| c.id == id) {
                c.autostart = on;
            }
            store(&cfg)?;
            sync_unit(&cfg)?;
            Ok(json!({"ok": true}))
        }
        "autostart-run" => Ok(autostart_run(&cfg)),
        "deps" => Ok(deps()),
        _ => Err("usage: mountsctl list|status|mount ID|unmount ID|save|delete ID|autostart enable|disable ID|autostart-run|deps".into()),
    }
}

fn on_path(prog: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
        .unwrap_or(false)
}

/// What the UI needs to warn about before the user hits a cryptic error.
fn deps() -> Value {
    let gvfs = |name: &str| std::path::Path::new("/usr/share/gvfs/mounts").join(name).exists();
    json!({
        "ok": true,
        "gio": on_path("gio"),
        "secret_tool": on_path("secret-tool"),
        "sshfs": on_path("sshfs"),
        "fusermount": on_path("fusermount3") || on_path("fusermount"),
        "gvfs_sftp": gvfs("sftp.mount"),
        "gvfs_smb": gvfs("smb.mount"),
        "gvfs_nfs": gvfs("nfs.mount"),
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run_cmd(&args) {
        Ok(v) => println!("{v}"),
        Err(e) => {
            println!("{}", json!({"error": e}));
            std::process::exit(1);
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(protocol: &str) -> Connection {
        Connection {
            id: "nas".into(),
            name: "NAS".into(),
            protocol: protocol.into(),
            host: "nas.local".into(),
            user: "justin".into(),
            path: "media".into(),
            backend: "gio".into(),
            ..Default::default()
        }
    }

    #[test]
    fn uris() {
        assert_eq!(uri(&conn("smb")), "smb://justin@nas.local/media");
        let mut s = conn("sftp");
        s.port = Some(2222);
        s.path = "/home/j docs".into();
        assert_eq!(uri(&s), "sftp://justin@nas.local:2222/home/j%20docs");
        let mut n = conn("nfs");
        n.user.clear();
        assert_eq!(uri(&n), "nfs://nas.local/media");
    }

    #[test]
    fn slugs() {
        assert_eq!(slug("My NAS (media)!"), "my-nas-media");
        assert_eq!(slug("***"), "mount");
        assert_eq!(unique_id("nas", &["nas".into(), "nas-2".into()]), "nas-3");
    }

    #[test]
    fn validation() {
        assert!(validate(&conn("smb")).is_ok());
        let mut c = conn("smb");
        c.host = "-oProxyCommand=x".into();
        assert!(validate(&c).is_err());
        let mut c = conn("smb");
        c.path = String::new();
        assert!(validate(&c).is_err());
        let mut c = conn("smb");
        c.backend = "sshfs".into();
        assert!(validate(&c).is_err());
        let mut c = conn("sftp");
        c.path = "../etc".into();
        assert!(validate(&c).is_err());
        let mut c = conn("sftp");
        c.user = "a@b".into();
        assert!(validate(&c).is_err());
    }

    #[test]
    fn sshfs_command() {
        let mut c = conn("sftp");
        c.backend = "sshfs".into();
        c.path = "/srv".into();
        c.port = Some(22);
        let a = sshfs_args(&c, "/home/j/Mounts/nas", false);
        assert_eq!(a[0], "justin@nas.local:/srv");
        assert_eq!(a[1], "/home/j/Mounts/nas");
        assert!(a[3].contains("BatchMode=yes") && !a[3].contains("password_stdin"));
        assert_eq!(&a[4..], ["-p", "22"]);
        assert!(sshfs_args(&c, "/m", true)[3].contains("password_stdin"));
    }

    #[test]
    fn gvfs_entries() {
        assert!(gvfs_matches(&conn("smb"), "smb-share:server=nas.local,share=media"));
        assert!(gvfs_matches(&conn("smb"), "smb-share:server=NAS.LOCAL,share=Media"));
        assert!(!gvfs_matches(&conn("smb"), "smb-share:server=nas.local,share=other"));
        assert!(gvfs_matches(&conn("sftp"), "sftp:host=nas.local,user=justin"));
        assert!(!gvfs_matches(&conn("sftp"), "sftp:host=other,user=justin"));
        assert!(!gvfs_matches(&conn("sftp"), "smb-share:server=nas.local,share=media"));
    }

    #[test]
    fn config_roundtrip() {
        let cfg = Config { connections: vec![conn("smb"), { let mut s = conn("sftp"); s.port = Some(2222); s }] };
        let text = toml::to_string_pretty(&cfg).unwrap();
        let back: Config = toml::from_str(&text).unwrap();
        assert_eq!(back.connections, cfg.connections);
    }

    #[test]
    fn friendly_errors() {
        assert!(friendly("Error mounting: Failed to resolve hostname").starts_with("can't find that host"));
        assert!(friendly("Permission denied (publickey)").starts_with("authentication failed"));
        assert!(friendly("ssh: connect to host x port 22: Connection refused").starts_with("connection refused"));
        assert!(friendly("read: Connection reset by peer").starts_with("the host closed"));
        assert!(friendly("sshfs timed out after 60s").starts_with("connected, but"));
        assert!(friendly("Connection timed out").starts_with("can't reach the host"));
        assert!(friendly("something unusual").eq("something unusual"));
    }

    #[test]
    fn validation_more() {
        let mut c = conn("nfs");
        c.port = Some(0);
        assert!(validate(&c).is_err());
        let mut c = conn("smb");
        c.name = "  ".into();
        assert!(validate(&c).is_err());
        let mut c = conn("smb");
        c.protocol = "ftp".into();
        assert!(validate(&c).is_err());
        let mut c = conn("sftp");
        c.host = "a b".into();
        assert!(validate(&c).is_err());
    }

    #[test]
    fn duplicate_names_rejected() {
        let mut cfg = Config { connections: vec![conn("smb")] };
        let body = r#"{"id":"","name":"nas","protocol":"smb","host":"h","path":"s","backend":"gio","autostart":false}"#;
        let r = cmd_save(&mut cfg, body);
        assert!(r.unwrap_err().contains("already exists"));
    }

    #[test]
    fn deps_has_keys() {
        let d = deps();
        for k in ["gio", "secret_tool", "sshfs", "fusermount", "gvfs_sftp", "gvfs_smb", "gvfs_nfs"] {
            assert!(d.get(k).is_some(), "{k}");
        }
    }

    #[test]
    fn unit_has_exe() {
        assert!(unit_text("/x/mountsctl").contains("ExecStart=/x/mountsctl autostart-run"));
    }
}

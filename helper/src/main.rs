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
use std::path::{Path, PathBuf};
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
    /// SMB only: Windows domain or workgroup.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    domain: String,
    /// SMB only: connect as a guest, with no user or password.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    guest: bool,
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

/// Create `dir` if needed and keep it private (it names your hosts and users).
fn private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

/// Replace `path` in one step, so a reader never sees a half-written file.
fn write_atomic(path: &Path, body: &str) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let tmp = path.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    let mut f = fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp)?;
    f.write_all(body.as_bytes())?;
    drop(f);
    fs::rename(&tmp, path)
}

/// Hold an exclusive lock until the returned file is dropped, so parallel mountsctl
/// runs can't overwrite each other's read-change-write.
fn lock_file(path: &Path) -> std::io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(path)?;
    f.lock()?;
    Ok(f)
}

fn store(cfg: &Config) -> Res<()> {
    let dir = config_dir();
    private_dir(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let body = toml::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    write_atomic(&config_path(), &body).map_err(|e| e.to_string())
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
    if host.is_empty() || host.starts_with('-') || has_ctl(host)
        || host.chars().any(|ch| ch.is_whitespace() || "/@?#%[]\\,;\"'<>=&|`$()".contains(ch))
        || (host.contains(':') && host.parse::<std::net::Ipv6Addr>().is_err()) {
        return Err("host is invalid".into());
    }
    if c.user.starts_with('-') || c.user.chars().any(|ch| ch.is_whitespace() || ch == '@' || ch == '/') || has_ctl(&c.user) {
        return Err("user is invalid".into());
    }
    if has_ctl(&c.path) || c.path.split('/').any(|seg| seg == "..") {
        return Err("path is invalid".into());
    }
    if c.protocol == "sftp" && c.backend == "gio" && !c.path.is_empty() && !c.path.starts_with('/') {
        return Err("with gio, an SFTP path must start with / (the sshfs backend also takes a path relative to your home)".into());
    }
    if has_ctl(&c.domain) || c.domain.chars().any(|ch| "/@\\:".contains(ch)) {
        return Err("domain is invalid".into());
    }
    if c.protocol != "smb" && (c.guest || !c.domain.is_empty()) {
        return Err("domain and guest access are for SMB only".into());
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

/// The host as it goes in a URI or an sshfs target: IPv6 addresses need brackets.
fn host_part(c: &Connection) -> String {
    if c.host.contains(':') { format!("[{}]", c.host) } else { c.host.clone() }
}

fn uri(c: &Connection) -> String {
    let user = if c.user.is_empty() { String::new() } else { format!("{}@", pct(&c.user, false)) };
    let port = c.port.map(|p| format!(":{p}")).unwrap_or_default();
    let path = c.path.trim_matches('/');
    let host = host_part(c);
    match c.protocol.as_str() {
        "smb" => format!("smb://{user}{host}{port}/{}", pct(path, true)),
        "sftp" => format!("sftp://{user}{host}{port}/{}", pct(path, true)),
        _ => format!("nfs://{host}{port}/{}", pct(path, true)),
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
    let mut args = vec![format!("{user}{}:{}", host_part(c), c.path), mp.to_string(), "-o".into(), opts];
    if let Some(p) = c.port {
        args.push("-p".into());
        args.push(p.to_string());
    }
    args
}

fn unpct(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = (b[i] == b'%').then(|| s.get(i + 1..i + 3)).flatten();
        match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
            Some(v) => { out.push(v); i += 3; }
            None => { out.push(b[i]); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Split a gvfs entry (`smb-share:server=nas,share=my%20share`) into its kind and decoded fields.
fn gvfs_fields(entry: &str) -> Option<(&str, HashMap<&str, String>)> {
    let (kind, rest) = entry.split_once(':')?;
    Some((kind, rest.split(',').filter_map(|kv| kv.split_once('=')).map(|(k, v)| (k, unpct(v))).collect()))
}

/// Where `path` sits inside an NFS export mounted at `prefix`; None if it's outside that export.
fn nfs_subpath(path: &str, prefix: Option<&str>) -> Option<String> {
    let want = path.trim_matches('/');
    let pre = prefix.unwrap_or("").trim_matches('/');
    if pre.is_empty() || want == pre {
        return Some(if pre.is_empty() { want.to_string() } else { String::new() });
    }
    want.strip_prefix(pre)?.strip_prefix('/').map(str::to_string)
}

/// Does a `/run/user/UID/gvfs/` entry (e.g. `smb-share:server=nas,share=media`) belong to `c`?
fn gvfs_matches(c: &Connection, entry: &str) -> bool {
    let Some((kind, p)) = gvfs_fields(entry) else { return false };
    let host_is = |k: &str| p.get(k).is_some_and(|v| v.trim_matches(['[', ']']).eq_ignore_ascii_case(&c.host));
    match (c.protocol.as_str(), kind) {
        ("smb", "smb-share") => {
            host_is("server") && p.get("share").is_some_and(|s| s.eq_ignore_ascii_case(smb_share(c)))
        }
        ("sftp", "sftp") => {
            // gvfs may leave out the default port, so "no port" and 22 are the same thing.
            let port = p.get("port").and_then(|v| v.parse().ok()).unwrap_or(22u16);
            host_is("host")
                && (c.user.is_empty() || p.get("user").is_none_or(|u| *u == c.user))
                && port == c.port.unwrap_or(22)
        }
        ("nfs", "nfs") => {
            (host_is("host") || host_is("server")) && nfs_subpath(&c.path, p.get("prefix").map(String::as_str)).is_some()
        }
        _ => false,
    }
}

/// The folder for `c` inside its mount. GVfs mounts the whole server, share or export,
/// so the configured subfolder has to be added to the mount's root.
fn local_path(c: &Connection, root: &str) -> String {
    if c.backend == "sshfs" || root.is_empty() {
        return root.to_string();
    }
    let path = c.path.trim_matches('/');
    let sub = match c.protocol.as_str() {
        "smb" => path.split_once('/').map_or(String::new(), |(_, s)| s.to_string()),
        "nfs" => Path::new(root)
            .file_name()
            .and_then(|n| gvfs_fields(&n.to_string_lossy()).and_then(|(_, p)| nfs_subpath(path, p.get("prefix").map(String::as_str))))
            .unwrap_or_default(),
        _ => path.to_string(),
    };
    if sub.is_empty() { root.to_string() } else { Path::new(root).join(sub).to_string_lossy().into_owned() }
}

// ── Process helpers ──────────────────────────────────────────────────────────

struct Out {
    ok: bool,
    /// stdout and stderr together, trimmed: for messages.
    text: String,
    /// stdout alone, untouched: for values that must stay exact, like passwords.
    stdout: String,
    stderr: String,
    timed_out: bool,
}

/// Run a command with optional stdin, killing it after `secs`.
fn run(prog: &str, args: &[String], stdin: Option<&str>, secs: u64) -> Out {
    let mut cmd = Command::new(prog);
    cmd.args(args);
    run_with(cmd, prog, stdin, false, secs)
}

/// `run` for a prepared command. `hold_stdin` keeps stdin open until the command ends.
fn run_with(mut cmd: Command, prog: &str, stdin: Option<&str>, hold_stdin: bool, secs: u64) -> Out {
    // classify() reads English output; C.UTF-8 keeps non-ASCII arguments intact.
    cmd.env("LC_ALL", "C.UTF-8")
        .env_remove("LANGUAGE")
        .stdin(if stdin.is_some() || hold_stdin { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Out { ok: false, text: format!("cannot run {prog}: {e}"), stdout: String::new(), stderr: String::new(), timed_out: false },
    };
    let held = if hold_stdin { child.stdin.take() } else { None };
    if let (Some(data), Some(mut si)) = (stdin, child.stdin.take()) {
        let _ = si.write_all(data.as_bytes());
    }
    // Drain stdout/stderr on threads. Reading after exit can block forever: sshfs
    // daemonizes and its ssh child keeps our pipes open for the life of the mount.
    let (tx, rx) = std::sync::mpsc::channel::<(bool, Vec<u8>)>();
    for (is_out, pipe) in [(true, child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>)),
                           (false, child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>))] {
        let Some(mut pipe) = pipe else { continue };
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match pipe.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => { let _ = tx.send((is_out, buf[..n].to_vec())); }
                }
            }
        });
    }
    drop(tx);
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
    drop(held);
    // Collect output; once the process is gone, give the readers a moment, then stop
    // (a daemonized grandchild may hold the pipes open indefinitely).
    let (mut merged, mut stdout, mut stderr) = (Vec::new(), Vec::new(), Vec::new());
    let deadline = Instant::now() + Duration::from_millis(1500);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok((is_out, chunk)) => {
                merged.extend_from_slice(&chunk);
                (if is_out { &mut stdout } else { &mut stderr }).extend_from_slice(&chunk);
            }
            Err(_) => break, // all readers done, or deadline passed
        }
    }
    let text = String::from_utf8_lossy(&merged).trim().to_string();
    let stdout = String::from_utf8_lossy(&stdout).into_owned();
    let stderr = String::from_utf8_lossy(&stderr).into_owned();
    match status {
        Some(s) => Out { ok: s.success(), text, stdout, stderr, timed_out: false },
        None => Out { ok: false, text: format!("{prog} timed out after {secs}s"), stdout, stderr, timed_out: true },
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

/// The stored password, if the connection has one. A connection that should have one
/// but can't get it is an error: carrying on would be a failed login with no password.
fn secret_lookup(c: &Connection) -> Res<Option<String>> {
    if !c.has_password {
        return Ok(None);
    }
    let o = run("secret-tool", &sv(&["lookup", "service", SERVICE, "id", &c.id]), None, 30);
    let password = o.stdout.strip_suffix('\n').unwrap_or(&o.stdout);
    if o.ok && !password.is_empty() {
        Ok(Some(password.to_string()))
    } else {
        Err(format!("keyring lookup failed {}", o.text).trim().to_string())
    }
}

fn secret_clear(c: &Connection) {
    let _ = run("secret-tool", &sv(&["clear", "service", SERVICE, "id", &c.id]), None, 30);
}

// ── Status ───────────────────────────────────────────────────────────────────

fn gvfs_dir() -> PathBuf {
    if let Ok(d) = std::env::var("MOUNTSCTL_GVFS_DIR") {
        if !d.is_empty() {
            return PathBuf::from(d);
        }
    }
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
        .then(String::new)
}

/// The folder for `c` right now, if it's mounted (see `local_path`).
fn mounted_path(c: &Connection) -> Option<String> {
    mounted_at(c).map(|root| local_path(c, &root))
}

/// Is this folder answering? A dead FUSE mount fails with ENOTCONN, or just hangs.
fn stat_alive(path: &Path, wait: Duration) -> bool {
    const ENOTCONN: i32 = 107;
    let p = path.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(fs::metadata(&p).err().and_then(|e| e.raw_os_error()));
    });
    !matches!(rx.recv_timeout(wait), Ok(Some(ENOTCONN)) | Err(_))
}

fn view(c: &Connection) -> Value {
    let at = mounted_path(c);
    let stale = c.backend == "sshfs" && at.is_some() && !stat_alive(&mountpoint(c), Duration::from_secs(2));
    let mut v = serde_json::to_value(c).unwrap_or(Value::Null);
    if let Value::Object(m) = &mut v {
        // Where it lives (or will live) on this computer: the sshfs folder is fixed;
        // GVfs picks its own folder, known only once mounted.
        let location = match (&at, c.backend.as_str()) {
            (Some(p), _) if !p.is_empty() => p.clone(),
            (_, "sshfs") => mountpoint(c).to_string_lossy().into_owned(),
            _ => String::new(),
        };
        m.insert("uri".into(), json!(uri(c)));
        m.insert("mounted".into(), json!(at.is_some()));
        m.insert("stale".into(), json!(stale));
        m.insert("mountpoint".into(), json!(at.unwrap_or_default()));
        m.insert("location".into(), json!(location));
        let err = if m.get("mounted") == Some(&json!(true)) { None } else { last_errors().remove(&c.id) };
        m.insert("last_error".into(), json!(err));
    }
    v
}

/// Recognise raw gio / sshfs output: (what happened, what the user should do about it).
fn classify(raw: &str) -> Option<(&'static str, &'static str)> {
    let l = raw.to_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| l.contains(n));
    Some(if has(&["a login script on the server"]) {
        ("the login works, but the server's login script breaks SFTP (~/.bashrc exits or prints text for non-interactive logins)",
         "On the server, edit the user's ~/.bashrc so non-interactive shells do nothing, e.g. at the top: \
          case $- in *i*) ;; *) return;; esac   — then remove any 'exit' or output (fastfetch, echo) that runs for them. \
          Test with: ssh USER@HOST echo ok   (must print exactly 'ok').")
    } else if has(&["the server's sftp service didn't start"]) {
        ("the login works, but the server's SFTP service didn't start",
         "On the server, check /etc/ssh/sshd_config has a 'Subsystem sftp' line (e.g. Subsystem sftp internal-sftp) and restart sshd.")
    } else if has(&["keyring lookup failed"]) {
        ("couldn't read the stored password from the keyring — it may be locked",
         "Unlock the keyring (it normally unlocks at login) and mount again. If the password is gone, Edit the connection and enter it again.")
    } else if has(&["/dev/fuse", "fuse: device", "fuse: failed", "fusermount", "modprobe fuse"]) {
        // Before the auth and not-found checks. Not a bare "fuse": that also matches "refused".
        ("FUSE isn't usable (check that /dev/fuse exists and fuse3 is installed)",
         "Install fuse3 (sudo pacman -S fuse3 sshfs) and make sure /dev/fuse exists. A reboot may be needed after installing.")
    } else if has(&["host key verification failed", "remote host identification has changed", "identity of the remote"]) {
        // Before the auth check: ssh's changed-key warning also mentions password authentication.
        ("the server's SSH host key isn't trusted yet, or it has changed",
         "First connection: run ssh USER@HOST once in a terminal and check the fingerprint before accepting it. \
          If the key changed and you expected that (the server was reinstalled): ssh-keygen -R HOST, then connect once. \
          If you didn't expect a change, stop and check the server first.")
    } else if has(&["password required", "authentication", "permission denied", "invalid password", "logon failure", "access denied"]) {
        ("authentication failed — check the user and password",
         "Open the connection (Edit), re-enter the password and save. Check the user name is exact (case matters). \
          For SFTP you can use an SSH key instead: ssh-copy-id USER@HOST, then remove the stored password. \
          To test outside Mounts: ssh USER@HOST (SFTP) or smbclient -L HOST -U USER (SMB).")
    } else if has(&["could not resolve", "name or service not known", "failed to resolve", "host not found", "no such host", "unable to locate"]) {
        ("can't find that host — check the name or your network",
         "Check the host name for typos, or use the IP address instead. Make sure you're on the right network (or VPN) at login time. Test with: ping HOST.")
    } else if has(&["connection refused"]) {
        ("connection refused — is the service running on that host and port?",
         "The host answered but nothing is listening on that port. Start the service (sshd for SFTP, smbd for SMB, nfsd for NFS) or fix the Port in the connection.")
    } else if has(&["sshfs timed out after", "gio timed out after"]) {
        ("connected, but the server never answered — if the host is up, its SSH/SFTP setup may be broken (login scripts like ~/.bashrc that print output break SFTP)",
         "Make sure the server's ~/.bashrc / ~/.profile print nothing for non-interactive logins, and that SFTP is enabled on the server. Test with: sftp USER@HOST.")
    } else if has(&["timed out", "timeout", "no route to host", "network is unreachable"]) {
        ("can't reach the host (timed out) — is it online?",
         "Check the host is powered on and on the same network. If this happens at login, the network may not be up yet — Mounts retries 5 times, so try Mount again in a minute.")
    // sshfs prints ssh's real error, then "read: Connection reset by peer", so the
    // specific network failures above must win or login retries never happen.
    } else if has(&["connection reset", "broken pipe", "connection closed", "closed by remote"]) {
        ("the host closed the connection — check the address, port and that SSH/SFTP is enabled",
         "If this worked before, the server may be temporarily blocking this computer after failed or repeated logins \
          (OpenSSH PerSourcePenalties, fail2ban): wait about 10 minutes and try once. \
          Otherwise check on the server that sshd is running, that the port is right, and that sshd_config has a 'Subsystem sftp' line.")
    } else if has(&["bad share name", "no such file", "not found", "does not exist"]) {
        ("the share or path wasn't found on the host",
         "Edit the connection and check the Share / Path. For SFTP it must be a folder that exists on the server; for SMB just the share name; for NFS the exported path.")
    } else if has(&["operation not supported", "volume doesn't implement mount", "not supported"]) {
        ("this protocol isn't supported on this system (is the gvfs package installed?)",
         "Install the backend: gvfs-smb for SMB, gvfs-nfs for NFS (run ./setup.sh --install in the plugin folder), then restart the session.")
    } else {
        return None;
    })
}

/// Turn raw gio / sshfs output into something a person can act on.
fn friendly(raw: &str) -> String {
    let t = raw.trim();
    match classify(t) {
        None => t.to_string(),
        Some((msg, _)) if t.is_empty() => msg.to_string(),
        Some((msg, _)) => format!("{msg} ({})", t.lines().next().unwrap_or("")),
    }
}

// ── Log ──────────────────────────────────────────────────────────────────────

fn log_path() -> PathBuf {
    let dir = match std::env::var("MOUNTSCTL_LOG_DIR") {
        Ok(d) if !d.is_empty() => PathBuf::from(d),
        _ => match std::env::var("XDG_STATE_HOME") {
            Ok(d) if !d.is_empty() => PathBuf::from(d).join("omarchy/jgarza.mounts"),
            _ => home().join(".local/state/omarchy/jgarza.mounts"),
        },
    };
    dir.join("mounts.log")
}

/// Last mount result per connection id ({"id": "error message"}), so the window can
/// show why something isn't mounted even when the failure happened at login.
fn last_errors_path() -> PathBuf {
    log_path().with_file_name("last-errors.json")
}

fn last_errors() -> HashMap<String, String> {
    fs::read_to_string(last_errors_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn record_result(id: &str, res: &Res<()>) {
    let p = last_errors_path();
    if let Some(d) = p.parent() {
        let _ = private_dir(d);
    }
    let _lock = lock_file(&p.with_extension("lock"));
    let mut m = last_errors();
    match res {
        Ok(()) => { if m.remove(id).is_none() { return; } }
        Err(e) => { m.insert(id.to_string(), e.clone()); }
    }
    let _ = write_atomic(&p, &serde_json::to_string(&m).unwrap_or_default());
}

fn timestamp() -> String {
    let o = run("date", &sv(&["+%Y-%m-%d %H:%M:%S"]), None, 5);
    if o.ok { o.text.trim().to_string() } else { "?".into() }
}

/// Keep the log small: past ~200 KB drop everything but the last 1000 lines.
fn trim_log(path: &std::path::Path) {
    if fs::metadata(path).map(|m| m.len() > 200_000).unwrap_or(false) {
        if let Ok(s) = fs::read_to_string(path) {
            let lines: Vec<&str> = s.lines().collect();
            let keep = lines[lines.len().saturating_sub(1000)..].join("\n");
            let _ = write_atomic(path, &(keep + "\n"));
        }
    }
}

/// Append one entry. `fix` and `raw` are optional; failures to write the log are ignored.
fn log_event(level: &str, who: &str, what: &str, problem: &str, fix: &str, raw: &str) {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let path = log_path();
    if let Some(d) = path.parent() {
        let _ = private_dir(d);
    }
    trim_log(&path);
    let mut e = format!("{}  {:<5}  {}: {}\n", timestamp(), level, who, what);
    if !problem.is_empty() {
        e.push_str(&format!("    Problem: {problem}\n"));
    }
    if !fix.is_empty() {
        e.push_str(&format!("    To fix:  {fix}\n"));
    }
    let raw = raw.trim();
    if !raw.is_empty() {
        let shown: Vec<&str> = raw.lines().take(6).collect();
        e.push_str(&format!("    Details: {}\n", shown.join("\n             ")));
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&path) {
        let _ = f.set_permissions(fs::Permissions::from_mode(0o600));
        let _ = f.write_all(e.as_bytes());
    }
}

/// A logged failure: the short message for the UI plus what went wrong and how to fix it.
struct Failure {
    message: String,
    problem: &'static str,
    fix: &'static str,
}

/// Log a failed mount/unmount of `c` and return the friendly message for the UI.
fn fail(c: &Connection, action: &str, raw: &str) -> String {
    fail_full(c, action, raw).message
}

fn fail_full(c: &Connection, action: &str, raw: &str) -> Failure {
    let f = describe_failure(c, raw);
    let who = format!("{} ({})", c.name, uri(c));
    log_event("ERROR", &who, action, f.problem, f.fix, raw);
    f
}

fn describe_failure(c: &Connection, raw: &str) -> Failure {
    let (problem, fix) = match classify(raw) {
        Some((m, f)) => (m, f),
        None => ("unexpected error", "Check the details below; if it's unclear, try the same host with the command-line tool (ssh / smbclient / showmount)."),
    };
    // NFS has no login: "denied" means the server refused this computer.
    if c.protocol == "nfs" && problem.starts_with("authentication") {
        let problem = "the NFS server refused this computer";
        return Failure {
            message: format!("{problem} ({})", raw.trim().lines().next().unwrap_or("")),
            problem,
            fix: "gvfs-nfs connects from an unprivileged port, so the export needs the 'insecure' option (and this computer allowed) in /etc/exports on the server. Then run: exportfs -ra",
        };
    }
    Failure { message: friendly(raw), problem, fix }
}

// ── Mount / unmount ──────────────────────────────────────────────────────────

fn do_mount(c: &Connection) -> Res<()> {
    if mounted_at(c).is_some() {
        return Ok(());
    }
    let password = secret_lookup(c).map_err(|e| fail(c, "mount", &e))?;
    if c.backend == "sshfs" {
        return sshfs_mount(c, &mountpoint(c), password.as_deref(), "mount").map_err(|f| f.message);
    }
    let o = gio_mount(c, password.as_deref());
    if o.ok || o.text.contains("already mounted") { Ok(()) } else { Err(fail(c, "mount", &o.text)) }
}

/// gio asks User, Domain, Password (in that order) when it needs them.
fn gio_mount(c: &Connection, password: Option<&str>) -> Out {
    if c.guest {
        return run("gio", &sv(&["mount", "-a", &uri(c)]), None, 60);
    }
    let stdin = match (c.protocol.as_str(), password) {
        ("smb", Some(p)) => Some(format!("{}\n{}\n{p}\n", c.user, c.domain)),
        (_, Some(p)) => Some(format!("{p}\n")),
        _ => None,
    };
    run("gio", &sv(&["mount", &uri(c)]), stdin.as_deref(), 60)
}

/// Mount `c` with sshfs at `mp`. On failure the folder is cleaned up and the error logged.
fn sshfs_mount(c: &Connection, mp: &Path, password: Option<&str>, action: &str) -> Result<(), Failure> {
    fs::create_dir_all(mp).map_err(|e| fail_full(c, action, &format!("cannot create the mount folder {}: {e}", mp.display())))?;
    let args = sshfs_args(c, &mp.to_string_lossy(), password.is_some());
    let stdin = password.map(|p| format!("{p}\n"));
    let o = run("sshfs", &args, stdin.as_deref(), 60);
    if o.ok {
        return Ok(());
    }
    if o.text.starts_with("cannot run sshfs") {
        // Nothing was mounted; don't leave an empty mountpoint dir behind.
        let _ = fs::remove_dir(mp);
        let m = "sshfs is not installed (sudo pacman -S sshfs, or run setup.sh --install)";
        let fix = "Install it with: sudo pacman -S sshfs fuse3 — or switch this connection to the gio backend (Edit).";
        log_event("ERROR", &c.name, action, m, fix, "");
        return Err(Failure { message: m.into(), problem: m, fix });
    }
    // A timed-out sshfs can leave a dead FUSE mount behind; detach it, then drop the empty folder.
    fuse_detach(mp, true);
    let _ = fs::remove_dir(mp);
    Err(fail_full(c, action, &explain_sshfs_reset(c, &o.text, password)))
}

fn fuse_detach(mp: &Path, lazy: bool) -> bool {
    let mps = mp.to_string_lossy().into_owned();
    let flag = if lazy { "-uz" } else { "-u" };
    run("fusermount3", &sv(&[flag, &mps]), None, 10).ok || run("fusermount", &sv(&[flag, &mps]), None, 10).ok
}

/// Try a connection without saving it: mount it somewhere temporary, look inside,
/// and unmount again. Uses exactly the same login path as a real mount.
fn do_test(c: &Connection, password: Option<&str>) -> Value {
    let summary = |n: Option<usize>| match n {
        Some(0) => "Connected — the folder is empty.".to_string(),
        Some(1) => "Connected — 1 item in the folder.".to_string(),
        Some(n) => format!("Connected — {n} items in the folder."),
        None => "Connected.".to_string(),
    };
    let count = |dir: &Path| fs::read_dir(dir).ok().map(|rd| rd.count());
    let failed = |f: Failure| json!({"ok": false, "message": f.message, "problem": f.problem, "fix": f.fix});
    // sshfs: only the saved connection's own folder counts (id is blank when settings changed).
    // gio: GVfs keys mounts by server/share, so an identical mount is the same mount.
    let already = if c.backend == "sshfs" && c.id.is_empty() { None } else { mounted_path(c) };
    if let Some(at) = already {
        let n = if at.is_empty() { None } else { count(Path::new(&at)) };
        return json!({"ok": true, "message": format!("{} (it's mounted right now)", summary(n))});
    }
    if c.backend == "sshfs" {
        let dir = std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
        let mp = dir.join(format!("mountsctl-test-{}", std::process::id()));
        return match sshfs_mount(c, &mp, password, "test") {
            Ok(()) => {
                let n = count(&mp);
                if !fuse_detach(&mp, false) {
                    fuse_detach(&mp, true);
                }
                let _ = fs::remove_dir(&mp);
                log_event("INFO", &c.name, "test passed", "", "", "");
                json!({"ok": true, "message": summary(n)})
            }
            Err(e) => failed(e),
        };
    }
    let o = gio_mount(c, password);
    if !o.ok && !o.text.contains("already mounted") {
        return failed(fail_full(c, "test", &o.text));
    }
    let n = mounted_path(c).filter(|p| !p.is_empty()).and_then(|p| count(Path::new(&p)));
    // "already mounted" means it was there before the test, so it stays.
    if !o.text.contains("already mounted") {
        let _ = run("gio", &sv(&["mount", "-u", &uri(c)]), None, 30);
    }
    log_event("INFO", &c.name, "test passed", "", "", "");
    json!({"ok": true, "message": summary(n)})
}

const PROBE_MARK: &str = "MOUNTS-PROBE-OK";

/// sshfs swallows ssh's own error: a wrong password, a login script that exits, and
/// a login script that prints text all surface as "read: Connection reset by peer".
/// When that happens, log in once the same way sshfs does and run `echo MARK`:
///   - "Permission denied"         → the password / key really is refused
///   - exit 0 but no MARK          → a login script (~/.bashrc) exits for non-interactive shells
///   - text before MARK            → a login script prints output, which corrupts SFTP
///   - only MARK                   → login and shell are fine; the SFTP subsystem itself is the problem
fn explain_sshfs_reset(c: &Connection, raw: &str, password: Option<&str>) -> String {
    let low = raw.to_lowercase();
    if !low.contains("connection reset") && !low.contains("sshfs timed out after") {
        return raw.to_string();
    }
    if low.contains("host key verification failed") {
        return raw.to_string(); // already explained; a probe would just fail the same way
    }
    let target = if c.user.is_empty() { c.host.clone() } else { format!("{}@{}", c.user, c.host) };
    let mut args = sv(&["-o", "ConnectTimeout=10", "-o", "NumberOfPasswordPrompts=1", "-T"]);
    // Password: hand it to ssh through a throwaway SSH_ASKPASS helper (never on the command line).
    let askpass = password.and_then(|_| {
        let dir = std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
        let p = dir.join(format!("mountsctl-askpass-{}", std::process::id()));
        use std::os::unix::fs::PermissionsExt;
        fs::write(&p, "#!/bin/sh\nprintf '%s\\n' \"$MOUNTSCTL_PW\"\n").ok()?;
        fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).ok()?;
        Some(p)
    });
    if askpass.is_none() {
        args.extend(sv(&["-o", "BatchMode=yes"]));
    }
    if let Some(p) = c.port {
        args.push("-p".into());
        args.push(p.to_string());
    }
    args.push("--".into());
    args.push(target);
    args.push(format!("echo {PROBE_MARK}"));
    // Keep stdin open like SFTP does: a login script that starts a shell (e.g. a bare `zsh`
    // in ~/.bashrc) then sits waiting for input instead of running our command.
    let mut cmd = Command::new("ssh");
    cmd.args(&args);
    if let (Some(ap), Some(pw)) = (&askpass, password) {
        cmd.env("SSH_ASKPASS", ap).env("SSH_ASKPASS_REQUIRE", "force").env("MOUNTSCTL_PW", pw);
    }
    let o = run_with(cmd, "ssh", None, true, 20);
    if let Some(ap) = &askpass {
        let _ = fs::remove_file(ap);
    }
    if o.timed_out {
        // Logged in (or still trying) but our command never ran: something is waiting for input.
        return format!(
            "the login works, but a login script on the server (usually ~/.bashrc) starts a program that waits \
             for input (often a bare 'zsh' line), so SFTP never starts. Start it only for interactive shells: \
             case $- in *i*) zsh; return;; esac\n{raw}");
    }
    let Out { ok, stdout, stderr, .. } = o;
    let why = if stderr.to_lowercase().contains("permission denied") {
        format!("login refused by the server: {}\n(wrong password, or no SSH key for this computer on the server)",
                stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim())
    } else if !ok {
        return raw.to_string();
    } else if !stdout.contains(PROBE_MARK) {
        "the login works, but a login script on the server (usually ~/.bashrc) exits for non-interactive \
         sessions, so SFTP never starts. Fix that script on the server: for non-interactive shells it must \
         'return' and print nothing.".to_string()
    } else if stdout.trim() != PROBE_MARK {
        "the login works, but a login script on the server (~/.bashrc / ~/.profile) prints text for \
         non-interactive sessions, which corrupts SFTP. Make it print nothing unless the shell is interactive.".to_string()
    } else {
        "the login works and the shell is clean, but the server's SFTP service didn't start \
         (check 'Subsystem sftp' in /etc/ssh/sshd_config on the server).".to_string()
    };
    format!("{why}\n{raw}")
}

/// Program names from `fuser -vm` output, leaving out the kernel's own "mount" line.
fn parse_fuser(text: &str) -> Vec<String> {
    let mut names: Vec<String> = text
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let pid = f.len().checked_sub(3).and_then(|i| f.get(i))?;
            pid.parse::<u32>().ok().map(|_| f[f.len() - 1].to_string())
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

fn unmount_fail(c: &Connection, raw: &str) -> String {
    let fix = "Close anything using the folder (file manager, terminal cd'd into it, running programs), then try again, or use Force unmount.";
    log_event("ERROR", &c.name, "unmount", "could not unmount", fix, raw);
    if !raw.to_lowercase().contains("busy") {
        return raw.to_string();
    }
    let users = mounted_at(c)
        .filter(|p| !p.is_empty())
        .map(|p| parse_fuser(&run("fuser", &sv(&["-vm", &p]), None, 10).text))
        .unwrap_or_default();
    if users.is_empty() {
        format!("{} is in use — close what's using it, or Force unmount", c.name)
    } else {
        format!("{} is in use by {} — close it, or Force unmount", c.name, users.join(", "))
    }
}

/// `force`: detach even with files open; programs using it get errors.
fn do_unmount(c: &Connection, force: bool) -> Res<()> {
    if mounted_at(c).is_none() {
        return Ok(());
    }
    if c.backend == "sshfs" {
        let mp = mountpoint(c);
        if force {
            return if fuse_detach(&mp, true) { Ok(()) } else { Err(unmount_fail(c, "fusermount couldn't detach the mount")) };
        }
        let mp = mp.to_string_lossy().into_owned();
        let mut o = run("fusermount3", &sv(&["-u", &mp]), None, 30);
        if !o.ok {
            o = run("fusermount", &sv(&["-u", &mp]), None, 30);
        }
        return if o.ok { Ok(()) } else { Err(unmount_fail(c, &o.text)) };
    }
    let u = uri(c);
    let args = if force { sv(&["mount", "-u", "-f", &u]) } else { sv(&["mount", "-u", &u]) };
    let o = run("gio", &args, None, 30);
    if o.ok { Ok(()) } else { Err(unmount_fail(c, &o.text)) }
}

// ── Autostart (systemd --user) ───────────────────────────────────────────────

fn systemd_enabled() -> bool {
    std::env::var("MOUNTSCTL_NO_SYSTEMD").is_err()
}

fn unit_text(exe: &str) -> String {
    format!(
        "[Unit]\nDescription=Mount saved network shares (jgarza.mounts)\nAfter=graphical-session.target\n\n\
         [Service]\nType=oneshot\nRemainAfterExit=yes\nKillMode=process\nExecStart={exe} autostart-run\n\n[Install]\nWantedBy=default.target\n"
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

/// Seconds between login attempts, about 2 minutes in all. There's no network target
/// to wait for in a user service, so retrying is what covers a slow network.
const RETRY_DELAYS: [u64; 7] = [2, 4, 8, 16, 30, 30, 30];

fn mount_with_retries(c: &Connection) -> Res<()> {
    let mut last = do_mount(c);
    for secs in RETRY_DELAYS {
        // Only retry while the network may still be coming up. Retrying a bad
        // password or a refused session just gets this machine penalised/banned.
        if !last.as_ref().err().is_some_and(|e| retryable(e)) {
            break;
        }
        std::thread::sleep(Duration::from_secs(secs));
        last = do_mount(c);
    }
    record_result(&c.id, &last);
    if last.is_ok() {
        log_event("INFO", &c.name, "mounted at login", "", "", "");
    }
    last
}

/// Indexes of `hosts`, grouped so that equal hosts (any case) are together.
fn group_by_host(hosts: &[&str]) -> Vec<Vec<usize>> {
    let mut groups: Vec<(String, Vec<usize>)> = Vec::new();
    for (i, h) in hosts.iter().enumerate() {
        let h = h.to_lowercase();
        match groups.iter_mut().find(|(g, _)| *g == h) {
            Some((_, list)) => list.push(i),
            None => groups.push((h, vec![i])),
        }
    }
    groups.into_iter().map(|(_, list)| list).collect()
}

/// Hosts run in parallel so a dead one can't hold up the rest. Connections to the same
/// host run one after another: logging in all at once can get this machine blocked.
fn autostart_run(cfg: &Config) -> Value {
    let wanted: Vec<&Connection> = cfg.connections.iter().filter(|c| c.autostart).collect();
    let hosts: Vec<&str> = wanted.iter().map(|c| c.host.as_str()).collect();
    let mut outcomes: Vec<Option<Res<()>>> = wanted.iter().map(|_| None).collect();
    std::thread::scope(|s| {
        let wanted = &wanted;
        let workers: Vec<_> = group_by_host(&hosts)
            .into_iter()
            .map(|group| s.spawn(move || group.into_iter().map(|i| (i, mount_with_retries(wanted[i]))).collect::<Vec<_>>()))
            .collect();
        for w in workers {
            for (i, res) in w.join().unwrap_or_default() {
                outcomes[i] = Some(res);
            }
        }
    });
    let results: Vec<Value> = wanted
        .iter()
        .zip(outcomes)
        .map(|(c, res)| {
            let res = res.unwrap_or_else(|| Err("not tried".to_string()));
            json!({"id": c.id, "name": c.name, "ok": res.is_ok(), "error": res.err()})
        })
        .collect();
    notify_autostart(&results);
    json!({"ok": true, "results": results})
}

/// Is a mount error worth retrying at login (network not up yet), as opposed to
/// one that will fail the same way again and count as another failed login?
fn retryable(err: &str) -> bool {
    ["can't reach the host", "can't find that host", "couldn't read the stored password"].iter().any(|p| err.starts_with(p))
}

/// One desktop notification summarising a login auto-mount run.
fn notify_autostart(results: &[Value]) {
    if results.is_empty() || !on_path("notify-send") {
        return;
    }
    let failed: Vec<String> = results
        .iter()
        .filter(|r| r["ok"] != json!(true))
        .map(|r| format!("{}: {}", r["name"].as_str().or(r["id"].as_str()).unwrap_or("?"), r["error"].as_str().unwrap_or("failed")))
        .collect();
    let (urgency, body) = if failed.is_empty() {
        ("low", format!("{} mounted at login", results.len()))
    } else {
        ("critical", format!("Could not mount at login:\n{}\n\nWhat to fix: open Mounts and click Log, or read\n{}", failed.join("\n"), log_path().display()))
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

/// A password typed in the form, else (for Duplicate) the one stored for `copyPasswordFrom`.
fn body_password(cfg: &Config, raw: &Value) -> Res<Option<String>> {
    if let Some(p) = raw.get("password").and_then(Value::as_str).filter(|p| !p.is_empty()) {
        return Ok(Some(p.to_string()));
    }
    if raw.get("clearPassword").and_then(Value::as_bool).unwrap_or(false) {
        return Ok(None);
    }
    match raw.get("copyPasswordFrom").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        None => Ok(None),
        Some(src) => {
            let s = find(cfg, src)?;
            secret_lookup(s)?.map(Some).ok_or_else(|| format!("'{}' has no stored password", s.name))
        }
    }
}

/// Do both connections mount the same thing, the same way?
fn same_target(a: &Connection, b: &Connection) -> bool {
    (&a.protocol, &a.host, &a.user, a.port, &a.path, &a.backend, &a.domain, a.guest)
        == (&b.protocol, &b.host, &b.user, b.port, &b.path, &b.backend, &b.domain, b.guest)
}

/// The connection in a save/test body, trimmed and validated.
fn body_connection(raw: Value) -> Res<Connection> {
    let mut c: Connection = serde_json::from_value(raw).map_err(|e| format!("bad connection: {e}"))?;
    for field in [&mut c.name, &mut c.host, &mut c.user, &mut c.path, &mut c.domain] {
        *field = field.trim().to_string();
    }
    validate(&c)?;
    Ok(c)
}

fn cmd_save(cfg: &mut Config, input: &str) -> Res<Value> {
    let raw: Value = serde_json::from_str(input).map_err(|e| format!("bad JSON: {e}"))?;
    let password = body_password(cfg, &raw)?;
    let clear = raw.get("clearPassword").and_then(Value::as_bool).unwrap_or(false);
    let mut c = body_connection(raw)?;
    if cfg.connections.iter().any(|x| x.id != c.id && x.name.eq_ignore_ascii_case(&c.name)) {
        return Err(format!("a connection named '{}' already exists", c.name));
    }

    let existing = cfg.connections.iter().position(|x| x.id == c.id && !c.id.is_empty());
    if let Some(old) = existing.map(|i| &cfg.connections[i]) {
        // The old mount would keep running, with nothing here pointing at it any more.
        if !same_target(old, &c) && mounted_at(old).is_some() {
            return Err(format!("{} is mounted — unmount it before changing its host, user, port, path, protocol or backend", old.name));
        }
    }
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
    record_result(&c.id, &Ok(())); // the settings changed, so an old failure no longer applies
    Ok(json!({"ok": true, "connection": view(&c)}))
}

/// `test`: same JSON body as `save`, but nothing is stored. A blank password on an
/// existing connection means "use the stored one" (unless clearPassword is set).
fn cmd_test(cfg: &Config, input: &str) -> Res<Value> {
    let raw: Value = serde_json::from_str(input).map_err(|e| format!("bad JSON: {e}"))?;
    let typed = body_password(cfg, &raw)?;
    let clear = raw.get("clearPassword").and_then(Value::as_bool).unwrap_or(false);
    let mut c = body_connection(raw)?;
    let saved = cfg.connections.iter().find(|x| x.id == c.id && !c.id.is_empty());
    let password = match (typed, saved) {
        (Some(p), _) => Some(p),
        (None, Some(s)) if !clear => secret_lookup(s)?,
        _ => None,
    };
    // Only treat it as "already mounted" if nothing that affects the mount changed.
    if !saved.is_some_and(|s| same_target(s, &c)) {
        c.id = String::new();
    }
    Ok(do_test(&c, password.as_deref()))
}

fn run_cmd(args: &[String]) -> Res<Value> {
    let sub = args.first().map(String::as_str).unwrap_or("");
    let arg = |i: usize| args.get(i).map(String::as_str).ok_or_else(|| "missing argument".to_string());
    // Changes hold this for the whole read-change-write.
    let _lock = if matches!(sub, "save" | "delete" | "autostart") {
        let dir = config_dir();
        private_dir(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        Some(lock_file(&dir.join(".lock")).map_err(|e| format!("cannot lock the config: {e}"))?)
    } else {
        None
    };
    // The log and deps must keep working when connections.toml is broken.
    let mut cfg = if matches!(sub, "log" | "deps") { Config::default() } else { load()? };
    match sub {
        "list" | "status" => {
            Ok(json!({"ok": true, "connections": cfg.connections.iter().map(view).collect::<Vec<_>>()}))
        }
        "mount" => {
            let c = find(&cfg, arg(1)?)?.clone();
            let res = do_mount(&c);
            record_result(&c.id, &res);
            res?;
            Ok(json!({"ok": true, "connection": view(&c)}))
        }
        "unmount" => {
            let c = find(&cfg, arg(1)?)?.clone();
            do_unmount(&c, args.get(2).map(String::as_str) == Some("--force"))?;
            Ok(json!({"ok": true, "connection": view(&c)}))
        }
        "remount" => {
            let c = find(&cfg, arg(1)?)?.clone();
            if c.backend == "sshfs" {
                fuse_detach(&mountpoint(&c), true); // a dead mount won't unmount normally
            }
            let res = do_mount(&c);
            record_result(&c.id, &res);
            res?;
            Ok(json!({"ok": true, "connection": view(&c)}))
        }
        "save" => cmd_save(&mut cfg, &read_stdin()?),
        "test" => cmd_test(&cfg, &read_stdin()?),
        "delete" => {
            let c = find(&cfg, arg(1)?)?.clone();
            // Don't forget a connection that is still mounted: its mount would be orphaned.
            do_unmount(&c, false).map_err(|e| format!("{} is still mounted and couldn't be unmounted, so it wasn't deleted: {e}", c.name))?;
            if c.backend == "sshfs" {
                let _ = fs::remove_dir(mountpoint(&c)); // only succeeds when empty
            }
            if c.has_password {
                secret_clear(&c);
            }
            cfg.connections.retain(|x| x.id != c.id);
            store(&cfg)?;
            sync_unit(&cfg)?;
            record_result(&c.id, &Ok(())); // a new connection could reuse this id
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
        "log" if args.get(1).map(String::as_str) == Some("clear") => {
            // Keep the previous log as mounts.log.old (one level), start a fresh one.
            let p = log_path();
            if p.exists() {
                fs::rename(&p, p.with_extension("log.old")).map_err(|e| format!("cannot clear the log: {e}"))?;
            }
            if let Some(d) = p.parent() {
                let _ = private_dir(d);
            }
            write_atomic(&p, &format!("{}  INFO   Log cleared (previous log saved as mounts.log.old)\n", timestamp()))
                .map_err(|e| format!("cannot write the log: {e}"))?;
            Ok(json!({"ok": true}))
        }
        "log" => {
            let p = log_path();
            if !p.exists() {
                if let Some(d) = p.parent() {
                    let _ = private_dir(d);
                }
                let _ = write_atomic(&p, "Mounts log — failures are recorded here with what to fix.\n");
            }
            let tail = fs::read_to_string(&p).unwrap_or_default();
            let lines: Vec<&str> = tail.lines().collect();
            let text = lines[lines.len().saturating_sub(500)..].join("\n");
            Ok(json!({"ok": true, "path": p.to_string_lossy(), "text": text}))
        }
        _ => Err("usage: mountsctl list|status|mount ID|unmount ID [--force]|remount ID|save|test|delete ID|log [clear]|autostart enable|disable ID|autostart-run|deps".into()),
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
    fn every_known_error_has_a_fix() {
        for raw in ["Permission denied", "Connection reset by peer", "Connection refused", "Name or service not known", "sshfs timed out after 60s", "No route to host"] {
            let (msg, fix) = classify(raw).expect(raw);
            assert!(!msg.is_empty() && fix.len() > 20, "{raw}");
        }
        assert!(classify("something odd").is_none());
    }

    #[test]
    fn login_script_problems_are_named() {
        let raw = "the login works, but a login script on the server (usually ~/.bashrc) exits\nread: Connection reset by peer";
        assert!(classify(raw).unwrap().0.contains("login script"));
        assert!(!retryable(&friendly(raw)));
    }

    #[test]
    fn only_network_errors_are_retried() {
        assert!(retryable(&friendly("No route to host")));
        assert!(retryable(&friendly("Name or service not known")));
        assert!(!retryable(&friendly("Permission denied (publickey,password)")));
        assert!(!retryable(&friendly("read: Connection reset by peer")));
    }

    #[test]
    fn ipv6_hosts_and_bad_hosts() {
        let mut c = conn("sftp");
        c.path = "/a".into();
        c.host = "::1".into();
        assert!(validate(&c).is_ok());
        assert_eq!(uri(&c), "sftp://justin@[::1]/a");
        c.backend = "sshfs".into();
        assert_eq!(sshfs_args(&c, "/m", false)[0], "justin@[::1]:/a");
        c.backend = "gio".into();
        assert!(gvfs_matches(&c, "sftp:host=%5B::1%5D,user=justin"));
        for bad in ["a:b", "a?b", "a#b", "a%b", "[::1]", "a,b"] {
            c.host = bad.into();
            assert!(validate(&c).is_err(), "{bad}");
        }
    }

    #[test]
    fn gio_sftp_paths_are_absolute() {
        let mut c = conn("sftp");
        c.path = "docs".into();
        assert!(validate(&c).is_err());
        c.backend = "sshfs".into();
        assert!(validate(&c).is_ok());
        c.backend = "gio".into();
        c.path = String::new();
        assert!(validate(&c).is_ok());
    }

    #[test]
    fn domain_and_guest_are_smb_only() {
        let mut c = conn("smb");
        c.domain = "WORK".into();
        c.guest = true;
        assert!(validate(&c).is_ok());
        c.domain = "a/b".into();
        assert!(validate(&c).is_err());
        let mut n = conn("nfs");
        n.guest = true;
        assert!(validate(&n).is_err());
        assert!(!toml::to_string(&conn("smb")).unwrap().contains("guest"));
    }

    #[test]
    fn keyring_failures_are_named_and_retried() {
        let m = friendly("keyring lookup failed");
        assert!(m.contains("keyring"), "{m}");
        assert!(retryable(&m));
    }

    #[test]
    fn nfs_refusal_is_not_called_a_password_problem() {
        let f = describe_failure(&conn("nfs"), "Permission denied");
        assert!(f.message.starts_with("the NFS server refused"));
        assert!(f.fix.contains("insecure"));
    }

    #[test]
    fn fuser_output_gives_program_names() {
        let text = "                     USER        PID ACCESS COMMAND\n/m:                  root     kernel mount /m\n                     j      834 ..c.. zsh\n                     j      900 F.... nvim\n                     j      901 ..c.. zsh\n";
        assert_eq!(parse_fuser(text), ["nvim", "zsh"]);
    }

    #[test]
    fn hosts_group_any_case() {
        assert_eq!(group_by_host(&["a", "b", "A"]), [vec![0, 2], vec![1]]);
    }

    #[test]
    fn login_retries_last_about_two_minutes() {
        let total: u64 = RETRY_DELAYS.iter().sum();
        assert!((100..=150).contains(&total));
    }

    #[test]
    fn stat_alive_on_a_normal_folder() {
        assert!(stat_alive(Path::new("/"), Duration::from_secs(2)));
        assert!(stat_alive(Path::new("/no/such/folder"), Duration::from_secs(2)));
    }

    #[test]
    fn gvfs_names_are_decoded() {
        let mut c = conn("smb");
        c.path = "my share/sub".into();
        assert!(gvfs_matches(&c, "smb-share:server=nas.local,share=my%20share"));
        assert_eq!(unpct("a%2Fb%zz%"), "a/b%zz%");
    }

    #[test]
    fn port_22_is_the_default() {
        let mut c = conn("sftp");
        c.port = Some(22);
        assert!(gvfs_matches(&c, "sftp:host=nas.local,user=justin"));
        assert!(gvfs_matches(&c, "sftp:host=nas.local,port=22,user=justin"));
        assert!(!gvfs_matches(&c, "sftp:host=nas.local,port=2222,user=justin"));
        c.port = None;
        assert!(gvfs_matches(&c, "sftp:host=nas.local,port=22,user=justin"));
        assert!(!gvfs_matches(&c, "sftp:host=nas.local,port=2222,user=justin"));
    }

    #[test]
    fn nfs_exports_stay_separate() {
        let mut c = conn("nfs");
        c.path = "/export/a".into();
        assert!(gvfs_matches(&c, "nfs:host=nas.local,prefix=%2Fexport%2Fa"));
        assert!(!gvfs_matches(&c, "nfs:host=nas.local,prefix=%2Fexport%2Fb"));
        assert!(!gvfs_matches(&c, "nfs:host=nas.local,prefix=%2Fexport%2Fab"));
        c.path = "/export/a/sub".into();
        assert!(gvfs_matches(&c, "nfs:host=nas.local,prefix=%2Fexport%2Fa"));
    }

    #[test]
    fn open_goes_to_the_configured_folder() {
        let mut s = conn("smb");
        s.path = "media/Movies/2020".into();
        assert_eq!(local_path(&s, "/g/smb-share:server=n,share=media"), "/g/smb-share:server=n,share=media/Movies/2020");
        s.path = "media".into();
        assert_eq!(local_path(&s, "/g/x"), "/g/x");
        let mut f = conn("sftp");
        f.path = "/srv/data/".into();
        assert_eq!(local_path(&f, "/g/sftp:host=n"), "/g/sftp:host=n/srv/data");
        assert_eq!(local_path(&f, ""), "");
        f.backend = "sshfs".into();
        assert_eq!(local_path(&f, "/home/j/Mounts/n"), "/home/j/Mounts/n");
        let mut n = conn("nfs");
        n.path = "/export/a/sub".into();
        assert_eq!(local_path(&n, "/g/nfs:host=n,prefix=%2Fexport%2Fa"), "/g/nfs:host=n,prefix=%2Fexport%2Fa/sub");
    }

    #[test]
    fn stdout_stays_exact_and_separate() {
        let o = run("sh", &sv(&["-c", "printf ' p@ss '; echo warn >&2"]), None, 5);
        assert_eq!(o.stdout, " p@ss ");
        assert!(o.text.contains("warn"));
    }

    #[test]
    fn only_mount_settings_count_as_a_new_target() {
        let a = conn("sftp");
        let mut b = a.clone();
        b.name = "Renamed".into();
        b.autostart = true;
        assert!(same_target(&a, &b));
        b.host = "other".into();
        assert!(!same_target(&a, &b));
    }

    #[test]
    fn fuse_and_host_key_errors_are_named() {
        assert!(friendly("fusermount3: failed to open /dev/fuse: Permission denied").starts_with("FUSE"));
        assert!(friendly("fuse: device not found, try 'modprobe fuse' first").starts_with("FUSE"));
        assert!(friendly("login refused by the server: Permission denied").starts_with("authentication failed"));
        assert!(friendly("Host key verification failed.\nread: Connection reset by peer").contains("host key"));
        let changed = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nPassword authentication is disabled";
        assert!(friendly(changed).contains("host key"));
    }

    #[test]
    fn child_output_is_forced_to_english() {
        let o = run("sh", &sv(&["-c", "echo \"$LC_ALL/${LANGUAGE:-none}\""]), None, 5);
        assert_eq!(o.text, "C.UTF-8/none");
    }

    #[test]
    fn sshfs_network_errors_beat_its_trailing_reset() {
        for first in ["No route to host", "Connection timed out", "Network is unreachable"] {
            let raw = format!("ssh: connect to host h port 22: {first}\nread: Connection reset by peer");
            assert!(retryable(&friendly(&raw)), "{raw}");
        }
    }

    #[test]
    fn run_does_not_hang_on_inherited_pipes() {
        // A background grandchild keeps stdout open; run() must still return promptly.
        let t = Instant::now();
        let o = run("sh", &sv(&["-c", "echo hi; sleep 30 & exit 0"]), None, 10);
        assert!(o.ok && o.text.contains("hi"));
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn unit_has_exe() {
        let u = unit_text("/x/mountsctl");
        assert!(u.contains("ExecStart=/x/mountsctl autostart-run"));
        // sshfs daemonizes inside the unit's cgroup; don't kill it when the oneshot exits.
        assert!(u.contains("KillMode=process"));
        assert!(u.contains("RemainAfterExit=yes"));
        assert!(!u.contains("network-online"), "not available to user services");
    }
}

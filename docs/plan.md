## Context
User wants a GUI to manage network mounts (SMB, SSH/SFTP, NFS) and no good off-the-shelf tool fits. They asked: Rust + QML? plugin or app?

Findings:
- Omarchy's shell is Quickshell (QML). Plugins live in `~/.config/omarchy/plugins/<id>/` with a `manifest.json` (kinds: `bar-widget`, `overlay`, `panel`, ...). User already authors many (`jgarza.*`, see `plugins/myplugins.md`).
- `jgarza.drives` is a close template (QML + helper scripts in `bin/` + python tests); it lists/mounts/ejects drives incl. network shares but does not manage saved connections.
- Installed: quickshell, qt6-declarative, rust/cargo, libsecret, gnome-keyring, gvfs-smb/nfs, cifs-utils. SFTP-via-gio is built into `gvfs`; `fuse3` is installed; only `sshfs` was missing (there is no `gvfs-sftp` package on Arch).

## Recommendation
**Plugin, not a standalone app; QML for UI; Rust for a small backend CLI.**
- Plugin: native look/theming, bar integration, opens as a real window (`FloatingWindow`, not a layer-shell overlay), shares install/marketplace flow. A standalone Qt app would need its own theming, tray and autostart.
- QML UI + Rust helper: QML can't safely do keyring/systemd/config work itself; a Rust CLI emitting JSON keeps UI dumb and testable (same split as `jgarza.drives`).

## Design: `jgarza.mounts`
Layout (mirror `jgarza.drives`): `manifest.json`, `Mounts.qml` (real `FloatingWindow`, not an overlay: connection list, add/edit form, mount/unmount buttons, status dots), optional `BarWidget.qml` (icon + count), `helper/` Rust crate producing `mountsctl`.

`mountsctl` subcommands (JSON out): `list`, `status`, `mount <id>`, `unmount <id>`, `save`, `delete`, `autostart enable|disable <id>`, `autostart-run` (mounts all flagged entries).
- Config: `~/.config/omarchy/jgarza.mounts/connections.toml` (name, protocol smb/sftp/nfs, host, user, path, backend, autostart). No secrets.
- Credentials: Secret Service via `keyring`/`oo7` crate (gnome-keyring already present).
- Backends, chosen per entry: `gio` (default, `gio mount`, no root, shows in Nautilus), `sshfs` (FUSE, mountpoint under `~/Mounts/<name>`), `cifs` only via gio in v1 (kernel `mount.cifs` needs root/fstab; defer).
- Auto-mount at login: per-entry flag; one systemd user unit `mounts-autostart.service` running `mountsctl autostart-run` (installed by `autostart enable`).
- Status: `gio mount -l` + `/proc/self/mountinfo`; refresh on interval and after actions.

## Build steps
1. Install deps: `sudo pacman -S sshfs` (user runs; only for the sshfs backend).
2. Scaffold plugin folder + manifest (copy structure from `~/.config/omarchy/plugins/jgarza.drives`).
3. Rust crate: config model, backends, keyring, JSON CLI; unit tests for config + command construction.
4. QML real window (`FloatingWindow`; title bar, resizable, Hyprland tiling/floating rules apply): list, form, buttons, status; call `mountsctl` via Quickshell `Process`.
5. Autostart unit; optional bar widget; README, update `myplugins.md`.

## Verification
- `cargo test`; `mountsctl list/status` against a real SMB and SFTP host.
- Mount/unmount each backend; confirm share appears in Nautilus (gio) / `findmnt` (sshfs).
- Password stored in keyring (`secret-tool lookup`), absent from `connections.toml`.
- Log out/in: autostart entries mount.
- Toggle the plugin and confirm it opens as a normal window (appears in `hyprctl clients`, title "Mounts"), UI renders and theme applies.

## Open items for user
- Is kernel-level CIFS (fstab/root) needed, or is gio-SMB enough for v1?

## Decision log
- Window type: real window (`FloatingWindow`), not an overlay. Converted in `Mounts.qml`; still need to confirm it opens. If overlay-kind plugins can't host one, switch the manifest to the kind `jgarza.clinic`/`jgarza.tidepool` use and open the window from a bar widget.
- Optional: Hyprland window rule to float/size it.
- Added: `setup.sh` (dependency check/install), `uninstall.sh`, `mountsctl deps`, friendly errors, form validation, mount/unmount all, bar widget (manifest 0.2.0).
- Lesson: shell hot-reload keeps stale QML; use `omarchy-restart-shell` to verify UI changes.
- Decisions: v1 is gio-only for SMB (kernel CIFS deferred); manifest kinds are overlay + bar-widget; prebuilt `bin/mountsctl` ships, `helper/target/` does not; autostart sends one desktop notification.
- Open (needs real hosts / a login): SMB via gio, SFTP via gio, NFS, autostart after a real login.

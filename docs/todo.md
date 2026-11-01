# Mounts — todo

## Blockers / setup
- [x] gio SFTP needs no extra package (`gvfs` ships `sftp.mount`; `gvfs-sftp` does not exist on Arch). SMB/NFS backends already installed.
- [x] `setup.sh` checks all dependencies (`./setup.sh --install` installs missing ones via pacman); `mountsctl` gives a clear "sshfs is not installed" error.
- [x] Run `./setup.sh --install` yourself to get `sshfs` (needs sudo; only for the sshfs backend).
- [x] `fuse3` (`fusermount3`), `libsecret` (`secret-tool`), `gio` and `ssh` are present.

- [x] `uninstall.sh` (interactive, `--dry-run`, `--clean`, `--yes`) with warnings; tested on a sandbox copy.
- [x] Try `./uninstall.sh --dry-run` against real data once connections exist.

## Window (now a real `FloatingWindow`)
- [x] Convert `PanelWindow` overlay to `FloatingWindow`; confirmed it opens as "Mounts" (class `org.quickshell`).
- [x] Look at the UI in the shell: layout, theme colors, spacing at small and large sizes. — checked list, empty state and form at the default size (themed correctly); minimum size is 560×420, small sizes not eyeballed.
- [x] Hyprland window rule: float, center and size it (class `org.quickshell`, title `Mounts`), or decide tiled is fine. — snippet in README; not applied to your hypr config
- [x] Decide on manifest `kinds`: still `overlay` (works via the shell's panel loader); revisit if a plugin-window kind appears. Decision: `overlay` + `bar-widget` (loads and toggles fine; note `listPlugins` reports `enabled` for the widget as "is in the bar", not whether the window works).
- [x] Verify close paths: `esc`, Close button, WM close (super+Q), toggle keybind; reopen after each. — verified: Esc (form → list → close), `q`, Close button, WM close (`hl.dsp.window.close`), toggle; the window reopens after each.
- [x] Keyboard focus: `n`/`r`/`q` keys work when the window is focused and don't fire while typing in form fields. — verified: typing `nrq` into a field doesn't trigger shortcuts.
- [x] Remember window size/position: not needed, Hyprland handles it (see window rule in README).
- [x] Restart note: shell hot-reload kept the old `Mounts.qml` until `omarchy-restart-shell`; document in README.

## Functionality tests (real hosts)
- [x] `cargo test` stays green (7 tests); add tests for command construction per backend and protocol. (now 11)
- [ ] Add + mount + unmount a real SMB share via gio; appears in Nautilus.
- [x] Add + mount + unmount a real SFTP host via gio. (Verified on two real LAN hosts with saved passwords; list and unmount clean.)
- [x] Add + mount + unmount SFTP via sshfs (also verified on two real LAN hosts) under `~/Mounts/<id>`; confirm with `findmnt`. (Verified against a temporary local sshd: fuse.sshfs mount, file readable, clean unmount.)
- [ ] NFS: gio handles `nfs://` (needs `gvfs-nfs`, banner warns if missing); test against a real NFS host.
- [x] Edit an existing connection; rename; change protocol and backend (sshfs only for SFTP).
- [x] Delete a connection (config entry, keyring secret, empty mountpoint verified; unit sync via `sync_unit`): removes config entry, keyring secret and autostart unit.
- [x] Password is in the keyring (`secret-tool lookup`) and absent from `connections.toml`.
- [x] "Remove stored password" actually clears the keyring item.
- [x] Mounted state detection stays correct after external mount/unmount (Nautilus, `umount`). — verified with a mount made outside the plugin (list flips true/false).
- [ ] Autostart: toggle installs/removes `~/.config/systemd/user/jgarza-mounts-autostart.service`; log out/in and confirm entries mount.
- [x] Autostart with network not yet up: unit waits for `network-online.target`, and `autostart-run` retries 5×5 s. (Still verify after a real login.)

## UX polish
- [x] Error messages: show mountsctl failures clearly (unreachable host, bad password, missing `sshfs`). (`friendly()` in mountsctl, tested)
- [x] Detect missing dependencies and show an actionable hint in the window. (`mountsctl deps` + banner)
- [x] Disabled "…" state while mounting exists; mountsctl kills mounts after 60 s.
- [x] Validate form: required name/host, port range, duplicate names/ids. (form hints + Save disabled; duplicate names rejected by mountsctl)
- [x] "Open" falls back to opening the URI when there is no local mountpoint (uses `xdg-open`).
- [x] Empty state: wording now says "press n"; add a visible "New connection" button.
- [x] Footer shows keys and "N of M mounted".
- [x] Mount all / unmount all actions (optional).
- [x] Sort/group list (mounted first, by protocol) (optional). (mounted first, then name)

## Extras
- [x] Omarchy menu entry (`menu.sh install|remove|status`); searching "drives" finds Mounts first; `omarchy menu summon mount` opens it. Wired into `setup.sh --install` and `uninstall.sh` (step 6).
- [x] Bar widget (`BarWidget.qml`): icon + mounted count, click opens the window. (written; needs shell restart + adding it in bar settings to see)
- [x] Add `kinds` entry in `manifest.json` if the widget is added.
- [x] Notification on autostart success/failure (optional).
- [x] Kernel CIFS (fstab/root) — deferred; decide if v1 stays gio-only. Decision: v1 is gio-only for SMB; no kernel CIFS.

## Housekeeping
- [x] Add `jgarza.mounts` to `~/.config/omarchy/plugins/myplugins.md`.
- [x] README: update for the real window, window rule, restart note, deps, key bindings.
- [x] Update `plan.md` decision log once the window and bar-widget questions are settled.
- [x] Trim `.gitignore`/build output: keep `helper/target/` out of the plugin when shared; ship `bin/mountsctl` or document `./build.sh`. Decision: `helper/target/` ignored; `bin/mountsctl` is shipped prebuilt (users can `./build.sh`).
- [x] Bump version in `manifest.json`; add a license file (manifest says MIT). (0.2.0 + LICENSE)

## Real-host test results (two real LAN hosts, a third with a broken shell profile, a fourth with a restricted account)
- Two hosts: sshfs and gio both mount, list and unmount cleanly.
- Host with a syntax error in its `~/.bashrc`: login works but the SFTP subsystem never answers. Plugin times out after 60 s with an explanatory message and leaves no stale mount.
- Host with a restricted account: password login succeeds but the server closes the session and SFTP. Plugin reports the connection was closed.
- Fix found while testing: failed/timed-out sshfs mounts now get `fusermount3 -uz` plus folder removal; sshfs uses `ConnectTimeout=15`.

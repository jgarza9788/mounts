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

## Improvement scan (2026-11-01)
Evidence: **[proven]** reproduced by running it · **[read]** certain from the code · **[verify]** depends on outside behaviour, check during the fix.

### Phase 1: Bugs that give wrong behaviour

Login and retry
- [x] 1. **[proven]** Unreachable sshfs hosts aren't retried at login: `classify()` tests "connection reset" before "no route"/"timed out". Move those checks above the reset branch.
- [x] 2. **[proven]** `network-online.target` doesn't exist in the user manager, so the unit's `After=`/`Wants=` do nothing. Remove them and make retries a time budget (about 2 min with backoff).
- [x] 3. **[read]** Connections mount one at a time at login, so one dead host delays the rest (up to 5×60 s). Use one thread per connection and keep results in order.
- [x] 4. **[read]** A keyring failure is reported as a bad password. Return `Res<Option<String>>` from `secret_lookup`, give a "keyring locked/unavailable" error, and retry it at login.

Passwords
- [x] 5. **[proven]** Stored passwords can be corrupted: `run()` merges stderr into stdout and trims. Keep the streams separate and strip only the final newline.

Mount state detection
- [x] 6. **[proven for the matcher]** Mounts go undetected with escaped gvfs names (`share=my%20share`) or an explicit port 22. Percent-decode entries and treat 22 as the default. **[verify]** the real gvfs entry name for port 22.
- [x] 7. **[proven]** Two NFS exports on one host look like the same mount. Compare `prefix=` in `gvfs_matches`.
- [x] 8. **[read]** Test can unmount a live mount through the "already mounted" path in `do_test`. Only unmount what the test mounted.
- [x] 9. **[read]** Open and the item count ignore the configured subfolder because `mounted_at` returns the gvfs root. Join the subpath in `view`/`do_test`.
- [x] 10. **[read]** Editing a mounted connection orphans the mount. `cmd_save` should refuse with "unmount first" when host, backend or path change.

Error messages
- [x] 11. **[proven]** FUSE errors are misclassified as auth or path problems. Move the FUSE branch to the top of `classify()`.
- [x] 12. **[proven]** Host key failures aren't recognised. Add a branch before the reset branch, with `ssh-keyscan`/`ssh-keygen -R` advice.
- [x] 13. **[read]** `classify` matches English text but no locale is forced. Set `LC_ALL=C` on child processes.
- [x] 14. **[read]** Stale failures stick around after delete and save. Clear `last-errors.json` entries on both, and `root.lastError[id]` in QML.

Bar and window (QML)
- [x] 15. **[read]** `hideWhenEmpty` hides the bar icon forever because the timer only runs while visible. Use `running: true`.
- [x] 16. **[read]** Searching by state doesn't work: `filterConnections` joins the `stateOf(c)` object as `[object Object]`. Use `.text`.
- [x] 17. **[read]** The list rebuilds every 5 s and can lose its scroll position. Skip unchanged JSON and ignore out-of-order `refresh` replies.
- [x] 18. **[verify]** A helper that can't start may leave "Mounting…" on screen forever. Add `onExited`/`onRunningChanged` handling with a once-only guard (see `ignibyte.stay-awake-sessions/Service.qml`).
- [x] 19. **[read]** A bad `connections.toml` breaks every command, including `log` and `deps`, and the bar shows "no connections". Load only where needed and show the error state.

### Phase 2: Robustness
- [x] 20. **[read]** Writes can race: Mount all loses `last-errors.json` updates, and `store()` uses a fixed temp filename. Add a `flock` helper and atomic writes with a PID-suffixed temp file.
- [x] 21. **[read]** Mount all can trigger server lockouts by logging in to every host at once. Queue it per host and show one summary toast.
- [x] 22. **[read]** `explain_sshfs_reset` can hang reading pipes after exit. Share `run()`'s drain threads.
- [x] 23. **[proven]** Config, state and log files are 644. Use 0600 for files and 0700 for their directories.
- [x] 24. **[proven]** IPv6 hosts pass validation but build a bad URI (`sftp://::1/a`). Bracket them and reject other URL-special host characters.
- [x] 25. **[proven]** `uninstall.sh` leaves `~/.local/state/omarchy/jgarza.mounts` behind. Add a step for it.
- [x] 26. **[read]** A stale Test result can show on changed settings. Ignore replies if the form changed after Test started.
- [x] 27. **[read]** A relative SFTP path means home on sshfs but `/` on gio. Require a leading `/` for gio SFTP, or show a form hint.
- [x] 28. **[read]** Names and errors, including server output, go through `AutoText`. Set `Text.PlainText`.
- [x] 29. **[verify]** Keyboard focus may be lost after leaving the form. Return it to `keyCatcher` in `onFormChanged`.
- [x] 30. Small fixes: the 8 clippy warnings, `menu.sh` usage with no argument, and no backup when the menu file wouldn't change.

### Phase 3: Features (ordered by value)
- [x] 31. SMB Domain field and guest access (`domain` on `Connection`, `gio mount -a`). Do alongside item 36.
- [x] 32. Form fits the protocol: hide User and Password for NFS, and note that gvfs-nfs needs `insecure` exports.
- [x] 33. Unmount help: name what's using a busy folder (`fuser -vm`) and offer a lazy unmount.
- [x] 34. Stale mount detection: stat with a timeout, plus a "Disconnected" state with a Remount action.
- [x] 35. Unsaved form guard: Esc or summoning the window silently discards a half-filled form.

### Phase 4: Docs and release
- [ ] 36. Finish the open tests above: real SMB, real NFS and a real logout/login. These need real hosts. SMB is the riskiest because the prompt order in `gio_mount` is untested against a server.
- [x] 37. Rebuild `bin/mountsctl`: it's older than `main.rs` (15:57 vs 16:08), so `tests/negative.sh` tested the older binary.
- [x] 38. README: add the `/`, `l`, `q` keys, the `log` and `test` commands, and `tests/negative.sh`.
- [x] 39. Add `python3` and `libnotify` to `setup.sh`.
- [x] 40. Bump `manifest.json` to 1.1.0.
- [ ] 41. **[provenance]** `bin/mountsctl` has no verifiable provenance. Added `.github/workflows/release.yml` (tag `v*` builds, tests and attests the binary) and `--locked` and a pinned toolchain in `build.sh`. Still open: push a tag, run `gh attestation verify`, then replace the committed binary with the CI-built one.
- [x] 42. Security scan fixes: private `O_EXCL` temp dirs for the askpass helper and the sshfs test mount (never shared `/tmp`); escape server text in login notifications; retry at login only while the host really doesn't answer; reject invalid ids in `connections.toml`; quote the systemd `ExecStart` path; `cargo audit` in the release workflow. `tests/negative.sh` is now a manual pre-tag check (the CI runner has no GVfs).

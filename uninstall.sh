#!/usr/bin/env bash
# Remove what jgarza.mounts created on this system, step by step, asking first.
#
#   ./uninstall.sh              interactive uninstall (asks before every step)
#   ./uninstall.sh --dry-run    show what would happen, change nothing
#   ./uninstall.sh --clean      only delete build output (helper/target, bin/mountsctl)
#   ./uninstall.sh --yes        answer yes to every question (still prints warnings)
#
# It NEVER removes packages (sshfs, gvfs...) and NEVER deletes the plugin folder
# itself; it prints the command for that at the end.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ctl="$here/bin/mountsctl"
cfg_dir="${MOUNTSCTL_CONFIG_DIR:-$HOME/.config/omarchy/jgarza.mounts}"
cfg="$cfg_dir/connections.toml"
mount_root="${MOUNTSCTL_MOUNT_ROOT:-$HOME/Mounts}"
unit="jgarza-mounts-autostart.service"
unit_file="$HOME/.config/systemd/user/$unit"
service="jgarza.mounts"

dry=0 yes=0 clean_only=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --yes|-y) yes=1 ;;
    --clean) clean_only=1 ;;
    -h|--help) sed -n 2,11p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 2 ;;
  esac
done

bold=$'\e[1m' red=$'\e[31m' yel=$'\e[33m' dim=$'\e[2m' off=$'\e[0m'
((dry)) && echo "${yel}DRY RUN — nothing will be changed.${off}"

# ask "question" -> 0 if yes
ask() {
  ((dry)) && { echo "  ${dim}[dry-run] would ask: $1${off}"; return 0; }
  ((yes)) && return 0
  local r; read -r -p "  $1 [y/N] " r; [[ "$r" == [yY]* ]]
}
# do_it cmd... -> runs unless dry-run
do_it() { if ((dry)); then echo "  ${dim}[dry-run] $*${off}"; else "$@"; fi; }
step() { echo; echo "${bold}== $1${off}"; }
warn() { echo "  ${red}WARNING:${off} $*"; }

ids=()
if [[ -f "$cfg" ]]; then
  mapfile -t ids < <(python3 - "$cfg" <<'PY' 2>/dev/null
import sys, tomllib
for c in tomllib.load(open(sys.argv[1], "rb")).get("connection", []):
    print(c.get("id", ""))
PY
)
  if ((${#ids[@]} == 0)); then
    mapfile -t ids < <(sed -n 's/^id *= *"\(.*\)"/\1/p' "$cfg")
  fi
fi

# ── Clean build output ──────────────────────────────────────────────────────
clean_build() {
  step "Build output"
  echo "  Deletes helper/target (compiled Rust) and bin/mountsctl."
  echo "  Safe: ./build.sh recreates both. The plugin stops working until you rebuild."
  if [[ ! -d "$here/helper/target" && ! -e "$ctl" ]]; then echo "  nothing to clean."; return; fi
  if ask "Delete build output?"; then
    do_it rm -rf "$here/helper/target" "$ctl"
    echo "  done."
  else echo "  skipped."; fi
}

if ((clean_only)); then clean_build; exit 0; fi

echo "${bold}jgarza.mounts uninstall${off}"
echo "Connections found: ${#ids[@]}${ids[*]:+ (${ids[*]})}"
echo "This undoes what the plugin set up. Each step asks first. Packages are never removed."

# ── 1. Unmount ──────────────────────────────────────────────────────────────
step "1/6  Unmount saved connections"
echo "  Unmounts every saved connection that is currently mounted."
warn "apps using these mounts (file manager, editors, running copies) will lose access;"
echo "           an unmount can fail or interrupt a transfer in progress."
if ((${#ids[@]})) && [[ -x "$ctl" ]]; then
  if ask "Unmount all saved connections?"; then
    for id in "${ids[@]}"; do
      echo "  unmount $id"
      do_it "$ctl" unmount "$id" >/dev/null || echo "    (could not unmount $id — close anything using it and retry)"
    done
  else echo "  skipped (later steps may then leave mounts behind)."; fi
else echo "  nothing to do (no connections, or bin/mountsctl not built)."; fi

# ── 2. Autostart unit ───────────────────────────────────────────────────────
step "2/6  Mount-at-login service"
echo "  Disables and deletes $unit_file"
if [[ -f "$unit_file" ]]; then
  if ask "Remove the autostart service?"; then
    do_it systemctl --user disable --now "$unit" 2>/dev/null
    do_it rm -f "$unit_file"
    do_it systemctl --user daemon-reload
    echo "  done."
  else echo "  skipped."; fi
else echo "  not installed."; fi

# ── 3. Keyring passwords ────────────────────────────────────────────────────
step "3/6  Saved passwords (keyring)"
echo "  Deletes the passwords stored in your keyring for: ${ids[*]:-(none)}"
warn "this cannot be undone. You will have to re-enter passwords if you reinstall."
echo "  Only entries with service=$service are touched; other keyring items are left alone."
if ((${#ids[@]})); then
  if ask "Delete stored passwords?"; then
    for id in "${ids[@]}"; do
      do_it secret-tool clear service "$service" id "$id"
    done
    echo "  done."
  else echo "  skipped."; fi
else echo "  nothing to do."; fi

# ── 4. Config ───────────────────────────────────────────────────────────────
step "4/6  Saved connections (config)"
echo "  Deletes $cfg_dir (names, hosts, users, paths — no passwords)."
warn "this cannot be undone."
if [[ -d "$cfg_dir" ]]; then
  if ask "Delete the config folder?"; then
    if ((dry)); then echo "  ${dim}[dry-run] would back up to ~/jgarza-mounts-connections.<date>.toml${off}"
    elif [[ -f "$cfg" ]]; then
      bak="$HOME/jgarza-mounts-connections.$(date +%Y%m%d-%H%M%S).toml"
      cp "$cfg" "$bak" && echo "  backup saved: $bak"
    fi
    do_it rm -rf "$cfg_dir"
    echo "  done."
  else echo "  skipped."; fi
else echo "  not present."; fi

# ── 5. Mountpoints ──────────────────────────────────────────────────────────
step "5/6  sshfs mountpoint folders"
echo "  Removes EMPTY folders under $mount_root (rmdir only; never deletes files)."
echo "  A folder that is still mounted or has content is left in place."
if [[ -d "$mount_root" ]]; then
  if ask "Remove empty mountpoint folders?"; then
    for id in "${ids[@]}"; do
      mp="$mount_root/$id"
      if mountpoint -q "$mp" 2>/dev/null; then echo "  $mp is still mounted — left alone"
      elif [[ -d "$mp" ]]; then do_it rmdir "$mp" 2>/dev/null && echo "  removed $mp" || echo "  $mp not empty — left alone"; fi
    done
    do_it rmdir "$mount_root" 2>/dev/null
  else echo "  skipped."; fi
else echo "  not present."; fi

# ── 6. Menu entry ───────────────────────────────────────────────────────────
step "6/6  Omarchy menu entry"
echo "  Removes the \"Mounts\" entry (between the jgarza.mounts markers) from"
echo "  ~/.config/omarchy/extensions/omarchy-menu.jsonc. A backup of that file is made first."
if [[ "$("$here/menu.sh" status 2>/dev/null)" == installed ]]; then
  if ask "Remove the menu entry?"; then
    if ((dry)); then echo "  ${dim}[dry-run] $here/menu.sh remove${off}"; else "$here/menu.sh" remove; fi
  else echo "  skipped."; fi
else echo "  not installed."; fi

clean_build

echo
echo "${bold}Finished.${off} Not removed (do it yourself if you want):"
echo "  - the plugin folder:  rm -rf '$here'   ${red}(deletes this script and the source)${off}"
echo "  - packages:           sudo pacman -Rns sshfs   (gvfs, libsecret etc. are shared with other apps)"
echo "  - disable it in the shell, then: omarchy-restart-shell"

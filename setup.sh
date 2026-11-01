#!/usr/bin/env bash
# Check (and optionally install) what jgarza.mounts needs.
#   ./setup.sh           check only, exit 1 if a required dependency is missing
#   ./setup.sh --install install missing packages with pacman (asks for sudo)
set -uo pipefail

install=0
[[ "${1:-}" == "--install" ]] && install=1

missing_pkgs=()
required_missing=0

# name | command to look for | pacman package | required? | why
deps=(
  "gio|gio|glib2|required|mount/unmount via GVfs (default backend)"
  "secret-tool|secret-tool|libsecret|required|passwords in the keyring"
  "ssh|ssh|openssh|required|SFTP through gio"
  "python3|python3|python|required|menu entry and uninstall scripts"
  "gvfs SFTP|/usr/share/gvfs/mounts/sftp.mount|gvfs|required|SFTP backend of gio"
  "gvfs SMB|/usr/share/gvfs/mounts/smb.mount|gvfs-smb|optional|SMB shares"
  "gvfs NFS|/usr/share/gvfs/mounts/nfs.mount|gvfs-nfs|optional|NFS shares"
  "sshfs|sshfs|sshfs|optional|sshfs backend (FUSE) for SFTP"
  "fusermount3|fusermount3|fuse3|optional|unmounting sshfs"
  "notify-send|notify-send|libnotify|optional|notification after mounting at login"
  "fuser|fuser|psmisc|optional|naming what keeps a mount busy"
)

for d in "${deps[@]}"; do
  IFS='|' read -r name probe pkg level why <<<"$d"
  if [[ "$probe" == /* ]]; then [[ -e "$probe" ]] && ok=1 || ok=0
  else command -v "$probe" >/dev/null 2>&1 && ok=1 || ok=0; fi
  if ((ok)); then
    printf '  ok       %-12s %s\n' "$name" "$why"
  else
    printf '  MISSING  %-12s %s  [%s, pacman: %s]\n' "$name" "$why" "$level" "$pkg"
    missing_pkgs+=("$pkg")
    [[ "$level" == required ]] && required_missing=1
  fi
done

menu_note() {
  local st; st="$("$(dirname "$0")/menu.sh" status 2>/dev/null || true)"
  if [[ "$st" == installed ]]; then echo "  ok       menu entry   searchable in the Omarchy menu"
  else echo "  note     menu entry   not installed — run ./menu.sh install (or ./setup.sh --install)"; fi
}
menu_note

if ((${#missing_pkgs[@]} == 0)); then
  echo "All dependencies present."
  ((install)) && "$(dirname "$0")/menu.sh" install
  exit 0
fi

mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
if ((install)); then
  sudo pacman -S --needed "${missing_pkgs[@]}" || exit $?
  "$(dirname "$0")/menu.sh" install
  exit 0
fi

echo
echo "Install with:  sudo pacman -S --needed ${missing_pkgs[*]}"
echo "or run:        $0 --install"
exit $required_missing

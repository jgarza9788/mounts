#!/usr/bin/env bash
# Add/remove the "Mounts" entry in the Omarchy menu so it can be found by
# searching "mount", "unmount", "drives", "network", "nas", "smb", "sftp"...
#
#   ./menu.sh install   add (or refresh) the entry; makes a timestamped backup first
#   ./menu.sh remove    delete the entry again
#   ./menu.sh status    say whether it is installed
#
# Edits only the block between the two "jgarza.mounts" marker comments in
# ~/.config/omarchy/extensions/omarchy-menu.jsonc (your own menu extensions).
set -euo pipefail

file="${OMARCHY_MENU_EXT:-$HOME/.config/omarchy/extensions/omarchy-menu.jsonc}"
start="// >>> jgarza.mounts >>>"
end="// <<< jgarza.mounts <<<"

exec python3 - "$1" "$file" "$start" "$end" <<'PY'
import sys, os, re, json, shutil, time

cmd, path, start, end = sys.argv[1:5]

ENTRY = {
    "icon": "󰋊",
    "label": "Mounts",
    "description": "Mount and unmount network drives and shares (SMB, SFTP, NFS) - network, drives, nas",
    "aliases": ["mounts", "mount", "unmount", "drives", "network drives", "smb", "sftp", "ssh", "nfs",
                "share", "shares", "nas", "sshfs", "remote", "network storage"],
    "action": "omarchy-shell shell summon jgarza.mounts",
}
block = (f"  {start}\n"
         f"  \"mounts\": {json.dumps(ENTRY, ensure_ascii=False)},\n"
         f"  {end}\n")

def strip_jsonc(t):
    out, i, n, instr = [], 0, len(t), False
    while i < n:
        c = t[i]
        if instr:
            out.append(c)
            if c == "\\" and i + 1 < n: out.append(t[i + 1]); i += 1
            elif c == '"': instr = False
        elif c == '"': instr = True; out.append(c)
        elif t.startswith("//", i):
            while i < n and t[i] != "\n": i += 1
            continue
        else: out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

def valid(t):
    try: json.loads(strip_jsonc(t)); return True
    except Exception: return False

text = open(path).read() if os.path.exists(path) else "{\n}\n"
pat = re.compile(r"[ \t]*" + re.escape(start) + r".*?" + re.escape(end) + r"[ \t]*\n?", re.S)
has = bool(pat.search(text))

if cmd == "status":
    print("installed" if has else "not installed"); sys.exit(0)
if cmd not in ("install", "remove"):
    print(__doc__ or "usage: menu.sh install|remove|status"); sys.exit(2)
if not valid(text):
    print(f"refusing to edit: {path} is not valid JSONC right now"); sys.exit(1)

body = pat.sub("", text) if has else text
if cmd == "install":
    # insert before the final closing brace; the previous entry needs a trailing comma
    idx = body.rstrip().rfind("}")
    head = body[:idx].rstrip()
    if head.endswith("{"): sep = "\n"
    else:
        # last significant char before the brace (ignoring trailing // comment lines)
        lines = [l for l in head.split("\n") if l.strip() and not l.strip().startswith("//")]
        last = lines[-1].rstrip() if lines else "{"
        sep = "\n" if last.endswith(",") or last.endswith("{") else None
        if sep is None:
            # add a comma after the last real entry line
            pos = head.rfind(last)
            head = head[:pos] + last + "," + head[pos + len(last):]
            sep = "\n"
    new = head + sep + block + "}\n"
else:
    new = body

if not valid(new):
    print("edit would produce invalid JSONC; nothing changed"); sys.exit(1)
if os.path.exists(path):
    bak = f"{path}.bak.mounts.{int(time.time())}"
    shutil.copy2(path, bak); print("backup:", bak)
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(new)
print("menu entry", "installed" if cmd == "install" else "removed")
PY

#!/usr/bin/env bash
# Negative test: a mount that cannot work must (1) fail with a readable error,
# (2) leave a log entry with Problem / To fix / Details, (3) be readable through
# `mountsctl log`, and (4) raise a critical notification that points at the log.
# Runs fully sandboxed: temp config + log dirs, a fake notify-send, no systemd, no real hosts.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
ctl="${MOUNTSCTL_BIN:-$here/bin/mountsctl}"   # set it to test a fresh build without touching bin/
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
export MOUNTSCTL_CONFIG_DIR="$t/config" MOUNTSCTL_LOG_DIR="$t/log" MOUNTSCTL_NO_SYSTEMD=1 HOME="$t/home"
mkdir -p "$HOME"
# Fake notify-send: record every call instead of showing anything.
cat > "$t/bin/notify-send" <<'N'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTIFY_LOG"
N
chmod +x "$t/bin/notify-send"
export NOTIFY_LOG="$t/notify.log" PATH="$t/bin:$PATH"

fails=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }

# Port 1 on localhost: nothing listens, so the connection is refused immediately.
for backend in sshfs gio; do
  printf '{"name":"neg-%s","protocol":"sftp","host":"127.0.0.1","port":1,"user":"nobody","path":"/","backend":"%s","autostart":true}' "$backend" "$backend" \
    | "$ctl" save >/dev/null
done

for id in neg-sshfs neg-gio; do
  out="$("$ctl" mount "$id" 2>&1)"
  check "$id: mount fails with an error" '[[ "$out" == *\"error\"* ]]'
  check "$id: error is readable (not raw tool output only)" '[[ "$out" == *refused* || "$out" == *"closed the connection"* || "$out" == *"can'"'"'t reach"* ]]'
done

logjson="$("$ctl" log)"
logpath="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' <<<"$logjson")"
check "log command returns a path" '[[ -n "$logpath" ]]'
check "log file exists where the command says" '[[ -f "$logpath" ]]'
for id in neg-sshfs neg-gio; do
  check "log mentions $id"  'grep -q "$id" "$logpath"'
done
check "log has a Problem line"  'grep -q "Problem:" "$logpath"'
check "log has a To fix line"   'grep -q "To fix:"  "$logpath"'
check "log has a Details line"  'grep -q "Details:" "$logpath"'
check "log text is returned by the log command" '[[ "$logjson" == *"To fix:"* ]]'

# Login run: failures must raise a critical notification naming the connection and the log.
"$ctl" autostart-run >/dev/null 2>&1
check "notification was sent"                'test -s "$NOTIFY_LOG"'
check "notification is critical"             'grep -q -- "-u critical" "$NOTIFY_LOG"'
check "notification names the connection"    'grep -q "neg-" "$NOTIFY_LOG"'
check "notification points at the log file"  'grep -q "$logpath" "$NOTIFY_LOG"'

# A failure must not outlive the settings that caused it, or the connection itself.
last_error() { "$ctl" list | python3 -c 'import json,sys
print(next((c["last_error"] or "" for c in json.load(sys.stdin)["connections"] if c["id"]==sys.argv[1]), ""))' "$1"; }
body='{"id":"%s","name":"%s","protocol":"sftp","host":"127.0.0.1","port":1,"user":"nobody","path":"/","backend":"gio","autostart":false}'
check "failure is recorded before the edit" '[[ -n "$(last_error neg-gio)" ]]'
printf "$body" neg-gio neg-gio | "$ctl" save >/dev/null
check "saving clears the old failure"       '[[ -z "$(last_error neg-gio)" ]]'
check "other connection keeps its failure"  '[[ -n "$(last_error neg-sshfs)" ]]'
"$ctl" delete neg-sshfs >/dev/null
printf "$body" "" neg-sshfs | "$ctl" save >/dev/null
check "a reused id starts clean"            '[[ -z "$(last_error neg-sshfs)" ]]'

# Fake gio and secret-tool: nothing here touches a real keyring, mount or host.
fake="$t/fake"; mkdir -p "$fake" "$t/gvfs"
cat > "$fake/gio" <<'G'
#!/usr/bin/env bash
echo "$*" >> "$GIO_LOG"
[[ "$1 $2" == "mount -u" ]] && exit 0
cat > "$GIO_STDIN"
if [[ -n "${GIO_OUT:-}" ]]; then echo "$GIO_OUT"; exit 1; fi
G
cat > "$fake/secret-tool" <<'K'
#!/usr/bin/env bash
case "$1" in
  store) cat >/dev/null ;;
  lookup) printf 'p@ss '; echo 'some warning' >&2 ;;
esac
K
chmod +x "$fake/gio" "$fake/secret-tool"
export GIO_LOG="$t/gio.log" GIO_STDIN="$t/gio.stdin" MOUNTSCTL_GVFS_DIR="$t/gvfs"
fctl() { PATH="$fake:$PATH" "$ctl" "$@"; }
conn='{"id":"%s","name":"fake","protocol":"sftp","host":"%s","port":2222,"user":"nobody","path":"/srv/data","backend":"gio","autostart":false%s}'

printf "$conn" "" 127.0.0.1 ',"password":"x"' | fctl save >/dev/null
fctl mount fake >/dev/null
check "the stored password reaches gio exactly" '[[ "$(cat "$GIO_STDIN"; echo x)" == $'"'"'p@ss \nx'"'"' ]]'

: > "$GIO_LOG"
printf "$conn" fake 127.0.0.1 "" | GIO_OUT="Error mounting location: Location is already mounted" fctl test >/dev/null
check "test leaves an existing mount alone" '! grep -q "mount -u" "$GIO_LOG"'

: > "$GIO_LOG"
printf "$conn" fake 127.0.0.1 "" | fctl test >/dev/null
check "test unmounts what it mounted itself" 'grep -q "mount -u" "$GIO_LOG"'

root="$t/gvfs/sftp:host=127.0.0.1,port=2222,user=nobody"; mkdir -p "$root"
where="$(fctl list | python3 -c 'import json,sys
print(next(c["mountpoint"] for c in json.load(sys.stdin)["connections"] if c["id"]=="fake"))')"
check "mountpoint includes the configured folder" '[[ "$where" == "$root/srv/data" ]]'

out="$(printf "$conn" fake 10.0.0.1 "" | fctl save 2>&1)"
check "changing the host of a mounted connection is refused" '[[ "$out" == *"unmount it before"* ]]'
out="$(printf '{"id":"fake","name":"renamed","protocol":"sftp","host":"127.0.0.1","port":2222,"user":"nobody","path":"/srv/data","backend":"gio","autostart":false}' | fctl save 2>&1)"
check "renaming a mounted connection is allowed" '[[ "$out" == *"\"ok\":true"* ]]'
rmdir "$root"
out="$(printf "$conn" fake 10.0.0.1 "" | fctl save 2>&1)"
check "the same host change works once unmounted" '[[ "$out" == *"\"ok\":true"* ]]'

# Keyring failure: named as such, and no login is attempted without the password.
cat > "$fake/secret-tool" <<'K'
#!/usr/bin/env bash
case "$1" in store) cat >/dev/null ;; lookup) exit 1 ;; esac
K
printf "$conn" fake 10.0.0.1 ',"password":"x"' | fctl save >/dev/null
: > "$GIO_LOG"
out="$(fctl mount fake 2>&1)"
check "a locked keyring is reported as that" '[[ "$out" == *keyring* ]]'
check "no login is tried without the password" '[[ ! -s "$GIO_LOG" ]]'

# Files stay private, and the log still works with a broken config.
check "config is private" '[[ "$(stat -c %a "$MOUNTSCTL_CONFIG_DIR/connections.toml")" == 600 ]]'
check "log is private"    '[[ "$(stat -c %a "$MOUNTSCTL_LOG_DIR/mounts.log")" == 600 ]]'
cp "$MOUNTSCTL_CONFIG_DIR/connections.toml" "$t/good.toml"
echo 'not [valid' > "$MOUNTSCTL_CONFIG_DIR/connections.toml"
check "list reports a broken config"   '"$ctl" list | grep -q "bad connections.toml"'
check "log works with a broken config" '"$ctl" log | grep -q "\"ok\":true"'
check "deps works with a broken config" '"$ctl" deps | grep -q "\"ok\":true"'

# Parallel saves must not lose each other's connections.
export MOUNTSCTL_CONFIG_DIR="$t/config2"
for i in 1 2 3 4 5 6 7 8; do
  printf '{"name":"par%s","protocol":"nfs","host":"h","path":"/x","backend":"gio"}' "$i" | "$ctl" save >/dev/null &
done
wait
count="$("$ctl" list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["connections"]))')"
check "parallel saves keep every connection" '[[ "$count" == 8 ]]'

# Login: a slow host holds up only its own host's connections.
export MOUNTSCTL_CONFIG_DIR="$t/config3"
cat > "$fake/gio" <<'G'
#!/usr/bin/env bash
sleep 1
G
for n in a1:a a2:a b1:b; do
  printf '{"name":"%s","protocol":"nfs","host":"%s","path":"/x","backend":"gio","autostart":true}' "${n%:*}" "${n#*:}" | "$ctl" save >/dev/null
done
s=$(date +%s%N); fctl autostart-run >/dev/null; ms=$(( ($(date +%s%N)-s)/1000000 ))
check "hosts mount in parallel, each host in turn (${ms} ms)" '(( ms >= 1900 && ms < 2900 ))'

echo; if [[ $fails -eq 0 ]]; then echo "all negative checks passed"; else echo "$fails check(s) failed"; exit 1; fi

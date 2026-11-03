#!/usr/bin/env bash
# Build the Rust helper and place it at bin/mountsctl (what Mounts.qml calls).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/setup.sh" || echo "warning: required dependencies missing (see above)"
cd "$here/helper"
# --locked enforces Cargo.lock; SOURCE_DATE_EPOCH pins embedded timestamps to the commit time.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$here" log -1 --format=%ct 2>/dev/null || echo 0)}"
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$here=." cargo build --release --locked
mkdir -p ../bin
cp target/release/mountsctl ../bin/mountsctl
echo "built $(realpath ../bin/mountsctl)"
sha256sum ../bin/mountsctl

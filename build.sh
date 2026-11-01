#!/usr/bin/env bash
# Build the Rust helper and place it at bin/mountsctl (what Mounts.qml calls).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/setup.sh" || echo "warning: required dependencies missing (see above)"
cd "$here/helper"
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$here=." cargo build --release
mkdir -p ../bin
cp target/release/mountsctl ../bin/mountsctl
echo "built $(realpath ../bin/mountsctl)"

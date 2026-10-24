#!/bin/sh
# Restore the frozen Visio reference (WP-01-T03): start mondrian-win from a QEMU internal snapshot,
# including memory, so the signed-in desktop session needed for Visio automation comes back with it.
# Restoring into an already-running VM (monitor `loadvm`) aborts QEMU on this device set; stop the VM
# first (`limactl stop mondrian-win`) and use this script instead.
set -eu
TAG="${1:-m0-reference-20261025}"
WRAPPER="$(mktemp -t mondrian-loadvm)"
trap 'rm -f "$WRAPPER"' EXIT
printf '#!/bin/sh\nexec /Users/acousland/.lima/mondrian-win/qemu-mondrian "$@" -loadvm %s\n' "$TAG" > "$WRAPPER"
chmod +x "$WRAPPER"
QEMU_SYSTEM_AARCH64="$WRAPPER" /opt/homebrew/bin/limactl start --tty=false mondrian-win

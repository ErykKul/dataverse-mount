#!/bin/bash
# unmount.sh — stop whichever mount container is running and clean up
# any stale FUSE mount left on ./data.
#
# Safe to run at any time; idempotent.
set -uo pipefail

cd "$(dirname "$0")"

DATA_DIR="${DATA_DIR:-./data}"

stopped=0
for name in dv-mount dv-mount-globus; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "Stopping container $name…"
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    stopped=1
  fi
done

# If the container died uncleanly, the FUSE mount can linger on the host.
if [[ -d "$DATA_DIR" ]] && mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo "Unmounting stale FUSE mount at $DATA_DIR…"
  fusermount3 -uz "$DATA_DIR" 2>/dev/null \
    || fusermount  -uz "$DATA_DIR" 2>/dev/null \
    || echo "warn: could not unmount $DATA_DIR (may need sudo umount)"
fi

if [[ $stopped -eq 0 ]] && ! mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo "Nothing to unmount."
fi

#!/usr/bin/env bash
# Local-development shim for scripts/seat-storage.sh.
#
# On the box, seat storage is plain shell: provision.sh runs seat-storage.sh as
# root and the Docker daemon, running in the host's mount namespace, sees the
# mounts. There is nothing to shim.
#
# On a developer laptop, Docker runs inside a VM and -- this is the part that
# wastes an afternoon if you do not know it -- dockerd lives in its OWN mount
# namespace, not PID 1's. A loop mount made in the VM's init namespace is
# invisible to the daemon, so the bind-mount silently resolves to the
# underlying directory instead: the student container comes up with the whole
# 1 TB VM disk at /home/jovyan and no limit at all, while every command
# reports success. Verified directly: PID 1 was mnt:[4026531841] and dockerd
# mnt:[4026532553].
#
# So the mount has to happen in dockerd's namespace. Everything else is the
# same script, shipped in via base64 so there is one implementation.
#
#   ./scripts/dev-seats.sh setup <seats> <gib> [root]
#   ./scripts/dev-seats.sh status|teardown [root]
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT_LOCAL="${LAB_DEV_SEAT_ROOT:-/var/lib/lab-seats}"
[ $# -ge 1 ] || { echo "usage: $0 {setup <seats> <gib> | status | teardown} [root]" >&2; exit 2; }

CMD="$1"; shift
case "$CMD" in
    setup)  [ $# -ge 2 ] || { echo "setup needs <seats> <gib>" >&2; exit 2; }
            ARGS="setup $1 $2 ${3:-$ROOT_LOCAL}" ;;
    status|teardown) ARGS="$CMD ${1:-$ROOT_LOCAL}" ;;
    *) echo "unknown command: $CMD" >&2; exit 2 ;;
esac

SCRIPT_B64="$(base64 < scripts/seat-storage.sh | tr -d '\n')"

docker run --rm --privileged --pid=host \
    -e SCRIPT_B64="$SCRIPT_B64" -e ARGS="$ARGS" \
    ubuntu:24.04 bash -c '
set -euo pipefail
pid=$(ps -eo pid,comm | awk "\$2==\"dockerd\"{print \$1; exit}")
[ -n "$pid" ] || { echo "could not find dockerd; is Docker Desktop running?" >&2; exit 1; }
echo "$SCRIPT_B64" | base64 -d > /tmp/seat-storage.sh
chmod +x /tmp/seat-storage.sh
# /tmp is this container is not dockerd s /tmp, so hand the script over stdin.
nsenter -t "$pid" -m -- /bin/bash -s -- $ARGS < /tmp/seat-storage.sh
'

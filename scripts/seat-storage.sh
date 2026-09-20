#!/usr/bin/env bash
# Per-seat storage: give every student a filesystem of their own, so the disk
# one student fills is their own and nobody else's.
#
# WHY NOT PROJECT QUOTAS. The obvious answer is ext4/XFS project quotas on a
# shared filesystem. They are thinner (unused seat space stays available) and
# need no loop devices. They were rejected for one reason: they cannot be
# tested anywhere but a real instance. Docker Desktop's linuxkit kernel is
# built without CONFIG_QUOTA/CONFIG_QFMT_V2, so `mount -o prjquota` fails
# outright and the local suite could never prove the limit is applied. A limit
# that only production can verify is a limit that silently stops being applied.
#
# A loop-mounted filesystem needs no quota subsystem at all: the filesystem's
# size IS the limit, enforced by ENOSPC, and it behaves identically on
# linuxkit and on Ubuntu. `scripts/test-containment.sh` proves it every run.
#
# Cost of the trade: seat space is preallocated, not shared. A seat sized 5 GiB
# holds 5 GiB whether the student uses it or not. `lab_disk_gib` already
# budgets base + N x per-seat, so the root volume is sized for exactly this.
#
#   seat-storage.sh setup <seats> <gib-per-seat> [root]
#   seat-storage.sh status [root]
#   seat-storage.sh teardown [root]
set -euo pipefail

ROOT_DEFAULT=/srv/lab
UID_JOVYAN=1000     # the student image's NB_UID
GID_USERS=100       # ...and its group

seat_name() { printf 'student%02d' "$1"; }

# `mountpoint` is not present in every environment this runs in -- notably the
# Docker Desktop VM namespace used for local testing. /proc/mounts is.
is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

setup() {
    local seats="$1" gib="$2" root="${3:-$ROOT_DEFAULT}"
    [ "$seats" -ge 1 ] || { echo "seats must be >= 1" >&2; exit 2; }
    [ "$gib" -ge 1 ]   || { echo "gib-per-seat must be >= 1" >&2; exit 2; }

    mkdir -p "$root/images" "$root/home"

    local i name img mnt
    for i in $(seq 1 "$seats"); do
        name="$(seat_name "$i")"
        img="$root/images/$name.img"
        mnt="$root/home/$name"
        mkdir -p "$mnt"

        # Already mounted from a previous run: leave it and the student's work
        # alone. `up` must be safe to re-run.
        if is_mounted "$mnt"; then
            continue
        fi

        if [ ! -f "$img" ]; then
            # fallocate reserves blocks without writing zeros, so this is
            # near-instant and still NOT sparse -- the space is genuinely
            # committed. A sparse image would let every seat overcommit the
            # same free space, which is the failure this exists to prevent.
            fallocate -l "${gib}G" "$img"
            # -E nodiscard is load-bearing, not tuning. mke2fs discards by
            # default, which on a file means punching holes straight through
            # the blocks fallocate just reserved: measured 268435456 bytes
            # before mkfs and 339968 after. The image goes sparse, every seat
            # silently overcommits the same free space, and the containment
            # this script exists to provide quietly stops being real.
            mkfs.ext4 -q -m 0 -E nodiscard -L "$name" "$img"
        fi

        mount -o loop "$img" "$mnt"
        # The student container runs as jovyan(1000):users(100). A fresh ext4
        # is root-owned, and a home the student cannot write is a seat that
        # fails at first login.
        chown "$UID_JOVYAN:$GID_USERS" "$mnt"
        chmod 0755 "$mnt"
    done

    # Survive a reboot mid-class. nofail so a bad image can never stop the box
    # from booting -- one broken seat is recoverable, an unbootable host is not.
    if [ -w /etc/fstab ]; then
        for i in $(seq 1 "$seats"); do
            name="$(seat_name "$i")"
            grep -q "$root/home/$name " /etc/fstab 2>/dev/null && continue
            echo "$root/images/$name.img $root/home/$name ext4 loop,nofail 0 0" >> /etc/fstab
        done
    fi

    echo "seat storage ready: $seats seats x ${gib} GiB at $root/home"
}

status() {
    local root="${1:-$ROOT_DEFAULT}"
    [ -d "$root/home" ] || { echo "no seat storage at $root"; return 0; }
    printf '%-14s %-10s %-8s %-8s %s\n' SEAT MOUNTED SIZE USED AVAIL
    local mnt name
    for mnt in "$root"/home/*/; do
        [ -d "$mnt" ] || continue
        # The glob yields a trailing slash; /proc/mounts records the path
        # without one, so an unstripped compare reports every mounted seat as
        # unmounted -- correct storage, lying status.
        mnt="${mnt%/}"
        name="$(basename "$mnt")"
        if is_mounted "$mnt"; then
            # shellcheck disable=SC2046
            printf '%-14s %-10s %-8s %-8s %s\n' "$name" yes \
                $(df -h --output=size,used,avail "$mnt" | tail -1)
        else
            printf '%-14s %-10s\n' "$name" NO
        fi
    done
}

teardown() {
    local root="${1:-$ROOT_DEFAULT}"
    local mnt name
    for mnt in "$root"/home/*/; do
        [ -d "$mnt" ] || continue
        mnt="${mnt%/}"
        name="$(basename "$mnt")"
        is_mounted "$mnt" && umount "$mnt" 2>/dev/null || true
        sed -i "\#$root/home/$name #d" /etc/fstab 2>/dev/null || true
    done
    rm -rf "$root/images" "$root/home"
    echo "seat storage removed from $root"
}

case "${1:-}" in
    setup)    shift; setup "$@" ;;
    status)   shift; status "$@" ;;
    teardown) shift; teardown "$@" ;;
    *) echo "usage: $0 {setup <seats> <gib> [root] | status [root] | teardown [root]}" >&2; exit 2 ;;
esac

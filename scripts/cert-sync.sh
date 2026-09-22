#!/usr/bin/env bash
# Keep Caddy's TLS state across instances. Runs ON the box, as root.
#
#   cert-sync.sh restore   S3 -> /var/lib/caddy   (before Caddy starts)
#   cert-sync.sh save      /var/lib/caddy -> S3   (timer, `up`, `down`)
#
# Why: every `workshop down` destroys the instance, and with it the
# certificate. Let's Encrypt allows 5 new certificates per hostname per week,
# globally, with no override. Without this, a few `up`s in a week lock the
# real certificate out for days. With it, a certificate is issued once and
# then renewed, and renewals (via ARI, which Caddy uses) are not counted.
#
# What is synced: Caddy's whole data directory -- certificates, keys, ACME
# account, OCSP staples -- because the ACME account is what makes a renewal a
# renewal. Both the production and staging issuers live in separate
# subdirectories, so `--staging` and real runs never collide.
#
# Never fatal. Caddy starts either way; without a restored certificate it
# simply requests one, which is what happened before this script existed.
set -uo pipefail

BUCKET_FILE="${LAB_CERT_BUCKET_FILE:-/etc/lab/cert-bucket}"
CADDY_HOME="${LAB_CADDY_HOME:-/var/lib/caddy}"
CADDY_DATA="$CADDY_HOME/.local/share/caddy"
CADDY_USER="${LAB_CADDY_USER:-caddy}"
LOCK="${LAB_CERT_LOCK:-/run/lab-cert-sync.lock}"

log() { echo "[cert-sync] $*"; }

[ -r "$BUCKET_FILE" ] || { log "no $BUCKET_FILE; nothing to do"; exit 0; }
BUCKET="$(tr -d '[:space:]' < "$BUCKET_FILE")"
[ -n "$BUCKET" ] || { log "$BUCKET_FILE is empty; nothing to do"; exit 0; }
DEST="s3://${BUCKET}/caddy"

# A restore at boot and the save timer could overlap; make them take turns.
exec 9>"$LOCK"; flock 9

case "${1:-}" in
restore)
    mkdir -p "$CADDY_DATA"
    # locks/ are Caddy's own advisory locks from a previous box; restoring them
    # would make Caddy think another process holds the certificate.
    if out="$(aws s3 sync "$DEST/" "$CADDY_DATA/" --exclude 'locks/*' --no-progress 2>&1)"; then
        chown -R "$CADDY_USER:$CADDY_USER" "$CADDY_HOME"
        find "$CADDY_DATA" -type d -exec chmod 700 {} +
        find "$CADDY_DATA" -type f -exec chmod 600 {} +
        n="$(find "$CADDY_DATA/certificates" -name '*.crt' 2>/dev/null | wc -l | tr -d ' ')"
        log "restored from $DEST ($n certificate(s))"
    else
        log "WARNING: restore from $DEST failed; Caddy will request a certificate: $out"
    fi
    ;;
save)
    # Only once there is something worth keeping. Syncing an empty directory
    # would be harmless (no --delete), but say so rather than look like a save.
    if [ ! -d "$CADDY_DATA/certificates" ]; then
        log "no certificates yet; nothing to save"
        exit 0
    fi
    if out="$(aws s3 sync "$CADDY_DATA/" "$DEST/" --exclude 'locks/*' --no-progress 2>&1)"; then
        [ -n "$out" ] && log "saved to $DEST" || true
    else
        log "WARNING: save to $DEST failed: $out"
    fi
    ;;
*)
    echo "usage: $0 restore|save" >&2; exit 2 ;;
esac
exit 0

#!/usr/bin/env bash
# Runs ON the build instance, as root, to produce the workshop AMI.
#
# Everything slow or network-dependent happens here, once, the day before a
# workshop -- not at spin-up. That is the whole point of baking an AMI: `up`
# should be a launch, not an install, and a workshop should not depend on apt,
# npm, NodeSource and Docker Hub all being healthy on the morning.
#
#   provision.sh <domain> <cert-bucket>
set -euxo pipefail

DOMAIN="${1:?usage: provision.sh <domain> <cert-bucket>}"
CERT_BUCKET="${2:?usage: provision.sh <domain> <cert-bucket>}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https

# --- Host swap ---------------------------------------------------------------
# A safety net for the HOST's processes only -- dockerd, the hub, Caddy. Student
# containers are launched with memswap_limit == mem_limit, so they cannot touch
# this; see hub/jupyterhub_config.py.
#
# This is NOT the reference project's 8 GiB swapfile. That one was load-bearing,
# because a shared box with no per-user caps could be livelocked by one runaway
# agent. Per-container cgroup limits make that structurally impossible here, so
# swap goes back to being what it should be: headroom for the host if the 4 GiB
# overhead budget in lib-size.sh turns out to be short on some cohort. A class
# should degrade, not stop.
#
# swappiness 10: use it under real pressure, not as a routine tier.
if ! swapon --show | grep -q .; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-lab-swappiness.conf

# --- Docker (official repo; Ubuntu's docker.io lags) -------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# --- AWS CLI -----------------------------------------------------------------
# Needed so the instance can fetch the workshop API key from Parameter Store
# under its own IAM role. Ubuntu 24.04 ships no installable awscli package.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
apt-get install -y unzip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -f /tmp/awscliv2.zip
find /tmp/aws -depth -delete 2>/dev/null || true
/usr/local/bin/aws --version

# --- Caddy -------------------------------------------------------------------
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# Production Caddyfile. `workshop up --staging` overwrites this with the Let's
# Encrypt staging endpoint before starting Caddy, which is what you want while
# iterating: the production endpoint allows only 5 duplicate certificates per
# week for the same hostname, and a debugging loop will burn through that.
cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
    reverse_proxy 127.0.0.1:8000
}
CADDY

# The certificate outlives the box. Before Caddy starts, pull its state from
# the durable stack's bucket; every five minutes, and at `up` and `down`, push
# it back. See scripts/cert-sync.sh for why. The bucket name is baked in here
# because Caddy starts at boot, before `workshop up` has talked to the box.
install -m 0755 /opt/lab/scripts/cert-sync.sh /opt/lab/cert-sync.sh
mkdir -p /etc/lab
echo "$CERT_BUCKET" > /etc/lab/cert-bucket
mkdir -p /etc/systemd/system/caddy.service.d
# The + prefix runs the restore as root regardless of the service's User=.
cat > /etc/systemd/system/caddy.service.d/lab-cert.conf <<'UNIT'
[Service]
ExecStartPre=+/opt/lab/cert-sync.sh restore
UNIT
cat > /etc/systemd/system/lab-cert-save.service <<'UNIT'
[Unit]
Description=Save Caddy's TLS state to the workshop certificate bucket

[Service]
Type=oneshot
ExecStart=/opt/lab/cert-sync.sh save
UNIT
cat > /etc/systemd/system/lab-cert-save.timer <<'UNIT'
[Unit]
Description=Save Caddy's TLS state every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable lab-cert-save.timer

# Caddy is enabled but NOT started here: during the build, DNS does not point at
# this temporary instance, so an ACME attempt would fail and back off. It starts
# on the next boot -- restoring the saved certificate first -- and `workshop up`
# restarts it once the A record is in place.
systemctl enable caddy
systemctl stop caddy || true

# --- Lab images --------------------------------------------------------------
# /opt/lab was unpacked by `workshop build` before this script ran.
cd /opt/lab
docker build -f student-image/Dockerfile -t lab-student:latest .
docker build -t lab-hub:latest ./hub

# A placeholder so the compose bind-mount has something to attach to; `workshop
# up` overwrites it with the real cohort's codes.
[ -f /opt/lab/hub/codes.json ] || echo '{}' > /opt/lab/hub/codes.json

docker image prune -f

# Do not leave the hub running in the image: the AMI should boot into a known
# stopped state and let `workshop up` start it with that cohort's parameters.
cd /opt/lab && docker compose down || true

# --- Tidy for imaging --------------------------------------------------------
apt-get clean
cloud-init clean --logs || true
rm -f /home/ubuntu/.ssh/authorized_keys.bak || true
truncate -s 0 /var/log/*.log 2>/dev/null || true

echo "PROVISION_OK"

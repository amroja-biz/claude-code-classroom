#!/usr/bin/env bash
# Runs ON the build instance, as root, to produce the workshop AMI.
#
# Everything slow or network-dependent happens here, once, the day before a
# workshop -- not at spin-up. That is the whole point of baking an AMI: `up`
# should be a launch, not an install, and a workshop should not depend on apt,
# npm, NodeSource and Docker Hub all being healthy on the morning.
#
#   provision.sh <domain>
set -euxo pipefail

DOMAIN="${1:?usage: provision.sh <domain>}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https

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

# Caddy is enabled but NOT started here: during the build, DNS does not point at
# this temporary instance, so an ACME attempt would fail and back off. It starts
# on the next boot, and `workshop up` restarts it once the A record is in place.
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

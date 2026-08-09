#!/usr/bin/env bash
# Phase 3: install and start Gitea (native binary + systemd).
# Run as root: sudo bash 03-gitea.sh
#
# - Binary in /usr/local/bin/gitea, runs as the 'gitea' system user.
# - SQLite backend (fine for a lab; use Postgres/MySQL in production).
# - HTTP bound to 127.0.0.1:3000 only (nginx will front it on :8091).
# - Built-in SSH server on :2222 (system sshd already owns :22).
# - INSTALL_LOCK=true skips the web setup wizard; LDAP auth source and
#   per-repo unit permissions are wired up in a later phase.
#
# Safe to rerun:
# - binary download/verify is skipped if the right version is already installed.
# - app.ini is written ONCE. If it already exists, it is left untouched:
#   SECRET_KEY/INTERNAL_TOKEN/JWT_SECRET encrypt data already stored in the
#   DB (sessions, 2FA, mirror credentials, etc), so regenerating them on a
#   rerun would silently corrupt that data. To force a genuine reconfigure,
#   remove /etc/gitea/app.ini yourself first.
# - the systemd unit is idempotently rewritten; the service is only
#   (re)started if it isn't already active.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

GITEA_VERSION="1.27.1"
GITEA_SHA256="86a7ac26e7f9c9cca0f56c4fac07fff205d5fc3bca0e54af23a204f07b833bc9"
EXTERNAL_PORT="8091"   # nginx will listen here and proxy to 127.0.0.1:3000

# --- 1. download + verify binary (skip if already installed) ---
if [ -x /usr/local/bin/gitea ] && /usr/local/bin/gitea --version 2>/dev/null | grep -q "version ${GITEA_VERSION} "; then
  log "gitea ${GITEA_VERSION} already installed at /usr/local/bin/gitea, skipping download."
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/gitea" \
    "https://dl.gitea.com/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64"
  echo "${GITEA_SHA256}  $TMP/gitea" | sha256sum -c - \
    || die "checksum mismatch for downloaded gitea binary"
  install -o root -g root -m 755 "$TMP/gitea" /usr/local/bin/gitea
  log "installed gitea ${GITEA_VERSION}"
fi
/usr/local/bin/gitea --version

# --- 2. directories ---
install -d -o gitea -g gitea -m 750 /var/lib/gitea/custom
install -d -o gitea -g gitea -m 750 /var/lib/gitea/data
install -d -o gitea -g gitea -m 750 /var/lib/gitea/log
install -d -o root  -g gitea -m 750 /etc/gitea

# --- 3./4. app.ini: written once, never clobbered on rerun ---
if [ -f /etc/gitea/app.ini ]; then
  log "/etc/gitea/app.ini already exists, leaving it untouched."
else
  SECRET_KEY=$(sudo -u gitea /usr/local/bin/gitea generate secret SECRET_KEY)
  INTERNAL_TOKEN=$(sudo -u gitea /usr/local/bin/gitea generate secret INTERNAL_TOKEN)
  JWT_SECRET=$(sudo -u gitea /usr/local/bin/gitea generate secret JWT_SECRET)

  cat > /etc/gitea/app.ini <<EOF
APP_NAME = Gerrit/Gitea Lab
RUN_MODE = prod
RUN_USER = gitea

[server]
PROTOCOL         = http
DOMAIN           = ${HOST_FQDN}
HTTP_ADDR        = 127.0.0.1
HTTP_PORT        = 3000
ROOT_URL         = http://${HOST_FQDN}:${EXTERNAL_PORT}/
START_SSH_SERVER = true
SSH_DOMAIN       = ${HOST_FQDN}
SSH_PORT         = 2222
SSH_LISTEN_PORT  = 2222

[database]
DB_TYPE = sqlite3
PATH    = /var/lib/gitea/data/gitea.db

[repository]
ROOT = /var/lib/gitea/data/gitea-repositories

[security]
INSTALL_LOCK   = true
SECRET_KEY     = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[service]
DISABLE_REGISTRATION            = true
REQUIRE_SIGNIN_VIEW             = false
ENABLE_NOTIFY_MAIL               = false

[log]
ROOT_PATH = /var/lib/gitea/log
MODE      = file
EOF

  chown gitea:gitea /etc/gitea/app.ini
  chmod 640 /etc/gitea/app.ini
  log "wrote /etc/gitea/app.ini"
fi

# --- 5. systemd unit (idempotent to rewrite; no secrets in it) ---
cat > /etc/systemd/system/gitea.service <<'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
RestartSec=2s
Type=simple
User=gitea
Group=gitea
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=gitea HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if systemctl is-active --quiet gitea; then
  log "gitea service already active, leaving it running."
else
  systemctl reset-failed gitea 2>/dev/null || true
  systemctl enable --now gitea
fi

# --- 6. wait for it to come up (bounded, with a clear failure message) ---
wait_for_http http://127.0.0.1:3000/api/healthz 30 \
  "systemctl status gitea --no-pager -l && journalctl -u gitea -n 80 --no-pager"

# --- 7. local fallback admin (separate from LDAP-derived accounts) ---
if sudo -u gitea /usr/local/bin/gitea admin user list --config /etc/gitea/app.ini \
     | awk 'NR>1{print $2}' | grep -qx gitea-admin; then
  log "local admin 'gitea-admin' already exists, skipping creation."
else
  sudo -u gitea /usr/local/bin/gitea admin user create \
    --config /etc/gitea/app.ini \
    --username gitea-admin \
    --password 'ChangeMe123!' \
    --email gitea-admin@tkos.co.il \
    --admin --must-change-password=false
  log "created local admin gitea-admin / ChangeMe123! (test-lab fallback, not LDAP-backed)"
fi

#!/usr/bin/env bash
# Production hardening: self-signed TLS on the nginx reverse proxy.
# Run as root: sudo bash nginx-tls.sh
#
# Adds HTTPS on :8453 (Gerrit) and :8454 (Gitea), alongside -- not
# replacing -- the existing plain-HTTP :8090/:8091 from scripts/install/08.
# Purely additive on purpose: Gerrit's canonicalWebUrl, the replication
# URL, and every script/doc in this project reference the http:// URLs,
# and changing those is real production work (see INSTALL.md's real-
# TLS guidance) that needs a real CA-signed cert to be worth doing, not
# a self-signed one a browser will always warn about. This script exists
# to demonstrate TLS termination actually works end to end, not to
# become the new default.
#
# Not grabbing :443: it's free on this host right now, but doesn't map
# cleanly to "two services" without real per-service hostnames for SNI
# (this lab uses one hostname, differentiated by port, the same reason
# :8090/:8091 exist instead of :80/:443 in the first place) -- and
# claiming the well-known HTTPS port on a host with other things on it
# is the same overreach avoided for :80 with Apache2.
#
# Safe to rerun: cert generation is skipped if a valid cert already
# exists; the nginx site file is plain config, always just rewritten;
# `nginx -t` validates before any reload.
#
# Host forwarded as $http_host, not $host -- same fix as
# scripts/install/08-nginx.sh's HTTP blocks, and for the same reason:
# these are non-standard ports too, so nginx's port-stripped $host
# would mismatch the browser's Origin header and trip Gitea's CSRF
# check on every state-changing request.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

SSL_DIR="/etc/nginx/ssl"
CERT="$SSL_DIR/gerrit-gitea-lab.crt"
KEY="$SSL_DIR/gerrit-gitea-lab.key"
SITE_FILE=/etc/nginx/sites-available/gerrit-gitea-lab.conf

install -d -m 750 "$SSL_DIR"

if [ -f "$CERT" ] && openssl x509 -checkend 86400 -noout -in "$CERT" >/dev/null 2>&1 \
   && openssl x509 -noout -text -in "$CERT" | grep -q "DNS:${HOST_FQDN}"; then
  log "self-signed cert already exists and is valid, reusing it"
else
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=${HOST_FQDN}" \
    -addext "subjectAltName=DNS:${HOST_FQDN},DNS:localhost,IP:127.0.0.1"
  chmod 600 "$KEY"
  chmod 644 "$CERT"
  log "generated a new self-signed cert for ${HOST_FQDN} (10y validity, lab only)"
fi

# Append HTTPS server blocks if not already present -- the HTTP blocks
# from scripts/install/08-nginx.sh stay exactly as they are.
if grep -q "listen 8453 ssl" "$SITE_FILE" 2>/dev/null; then
  log "HTTPS server blocks already present in ${SITE_FILE}"
else
  cat >> "$SITE_FILE" <<EOF

server {
	listen 8453 ssl;
	server_name ${HOST_FQDN};
	client_max_body_size 100m;

	ssl_certificate     ${CERT};
	ssl_certificate_key ${KEY};
	ssl_protocols TLSv1.2 TLSv1.3;

	location / {
		proxy_pass http://127.0.0.1:8080;
		proxy_set_header Host \$http_host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
	}
}

server {
	listen 8454 ssl;
	server_name ${HOST_FQDN};
	client_max_body_size 100m;

	ssl_certificate     ${CERT};
	ssl_certificate_key ${KEY};
	ssl_protocols TLSv1.2 TLSv1.3;

	location / {
		proxy_pass http://127.0.0.1:3000;
		proxy_set_header Host \$http_host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_redirect off;
	}
}
EOF
  log "appended HTTPS server blocks (:8453 Gerrit, :8454 Gitea) to ${SITE_FILE}"
fi

nginx -t
systemctl reload nginx
log "nginx reloaded"

# --- verify: TLS actually terminates and proxies correctly, and the plain-HTTP ports still work ---
GERRIT_TLS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:8453/")
[ "$GERRIT_TLS_CODE" = "200" ] || die "HTTPS Gerrit proxy (:8453) returned HTTP ${GERRIT_TLS_CODE}, expected 200"
GITEA_TLS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:8454/")
[ "$GITEA_TLS_CODE" = "200" ] || die "HTTPS Gitea proxy (:8454) returned HTTP ${GITEA_TLS_CODE}, expected 200"

curl -fs -o /dev/null "http://127.0.0.1:8090/" || die "existing plain-HTTP Gerrit proxy (:8090) broke"
curl -fs -o /dev/null "http://127.0.0.1:8091/" || die "existing plain-HTTP Gitea proxy (:8091) broke"

SAN=$(openssl x509 -noout -text -in "$CERT" | grep "DNS:${HOST_FQDN}" || true)
[ -n "$SAN" ] || die "cert is missing the expected SAN for ${HOST_FQDN}"

log "OK: HTTPS works on :8453 (Gerrit) and :8454 (Gitea) with a valid self-signed cert for ${HOST_FQDN}, and the existing plain-HTTP :8090/:8091 are untouched."

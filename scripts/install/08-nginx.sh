#!/usr/bin/env bash
# Phase 7: nginx reverse proxy for Gerrit (:8090) and Gitea (:8091).
# Run as root: sudo bash 08-nginx.sh
#
# Alt ports, not :80/:443 -- this host already runs an unrelated
# Apache2 on port 80, which stays completely untouched. Gerrit's
# httpd.listenUrl is "proxy-http://..." (set in phase 4), so it trusts
# X-Forwarded-For/-Proto from this proxy; Gitea gets the same headers
# for consistency even though it's less strict about them.
#
# Safe to rerun: the site file is plain config (no secrets, no
# generated values) so it's always just rewritten; `nginx -t` validates
# before any reload, so a bad edit here fails loudly instead of taking
# nginx down.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

SITE_FILE=/etc/nginx/sites-available/gerrit-gitea-lab.conf

cat > "$SITE_FILE" <<EOF
server {
	listen 8090;
	server_name ${HOST_FQDN};
	client_max_body_size 100m;

	location / {
		proxy_pass http://127.0.0.1:8080;
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
	}
}

server {
	listen 8091;
	server_name ${HOST_FQDN};
	client_max_body_size 100m;

	location / {
		proxy_pass http://127.0.0.1:3000;
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_redirect off;
	}
}
EOF
log "wrote ${SITE_FILE}"

ln -sf "$SITE_FILE" /etc/nginx/sites-enabled/gerrit-gitea-lab.conf

# The stock Debian nginx package ships a "default" site listening on
# :80/:443, which fights with the Apache2 already bound to :80 on this
# host -- nginx.service has apparently been failing to start since
# install because of this, unrelated to anything we've configured.
# Disabling it is what actually lets nginx start at all; Apache2 stays
# the sole owner of :80.
if [ -e /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
  log "disabled the stock nginx 'default' site (was conflicting with Apache2 on :80)."
fi

nginx -t
systemctl reset-failed nginx 2>/dev/null || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
log "nginx reloaded"

wait_for_http "http://127.0.0.1:8090/" 15 "curl -v http://127.0.0.1:8090/"
wait_for_http "http://127.0.0.1:8091/" 15 "curl -v http://127.0.0.1:8091/"
log "OK: Gerrit reachable via nginx on :8090, Gitea on :8091 -- port 80/Apache2 untouched."

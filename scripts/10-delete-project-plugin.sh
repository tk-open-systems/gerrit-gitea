#!/usr/bin/env bash
# Enable Gerrit's delete-project plugin (bundled in gerrit.war, but not
# installed during phase 4 -- only 'replication' was requested then).
# Needed for the project-deletion procedure documented in ADMIN.md.
# Run as root: sudo bash 10-delete-project-plugin.sh
#
# Safe to rerun: extracting the jar is a plain overwrite: unzip -o; the
# plugin is only (re)loaded via a Gerrit restart if it wasn't already
# active.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

SITE=/var/lib/gerrit
GERRIT_URL="http://127.0.0.1:8080"
TEST_PW="ChangeMe123!"   # test-lab only, see scripts/02-openldap.sh

sudo -u gerrit unzip -o -q "$SITE/bin/gerrit.war" WEB-INF/plugins/delete-project.jar -d "$SITE"
sudo -u gerrit mv "$SITE/WEB-INF/plugins/delete-project.jar" "$SITE/plugins/delete-project.jar"
rmdir "$SITE/WEB-INF/plugins" "$SITE/WEB-INF" 2>/dev/null || true
log "extracted delete-project.jar into $SITE/plugins/"

if curl -fsS -u "carol:${TEST_PW}" "${GERRIT_URL}/a/plugins/?all" | tail -n +2 \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "delete-project" in d and not d["delete-project"].get("disabled") else 1)'; then
  log "delete-project already loaded and enabled."
else
  systemctl restart gerrit
  wait_for_http "${GERRIT_URL}/" 120 \
    "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
  curl -fsS -u "carol:${TEST_PW}" "${GERRIT_URL}/a/plugins/?all" | tail -n +2 \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "delete-project" in d and not d["delete-project"].get("disabled") else 1)' \
    || die "delete-project still not loaded after restart -- check: journalctl -u gerrit -n 100 --no-pager"
  log "delete-project plugin loaded and enabled."
fi

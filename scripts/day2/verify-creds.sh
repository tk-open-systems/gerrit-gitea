#!/usr/bin/env bash
# Standalone credential checker: verifies whichever of LDAP_ADMIN_PW,
# GERRIT_ADMIN_PW, GITEA_ADMIN_PW are currently set in the environment,
# and names exactly which one (if any) is wrong -- instead of finding
# out indirectly, several steps later, from a bare curl/ldap error deep
# inside project-lifecycle.sh or user-lifecycle.sh that gives no hint
# it's a password problem at all, let alone which password.
#
# Run as root on the Gerrit/Gitea host, with whichever of the three
# passwords you want checked set as env vars (any left unset are
# skipped, not failed -- so e.g. `GERRIT_ADMIN_PW='...' bash
# verify-creds.sh` alone is a fine way to check just that one):
#
#   sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
#     bash verify-creds.sh
#
# Exit status: 0 if every credential that was set checked out, 1 if at
# least one was wrong (or none were set at all -- nothing to check is
# itself worth flagging, since that's almost always a forgotten env var
# rather than intentional).
set -euo pipefail
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib.sh"
require_root

ADMIN_DN="cn=admin,${BASE_DN}"
GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"
GERRIT_ADMIN_USER="${GERRIT_ADMIN_USER:-gerrit-bot}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"

checked=0
failed=0

if [ -n "${LDAP_ADMIN_PW:-}" ]; then
  checked=1
  verify_ldap_cred "LDAP_ADMIN_PW (${ADMIN_DN})" "$ADMIN_DN" "$LDAP_ADMIN_PW" || failed=1
else
  log "LDAP_ADMIN_PW not set, skipping"
fi

if [ -n "${GERRIT_ADMIN_PW:-}" ]; then
  checked=1
  verify_http_cred "GERRIT_ADMIN_PW (${GERRIT_ADMIN_USER})" "${GERRIT_URL}/" "${GERRIT_URL}/a/accounts/self" "$GERRIT_ADMIN_USER" "$GERRIT_ADMIN_PW" || failed=1
else
  log "GERRIT_ADMIN_PW not set, skipping"
fi

if [ -n "${GITEA_ADMIN_PW:-}" ]; then
  checked=1
  verify_http_cred "GITEA_ADMIN_PW (${GITEA_ADMIN_USER})" "${GITEA_URL}/" "${GITEA_URL}/api/v1/user" "$GITEA_ADMIN_USER" "$GITEA_ADMIN_PW" || failed=1
else
  log "GITEA_ADMIN_PW not set, skipping"
fi

[ "$checked" -eq 1 ] || die "none of LDAP_ADMIN_PW / GERRIT_ADMIN_PW / GITEA_ADMIN_PW are set -- nothing to check. Set at least one, e.g.:
  sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' bash ${SCRIPT_NAME}"

if [ "$failed" -eq 1 ]; then
  die "at least one credential above is wrong -- see the WARNING line(s) for exactly which, and why. Fix it (see this script's own header comment, or project-lifecycle.sh/user-lifecycle.sh's header comments, for where each password comes from) and rerun."
fi

log "all set credentials verified OK"

#!/usr/bin/env bash
# Phase 5b: Gitea LDAP auth source + LDAP-group-to-team mapping.
# Run as root: sudo bash 06-gitea-ldap.sh
#
# Creates a Gitea org ("engineering") with a "Developers" team scoped to
# WORKFLOW.md's per-unit model (Code read-only, Issues/Wiki/Projects
# write, Pull Requests excluded), wires the phase-2 LDAP directory as an
# auth source with group sync enabled, and maps:
#   cn=developers,ou=groups,...  -> engineering/Developers
#   cn=admins,ou=groups,...      -> engineering/Owners  (built-in, full org admin)
# Gitea never needs a code-write ACL here since the mirrored repo will be
# read-only for everyone except the replication service account (phase 6);
# and this intentionally does NOT grant Gitea *instance* admin via LDAP --
# that stays on the local 'gitea-admin' fallback account from phase 3.
# Disabling the Pull Requests unit repo-wide (not just for this team)
# happens in phase 6 once the mirrored repo actually exists.
#
# Safe to rerun: org/team creation is skip-if-exists via the REST API;
# the LDAP source is skip-if-exists by name (to change its settings
# later, edit by hand with `gitea admin auth update-ldap` -- a bare
# rerun of this script won't pick up edits to the flags below once the
# source already exists, to avoid silently altering a live auth source).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

BASE_DN="dc=tkos,dc=co,dc=il"
DEV_GROUP_DN="cn=developers,ou=groups,${BASE_DN}"
ADMIN_GROUP_DN="cn=admins,ou=groups,${BASE_DN}"
LDAP_BIND_DN="cn=admin,${BASE_DN}"
TEST_PW="ChangeMe123!"   # test-lab only, see scripts/02-openldap.sh
GITEA_URL="http://127.0.0.1:3000"
GITEA_ADMIN="gitea-admin"
ORG="engineering"
GITEA="/usr/local/bin/gitea"
APP_INI="/etc/gitea/app.ini"

api() { curl -fsS -u "${GITEA_ADMIN}:${TEST_PW}" "$@"; }

# --- 1. org ---
if api -o /dev/null -w '' "${GITEA_URL}/api/v1/orgs/${ORG}" 2>/dev/null; then
  log "org '${ORG}' already exists."
else
  api -X POST -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ORG}\"}" "${GITEA_URL}/api/v1/orgs" >/dev/null
  log "created org '${ORG}'."
fi

# --- 2. Developers team: code read-only, issues/wiki/projects write, no PRs ---
if api "${GITEA_URL}/api/v1/orgs/${ORG}/teams" | grep -q '"name":"Developers"'; then
  log "team '${ORG}/Developers' already exists."
else
  api -X POST -H 'Content-Type: application/json' -d '{
    "name": "Developers",
    "description": "Plan/discuss access; code is a read-only Gerrit mirror.",
    "permission": "read",
    "units_map": {
      "repo.code": "read",
      "repo.issues": "write",
      "repo.wiki": "write",
      "repo.projects": "write"
    }
  }' "${GITEA_URL}/api/v1/orgs/${ORG}/teams" >/dev/null
  log "created team '${ORG}/Developers'."
fi

# --- 3. LDAP auth source with group sync ---
if sudo -u gitea "$GITEA" admin auth list --config "$APP_INI" | awk '{print $2}' | grep -qx LDAP; then
  log "auth source 'LDAP' already exists, leaving it as configured."
else
  GROUP_TEAM_MAP=$(printf '{"%s":{"%s":["Developers"]},"%s":{"%s":["Owners"]}}' \
    "$DEV_GROUP_DN" "$ORG" "$ADMIN_GROUP_DN" "$ORG")

  sudo -u gitea "$GITEA" admin auth add-ldap \
    --config "$APP_INI" \
    --name LDAP \
    --active \
    --security-protocol unencrypted \
    --host localhost \
    --port 389 \
    --bind-dn "$LDAP_BIND_DN" \
    --bind-password "$TEST_PW" \
    --user-search-base "ou=people,${BASE_DN}" \
    --user-filter '(&(objectClass=inetOrgPerson)(uid=%s))' \
    --username-attribute uid \
    --surname-attribute sn \
    --email-attribute mail \
    --synchronize-users \
    --enable-groups \
    --group-search-base-dn "ou=groups,${BASE_DN}" \
    --group-member-attribute member \
    --group-user-attribute dn \
    --group-filter '(objectClass=groupOfNames)' \
    --group-team-map "$GROUP_TEAM_MAP" \
    --group-team-map-removal
  log "created LDAP auth source with group sync (developers -> ${ORG}/Developers, admins -> ${ORG}/Owners)."
fi

# --- 4. force-provision alice/bob/carol (LDAP auth auto-creates + syncs teams on login) ---
for u in alice bob carol; do
  curl -fsS -u "${u}:${TEST_PW}" -o /dev/null "${GITEA_URL}/api/v1/user"
  log "provisioned/synced Gitea account for ${u}."
done

# --- 5. verify team membership synced as expected ---
DEV_MEMBERS=$(api "${GITEA_URL}/api/v1/orgs/${ORG}/teams" \
  | python3 -c 'import json,sys; teams=json.load(sys.stdin); print([t["id"] for t in teams if t["name"]=="Developers"][0])')
OWNER_MEMBERS_ID=$(api "${GITEA_URL}/api/v1/orgs/${ORG}/teams" \
  | python3 -c 'import json,sys; teams=json.load(sys.stdin); print([t["id"] for t in teams if t["name"]=="Owners"][0])')

api "${GITEA_URL}/api/v1/teams/${DEV_MEMBERS}/members" | grep -q '"login":"alice"' \
  && log "verified: alice is in ${ORG}/Developers" \
  || die "alice is NOT in ${ORG}/Developers -- check LDAP group sync"
api "${GITEA_URL}/api/v1/teams/${DEV_MEMBERS}/members" | grep -q '"login":"bob"' \
  && log "verified: bob is in ${ORG}/Developers" \
  || die "bob is NOT in ${ORG}/Developers -- check LDAP group sync"
api "${GITEA_URL}/api/v1/teams/${OWNER_MEMBERS_ID}/members" | grep -q '"login":"carol"' \
  && log "verified: carol is in ${ORG}/Owners" \
  || die "carol is NOT in ${ORG}/Owners -- check LDAP group sync"

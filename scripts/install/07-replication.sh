#!/usr/bin/env bash
# Phase 6: Gerrit replication plugin -> Gitea (push-based, merge-only mirror).
# Run as root: sudo bash 07-replication.sh
#
# - Dedicated Gitea LOCAL account 'gerrit-replication' is the only
#   identity with Write on the mirrored repos' Code unit (via its own
#   org-wide "Replication" team); every human's Code unit stays
#   read-only (Developers team) or governed by their own admin trust
#   (Owners team) -- this is the "authenticate the replication job as
#   a dedicated service account" design from WORKFLOW.md section 2.
# - Gitea's ENABLE_PUSH_CREATE_ORG lets that account's first push
#   auto-create the repo under the 'engineering' org.
# - replication.config scopes push refspecs to refs/heads/*:refs/heads/*
#   and refs/tags/*:refs/tags/* only -- refs/changes/* is never
#   included, so Gitea only ever sees a ref move when a Gerrit change
#   is actually submitted, not on every patchset. All-Projects/All-Users
#   (Gerrit's own metadata repos) are excluded from replication.
# - Ends by creating a throwaway 'replication-test' Gerrit project,
#   pushing+submitting a change through it, and confirming the commit
#   lands in Gitea -- so a config mistake is caught here, not in the
#   final smoke test.
#
# Safe to rerun: user/team creation is skip-if-exists; app.ini and
# replication.config edits are idempotent (grep/git-config guarded);
# gerrit is only restarted if the replication config actually changed;
# the throwaway test project is skip-if-exists too, so a rerun after
# a successful run just re-verifies rather than erroring.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

SITE=/var/lib/gerrit
APP_INI=/etc/gitea/app.ini
GITEA="/usr/local/bin/gitea"
GITEA_URL="http://127.0.0.1:3000"
GITEA_ADMIN="gitea-admin"
ORG="engineering"
REPL_USER="gerrit-replication"
REPL_PW="ChangeMe123!"   # test-lab only
TEST_PW="ChangeMe123!"   # test-lab only, carol's LDAP password (see scripts/install/02-openldap.sh)
GERRIT_URL="http://127.0.0.1:8080"

gitea_api() { curl -fsS -u "${GITEA_ADMIN}:${TEST_PW}" "$@"; }

# --- 1. dedicated Gitea service account for replication ---
if sudo -u gitea "$GITEA" admin user list --config "$APP_INI" \
     | awk 'NR>1{print $2}' | grep -qx "$REPL_USER"; then
  log "Gitea user '${REPL_USER}' already exists."
else
  sudo -u gitea "$GITEA" admin user create \
    --config "$APP_INI" \
    --username "$REPL_USER" \
    --password "$REPL_PW" \
    --email "${REPL_USER}@tkos.co.il" \
    --must-change-password=false
  log "created Gitea local user '${REPL_USER}' (test-lab password, not LDAP-backed)."
fi

# --- 2. allow that account's first push to auto-create the repo under the org ---
if grep -q '^ENABLE_PUSH_CREATE_ORG' "$APP_INI"; then
  log "ENABLE_PUSH_CREATE_ORG already set."
else
  sed -i '/^\[repository\]/a ENABLE_PUSH_CREATE_ORG = true' "$APP_INI"
  log "set ENABLE_PUSH_CREATE_ORG=true, restarting gitea."
  systemctl restart gitea
  wait_for_http "${GITEA_URL}/api/healthz" 30 \
    "systemctl status gitea --no-pager -l && journalctl -u gitea -n 80 --no-pager"
fi

# --- 3. Replication team: Code write only, applies to all (incl. future) org repos ---
TEAMS_JSON=$(gitea_api "${GITEA_URL}/api/v1/orgs/${ORG}/teams")
REPL_TEAM_ID=$(echo "$TEAMS_JSON" | python3 -c 'import json,sys
teams=[t for t in json.load(sys.stdin) if t["name"]=="Replication"]
print(teams[0]["id"] if teams else "")')

if [ -z "$REPL_TEAM_ID" ]; then
  gitea_api -X POST -H 'Content-Type: application/json' -d '{
    "name": "Replication",
    "description": "Write access for the Gerrit replication service account only.",
    "permission": "write",
    "includes_all_repositories": true,
    "can_create_org_repo": true,
    "units_map": { "repo.code": "write" }
  }' "${GITEA_URL}/api/v1/orgs/${ORG}/teams" >/dev/null
  REPL_TEAM_ID=$(gitea_api "${GITEA_URL}/api/v1/orgs/${ORG}/teams" | python3 -c 'import json,sys
teams=[t for t in json.load(sys.stdin) if t["name"]=="Replication"]
print(teams[0]["id"])')
  log "created team '${ORG}/Replication' (includes_all_repositories=true, can_create_org_repo=true)."
else
  log "team '${ORG}/Replication' already exists."
fi

# can_create_org_repo is what actually lets this account's first push
# auto-vivify a repo -- ENABLE_PUSH_CREATE_ORG in app.ini is necessary
# but not sufficient. includes_all_repositories/units_map only govern
# access to repos that already exist, so both flags are required
# together, and re-asserted here (harmless if already set) since a repo
# created before this was set would otherwise silently 404 on push.
gitea_api -X PATCH -H 'Content-Type: application/json' \
  -d '{"can_create_org_repo": true}' \
  "${GITEA_URL}/api/v1/teams/${REPL_TEAM_ID}" >/dev/null

gitea_api -X PUT "${GITEA_URL}/api/v1/teams/${REPL_TEAM_ID}/members/${REPL_USER}" >/dev/null
log "ensured ${REPL_USER} is a member of ${ORG}/Replication."

# --- 3b. fix: Developers team (phase 5) also needs includes_all_repositories=true,
#     otherwise it only applies to repos that existed at team-creation time.
#
# Gitea's team-edit API silently DISCARDS this field if the PATCH body
# doesn't also resend units_map/permission alongside it -- it returns
# HTTP 200 with includes_all_repositories still false, no error at all.
# This bit us for real: an earlier version of this script sent
# includes_all_repositories alone, which silently no-op'd, and every
# script since kept reporting success while Developers-team accounts
# actually got 404 on the repo, its issues, and its wiki (discovered
# only when testing wiki access as alice for WORKFLOW.md section 4 --
# not caught by this script's own logging, which trusted the API's 200
# instead of reading back the result). Always resend the full team
# object, and verify the readback afterward rather than trusting the
# HTTP status alone. ---
DEV_TEAM_ID=$(echo "$TEAMS_JSON" | python3 -c 'import json,sys
teams=[t for t in json.load(sys.stdin) if t["name"]=="Developers"]
print(teams[0]["id"] if teams else "")')
[ -n "$DEV_TEAM_ID" ] || die "Developers team not found -- run scripts/install/06-gitea-ldap.sh first"
gitea_api -X PATCH -H 'Content-Type: application/json' -d '{
    "description": "Plan/discuss access; code is a read-only Gerrit mirror.",
    "permission": "read",
    "includes_all_repositories": true,
    "units_map": {
      "repo.code": "read",
      "repo.issues": "write",
      "repo.wiki": "write",
      "repo.projects": "write"
    }
  }' "${GITEA_URL}/api/v1/teams/${DEV_TEAM_ID}" >/dev/null

gitea_api "${GITEA_URL}/api/v1/teams/${DEV_TEAM_ID}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["includes_all_repositories"] else 1)' \
  || die "includes_all_repositories still false on ${ORG}/Developers after PATCH -- Gitea silently dropped it again"
log "confirmed (via readback, not just HTTP status) '${ORG}/Developers' applies to all org repos."

# --- 4. Gerrit replication.config + secure.config ---
cd "$SITE"
rcfg() { sudo -u gerrit git config -f "$SITE/etc/replication.config" "$@"; }

BEFORE=$(md5sum "$SITE/etc/replication.config" 2>/dev/null || true)

# Password embedded directly in the URL, not left to secure.config's
# remote.<name>.password lookup: empirically, JGit's TransportHttp threw
# "authentication not supported" when only a username was present in the
# URL and the password had to come from secure.config -- this exact
# user:pass@ pattern already works reliably elsewhere in this lab (the
# git operations in scripts/install/05-gerrit-acl.sh and this script's own
# smoke-test push below). replication.config is chmod'd 600 below since
# it now holds a credential.
rcfg remote.gitea.url "http://${REPL_USER}:${REPL_PW}@127.0.0.1:3000/${ORG}/\${name}.git"

# multi-valued key: unset-then-add so reruns don't accumulate duplicates
sudo -u gerrit git config -f "$SITE/etc/replication.config" --unset-all remote.gitea.push 2>/dev/null || true
rcfg --add remote.gitea.push "+refs/heads/*:refs/heads/*"
rcfg --add remote.gitea.push "+refs/tags/*:refs/tags/*"

rcfg remote.gitea.projects '^(?!All-Projects$)(?!All-Users$).*'
rcfg remote.gitea.createMissingRepositories true
rcfg remote.gitea.replicatePermissions false
# remote.timeout is parsed by JGit's RemoteConfig as a plain integer
# (seconds) -- unlike gerrit.config's duration fields, a unit suffix
# like "30s" throws NumberFormatException and crashes the plugin.
rcfg remote.gitea.timeout 30

chmod 600 "$SITE/etc/replication.config"

AFTER=$(md5sum "$SITE/etc/replication.config" 2>/dev/null || true)

if [ "$BEFORE" = "$AFTER" ] && systemctl is-active --quiet gerrit; then
  log "replication.config unchanged, gerrit already running -- leaving it as-is."
else
  log "replication.config written, restarting gerrit to load the replication plugin config."
  systemctl restart gerrit
  wait_for_http "${GERRIT_URL}/" 120 \
    "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
fi

# Gerrit itself can come up fine even if a plugin failed to load (it just
# logs a warning), so check explicitly rather than assuming the replication
# plugin is actually active -- a bad replication.config would otherwise only
# surface as a confusing timeout several steps later.
if curl -fsS -u "carol:${TEST_PW}" "${GERRIT_URL}/a/plugins/?all" | tail -n +2 \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "replication" in d and not d["replication"].get("disabled") else 1)'; then
  log "replication plugin is loaded and enabled."
else
  die "replication plugin is not loaded -- check: journalctl -u gerrit -n 150 --no-pager | grep -i replicat"
fi

# --- 5. end-to-end check: create a throwaway project, push+submit, confirm it mirrors ---
PROJECT="replication-test"
if curl -fsS -u "carol:${TEST_PW}" -o /dev/null "${GERRIT_URL}/a/projects/${PROJECT}" 2>/dev/null; then
  log "Gerrit project '${PROJECT}' already exists, skipping creation."
else
  curl -fsS -u "carol:${TEST_PW}" -X PUT -H 'Content-Type: application/json' \
    -d '{"create_empty_commit": true, "branches": ["main"]}' \
    "${GERRIT_URL}/a/projects/${PROJECT}" >/dev/null
  log "created Gerrit project '${PROJECT}' with an initial empty commit on main."
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
AUTH_URL="http://carol:${TEST_PW}@127.0.0.1:8080/a/${PROJECT}"
git clone -q "$AUTH_URL" repo
cd repo
echo "replication smoke test $(date -u +%FT%TZ)" > REPLICATION_TEST.txt
git add REPLICATION_TEST.txt
CHANGE_ID="I$(openssl rand -hex 20)"
git -c user.name="Lab Bootstrap" -c user.email="carol@tkos.co.il" \
  commit -q -m "$(printf 'Add replication smoke test file\n\nChange-Id: %s\n' "$CHANGE_ID")"
git push -q "$AUTH_URL" HEAD:refs/for/main

CHANGE_NUM=$(curl -fsS -u "carol:${TEST_PW}" \
  "${GERRIT_URL}/a/changes/?q=change:${CHANGE_ID}" | tail -n +2 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')
curl -fsS -u "carol:${TEST_PW}" -X POST -H 'Content-Type: application/json' \
  -d '{"labels":{"Code-Review":2}}' \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/current/review" >/dev/null
curl -fsS -u "carol:${TEST_PW}" -X POST \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/submit" >/dev/null
log "submitted change ${CHANGE_NUM} on '${PROJECT}'; waiting for it to replicate to Gitea..."

GERRIT_SHA=$(curl -fsS -u "carol:${TEST_PW}" \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}?o=CURRENT_REVISION" | tail -n +2 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["current_revision"])')

# Poll until Gitea's main branch actually matches the SHA just submitted --
# the repo may already exist from an earlier run, so its mere presence
# doesn't tell us THIS commit has replicated yet. Push-created repos are
# also private by default, so all of this must be authenticated (an
# anonymous check 404s the same whether the repo is missing or just
# private-and-not-visible).
i=0
GITEA_SHA=""
until [ "$GITEA_SHA" = "$GERRIT_SHA" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || die "Gitea main (${GITEA_SHA:0:10}) never matched Gerrit's submitted commit (${GERRIT_SHA:0:10}) after 30s -- check: journalctl -u gerrit -n 100 --no-pager | grep -i replicat"
  sleep 1
  GITEA_SHA=$( (gitea_api "${GITEA_URL}/api/v1/repos/${ORG}/${PROJECT}/branches/main" 2>/dev/null || true) \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["commit"]["id"])
except Exception: print("")')
done

log "OK: Gitea's main branch (${GITEA_SHA:0:10}) matches Gerrit's submitted commit -- replication is working."

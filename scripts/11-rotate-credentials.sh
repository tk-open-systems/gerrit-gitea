#!/usr/bin/env bash
# Production hardening: rotate every service/admin credential this
# project's automation set to the shared lab default (ChangeMe123!)
# during initial setup.
# Run as root: sudo bash 11-rotate-credentials.sh
#
# Touches, in dependency order: LDAP (cn=admin bind + every test user),
# Gerrit's stored LDAP bind password (secure.config) and replication
# credential (replication.config), Gitea's LDAP auth source bind
# password, and Gitea's two local accounts (gitea-admin, gerrit-
# replication). Restarts Gerrit where needed and re-verifies LDAP login
# and replication both still work with the new credentials before
# declaring success.
#
# NOT idempotent by design -- rotation means "set a new secret," so
# rerunning it changes every credential again each time. That's the
# point. It IS safe to rerun without corrupting state: each step either
# fully succeeds or the script dies loudly (via lib.sh's ERR trap)
# before anything downstream depends on a half-applied change.
#
# After running this, scripts/02 through scripts/10 can no longer be
# blindly rerun -- they hard-code the lab bootstrap password
# (ChangeMe123!) to talk to LDAP/Gerrit/Gitea, which is exactly what
# this script replaces. That's expected: their job (bootstrap the lab)
# is done; this is a separate, later day-2 operation. New credentials
# are printed at the end -- store them somewhere real. In an actual
# production deployment none of this should live in plaintext shell
# variables at all; use a secrets manager instead. This script exists
# to demonstrate *that* rotation is possible and what it touches, not
# as a template for real secret handling.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

ADMIN_DN="cn=admin,${BASE_DN}"
OLD_PW="ChangeMe123!"
SITE=/var/lib/gerrit
APP_INI=/etc/gitea/app.ini
GITEA="/usr/local/bin/gitea"
GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"
ORG="engineering"

gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo; }

NEW_ADMIN_PW=$(gen_pw)
NEW_ALICE_PW=$(gen_pw)
NEW_BOB_PW=$(gen_pw)
NEW_CAROL_PW=$(gen_pw)
NEW_GITEA_ADMIN_PW=$(gen_pw)
NEW_REPL_PW=$(gen_pw)

# `sudo -u gerrit <cmd>` inherits this script's cwd; if that's somewhere
# the gerrit user can't stat (e.g. an invoking user's home directory),
# git fails with a confusing "failed to stat" error unrelated to the
# actual command (see SYSADMIN.md gotcha 2).
cd "$SITE"

# --- 1. LDAP: rotate cn=admin's bind password ---
ADMIN_HASH=$(/usr/sbin/slappasswd -s "$NEW_ADMIN_PW")
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn \
  2>/dev/null | awk -F': ' '/^dn:/{print $2}')
[ -n "$DB_DN" ] || die "could not find mdb database entry for suffix ${BASE_DN}"
ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcRootPW
olcRootPW: ${ADMIN_HASH}
EOF
log "rotated LDAP admin bind password"

# --- 2. LDAP: rotate every test user (using the NEW admin password from here on) ---
rotate_ldap_user() {
  local uid=$1 newpw=$2
  local hash
  hash=$(/usr/sbin/slappasswd -s "$newpw")
  ldapmodify -x -D "$ADMIN_DN" -w "$NEW_ADMIN_PW" -H ldap://localhost <<EOF
dn: uid=${uid},ou=people,${BASE_DN}
changetype: modify
replace: userPassword
userPassword: ${hash}
EOF
  log "rotated LDAP password for ${uid}"
}
rotate_ldap_user alice "$NEW_ALICE_PW"
rotate_ldap_user bob "$NEW_BOB_PW"
rotate_ldap_user carol "$NEW_CAROL_PW"

# --- 3. Gerrit: update its stored LDAP bind password, restart, verify login ---
sudo -u gerrit git config -f "$SITE/etc/secure.config" ldap.password "$NEW_ADMIN_PW"
chmod 600 "$SITE/etc/secure.config"
systemctl restart gerrit
wait_for_http "${GERRIT_URL}/" 120 \
  "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
curl -fsS -u "carol:${NEW_CAROL_PW}" -o /dev/null "${GERRIT_URL}/a/accounts/self" \
  || die "carol cannot log into Gerrit with her new LDAP password"
log "Gerrit: LDAP bind password rotated, restarted, verified carol can still log in"

# --- 4. Gitea: rotate its LDAP auth source bind password ---
LDAP_SOURCE_ID=$(sudo -u gitea "$GITEA" admin auth list --config "$APP_INI" \
  | awk '$2=="LDAP"{print $1}')
[ -n "$LDAP_SOURCE_ID" ] || die "could not find Gitea's LDAP auth source id"
sudo -u gitea "$GITEA" admin auth update-ldap \
  --config "$APP_INI" \
  --id "$LDAP_SOURCE_ID" \
  --bind-password "$NEW_ADMIN_PW"
curl -fsS -u "carol:${NEW_CAROL_PW}" -o /dev/null "${GITEA_URL}/api/v1/user" \
  || die "carol cannot log into Gitea with her new LDAP password"
log "Gitea: LDAP auth source bind password rotated, verified carol can still log in"

# --- 5. Gitea: rotate the two local (non-LDAP) accounts ---
sudo -u gitea "$GITEA" admin user change-password --config "$APP_INI" \
  -u gitea-admin -p "$NEW_GITEA_ADMIN_PW" --must-change-password=false
sudo -u gitea "$GITEA" admin user change-password --config "$APP_INI" \
  -u gerrit-replication -p "$NEW_REPL_PW" --must-change-password=false
log "Gitea: rotated local accounts gitea-admin and gerrit-replication"

# --- 6. Gerrit: update the replication credential, restart, verify replication ---
sudo -u gerrit git config -f "$SITE/etc/replication.config" remote.gitea.url \
  "http://gerrit-replication:${NEW_REPL_PW}@127.0.0.1:3000/${ORG}/\${name}.git"
chmod 600 "$SITE/etc/replication.config"
systemctl restart gerrit
wait_for_http "${GERRIT_URL}/" 120 \
  "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
curl -fsS -u "carol:${NEW_CAROL_PW}" "${GERRIT_URL}/a/plugins/?all" | tail -n +2 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "replication" in d and not d["replication"].get("disabled") else 1)' \
  || die "replication plugin not loaded after rotation"

PROJECT="replication-test"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
AUTH_URL="http://carol:${NEW_CAROL_PW}@127.0.0.1:8080/a/${PROJECT}"
git clone -q "$AUTH_URL" repo
cd repo
echo "credential rotation check $(date -u +%FT%TZ)" > ROTATION_TEST.txt
git add ROTATION_TEST.txt
CHANGE_ID="I$(openssl rand -hex 20)"
git -c user.name="Lab Bootstrap" -c user.email="carol@tkos.co.il" \
  commit -q -m "$(printf 'Verify replication after credential rotation\n\nChange-Id: %s\n' "$CHANGE_ID")"
git push -q "$AUTH_URL" HEAD:refs/for/main
CHANGE_NUM=$(curl -fsS -u "carol:${NEW_CAROL_PW}" \
  "${GERRIT_URL}/a/changes/?q=change:${CHANGE_ID}" | tail -n +2 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')
curl -fsS -u "carol:${NEW_CAROL_PW}" -X POST -H 'Content-Type: application/json' \
  -d '{"labels":{"Code-Review":2}}' \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/current/review" >/dev/null
curl -fsS -u "carol:${NEW_CAROL_PW}" -X POST \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/submit" >/dev/null
GERRIT_SHA=$(curl -fsS -u "carol:${NEW_CAROL_PW}" \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}?o=CURRENT_REVISION" | tail -n +2 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["current_revision"])')

i=0
GITEA_SHA=""
until [ "$GITEA_SHA" = "$GERRIT_SHA" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || die "replication did not pick up the new credential after 30s"
  sleep 1
  GITEA_SHA=$(curl -fsS -u "gitea-admin:${NEW_GITEA_ADMIN_PW}" \
    "${GITEA_URL}/api/v1/repos/${ORG}/${PROJECT}/branches/main" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["commit"]["id"])
except Exception: print("")')
done
log "Gerrit: replication credential rotated, restarted, verified a real push still replicates"

cat <<SUMMARY

=== Credential rotation complete ===
Store these somewhere real (a secrets manager, not this terminal scrollback):

  LDAP cn=admin       : ${NEW_ADMIN_PW}
  LDAP alice           : ${NEW_ALICE_PW}
  LDAP bob              : ${NEW_BOB_PW}
  LDAP carol            : ${NEW_CAROL_PW}
  Gitea gitea-admin     : ${NEW_GITEA_ADMIN_PW}
  Gitea gerrit-replication : ${NEW_REPL_PW}

scripts/02 through scripts/10 hard-code the old lab password
(ChangeMe123!) and can no longer be blindly rerun against this host --
see SYSADMIN.md's Production Hardening section.
SUMMARY

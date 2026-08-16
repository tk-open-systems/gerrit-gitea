#!/usr/bin/env bash
# Day-2 operation: set/change the password for one or more of this
# lab's non-human "special" accounts, individually:
#   ldap-admin          cn=admin -- the LDAP directory's own root bind
#   ldap-reader         cn=ldap-reader,ou=services,... -- read-only
#                       search bind for Gerrit/Gitea (only exists if
#                       scripts/12-ldap-least-privilege.sh has run)
#   gitea-admin         local Gitea instance-admin account
#   gerrit-replication  local Gitea account the replication plugin
#                       pushes as
#
# Everything else -- gerrit-bot, carol, alice, bob, or any other real
# LDAP person under ou=people -- is a normal user account and goes
# through scripts/18-user-lifecycle.sh (`ggadmin-user set-password
# <uid>`) instead. This script only covers what falls outside that:
# the directory root itself, the ou=services bind account, and Gitea's
# own local (non-LDAP) accounts.
#
# Run as root: sudo bash 11-set-service-credentials.sh <account> [<account> ...]
#   sudo bash 11-set-service-credentials.sh gitea-admin
#   sudo bash 11-set-service-credentials.sh ldap-admin gerrit-replication
#
# A new password is generated per account (openssl rand) unless you
# override it via NEW_LDAP_ADMIN_PW / NEW_LDAP_READER_PW /
# NEW_GITEA_ADMIN_PW / NEW_GERRIT_REPLICATION_PW. Printed once at the
# end -- nothing is stored by this script itself; capture it there.
#
# Only ldap-reader needs an existing credential (LDAP_ADMIN_PW,
# cn=admin's CURRENT password, to authenticate the change). The other
# three need none: ldap-admin changes via SASL EXTERNAL as root against
# the cn=config backend (the same mechanism scripts/12 uses), and
# gitea-admin/gerrit-replication change via the `gitea` CLI run as the
# `gitea` OS user -- both need only root on this host.
#
# If Gerrit/Gitea's own LDAP search bind is currently configured to use
# the account being changed, that stored copy is updated and the
# affected service restarted too, so a password change never leaves a
# service unable to search the directory. Which DN they're currently
# bound as isn't guessed: scripts/06-gitea-ldap.sh always points both
# at cn=admin, and scripts/12-ldap-least-privilege.sh always repoints
# BOTH at ldap-reader together, atomically -- so "does cn=ldap-reader
# exist" is a reliable signal for which one currently applies. Changing
# gerrit-replication's password similarly updates the copy embedded in
# Gerrit's replication.config remote URL.
#
# Verification here is intentionally lighter than a full rotate-
# everything script's replication smoke test would be: each account's
# new password is confirmed to actually authenticate (a direct LDAP
# bind, or the gitea CLI call's own exit code), and any service whose
# config got touched is confirmed to restart cleanly -- not a full
# create-project-push-merge-verify cycle, since that's what
# scripts/09-smoke-test.sh is already for.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

[ $# -ge 1 ] || die "usage: $SCRIPT_NAME <account> [<account> ...]  -- account is one of: ldap-admin, ldap-reader, gitea-admin, gerrit-replication"

SITE=/var/lib/gerrit
APP_INI=/etc/gitea/app.ini
GITEA=/usr/local/bin/gitea
GERRIT_URL="http://127.0.0.1:8080"
ORG="${GITEA_ORG:-engineering}"
ADMIN_DN="cn=admin,${BASE_DN}"
READER_DN="cn=ldap-reader,ou=services,${BASE_DN}"

# --- validate every requested account name up front, before changing anything ---
for acct in "$@"; do
  case "$acct" in
    ldap-admin|ldap-reader|gitea-admin|gerrit-replication) ;;
    *) die "unknown account '$acct' -- must be one of: ldap-admin, ldap-reader, gitea-admin, gerrit-replication" ;;
  esac
done

gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo; }

reader_exists() {
  ldapsearch -x -H ldap://localhost -b "$READER_DN" -s base "(objectClass=*)" dn >/dev/null 2>&1
}

gitea_ldap_source_id() {
  sudo -u gitea "$GITEA" admin auth list --config "$APP_INI" 2>/dev/null \
    | awk '$2=="LDAP"{print $1}'
}

# update_gerrit_ldap_bind NEW_PW -- Gerrit's secure.config only ever
# stores a password, never the DN it goes with (that's in
# gerrit.config's ldap.username, untouched here since it doesn't
# change) -- so this just needs the new value and a restart.
update_gerrit_ldap_bind() {
  local new_pw=$1
  sudo -u gerrit git config -f "$SITE/etc/secure.config" ldap.password "$new_pw"
  chmod 600 "$SITE/etc/secure.config"
  systemctl restart gerrit
  wait_for_http "${GERRIT_URL}/" 120 \
    "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
  log "Gerrit: restarted with updated LDAP bind password"
}

# update_gitea_ldap_bind BIND_DN NEW_PW -- must resend the FULL field
# set on every update, not just bind-dn/bind-password: `update-ldap`
# silently resets any omitted field (including group-sync settings) to
# empty, confirmed the hard way once already (see
# scripts/12-ldap-least-privilege.sh's comment on this exact gotcha).
update_gitea_ldap_bind() {
  local bind_dn=$1 new_pw=$2
  local id; id=$(gitea_ldap_source_id)
  [ -n "$id" ] || die "could not find Gitea's LDAP auth source id -- has scripts/06-gitea-ldap.sh been run?"
  local group_team_map
  group_team_map=$(printf '{"cn=developers,ou=groups,%s":{"%s":["Developers"]},"cn=admins,ou=groups,%s":{"%s":["Owners"]}}' \
    "$BASE_DN" "$ORG" "$BASE_DN" "$ORG")
  sudo -u gitea "$GITEA" admin auth update-ldap \
    --config "$APP_INI" \
    --id "$id" \
    --name LDAP \
    --active \
    --security-protocol unencrypted \
    --host localhost \
    --port 389 \
    --bind-dn "$bind_dn" \
    --bind-password "$new_pw" \
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
    --group-team-map "$group_team_map" \
    --group-team-map-removal
  log "Gitea: LDAP auth source bind password updated"
}

set_ldap_admin() {
  local new_pw=${NEW_LDAP_ADMIN_PW:-$(gen_pw)}
  local hash; hash=$(/usr/sbin/slappasswd -s "$new_pw")
  local db_dn
  db_dn=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
    "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn \
    2>/dev/null | awk -F': ' '/^dn:/{print $2}')
  [ -n "$db_dn" ] || die "could not find mdb database entry for suffix ${BASE_DN}"
  ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${db_dn}
changetype: modify
replace: olcRootPW
olcRootPW: ${hash}
EOF
  ldapwhoami -x -D "$ADMIN_DN" -w "$new_pw" -H ldap://localhost >/dev/null \
    || die "cn=admin's new password was set but does not authenticate -- something went wrong"
  log "LDAP: cn=admin's password changed and verified"

  if reader_exists; then
    log "cn=ldap-reader exists -- Gerrit/Gitea already bind as it, not cn=admin, so their config is untouched"
  else
    update_gerrit_ldap_bind "$new_pw"
    update_gitea_ldap_bind "$ADMIN_DN" "$new_pw"
  fi
  RESULT_LDAP_ADMIN_PW=$new_pw
}

set_ldap_reader() {
  reader_exists || die "cn=ldap-reader does not exist -- scripts/12-ldap-least-privilege.sh has not been run on this host, nothing to change"
  : "${LDAP_ADMIN_PW:?Set LDAP_ADMIN_PW to cn=admin current password, needed to authenticate this change}"
  local new_pw=${NEW_LDAP_READER_PW:-$(gen_pw)}
  local hash; hash=$(/usr/sbin/slappasswd -s "$new_pw")
  ldapmodify -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost <<EOF
dn: ${READER_DN}
changetype: modify
replace: userPassword
userPassword: ${hash}
EOF
  ldapwhoami -x -D "$READER_DN" -w "$new_pw" -H ldap://localhost >/dev/null \
    || die "ldap-reader's new password was set but does not authenticate -- something went wrong"
  log "LDAP: ldap-reader's password changed and verified"
  update_gerrit_ldap_bind "$new_pw"
  update_gitea_ldap_bind "$READER_DN" "$new_pw"
  RESULT_LDAP_READER_PW=$new_pw
}

set_gitea_admin() {
  local new_pw=${NEW_GITEA_ADMIN_PW:-$(gen_pw)}
  sudo -u gitea "$GITEA" admin user change-password --config "$APP_INI" \
    -u gitea-admin -p "$new_pw" --must-change-password=false
  log "Gitea: gitea-admin's password changed"
  RESULT_GITEA_ADMIN_PW=$new_pw
}

set_gerrit_replication() {
  local new_pw=${NEW_GERRIT_REPLICATION_PW:-$(gen_pw)}
  sudo -u gitea "$GITEA" admin user change-password --config "$APP_INI" \
    -u gerrit-replication -p "$new_pw" --must-change-password=false
  log "Gitea: gerrit-replication's password changed"
  sudo -u gerrit git config -f "$SITE/etc/replication.config" remote.gitea.url \
    "http://gerrit-replication:${new_pw}@127.0.0.1:3000/${ORG}/\${name}.git"
  chmod 600 "$SITE/etc/replication.config"
  systemctl restart gerrit
  wait_for_http "${GERRIT_URL}/" 120 \
    "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
  log "Gerrit: restarted with updated replication credential"
  RESULT_GERRIT_REPLICATION_PW=$new_pw
}

for acct in "$@"; do
  case "$acct" in
    ldap-admin)          set_ldap_admin ;;
    ldap-reader)         set_ldap_reader ;;
    gitea-admin)         set_gitea_admin ;;
    gerrit-replication)  set_gerrit_replication ;;
  esac
done

cat <<EOF

=== New credentials (capture these -- nothing is stored by this script) ===
EOF
[ -n "${RESULT_LDAP_ADMIN_PW:-}" ]         && echo "  ldap-admin (cn=admin) : ${RESULT_LDAP_ADMIN_PW}"
[ -n "${RESULT_LDAP_READER_PW:-}" ]        && echo "  ldap-reader           : ${RESULT_LDAP_READER_PW}"
[ -n "${RESULT_GITEA_ADMIN_PW:-}" ]        && echo "  gitea-admin           : ${RESULT_GITEA_ADMIN_PW}"
[ -n "${RESULT_GERRIT_REPLICATION_PW:-}" ] && echo "  gerrit-replication    : ${RESULT_GERRIT_REPLICATION_PW}"
true

#!/usr/bin/env bash
# Post-install: dedicated least-privilege LDAP bind account. Not
# optional hardening -- this directory ships wide open (see below), so
# treat this as required to close that gap for any real deployment,
# same reasoning as scripts/post-install/set-service-credentials.sh.
# Run as root, passing the CURRENT passwords for cn=admin, alice, and
# carol (needed to verify the lockdown -- see step 5 below; `sudo`
# strips the environment by default, so pass them on the sudo command
# line, which sudo applies even under env_reset):
#
#   sudo LDAP_ADMIN_PW='...' ALICE_PW='...' CAROL_PW='...' \
#     bash ldap-least-privilege.sh
#
# alice/carol specifically only if this host hasn't run
# scripts/post-install/final-remove-test-users.sh yet -- once it has, they're
# gone for good and step 5 needs two OTHER real, currently-existing
# accounts instead. Set PROBER_UID/TARGET_UID to pick which ones (still
# via ALICE_PW/CAROL_PW for their respective passwords -- see below):
#
#   sudo LDAP_ADMIN_PW='...' PROBER_UID=dave ALICE_PW='...' \
#     TARGET_UID=erin CAROL_PW='...' bash ldap-least-privilege.sh
#
# This directory currently has NO explicit ACLs at all -- it runs on
# OpenLDAP's compiled-in default, which protects userPassword but
# leaves every other attribute (names, emails, group membership)
# readable by a fully anonymous, unauthenticated bind. Confirmed live:
# `ldapsearch -x` with no credentials could already list who's in the
# admins group. Given that, creating a "least-privilege read-only bind
# account" would be close to meaningless on its own -- it would grant
# the same read access anonymous already has. So this script does two
# things together:
#
#   1. Creates cn=ldap-reader,ou=services,dc=tkos,dc=co,dc=il: a
#      bind-only service account (organizationalRole +
#      simpleSecurityObject, no human attributes) with read access to
#      ou=people/ou=groups and nothing else.
#   2. Replaces the implicit default ACL with explicit rules: nobody
#      but ldap-reader gets general read access; everyone else (incl.
#      anonymous) gets none. Regular users can still authenticate --
#      BIND is a distinct LDAP operation from READ/SEARCH and doesn't
#      require read access to succeed, so alice/bob/carol logging into
#      Gerrit/Gitea is unaffected; only directory *browsing* is
#      restricted.
#
# Gerrit and Gitea are then repointed from cn=admin (full directory
# write access, reused for search convenience during initial setup --
# see scripts/install/02-openldap.sh) to this read-only account, and every
# claim here is verified by actually testing as the restricted role,
# not by trusting that the ACL text looks right: anonymous and a
# regular user (alice) are both confirmed unable to browse the
# directory afterward, ldap-reader is confirmed unable to write
# anywhere, and carol logging into both Gerrit and Gitea (proving the
# search-then-bind-as-user auth flow still works through the new
# reader account) is reverified end to end.
#
# NOT safe to blindly rerun with the SAME generated password (it mints
# a new one each time, like scripts/post-install/set-service-credentials.sh) -- but every step is
# idempotent/guarded (LDAP entries via ldap_add_if_missing, ACL via a
# plain replace, config edits via git config -f), so rerunning just
# rotates the reader account's password and re-verifies everything.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

ADMIN_DN="cn=admin,${BASE_DN}"
READER_DN="cn=ldap-reader,ou=services,${BASE_DN}"
SITE=/var/lib/gerrit
APP_INI=/etc/gitea/app.ini
GITEA="/usr/local/bin/gitea"
GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"

# Step 5's verification needs two DISTINCT, currently-real LDAP person
# accounts: PROBER_UID attempts to read TARGET_UID's entry (must fail)
# and log into Gerrit/Gitea (must still succeed). Default to the lab
# test users alice/carol, same as always -- but those are only ever
# real on a host that hasn't run scripts/post-install/final-remove-test-users.sh
# yet (see this script's header comment on ordering). Once that's run,
# alice/carol no longer exist, and this script cannot be blindly
# rerun -- confirmed live, not hypothetical: an operator whose ACTUAL
# lockdown was already correct hit "carol cannot log into Gerrit"
# here, purely because carol herself was long gone, not because
# anything was broken. Override both to a pair of real accounts that
# still exist on this host to get a meaningful rerun instead:
#   sudo LDAP_ADMIN_PW='...' PROBER_UID=dave ALICE_PW='...' \
#     TARGET_UID=erin CAROL_PW='...' bash ldap-least-privilege.sh
PROBER_UID="${PROBER_UID:-alice}"
TARGET_UID="${TARGET_UID:-carol}"

# Current passwords, likely already rotated off the lab default by
# scripts/post-install/set-service-credentials.sh -- nothing persists them anywhere, so they must be passed
# in rather than hard-coded. Despite the variable names, these are
# PROBER_UID's and TARGET_UID's passwords respectively -- still named
# ALICE_PW/CAROL_PW to match this script's whole history and every doc
# that references it, for the common case where PROBER_UID/TARGET_UID
# are left at their alice/carol defaults.
: "${LDAP_ADMIN_PW:?Set LDAP_ADMIN_PW to cn=admins current password. Test-lab default: ChangeMe123! (printed by scripts/install/02-openldap.sh); only different if someone ran scripts/post-install/set-service-credentials.sh ldap-admin (or 'all') since.}"
: "${ALICE_PW:?Set ALICE_PW to ${PROBER_UID}s current LDAP password (this is PROBER_UID's password, named ALICE_PW because PROBER_UID defaults to alice). Test-lab default for alice: ChangeMe123! (printed by scripts/install/02-openldap.sh); only different if someone ran scripts/day2/user-lifecycle.sh set-password ${PROBER_UID} since.}"
: "${CAROL_PW:?Set CAROL_PW to ${TARGET_UID}s current LDAP password (this is TARGET_UID's password, named CAROL_PW because TARGET_UID defaults to carol). Test-lab default for carol: ChangeMe123! (printed by scripts/install/02-openldap.sh); only different if someone ran scripts/day2/user-lifecycle.sh set-password ${TARGET_UID} since.}"

# Fail fast and clearly if either account is simply gone (e.g.
# final-remove-test-users.sh already ran) instead of dying confusingly
# deep in step 5 after every other step already made real changes.
for _uid in "$PROBER_UID" "$TARGET_UID"; do
  ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost \
    -b "uid=${_uid},ou=people,${BASE_DN}" -s base "(objectClass=*)" dn >/dev/null 2>&1 \
    || die "no LDAP entry for uid=${_uid} -- step 5's verification needs this account to actually exist and log in. If this host already ran scripts/post-install/final-remove-test-users.sh, alice/bob/carol are gone for good (by design, see that script's header) -- point PROBER_UID/TARGET_UID at two other real, currently-existing accounts instead (with ALICE_PW/CAROL_PW set to their respective passwords): sudo LDAP_ADMIN_PW='...' PROBER_UID=<uid> ALICE_PW='...' TARGET_UID=<uid> CAROL_PW='...' bash ${SCRIPT_NAME}"
done
unset _uid

READER_PW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo)

cd "$SITE"

# --- 1. ou=services + the reader account itself ---
ldap_add_if_missing "ou=services,${BASE_DN}" "$(cat <<EOF
dn: ou=services,${BASE_DN}
objectClass: organizationalUnit
ou: services
EOF
)" "$ADMIN_DN" "$LDAP_ADMIN_PW"

READER_HASH=$(/usr/sbin/slappasswd -s "$READER_PW")
if ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost \
     -b "$READER_DN" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  ldapmodify -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost <<EOF
dn: ${READER_DN}
changetype: modify
replace: userPassword
userPassword: ${READER_HASH}
EOF
  log "reader account already existed, rotated its password"
else
  ldapadd -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost <<EOF
dn: ${READER_DN}
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: ldap-reader
userPassword: ${READER_HASH}
description: Bind-only account for Gerrit/Gitea directory searches -- read access only, see scripts/post-install/ldap-least-privilege.sh
EOF
  log "created reader account ${READER_DN}"
fi

# --- 2. explicit least-privilege ACL, replacing the implicit default ---
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn \
  2>/dev/null | awk -F': ' '/^dn:/{print $2}')
[ -n "$DB_DN" ] || die "could not find mdb database entry for suffix ${BASE_DN}"

# The middle rule (ou=groups readable by any authenticated user, not
# just the reader account) exists because of a real behavioral
# discovery, not an oversight: Gitea's LDAP client reuses ONE
# connection across the whole login flow. It binds as the reader,
# searches ou=people for the user, then REBINDS THAT SAME CONNECTION
# AS THE LOGGING-IN USER to verify their password -- and the
# subsequent group-membership search runs on that connection, meaning
# it executes with the USER's own privileges, not the reader's.
# Confirmed by turning on slapd's stats log and watching the actual
# wire traffic: the group search (op=4) arrives on a connection already
# rebound to "uid=carol,...", and fails with "No Such Object" (32) once
# ou=groups is locked down to reader-only -- OpenLDAP returns that
# instead of "insufficient access" specifically to avoid confirming a
# restricted subtree even exists. A reader-only-search design is
# fundamentally incompatible with how Gitea's group sync actually
# authenticates; granting any authenticated (non-anonymous) bind read
# access to ou=groups specifically is the minimal change that unbreaks
# it while ou=people -- individual attributes like email, not just
# membership -- stays restricted to the reader account and self.
ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword
  by self write
  by anonymous auth
  by * none
olcAccess: {1}to dn.subtree="ou=groups,${BASE_DN}"
  by users read
  by * none
olcAccess: {2}to *
  by dn.exact="${READER_DN}" read
  by self read
  by * none
EOF
log "replaced implicit default ACL with explicit least-privilege rules"

# --- 3. Gerrit: point at the reader account instead of cn=admin ---
gcfg() { sudo -u gerrit git config -f "$SITE/etc/gerrit.config" "$@"; }
gcfg ldap.username "$READER_DN"
sudo -u gerrit git config -f "$SITE/etc/secure.config" ldap.password "$READER_PW"
chmod 600 "$SITE/etc/secure.config"
systemctl restart gerrit
wait_for_http "${GERRIT_URL}/" 120 \
  "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"

# --- 4. Gitea: same, via its LDAP auth source ---
#
# Learned the hard way (again -- see SYSADMIN.md gotcha 11 for the
# first time this exact class of bug bit us): `update-ldap` with only
# --bind-dn/--bind-password silently reset the group-sync fields
# (group-search-base-dn etc.) to empty, breaking Gitea's group lookups
# with "LDAP Result Code 32 No Such Object" -- even though the LDAP
# server and reader account were completely fine (Gerrit's own group
# lookups, using the very same reader account, kept working the whole
# time). Always resend the FULL set of add-ldap-equivalent flags on
# any update, not just the fields being changed.
LDAP_SOURCE_ID=$(sudo -u gitea "$GITEA" admin auth list --config "$APP_INI" \
  | awk '$2=="LDAP"{print $1}')
[ -n "$LDAP_SOURCE_ID" ] || die "could not find Gitea's LDAP auth source id"

GROUP_TEAM_MAP=$(printf '{"cn=developers,ou=groups,%s":{"engineering":["Developers"]},"cn=admins,ou=groups,%s":{"engineering":["Owners"]}}' \
  "$BASE_DN" "$BASE_DN")

sudo -u gitea "$GITEA" admin auth update-ldap \
  --config "$APP_INI" \
  --id "$LDAP_SOURCE_ID" \
  --name LDAP \
  --active \
  --security-protocol unencrypted \
  --host localhost \
  --port 389 \
  --bind-dn "$READER_DN" \
  --bind-password "$READER_PW" \
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
log "repointed Gerrit and Gitea at the reader account"

# --- 5. verify: test as the actual restricted roles, not just re-check config ---

# 5a. anonymous can no longer browse the directory
ANON_COUNT=$(ldapsearch -x -H ldap://localhost -b "ou=groups,${BASE_DN}" \
  "(cn=admins)" member 2>/dev/null | grep -c '^member:' || true)
[ "$ANON_COUNT" -eq 0 ] || die "anonymous can still read group membership -- ACL lockdown failed"
log "confirmed: anonymous bind can no longer read group membership"

# 5b. a regular user (PROBER_UID) cannot browse other users entries either
# -- this is the actual point of the exercise, so it is not optional.
PROBER_COUNT=$(ldapsearch -x -D "uid=${PROBER_UID},ou=people,${BASE_DN}" -w "$ALICE_PW" -H ldap://localhost \
  -b "uid=${TARGET_UID},ou=people,${BASE_DN}" mail 2>/dev/null | grep -c '^mail:' || true)
[ "$PROBER_COUNT" -eq 0 ] || die "${PROBER_UID} can still read another user's attributes -- ACL lockdown failed"
log "confirmed: ${PROBER_UID} (regular user) cannot read other users entries"

# 5c. the reader account itself cannot write anywhere. Targets TARGET_UID,
# not PROBER_UID -- both are confirmed to exist up front, but it doesn't
# matter which as long as it's a real entry: a write attempt against a
# nonexistent DN would fail for the wrong reason ("no such object") and
# silently pass this check even if the reader account has write access.
if ldapmodify -x -D "$READER_DN" -w "$READER_PW" -H ldap://localhost 2>/dev/null <<EOF
dn: uid=${TARGET_UID},ou=people,${BASE_DN}
changetype: modify
replace: description
description: reader account should not be able to do this
EOF
then
  die "ldap-reader was able to write to the directory -- it should be read-only"
fi
log "confirmed: ldap-reader cannot write to the directory (write attempt correctly rejected)"

# 5d. Gerrit and Gitea logins still work through the new reader account
curl -fsS -u "${TARGET_UID}:${CAROL_PW}" \
  -o /dev/null "${GERRIT_URL}/a/accounts/self" \
  || die "${TARGET_UID} cannot log into Gerrit through the new reader account"
curl -fsS -u "${TARGET_UID}:${CAROL_PW}" -o /dev/null "${GITEA_URL}/api/v1/user" \
  || die "${TARGET_UID} cannot log into Gitea through the new reader account"
log "confirmed: ${TARGET_UID} can still log into both Gerrit and Gitea via the reader account"

log "OK: least-privilege LDAP bind account in place, ACL lockdown verified, logins still work."

#!/usr/bin/env bash
# Phase 2: test OpenLDAP directory for the Gerrit/Gitea lab.
# Run as root: sudo bash 02-openldap.sh
#
# slapd auto-configured itself during package install with a base DN
# derived from this host's domain (dc=tkos,dc=co,dc=il) and no usable
# admin password. This script sets a known admin password, then loads
# an ou=people/ou=groups tree with two test users and two groups
# (developers, admins) that Gerrit and Gitea will both bind against.
#
# TEST-LAB CREDENTIALS ONLY: every account below uses the password
# "ChangeMe123!" so the doc stays reproducible. Never reuse this
# password scheme outside a throwaway lab.
#
# Safe to rerun: the rootPW change is a replace (always succeeds), and
# every LDAP entry is added through ldap_add_if_missing, which skips
# entries that already exist instead of failing on "already exists".
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

BASE_DN="dc=tkos,dc=co,dc=il"
ADMIN_DN="cn=admin,${BASE_DN}"
TEST_PW="ChangeMe123!"

# --- 1. find the mdb database entry under cn=config and set its rootPW ---
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn \
  2>/dev/null | awk -F': ' '/^dn:/{print $2}')

[ -n "$DB_DN" ] || die "could not find mdb database entry for suffix ${BASE_DN} under cn=config"
log "found database entry: $DB_DN"

PW_HASH=$(slappasswd -s "$TEST_PW")

ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcRootDN
olcRootDN: ${ADMIN_DN}
-
replace: olcRootPW
olcRootPW: ${PW_HASH}
EOF

log "admin bind DN is now ${ADMIN_DN} (password: ${TEST_PW})"

# --- 2. base structure: ou=people, ou=groups ---
ldap_add_if_missing "ou=people,${BASE_DN}" "$(cat <<EOF
dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people
EOF
)" "$ADMIN_DN" "$TEST_PW"

ldap_add_if_missing "ou=groups,${BASE_DN}" "$(cat <<EOF
dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups
EOF
)" "$ADMIN_DN" "$TEST_PW"

# --- 3. test users (inetOrgPerson) ---
USER_PW_HASH=$(slappasswd -s "$TEST_PW")

ldap_add_if_missing "uid=alice,ou=people,${BASE_DN}" "$(cat <<EOF
dn: uid=alice,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: alice
cn: Alice Developer
sn: Developer
mail: alice@tkos.co.il
userPassword: ${USER_PW_HASH}
EOF
)" "$ADMIN_DN" "$TEST_PW"

ldap_add_if_missing "uid=bob,ou=people,${BASE_DN}" "$(cat <<EOF
dn: uid=bob,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: bob
cn: Bob Developer
sn: Developer
mail: bob@tkos.co.il
userPassword: ${USER_PW_HASH}
EOF
)" "$ADMIN_DN" "$TEST_PW"

ldap_add_if_missing "uid=carol,ou=people,${BASE_DN}" "$(cat <<EOF
dn: uid=carol,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: carol
cn: Carol Admin
sn: Admin
mail: carol@tkos.co.il
userPassword: ${USER_PW_HASH}
EOF
)" "$ADMIN_DN" "$TEST_PW"

# --- 4. groups (groupOfNames, requires >=1 member) ---
ldap_add_if_missing "cn=developers,ou=groups,${BASE_DN}" "$(cat <<EOF
dn: cn=developers,ou=groups,${BASE_DN}
objectClass: groupOfNames
cn: developers
member: uid=alice,ou=people,${BASE_DN}
member: uid=bob,ou=people,${BASE_DN}
EOF
)" "$ADMIN_DN" "$TEST_PW"

ldap_add_if_missing "cn=admins,ou=groups,${BASE_DN}" "$(cat <<EOF
dn: cn=admins,ou=groups,${BASE_DN}
objectClass: groupOfNames
cn: admins
member: uid=carol,ou=people,${BASE_DN}
EOF
)" "$ADMIN_DN" "$TEST_PW"

log "ou=people, ou=groups, users alice/bob/carol, groups developers/admins are all present."

# --- 5. sanity check: bind as alice ---
ldapwhoami -x -D "uid=alice,ou=people,${BASE_DN}" -w "${TEST_PW}" -H ldapi:///

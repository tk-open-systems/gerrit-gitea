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
set -euo pipefail

BASE_DN="dc=tkos,dc=co,dc=il"
ADMIN_DN="cn=admin,${BASE_DN}"
TEST_PW="ChangeMe123!"

# --- 1. find the mdb database entry under cn=config and set its rootPW ---
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn \
  2>/dev/null | awk -F': ' '/^dn:/{print $2}')

if [ -z "$DB_DN" ]; then
  echo "ERROR: could not find mdb database entry for suffix ${BASE_DN} under cn=config" >&2
  exit 1
fi
echo "Found database entry: $DB_DN"

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

echo "OK: admin bind DN is now ${ADMIN_DN} (password: ${TEST_PW})"

# --- 2. base structure: ou=people, ou=groups ---
ldapadd -x -D "${ADMIN_DN}" -w "${TEST_PW}" -H ldapi:/// <<EOF
dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups
EOF

# --- 3. test users (inetOrgPerson) ---
USER_PW_HASH=$(slappasswd -s "$TEST_PW")

ldapadd -x -D "${ADMIN_DN}" -w "${TEST_PW}" -H ldapi:/// <<EOF
dn: uid=alice,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: alice
cn: Alice Developer
sn: Developer
mail: alice@tkos.co.il
userPassword: ${USER_PW_HASH}

dn: uid=bob,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: bob
cn: Bob Developer
sn: Developer
mail: bob@tkos.co.il
userPassword: ${USER_PW_HASH}

dn: uid=carol,ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: carol
cn: Carol Admin
sn: Admin
mail: carol@tkos.co.il
userPassword: ${USER_PW_HASH}
EOF

# --- 4. groups (groupOfNames, requires >=1 member) ---
ldapadd -x -D "${ADMIN_DN}" -w "${TEST_PW}" -H ldapi:/// <<EOF
dn: cn=developers,ou=groups,${BASE_DN}
objectClass: groupOfNames
cn: developers
member: uid=alice,ou=people,${BASE_DN}
member: uid=bob,ou=people,${BASE_DN}

dn: cn=admins,ou=groups,${BASE_DN}
objectClass: groupOfNames
cn: admins
member: uid=carol,ou=people,${BASE_DN}
EOF

echo "OK: loaded ou=people, ou=groups, users alice/bob/carol, groups developers/admins."

# --- 5. sanity check: bind as alice ---
ldapwhoami -x -D "uid=alice,ou=people,${BASE_DN}" -w "${TEST_PW}" -H ldapi:///

#!/usr/bin/env bash
# Production hardening: remove the lab test users (alice/bob/carol)
# created by scripts/install/02-openldap.sh, once they're no longer
# needed for testing -- see ADMIN.md's "Removing the lab test users"
# for the full rationale; this script automates the procedure
# documented there instead of leaving it to a manual walkthrough.
#
# Run as root:
#   sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
#     bash 17-remove-test-users.sh
#
# Prerequisite: gerrit-bot must already exist and hold Gerrit admin
# rights (see ADMIN.md's "Setting up the Gerrit service account" --
# `ggadmin-user add gerrit-bot ... admins`). carol is the other member
# of the LDAP `admins` group, and offboarding the last member of a
# group is refused (groupOfNames requires >=1 member) -- gerrit-bot
# staying in `admins` is what makes removing carol safe. If gerrit-bot
# isn't set up yet, this script fails on the carol step with that exact
# explanation (from scripts/day2/18-user-lifecycle.sh's own offboard
# guard), not a confusing LDAP error.
#
# Reuses scripts/day2/18-user-lifecycle.sh's `offboard --delete-entry`
# for each of the three users -- same LDAP-removal + Gerrit/Gitea-
# deactivation logic ADMIN.md documents, no reason to duplicate it here
# -- then handles the one thing offboard itself can't: alice/bob are
# the ONLY members of cn=developers, and groupOfNames can't have zero
# members, so removing both also means deleting that group entry, not
# just the two users. (If a real developer was already added to
# `developers` alongside alice/bob before this runs, the group is left
# alone instead -- it's no longer actually empty.)
#
# DESTRUCTIVE, but narrowly scoped and expected: this only ever touches
# alice/bob/carol and the developers group, never a real account. Not
# reversible -- matches scripts/hardening/11's credential rotation: a
# one-way step towards Day-2, not something that needs an interactive
# confirmation prompt every time (unlike scripts/teardown/21-22, which
# affect everything, this affects three specific, always-lab-only
# accounts). After this runs, several install/hardening scripts that
# authenticate as carol/alice/bob (scripts/install/04-07/09/10,
# scripts/hardening/12/14/15) can no longer be blindly rerun on this
# host -- expected, their job is already done.
#
# Safe to rerun: offboard is already idempotent (an already-gone user
# is a no-op, logged not errored), and the developers group is only
# deleted if it's actually still present and actually empty.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFBOARD="${SCRIPTS_DIR}/../day2/18-user-lifecycle.sh"
[ -x "$OFFBOARD" ] || die "expected $OFFBOARD to exist and be executable"

for var in LDAP_ADMIN_PW GERRIT_ADMIN_PW GITEA_ADMIN_PW; do
  [ -n "${!var:-}" ] || die "$var is not set -- see the top of this script for what it's needed for and where to get it.
  Rerun with it set: sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' bash ${SCRIPT_NAME}"
done

for uid in carol alice bob; do
  log "offboarding ${uid} (--delete-entry)..."
  bash "$OFFBOARD" offboard "$uid" --delete-entry
done

# --- delete cn=developers only if it's actually empty now ---
ADMIN_DN="cn=admin,${BASE_DN}"
DEV_DN="cn=developers,ou=groups,${BASE_DN}"
ldap_search() { ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost "$@"; }

if ldap_search -b "$DEV_DN" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  MEMBER_COUNT=$(ldap_search -b "$DEV_DN" -s base "(objectClass=*)" member 2>/dev/null | grep -c '^member:' || true)
  if [ "$MEMBER_COUNT" -eq 0 ]; then
    ldapdelete -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost "$DEV_DN"
    log "deleted now-empty LDAP group ${DEV_DN}"
    log "note: onboarding the first real developer needs this group recreated with them as its initial member -- see ADMIN.md's \"Removing the lab test users\" for the exact ldapmodify snippet."
  else
    log "LDAP group ${DEV_DN} still has ${MEMBER_COUNT} member(s) besides alice/bob -- a real developer must already be in it, leaving it in place"
  fi
else
  log "LDAP group ${DEV_DN} already gone"
fi

log "=== done. alice/bob/carol are removed from LDAP and deactivated in Gerrit/Gitea. ==="

#!/usr/bin/env bash
# Day-2 operation: LDAP group lifecycle (create/delete/members), the
# gap left by scripts/day2/user-lifecycle.sh's add-group/remove-group,
# which only manage MEMBERSHIP on a group that already exists (see its
# own add-group: `group_exists "$group" || die "no such group"`) --
# never the group entry's own lifecycle. Run as root on the Gerrit/Gitea
# host: sudo bash group-lifecycle.sh <command> ...
#
# The gap this closes, confirmed live: `ggadmin-user add <uid> ...`
# (no explicit group) defaults new users to `developers`, and refuses
# if that group doesn't exist -- which it won't, on any host that's
# already run scripts/post-install/final-remove-test-users.sh (that
# script deletes `developers` outright once alice/bob, its only
# members, are both removed -- ADMIN.md's "Removing the lab test
# users"). Onboarding the first real developer after that needs the
# group recreated first, with them as its initial member --
# `groupOfNames` requires at least one member even at creation, so
# there's no such thing as a bare empty group waiting for one.
#
# Needs LDAP_ADMIN_PW (cn=admin's current password -- sudo strips the
# environment by default, so pass it on the sudo command line, which
# sudo applies even under env_reset):
#
#   sudo LDAP_ADMIN_PW='...' bash group-lifecycle.sh create developers yba
#
# Usage:
#   group-lifecycle.sh create <group> <initial-member-uid>
#   group-lifecycle.sh delete <group>
#   group-lifecycle.sh members <group>
#
# create is safe to rerun: an already-existing group is left alone (a
# member is NOT retroactively added -- use `ggadmin-user add-group` for
# that once the group exists). delete is safe to rerun too: an
# already-gone group is a no-op, not an error. delete does not check
# membership first -- unlike scripts/post-install/final-remove-test-users.sh's
# inline group deletion, which only deletes cn=developers when alice/bob
# were its only members, this deletes the group entry outright whenever
# you ask it to, real members or not (their own LDAP entries are
# untouched either way -- membership lives on the group entry, not the
# user's).
set -euo pipefail
# readlink -f (not just dirname "$BASH_SOURCE") because scripts/day2/install-ggadmin-tools.sh
# installs this under /usr/local/sbin as a symlink -- BASH_SOURCE gives the
# symlink's own path, not its target, so resolving it here is what lets
# lib.sh/config.sh still be found one directory up from the real file,
# in scripts/.
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib.sh"
require_root

ADMIN_DN="cn=admin,${BASE_DN}"
GROUPS_BASE="ou=groups,${BASE_DN}"
PEOPLE_BASE="ou=people,${BASE_DN}"

usage() {
  cat >&2 <<EOF
Usage:
  $SCRIPT_NAME create <group> <initial-member-uid>
  $SCRIPT_NAME delete <group>
  $SCRIPT_NAME members <group>

See the top of this script for required environment variables.
EOF
  exit 1
}

# Usage must be reachable without secrets set -- check args before the
# LDAP_ADMIN_PW requirement below, not after.
case "${1:-}" in
  ""|-h|--help) usage ;;
esac

# %q-quoted so the suggested fix below is the exact command actually run,
# safe to paste back even if an argument has spaces or quotes in it.
ORIG_ARGS_Q=$(printf '%q ' "$@")

if [ -z "${LDAP_ADMIN_PW:-}" ]; then
  die "LDAP_ADMIN_PW is not set (cn=admin current password).
  Get it from: scripts/post-install/set-service-credentials.sh ldap-admin printed it the last time that ran; if it was never run, it is still the install default, ChangeMe123!
  Then rerun this exact command with it set:
    LDAP_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${ORIG_ARGS_Q}
  (invoking via sudo instead of already being root? put VAR=value right after the word sudo, since sudo otherwise drops plain env vars: sudo LDAP_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${ORIG_ARGS_Q})"
fi
verify_ldap_cred "LDAP_ADMIN_PW" "$ADMIN_DN" "$LDAP_ADMIN_PW" \
  || die "LDAP_ADMIN_PW is wrong -- see the WARNING line above.
  Get the current password from: scripts/post-install/set-service-credentials.sh ldap-admin printed it the last time that ran; if it was never run, it is still the install default, ChangeMe123!
  Then rerun this exact command with it fixed:
    LDAP_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${ORIG_ARGS_Q}"

ldap_search() { ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost "$@"; }
ldap_modify() { ldapmodify -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost "$@"; }

user_dn() { printf 'uid=%s,%s' "$1" "$PEOPLE_BASE"; }
group_dn() { printf 'cn=%s,%s' "$1" "$GROUPS_BASE"; }

user_exists() {
  ldap_search -b "$(user_dn "$1")" -s base "(objectClass=*)" dn >/dev/null 2>&1
}

group_exists() {
  ldap_search -b "$(group_dn "$1")" -s base "(objectClass=*)" dn >/dev/null 2>&1
}

cmd_create() {
  local group=$1 member_uid=$2

  if group_exists "$group"; then
    log "group '${group}' already exists, leaving it as-is -- to add a member, use: ggadmin-user add-group ${member_uid} ${group}"
    return 0
  fi
  user_exists "$member_uid" || die "no LDAP entry for uid=${member_uid} -- create it first (ggadmin-user add ${member_uid} <full name> <email>), or pick an existing uid as the initial member"

  ldap_modify <<EOF
dn: $(group_dn "$group")
changetype: add
objectClass: groupOfNames
cn: ${group}
member: $(user_dn "$member_uid")
EOF
  log "created group '${group}' with initial member uid=${member_uid}"
}

cmd_delete() {
  local group=$1

  if ! group_exists "$group"; then
    log "group '${group}' already gone, skipping"
    return 0
  fi
  ldap_modify <<EOF
dn: $(group_dn "$group")
changetype: delete
EOF
  log "deleted group '${group}'"
}

cmd_members() {
  local group=$1
  group_exists "$group" || die "no such group: $group"
  local m
  m=$(ldap_search -b "$(group_dn "$group")" -s base "(objectClass=*)" member 2>/dev/null \
    | sed -n "s/^member: uid=\\([^,]*\\),ou=people,.*/\\1/p")
  if [ -z "$m" ]; then
    log "group '${group}' has no members"
  else
    printf '%s\n' "$m"
  fi
}

[ $# -ge 1 ] || usage
CMD=$1; shift
case "$CMD" in
  create)   [ $# -eq 2 ] || usage; cmd_create "$@" ;;
  delete)   [ $# -eq 1 ] || usage; cmd_delete "$@" ;;
  members)  [ $# -eq 1 ] || usage; cmd_members "$@" ;;
  *) usage ;;
esac

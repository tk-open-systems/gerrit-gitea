#!/usr/bin/env bash
# Day-2 operation: user lifecycle (add/modify/offboard), scripting
# ADMIN.md section 1. Run as root on the Gerrit/Gitea host: sudo bash
# 18-user-lifecycle.sh <command> ...
#
# Gerrit and Gitea are pure LDAP-auth consumers (WORKFLOW.md section 1)
# -- accounts are never created directly in either, only in LDAP. This
# script's job is everything ADMIN.md section 1 documents by hand:
# create/update the LDAP identity, and where a subcommand also touches
# Gerrit/Gitea (offboard/reactivate), account for the asymmetry ADMIN.md
# found: Gerrit reflects LDAP group changes on the very next request,
# Gitea only resyncs at login time.
#
# Needs LDAP_ADMIN_PW always (cn=admin's current password -- rotated by
# scripts/11-rotate-credentials.sh, so there's no safe default to fall
# back to here). offboard/reactivate also need GERRIT_ADMIN_PW and
# GITEA_ADMIN_PW (current passwords for the carol/gitea-admin admin
# accounts). sudo strips the environment by default, so pass these on
# the sudo command line (sudo still applies them under env_reset):
#
#   sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
#     bash 18-user-lifecycle.sh offboard dave
#
# Usage:
#   18-user-lifecycle.sh add <uid> <full name> <email> [group ...]
#   18-user-lifecycle.sh set-password <uid>
#   18-user-lifecycle.sh groups <uid>
#   18-user-lifecycle.sh add-group <uid> <group>
#   18-user-lifecycle.sh remove-group <uid> <group>
#   18-user-lifecycle.sh offboard <uid> [--delete-entry]
#   18-user-lifecycle.sh reactivate <uid>
#
# add/set-password print a freshly generated password once at the end
# (or use the one given via NEW_USER_PW) -- nothing is stored by this
# script itself; capture it there.
#
# add-group/remove-group are skip-if-already-applied (idempotent).
# offboard always removes the uid from every group it's currently in
# (idempotent: no-op if already out of all of them) and explicitly
# deactivates the Gerrit/Gitea accounts if they exist; --delete-entry
# additionally removes the LDAP entry itself (ADMIN.md's "at minimum
# pull them out of every group" vs. full removal choice). Either way,
# per ADMIN.md, nothing in Gerrit/Gitea's own history (commits,
# reviews, issue comments) is ever touched.
set -euo pipefail
# readlink -f (not just dirname "$BASH_SOURCE") because scripts/20 installs
# this under /usr/local/sbin as a symlink -- BASH_SOURCE gives the symlink's
# own path, not its target, so resolving it here is what lets lib.sh/
# config.sh still be found next to the real file in scripts/.
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"
require_root

ADMIN_DN="cn=admin,${BASE_DN}"
PEOPLE_BASE="ou=people,${BASE_DN}"
GROUPS_BASE="ou=groups,${BASE_DN}"
GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"
GERRIT_ADMIN_USER="${GERRIT_ADMIN_USER:-carol}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"

usage() {
  cat >&2 <<EOF
Usage:
  $SCRIPT_NAME add <uid> <full name> <email> [group ...]
  $SCRIPT_NAME set-password <uid>
  $SCRIPT_NAME groups <uid>
  $SCRIPT_NAME add-group <uid> <group>
  $SCRIPT_NAME remove-group <uid> <group>
  $SCRIPT_NAME offboard <uid> [--delete-entry]
  $SCRIPT_NAME reactivate <uid>

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
# safe to paste back even if an argument (e.g. a full name) has spaces.
ORIG_ARGS_Q=$(printf '%q ' "$@")

: "${LDAP_ADMIN_PW:?Missing LDAP_ADMIN_PW (cn=admin current password).
Already root, no sudo:
  LDAP_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${ORIG_ARGS_Q}
Via sudo (sudo strips plain env vars, so it goes on its command line):
  sudo LDAP_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${ORIG_ARGS_Q}
Value: whatever scripts/11-rotate-credentials.sh last set it to, or the
bootstrap default ChangeMe123! if that script was never run.}"

gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo; }

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

is_member() {
  local uid=$1 group=$2
  ldap_search -b "$(group_dn "$group")" -s base \
    "(member=$(user_dn "$uid"))" dn 2>/dev/null | grep -q "^dn:"
}

# groupOfNames requires at least one member attribute (schema MUST) --
# LDAP itself rejects a delete that would empty a group ("Object class
# violation") rather than allow it. Check for that case ourselves so we
# can explain it instead of surfacing that cryptic error.
group_member_count() {
  ldap_search -b "$(group_dn "$1")" -s base "(objectClass=*)" member 2>/dev/null \
    | grep -c "^member:" || true
}

# groups_of UID -- prints one group cn per line
groups_of() {
  local uid=$1
  ldap_search -b "$GROUPS_BASE" -s sub \
    "(member=$(user_dn "$uid"))" cn 2>/dev/null \
    | sed -n 's/^cn: //p'
}

cmd_add() {
  local uid=$1 full_name=$2 email=$3; shift 3
  local groups=("$@")
  [ ${#groups[@]} -gt 0 ] || groups=(developers)

  user_exists "$uid" && die "LDAP entry already exists for uid=$uid -- use set-password/add-group instead"

  local sn=${full_name##* }
  local pw=${NEW_USER_PW:-$(gen_pw)}
  local hash; hash=$(/usr/sbin/slappasswd -s "$pw")

  ldap_modify <<EOF
dn: $(user_dn "$uid")
changetype: add
objectClass: inetOrgPerson
uid: ${uid}
cn: ${full_name}
sn: ${sn}
mail: ${email}
userPassword: ${hash}
EOF
  log "created LDAP entry uid=${uid}"

  local g
  for g in "${groups[@]}"; do
    group_exists "$g" || die "group '$g' does not exist -- create it first, or pick an existing one"
    ldap_modify <<EOF
dn: $(group_dn "$g")
changetype: modify
add: member
member: $(user_dn "$uid")
EOF
    log "added uid=${uid} to group '${g}'"
  done

  cat <<EOF
=== User created ===
  uid      : ${uid}
  password : ${pw}
Gerrit/Gitea auto-provision the account on first authenticated request
(their first login, or first git push/API call). To pre-provision now:
  curl -u ${uid}:'${pw}' ${GERRIT_URL}/a/accounts/self
  curl -u ${uid}:'${pw}' ${GITEA_URL}/api/v1/user
EOF
}

cmd_set_password() {
  local uid=$1
  user_exists "$uid" || die "no LDAP entry for uid=$uid"
  local pw=${NEW_USER_PW:-$(gen_pw)}
  local hash; hash=$(/usr/sbin/slappasswd -s "$pw")
  ldap_modify <<EOF
dn: $(user_dn "$uid")
changetype: modify
replace: userPassword
userPassword: ${hash}
EOF
  cat <<EOF
=== Password changed ===
  uid      : ${uid}
  password : ${pw}
EOF
}

cmd_groups() {
  local uid=$1
  user_exists "$uid" || die "no LDAP entry for uid=$uid"
  local g; g=$(groups_of "$uid")
  if [ -z "$g" ]; then
    log "uid=${uid} is in no groups"
  else
    printf '%s\n' "$g"
  fi
}

cmd_add_group() {
  local uid=$1 group=$2
  user_exists "$uid" || die "no LDAP entry for uid=$uid"
  group_exists "$group" || die "no such group: $group"
  if is_member "$uid" "$group"; then
    log "uid=${uid} already in '${group}', skipping"
    return 0
  fi
  ldap_modify <<EOF
dn: $(group_dn "$group")
changetype: modify
add: member
member: $(user_dn "$uid")
EOF
  log "added uid=${uid} to group '${group}' -- Gerrit picks this up on their next request; Gitea only at their next login (or the sync_external_users cron task) -- see ADMIN.md section 1"
}

cmd_remove_group() {
  local uid=$1 group=$2
  group_exists "$group" || die "no such group: $group"
  if ! is_member "$uid" "$group"; then
    log "uid=${uid} already not in '${group}', skipping"
    return 0
  fi
  if [ "$(group_member_count "$group")" -le 1 ]; then
    die "uid=${uid} is the last member of '${group}' -- groupOfNames requires at least one member, so LDAP would reject this (that's the 'Object class violation' you'd otherwise see). Add another member to '${group}' first, or if you want the group gone, delete its LDAP entry outright instead of emptying it."
  fi
  ldap_modify <<EOF
dn: $(group_dn "$group")
changetype: modify
delete: member
member: $(user_dn "$uid")
EOF
  log "removed uid=${uid} from group '${group}' -- same Gerrit-immediate/Gitea-at-login asymmetry as add-group"
}

cmd_offboard() {
  local uid=$1; shift
  local delete_entry=0
  [ "${1:-}" = "--delete-entry" ] && delete_entry=1

  local had_groups=0
  local g hint
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    had_groups=1
    if [ "$(group_member_count "$g")" -le 1 ]; then
      hint=""
      [ "$g" = "admins" ] && hint=" -- '${g}' is the group granting Gerrit/Gitea admin rights (ADMIN.md section 1), so this would remove the last admin"
      die "uid=${uid} is the last member of '${g}'${hint}. groupOfNames requires at least one member, so LDAP would reject removing them (the 'Object class violation' error). Add another member to '${g}' first (${SCRIPT_NAME} add-group <other-uid> ${g}), or delete '${g}' outright if you mean for it to be gone. Note: uid=${uid} may have already been removed from other groups above before this one was hit -- rerun offboard afterward to finish the rest."
    fi
    ldap_modify <<EOF
dn: $(group_dn "$g")
changetype: modify
delete: member
member: $(user_dn "$uid")
EOF
    log "removed uid=${uid} from group '${g}'"
  done < <(groups_of "$uid")
  [ "$had_groups" -eq 1 ] || log "uid=${uid} was already in no groups"

  if [ "$delete_entry" -eq 1 ]; then
    if user_exists "$uid"; then
      ldap_modify <<EOF
dn: $(user_dn "$uid")
changetype: delete
EOF
      log "deleted LDAP entry uid=${uid}"
    else
      log "LDAP entry uid=${uid} already gone, skipping delete"
    fi
  fi

  local orig_cmd="offboard $(printf '%q' "$uid")"
  [ "$delete_entry" -eq 1 ] && orig_cmd="${orig_cmd} --delete-entry"
  : "${GERRIT_ADMIN_PW:?Missing GERRIT_ADMIN_PW (current password for ${GERRIT_ADMIN_USER}) -- needed to also deactivate the Gerrit/Gitea accounts.
Already root, no sudo:
  GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}
Via sudo (sudo strips plain env vars, so they go on its command line):
  sudo GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}}"
  : "${GITEA_ADMIN_PW:?Missing GITEA_ADMIN_PW (current password for ${GITEA_ADMIN_USER}) -- needed to also deactivate the Gerrit/Gitea accounts.
Already root, no sudo:
  GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}
Via sudo (sudo strips plain env vars, so they go on its command line):
  sudo GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}}"

  local acct_json account_id
  acct_json=$(curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" \
    "${GERRIT_URL}/a/accounts/${uid}" 2>/dev/null || true)
  if [ -z "$acct_json" ]; then
    log "no Gerrit account for '${uid}' (never logged in) -- nothing to deactivate there"
  else
    account_id=$(echo "$acct_json" | tail -n +2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["_account_id"])')
    curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" -X DELETE \
      "${GERRIT_URL}/a/accounts/${account_id}/active" >/dev/null
    # ADMIN.md: the DELETE .../active response's own status-code semantics
    # were inconsistent in testing -- confirm via a search instead.
    if curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" \
         "${GERRIT_URL}/a/accounts/?q=is:inactive+username:${uid}" \
         | tail -n +2 | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
      log "confirmed Gerrit account '${uid}' (id ${account_id}) is inactive"
    else
      warn "deactivated Gerrit account '${uid}' but it did not show up under is:inactive -- verify manually"
    fi
  fi

  if curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PW}" -o /dev/null \
       "${GITEA_URL}/api/v1/users/${uid}" 2>/dev/null; then
    curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PW}" -X PATCH \
      -H 'Content-Type: application/json' \
      -d "{\"login_name\":\"${uid}\",\"source_id\":0,\"active\":false}" \
      "${GITEA_URL}/api/v1/admin/users/${uid}" >/dev/null
    log "deactivated Gitea account '${uid}'"
  else
    log "no Gitea account for '${uid}' (never logged in) -- nothing to deactivate there"
  fi
}

cmd_reactivate() {
  local uid=$1
  local orig_cmd="reactivate $(printf '%q' "$uid")"
  : "${GERRIT_ADMIN_PW:?Missing GERRIT_ADMIN_PW (current password for ${GERRIT_ADMIN_USER}).
Already root, no sudo:
  GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}
Via sudo (sudo strips plain env vars, so they go on its command line):
  sudo GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}}"
  : "${GITEA_ADMIN_PW:?Missing GITEA_ADMIN_PW (current password for ${GITEA_ADMIN_USER}).
Already root, no sudo:
  GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}
Via sudo (sudo strips plain env vars, so they go on its command line):
  sudo GERRIT_ADMIN_PW=\"...\" GITEA_ADMIN_PW=\"...\" ${SCRIPT_NAME} ${orig_cmd}}"

  local acct_json account_id
  acct_json=$(curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" \
    "${GERRIT_URL}/a/accounts/${uid}" 2>/dev/null || true)
  if [ -z "$acct_json" ]; then
    log "no Gerrit account for '${uid}' -- nothing to reactivate there"
  else
    account_id=$(echo "$acct_json" | tail -n +2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["_account_id"])')
    curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" -X PUT \
      "${GERRIT_URL}/a/accounts/${account_id}/active" >/dev/null
    log "reactivated Gerrit account '${uid}' (id ${account_id})"
  fi

  if curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PW}" -o /dev/null \
       "${GITEA_URL}/api/v1/users/${uid}" 2>/dev/null; then
    curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PW}" -X PATCH \
      -H 'Content-Type: application/json' \
      -d "{\"login_name\":\"${uid}\",\"source_id\":0,\"active\":true}" \
      "${GITEA_URL}/api/v1/admin/users/${uid}" >/dev/null
    log "reactivated Gitea account '${uid}'"
  else
    log "no Gitea account for '${uid}' -- nothing to reactivate there"
  fi

  log "reminder: reactivating here only undoes the explicit deactivation -- if they were also pulled from LDAP groups during offboarding, re-add them (add-group) for Gerrit/Gitea access to actually work again"
}

[ $# -ge 1 ] || usage
CMD=$1; shift
case "$CMD" in
  add)           [ $# -ge 3 ] || usage; cmd_add "$@" ;;
  set-password)  [ $# -eq 1 ] || usage; cmd_set_password "$@" ;;
  groups)        [ $# -eq 1 ] || usage; cmd_groups "$@" ;;
  add-group)     [ $# -eq 2 ] || usage; cmd_add_group "$@" ;;
  remove-group)  [ $# -eq 2 ] || usage; cmd_remove_group "$@" ;;
  offboard)      [ $# -ge 1 ] && [ $# -le 2 ] || usage; cmd_offboard "$@" ;;
  reactivate)    [ $# -eq 1 ] || usage; cmd_reactivate "$@" ;;
  *) usage ;;
esac

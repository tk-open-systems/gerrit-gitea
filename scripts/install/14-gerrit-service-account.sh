#!/usr/bin/env bash
# Creates gerrit-bot: the dedicated, non-human LDAP account meant to
# hold Gerrit admin rights instead of a real person. Part of the same
# required bootstrap as the rest of scripts/install/, not optional
# hardening -- see ADMIN.md's "Setting up the Gerrit service account"
# for the full rationale (GERRIT_ADMIN_USER used to default to carol,
# a real person's LDAP login reused as the automation credential --
# fragile, and un-auditable).
#
# Also the prerequisite scripts/post-install/final-remove-test-users.sh
# needs: carol and gerrit-bot end up the only two members of the LDAP
# `admins` group, and LDAP refuses to remove the last member of a
# groupOfNames -- gerrit-bot staying in `admins` is what makes removing
# carol safe later. Skipping this script is exactly what produces
# "uid=carol is the last member of 'admins'" out of
# scripts/day2/user-lifecycle.sh offboard.
#
# Run as root, after scripts/install/05-gerrit-acl.sh (needs the
# `admins` LDAP group and Gerrit's own LDAP auth already working):
#
#   sudo LDAP_ADMIN_PW='...' bash 14-gerrit-service-account.sh
#
# Deliberately does NOT pre-provision gerrit-bot in Gitea, unlike the
# curl suggestion scripts/day2/user-lifecycle.sh's own `add` output
# prints for every new user -- being in `admins` would make it a Gitea
# org Owner the moment it ever authenticates there, scope this
# account never needs (ADMIN.md).
#
# Safe to rerun: skips creation if uid=gerrit-bot already exists in
# LDAP, only re-verifying its group membership in that case (its
# password is unknown to this script then -- nothing is ever
# persisted -- so the Gerrit admin-rights check only runs right after
# creation, when the password is still in hand). Use
# scripts/day2/user-lifecycle.sh set-password gerrit-bot if you need a
# known password again later.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

: "${LDAP_ADMIN_PW:?Set LDAP_ADMIN_PW to cn=admins current password. Test-lab default: ChangeMe123! (printed by scripts/install/02-openldap.sh); only different if someone ran scripts/post-install/set-service-credentials.sh ldap-admin since.}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_LIFECYCLE="${SCRIPTS_DIR}/../day2/user-lifecycle.sh"
[ -x "$USER_LIFECYCLE" ] || die "expected $USER_LIFECYCLE to exist and be executable"

GERRIT_URL="http://127.0.0.1:8080"
ADMIN_DN="cn=admin,${BASE_DN}"
BOT_DN="uid=gerrit-bot,ou=people,${BASE_DN}"
ADMINS_DN="cn=admins,ou=groups,${BASE_DN}"
ldap_search() { ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost "$@"; }

if ldap_search -b "$BOT_DN" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  log "uid=gerrit-bot already exists, skipping creation."
  IS_MEMBER=$(ldap_search -b "$ADMINS_DN" -s base "(member=${BOT_DN})" dn 2>/dev/null | grep -c '^dn:' || true)
  [ "$IS_MEMBER" -ge 1 ] || die "uid=gerrit-bot exists but is not a member of cn=admins -- add it: sudo LDAP_ADMIN_PW='...' bash ${USER_LIFECYCLE} add-group gerrit-bot admins"
  log "confirmed: gerrit-bot is a member of admins"
else
  GERRIT_BOT_PW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo)
  NEW_USER_PW="$GERRIT_BOT_PW" \
    bash "$USER_LIFECYCLE" add gerrit-bot "Gerrit Service Account" gerrit-bot@tkos.co.il admins
  log "created gerrit-bot and added it to admins"

  curl -fsS -u "gerrit-bot:${GERRIT_BOT_PW}" "${GERRIT_URL}/a/accounts/self/capabilities" | tail -n +2 \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("administrateServer") else 1)' \
    || die "gerrit-bot was created but does not have administrateServer in Gerrit -- check the admins LDAP group and Gerrit's ldap.accountPattern config"
  log "confirmed: gerrit-bot has administrateServer in Gerrit"
  log "gerrit-bot password: ${GERRIT_BOT_PW} -- capture this now, nothing persists it. Rotate later with: scripts/day2/user-lifecycle.sh set-password gerrit-bot"
fi

log "OK: gerrit-bot exists and is in admins, ready to be GERRIT_ADMIN_USER for scripts/day2/."

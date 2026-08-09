#!/usr/bin/env bash
# Phase 5a: wire Gerrit's authorization to the LDAP "admins" group.
# Run as root: sudo bash 05-gerrit-acl.sh
#
# Gerrit already binds *authentication* to LDAP (phase 4). This phase
# handles *authorization*: Gerrit auto-promotes the first account it
# ever sees to the internal "Administrators" group, which is how carol
# (our LDAP admins-group user) becomes the initial site admin here --
# but that's a one-time bootstrap trick, not a durable mapping. Anyone
# ELSE later added to the LDAP "admins" group would NOT automatically
# get Gerrit admin rights from that trick alone. So this script adds
# `ldap/cn=admins,ou=groups,dc=tkos,dc=co,dc=il` directly into
# All-Projects' ACL (administrateServer capability, Code-Review -2..+2,
# submit) -- Gerrit resolves "ldap/<dn>" group references against LDAP
# live, so membership in that one LDAP group is now the durable,
# single source of truth for who gets admin rights in Gerrit. This is
# exactly the "each role is defined once" design from WORKFLOW.md.
#
# Mechanics: enables auth.gitBasicAuthPolicy=LDAP so we can drive the
# REST API and git-over-http with carol's LDAP password directly, then
# provisions her account, pushes an edit to All-Projects'
# refs/meta/config as a real Gerrit change (refs/for/refs/meta/config),
# and self-approves + submits it via REST -- the same flow a human
# admin would use, just scripted.
#
# Safe to rerun: the gitBasicAuthPolicy edit is a no-op if already set
# (restart only happens if it actually changed); account provisioning
# via GET self is inherently idempotent; the ACL edit is skipped if
# the target lines are already present in project.config.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

SITE=/var/lib/gerrit
ADMINS_GROUP_DN="cn=admins,ou=groups,${BASE_DN}"
TEST_PW="ChangeMe123!"   # test-lab only, see scripts/02-openldap.sh
GERRIT_URL="http://127.0.0.1:8080"

cd "$SITE"

# --- 1. allow HTTP basic auth to validate directly against LDAP ---
CURRENT=$(git config -f "$SITE/etc/gerrit.config" --get auth.gitBasicAuthPolicy || true)
if [ "$CURRENT" = "LDAP" ]; then
  log "auth.gitBasicAuthPolicy already LDAP."
else
  sudo -u gerrit git config -f "$SITE/etc/gerrit.config" auth.gitBasicAuthPolicy LDAP
  log "set auth.gitBasicAuthPolicy=LDAP, restarting gerrit to apply."
  systemctl restart gerrit
  wait_for_http "${GERRIT_URL}/" 60 \
    "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"
fi

# --- 2. provision carol's account (auto-promoted to Administrators: first-ever account) ---
CAROL_JSON=$(curl -fsS -u "carol:${TEST_PW}" "${GERRIT_URL}/a/accounts/self" | tail -n +2)
echo "$CAROL_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("carol account_id=" + str(d["_account_id"]) + " name=" + str(d.get("name")))'

CAPS=$(curl -fsS -u "carol:${TEST_PW}" "${GERRIT_URL}/a/accounts/self/capabilities" | tail -n +2)
if echo "$CAPS" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("administrateServer") else 1)'; then
  log "carol has administrateServer (site admin) -- bootstrap confirmed."
else
  die "carol does not have administrateServer; expected auto-promotion as the first Gerrit account. Check for pre-existing accounts."
fi

# --- 3. edit All-Projects' refs/meta/config ACL, as a real Gerrit change ---
MARKER="group ldap/${ADMINS_GROUP_DN}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

AUTH_URL="http://carol:${TEST_PW}@127.0.0.1:8080/a/All-Projects"
git init -q repo && cd repo
git -c protocol.version=2 fetch -q "$AUTH_URL" refs/meta/config
git checkout -q FETCH_HEAD

if grep -qF "$MARKER" project.config; then
  log "project.config already grants ${MARKER}, nothing to push."
else
  python3 - "$MARKER" "$ADMINS_GROUP_DN" <<'PYEOF'
import sys
marker, dn = sys.argv[1], sys.argv[2]
with open("project.config") as f:
    lines = f.readlines()

def insert_after(lines, section, new_lines):
    out = []
    i = 0
    n = len(lines)
    while i < n:
        out.append(lines[i])
        if lines[i].strip() == section:
            j = i + 1
            while j < n and not lines[j].startswith('['):
                out.append(lines[j])
                j += 1
            out.extend(new_lines)
            i = j
            continue
        i += 1
    return out

lines = insert_after(lines, '[capability]', [f"\tadministrateServer = group ldap/{dn}\n"])
lines = insert_after(lines, '[access "refs/heads/*"]', [
    f"\tlabel-Code-Review = -2..+2 group ldap/{dn}\n",
    f"\tsubmit = group ldap/{dn}\n",
])

with open("project.config", "w") as f:
    f.writelines(lines)
PYEOF
  grep -qF "$MARKER" project.config || die "failed to insert ACL entry into project.config"

  # project.config's ACL lines reference a group by NAME; Gerrit resolves
  # that name to a UUID via the sibling "groups" file (also part of
  # refs/meta/config) and rejects the push if the name isn't registered
  # there. For an LDAP group the convention is UUID "ldap:<dn>" mapped to
  # Name "ldap/<dn>" (the same string used in project.config).
  GROUPS_LINE="$(printf 'ldap:%s\tldap/%s' "$ADMINS_GROUP_DN" "$ADMINS_GROUP_DN")"
  if ! grep -qF "ldap:${ADMINS_GROUP_DN}" groups; then
    printf '%s\n' "$GROUPS_LINE" >> groups
  fi

  CHANGE_ID="I$(openssl rand -hex 20)"
  git -c user.name="Lab Bootstrap" -c user.email="carol@tkos.co.il" \
    commit -q -a -m "$(printf 'Grant LDAP admins group Gerrit admin rights\n\nChange-Id: %s\n' "$CHANGE_ID")"

  git push -q "$AUTH_URL" "HEAD:refs/for/refs/meta/config"
  log "pushed ACL change ${CHANGE_ID} for review"

  CHANGE_NUM=$(curl -fsS -u "carol:${TEST_PW}" \
    "${GERRIT_URL}/a/changes/?q=change:${CHANGE_ID}" | tail -n +2 \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')

  curl -fsS -u "carol:${TEST_PW}" -X POST -H 'Content-Type: application/json' \
    -d '{"labels":{"Code-Review":2}}' \
    "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/current/review" >/dev/null
  curl -fsS -u "carol:${TEST_PW}" -X POST \
    "${GERRIT_URL}/a/changes/${CHANGE_NUM}/submit" >/dev/null
  log "self-approved and submitted change ${CHANGE_NUM}: ldap/${ADMINS_GROUP_DN} now has Gerrit admin rights."
fi

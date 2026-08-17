#!/usr/bin/env bash
# Phase 8: end-to-end smoke test of the full WORKFLOW.md flow.
# Run as root: sudo bash 09-smoke-test.sh
#
# Phases 4-7 already proved push -> review -> submit -> replicate
# repeatedly (via scripts/install/07-replication.sh's own verification step).
# The one piece of WORKFLOW.md's design not yet exercised is section 3:
# a Gerrit commit trailer ("Fixes org/repo#N") auto-closing the linked
# Gitea issue once the replicated push lands on the default branch.
# This script is the one place that actually proves that end to end:
#   1. open a fresh Gitea issue on engineering/replication-test
#   2. push+submit a Gerrit change whose commit message says
#      "Fixes engineering/replication-test#<N>"
#   3. wait for it to replicate (same technique as script 07)
#   4. confirm Gitea auto-closed the issue
#
# Not idempotent by design: it opens a brand-new issue and change each
# run, because reusing a previously-closed issue would let a rerun
# "pass" without actually exercising the auto-close mechanism again.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

TEST_PW="ChangeMe123!"   # test-lab only, see scripts/install/02-openldap.sh
GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"
ORG="engineering"
PROJECT="replication-test"

gitea_api() { curl -fsS -u "carol:${TEST_PW}" "$@"; }

# --- 1. open a fresh Gitea issue ---
STAMP=$(date -u +%FT%TZ)
ISSUE_JSON=$(gitea_api -X POST -H 'Content-Type: application/json' \
  -d "{\"title\": \"Smoke test issue (${STAMP})\", \"body\": \"Opened by scripts/install/09-smoke-test.sh to verify the Fixes-trailer auto-close flow.\"}" \
  "${GITEA_URL}/api/v1/repos/${ORG}/${PROJECT}/issues")
ISSUE_NUM=$(echo "$ISSUE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
log "opened Gitea issue ${ORG}/${PROJECT}#${ISSUE_NUM}"

# --- 2. push+submit a Gerrit change referencing it via the Fixes trailer ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
AUTH_URL="http://carol:${TEST_PW}@127.0.0.1:8080/a/${PROJECT}"
git clone -q "$AUTH_URL" repo
cd repo
echo "smoke test ${STAMP}, closes issue #${ISSUE_NUM}" > SMOKE_TEST.txt
git add SMOKE_TEST.txt
CHANGE_ID="I$(openssl rand -hex 20)"
git -c user.name="Lab Bootstrap" -c user.email="carol@tkos.co.il" commit -q -m "$(printf \
  'Add smoke test file\n\nFixes %s/%s#%s\n\nChange-Id: %s\n' "$ORG" "$PROJECT" "$ISSUE_NUM" "$CHANGE_ID")"
git push -q "$AUTH_URL" HEAD:refs/for/main

CHANGE_NUM=$(curl -fsS -u "carol:${TEST_PW}" \
  "${GERRIT_URL}/a/changes/?q=change:${CHANGE_ID}" | tail -n +2 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')
curl -fsS -u "carol:${TEST_PW}" -X POST -H 'Content-Type: application/json' \
  -d '{"labels":{"Code-Review":2}}' \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/current/review" >/dev/null
curl -fsS -u "carol:${TEST_PW}" -X POST \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/submit" >/dev/null
GERRIT_SHA=$(curl -fsS -u "carol:${TEST_PW}" \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}?o=CURRENT_REVISION" | tail -n +2 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["current_revision"])')
log "submitted change ${CHANGE_NUM} referencing issue #${ISSUE_NUM}; waiting for replication..."

# --- 3. wait for the commit to actually replicate ---
i=0
GITEA_SHA=""
until [ "$GITEA_SHA" = "$GERRIT_SHA" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || die "commit never replicated to Gitea after 30s -- check: journalctl -u gerrit -n 100 --no-pager | grep -i replicat"
  sleep 1
  GITEA_SHA=$( (gitea_api "${GITEA_URL}/api/v1/repos/${ORG}/${PROJECT}/branches/main" 2>/dev/null || true) \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["commit"]["id"])
except Exception: print("")')
done
log "commit replicated to Gitea (${GITEA_SHA:0:10})."

# --- 4. confirm the issue auto-closed ---
i=0
STATE=""
until [ "$STATE" = "closed" ]; do
  i=$((i + 1))
  [ "$i" -lt 15 ] || die "issue #${ISSUE_NUM} never auto-closed after replication -- check the 'Fixes' trailer parsing / default branch settings"
  sleep 1
  STATE=$(gitea_api "${GITEA_URL}/api/v1/repos/${ORG}/${PROJECT}/issues/${ISSUE_NUM}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
done

log "OK: full WORKFLOW.md flow verified end to end -- issue #${ISSUE_NUM} auto-closed by the replicated commit."

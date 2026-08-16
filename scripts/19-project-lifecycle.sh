#!/usr/bin/env bash
# Day-2 operation: project lifecycle (add/describe/delete), scripting
# ADMIN.md section 2. Run as root on the Gerrit/Gitea host: sudo bash
# 19-project-lifecycle.sh <command> ...
#
# Gerrit is the source of truth; Gitea's copy is a replication-plugin
# mirror (WORKFLOW.md section 2). This script encodes ADMIN.md's two
# "required follow-up steps" that push-to-create otherwise leaves out
# on every new project -- both confirmed live against this lab, not
# assumed from docs:
#   1. Pull Requests unit is enabled by default on an auto-created
#      Gitea repo even though no team is granted repo.pulls -- disabled
#      here explicitly (a unit existing at all is a competing
#      contribution path WORKFLOW.md means to prevent).
#   2. Gitea org Owners always have full Code admin on every org repo,
#      which team units_map cannot strip -- a branch-protection rule
#      restricting push/force-push to the Replication team (with admin
#      bypass blocked) is added explicitly, or an Owner-team account
#      can force-push straight past Gerrit review.
#
# Needs GERRIT_ADMIN_PW and GITEA_ADMIN_PW (current passwords for the
# carol/gitea-admin admin accounts -- rotated by
# scripts/11-rotate-credentials.sh, so there's no safe default here).
# sudo strips the environment by default, so pass these on the sudo
# command line (sudo still applies them under env_reset):
#
#   sudo GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
#     bash 19-project-lifecycle.sh add my-new-project "some description"
#
# delete additionally needs scripts/10-delete-project-plugin.sh already
# run once (Gerrit has no delete support without it).
#
# Usage:
#   19-project-lifecycle.sh add <project> [description]
#   19-project-lifecycle.sh describe <project> <description> [--gitea-too]
#   19-project-lifecycle.sh delete <project>
#
# add is safe to rerun: if the Gerrit project already exists it's left
# alone, but the two Gitea follow-ups are still (re-)applied -- handy
# for fixing up a project that was created before this script existed,
# or by hand. delete is safe to rerun too: a side already gone is
# skipped rather than erroring.
set -euo pipefail
# readlink -f (not just dirname "$BASH_SOURCE") because scripts/20 installs
# this under /usr/local/sbin as a symlink -- BASH_SOURCE gives the symlink's
# own path, not its target, so resolving it here is what lets lib.sh/
# config.sh still be found next to the real file in scripts/.
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"
require_root

GERRIT_URL="http://127.0.0.1:8080"
GITEA_URL="http://127.0.0.1:3000"
GERRIT_ADMIN_USER="${GERRIT_ADMIN_USER:-carol}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
ORG="${GITEA_ORG:-engineering}"
REPLICATION_TEAM="${REPLICATION_TEAM:-Replication}"

: "${GERRIT_ADMIN_PW:?Set GERRIT_ADMIN_PW to the current password for ${GERRIT_ADMIN_USER}}"
: "${GITEA_ADMIN_PW:?Set GITEA_ADMIN_PW to the current password for ${GITEA_ADMIN_USER}}"

gerrit_api() { curl -fsS -u "${GERRIT_ADMIN_USER}:${GERRIT_ADMIN_PW}" "$@"; }
gitea_api() { curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PW}" "$@"; }

gerrit_project_exists() {
  gerrit_api -o /dev/null "${GERRIT_URL}/a/projects/$1" 2>/dev/null
}

gitea_repo_exists() {
  gitea_api -o /dev/null "${GITEA_URL}/api/v1/repos/${ORG}/$1" 2>/dev/null
}

usage() {
  cat >&2 <<EOF
Usage:
  $SCRIPT_NAME add <project> [description]
  $SCRIPT_NAME describe <project> <description> [--gitea-too]
  $SCRIPT_NAME delete <project>

See the top of this script for required environment variables.
EOF
  exit 1
}

cmd_add() {
  local project=$1 description=${2:-}

  if gerrit_project_exists "$project"; then
    log "Gerrit project '${project}' already exists, leaving it as-is"
  else
    gerrit_api -X PUT -H 'Content-Type: application/json' \
      -d "{\"description\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$description"), \"create_empty_commit\": true, \"branches\": [\"main\"]}" \
      "${GERRIT_URL}/a/projects/${project}" >/dev/null
    log "created Gerrit project '${project}'"
  fi

  log "waiting for replication to create Gitea's mirror..."
  local i=0
  until gitea_repo_exists "$project"; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || die "Gitea repo '${ORG}/${project}' never appeared after 30s -- check: journalctl -u gerrit -n 100 --no-pager | grep -i replicat"
    sleep 1
  done
  log "Gitea mirror '${ORG}/${project}' is present"

  local has_pr
  has_pr=$(gitea_api "${GITEA_URL}/api/v1/repos/${ORG}/${project}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["has_pull_requests"])')
  if [ "$has_pr" = "True" ]; then
    gitea_api -X PATCH -H 'Content-Type: application/json' \
      -d '{"has_pull_requests": false}' \
      "${GITEA_URL}/api/v1/repos/${ORG}/${project}" >/dev/null
    log "disabled the Pull Requests unit on '${ORG}/${project}'"
  else
    log "Pull Requests unit already disabled on '${ORG}/${project}', skipping"
  fi

  if gitea_api "${GITEA_URL}/api/v1/repos/${ORG}/${project}/branch_protections" \
       | python3 -c 'import json,sys; sys.exit(0 if any(r.get("rule_name")=="**" for r in json.load(sys.stdin)) else 1)' 2>/dev/null; then
    log "branch protection rule '**' already exists on '${ORG}/${project}', skipping"
  else
    gitea_api -X POST -H 'Content-Type: application/json' \
      -d "{
        \"rule_name\": \"**\",
        \"enable_push\": true,
        \"enable_push_whitelist\": true,
        \"push_whitelist_teams\": [\"${REPLICATION_TEAM}\"],
        \"enable_force_push\": true,
        \"enable_force_push_allowlist\": true,
        \"force_push_allowlist_teams\": [\"${REPLICATION_TEAM}\"],
        \"block_admin_merge_override\": true
      }" \
      "${GITEA_URL}/api/v1/repos/${ORG}/${project}/branch_protections" >/dev/null
    log "added branch protection rule '**' restricting push/force-push to '${REPLICATION_TEAM}' on '${ORG}/${project}'"
  fi
}

cmd_describe() {
  local project=$1 description=$2 gitea_too=${3:-}

  gerrit_project_exists "$project" || die "no such Gerrit project: $project"
  gerrit_api -X PUT -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"description": sys.argv[1]}))' "$description")" \
    "${GERRIT_URL}/a/projects/${project}/description" >/dev/null
  log "updated Gerrit description for '${project}'"

  if [ "$gitea_too" = "--gitea-too" ]; then
    if gitea_repo_exists "$project"; then
      gitea_api -X PATCH -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; print(json.dumps({"description": sys.argv[1]}))' "$description")" \
        "${GITEA_URL}/api/v1/repos/${ORG}/${project}" >/dev/null
      log "updated Gitea description for '${ORG}/${project}'"
    else
      warn "no Gitea mirror '${ORG}/${project}' to update"
    fi
  else
    log "reminder: this metadata does not replicate (ADMIN.md section 2) -- pass --gitea-too to also update Gitea's copy"
  fi
}

cmd_delete() {
  local project=$1

  if gerrit_project_exists "$project"; then
    gerrit_api -X POST -H 'Content-Type: application/json' \
      -d '{"force": true, "preserve": false}' \
      "${GERRIT_URL}/a/projects/${project}/delete-project~delete" >/dev/null
    log "deleted Gerrit project '${project}' (needs scripts/10-delete-project-plugin.sh already run once)"
  else
    log "Gerrit project '${project}' already gone, skipping"
  fi

  if gitea_repo_exists "$project"; then
    gitea_api -X DELETE "${GITEA_URL}/api/v1/repos/${ORG}/${project}" >/dev/null
    log "deleted Gitea mirror '${ORG}/${project}'"
  else
    log "Gitea mirror '${ORG}/${project}' already gone, skipping"
  fi
}

[ $# -ge 1 ] || usage
CMD=$1; shift
case "$CMD" in
  add)      [ $# -ge 1 ] && [ $# -le 2 ] || usage; cmd_add "$@" ;;
  describe) [ $# -ge 2 ] && [ $# -le 3 ] || usage; cmd_describe "$@" ;;
  delete)   [ $# -eq 1 ] || usage; cmd_delete "$@" ;;
  *) usage ;;
esac

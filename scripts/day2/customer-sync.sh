#!/usr/bin/env bash
# Wraps WORKFLOW.md section 5's customer branch delivery procedure
# (Gerrit <-> GitLab, branch-per-cycle model). Run from a maintainer's
# own working clone with two remotes already set up:
#   "gerrit"           -> the internal Gerrit repo
#   "customer-<name>"  -> the customer's GitLab repo (add with:
#                          git remote add customer-<name> <gitlab-url>)
#
# Usage:
#   customer-sync.sh start-cycle <name>
#   customer-sync.sh deliver     <name> [cycle-branch]
#
# start-cycle imports the customer's current tree as a new Gerrit
# branch (customer/<name>/<date>-import) with no shared history to any
# previous cycle -- see WORKFLOW.md section 5 for why.
# deliver squash-exports a cycle branch's tip back to the customer as
# one commit, with a message built from commit subjects only (never
# commit bodies), so Change-Id and any other Gerrit trailer never has a
# path into the customer repo. If no cycle-branch is given, the most
# recently created customer/<name>/*-import branch on gerrit is used.
#
# Idempotent: rerunning start-cycle the same day with no new customer
# commits reuses the existing branch instead of creating a duplicate;
# rerunning deliver when the customer's tree already matches the cycle
# branch's tree is a no-op.
#
# This is a maintainer workstation tool, not a target-host install
# script, so unlike scripts/install and scripts/hardening it does not
# source lib.sh (no root requirement, no HOST_FQDN/BASE_DN relevance --
# this can run from any
# machine with the two remotes configured).
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
trap 'printf "[%s] ERROR: command failed (exit %s) at line %s: %s\n" "$SCRIPT_NAME" "$?" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat >&2 <<EOF
Usage:
  $SCRIPT_NAME start-cycle <name>
  $SCRIPT_NAME deliver     <name> [cycle-branch]

<name> is the customer identifier used for remote "customer-<name>" and
branch prefix "customer/<name>/". See WORKFLOW.md section 5.
EOF
  exit 1
}

[ $# -ge 1 ] || usage
CMD=$1; shift
case "$CMD" in
  start-cycle) [ $# -eq 1 ] || usage; NAME=$1 ;;
  deliver)     [ $# -ge 1 ] && [ $# -le 2 ] || usage; NAME=$1; CYCLE_ARG=${2:-} ;;
  *) usage ;;
esac

CUSTOMER_REMOTE="customer-${NAME}"
SYNC_BRANCH="customer-${NAME}-sync"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git working tree"
git rev-parse -q --verify HEAD >/dev/null 2>&1 \
  || die "HEAD has no commit checked out in this clone (unborn/broken) -- fix the clone (e.g. 'git checkout main') before running $SCRIPT_NAME"
[ -z "$(git status --porcelain)" ] \
  || die "working tree not clean -- commit, stash, or discard changes before running $SCRIPT_NAME"
git remote get-url gerrit >/dev/null 2>&1 \
  || die "no 'gerrit' remote configured in this clone -- see WORKFLOW.md section 5"
git remote get-url "$CUSTOMER_REMOTE" >/dev/null 2>&1 \
  || die "no '$CUSTOMER_REMOTE' remote configured -- run: git remote add $CUSTOMER_REMOTE <gitlab-url>"

# Whatever HEAD actually was (a branch name, or a raw SHA if detached)
# -- restored as-is, never assumed to be any particular default branch
# name, since this runs against arbitrary maintainer clones.
ORIG_REF=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
_cleanup_branch=""
_cleanup() {
  if [ -n "$_cleanup_branch" ] && git show-ref --verify --quiet "refs/heads/$_cleanup_branch"; then
    git checkout -q "$ORIG_REF" 2>/dev/null || true
    git branch -q -D "$_cleanup_branch" >/dev/null 2>&1 || true
  fi
}
trap _cleanup EXIT

start_cycle() {
  log "fetching gerrit and $CUSTOMER_REMOTE..."
  git fetch -q gerrit
  git fetch -q "$CUSTOMER_REMOTE"

  local today prefix cycle n tracking
  today=$(date +%F)
  prefix="customer/${NAME}/${today}-import"
  cycle="$prefix"
  n=1
  while tracking="refs/remotes/gerrit/${cycle}"; git show-ref --verify --quiet "$tracking"; do
    if git diff --quiet "$tracking" "${CUSTOMER_REMOTE}/main"; then
      log "already imported today with no changes since -- reusing $cycle"
      return 0
    fi
    n=$((n + 1))
    cycle="${prefix}-${n}"
  done

  log "creating cycle branch $cycle from ${CUSTOMER_REMOTE}/main..."
  _cleanup_branch="_tmp_customer_sync_$$"
  git checkout -q --orphan "$_cleanup_branch" "${CUSTOMER_REMOTE}/main"
  git commit -q -m "Import from ${NAME} as of ${today}

Baseline for this cycle's work; nothing to diff against yet, since it's
simply what the customer currently has."
  git push -q gerrit "HEAD:refs/heads/${cycle}"
  git checkout -q "$ORIG_REF"
  git branch -q -D "$_cleanup_branch"
  _cleanup_branch=""
  log "pushed $cycle to gerrit -- further work goes through: git push gerrit HEAD:refs/for/${cycle}"
}

deliver_cycle() {
  log "fetching gerrit and $CUSTOMER_REMOTE..."
  git fetch -q gerrit
  git fetch -q "$CUSTOMER_REMOTE"

  local cycle=$CYCLE_ARG
  if [ -z "$cycle" ]; then
    cycle=$(git for-each-ref --format='%(refname:short)' --sort=-refname \
              "refs/remotes/gerrit/customer/${NAME}/*" | head -1)
    [ -n "$cycle" ] || die "no cycle branch found for '$NAME' -- run '$SCRIPT_NAME start-cycle $NAME' first, or pass one explicitly"
    cycle=${cycle#gerrit/}
    log "auto-detected most recent cycle: $cycle"
  fi
  git show-ref --verify --quiet "refs/remotes/gerrit/${cycle}" \
    || die "no such gerrit branch: $cycle"

  git show-ref --verify --quiet "refs/heads/${SYNC_BRANCH}" \
    || git branch -q "$SYNC_BRANCH" "${CUSTOMER_REMOTE}/main"
  git checkout -q "$SYNC_BRANCH"
  git reset -q --hard "${CUSTOMER_REMOTE}/main"

  local new last
  new=$(git rev-parse "gerrit/${cycle}")

  if git diff --quiet "$new" HEAD; then
    log "customer's tree already matches gerrit/${cycle} -- nothing to deliver"
    git checkout -q "$ORIG_REF"
    return 0
  fi

  last=$(git log -1 --format='%(trailers:key=Synced-From,valueonly)' HEAD)
  [ -n "$last" ] || last=$(git rev-list --max-parents=0 "$new")

  git rm -rq --ignore-unmatch .
  git checkout -q "$new" -- .
  git add -A

  local msg
  msg=$(mktemp)
  {
    echo "Sync internal ${cycle} as of $(git rev-parse --short "$new") ($(date +%F))"
    echo
    git log --no-merges --format='* %s' "${last}..${new}"
    echo
    echo "Synced-From: ${new}"
  } > "$msg"
  git commit -q -F "$msg"
  rm -f "$msg"

  git push -q "$CUSTOMER_REMOTE" "${SYNC_BRANCH}:main"
  log "delivered ${cycle} to ${CUSTOMER_REMOTE}/main ($(git rev-parse --short HEAD))"
  git checkout -q "$ORIG_REF"
}

case "$CMD" in
  start-cycle) start_cycle ;;
  deliver)     deliver_cycle ;;
esac

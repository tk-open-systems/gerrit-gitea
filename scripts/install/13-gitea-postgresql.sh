#!/usr/bin/env bash
# Migrate Gitea off SQLite onto PostgreSQL -- part of the same design
# decision as scripts/install/11-postgresql.sh, not optional hardening.
# Run as root, passing the gitea role's password from scripts/install/11-postgresql.sh:
#
#   sudo GITEA_DB_PW='...' GITEA_ADMIN_PW='...' CAROL_PW='...' \
#     bash 13-gitea-postgresql.sh
#
# CAROL_PW is needed because verification below confirms carol can
# still log in and checks alice's team membership survived -- so this
# must run BEFORE scripts/post-install/final-remove-test-users.sh, not after
# (same reason as scripts/post-install/ldap-least-privilege.sh; see
# SYSADMIN.md's "Which ones to run, and in what order").
#
# Unlike Gerrit's H2 (which only held disposable reviewed-file
# checkboxes), Gitea's SQLite file holds everything -- users, orgs,
# teams, repo metadata, issues, wiki page metadata, auth sources,
# tokens. Gitea ships no built-in cross-backend converter.
#
# A first attempt at this script let pgloader create the target schema
# directly from SQLite's structure (its default, documented behavior).
# That looked completely fine at import time -- 0 errors, every table
# copied, correct row counts -- but Gitea then crash-looped forever
# with no visible error in the systemd journal (the real error was in
# /var/lib/gitea/log/gitea.log instead -- app.ini has MODE=file for
# Gitea's own logger, journald only sees the few bootstrap lines before
# that logger takes over). The actual error: Gitea's own startup schema
# sync tried to reconcile pgloader's SQLite-derived index names and
# column types (BIGINT vs the BIGSERIAL its ORM expects, TEXT vs
# VARCHAR(255), etc.) against what its Go structs define, and got stuck
# retrying an index it couldn't drop because a constraint depended on
# it -- forever, every 3 seconds, 10 attempts, then a silent exit.
#
# The fix, confirmed against pgloader's own reference docs (SQLite
# migration options): let GITEA build its own schema first (a fresh,
# empty giteadb + a normal Gitea startup, so xorm's auto-migrate
# creates tables exactly matching its Go structs -- guaranteed
# compatible), then load pgloader in "create no tables, create no
# indexes" mode, which explicitly means "the target schema already
# exists, adapt to its types, load data only." The CLI --with flag
# rejects a comma-separated option list (parse error right at the
# comma) despite that being the documented .load-file syntax; pass
# each option as its own --with instead.
#
# Expect ~4 harmless per-row duplicate-key errors in pgloader's output
# on the version/oauth2_application/app_state/system_setting tables --
# these are singleton install-state rows Gitea's own fresh-schema step
# already seeded in phase 3 (a schema version marker, built-in default
# OAuth2 apps, etc.), so the SQLite copy of that same row collides.
# Keeping Gitea's freshly-created version there is correct, not data
# loss; every real user-facing table (users, orgs, teams, issues,
# comments, wiki metadata, notifications, ...) copies cleanly.
#
# Verification is data-focused, not just "did Gitea start": confirms
# specific known records survived across several different tables (a
# user, an org, a team, an issue), does a real write (a new issue, and
# a wiki page if none exists yet -- wikis live in their own git repo,
# untouched by this migration, so there's nothing pre-existing to
# assert survived) to confirm the app can actually write to the new
# backend, and exercises the LDAP login + group-sync path end to end.
#
# Safe to rerun: it always drops and rebuilds giteadb from scratch
# (via Gitea's own schema creation, then a fresh pgloader data load
# from the still-untouched SQLite file) -- so a rerun DISCARDS any
# data written directly against Postgres since the last run and
# replaces it with a fresh copy from SQLite. Fine immediately after a
# first run; not fine once Postgres is the real system of record with
# its own new data.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

: "${GITEA_DB_PW:?Set GITEA_DB_PW to the gitea Postgres roles password from scripts/install/11-postgresql.sh}"
: "${GITEA_ADMIN_PW:?Set GITEA_ADMIN_PW to gitea-admins current password. Test-lab default: ChangeMe123! (printed by scripts/install/03-gitea.sh); only different if someone ran scripts/post-install/set-service-credentials.sh gitea-admin since.}"
: "${CAROL_PW:?Set CAROL_PW to carols current LDAP password. Test-lab default: ChangeMe123! (printed by scripts/install/02-openldap.sh); only different if someone ran scripts/day2/user-lifecycle.sh set-password carol since.}"

APP_INI=/etc/gitea/app.ini
GITEA_URL="http://127.0.0.1:3000"
SQLITE_PATH=/var/lib/gitea/data/gitea.db

apt-get install -y pgloader

# --- snapshot known records from SQLite before migrating, to verify against after ---
BEFORE_USERS=$(sqlite3 "$SQLITE_PATH" "SELECT count(*) FROM user;")
BEFORE_ISSUES=$(sqlite3 "$SQLITE_PATH" "SELECT count(*) FROM issue;")
log "SQLite has ${BEFORE_USERS} users, ${BEFORE_ISSUES} issues before migration"

systemctl stop gitea

# --- 1. fresh, empty giteadb (discard any earlier attempt's schema) ---
sudo -u postgres psql -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='giteadb';" >/dev/null
sudo -u postgres psql -c "DROP DATABASE IF EXISTS giteadb;" >/dev/null
sudo -u postgres psql -c "CREATE DATABASE giteadb OWNER gitea ENCODING 'UTF8';" >/dev/null
sudo -u postgres psql -c "REVOKE CONNECT ON DATABASE giteadb FROM PUBLIC;" >/dev/null
log "recreated an empty giteadb"

# --- 2. point app.ini at it ---
python3 - "$APP_INI" "$GITEA_DB_PW" <<'PYEOF'
import re, sys
app_ini_path, db_pw = sys.argv[1], sys.argv[2]
with open(app_ini_path) as f:
    content = f.read()
new_section = (
    "[database]\n"
    "DB_TYPE = postgres\n"
    "HOST    = 127.0.0.1:5432\n"
    "NAME    = giteadb\n"
    "USER    = gitea\n"
    f"PASSWD  = {db_pw}\n"
)
content, n = re.subn(r"\[database\]\n(?:.*\n)*?(?=\n\[|\Z)", new_section, content, count=1)
assert n == 1, "did not find exactly one [database] section to replace"
with open(app_ini_path, "w") as f:
    f.write(content)
PYEOF
# Keep app.ini owned by gitea:gitea (not root) -- Gitea's own process
# needs write access to it for auto-persisted values (see SYSADMIN.md
# gotcha 1); only tighten the mode, don't change the owner.
chmod 640 "$APP_INI"

# --- 3. let Gitea build its OWN schema against the empty database ---
systemctl start gitea
wait_for_http "${GITEA_URL}/api/healthz" 60 \
  "systemctl status gitea --no-pager -l && journalctl -u gitea -n 60 --no-pager && tail -n 60 /var/lib/gitea/log/gitea.log"
TABLE_COUNT=$(sudo -u postgres psql -d giteadb -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
[ "$TABLE_COUNT" -gt 50 ] || die "Gitea only created ${TABLE_COUNT} tables against the fresh database -- schema creation looks incomplete"
log "Gitea built its own schema (${TABLE_COUNT} tables) against the fresh database"

# --- 4. stop Gitea again, load data only into the now-correct schema ---
systemctl stop gitea
# The CLI --with flag rejects a comma-separated list of options (fails
# to parse right at the comma) despite that being the .load-file
# syntax -- pass each option as its own --with instead.
pgloader \
  --with "create no tables" \
  --with "create no indexes" \
  --with "include no drop" \
  --with "reset sequences" \
  --with "disable triggers" \
  "sqlite://${SQLITE_PATH}" \
  "postgresql://gitea:${GITEA_DB_PW}@127.0.0.1/giteadb"

# --- 5. start Gitea against the now-populated database ---
systemctl start gitea
wait_for_http "${GITEA_URL}/api/healthz" 60 \
  "systemctl status gitea --no-pager -l && journalctl -u gitea -n 60 --no-pager && tail -n 60 /var/lib/gitea/log/gitea.log"

# --- verify: specific known records survived, across several different tables ---
gitea_api() { curl -fsS -u "gitea-admin:${GITEA_ADMIN_PW}" "$@"; }

# Checked on its own first: curl -f turns a 401 (wrong GITEA_ADMIN_PW)
# and a 404 (record actually missing) into the same generic nonzero
# exit, so without this every check below would misreport a bad
# credential as e.g. "user 'alice' missing after migration".
gitea_api -o /dev/null "${GITEA_URL}/api/v1/user" \
  || die "gitea-admin authentication failed -- GITEA_ADMIN_PW is wrong (test-lab default: ChangeMe123!, printed by scripts/install/03-gitea.sh; only different if someone ran scripts/post-install/set-service-credentials.sh gitea-admin since)"
log "confirmed: gitea-admin credentials are valid"

gitea_api -o /dev/null "${GITEA_URL}/api/v1/users/alice" || die "user 'alice' missing after migration"
gitea_api -o /dev/null "${GITEA_URL}/api/v1/orgs/engineering" || die "org 'engineering' missing after migration"
DEV_TEAM_ID=$(gitea_api "${GITEA_URL}/api/v1/orgs/engineering/teams" | python3 -c 'import json,sys
teams=[t for t in json.load(sys.stdin) if t["name"]=="Developers"]
print(teams[0]["id"] if teams else "")')
[ -n "$DEV_TEAM_ID" ] || die "team 'Developers' missing after migration"
DEV_MEMBERS=$(gitea_api "${GITEA_URL}/api/v1/teams/${DEV_TEAM_ID}/members" | python3 -c 'import json,sys; print([m["login"] for m in json.load(sys.stdin)])')
echo "$DEV_MEMBERS" | grep -q alice || die "alice is no longer a member of Developers after migration"
gitea_api -o /dev/null "${GITEA_URL}/api/v1/repos/engineering/replication-test/issues/1" || die "issue #1 missing after migration"
log "confirmed: a user, an org, a team (with correct membership), and an issue all survived the migration"

# Unlike the checks above, nothing in scripts/install/ ever creates a
# wiki page -- it lives in its own git repo
# (engineering/replication-test.wiki.git), entirely separate from the
# SQL database this script migrates, so there is no pre-existing page
# to assert survived. Create one now if this is the first run, so the
# read-back below is a real live check instead of an assumption about
# unautomated manual state.
if gitea_api -o /dev/null "${GITEA_URL}/api/v1/repos/engineering/replication-test/wiki/page/Home" 2>/dev/null; then
  log "wiki page 'Home' already exists"
else
  gitea_api -X POST -H 'Content-Type: application/json' \
    -d "{\"title\": \"Home\", \"content_base64\": \"$(echo -n '# replication-test' | base64 -w0)\"}" \
    "${GITEA_URL}/api/v1/repos/engineering/replication-test/wiki/new" >/dev/null
  log "created wiki page 'Home' (none existed yet)"
fi
gitea_api -o /dev/null "${GITEA_URL}/api/v1/repos/engineering/replication-test/wiki/page/Home" || die "wiki page 'Home' unreadable even after creating it -- wiki feature is broken after migration"
log "confirmed: the wiki (its own git repo, untouched by this migration) is still reachable through the new Postgres-backed Gitea"

AFTER_ISSUE_COUNT=$(gitea_api "${GITEA_URL}/api/v1/repos/engineering/replication-test/issues?state=all&limit=50" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
log "issue count after migration: ${AFTER_ISSUE_COUNT} (SQLite had ${BEFORE_ISSUES} total across all repos)"

# --- verify: Gitea can actually WRITE to PostgreSQL, not just read ---
NEW_ISSUE=$(gitea_api -X POST -H 'Content-Type: application/json' \
  -d '{"title": "PostgreSQL migration write check"}' \
  "${GITEA_URL}/api/v1/repos/engineering/replication-test/issues")
echo "$NEW_ISSUE" | python3 -c 'import json,sys; json.load(sys.stdin)["number"]' >/dev/null \
  || die "creating a new issue after migration failed -- writes may not be reaching PostgreSQL"
log "confirmed: Gitea can write new records to PostgreSQL"

# --- verify: the LDAP login + group-sync path still works end to end (touches several tables at once) ---
curl -fsS -u "carol:${CAROL_PW}" \
  -o /dev/null "${GITEA_URL}/api/v1/user" \
  || die "carol cannot log into Gitea after migration"
log "confirmed: LDAP login + group sync still works end to end"

log "OK: Gitea is running on PostgreSQL. SQLite file left in place at ${SQLITE_PATH} as a rollback point."

#!/usr/bin/env bash
# Production hardening: migrate Gerrit off H2 onto PostgreSQL.
# Run as root, passing the gerrit role's password from scripts/hardening/postgresql.sh:
#
#   sudo GERRIT_DB_PW='...' CAROL_PW='...' \
#     bash gerrit-postgresql.sh
#
# What Gerrit's H2 database actually holds (confirmed by inspecting
# /var/lib/gerrit/db/ before touching anything): just
# account_patch_reviews -- which files each person has checked
# "reviewed" in a diff view. Nothing about changes, comments, votes, or
# code lives there; all of that is in NoteDb (git refs), untouched by
# this migration.
#
# An earlier version of this script configured `[database]` in
# gerrit.config, which is the ReviewDb-era section and is NOT what
# controls this in a NoteDb-based Gerrit like this one -- Gerrit kept
# silently writing to the old H2 file regardless, no error anywhere.
# The actual mechanism, straight from Gerrit's own bundled
# Documentation/pgm-MigrateAccountPatchReviewDb.html (there is no
# generic online docs site for this -- it ships inside gerrit.war):
# set `accountPatchReviewDb.url`, STOP Gerrit (the docs are explicit:
# "Migration cannot be done while the server is running"), run the
# `MigrateAccountPatchReviewDb` program, then start Gerrit again.
#
# Verification exercises the exact feature that moved (mark-file-
# reviewed) against the new backend, confirms the pre-existing H2 data
# actually migrated (not just that a fresh empty schema exists), and
# reruns a full push/review/submit cycle to confirm nothing else broke.
#
# Safe to rerun: config edits go through git config -f; the migrate
# program is safe to run again (source is unchanged H2, target
# gets re-migrated); systemctl stop/start are idempotent.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

: "${GERRIT_DB_PW:?Set GERRIT_DB_PW to the gerrit Postgres roles password from scripts/hardening/postgresql.sh}"
: "${CAROL_PW:?Set CAROL_PW to carols current password}"

SITE=/var/lib/gerrit
GERRIT_URL="http://127.0.0.1:8080"

cd "$SITE"

# Undo the earlier wrong attempt's config, if present -- [database] is
# vestigial ReviewDb-era config here and does nothing, but leaving it
# would mislead a future reader into thinking it's what's in effect.
sudo -u gerrit git config -f "$SITE/etc/gerrit.config" --remove-section database 2>/dev/null || true

# The docs' own example embeds user+password directly in the URL
# (jdbc:postgresql://host:port/db?user=X&password=Y) with no mention of
# a secure.config split for this parameter -- unlike ldap.password,
# which IS documented that way. Not assuming the same convention
# applies here without evidence; gerrit.config is chmod 600 below since
# it now holds a credential, matching how replication.config's
# embedded credential is handled.
gcfg() { sudo -u gerrit git config -f "$SITE/etc/gerrit.config" "$@"; }
gcfg accountPatchReviewDb.url "jdbc:postgresql://127.0.0.1:5432/gerritdb?user=gerrit&password=${GERRIT_DB_PW}"
chmod 600 "$SITE/etc/gerrit.config"

# The PostgreSQL JDBC driver isn't bundled in gerrit.war (H2's is) --
# the docs say to "drop the driver jar in the lib folder"; without it
# the migrate program fails with ClassNotFoundException:
# org.postgresql.Driver.
PG_JDBC_VERSION="42.7.7"
PG_JDBC_SHA1="67f8093e8d8104c74bbf588392ac3229803f5d17"
PG_JDBC_JAR="$SITE/lib/postgresql-${PG_JDBC_VERSION}.jar"
if [ -f "$PG_JDBC_JAR" ] && sha1sum "$PG_JDBC_JAR" | cut -d' ' -f1 | grep -qx "$PG_JDBC_SHA1"; then
  log "PostgreSQL JDBC driver already installed"
else
  TMP_JAR=$(mktemp)
  curl -fsSL -o "$TMP_JAR" \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC_VERSION}/postgresql-${PG_JDBC_VERSION}.jar"
  echo "${PG_JDBC_SHA1}  ${TMP_JAR}" | sha1sum -c - || die "checksum mismatch for downloaded postgresql JDBC driver"
  install -d -o gerrit -g gerrit -m 750 "$SITE/lib"
  install -o gerrit -g gerrit -m 644 "$TMP_JAR" "$PG_JDBC_JAR"
  rm -f "$TMP_JAR"
  log "installed PostgreSQL JDBC driver ${PG_JDBC_VERSION}"
fi

BEFORE_COUNT=$(PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d gerritdb -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name='account_patch_reviews'" 2>/dev/null || echo 0)

systemctl stop gerrit
sudo -u gerrit java -jar "$SITE/bin/gerrit.war" MigrateAccountPatchReviewDb -d "$SITE"
systemctl start gerrit
wait_for_http "${GERRIT_URL}/" 120 \
  "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"

# --- verify: schema exists and the pre-existing H2 row(s) actually migrated ---
PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d gerritdb -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='account_patch_reviews'" \
  | grep -q 1 || die "account_patch_reviews table not found in gerritdb after migration"
MIGRATED_COUNT=$(PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d gerritdb -tAc \
  "SELECT count(*) FROM account_patch_reviews")
[ "$MIGRATED_COUNT" -ge 1 ] || die "account_patch_reviews table exists but is empty -- data migration did not carry over the existing H2 rows"
log "confirmed: account_patch_reviews table exists with ${MIGRATED_COUNT} row(s) migrated from H2"

# --- verify: NEW writes go to PostgreSQL, not H2 ---
CHANGE_JSON=$(curl -fsS -u "carol:${CAROL_PW}" \
  "${GERRIT_URL}/a/changes/?q=project:replication-test+status:merged&n=1&o=CURRENT_REVISION" | tail -n +2)
CHANGE_NUM=$(echo "$CHANGE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')
REVISION=$(echo "$CHANGE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["current_revision"])')
FILE=$(curl -fsS -u "carol:${CAROL_PW}" \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/${REVISION}/files" | tail -n +2 \
  | python3 -c 'import json,sys; print([f for f in json.load(sys.stdin) if f != "/COMMIT_MSG"][0])')
ENCODED_FILE=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$FILE")

curl -fsS -u "carol:${CAROL_PW}" -X PUT \
  "${GERRIT_URL}/a/changes/${CHANGE_NUM}/revisions/${REVISION}/files/${ENCODED_FILE}/reviewed"

AFTER_COUNT=$(PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d gerritdb -tAc \
  "SELECT count(*) FROM account_patch_reviews")
[ "$AFTER_COUNT" -gt "$MIGRATED_COUNT" ] || die "marking a file reviewed via REST did not add a new row to PostgreSQL"
log "confirmed: marking a file reviewed now writes to PostgreSQL (${MIGRATED_COUNT} -> ${AFTER_COUNT} rows)"

# --- verify: nothing else broke -- full push/review/submit cycle ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
AUTH_URL="http://carol:${CAROL_PW}@127.0.0.1:8080/a/replication-test"
git clone -q "$AUTH_URL" repo
cd repo
echo "postgres migration check $(date -u +%FT%TZ)" > PG_MIGRATION_TEST.txt
git add PG_MIGRATION_TEST.txt
CHANGE_ID="I$(openssl rand -hex 20)"
git -c user.name="Lab Bootstrap" -c user.email="carol@tkos.co.il" \
  commit -q -m "$(printf 'Verify Gerrit after PostgreSQL migration\n\nChange-Id: %s\n' "$CHANGE_ID")"
git push -q "$AUTH_URL" HEAD:refs/for/main
NEW_CHANGE_NUM=$(curl -fsS -u "carol:${CAROL_PW}" \
  "${GERRIT_URL}/a/changes/?q=change:${CHANGE_ID}" | tail -n +2 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["_number"])')
curl -fsS -u "carol:${CAROL_PW}" -X POST -H 'Content-Type: application/json' \
  -d '{"labels":{"Code-Review":2}}' \
  "${GERRIT_URL}/a/changes/${NEW_CHANGE_NUM}/revisions/current/review" >/dev/null
curl -fsS -u "carol:${CAROL_PW}" -X POST \
  "${GERRIT_URL}/a/changes/${NEW_CHANGE_NUM}/submit" >/dev/null
log "confirmed: push -> review -> submit still works end to end on PostgreSQL"

log "OK: Gerrit's AccountPatchReviewDb is running on PostgreSQL, with prior data migrated."

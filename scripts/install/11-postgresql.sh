#!/usr/bin/env bash
# Install PostgreSQL and create isolated databases and least-privilege
# roles for Gerrit and Gitea -- PostgreSQL is this project's chosen
# database backend (not an optional hardening add-on: run this and the
# two migration scripts that follow it for any real deployment, only
# skip them for a quick throwaway lab you don't care about).
# Run as root: sudo bash 11-postgresql.sh
#
# One role per service, each owning only its own database -- neither
# can see or connect to the other's (PUBLIC's default CONNECT grant on
# new databases is explicitly revoked). Auth is password (scram-sha-256)
# over TCP to 127.0.0.1 only, since Gerrit/Gitea's system users don't
# map to Postgres roles for peer auth.
#
# Safe to rerun: package install is idempotent; role/database creation
# is guarded by existence checks; pg_hba.conf gets the TCP-auth line
# appended only if not already present.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

apt-get update
apt-get install -y postgresql

PG_VERSION=$(ls /etc/postgresql/ | sort -n | tail -1)
[ -n "$PG_VERSION" ] || die "could not determine installed PostgreSQL version under /etc/postgresql/"
HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

if grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+scram-sha-256' "$HBA" 2>/dev/null; then
  log "pg_hba.conf already allows password auth on 127.0.0.1"
else
  echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$HBA"
  log "added password-auth line to pg_hba.conf"
fi
systemctl reload postgresql

gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; echo; }
GERRIT_DB_PW=$(gen_pw)
GITEA_DB_PW=$(gen_pw)

create_role_and_db() {
  local role=$1 db=$2 pw=$3
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${role}'" | grep -q 1; then
    sudo -u postgres psql -c "ALTER ROLE ${role} WITH PASSWORD '${pw}';" >/dev/null
    log "role ${role} already existed, rotated its password"
  else
    sudo -u postgres psql -c "CREATE ROLE ${role} WITH LOGIN PASSWORD '${pw}';" >/dev/null
    log "created role ${role}"
  fi
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    log "database ${db} already exists"
  else
    sudo -u postgres psql -c "CREATE DATABASE ${db} OWNER ${role} ENCODING 'UTF8';" >/dev/null
    log "created database ${db}, owned by ${role}"
  fi
  sudo -u postgres psql -c "REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC;" >/dev/null
}

create_role_and_db gerrit gerritdb "$GERRIT_DB_PW"
create_role_and_db gitea giteadb "$GITEA_DB_PW"

# --- verify: each role can connect to its own DB and NOT the other's ---
PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d gerritdb -tAc 'SELECT 1' >/dev/null \
  || die "gerrit role cannot connect to gerritdb"
PGPASSWORD="$GITEA_DB_PW" psql -h 127.0.0.1 -U gitea -d giteadb -tAc 'SELECT 1' >/dev/null \
  || die "gitea role cannot connect to giteadb"
if PGPASSWORD="$GERRIT_DB_PW" psql -h 127.0.0.1 -U gerrit -d giteadb -tAc 'SELECT 1' >/dev/null 2>&1; then
  die "gerrit role can connect to giteadb -- database isolation failed"
fi
log "confirmed: gerrit and gitea roles are isolated to their own databases"

cat <<SUMMARY

=== PostgreSQL ready ===
  gerrit role password : ${GERRIT_DB_PW}
  gitea role password  : ${GITEA_DB_PW}

Nothing persists these -- pass them to scripts/install/12-gerrit-postgresql.sh and scripts/install/13-gitea-postgresql.sh (the
Gerrit and Gitea migration scripts) when you run them.
SUMMARY

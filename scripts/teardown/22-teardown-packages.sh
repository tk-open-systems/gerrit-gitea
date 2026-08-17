#!/usr/bin/env bash
# Tear down the gg (Gerrit/Gitea) installation, phase 2 of 2: purge the
# packages scripts/install/01-prereqs.sh and scripts/install/11-postgresql.sh installed
# solely for this project -- nginx, slapd + ldap-utils, every
# postgresql* package, and openjdk-21-jre-headless -- plus their
# leftover config/data directories.
#
# Run as root, AFTER scripts/teardown/21-teardown-data.sh:
#   sudo bash 22-teardown-packages.sh [--yes] [--force]
#
# Refuses to run if the gerrit/gitea systemd services or system users
# still exist, since that means scripts/teardown/21 hasn't been (fully) run --
# purging java/postgresql/slapd out from under a still-configured
# Gerrit/Gitea would just leave a broken half-removed mess instead of
# a clean host. Pass --force to override (e.g. Gerrit/Gitea were never
# actually installed and you just want these packages gone).
#
# DESTRUCTIVE AND IRREVERSIBLE, and wider-reaching than scripts/teardown/21:
# this changes host-wide package state, not just this project's data.
# If anything else on this host started depending on nginx/postgresql/
# slapd/java after scripts/install/01 / scripts/install/11-postgresql.sh installed them here, this breaks it.
# Requires typing the host's FQDN to confirm, unless --yes is passed.
#
# Safe to rerun: purging an already-purged package is a dpkg/apt
# no-op; directory removal checks existence first.
#
# Apache2 on :80 predates this project and is never touched.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

CONFIRM=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --yes) CONFIRM=1 ;;
    --force) FORCE=1 ;;
    *) die "unknown argument '$a' -- usage: $SCRIPT_NAME [--yes] [--force]" ;;
  esac
done

if [ "$FORCE" -ne 1 ]; then
  for pair in "gerrit:/etc/systemd/system/gerrit.service" "gitea:/etc/systemd/system/gitea.service"; do
    user=${pair%%:*}
    unit=${pair##*:}
    if id "$user" >/dev/null 2>&1 || [ -f "$unit" ]; then
      die "system user '${user}' or ${unit} still exists -- run scripts/teardown/21-teardown-data.sh first (or pass --force to purge packages anyway)."
    fi
  done
fi

if [ "$CONFIRM" -ne 1 ]; then
  cat <<EOF
=== gg teardown, phase 2: packages (this host: ${HOST_FQDN}) ===
About to apt-get purge:
  - nginx (and remove /etc/nginx)
  - slapd, ldap-utils (and remove /etc/ldap, /var/lib/ldap)
  - every installed postgresql* package (and remove /etc/postgresql, /var/lib/postgresql)
  - openjdk-21-jre-headless

This does NOT touch Apache2 on :80. It DOES change host-wide package
state -- anything else on this host that started depending on these
packages after scripts/install/01 / scripts/install/11-postgresql.sh installed them will break.

Type the host's FQDN (${HOST_FQDN}) to confirm, or rerun with --yes:
EOF
  read -r reply
  [ "$reply" = "$HOST_FQDN" ] || die "confirmation did not match '${HOST_FQDN}' -- aborting, nothing was changed."
fi

purge_matching() {
  local pattern=$1
  local pkgs
  pkgs=$(dpkg -l | awk '/^ii/{print $2}' | grep -E "$pattern" || true)
  if [ -n "$pkgs" ]; then
    # Word-splitting $pkgs is the point here (one apt-get purge call, all matched packages).
    # shellcheck disable=SC2086
    apt-get purge -y $pkgs
    log "purged: $pkgs"
  else
    log "no installed packages matching '${pattern}', skipping"
  fi
}

apt-get update
purge_matching '^nginx'
purge_matching '^(slapd|ldap-utils)$'
purge_matching '^postgresql'
purge_matching '^openjdk-21-jre-headless$'

# Belt-and-suspenders: apt purge normally removes these, but a
# manually-created directory (slapd's own database dir, config edited
# by scripts/post-install/ldap-least-privilege.sh / scripts/install/11-postgresql.sh) can survive if a purge prompt was ever answered
# "keep" in the past, and scripts/teardown/21 already deleted the actual LDAP
# entries and DB roles/databases anyway -- there is no live data left
# to lose here.
rm -rf /etc/ldap /var/lib/ldap
rm -rf /etc/postgresql /var/lib/postgresql
rm -rf /etc/nginx

systemctl daemon-reload

log "=== phase 2 done. nginx, slapd/ldap-utils, postgresql*, and openjdk-21-jre-headless are purged. Apache2 on :80 is untouched. Run 'apt-get autoremove --purge' yourself if you also want now-orphaned dependency packages reclaimed (not run automatically here, since it can affect packages unrelated to this project). ==="

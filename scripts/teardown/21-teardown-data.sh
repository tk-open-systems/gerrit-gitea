#!/usr/bin/env bash
# Tear down the gg (Gerrit/Gitea) installation, phase 1 of 2: stop and
# remove every gg-specific systemd service, binary, data/config
# directory, LDAP entry, and PostgreSQL role/database created by
# scripts/install, scripts/hardening, and scripts/day2's
# customer-sync.sh/user-lifecycle.sh/project-lifecycle.sh, plus the
# symlinks scripts/day2/install-ggadmin-tools.sh installed. Leaves the
# underlying packages (openjdk, nginx, slapd, postgresql) installed --
# see scripts/teardown/22-teardown-packages.sh to purge those too, once
# this has run.
#
# Run as root: sudo LDAP_ADMIN_PW='...' bash 21-teardown-data.sh [--yes]
#
# LDAP_ADMIN_PW is cn=admin's current password (scripts/post-install/set-service-credentials.sh's last run,
# or the install default ChangeMe123! if that was never run) -- needed
# to delete the LDAP tree over the wire rather than touching slapd's
# database files directly while it's running.
#
# DESTRUCTIVE AND IRREVERSIBLE: every Gerrit project/review, every
# Gitea repo/issue/wiki page, and the entire LDAP people/groups/services
# tree under ${BASE_DN} are permanently deleted -- this is NOT the
# narrower "remove the lab test users" procedure in ADMIN.md, it
# removes everything, real projects and real users included. Requires
# typing the host's FQDN to confirm, unless --yes is passed (for
# scripted use).
#
# Safe to rerun: every step checks whether its target exists first and
# logs "already gone" instead of erroring, the same idempotent
# convention every other script in this project uses -- rerunning after
# a partial/interrupted teardown just finishes the rest.
#
# Apache2 on :80 predates this project and is never touched, here or
# in scripts/teardown/22.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

CONFIRM=0
[ "${1:-}" = "--yes" ] && CONFIRM=1

if [ "$CONFIRM" -ne 1 ]; then
  cat <<EOF
=== gg teardown, phase 1: services + data (this host: ${HOST_FQDN}) ===
About to PERMANENTLY remove:
  - the gerrit and gitea systemd services, and their installed binaries
  - /var/lib/gerrit, /var/lib/gitea, /etc/gitea -- ALL repos, reviews,
    issues, and wiki pages, not just lab test data
  - the entire LDAP ou=people/ou=groups/ou=services tree under ${BASE_DN}
  - the gerritdb/giteadb PostgreSQL roles and databases, if present
  - this project's nginx site config and self-signed TLS certs
  - the gerrit/gitea system users and their home directories
  - the ggadmin-user/ggadmin-project symlinks in /usr/local/sbin

Packages themselves (nginx, slapd, postgresql, openjdk) are left
installed -- see scripts/teardown/22-teardown-packages.sh for that.

This does NOT touch Apache2 on :80.

Type the host's FQDN (${HOST_FQDN}) to confirm, or rerun with --yes:
EOF
  read -r reply
  [ "$reply" = "$HOST_FQDN" ] || die "confirmation did not match '${HOST_FQDN}' -- aborting, nothing was changed."
fi

# Check LDAP_ADMIN_PW up front, before any destructive step, if there's
# an active slapd to delete from -- failing fast here beats stopping
# services and dropping databases only to die on step 7 for a missing
# env var (later steps are all safe to rerun regardless, but there is
# no reason to leave a run half-finished for a checkable precondition).
if command -v ldapsearch >/dev/null 2>&1 && systemctl is-active --quiet slapd 2>/dev/null \
   && [ -z "${LDAP_ADMIN_PW:-}" ]; then
  die "LDAP_ADMIN_PW is not set (cn=admin's current password -- scripts/post-install/set-service-credentials.sh ldap-admin's last run, or the install default ChangeMe123! if that was never run).
  Rerun with it set: sudo LDAP_ADMIN_PW='...' bash ${SCRIPT_NAME} --yes"
fi

# --- 1. stop/disable/remove the systemd services ---
for svc in gerrit gitea; do
  unit="/etc/systemd/system/${svc}.service"
  if [ -f "$unit" ] || systemctl is-active --quiet "$svc" 2>/dev/null; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "$unit"
    log "stopped, disabled, and removed ${svc}.service"
  else
    log "${svc}.service already gone"
  fi
done
systemctl daemon-reload
systemctl reset-failed gerrit gitea 2>/dev/null || true

# --- 2. ggadmin-tools symlinks (only if they're actually ours) ---
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for pair in "ggadmin-user:user-lifecycle.sh" "ggadmin-project:project-lifecycle.sh"; do
  name=${pair%%:*}
  src="${SCRIPTS_DIR}/../day2/${pair##*:}"
  target="/usr/local/sbin/${name}"
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
    rm -f "$target"
    log "removed ${target}"
  elif [ -e "$target" ] || [ -L "$target" ]; then
    warn "${target} exists but doesn't point at ${src} -- leaving it alone"
  else
    log "${target} already gone"
  fi
done

# --- 3. PostgreSQL roles/databases, if scripts/install/11-13 were ever run ---
if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
  for pair in "gerritdb:gerrit" "giteadb:gitea"; do
    db=${pair%%:*}
    role=${pair##*:}
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
      sudo -u postgres psql -c "DROP DATABASE ${db};" >/dev/null
      log "dropped database ${db}"
    else
      log "database ${db} already gone"
    fi
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${role}'" | grep -q 1; then
      sudo -u postgres psql -c "DROP ROLE ${role};" >/dev/null
      log "dropped role ${role}"
    else
      log "role ${role} already gone"
    fi
  done
else
  log "PostgreSQL not installed/running -- skipping database/role cleanup (expected if scripts/install/11-13 were never run)"
fi

# --- 4. nginx site + TLS certs (leave the package and its other sites alone) ---
rm -f /etc/nginx/sites-enabled/gerrit-gitea-lab.conf /etc/nginx/sites-available/gerrit-gitea-lab.conf
if [ -d /etc/nginx/ssl ]; then
  rm -rf /etc/nginx/ssl
  log "removed self-signed TLS certs (/etc/nginx/ssl)"
fi
log "note: the stock nginx 'default' site stays disabled (scripts/install/08 disabled it to stop it fighting Apache2 on :80 -- re-enabling it here would reintroduce that)"
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
  nginx -t && systemctl reload nginx
  log "nginx reloaded"
else
  log "nginx not installed/running -- skipping reload"
fi

# --- 5. Gerrit: service account processes, install tree, system user ---
pkill -u gerrit 2>/dev/null || true
if id gerrit >/dev/null 2>&1; then
  userdel --remove gerrit 2>/dev/null || warn "userdel gerrit failed (processes still running as gerrit?) -- rerun this script after they exit"
  log "removed system user gerrit"
else
  log "system user gerrit already gone"
fi
rm -rf /var/lib/gerrit

# --- 6. Gitea: service account processes, install tree, binary, system user ---
pkill -u gitea 2>/dev/null || true
if id gitea >/dev/null 2>&1; then
  userdel --remove gitea 2>/dev/null || warn "userdel gitea failed (processes still running as gitea?) -- rerun this script after they exit"
  log "removed system user gitea"
else
  log "system user gitea already gone"
fi
rm -rf /var/lib/gitea /etc/gitea
rm -f /usr/local/bin/gitea

# --- 7. LDAP: delete the whole ou=people/ou=groups/ou=services tree ---
if command -v ldapsearch >/dev/null 2>&1 && systemctl is-active --quiet slapd 2>/dev/null; then
  ADMIN_DN="cn=admin,${BASE_DN}"
  for ou in services groups people; do
    dn="ou=${ou},${BASE_DN}"
    if ldapsearch -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost -b "$dn" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
      ldapdelete -x -D "$ADMIN_DN" -w "$LDAP_ADMIN_PW" -H ldap://localhost -r "$dn"
      log "deleted LDAP subtree ${dn}"
    else
      log "LDAP subtree ${dn} already gone"
    fi
  done
  log "note: cn=admin's rootDN/rootPW and the read-only ACLs from scripts/post-install/ldap-least-privilege.sh are still set on slapd's cn=config -- harmless on an empty directory, but not reverted to slapd's original defaults. scripts/teardown/22-teardown-packages.sh's slapd purge resets that too."
else
  log "slapd not installed/running -- skipping LDAP cleanup (expected if it was already purged)"
fi

log "=== phase 1 done. Gerrit/Gitea/LDAP data is gone; nginx/slapd/postgresql/openjdk packages are still installed. Run scripts/teardown/22-teardown-packages.sh next if you want those purged too. ==="

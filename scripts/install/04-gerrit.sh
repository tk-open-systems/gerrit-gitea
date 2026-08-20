#!/usr/bin/env bash
# Phase 4: install and configure Gerrit (WAR + systemd), with LDAP auth
# pointed at the test directory from phase 2.
# Run as root: sudo bash 04-gerrit.sh
#
# - gerrit.war -> /var/lib/gerrit/bin/gerrit.war, site at /var/lib/gerrit.
# - H2 database, Lucene index (init --batch defaults; fine for a lab).
# - auth.type=LDAP, bound against ou=people/ou=groups,dc=tkos,dc=co,dc=il.
#   Gerrit auto-promotes the FIRST account ever logged in to
#   Administrators, so log in as carol (our LDAP admins-group user)
#   first once this phase is verified.
# - httpd on 127.0.0.1:8080 (proxy-http, nginx fronts it on :8090),
#   sshd on :29418. download.scheme=http+ssh so each repo's page in the
#   Gerrit web UI (Browse > Repos > <project>) shows its clone/push URL.
# - replication plugin is installed (bundled in the war) but not yet
#   configured -- that's phase 6, once the Gitea target repo exists.
#
# Safe to rerun: `gerrit init --batch` is Gerrit's own supported
# upgrade/repair path and does not clobber existing data; the war is
# only re-downloaded if the installed copy's version/checksum differs;
# config edits go through `git config -f`, which replaces keys in
# place instead of appending duplicates. One deliberate exception: the
# LDAP bind identity (gerrit.config's ldap.username + secure.config's
# ldap.password) is only (re)written while still in its original
# bootstrap state -- see the comment at that block -- so this rerun
# safety does NOT extend to blindly restoring a bind identity that
# scripts/post-install/ldap-least-privilege.sh has since repointed
# elsewhere.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

GERRIT_VERSION="3.14.2"
GERRIT_MD5="5f0964143e03121b5f547f29f1af91e1"
EXTERNAL_PORT="8090"   # nginx will listen here and proxy to 127.0.0.1:8080
SITE=/var/lib/gerrit
LDAP_BIND_DN="cn=admin,${BASE_DN}"
LDAP_BIND_PW="ChangeMe123!"   # test-lab only, see scripts/install/02-openldap.sh

install -d -o gerrit -g gerrit -m 750 "$SITE"

# `sudo -u gerrit <cmd>` inherits this script's cwd; if that's under the
# invoking user's home directory (e.g. ~/scripts), the gerrit user may not
# be able to stat it, and tools like git fail loudly trying to. Run from
# the site dir instead, which gerrit always owns.
cd "$SITE"

# --- 1. get gerrit.war (skip download if the right version is already installed) ---
# Installed directly into $SITE/bin, owned by gerrit, so `sudo -u gerrit java
# -jar` can read it -- a root-owned mktemp dir (mode 700) would not be
# readable by the gerrit user.
WAR="$SITE/bin/gerrit.war"
if [ -f "$WAR" ] && sudo -u gerrit md5sum "$WAR" | cut -d' ' -f1 | grep -qx "$GERRIT_MD5"; then
  log "gerrit ${GERRIT_VERSION} already installed at $WAR, skipping download."
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/gerrit.war" \
    "https://gerrit-releases.storage.googleapis.com/gerrit-${GERRIT_VERSION}.war"
  echo "${GERRIT_MD5}  $TMP/gerrit.war" | md5sum -c - \
    || die "checksum mismatch for downloaded gerrit.war"
  install -d -o gerrit -g gerrit -m 750 "$SITE/bin"
  install -o gerrit -g gerrit -m 640 "$TMP/gerrit.war" "$WAR"
fi

# --- 2. init/upgrade the site (Gerrit's own supported rerun path) ---
sudo -u gerrit java -jar "$WAR" init -d "$SITE" \
  --batch --no-auto-start --install-plugin replication

# --- 3. gerrit.config ---
gcfg() { sudo -u gerrit git config -f "$SITE/etc/gerrit.config" "$@"; }

gcfg gerrit.canonicalWebUrl "http://${HOST_FQDN}:${EXTERNAL_PORT}/"
gcfg auth.type LDAP
gcfg ldap.server "ldap://localhost"
gcfg ldap.accountBase "ou=people,${BASE_DN}"
gcfg ldap.accountPattern '(&(objectClass=inetOrgPerson)(uid=${username}))'
gcfg ldap.accountFullName cn
gcfg ldap.accountEmailAddress mail
gcfg ldap.accountSshUserName uid
gcfg ldap.groupBase "ou=groups,${BASE_DN}"
gcfg ldap.groupPattern '(&(objectClass=groupOfNames)(cn=${groupname}))'
gcfg ldap.groupMemberPattern '(member=${dn})'
gcfg httpd.listenUrl "proxy-http://127.0.0.1:8080/"
gcfg sshd.listenAddress "*:29418"

# download.scheme drives the "Clone" command panel on each repo's page in
# the Gerrit web UI (Browse > Repos > <project>) -- without it the panel
# renders empty, leaving no in-UI way to find a project's clone/push URL.
# Multi-valued key, unlike everything else set via gcfg above: unset-all
# then re-add on every run instead of a plain `gcfg` call, so reruns stay
# idempotent (a second `--add` would otherwise duplicate the entry) while
# still replacing a stale/partial value from before this existed.
sudo -u gerrit git config -f "$SITE/etc/gerrit.config" --unset-all download.scheme 2>/dev/null || true
sudo -u gerrit git config -f "$SITE/etc/gerrit.config" --add download.scheme http
sudo -u gerrit git config -f "$SITE/etc/gerrit.config" --add download.scheme ssh

log "wrote gerrit.config (auth.type=LDAP, canonicalWebUrl=http://${HOST_FQDN}:${EXTERNAL_PORT}/, download.scheme=http+ssh)"

# --- 4. LDAP bind identity (gerrit.config's ldap.username + secure.config's
# ldap.password) -- guarded, unlike every other gcfg call above. This pair
# is a deliberate exception to "config edits go through git config -f,
# which replaces keys in place" (see top of file): scripts/post-install/
# ldap-least-privilege.sh repoints both of these, together, from this
# script's cn=admin bootstrap bind to a dedicated cn=ldap-reader account
# with its own generated password -- and unconditionally rewriting them
# here on every rerun previously stomped that repointing straight back to
# the (by then stale) bootstrap credentials, breaking Gerrit LDAP auth
# entirely while leaving Gitea (whose config this script never touches)
# unaffected. Confirmed live, not hypothetical. Only (re)write the
# bootstrap identity if it's still in its original bootstrap state --
# i.e. this is the first-ever run, or ldap-least-privilege.sh was never
# applied on this host -- so a later repointing is left alone here.
CURRENT_LDAP_USERNAME=$(sudo -u gerrit git config -f "$SITE/etc/gerrit.config" --get ldap.username 2>/dev/null || true)
if [ -z "$CURRENT_LDAP_USERNAME" ] || [ "$CURRENT_LDAP_USERNAME" = "$LDAP_BIND_DN" ]; then
  gcfg ldap.username "$LDAP_BIND_DN"
  sudo -u gerrit git config -f "$SITE/etc/secure.config" ldap.password "$LDAP_BIND_PW"
  log "wrote LDAP bind identity (${LDAP_BIND_DN}) into gerrit.config/secure.config"
else
  log "ldap.username is already '${CURRENT_LDAP_USERNAME}' (not the bootstrap ${LDAP_BIND_DN}) -- leaving it and secure.config's ldap.password untouched. Expected if scripts/post-install/ldap-least-privilege.sh has already repointed this host to a dedicated bind account; rerun that script instead if you need to rotate its password. To deliberately reset back to the bootstrap cn=admin bind, edit gerrit.config's ldap.username by hand first, then rerun this script."
fi
chmod 600 "$SITE/etc/secure.config"

# --- 5. systemd unit ---
cat > /etc/systemd/system/gerrit.service <<EOF
[Unit]
Description=Gerrit Code Review
After=network.target slapd.service

[Service]
Type=simple
User=gerrit
Group=gerrit
ExecStart=/usr/bin/java -jar ${SITE}/bin/gerrit.war daemon -d ${SITE} --console-log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if systemctl is-active --quiet gerrit; then
  log "gerrit service already active, leaving it running (config changes need a manual restart: systemctl restart gerrit)."
else
  systemctl reset-failed gerrit 2>/dev/null || true
  systemctl enable --now gerrit
fi

# --- 6. wait for it to come up (Gerrit's first boot is slow: index build + JVM warm-up) ---
wait_for_http http://127.0.0.1:8080/ 120 \
  "systemctl status gerrit --no-pager -l && journalctl -u gerrit -n 100 --no-pager"

log "Gerrit is up. Next: log in as carol (LDAP admins group) first -- Gerrit auto-promotes the first-ever account to Administrators."

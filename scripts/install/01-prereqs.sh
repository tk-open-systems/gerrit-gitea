#!/usr/bin/env bash
# Phase 1: packages + system users/dirs for the Gerrit/Gitea test install.
# Run as root: sudo bash 01-prereqs.sh
# Safe to rerun: apt-get install and useradd/install -d are all idempotent.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

apt-get update
apt-get install -y \
  openjdk-21-jre-headless \
  nginx \
  slapd ldap-utils \
  git curl unzip sqlite3

# --- system users (no login shell, dedicated home under /var/lib) ---
if ! id gerrit >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/gerrit \
    --shell /usr/sbin/nologin gerrit
fi

if ! id gitea >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/gitea \
    --shell /usr/sbin/nologin gitea
fi

# --- directories ---
install -d -o gerrit -g gerrit -m 750 /var/lib/gerrit
install -d -o gitea  -g gitea  -m 750 /var/lib/gitea
install -d -o gitea  -g gitea  -m 750 /etc/gitea

log "packages installed, users 'gerrit' and 'gitea' present."
id gerrit
id gitea

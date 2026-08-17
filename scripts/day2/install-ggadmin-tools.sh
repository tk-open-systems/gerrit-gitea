#!/usr/bin/env bash
# Installs the "Day-2" admin tools (scripts/day2/user-lifecycle.sh,
# scripts/day2/project-lifecycle.sh) onto this host's PATH under
# short names, as symlinks into /usr/local/sbin:
#   /usr/local/sbin/ggadmin-user    -> scripts/day2/user-lifecycle.sh
#   /usr/local/sbin/ggadmin-project -> scripts/day2/project-lifecycle.sh
#
# /usr/local/sbin is the FHS/Debian-policy location for locally
# installed root-only admin binaries that aren't managed by dpkg (FHS:
# "/usr/local/sbin: Local system administration binaries"; Debian
# Policy Manual 9.1.1: /usr/local is reserved for the sysadmin and
# never touched by the package system). Symlinks rather than copies so
# the installed commands always run the actual scripts/ files -- a
# `git pull` here updates them in place, nothing to reinstall.
#
# No PATH edit needed on a stock Debian host: /etc/profile already
# puts /usr/local/sbin on PATH for root login shells, and sudo's
# default secure_path includes it too, so `sudo ggadmin-user ...`
# already works for any admin. This script verifies that instead of
# assuming it (see step 2 below) and warns rather than silently
# rewriting shell config if it's somehow not the case -- forcing an
# sbin directory onto a non-root PATH would work against the very
# root-only convention /usr/local/sbin exists to signal.
#
# Run as root: sudo bash install-ggadmin-tools.sh
#
# Safe to rerun: an existing correct symlink is left alone; a
# pre-existing file/symlink at the target path pointing somewhere else
# is left alone too, with a warning, rather than clobbered.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR=/usr/local/sbin

# name -> source script, kept as two parallel arrays for bash 4/5
# portability (no need for associative-array ordering guarantees).
NAMES=(ggadmin-user ggadmin-project)
SRCS=(user-lifecycle.sh project-lifecycle.sh)

[ -d "$BIN_DIR" ] || die "$BIN_DIR does not exist -- unexpected on a standard Debian host, check the base install"

for i in "${!NAMES[@]}"; do
  name=${NAMES[$i]}
  src="${SCRIPTS_DIR}/${SRCS[$i]}"
  target="${BIN_DIR}/${name}"

  [ -x "$src" ] || die "expected $src to exist and be executable"

  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
    log "${target} already correctly symlinked to ${src}, skipping"
  elif [ -e "$target" ] || [ -L "$target" ]; then
    warn "${target} already exists and isn't our symlink -- leaving it alone. Remove it manually first if you want ${name} reinstalled."
  else
    ln -s "$src" "$target"
    log "installed ${target} -> ${src}"
  fi
done

# --- verify PATH coverage instead of assuming/forcing it ---
if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  log "PATH check: ${BIN_DIR} is on the current PATH (as expected for root)"
else
  warn "${BIN_DIR} is not on the current PATH in this shell -- expected for root on a stock Debian host via /etc/profile. If this persists in a normal root login shell, something about this host's shell config is nonstandard; otherwise this is just this specific non-login shell and 'sudo ${NAMES[0]} ...' will still work via sudo's secure_path."
fi

log "done. Try: sudo ${NAMES[0]} 2>&1 | head -1"

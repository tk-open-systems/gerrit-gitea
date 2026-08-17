#!/usr/bin/env bash
# Installs the "Day-2" admin tools (scripts/day2/user-lifecycle.sh,
# scripts/day2/project-lifecycle.sh) onto this host's PATH under short
# names, as a standalone copy this repo clone's continued existence is
# never required for:
#   1. Copies user-lifecycle.sh, project-lifecycle.sh, lib.sh, and
#      config.sh into /usr/local/lib/gerrit-gitea/ (preserving the
#      same day2/ subdirectory layout they have in this repo, so their
#      own "source ../lib.sh" line resolves identically either way,
#      unchanged).
#   2. Symlinks the two entry points from there onto PATH:
#        /usr/local/sbin/ggadmin-user    -> .../day2/user-lifecycle.sh
#        /usr/local/sbin/ggadmin-project -> .../day2/project-lifecycle.sh
#
# Deliberately copies rather than symlinking straight into this repo
# clone (an earlier version of this script did that): if the clone is
# later moved, renamed, or deleted, `ggadmin-user`/`ggadmin-project`
# would silently break -- a real risk for a directory some other admin
# or process might reasonably clean up, not knowing /usr/local/sbin
# depended on it. The flip side of copying is the one to know: editing
# a script in this repo clone, or `git pull`ing a newer version, does
# NOT change what's installed until you rerun this script -- unlike a
# symlink, a copy needs an explicit reinstall to pick up changes.
#
# /usr/local/sbin is the FHS/Debian-policy location for locally
# installed root-only admin binaries that aren't managed by dpkg (FHS:
# "/usr/local/sbin: Local system administration binaries"; Debian
# Policy Manual 9.1.1: /usr/local is reserved for the sysadmin and
# never touched by the package system); /usr/local/lib is the same
# policy's location for such a program's private support files.
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
# Safe to rerun -- in fact, rerun this any time you edit
# user-lifecycle.sh/project-lifecycle.sh/lib.sh/config.sh in this repo
# clone (or `git pull` a change to any of them) and want that change
# to take effect on this host; the copy step above always overwrites.
# The symlink step is more cautious: an existing correct symlink is
# left alone, and a pre-existing file/symlink at the target path
# pointing somewhere else (including an old-style symlink straight
# into a repo clone, from before this script copied instead) is left
# alone too, with a warning, rather than clobbered -- remove it
# manually first (`rm /usr/local/sbin/ggadmin-user`) if you want it
# replaced.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
require_root

DAY2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$DAY2_DIR/.." && pwd)"
LIB_DIR=/usr/local/lib/gerrit-gitea
BIN_DIR=/usr/local/sbin

# name -> source script under $DAY2_DIR, kept as two parallel arrays
# for bash 4/5 portability (no need for associative-array ordering
# guarantees).
NAMES=(ggadmin-user ggadmin-project)
SRCS=(user-lifecycle.sh project-lifecycle.sh)

[ -d "$BIN_DIR" ] || die "$BIN_DIR does not exist -- unexpected on a standard Debian host, check the base install"

# --- 1. copy this repo clone's files into a standalone location ---
install -d -m 755 "$LIB_DIR" "$LIB_DIR/day2"
install -m 644 "$SCRIPTS_DIR/lib.sh" "$LIB_DIR/lib.sh"
install -m 644 "$SCRIPTS_DIR/config.sh" "$LIB_DIR/config.sh"
for i in "${!NAMES[@]}"; do
  src="${DAY2_DIR}/${SRCS[$i]}"
  [ -x "$src" ] || die "expected $src to exist and be executable"
  install -m 755 "$src" "$LIB_DIR/day2/${SRCS[$i]}"
done
log "copied lib.sh, config.sh, ${SRCS[*]} into ${LIB_DIR} -- this host's installed copy, independent of this repo clone from here on"

# --- 2. symlink the two entry points from there onto PATH ---
for i in "${!NAMES[@]}"; do
  name=${NAMES[$i]}
  src="${LIB_DIR}/day2/${SRCS[$i]}"
  target="${BIN_DIR}/${name}"

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

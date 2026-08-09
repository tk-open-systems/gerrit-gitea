# Shared helpers for scripts/NN-*.sh.
# Source this, don't execute it: `source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"`
# Caller script must already have `set -euo pipefail`.

SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

_on_err() {
  printf '[%s] ERROR: command failed (exit %s) at line %s: %s\n' \
    "$SCRIPT_NAME" "$?" "$1" "$2" >&2
}
trap '_on_err "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must be run as root (sudo bash $0)"
}

# wait_for_http URL [timeout_seconds] [diagnostic_hint]
# Polls URL until it returns success or timeout elapses; never loops forever,
# and fails with an actionable message instead of a bare curl error.
wait_for_http() {
  local url=$1 timeout=${2:-30} hint=${3:-} i=0
  while ! curl -fsS -o /dev/null "$url" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$timeout" ]; then
      printf '[%s] ERROR: timed out after %ss waiting for %s\n' "$SCRIPT_NAME" "$timeout" "$url" >&2
      [ -n "$hint" ] && printf '[%s]   diagnose with: %s\n' "$SCRIPT_NAME" "$hint" >&2
      return 1
    fi
    sleep 1
  done
  log "up: $url (after ${i}s)"
}

# ldap_add_if_missing DN LDIF ADMIN_DN PASSWORD
# Idempotent ldapadd: skips (with a log line) if the DN already exists.
ldap_add_if_missing() {
  local dn=$1 ldif=$2 admin_dn=$3 password=$4
  if ldapsearch -x -D "$admin_dn" -w "$password" -H ldapi:/// \
       -b "$dn" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
    log "LDAP entry already exists, skipping: $dn"
  else
    printf '%s\n' "$ldif" | ldapadd -x -D "$admin_dn" -w "$password" -H ldapi:///
    log "created LDAP entry: $dn"
  fi
}

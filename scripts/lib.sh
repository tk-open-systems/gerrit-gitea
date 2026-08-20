# Shared helpers for scripts/NN-*.sh.
# Source this, don't execute it: `source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"`
# Caller script must already have `set -euo pipefail`.

SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"

# Pulls in HOST_FQDN/BASE_DN so no individual script has to declare them --
# see config.sh to point this project at a different host.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# Catches the "forgot to edit config.sh for this host" mistake: HOST_FQDN
# is only ever a value WE chose, so nothing enforces it matches reality.
# BASE_DN mismatches are already caught hard (scripts/02-openldap.sh dies
# if it doesn't match slapd's actual suffix), but a wrong host *label*
# with the same domain sails through that check silently and only shows
# up later as wrong URLs baked into gerrit.config/app.ini/nginx. Just a
# warning, not a die: some hosts legitimately run behind a NAT/LB under a
# public name that differs from their local hostname.
_actual_fqdn="$(hostname -f 2>/dev/null || hostname)"
if [ "$_actual_fqdn" != "$HOST_FQDN" ]; then
  warn "this host's real FQDN ('hostname -f') is '${_actual_fqdn}' but scripts/config.sh has HOST_FQDN='${HOST_FQDN}' -- if that's not deliberate, fix config.sh before continuing (see INSTALL.md's \"Running it\")."
fi
unset _actual_fqdn

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

# verify_http_cred LABEL UNAUTH_URL AUTH_URL USER PASSWORD
# Confirms USER:PASSWORD authenticates via HTTP Basic auth against
# AUTH_URL (an endpoint that requires auth and returns 2xx once
# authenticated -- e.g. Gerrit's .../a/accounts/self, Gitea's
# .../api/v1/user). UNAUTH_URL is any endpoint on the same service that
# succeeds without auth, checked first so a dead/unreachable service is
# reported as that, not misdiagnosed as a bad password. Prints one
# clear log/WARNING line naming LABEL either way, so a caller checking
# several credentials in a row leaves a readable trail of exactly which
# one(s) failed. Returns 0 if the credential checks out, 1 otherwise --
# callers decide whether that's fatal (see scripts/day2/verify-creds.sh
# for a standalone example, or the preflight in project-lifecycle.sh /
# user-lifecycle.sh for the wired-in one).
verify_http_cred() {
  local label=$1 unauth_url=$2 auth_url=$3 user=$4 pass=$5
  local code

  if ! curl -fsS -o /dev/null --max-time 5 "$unauth_url" 2>/dev/null; then
    warn "${label}: can't reach ${unauth_url} at all -- that's a service-down/network problem, not a password problem. Fix that first, then retry."
    return 1
  fi

  code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -u "${user}:${pass}" "$auth_url" 2>/dev/null) || code=000
  case "$code" in
    2??)
      log "${label}: OK -- '${user}' authenticated successfully"
      return 0 ;;
    401)
      warn "${label}: WRONG -- '${user}' was rejected (HTTP 401) by ${auth_url}"
      return 1 ;;
    503)
      warn "${label}: WRONG (most likely) -- '${user}' got HTTP 503 from ${auth_url}. On this stack, an LDAP-backed realm surfaces a rejected bind as 503, not 401 -- confirm with: journalctl -u gerrit -n 50 --no-pager | grep -A2 'Caused by'"
      return 1 ;;
    000)
      warn "${label}: request to ${auth_url} failed outright (timeout/connection reset) -- a transient network issue, not confirmed as a password problem. Retry."
      return 1 ;;
    *)
      warn "${label}: unexpected HTTP ${code} from ${auth_url} for '${user}' -- not a clean pass/fail, investigate directly"
      return 1 ;;
  esac
}

# verify_ldap_cred LABEL BIND_DN PASSWORD
# Confirms BIND_DN can bind to LDAP with PASSWORD right now, distinguishing
# "slapd unreachable" from "wrong password" from success. Prints one
# clear log/WARNING line naming LABEL either way. Returns 0/1 like
# verify_http_cred above.
verify_ldap_cred() {
  local label=$1 bind_dn=$2 pass=$3
  local out

  if ! ldapsearch -x -H ldap://localhost -b "" -s base >/dev/null 2>&1; then
    warn "${label}: can't reach LDAP at ldap://localhost at all -- that's a service-down/network problem (check: systemctl status slapd), not a password problem."
    return 1
  fi

  if out=$(ldapwhoami -x -H ldap://localhost -D "$bind_dn" -w "$pass" 2>&1); then
    log "${label}: OK -- '${bind_dn}' authenticated successfully"
    return 0
  fi
  warn "${label}: WRONG -- '${bind_dn}' was rejected by LDAP (${out})"
  return 1
}

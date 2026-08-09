# Shared host-specific configuration for scripts/NN-*.sh.
# Source this, don't execute it -- lib.sh sources it automatically, so
# every script that already does `source .../lib.sh` gets these without
# any change of its own.
#
# To point this whole project at a different host, edit HOST_FQDN below
# (and BASE_DN too, if it doesn't end up matching -- see note).
#
# BASE_DN default derives from HOST_FQDN's domain part the same way
# Debian's slapd package itself derives it from the system's DNS domain
# during a noninteractive install (scripts/02-openldap.sh): everything
# after the first label, dot-separated components each become "dc=X".
# That's correct for a fresh target host with no prior LDAP config. If
# your target host's slapd ends up with a different suffix (e.g. it
# already had LDAP configured, or its domain isn't what you expect),
# override BASE_DN explicitly here instead of relying on the derivation
# -- check the real value after scripts/01-prereqs.sh installs slapd via:
#   ldapsearch -x -H ldap:/// -b "" -s base namingContexts
#
# Both support a plain shell-variable override too, e.g.:
#   HOST_FQDN=gerrit.example.com sudo -E bash 01-prereqs.sh

HOST_FQDN="${HOST_FQDN:-claude.tkos.co.il}"

_config_domain="${HOST_FQDN#*.}"
BASE_DN="${BASE_DN:-dc=$(echo "$_config_domain" | sed 's/\./,dc=/g')}"
unset _config_domain

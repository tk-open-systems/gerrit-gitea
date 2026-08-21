# Gerrit + Gitea

A native (no containers), LDAP-backed Gerrit + Gitea stack on a single
Debian host: **Gerrit** is the code-review system and source of truth for
every repo; **Gitea** hosts project planning, wiki, kanban, and issue
tracking, plus a read-only mirror of each repo, kept in sync by Gerrit's
own replication plugin on every merge. One shared LDAP directory backs
authentication for both.

Every script here has been run, broken, fixed, and re-verified live against
a real install — not written from the plugin docs and left untested. The
`scripts/` directory is the actual source of truth; the docs below are the
narrative walkthrough, the day-2 procedures, and the gotchas that weren't
obvious from the plugin docs alone.

## Documentation

| Doc | For | Covers |
|---|---|---|
| **[INSTALL.md](INSTALL.md)** | Whoever stands this up | Installing from scratch (`scripts/install/`), architecture, design decisions, gotchas found by actually running this, post-install hardening, and teardown. |
| **[ADMIN.md](ADMIN.md)** | Whoever administers it day to day | Adding/changing/removing users and projects, the `ggadmin-*` command-line tools (`scripts/day2/`), and the credentials each one needs. |
| **[WORKFLOW.md](WORKFLOW.md)** | Whoever develops against it | How Gerrit and Gitea fit together day to day: identity/ACLs, repo mirroring, linking changes to issues, the end-to-end push→review→submit→replicate flow, and customer branch delivery. |
| **[HOWTO.md](HOWTO.md)** | Anyone who just wants the command | FAQ-style one-liners for common tasks, each linking back to the fuller explanation in the doc above it belongs to. |
| **[TODO.md](TODO.md)** | Anyone picking up open work | What's left, and why each item is deferred rather than done. |

If you're setting this up for the first time, start with INSTALL.md. If
it's already running and you need to do something with it, ADMIN.md and
WORKFLOW.md are the day-2 references — start there before re-reading
INSTALL.md.

## Quick start

```
# 1. Point it at your host (do this before running anything else --
#    see INSTALL.md's "Edit config.sh" for why order matters here)
$EDITOR scripts/config.sh   # set HOST_FQDN

# 2. Run the install phases in order, as root
cd scripts/install
sudo bash 01-prereqs.sh
sudo bash 02-openldap.sh
# ... through 09-smoke-test.sh -- see INSTALL.md's Status checklist
#     for the full list and what each phase does.
```

See INSTALL.md for the complete walkthrough, including the phases beyond
09 (delete-project plugin, PostgreSQL migration, the dedicated
`gerrit-bot` service account) and what to do if something doesn't come up
clean.

## Repo layout

```
scripts/
  config.sh        single place to set HOST_FQDN / BASE_DN
  lib.sh            shared helpers (logging, root/cred checks, ...)
  install/          numbered phases 01-14, run once to stand this up
  post-install/     required hardening (LDAP least-privilege, credential
                    rotation, removing lab test users) -- not optional
  hardening/        additional hardening (TLS termination)
  day2/             ggadmin-user / ggadmin-project / ggadmin-group / 
                    ggadmin-verify-creds -- ongoing operations
  teardown/         tearing the whole thing back down
```

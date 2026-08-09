# Gerrit + Gitea: Sysadmin Install Guide

This is the installation/configuration half of the project; [WORKFLOW.md](WORKFLOW.md)
is the "how to use it once it's running" half. Everything here has been run,
broken, fixed, and re-verified live on a real Debian 13.6 host
(`claude.tkos.co.il`) rather than written from documentation alone — the
`scripts/` directory is the actual source of truth, this file is the
narrative walkthrough plus the gotchas that weren't obvious from the plugin
docs.

## Status

All nine phases below are scripted, idempotent (safe to rerun), and verified
working end to end on the test host, including a real push → review →
submit → replicate → issue-auto-close cycle.

- [x] `scripts/01-prereqs.sh` — packages, `gerrit`/`gitea` system users
- [x] `scripts/02-openldap.sh` — test OpenLDAP directory
- [x] `scripts/03-gitea.sh` — Gitea install
- [x] `scripts/04-gerrit.sh` — Gerrit install, LDAP auth
- [x] `scripts/05-gerrit-acl.sh` — Gerrit authorization bound to an LDAP group
- [x] `scripts/06-gitea-ldap.sh` — Gitea LDAP source + group-to-team sync
- [x] `scripts/07-replication.sh` — Gerrit → Gitea replication
- [x] `scripts/08-nginx.sh` — reverse proxy
- [x] `scripts/09-smoke-test.sh` — full end-to-end verification
- [x] `scripts/10-delete-project-plugin.sh` — enables Gerrit's
      `delete-project` plugin (bundled in the WAR, not installed by phase
      4), used by the project-deletion procedure in [ADMIN.md](ADMIN.md)
- [x] `scripts/11-rotate-credentials.sh` — rotates every lab-default
      credential; see Production Hardening below for what's done vs. not
- [x] `scripts/12-ldap-least-privilege.sh` — locks down the directory's
      previously-nonexistent ACLs and adds a dedicated read-only bind
      account for Gerrit/Gitea
- [ ] Production hardening beyond credential rotation and the LDAP bind
      account (see below) — not done, this is a lab install
- [ ] Gerrit → Gitea webhook for in-review issue visibility — deferred, see
      WORKFLOW.md's "Open items"

## Architecture on this host

| Component | Version | Listens on | Config | Systemd unit |
|---|---|---|---|---|
| OpenLDAP | slapd 2.6.10 | `:389`, `ldapi:///` | `cn=config` (olc) | `slapd` |
| Gitea | 1.27.1 | `127.0.0.1:3000` (HTTP), `:2222` (SSH) | `/etc/gitea/app.ini` | `gitea` |
| Gerrit | 3.14.2 | `127.0.0.1:8080` (HTTP), `:29418` (SSH) | `/var/lib/gerrit/etc/*.config` | `gerrit` |
| nginx | 1.26.3 | `:8090`→Gerrit, `:8091`→Gitea | `/etc/nginx/sites-available/gerrit-gitea-lab.conf` | `nginx` |

System users: `gerrit` (site at `/var/lib/gerrit`), `gitea` (site at
`/var/lib/gitea`), both `--system --shell /usr/sbin/nologin`.

This host already runs an unrelated Apache2 on port `:80` — every script
here was written to leave it completely alone. If your target host is
otherwise empty, you'd normally just put Gerrit/Gitea on `:80`/`:443` with
TLS instead of the `:8090`/`:8091` alt-port arrangement here.

## Design decisions baked into the scripts

- **Native install (WAR/binary + systemd), not containers.** Simplest to
  reason about on a single Debian host; no container runtime dependency.
- **H2 (Gerrit) / SQLite (Gitea).** Fine for a lab; see "Production
  hardening" below.
- **A real, live-tested OpenLDAP directory**, not a stubbed-out identity
  layer, so the LDAP-bind auth and group-sync config in phases 4-6 are
  proven against actual LDAP traffic, not just written from memory. Base DN
  `dc=tkos,dc=co,dc=il` was auto-picked by `slapd` from this host's domain
  during install; `ou=people`/`ou=groups`, two groups (`developers`,
  `admins`), three test users (alice/bob → developers, carol → admins).
- **Every account in this lab uses the password `ChangeMe123!`.** This is
  intentional and documented everywhere it appears, purely to keep the
  scripts reproducible. Never reuse this scheme outside a throwaway lab.

## Running it

Each script is self-contained, logs what it's doing, and is safe to rerun
(see `scripts/lib.sh` for the shared idempotency/error-handling helpers).
Run them **as root, in order**:

```
sudo bash scripts/01-prereqs.sh
sudo bash scripts/02-openldap.sh
sudo bash scripts/03-gitea.sh
sudo bash scripts/04-gerrit.sh
sudo bash scripts/05-gerrit-acl.sh
sudo bash scripts/06-gitea-ldap.sh
sudo bash scripts/07-replication.sh
sudo bash scripts/08-nginx.sh
sudo bash scripts/09-smoke-test.sh
```

Each has a comment block at the top explaining what it does and why; read
those rather than this doc if you need the exact commands.

## Gotchas found by actually running this (not just reading docs)

These cost real debugging time; they're recorded here so the next person
(including future-us) doesn't repeat them.

1. **Gitea's `SECRET_KEY`/`INTERNAL_TOKEN`/`JWT_SECRET` encrypt data already
   stored once Gitea has run.** Regenerating them on every install rerun
   would silently corrupt sessions, 2FA, mirror credentials, etc. `app.ini`
   is written once and never touched again by the script.
2. **`sudo -u <user> <cmd>` inherits the caller's cwd.** If that's under an
   unrelated user's home directory, the target user may not be able to
   `stat` it, and tools like `git` fail with a confusing
   `fatal: failed to stat ... Permission denied` that has nothing to do
   with the actual command. Scripts that shell out as `gerrit`/`gitea` `cd`
   into that user's own site directory first.
3. **Gerrit's `project.config` ACL group references must also be
   registered in the sibling `groups` file** (a UUID↔name map, also part of
   the `refs/meta/config` tree) — pushing an ACL change that references a
   new group name without a matching `groups` entry is rejected with
   `group "X" not in groups`, even though the group name itself
   ("ldap/cn=...") is otherwise valid syntax.
4. **`remote.<name>.timeout` in `replication.config` is a plain integer
   (seconds), parsed by JGit** — unlike Gerrit's own duration-style config
   fields, a unit suffix like `"30s"` throws `NumberFormatException` and
   crashes the whole replication plugin at Gerrit startup.
5. **Gerrit can come up fine (HTTP 200) even when a plugin failed to
   load** — it just logs a warning. Don't assume "Gerrit is reachable"
   means "the config change to a plugin took effect"; check
   `GET /a/plugins/?all` explicitly.
6. **HTTP auth for the replication plugin: embed `user:pass@` directly in
   the remote URL, `chmod 600` the file.** The documented alternative
   (username in the URL, password alone in `secure.config`'s
   `remote.<name>.password`) produced `authentication not supported` from
   JGit in this setup; the embedded-credential form is what actually
   works, and matches the pattern already proven elsewhere in this lab for
   Gerrit's own git operations.
7. **Gitea's push-to-create needs the pushing account's team to have
   `can_create_org_repo: true` specifically.** `includes_all_repositories`
   (on the team) and `ENABLE_PUSH_CREATE_ORG` (in `app.ini`) are both
   necessary but not sufficient — without `can_create_org_repo`, every push
   to a not-yet-existing repo 404s, and the error Gerrit's replication
   plugin logs for this (`authentication not supported`) is misleading;
   `git push` directly against the same URL reports the real `HTTP 404`.
8. **Push-created Gitea repos default to `private`.** Any verification
   script polling for "has it replicated yet" needs to authenticate — an
   anonymous check 404s identically whether the repo is missing or just
   not visible, which looks like "hasn't replicated" and can time out even
   after a successful replication.
9. **The stock Debian `nginx` package ships a `default` site that also
   binds `:80`/`:443`.** If another web server already owns port 80 (as
   Apache2 does here), `nginx.service` fails to start at all — silently,
   possibly since the very first `apt install` — until that default site
   is disabled, regardless of what your own site config listens on.
10. **Gerrit auto-promotes the very first account it ever sees to the
    internal `Administrators` group.** Useful for bootstrapping (log in as
    an LDAP `admins`-group user first), but it's a one-time trick tied to
    one account, not a durable mapping — bind `ldap/<group-dn>` directly
    into `All-Projects`' ACL (as `scripts/05-gerrit-acl.sh` does) so
    *membership in the LDAP group* is the actual source of truth for who
    gets Gerrit admin rights.
11. **Gitea's team-edit API silently discards a partial `PATCH`.** Sending
    `{"includes_all_repositories": true}` alone returns `HTTP 200` with the
    field still `false` in the response — no error, nothing to notice
    unless you actually read the response back. This bit us for real: an
    earlier version of `scripts/07-replication.sh` sent exactly that
    partial PATCH, every subsequent script run kept logging success, and
    the `Developers` team's grant silently never took effect — LDAP
    developers got `404` on the mirrored repo, its issues, *and* its wiki
    the entire time, only caught while testing wiki access for
    WORKFLOW.md section 4. Always resend the full team object (`units_map`
    included) on any team edit, and verify by reading the field back
    afterward rather than trusting the HTTP status code — which is exactly
    what the fixed script now does.
12. **This directory had no explicit ACLs at all until
    `scripts/12-ldap-least-privilege.sh`**, running on OpenLDAP's
    compiled-in default: `userPassword` was protected, but every other
    attribute — names, emails, group membership — was readable by a fully
    anonymous, unauthenticated bind. Confirmed live before fixing it:
    `ldapsearch -x` with no credentials could list who's in the `admins`
    group. And once it *was* locked down: **Gitea's LDAP client reuses one
    connection across the whole login flow.** It binds as the reader
    account, searches for the user, then rebinds that same connection as
    the logging-in user to verify their password — and the subsequent
    group-membership search then runs with *that user's own privileges*,
    not the reader's. Invisible under the old permissive default (everyone
    could read everything); broke immediately once `ou=groups` was made
    reader-only, with Gitea logging a misleading `LDAP Result Code 32 "No
    Such Object"` (OpenLDAP's way of not confirming a restricted subtree
    even exists, rather than a plain access-denied). Root-caused only by
    turning on slapd's `stats` log level and watching the actual bind/
    search sequence on the wire — config readbacks and even a raw dump of
    Gitea's stored LDAP source from its own database looked completely
    correct the whole time. Fix: grant any authenticated (non-anonymous)
    bind read access to `ou=groups` specifically, not just the reader
    account; `ou=people` stays reader-and-self-only.

## Production hardening

This lab intentionally cut corners a production install shouldn't. Status:

- [x] **Replace every `ChangeMe123!` credential** — done, via
  `scripts/11-rotate-credentials.sh`. Rotates the LDAP admin bind
  password, every test user's LDAP password, Gitea's LDAP auth source
  bind password, and Gitea's two local accounts, and re-verifies real
  login + a full replication cycle after each stage rather than trusting
  the update calls succeeded. Not idempotent by design (it generates new
  random secrets every run) — see its own header comment before rerunning
  it. **After running it, `scripts/02` through `scripts/10` can no longer
  be blindly rerun**, since they hard-code the credential this script
  replaces; that's expected, their job (bootstrap the lab) is already
  done.
- [x] **Dedicated, least-privilege LDAP bind account** — done, via
  `scripts/12-ldap-least-privilege.sh`. Replaced the directory admin DN
  Gerrit/Gitea had been reusing (a deliberate shortcut during initial
  setup, see `scripts/02-openldap.sh`) with `cn=ldap-reader`, and — since
  the directory had no explicit ACLs at all before this, running on
  OpenLDAP's wide-open compiled-in default — locked down anonymous access
  too. See SYSADMIN gotcha 12 for the real discovery this took: a naive
  reader-only ACL breaks Gitea's group sync, because Gitea's LDAP client
  reuses one connection across the login flow and ends up running the
  group-membership search as the logging-in user, not the reader.
- [ ] **Point at a real corporate LDAP/OIDC directory** instead of the
  local `slapd` from `scripts/02-openldap.sh`. Can't be executed on this
  lab host (no real directory to point at), but the change itself is
  small and localized: `scripts/04-gerrit.sh`'s `ldap.server`/
  `ldap.accountBase`/`ldap.groupBase`/etc. and `scripts/06-gitea-ldap.sh`'s
  `add-ldap` flags both need to match your real directory's schema (base
  DNs, the attribute holding group membership, whether it uses
  `groupOfNames`/`member` like this lab or something else e.g.
  `memberOf`) — the least-privilege bind account itself is already handled
  above, just pointed at this lab's own directory rather than a real one.
  Everything downstream (Gerrit ACLs bound to `ldap/<dn>` groups, Gitea's
  group-to-team sync) is structurally identical either way; only the
  connection details change.
- [ ] **Put real TLS + a real domain in front of both services.** Can't be
  executed on this lab host (no public DNS to get a real CA-signed cert
  for — Let's Encrypt needs one). nginx already does the reverse-proxy
  plumbing (`scripts/08-nginx.sh`); a real deployment adds a cert (Let's
  Encrypt via `certbot`, or your org's own CA) and listens on `:443`
  instead of `:8091`/`:8090`, which exist here solely because this host's
  port `:80` was already taken by an unrelated Apache2. Gerrit's
  `httpd.listenUrl` is already `proxy-http://` (trusting forwarded
  headers from a reverse proxy), so no Gerrit-side change is needed beyond
  updating `gerrit.canonicalWebUrl` to the real `https://` URL; Gitea
  similarly just needs `ROOT_URL` updated in `app.ini`.
- [ ] **Move Gerrit off H2 and Gitea off SQLite onto PostgreSQL** for
  anything past small-team scale. Not executed here; both are drop-in
  config changes (`database.type`/`jdbc` in `gerrit.config` and
  `[database]` in `app.ini`) but need a real migration pass, not just a
  config edit, since this lab's data would need exporting first.
- [ ] Decide on the deferred items from WORKFLOW.md's "Open items" section
  (the Gerrit→Gitea webhook for in-review visibility, CI/CD placement).

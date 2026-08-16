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
- [x] `scripts/11-set-service-credentials.sh` — sets/changes the
      password for one or more of the non-human "special" accounts
      (`ldap-admin`, `ldap-reader`, `gitea-admin`, `gerrit-replication`)
      individually; see Production Hardening below for what's done vs.
      not
- [x] `scripts/12-ldap-least-privilege.sh` — locks down the directory's
      previously-nonexistent ACLs and adds a dedicated read-only bind
      account for Gerrit/Gitea
- [x] `scripts/13-postgresql.sh` — installs PostgreSQL, one isolated
      database + role per service
- [x] `scripts/14-gerrit-postgresql.sh` — migrates Gerrit's
      AccountPatchReviewDb off H2
- [x] `scripts/15-gitea-postgresql.sh` — migrates Gitea off SQLite,
      preserving all data
- [x] `scripts/16-nginx-tls.sh` — self-signed HTTPS on `:8453`/`:8454`,
      additive alongside the existing plain-HTTP `:8090`/`:8091`
- [ ] Production hardening beyond what's listed above (see below) — not
      done, this is a lab install
- [ ] Gerrit → Gitea webhook for in-review issue visibility — deferred, see
      WORKFLOW.md's "Open items"

## Architecture on this host

| Component | Version | Listens on | Config | Systemd unit |
|---|---|---|---|---|
| OpenLDAP | slapd 2.6.10 | `:389`, `ldapi:///` | `cn=config` (olc) | `slapd` |
| Gitea | 1.27.1 | `127.0.0.1:3000` (HTTP), `:2222` (SSH) | `/etc/gitea/app.ini` | `gitea` |
| Gerrit | 3.14.2 | `127.0.0.1:8080` (HTTP), `:29418` (SSH) | `/var/lib/gerrit/etc/*.config` | `gerrit` |
| nginx | 1.26.3 | `:8090`→Gerrit, `:8091`→Gitea (HTTP); `:8453`→Gerrit, `:8454`→Gitea (HTTPS, self-signed) | `/etc/nginx/sites-available/gerrit-gitea-lab.conf` | `nginx` |
| PostgreSQL | 17 | `127.0.0.1:5432` | `/etc/postgresql/17/main/` | `postgresql` |

Gerrit's `AccountPatchReviewDb` (file-reviewed checkboxes) lives in
database `gerritdb`; Gitea's full application database (users, orgs,
issues, everything) lives in `giteadb`. Each has its own login role
(`gerrit`, `gitea`) with no access to the other's database.

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

## Installing

### Edit config.sh

First of all, edit `scripts/config.sh` — it's the single place `HOST_FQDN`
(and the LDAP `BASE_DN` derived from it) are defined.

**Do this before running `01-prereqs.sh`, not after.** `01-prereqs.sh`
does a noninteractive `slapd` install that derives its actual on-disk LDAP
suffix from the machine's DNS domain *at install time*. `config.sh`'s
`BASE_DN` is only this project's guess at that value, derived from
`HOST_FQDN` the same way. If you change `HOST_FQDN` after `01-prereqs.sh`
already ran, the real slapd suffix on disk won't move to match, and every
later script would silently target the wrong `BASE_DN`. So on a new host:

1. Edit `HOST_FQDN` in `scripts/config.sh` to the new host's real FQDN
   *before running anything*.
2. Run `01-prereqs.sh`.
3. Verify the derived `BASE_DN` guess was actually right:
   `ldapsearch -x -H ldap:/// -b "" -s base namingContexts`. If it
   doesn't match, override `BASE_DN` explicitly in `config.sh` now,
   before `02-openldap.sh`.
4. Continue 02 → 09 as normal — nothing else to touch.

Every script also self-checks this now: `lib.sh` compares `HOST_FQDN`
against `hostname -f` and prints a `WARNING:` (not fatal -- some hosts
legitimately run behind a NAT/LB under a public name that differs from
their local hostname) if they don't match. It won't catch a wrong
`BASE_DN` on its own (`02-openldap.sh`'s hard failure still does that),
but it does catch the case that check misses: a wrong host *label* under
the same domain, which sails through `02` silently and only shows up
later as wrong URLs baked into `gerrit.config`/`app.ini`/nginx. If you
see that warning, fix `config.sh` before continuing rather than pushing
through -- see "Fixing a wrong `HOST_FQDN` after the fact" below for the
cleanup if you already have.

### Run the scripts as root

Run the scripts in numerical order **as root**.

Each script is self-contained, logs what it's doing, and is safe to rerun
(see `scripts/lib.sh` for the shared idempotency/error-handling helpers).

Every script pulls both in automatically via `lib.sh` (it sources `config.sh`
on every invocation, so there's nothing to separately "source" yourself — editing
the values is the only step).

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

### Fixing a wrong `HOST_FQDN` after the fact

If you already ran scripts with the wrong host label (same domain, so
`BASE_DN`/LDAP are unaffected) before catching it:

1. Fix `HOST_FQDN` in `scripts/config.sh`.
2. `03-gitea.sh` writes `/etc/gitea/app.ini` **once** and never touches it
   again on rerun (by design -- see gotcha 1 below), so rerunning it won't
   pick up the fix. Edit `DOMAIN`, `ROOT_URL`, and `SSH_DOMAIN` in
   `/etc/gitea/app.ini` by hand, then `systemctl restart gitea`.
3. `04-gerrit.sh`'s config writes go through `git config -f`, which *does*
   update in place on rerun: `sudo bash scripts/04-gerrit.sh` correctly
   rewrites `canonicalWebUrl`. It won't restart Gerrit itself if already
   active (it only logs a reminder) -- run `systemctl restart gerrit`
   afterward.
4. `07-replication.sh` doesn't use `HOST_FQDN` at all (it only talks to
   `127.0.0.1` ports), so nothing to redo there.
5. Rerun `08-nginx.sh` -- it always rewrites its site file from scratch,
   so it just picks up the corrected value.

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
13. **Gerrit's `[database]` section in `gerrit.config` is vestigial
    ReviewDb-era config and does nothing in a NoteDb-based Gerrit like
    this one.** Setting `database.type = postgresql` etc. was accepted
    with no error, and Gerrit kept silently writing to the old H2 file
    regardless. The real config key, straight from Gerrit's own bundled
    `Documentation/config-gerrit.html` inside the WAR (there's no public
    docs site for this) is `accountPatchReviewDb.url`, and changing it
    requires running the `MigrateAccountPatchReviewDb` program with the
    server *stopped*, not just a reconfigure-and-restart. Also: the
    PostgreSQL JDBC driver isn't bundled in `gerrit.war` (H2's is) --
    fails with `ClassNotFoundException: org.postgresql.Driver` without
    manually downloading it into `$SITE/lib`.
14. **Gitea's file-mode logging (`[log] MODE = file`, set in phase 3)
    means the systemd journal only ever shows a handful of bootstrap
    lines.** A crash-looping Gitea showed literally nothing useful in
    `journalctl` -- no error, just silence between "Prepare to run web
    server" and the exit. The real error is always in
    `/var/lib/gitea/log/gitea.log`, which the journal never sees once
    Gitea's own logger takes over.
15. **pgloader's default SQLite→PostgreSQL migration (auto-creating the
    target schema from SQLite's structure) is incompatible with what
    Gitea's own ORM expects**, even though the import itself reports
    zero errors and correct row counts. Gitea's startup schema sync then
    gets stuck retrying an index it can't drop because a constraint
    depends on it, forever -- a symptom of pgloader's SQLite-derived
    index names and column types (`BIGINT` vs the `BIGSERIAL` xorm
    expects, `TEXT` vs `VARCHAR(255)`, etc.) not matching Gitea's Go
    structs. Fix: let Gitea build its own schema first (empty database +
    a normal startup), then run pgloader in `create no tables, create no
    indexes` mode -- "the schema already exists, adapt to its types,
    load data only." Also: pgloader's CLI `--with` flag rejects a
    comma-separated option list (parse error right at the comma) despite
    that being the documented `.load`-file syntax; each option needs its
    own `--with`.

## Production hardening

This lab intentionally cut corners a production install shouldn't. Status:

- [x] **Replace every `ChangeMe123!` credential** — done, via two
  tools with different scopes. Non-human "special" accounts (the LDAP
  admin bind, the `ldap-reader` search bind if `scripts/12` has been
  run, and Gitea's two local accounts `gitea-admin`/
  `gerrit-replication`) go through `scripts/11-set-service-credentials.sh
  <account> [<account> ...]`, one or more at a time — it updates every
  place each account's password is stored (Gerrit's `secure.config`/
  `replication.config`, Gitea's LDAP auth source) and restarts whatever
  needs it, verifying the new password actually authenticates rather
  than trusting the update call succeeded. Real LDAP people (`carol`,
  and any other account under `ou=people`) go through
  `ggadmin-user set-password <uid>` instead (ADMIN.md section 1) — not
  this script, since they're not "special" accounts. **After running
  either against a fresh install, `scripts/02` through `scripts/10` can
  no longer be blindly rerun**, since they hard-code the
  `ChangeMe123!` credentials these tools replace; that's expected,
  their job (bootstrap the lab) is already done. The lab's `alice`/
  `bob` test users aren't "special" either, and aren't needed past
  bootstrap — remove them once real users exist:
  `ggadmin-user offboard alice --delete-entry` (and the same for
  `bob`).
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
- [x] **TLS termination on nginx** — partially done. `scripts/16-nginx-tls.sh`
  adds self-signed HTTPS on `:8453`/`:8454`, purely additive alongside the
  existing plain-HTTP `:8090`/`:8091`, to demonstrate TLS termination
  actually works (verified live) without touching anything that currently
  depends on the `http://` URLs (Gerrit's `canonicalWebUrl`, the
  replication URL, every script/doc in this project).
  **Real TLS + a real domain is still not done** and can't be executed on
  this lab host (no public DNS to get a real CA-signed cert for — Let's
  Encrypt needs one). A real deployment replaces the self-signed cert with
  one from Let's Encrypt (`certbot`) or your org's own CA, moves onto
  `:443` instead of the alt ports (which exist here solely because this
  host's port `:80` was already taken by an unrelated Apache2), and
  updates `gerrit.canonicalWebUrl` and Gitea's `ROOT_URL` to the real
  `https://` URL — Gerrit's `httpd.listenUrl` is already `proxy-http://`
  (trusting forwarded headers from a reverse proxy), so no other
  Gerrit-side change is needed.
- [x] **Move Gerrit off H2 and Gitea off SQLite onto PostgreSQL** — done,
  via `scripts/13-postgresql.sh`, `scripts/14-gerrit-postgresql.sh`, and
  `scripts/15-gitea-postgresql.sh`. Neither turned out to be a simple
  config-and-restart, as originally guessed in this section — see
  gotchas 13-15 for what each actually took, including a real data
  migration for Gitea (verified specific records survived across
  multiple tables, not just that Gitea started).
- [ ] Decide on the deferred items from WORKFLOW.md's "Open items" section
  (the Gerrit→Gitea webhook for in-review visibility, CI/CD placement).

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

- [x] `scripts/install/01-prereqs.sh` — packages, `gerrit`/`gitea` system users
- [x] `scripts/install/02-openldap.sh` — test OpenLDAP directory
- [x] `scripts/install/03-gitea.sh` — Gitea install
- [x] `scripts/install/04-gerrit.sh` — Gerrit install, LDAP auth
- [x] `scripts/install/05-gerrit-acl.sh` — Gerrit authorization bound to an LDAP group
- [x] `scripts/install/06-gitea-ldap.sh` — Gitea LDAP source + group-to-team sync
- [x] `scripts/install/07-replication.sh` — Gerrit → Gitea replication
- [x] `scripts/install/08-nginx.sh` — reverse proxy
- [x] `scripts/install/09-smoke-test.sh` — full end-to-end verification
- [x] `scripts/install/10-delete-project-plugin.sh` — enables Gerrit's
      `delete-project` plugin (bundled in the WAR, not installed by phase
      4), used by the project-deletion procedure in [ADMIN.md](ADMIN.md)
- [x] `scripts/install/11-postgresql.sh` — installs PostgreSQL, one
      isolated database + role per service. This project's chosen
      database backend, not optional hardening -- see "Run the scripts
      as root" below for why it's numbered here instead of in
      `hardening/`
- [x] `scripts/install/12-gerrit-postgresql.sh` — migrates Gerrit's
      AccountPatchReviewDb off H2
- [x] `scripts/install/13-gitea-postgresql.sh` — migrates Gitea off
      SQLite, preserving all data
- [x] `scripts/install/14-gerrit-service-account.sh` — creates `gerrit-bot`,
      the dedicated non-human account holding Gerrit admin rights, and
      confirms it — required before
      `scripts/post-install/final-remove-test-users.sh` (see "Post-install"
      below), which errors outright without it
- [x] `scripts/post-install/set-service-credentials.sh` — sets/changes the
      password for one or more of the non-human "special" accounts
      (`ldap-admin`, `ldap-reader`, `gitea-admin`, `gerrit-replication`),
      individually or all at once (`all`) — see "Post-install" below
- [x] `scripts/post-install/ldap-least-privilege.sh` — locks down the directory's
      previously-nonexistent ACLs and adds a dedicated read-only bind
      account for Gerrit/Gitea — see "Post-install" below
- [x] `scripts/post-install/final-remove-test-users.sh` — removes the lab
      test users `alice`/`bob`/`carol` (LDAP entries + Gerrit/Gitea
      deactivation) once they're no longer needed, and the now-empty
      `developers` LDAP group they leave behind. Run this one **last**
      (the name says so) — see "Post-install" below
- [x] `scripts/hardening/nginx-tls.sh` — self-signed HTTPS on `:8453`/`:8454`,
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
- **H2/SQLite bootstrap, then PostgreSQL.** `scripts/install/03-gitea.sh`/
  `04-gerrit.sh` initialize Gerrit/Gitea on H2/SQLite for a fast,
  dependency-light first boot, but `scripts/install/11-postgresql.sh`
  through `13-gitea-postgresql.sh` immediately migrate both onto
  PostgreSQL — this project's actual chosen database backend, not
  optional hardening (see "Run the scripts as root" below for why
  they're numbered in `install/`, not `hardening/`). Neither migration
  turned out to be a simple config-and-restart, as originally guessed
  — see gotchas 13-15 for what each actually took, including a real
  data migration for Gitea (verified specific records survived across
  multiple tables, not just that Gitea started).
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
sudo bash scripts/install/01-prereqs.sh
sudo bash scripts/install/02-openldap.sh
sudo bash scripts/install/03-gitea.sh
sudo bash scripts/install/04-gerrit.sh
sudo bash scripts/install/05-gerrit-acl.sh
sudo bash scripts/install/06-gitea-ldap.sh
sudo bash scripts/install/07-replication.sh
sudo bash scripts/install/08-nginx.sh
sudo bash scripts/install/09-smoke-test.sh
```

**`09-smoke-test.sh` is the last unconditionally required step.** It
runs a full push → review → submit → replicate → issue-auto-close
cycle, so a clean exit there means you have a complete, working
installation — on H2/SQLite. `scripts/install/` isn't quite done yet
for a real deployment, though: `11`-`13` below move Gerrit/Gitea onto
PostgreSQL, this project's actual chosen backend, and are effectively
required too outside of a disposable lab. Everything past `09`,
across every `scripts/` subdirectory, serves a different purpose
rather than continuing one sequence:

- **`scripts/install/10` through `14`** — five more scripts left in
  `install/` after the required run above, all one-time setup, but not
  equally optional:
  - `10-delete-project-plugin.sh` enables the Gerrit plugin
    `ggadmin-project delete` needs (ADMIN.md section 2) — skip until
    you actually need to delete a project.
  - `11-postgresql.sh`, `12-gerrit-postgresql.sh`, and
    `13-gitea-postgresql.sh` move Gerrit/Gitea off H2/SQLite onto
    PostgreSQL. This is this project's chosen database backend, not an
    optional hardening add-on — treat these three as required for any
    real deployment, and only skip them for a disposable lab you don't
    care about. Run `11` first and capture the `GERRIT_DB_PW`/
    `GITEA_DB_PW` it prints, then `12` and `13` (either order relative
    to each other).
  - `14-gerrit-service-account.sh` creates `gerrit-bot` — the dedicated,
    non-human account meant to hold Gerrit admin rights instead of a
    real person (ADMIN.md's "Setting up the Gerrit service account").
    Needs `05-gerrit-acl.sh` already run (the `admins` LDAP group and
    Gerrit's own LDAP auth). Effectively required, same as `11`-`13`:
    `scripts/post-install/final-remove-test-users.sh` hard-depends on
    `gerrit-bot` already existing (carol and gerrit-bot are the only two
    members of `admins`, and LDAP refuses to empty a `groupOfNames`) —
    skipping this script is exactly what produces "uid=carol is the
    last member of 'admins'" out of that one later.
- **`scripts/post-install/`** — closes the gap between "installed" and
  "not shipping known-insecure defaults," which `install/` deliberately
  leaves open for reproducibility (see "Every account in this lab uses
  the password `ChangeMe123!`" above). Skippable for a disposable lab,
  but effectively required for any real deployment, same reasoning as
  the PostgreSQL scripts above — just not part of `install/` itself
  since neither changes how the system works, only how exposed it is
  by default: `set-service-credentials.sh all` rotates every "special"
  account off `ChangeMe123!` in one command (`ldap-admin`,
  `gitea-admin`, `gerrit-replication` are all still on it after
  `install/` alone); `ldap-least-privilege.sh` locks down the LDAP
  directory, which otherwise ships with **no ACLs at all** — anonymous
  can read the entire `ou=people`/`ou=groups` tree. Also here:
  `final-remove-test-users.sh`, which removes the lab test users
  `alice`/`bob`/`carol` once they're no longer needed — genuinely
  optional (unlike the other two), and the name says what it needs to:
  run it **last**, after everything else in `post-install/` and
  `install/` that you're going to run, since `12`-`13` above still need
  `alice`/`carol` alive for their own verification.
  `ldap-least-privilege.sh` used to have this same constraint but no
  longer does — it verifies against `gerrit-bot` instead (see "Which
  ones to run, and in what order" below) — so it's fine to run before
  or after `final-remove-test-users.sh`, in either order. None of the
  three are numbered relative to each other — the ordering that matters
  here is "`12`/`13`, then this one," which the name conveys on its own,
  not "run 1, 2, 3 in sequence" — see "Post-install" below for the full
  reasoning and a copy-pasteable sequence.
- **`scripts/hardening/`** — genuinely optional, deferrable extras:
  currently just `nginx-tls.sh` (self-signed HTTPS), which needs a real
  domain/CA-signed cert to matter for production and is fine to put off
  until you have one. Not numbered, same reason as `post-install/`: no
  sequence to number by.
- **`scripts/day2/`** — ongoing/Day-2 tooling, not setup, and not a
  sequence either (hence no numbers): `customer-sync.sh` runs as
  needed, not once; `user-lifecycle.sh`/`project-lifecycle.sh` are the
  `ggadmin-user`/`ggadmin-project` admin CLIs (ADMIN.md), and
  `install-ggadmin-tools.sh` puts them on PATH — worth running if you
  want those commands available, but not required for the install
  itself to work. It copies rather than symlinks into this repo clone,
  so it needs rerunning after an edit or `git pull` to those two
  scripts (or `lib.sh`/`config.sh`) to take effect — see the script's
  own header for why.
- **`scripts/teardown/`** — the opposite of installing, and genuinely
  sequential (`21-teardown-data.sh` before `22-teardown-packages.sh`,
  the latter refuses to run otherwise) — see "Tearing down the
  installation" below.

Each script has a comment block at the top explaining what it does and
why; read those rather than this doc if you need the exact commands.

### Fixing a wrong `HOST_FQDN` after the fact

If you already ran scripts with the wrong host label (same domain, so
`BASE_DN`/LDAP are unaffected) before catching it:

1. Fix `HOST_FQDN` in `scripts/config.sh`.
2. `03-gitea.sh` writes `/etc/gitea/app.ini` **once** and never touches it
   again on rerun (by design -- see gotcha 1 below), so rerunning it won't
   pick up the fix. Edit `DOMAIN`, `ROOT_URL`, and `SSH_DOMAIN` in
   `/etc/gitea/app.ini` by hand, then `systemctl restart gitea`.
3. `04-gerrit.sh`'s config writes go through `git config -f`, which *does*
   update in place on rerun: `sudo bash scripts/install/04-gerrit.sh` correctly
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
    into `All-Projects`' ACL (as `scripts/install/05-gerrit-acl.sh` does) so
    *membership in the LDAP group* is the actual source of truth for who
    gets Gerrit admin rights.
11. **Gitea's team-edit API silently discards a partial `PATCH`.** Sending
    `{"includes_all_repositories": true}` alone returns `HTTP 200` with the
    field still `false` in the response — no error, nothing to notice
    unless you actually read the response back. This bit us for real: an
    earlier version of `scripts/install/07-replication.sh` sent exactly that
    partial PATCH, every subsequent script run kept logging success, and
    the `Developers` team's grant silently never took effect — LDAP
    developers got `404` on the mirrored repo, its issues, *and* its wiki
    the entire time, only caught while testing wiki access for
    WORKFLOW.md section 4. Always resend the full team object (`units_map`
    included) on any team edit, and verify by reading the field back
    afterward rather than trusting the HTTP status code — which is exactly
    what the fixed script now does.
12. **This directory had no explicit ACLs at all until
    `scripts/post-install/ldap-least-privilege.sh`**, running on OpenLDAP's
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
16. **`nginx`'s `$host` variable never includes a port, which broke Gitea
    project creation with a CSRF rejection** (`cross-origin request
    detected ... Origin does not match Host`) purely because Gerrit/Gitea
    both run on non-default ports (`:8090`/`:8091` plain, `:8453`/`:8454`
    TLS) — `scripts/install/08-nginx.sh`'s `proxy_set_header Host
    $host;` forwarded Gitea a Host header of just `host`, while the
    browser's `Origin` for a non-default-port URL always includes the
    port (`http://host:8091`); Gitea's CSRF check compares the two and
    rejected every state-changing request. Looked exactly like a
    hostname mismatch at first — `DOMAIN`/`ROOT_URL` in `app.ini`,
    `config.sh`'s `HOST_FQDN`, `hostname -f`, and nginx's `server_name`
    all agreed, which is what actually narrowed it down to the proxy
    layer rather than DNS/config. Fix: `proxy_set_header Host
    $http_host;` instead, which preserves the port the client actually
    sent. Wouldn't have surfaced at all on the standard `:80`/`:443`,
    where browsers omit the port from `Origin` too.
17. **There is no multi-org support, despite `ggadmin-project` accepting
    a `GITEA_ORG` variable.** Every Gerrit-created project replicates into
    the single Gitea org `engineering`, unconditionally —
    `scripts/install/07-replication.sh` bakes `ORG="engineering"` straight
    into `remote.gitea.url` in `replication.config`, and doesn't read
    `GITEA_ORG` at all. `project-lifecycle.sh` reads `GITEA_ORG` for its
    *own* two follow-up API calls (disable Pull Requests, add branch
    protection) and for the URLs it prints, but that's it — those calls
    just silently target an org the mirror was never actually pushed to.
    Confirmed live: `GITEA_ORG=other-org ggadmin-project add foo` creates
    the Gerrit project and the `engineering/foo` mirror exactly as normal,
    then dies after 30s insisting `other-org/foo` never appeared, because
    it never will. And separately, in the other direction: this has
    nothing to do with replication being one-way regardless of org — a
    repo created directly in Gitea, in `engineering` or any other org,
    never reaches Gerrit either way (WORKFLOW.md section 2). Nothing
    disables Gitea's self-service org creation, so anyone can create a
    second org; it just won't be connected to Gerrit in either direction,
    and gets none of `engineering`'s LDAP-team/branch-protection setup
    (`scripts/install/06-gitea-ldap.sh` hardcodes `ORG="engineering"` too).

## Post-install

`install/` deliberately ships with known lab-default credentials and a
wide-open LDAP directory, for reproducibility (see "Every account in
this lab uses the password `ChangeMe123!`" above) — the three scripts
here close that gap and clean up after it. Not part of `install/`
itself, since none of them changes how the system works, only how
exposed it is by default or which test-only accounts are still present
(unlike the PostgreSQL scripts, a real architecture decision) — but not
"opt-in" the way "Production hardening" below is, either: skippable for
a disposable lab, effectively required for anything real.

### Which ones to run, and in what order

`set-service-credentials.sh` and `ldap-least-privilege.sh` are
independent of each other — no ordering constraint between them, and
(since a redesign — see below) neither depends on the lab test users
`alice`/`bob`/`carol` still existing either. `final-remove-test-users.sh`
depends on `scripts/install/12`/`13` having already run (if you're
running them at all) — its name says so directly, which is why it's not
just `remove-test-users.sh`: nothing else in `post-install/` is numbered
either, but this one script's position genuinely isn't interchangeable,
and a name is a lighter way to say that than a number would be for a
one-script exception in an otherwise unordered directory.

- **`scripts/install/12-gerrit-postgresql.sh` and `13-gitea-postgresql.sh`
  before `scripts/post-install/final-remove-test-users.sh`, not after**
  — both scripts' own verification step logs in as `alice`/`carol` to
  *prove* the PostgreSQL migration didn't break anything; if the test
  users are already deleted, they have nothing to verify with and fail.
  Do the migration while the test users still exist; removing them is
  `final-remove-test-users.sh`'s job, done last.
- **`scripts/install/14-gerrit-service-account.sh` before both
  `final-remove-test-users.sh` *and* `ldap-least-privilege.sh`** — for
  `final-remove-test-users.sh` this is a hard failure, not just a failed
  verification: `carol` and `gerrit-bot` are the only two members of the
  LDAP `admins` group, so removing `carol` while `gerrit-bot` doesn't
  exist yet would empty a `groupOfNames`, which LDAP refuses.
  `ldap-least-privilege.sh` needs `gerrit-bot` for a different reason:
  its own verification step (below) authenticates as `gerrit-bot`
  instead of a lab test user, specifically so it has nothing to do with
  `final-remove-test-users.sh`'s ordering — but that means it now needs
  `gerrit-bot` to exist by the time *it* runs, instead.

`ldap-least-privilege.sh` used to depend on `alice`/`carol` the same
way `12`/`13` still do — confirmed live to actually break that way, not
just in theory: on a host that had already run
`final-remove-test-users.sh`, rerunning `ldap-least-privilege.sh` (to
recreate `ou=services`, which had somehow gone missing) died at
"`carol` cannot log into Gerrit" purely because `carol` no longer
existed, even though the actual lockdown it was trying to verify was
already correct. Redesigned to verify against `gerrit-bot` instead
(`PROBER_UID`, default `gerrit-bot`) and the reader account's own LDAP
entry — both things this project already treats as permanent,
always-present prerequisites — so it no longer cares what order it runs
relative to `final-remove-test-users.sh`, or whether that script has
run at all. See its header comment for the (now rare) case where you'd
still need to override `PROBER_UID`/`GERRIT_ADMIN_PW`.

`set-service-credentials.sh` has no ordering constraint against either
of the other two — run it whenever the credential you want to rotate
exists (or use `all`).

A reasonable sequence, doing all three:

```
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' \
  bash scripts/post-install/ldap-least-privilege.sh
sudo LDAP_ADMIN_PW='...' bash scripts/post-install/set-service-credentials.sh all
# ^ prints a NEW ldap-admin password -- every '...' placeholder below
# means that new value, not the one used above.
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  bash scripts/post-install/final-remove-test-users.sh
```

(This assumes `scripts/install/11-14` -- PostgreSQL and the `gerrit-bot`
service account -- already ran as part of `install/`, since `12`-`14`
each share some form of a "before `final-remove-test-users.sh`"
constraint above -- `14` a hard failure for that script, `12`/`13` a
failed verification. `14` is also now a prerequisite for
`ldap-least-privilege.sh` itself, per its own default `PROBER_UID`.)

Each script's own header comment has the exact credentials it needs and
where to get them; the status list below explains what each one does
and why, not how to sequence them.

### Status

- [x] **Replace every `ChangeMe123!` credential** — done, via two
  tools with different scopes. **`scripts/install/` on its own does
  NOT do this** — `ldap-admin`, `gitea-admin`, and `gerrit-replication`
  are all still `ChangeMe123!` after a fresh install finishes, and
  `ldap-reader` doesn't even exist yet; that's deliberate (see "Every
  account in this lab uses the password `ChangeMe123!`" above), not an
  oversight, since scripts/install/02-10 rely on it being the same
  known value every run. Rotating is this separate step. Non-human
  "special" accounts (the LDAP admin bind, the `ldap-reader` search
  bind if `scripts/post-install/ldap-least-privilege.sh` has been run,
  and Gitea's two local accounts `gitea-admin`/`gerrit-replication`) go
  through `scripts/post-install/set-service-credentials.sh <account>
  [<account> ...]`, one or more at a time, **or `all` to rotate every
  one of them that currently exists in a single command** — it updates
  every place each account's password is stored (Gerrit's
  `secure.config`/`replication.config`, Gitea's LDAP auth source) and
  restarts whatever needs it, verifying the new password actually
  authenticates rather than trusting the update call succeeded. Real LDAP people (any real
  named account under `ou=people`) go through `ggadmin-user
  set-password <uid>` instead (ADMIN.md section 1) — not this script,
  since they're not "special" accounts. **After running either against
  a fresh install, `scripts/install/02` through `scripts/install/10`
  can no longer be blindly rerun**, since they hard-code the `ChangeMe123!` credentials
  these tools replace; that's expected, their job (bootstrap the lab)
  is already done. The lab test users `alice`/`bob`/`carol` aren't
  "special" accounts either and shouldn't survive into Day-2, but
  removing them is `scripts/post-install/final-remove-test-users.sh`'s job now
  (see "Run the scripts as root" above and ADMIN.md's "Removing the lab
  test users") — not part of this credential-rotation step, just worth
  sequencing after `ldap-least-privilege.sh` below if you're doing both
  (see "Which ones to run, and in what order").
- [x] **Dedicated, least-privilege LDAP bind account** — done, via
  `scripts/post-install/ldap-least-privilege.sh`. Replaced the directory admin DN
  Gerrit/Gitea had been reusing (a deliberate shortcut during initial
  setup, see `scripts/install/02-openldap.sh`) with `cn=ldap-reader`
  (see ADMIN.md's "What `ldap-reader` is, and why it exists" for what
  this account actually does day to day, not just this status bullet)
  and, since the directory had no explicit ACLs at all before this,
  running on OpenLDAP's wide-open compiled-in default — locked down
  anonymous access too. See gotcha 12 above for the real discovery
  this took: a naive
  reader-only ACL breaks Gitea's group sync, because Gitea's LDAP client
  reuses one connection across the login flow and ends up running the
  group-membership search as the logging-in user, not the reader.
- [x] **Remove the lab test users** — done, via
  `scripts/post-install/final-remove-test-users.sh`. `alice`/`bob`/
  `carol` aren't "special" accounts (the bullet above), but they
  shouldn't survive into Day-2 either; this isn't just three `offboard`
  calls, though, since `alice`/`bob` are the only members of the
  `developers` LDAP group and `groupOfNames` can't have zero members —
  see ADMIN.md's "Removing the lab test users" for the full procedure
  this script automates, including the now-empty-group cleanup and
  what recreating it for the first real developer looks like.

## Production hardening

Genuinely optional, deferrable extras — unlike "Post-install" above,
nothing here closes a "ships insecure by default" gap; it's real
production-grade infrastructure this lab doesn't have the resources
for (a public domain, a real CA-signed cert), documented for when you
do.

### Status

- [ ] **Point at a real corporate LDAP/OIDC directory** instead of the
  local `slapd` from `scripts/install/02-openldap.sh`. Can't be executed on this
  lab host (no real directory to point at), but the change itself is
  small and localized: `scripts/install/04-gerrit.sh`'s `ldap.server`/
  `ldap.accountBase`/`ldap.groupBase`/etc. and `scripts/install/06-gitea-ldap.sh`'s
  `add-ldap` flags both need to match your real directory's schema (base
  DNs, the attribute holding group membership, whether it uses
  `groupOfNames`/`member` like this lab or something else e.g.
  `memberOf`) — the least-privilege bind account itself is already
  handled in "Post-install" above, just pointed at this lab's own
  directory rather than a real one. Everything downstream (Gerrit ACLs
  bound to `ldap/<dn>` groups, Gitea's group-to-team sync) is
  structurally identical either way; only the connection details change.
- [x] **TLS termination on nginx** — partially done. `scripts/hardening/nginx-tls.sh`
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
- [ ] Decide on the deferred items from WORKFLOW.md's "Open items" section
  (the Gerrit→Gitea webhook for in-review visibility, CI/CD placement).

## Tearing down the installation

Two scripts, meant to be run in order, both requiring root and both
gated by a confirmation prompt (type the host's `HOST_FQDN` to
proceed, or pass `--yes` for scripted use) since neither is
reversible:

- **`scripts/teardown/21-teardown-data.sh`** — stops and removes
  everything gg-specific: the `gerrit`/`gitea` systemd services and
  their installed binaries, `/var/lib/gerrit`, `/var/lib/gitea`,
  `/etc/gitea` (every project, review, repo, issue, and wiki page — not
  just lab test data), the whole LDAP `ou=people`/`ou=groups`/
  `ou=services` tree under `BASE_DN`, the `gerritdb`/`giteadb`
  PostgreSQL roles and databases if `scripts/install/11-13` were ever
  run, this project's nginx site config and self-signed TLS certs, the
  `gerrit`/`gitea` system users, and everything
  `scripts/day2/install-ggadmin-tools.sh` installed — the `ggadmin-*`
  symlinks and their standalone copy under `/usr/local/lib/gerrit-gitea/`.
  Needs `LDAP_ADMIN_PW` if slapd is still running
  (same credential `scripts/day2/user-lifecycle.sh` uses). Leaves the underlying
  packages installed.
- **`scripts/teardown/22-teardown-packages.sh`** — run after the above (it
  refuses to proceed if the `gerrit`/`gitea` systemd units or system
  users still exist, unless `--force` is passed). `apt-get purge`s
  `nginx`, `slapd`/`ldap-utils`, every installed `postgresql*` package,
  and `openjdk-21-jre-headless` — the packages
  `scripts/install/01`/`scripts/install/11-postgresql.sh` installed solely for this
  project — plus their config/data directories as a fallback in case a
  purge leaves them behind.

Both scripts are idempotent the same way every other script here is: a
target that's already gone is logged and skipped, not treated as an
error, so a teardown interrupted partway through (or run twice) just
finishes the rest instead of failing. **Apache2 on `:80` predates this
project and neither script touches it.**

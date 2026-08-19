# Gerrit + Gitea: Admin Operations Guide

This sits between [SYSADMIN.md](SYSADMIN.md) (install the infrastructure)
and [WORKFLOW.md](WORKFLOW.md) (use it day to day as a developer): it's the
"how do I add/change/remove a user or a project" reference for whoever
administers this setup. Every procedure below was run against the live test
install, not written from the plugin docs — see each section's notes for
things that surprised us.

Examples use this lab's actual values (base DN `dc=tkos,dc=co,dc=il`, Gitea
org `engineering`, test password `ChangeMe123!`) — substitute your real
values. LDAP operations use the regular `cn=admin` bind over `ldap://`, so
they don't need root on the Gerrit/Gitea host at all; only the one plugin
install below does.

**Everything below is now also wrapped as scripts** —
`scripts/day2/user-lifecycle.sh` (section 1) and
`scripts/day2/project-lifecycle.sh` (section 2), run as root on the
Gerrit/Gitea host the same way as every other numbered script here.
They encode every
gotcha this file documents (the Gerrit/Gitea sync asymmetry, the two
required Gitea follow-ups on project creation, the Gerrit
`is:inactive`-readback quirk, ...) instead of leaving it to a human to
remember on every one-off `curl`. The commands below are still shown
in full since they're what the scripts actually run, and the prose
around them (why each step exists, what surprised us) is the part a
script can't carry — but for real operations, prefer the script.

Run `sudo bash scripts/day2/install-ggadmin-tools.sh` to put them on
PATH under short names — `ggadmin-user`, `ggadmin-project`, and
`ggadmin-verify-creds` — so `sudo ggadmin-user offboard dave` works
from anywhere without a `scripts/` path. That's what the rest of this
file calls them as; before installing, substitute the full
`scripts/day2/user-lifecycle.sh` / `scripts/day2/project-lifecycle.sh` /
`scripts/day2/verify-creds.sh` path instead. It installs a standalone
copy under `/usr/local/lib/gerrit-gitea/`, not a symlink into this repo
clone — run it again any time you edit these scripts (or `git pull` a
change to them) and want that change to actually take effect on this
host.

### Required credentials, per command

Neither `ggadmin-user` nor `ggadmin-project` stores or defaults any of
these — every credential below has to be passed in on every invocation,
as an env var on the `sudo` command line (sudo strips plain env vars
otherwise; see each script's header for the exact syntax). Both scripts
now also verify each credential is actually correct before doing
anything else, not just that it's set — a stale password fails
immediately with a line naming exactly which credential is wrong,
rather than surfacing minutes later as a bare `curl: (22) ... 503` (or
401) from deep inside some subcommand with no hint it's a credential
problem at all. Run `sudo ggadmin-verify-creds` any time you just want
to sanity-check credentials on their own — pass whichever of
`LDAP_ADMIN_PW`/`GERRIT_ADMIN_PW`/`GITEA_ADMIN_PW` you want checked;
any left unset are skipped, not failed. `LDAP_ADMIN_PW` and
`GITEA_ADMIN_PW` are whatever `scripts/post-install/set-service-credentials.sh
ldap-admin` / `... gitea-admin` last set them to, or still the install
default `ChangeMe123!` if that was never run; `GERRIT_ADMIN_PW` is
whatever `ggadmin-user add gerrit-bot ...` or
`ggadmin-user set-password gerrit-bot` last set it to (see "Setting up
the Gerrit service account" below).

- **`ggadmin-user add / set-password / groups / add-group /
  remove-group`** — `LDAP_ADMIN_PW` only (`cn=admin`'s password). These
  never touch Gerrit or Gitea directly, only the shared LDAP directory.
- **`ggadmin-user offboard`** — `LDAP_ADMIN_PW`, plus `GERRIT_ADMIN_PW`
  and `GITEA_ADMIN_PW` (current passwords for the `gerrit-bot`/
  `gitea-admin` admin accounts — see "Setting up the Gerrit service
  account" below for what `gerrit-bot` is) to also deactivate the
  Gerrit/Gitea accounts, not just pull LDAP group membership.
- **`ggadmin-user reactivate`** — `GERRIT_ADMIN_PW` and `GITEA_ADMIN_PW`.
  `LDAP_ADMIN_PW` is also required up front even though this particular
  subcommand never touches LDAP — the check runs before the script knows
  which subcommand you picked.
- **`ggadmin-project add / describe / delete`** — `GERRIT_ADMIN_PW` and
  `GITEA_ADMIN_PW` for all three; there's no LDAP-only path here since
  every project operation touches at least one of Gerrit or Gitea.

### What these credentials are, and how they're set

These three names refer to genuinely different kinds of account, not
three peers of the same shape — worth knowing before you go looking for
where to reset one.

- **`LDAP_ADMIN_PW`** is `cn=admin`'s bind password — LDAP's own
  directory superuser (`olcRootPW` on the config backend), not a person
  entry under `ou=people` and not a member of any group. It bypasses
  every ACL by being the directory root, so it has no connection to
  group membership at all. Set at bootstrap by `scripts/install/02-openldap.sh`
  (lab default `ChangeMe123!`); changed by
  `scripts/post-install/set-service-credentials.sh ldap-admin` via
  `ldapmodify -Y EXTERNAL` against the `cn=config` backend over
  `ldapi:///` (SASL EXTERNAL auth as root, not a regular LDAP bind).

- **`GERRIT_ADMIN_PW`** is not a Gerrit-side secret at all — it **is the
  LDAP password of whichever LDAP account `GERRIT_ADMIN_USER` names**
  (default `gerrit-bot`, a dedicated service account — see "Setting up
  the Gerrit service account" below for why). Gerrit's `auth.type=LDAP`
  plus `auth.gitBasicAuthPolicy=LDAP` (`scripts/install/04-gerrit.sh`,
  `scripts/install/05-gerrit-acl.sh`) means Gerrit validates REST/git-over-HTTP
  credentials directly against LDAP bind — nothing is stored in Gerrit
  itself to rotate independently. The only way to change it is to
  change that account's LDAP `userPassword`
  (`ggadmin-user set-password gerrit-bot`). A wrong `GERRIT_ADMIN_PW`
  surfaces as **HTTP 503**, not the 401 you'd expect for bad
  credentials — Gerrit's LDAP realm throws an unhandled
  `AuthenticationException` (`error code 49 - Invalid Credentials` in
  `journalctl -u gerrit`) on the rejected bind, and that propagates up
  as a service error rather than a clean auth rejection. `ggadmin-*`'s
  built-in credential check (above) already accounts for this.

- **`GITEA_ADMIN_PW`** is the password for `gitea-admin`, a **local
  Gitea-only account, deliberately not LDAP-backed**
  (`scripts/install/03-gitea.sh`, `scripts/install/06-gitea-ldap.sh`) — a completely
  separate identity from LDAP, stored in Gitea's own database. Set at
  bootstrap by `scripts/install/03-gitea.sh`; changed by
  `scripts/post-install/set-service-credentials.sh gitea-admin` via Gitea's own
  `gitea admin user change-password` CLI, which never touches LDAP.

**Connection to group membership/roles — and it's asymmetric between
the two:**

- Gerrit admin rights (`administrateServer`, the capability
  `GERRIT_ADMIN_PW`'s holder needs for these scripts to work at all)
  are **durably, live-derived from the LDAP `admins` group**:
  `scripts/install/05-gerrit-acl.sh` adds `ldap/cn=admins,ou=groups,...`
  straight into `All-Projects`' ACL, and Gerrit resolves `ldap/<dn>`
  group references against LDAP on every request — no caching, no
  re-login needed. (The very first admin grant in this lab came from a
  separate, one-time Gerrit quirk — it auto-promotes the first account
  it ever sees to the internal Administrators group, which is how the
  human account `carol` originally got admin rights during bootstrap —
  but that's bootstrap trivia, not the ongoing mechanism: anyone added
  to `admins`, human or service account, gets the same rights the same
  way.) Concretely: pull any account out of the `admins` LDAP group and
  its LDAP password still authenticates fine, but every `ggadmin-*`
  operation using it as `GERRIT_ADMIN_PW` starts failing with a
  permission error, not a login error.

- Gitea *instance* admin (what `GITEA_ADMIN_PW` grants) has **no
  connection to LDAP or group membership at all, by design** —
  `scripts/install/06-gitea-ldap.sh` says so explicitly: the LDAP-to-team
  mapping intentionally does not grant Gitea instance admin, to keep
  that blast radius local-only. Emptying or deleting the `admins` LDAP
  group would not touch `gitea-admin` in any way. Separately (and easy
  to conflate if you don't know this), any `admins`-group LDAP account
  *also* gets Gitea **org** Owner in `engineering` through that same
  group — full admin over that org's repos — but that's that account's
  own LDAP password granting an org-scoped role, a different credential
  and a different scope than `GITEA_ADMIN_PW`, and it only re-syncs at
  that account's next Gitea login (WORKFLOW.md section 1), unlike
  Gerrit's live lookup.

### What `ldap-reader` is, and why it exists

Not one of the three credentials above — it's never passed as an
argument to a `ggadmin-*` command — but it's referenced often enough
elsewhere (`ldap-least-privilege.sh`, `set-service-credentials.sh`,
the Status checklists in SYSADMIN.md) without ever being explained on
its own, so here it is.

Gerrit and Gitea don't just *authenticate* against LDAP — checking a
password on login — they also *search* it, on every login and
permission check: resolving a username to its full DN, then looking
up which groups that DN belongs to (that's the mechanism behind
`admins`/`developers` group membership turning into Gerrit
capabilities and Gitea team membership). That search needs its own
LDAP bind, separate from the person logging in. `scripts/install/04-gerrit.sh`
and `scripts/install/06-gitea-ldap.sh` both set that bind to `cn=admin`
at bootstrap — a deliberate shortcut for getting the lab running
quickly, but a real problem left as-is: `cn=admin` is the directory's
full read *and write* superuser, so Gerrit's and Gitea's own stored
LDAP passwords (`secure.config`, Gitea's LDAP auth source) each become
a path to compromising the entire directory, not just to running
read-only searches.

`cn=ldap-reader,ou=services,...` is the fix. `scripts/post-install/ldap-least-privilege.sh`
creates it as a dedicated `organizationalRole` account — not a person,
doesn't live under `ou=people`, can't log into Gerrit or Gitea as a
user — with *only* read access to `ou=people`/`ou=groups` and nothing
else (no write access anywhere, no access to any other part of the
tree), then repoints both Gerrit's and Gitea's LDAP search bind at it,
atomically, in place of `cn=admin`. From then on, a compromised
Gerrit/Gitea LDAP credential can browse names, emails, and group
membership — nothing it couldn't already show a logged-in user anyway
— but can't write to the directory or read `userPassword` (that
attribute is protected against `ldap-reader`'s own bind, not just
anonymous, at the ACL level).

Rotate its password with `scripts/post-install/set-service-credentials.sh ldap-reader`
(or `all`), same as any other special account — but it only *exists*
once `ldap-least-privilege.sh` has run; before that, there's nothing
to rotate, and Gerrit/Gitea are still bound as `cn=admin`.

### Setting up the Gerrit service account

`GERRIT_ADMIN_USER` used to default to `carol` — a real person's LDAP
login reused as the automation credential. That's fragile: it breaks
the moment she changes her own password for unrelated reasons, or
leaves, and "who is currently `GERRIT_ADMIN_USER`" wasn't recorded
anywhere but tribal knowledge. `gerrit-bot` is a dedicated, non-human
LDAP account that exists only to be `GERRIT_ADMIN_USER`; both scripts
now default to it.

It has to live under `ou=people` like a real person, not `ou=services`
like the `ldap-reader` bind account (see "Required credentials, per
command" above) — Gerrit's `ldap.accountPattern`
(`scripts/install/04-gerrit.sh`) only recognizes `inetOrgPerson` entries under
`ou=people` as valid accounts, so an `ou=services` entry would never be
able to log in as a Gerrit account at all. Given that, the existing
`ggadmin-user add` command already does everything needed:

```
sudo LDAP_ADMIN_PW='...' ggadmin-user add gerrit-bot "Gerrit Service Account" gerrit-bot@tkos.co.il admins
```

A fresh install now runs this for you —
`scripts/install/14-gerrit-service-account.sh` wraps the exact command
above (idempotent: skips creation and just checks group membership if
`gerrit-bot` already exists), plus the `administrateServer` check
below, so `scripts/post-install/final-remove-test-users.sh` doesn't hit
"uid=carol is the last member of 'admins'" later. Run it by hand only
if you're re-creating `gerrit-bot` after it was deleted, or catching up
a host that skipped it.

This creates the LDAP entry, adds it to `admins` (the same group carol
is in — see the trade-off note below), and prints a freshly generated
password once; capture it. Verify it actually has Gerrit admin rights
before relying on it:

```
curl -fsS -u gerrit-bot:'<the printed password>' http://127.0.0.1:8080/a/accounts/self/capabilities \
  | tail -n +2 | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("administrateServer") else 1)' \
  && echo "gerrit-bot has administrateServer"
```

**Do not also pre-provision it in Gitea** (skip the `curl -u gerrit-bot:...
.../api/v1/user` step section 1's "Add a user" otherwise suggests) —
being in `admins` means it *would* become a Gitea org Owner
the moment it ever authenticates there, which is unnecessary scope for
an account that only ever talks to Gerrit's REST API. Leaving it
unprovisioned in Gitea keeps that grant dormant.

From here on, point the day-2 scripts at it (or rely on the new
default):

```
sudo GERRIT_ADMIN_USER=gerrit-bot GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  ggadmin-project add my-new-project "some description"
```

This doesn't touch carol's own admin status by itself — she keeps it
until you separately remove her, which "Removing the lab test users"
below now recommends doing before Day-2 (she was only ever a bootstrap
test account, not a real admin). Setting up `gerrit-bot` has no
dependency on carol staying around either way: rotate `gerrit-bot`'s
password the same way as any other user: `ggadmin-user set-password
gerrit-bot`. Retire it the same way too, if it's ever compromised or
no longer needed: `ggadmin-user offboard gerrit-bot`.

*Why not a narrower LDAP group instead of reusing `admins`?* That was
considered — a dedicated `cn=gerrit-admins` group wired into Gerrit's
ACL only, so the bot never picks up the Gitea Owner side-effect at all.
Rejected for now as more machinery than this lab needs (a live
`All-Projects` ACL edit, another group to maintain) given the
side-effect is dormant unless someone deliberately provisions the bot
in Gitea too; revisit if that stops being true.

### Why isn't this in Gerrit's or Gitea's own UI?

Worth asking, since it's a fair question the first time you reach for a
script instead of a button: neither tool is missing a UI by accident,
and the reasons split into two genuinely different categories.

**User creation is deliberately absent, not overlooked.** Both Gerrit
and Gitea are pure LDAP-auth *consumers* here (section 1 below,
WORKFLOW.md section 1) — an account doesn't exist locally until first
login. Neither ships a "create a user in the directory" screen because
that would mean managing a different system's data model from inside
an unrelated app — the same reason Gmail's admin console doesn't let
you edit your on-prem Active Directory. That's the correct boundary,
not a gap. What genuinely *is* missing is a single admin surface that
spans all three systems (LDAP + Gerrit + Gitea) together, but no
individual tool's UI could ever provide that without reaching into
services it doesn't own — it's structural, not a product oversight.
Notably, *deactivation* already has a UI in both products (Gerrit's
Admin > Users, Gitea's Site Administration both have an Active/Inactive
toggle) — `ggadmin-user offboard` isn't adding a capability neither
tool has, it's doing the LDAP-group removal and both toggles together
in the right order instead of three manual steps in three different
places, and adding the Gerrit `is:inactive` readback confirmation
neither tool's UI does for you.

**Project lifecycle gaps are real product gaps, for different reasons
per tool.** Gerrit's `delete-project` isn't in the default build's UI
at all, and that's deliberate conservatism, not an omission: Gerrit
treats a project's review history as closer to a permanent record than
a typical Git host does, so destroying it is gated behind an opt-in
plugin (`scripts/install/10-delete-project-plugin.sh`) rather than a one-click
admin button — the friction is the point. Gitea, on the other hand,
simply has no concept of an org-wide default applied to repos that
don't exist yet. Branch protection *is* a real, fully-functional UI
feature — you can set the exact rule `ggadmin-project add` applies by
hand, per repo, in Settings > Branches — but there's no template a
newly created repo inherits automatically, and push-to-create doesn't
fully respect the instance's default-units configuration either
(confirmed live, section 2 below). Gitea's admin UI is built around
configuring one repo at a time in one session; it has no answer to
"apply this policy to every repo, including future ones."

The unifying reason underneath both categories: what these scripts
actually add isn't capability either product is missing in general —
it's enforcement of a policy specific to *this* deployment (Gerrit-only
contribution, no competing Gitea PRs, replication-only write access,
LDAP as the single identity source). No vendor UI can bake in a policy
that only exists because of how *you've* composed two separate
products together. Any team wiring up a comparably opinionated
multi-tool setup ends up needing a scripting layer for exactly this
reason, regardless of which specific tools they picked.

## 1. User lifecycle

Accounts are never created directly in Gerrit or Gitea — both are pure
LDAP-auth consumers (WORKFLOW.md section 1). All identity changes happen in
LDAP; Gerrit and Gitea pick them up, but **not on the same schedule**.

### Add a user

**uid convention:** use the person's regular org username as the LDAP `uid`
(e.g. `dave`) — Gerrit and Gitea are pure LDAP-auth consumers, so this
becomes their login name in both systems too, one identity everywhere. Pick
something stable, not a display name: `uid` is the RDN of the LDAP entry's
DN (`uid=dave,ou=people,...`), so renaming it later isn't a field edit —
it's deleting and recreating the entry (or an `ldapmodify moddn`), plus
updating every group `member:` reference that points at the old DN.

Script: `ggadmin-user add dave "Dave Developer" dave@tkos.co.il developers`
(generates the password, prints it once). Manually:

```
ldapadd -x -D "cn=admin,dc=tkos,dc=co,dc=il" -w 'ChangeMe123!' -H ldap://localhost <<EOF
dn: uid=dave,ou=people,dc=tkos,dc=co,dc=il
objectClass: inetOrgPerson
uid: dave
cn: Dave Developer
sn: Developer
mail: dave@tkos.co.il
userPassword: $(/usr/sbin/slappasswd -s 'their-password')
EOF

ldapmodify -x -D "cn=admin,dc=tkos,dc=co,dc=il" -w 'ChangeMe123!' -H ldap://localhost <<EOF
dn: cn=developers,ou=groups,dc=tkos,dc=co,dc=il
changetype: modify
add: member
member: uid=dave,ou=people,dc=tkos,dc=co,dc=il
EOF
```

That's it — no Gerrit or Gitea step needed. Both auto-provision the account
on the user's first authenticated request (their first login, or the first
`git push`/API call using their LDAP credentials). If you want the account
to exist before their first real login (e.g. to pre-add them somewhere),
force provisioning yourself: `curl -u dave:their-password
http://.../a/accounts/self` (Gerrit) and `curl -u dave:their-password
http://.../api/v1/user` (Gitea).

### Change a user (role, email, name, group membership)

Scripts: `ggadmin-user add-group|remove-group <uid> <group>`
(skip-if-already-applied), `set-password <uid>`, `groups <uid>` to list
current membership. Manually: edit the LDAP entry or group membership
the same way (`ldapmodify`). What
happens next **differs by system** — this asymmetry cost real debugging
time to find, so it's worth internalizing:

- **Gerrit reflects the change on the very next request.** It queries LDAP
  live for group membership on every permission check — moving someone
  into `cn=admins` grants Gerrit admin rights immediately, no re-login, no
  restart.
- **Gitea only resyncs team membership at login time** (or via the
  periodic `sync_external_users` cron task, enabled by
  `--synchronize-users` in `scripts/install/06-gitea-ldap.sh`, default roughly
  daily). A user moved between LDAP groups keeps their *old* Gitea team
  membership until they log in again. To force it immediately rather than
  waiting: have them log in, or trigger one authenticated request as them
  yourself (`curl -u dave:their-password http://.../api/v1/user`) —
  confirmed to immediately move them between teams (e.g. `Developers` →
  `Owners`) in our testing.

### Remove / offboard a user

Script: `ggadmin-user offboard dave` (add `--delete-entry`
to also remove the LDAP entry, not just pull group membership) — does
both steps below in order, including the Gerrit `is:inactive` readback
confirmation from step 2. `reactivate dave` undoes the explicit
deactivation (does not restore LDAP group membership).

Two mechanisms, and they're not equivalent — for real offboarding, do
**both**:

1. **Remove them from LDAP** (delete the entry, or at minimum pull them out
   of every group). This blocks login immediately (`401`) on both Gerrit
   and Gitea. But it's silent: **the local account record in each system
   is untouched** — still shown as active, full name/email/history intact,
   just permanently unable to authenticate. Confirmed: a Gitea account
   still reports `"active": true` after its LDAP entry is gone.
2. **Explicitly deactivate the account in each system**, which is visible
   and auditable in each tool's own admin UI, rather than a silent
   LDAP-side-only change:
   ```
   # Gerrit
   curl -u gerrit-bot:'<GERRIT_ADMIN_PW>' -X DELETE \
     http://127.0.0.1:8080/a/accounts/<account-id>/active

   # Gitea
   curl -u gitea-admin:ChangeMe123! -X PATCH \
     -H 'Content-Type: application/json' \
     -d '{"login_name":"dave","source_id":0,"active": false}' \
     http://127.0.0.1:3000/api/v1/admin/users/dave
   ```
   (Gerrit's own `GET .../active` status-code semantics were inconsistent
   in our testing — confirm deactivation via a search instead:
   `GET /a/accounts/?q=is:inactive`.)

Either way, **nothing is deleted** — authored commits, past code reviews,
and issue comments all survive. That's deliberate: revoking access should
never rewrite history.

### Removing the lab test users (alice/bob/carol)

Script: `scripts/post-install/final-remove-test-users.sh` — the name
says when: last, after everything else you're going to run in
`scripts/post-install/` and `scripts/install/` (see SYSADMIN.md's "Run
the scripts as root"). Does everything below in order (offboards all
three with `--delete-entry`, then deletes `cn=developers` only if it's
actually empty afterward). Needs `LDAP_ADMIN_PW`, `GERRIT_ADMIN_PW`,
and `GITEA_ADMIN_PW`, same as `ggadmin-user offboard` itself:

```
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  bash scripts/post-install/final-remove-test-users.sh
```

Run this LAST: `scripts/install/12-gerrit-postgresql.sh`,
`13-gitea-postgresql.sh`, and (if you're also running it)
`scripts/post-install/ldap-least-privilege.sh` all authenticate as
`alice`/`carol` as part of their own verification, so all of them need
to run *before* this script, not after — see SYSADMIN.md's "Which ones
to run, and in what order" for why.

The rest of this section is what that script actually runs, and why —
read on if you want the manual version or the reasoning, otherwise the
command above is all you need.

`alice`/`bob`/`carol` (`scripts/install/02-openldap.sh`) exist purely to
exercise LDAP groups, Gerrit ACL bootstrap, Gitea team sync, and the
PostgreSQL migration (`scripts/install/02` through `13`), plus
`scripts/post-install/ldap-least-privilege.sh`, while all of those were
being written and verified — they aren't real people and shouldn't
still be sitting in the directory once
this install moves into Day-2. Removing them is just the `offboard
--delete-entry` procedure above, run against all three, but with one
real wrinkle worth knowing before you start:

**`alice` and `bob` are the *only* members of `cn=developers`.**
`groupOfNames` requires at least one `member`, so `offboard` refuses to
remove the second of the two (`die`s with "is the last member of
'developers'") rather than leave the group empty — LDAP would reject it
anyway (`objectClass violation`). Deleting both test users therefore
means deleting the `developers` group entry too, not just the users.
(`admins` doesn't have this problem as long as `gerrit-bot` already
exists and is in it — see "Setting up the Gerrit service account"
above; do that first if you haven't. `gerrit-bot` staying in `admins`
is what makes it safe to remove `carol`, its other member.)

Prerequisite: `gerrit-bot` is set up and confirmed to have
`administrateServer` (see above). Then, in any order:

```
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  ggadmin-user offboard carol --delete-entry
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  ggadmin-user offboard alice --delete-entry
sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' \
  ggadmin-user offboard bob --delete-entry
```

Then delete the now-empty `developers` group directly (no `ggadmin-*`
subcommand manages groups themselves, only membership):

```
ldapmodify -x -D "cn=admin,dc=tkos,dc=co,dc=il" -w '<LDAP_ADMIN_PW>' -H ldap://localhost <<EOF
dn: cn=developers,ou=groups,dc=tkos,dc=co,dc=il
changetype: delete
EOF
```

`ggadmin-user add` defaults new users to the `developers` group when
none is given, and refuses to add anyone to a group that doesn't exist
— so onboarding the first real developer after this needs the group
recreated first, with that person as its initial member (`groupOfNames`
needs a member at creation time too, so this can't be a bare empty
group waiting for one):

```
ldapmodify -x -D "cn=admin,dc=tkos,dc=co,dc=il" -w '<LDAP_ADMIN_PW>' -H ldap://localhost <<EOF
dn: cn=developers,ou=groups,dc=tkos,dc=co,dc=il
changetype: add
objectClass: groupOfNames
cn: developers
member: uid=<first-real-developer>,ou=people,dc=tkos,dc=co,dc=il
EOF
```

After that, `ggadmin-user add <uid> <full name> <email>` (no explicit
group) works again as documented above.

As with any offboard, nothing in Gerrit/Gitea's own history is
touched — commits `scripts/install/05`/`07`/`09` and
`scripts/install/12-gerrit-postgresql.sh` authored as `carol` during
bootstrap keep her name/email in their history forever, same as any
other offboarded user's past work. And as SYSADMIN.md's "Which ones to
run, and in what order" notes: once these three are gone, several
other scripts stop working too, since they authenticate as `carol` —
`scripts/install/04`-`07`/`09`/`10` hardcode her original
`ChangeMe123!` password, while `scripts/install/12-gerrit-postgresql.sh`,
`13-gitea-postgresql.sh`, and `scripts/post-install/ldap-least-privilege.sh`
take `CAROL_PW` as a parameter instead but still need her account to
exist at all. Expected either way — their job is already done, none of
them are meant to be rerun against this already-bootstrapped host.

## 2. Project lifecycle

### Quick checklist: setting up a new project

1. `ggadmin-project add <name> ["description"]` — the only required step.
   It creates the Gerrit project, waits for the Gitea mirror to appear,
   and applies both required Gitea follow-ups (disables the Pull
   Requests unit; adds the branch-protection rule blocking Owner/admin
   force-push). See "Add a project" below for what each of those does
   and why.
2. **No Gerrit or Gitea UI steps are required** for a standard project.
   Access control is inherited automatically: Gerrit ACLs come from
   `All-Projects` (`scripts/install/05-gerrit-acl.sh`), and Gitea's
   `Developers`/`Owners`/`Replication` teams are org-wide
   (`includes_all_repositories`, `scripts/install/06-gitea-ldap.sh`/
   `scripts/install/07-replication.sh`), so both already apply to the new repo
   with no per-project setup.
3. Optional, UI-only, and only if your team actually wants them — none
   of this blocks developers from pushing to Gerrit:
   - Gitea → repo → **Projects**: create a Kanban board for planning
     (WORKFLOW.md sections 3-4). No REST API for this in this Gitea
     version, so it can't be scripted.
   - Gitea → repo → **Wiki**: seed initial docs — it's a normal
     writable repo, not mirrored from Gerrit.
   - Gitea → repo → **Issues → Labels**: add labels if you use them.
4. Only if this specific project needs access different from the
   org-wide default (rare):
   - Gerrit side: project's **Access** tab in the Gerrit UI, or edit
     `refs/meta/config` directly (`scripts/install/05-gerrit-acl.sh` is a
     scripted example of the latter).
   - Gitea side: repo → **Settings → Collaborators**, or add the repo
     to another team explicitly.

### Add a project

Script: `ggadmin-project add my-new-project "description"`
— creates the Gerrit project, waits for the Gitea mirror to replicate,
and applies both required follow-up steps below. Safe to rerun to
apply the follow-ups to a project created before this script existed.
Manually: create it in Gerrit (the source of truth) — Gitea's copy
takes care of itself:

```
curl -u carol:ChangeMe123! -X PUT -H 'Content-Type: application/json' \
  -d '{"description": "...", "create_empty_commit": true, "branches": ["main"]}' \
  http://127.0.0.1:8080/a/projects/my-new-project
```

Project creation is itself a ref-update event, so the replication plugin
picks it up automatically — confirmed the mirror appears in Gitea's
`engineering` org within a few seconds, **with no manual push required**.
It lands **private by default** (Gitea's default for API/push-created
repos); the `Developers`/`Owners`/`Replication` teams already apply to it
automatically (they're org-wide via `includes_all_repositories`, set up in
`scripts/install/06-gitea-ldap.sh`/`scripts/install/07-replication.sh`), but nobody outside
those teams can see it until/unless you change that.

**One required follow-up step**, until this is automated: push-to-create
leaves the new repo's Pull Requests unit *enabled*, which WORKFLOW.md
section 1 explicitly says should be off (contributions go through Gerrit,
not Gitea PRs — a competing contribution path is exactly what this is
meant to prevent). Team-level permissions alone don't cover this since
they only restrict who can *use* a unit, not whether the unit exists on
the repo at all — confirmed live: `engineering/replication-test` showed
`"has_pull_requests": true` right after being auto-created despite no
team having `repo.pulls` in its `units_map`. Disable it explicitly on
every new project:

```
curl -u gitea-admin:ChangeMe123! -X PATCH -H 'Content-Type: application/json' \
  -d '{"has_pull_requests": false}' \
  http://127.0.0.1:3000/api/v1/repos/engineering/my-new-project
```

**A second required follow-up step**, also until automated: team
permissions alone do **not** make Code actually read-only for every human.
Gitea org Owners always have full admin on every org repo — that's
inherent to being an Owner, not something `units_map` can strip — so the
`admins` LDAP group (mapped to Owners in `scripts/install/06-gitea-ldap.sh`)
retains real Code write access by default. Confirmed live: an Owner-team
account force-pushed directly to a mirrored repo's `main`, completely
bypassing Gerrit review, with no error. WORKFLOW.md section 2's original
design assumed the dedicated service account made a branch-protection
rule unnecessary ("rather than a branch-protection rule bolted on
afterward") — that assumption didn't hold once actually tested. Add a
branch protection rule on every new project restricting push (including
force-push) to the `Replication` team only, with admin bypass explicitly
blocked:

```
curl -u gitea-admin:ChangeMe123! -X POST -H 'Content-Type: application/json' \
  -d '{
    "rule_name": "**",
    "enable_push": true,
    "enable_push_whitelist": true,
    "push_whitelist_teams": ["Replication"],
    "enable_force_push": true,
    "enable_force_push_allowlist": true,
    "force_push_allowlist_teams": ["Replication"],
    "block_admin_merge_override": true
  }' \
  http://127.0.0.1:3000/api/v1/repos/engineering/my-new-project/branch_protections
```

Confirmed this actually blocks an Owner-team account (including force-push,
with the real error `Not allowed to push to protected branch`) while
leaving the `Replication` team's own force-push (what real replication
does) working normally.

### Change a project

Script: `ggadmin-project describe my-new-project "new description" [--gitea-too]`.
Project-level settings (description, ACLs,
labels) live in Gerrit's
`project.config`, on the special `refs/meta/config` ref — editable via
`PUT /a/projects/{name}/description`, the permissions REST endpoints, or by
cloning/editing/pushing `refs/meta/config` directly (see
`scripts/install/05-gerrit-acl.sh` for a scripted example of the latter).

**This metadata does not replicate to Gitea.** Replication only ever
carries `refs/heads/*` and `refs/tags/*` (WORKFLOW.md section 2, by
design — it's what makes "mirror only on merge" work). Confirmed: changing
a Gerrit project's description left Gitea's copy of that repo's
description untouched. If you want Gitea's description/topics to match,
set them there too, separately.

### Delete a project

Script: `ggadmin-project delete my-new-project` — does
both steps below, in order, and skips a side that's already gone.
Gerrit doesn't support this without the `delete-project` plugin (bundled in
`gerrit.war` but not installed by `scripts/install/04-gerrit.sh` — enable it once
via `scripts/install/10-delete-project-plugin.sh`). Then:

```
# 1. Gerrit first -- it's the source of truth; if this fails, nothing
#    downstream has been touched yet.
curl -u carol:ChangeMe123! -X POST -H 'Content-Type: application/json' \
  -d '{"force": true, "preserve": false}' \
  http://127.0.0.1:8080/a/projects/my-new-project/delete-project~delete

# 2. Gitea's mirror is NOT deleted automatically -- confirmed it survives,
#    orphaned, after the Gerrit-side delete. Remove it explicitly:
curl -u gitea-admin:ChangeMe123! -X DELETE \
  http://127.0.0.1:3000/api/v1/repos/engineering/my-new-project
```

Do both, in that order, every time — an orphaned Gitea mirror of a
Gerrit project that no longer exists is a real trap (it'll look like a
live repo with no way to push new changes to it via the normal flow).

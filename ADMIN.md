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
`scripts/18-user-lifecycle.sh` (section 1) and
`scripts/19-project-lifecycle.sh` (section 2), run as root on the
Gerrit/Gitea host the same way as `scripts/01-17`. They encode every
gotcha this file documents (the Gerrit/Gitea sync asymmetry, the two
required Gitea follow-ups on project creation, the Gerrit
`is:inactive`-readback quirk, ...) instead of leaving it to a human to
remember on every one-off `curl`. The commands below are still shown
in full since they're what the scripts actually run, and the prose
around them (why each step exists, what surprised us) is the part a
script can't carry — but for real operations, prefer the script.

Run `sudo bash scripts/20-install-ggadmin-tools.sh` once to symlink
them onto PATH under short names — `ggadmin-user` and
`ggadmin-project` — so `sudo ggadmin-user offboard dave` works from
anywhere without a `scripts/` path. That's what the rest of this file
calls them as; before installing, substitute the full
`scripts/18-user-lifecycle.sh` / `scripts/19-project-lifecycle.sh`
path instead.

## 1. User lifecycle

Accounts are never created directly in Gerrit or Gitea — both are pure
LDAP-auth consumers (WORKFLOW.md section 1). All identity changes happen in
LDAP; Gerrit and Gitea pick them up, but **not on the same schedule**.

### Add a user

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
  `--synchronize-users` in `scripts/06-gitea-ldap.sh`, default roughly
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
   curl -u carol:ChangeMe123! -X DELETE \
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

## 2. Project lifecycle

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
`scripts/06-gitea-ldap.sh`/`scripts/07-replication.sh`), but nobody outside
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
`admins` LDAP group (mapped to Owners in `scripts/06-gitea-ldap.sh`)
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
`scripts/05-gerrit-acl.sh` for a scripted example of the latter).

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
`gerrit.war` but not installed by `scripts/04-gerrit.sh` — enable it once
via `scripts/10-delete-project-plugin.sh`). Then:

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

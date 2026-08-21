# HOWTO

Quick one-liners for common tasks — an FAQ, not a replacement for
[README.md](README.md)'s full doc map. Each entry links to the fuller
explanation (the "why", the gotchas, the full option list) rather than
repeating it here; if a one-liner doesn't cover your case, follow the link.

All `ggadmin-*` commands below assume `scripts/day2/install-ggadmin-tools.sh`
has been run (see ADMIN.md's intro) — substitute the full
`scripts/day2/*-lifecycle.sh` path otherwise. Every credential placeholder
(`'...'`) is a *current* password, not a fixed default — see ADMIN.md's
"What these credentials are, and how they're set" if you don't have one
handy. Examples use this lab's values (`engineering` org, host substituted
as `<host>`) — see ADMIN.md/INSTALL.md's intros for why.

## Users

- **Add a new user** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user add dave "Dave Developer" dave@tkos.co.il developers`
  See ADMIN.md's "Add a user".

- **Make a user a Gerrit admin** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user add-group dave admins`
  Takes effect immediately, no re-login. Also makes them a Gitea org
  Owner the moment they ever log into Gitea — the same LDAP group drives
  both, deliberately, not a bug. See ADMIN.md's "Change a user" and
  "Setting up the Gerrit service account".

- **Remove a user from the admins group (without fully offboarding them)** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user remove-group dave admins`
  See ADMIN.md's "Change a user".

- **See what groups a user is in** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user groups dave`

- **Add/remove a user from any group** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user add-group|remove-group dave <group>`
  See ADMIN.md's "Change a user" for the Gerrit-vs-Gitea sync-timing
  asymmetry this causes.

- **Change a user's password** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-user set-password dave`

- **Remove / offboard a user** —
  `sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-user offboard dave`
  Add `--delete-entry` to also remove the LDAP entry, not just deactivate.
  See ADMIN.md's "Remove / offboard a user" for what each of the two
  mechanisms actually does.

- **Reactivate an offboarded user** —
  `sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-user reactivate dave`
  Undoes the explicit deactivation only — does not restore LDAP group
  membership pulled during offboarding.

- **Create a new LDAP group** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-group create <group> <initial-member-uid>`
  A group needs at least one member even at creation
  (`groupOfNames` can't be empty). See ADMIN.md's intro paragraph on
  `ggadmin-group`, just above "Required credentials, per command".

- **Delete an LDAP group** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-group delete <group>`

- **List a group's members** —
  `sudo LDAP_ADMIN_PW='...' ggadmin-group members <group>`

## Projects / repos

- **Create a new project (the only way to get a repo Gerrit tracks)** —
  `sudo GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-project add my-new-project "description"`
  Creates the Gerrit project, waits for the Gitea mirror, applies the
  two required Gitea follow-ups, and prints the clone/push URL. See
  ADMIN.md's "Add a project".

- **Find a project's clone/push URL later** —
  Gerrit web UI: Browse → Repos → the project → "Clone" panel. Or rerun
  `ggadmin-project add` on the existing project (safe — just reprints
  it). See ADMIN.md's "Finding the clone/push URL later" note in
  "Add a project".

- **Push a change for review** —
  `git push <remote> HEAD:refs/for/main` — never straight to `main`.
  Remote URL is `http://<uid>@<host>:8090/a/<project>` (HTTP) or
  `ssh://<uid>@<host>:29418/<project>` (SSH). See WORKFLOW.md section 4.

- **Review and submit a pushed change** —
  ```
  curl -u <uid>:<pw> -X POST -H 'Content-Type: application/json' \
    -d '{"labels":{"Code-Review":2}}' \
    "http://<host>:8090/a/changes/<change-number>/revisions/current/review"
  curl -u <uid>:<pw> -X POST "http://<host>:8090/a/changes/<change-number>/submit"
  ```
  Needs Code-Review `+2` rights — `scripts/install/05-gerrit-acl.sh`
  explicitly grants the `admins` LDAP group `-2..+2` and `submit`; a
  plain `developers`-group account gets whatever Gerrit's own
  `All-Projects` default template grants (narrower than that, not
  independently re-verified against this instance — check with your own
  account if in doubt). See WORKFLOW.md section 4.

- **Link a Gerrit change to a Gitea issue** —
  Add a `Fixes org/repo#123` trailer to the commit message. Auto-closes
  the issue on submit (does **not** move its kanban card). See
  WORKFLOW.md section 3.

- **Change a project's description** —
  `sudo GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-project describe my-project "new description" [--gitea-too]`
  Gerrit and Gitea descriptions don't sync — `--gitea-too` updates both.
  See ADMIN.md's "Change a project".

- **Delete a project (Gerrit-tracked)** —
  `sudo GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-project delete my-project`
  Needs `scripts/install/10-delete-project-plugin.sh` already run once.
  See ADMIN.md's "Delete a project".

- **Delete a repo that was created directly in Gitea** (not via
  `ggadmin-project`) —
  Gitea web UI: repo → Settings → Danger Zone → Delete This Repository.
  Or: `curl -u gitea-admin:'...' -X DELETE "http://<host>:8091/api/v1/repos/<org>/<repo>"`.
  Pure Gitea-side operation — there's nothing to clean up in Gerrit,
  since Gerrit never knew the repo existed.

- **Organize/group repos in Gerrit's UI** —
  Not supported — Gerrit's repo list is always flat, no folders/orgs. A
  hyphen naming convention (`team-a-service-1`) is filterable in the UI
  search box and safe; a `/`-nested name (`team-a/service-1`) is *not*
  safe here — Gerrit supports it natively, but it breaks Gerrit → Gitea
  replication for that project (Gitea has no nested repo paths, and
  `remote.gitea.url` in `replication.config` passes the project name
  straight through — `scripts/install/07-replication.sh`). Not written
  up elsewhere in the docs; this is the reference for it.

- **Replicate a project into a Gitea org other than `engineering`** —
  Not supported — every project mirrors into the single hardcoded org
  `engineering`, in both directions. `GITEA_ORG` on `ggadmin-project`
  does not redirect this (it now fails fast if you try). See WORKFLOW.md
  section 2 and INSTALL.md gotcha 17.

## Credentials

- **Check whether my admin credentials are still correct** —
  `sudo LDAP_ADMIN_PW='...' GERRIT_ADMIN_PW='...' GITEA_ADMIN_PW='...' ggadmin-verify-creds`
  Any left unset are skipped, not failed — fine to check just one.

- **Rotate a service account's password** —
  `sudo bash scripts/post-install/set-service-credentials.sh <ldap-admin|gitea-admin|all>`
  Prints the new password once — nowhere else to retrieve it after.

- **Figure out which password `GERRIT_ADMIN_PW`/`GITEA_ADMIN_PW`/
  `LDAP_ADMIN_PW` actually means** —
  See ADMIN.md's "What these credentials are, and how they're set" —
  they're three genuinely different kinds of account, not interchangeable.

## Customer branch delivery

- **Start a new delivery cycle from a customer's repo** —
  `customer-sync.sh start-cycle <name>` (run from a working clone with
  `gerrit` and `customer-<name>` remotes already set up). See WORKFLOW.md
  section 5.

- **Deliver (export) a cycle back to the customer** —
  `customer-sync.sh deliver <name> [cycle-branch]`
  Squash-exports as one commit built from subjects only — no Change-Id
  or other Gerrit trailer ever reaches the customer repo. See
  WORKFLOW.md section 5.

## Troubleshooting

- **Gerrit login suddenly fails: "Authentication unavailable at this
  time"** — almost always means Gerrit's LDAP bind identity got
  reverted to the bootstrap `cn=admin` credentials by an unguarded
  rerun of an older `04-gerrit.sh` (guarded against as of the version
  currently in this repo — see that script's own `--- 4. LDAP bind
  identity ---` comment block for the full mechanism). Fix: rerun
  `scripts/post-install/ldap-least-privilege.sh` with the *current*
  `cn=admin` and `gerrit-bot` passwords — it's safe to rerun and mints a
  fresh bind password unconditionally.

- **Gerrit repo page shows no "Clone" panel** — needs both
  `download.scheme = http`+`ssh` in `gerrit.config` *and* the
  `download-commands` plugin actually installed (`--install-plugin
  download-commands` on `gerrit init`) — a bundled-but-not-active core
  plugin, easy to miss, no warning logged either way. Both are handled
  by the current `scripts/install/04-gerrit.sh`; rerun it (safe) plus
  `systemctl restart gerrit` if you're still on an older copy.

- **A `GITEA_ORG` override on `ggadmin-project` dies with "Gitea repo
  never appeared"** — expected; see "Replicate a project into a Gitea
  org other than `engineering`" above.

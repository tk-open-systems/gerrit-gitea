# Gerrit + Gitea Workflow

Gerrit is the code-review and source-of-truth system. Gitea hosts project
planning, wiki, kanban, and bug tracking, plus a read-only mirror of each
repo. This document describes how the two systems fit together.

Assumptions:

- A shared LDAP/OIDC directory is available to both Gerrit and Gitea.
- Repos are mirrored from Gerrit to Gitea only on merge (not per patchset).
- No CI/CD is wired into this workflow yet.

## 1. Identity & access control

Authentication is unified via the shared directory; authorization stays
split between the two tools, but with very different scope in each.

- **Gerrit** is the only place code-level ACLs matter: who can push,
  submit, and vote Code-Review/Verified. Bind Gerrit to LDAP groups
  directly and inherit access rights from `All-Projects` so each role is
  defined once rather than per repo.
- **Gitea** never needs code-write ACLs, since the repo is read-only
  there. Use Gitea's **per-unit permissions** (Code / Issues / Wiki /
  Projects / Pull Requests are separate units per repo):
  - Disable the Pull Requests unit entirely — contributions go through
    Gerrit, not Gitea PRs. This is a per-repo toggle, not something team
    permissions alone achieve: excluding `repo.pulls` from a team's
    `units_map` only restricts who can *use* the unit, not whether it
    exists on the repo — a repo created without this explicit step still
    shows Pull Requests enabled regardless of team permissions. See
    ADMIN.md's "Add a project" for the exact step.
  - Set the Code unit to read-only for everyone.
  - Give the working team Write on Issues/Wiki/Projects only.

  This keeps Gitea's ACL surface limited to "who can plan/discuss,"
  which is coarser than Gerrit's ACLs and easier to keep in sync.

- To avoid manually recreating group membership in both tools, enable
  Gitea's **LDAP group-to-team mapping** (Admin → Authentication Source →
  Group mapping) so the same LDAP groups driving Gerrit ACLs also
  populate Gitea org teams automatically. Two permission *schemas* still
  have to be defined (Gerrit's label/ref-based model vs. Gitea's
  unit-based model), since the tools model permissions differently — but
  membership sync becomes automatic instead of a manual duplication
  chore.

  This sync isn't on the same clock in both tools, though: Gerrit
  evaluates LDAP group membership live on every request, so a group
  change takes effect immediately with no re-login needed. Gitea only
  resyncs a user's team membership at their next login (or via the
  periodic sync task) — someone moved into a new LDAP group keeps their
  old Gitea team membership until they authenticate again. See ADMIN.md's
  "Change a user" for how to force it.

## 2. Repo mirroring (Gerrit → Gitea, merge-only)

**Single fixed Gitea org, hardcoded, in both directions — no multi-org
support exists.** Every Gerrit-created project replicates into the one
Gitea org named `engineering` (`scripts/install/07-replication.sh`'s
`remote.gitea.url`, and the `Developers`/`Owners`/`Replication` team
setup in `scripts/install/06-gitea-ldap.sh`, both hardcode it — there is
no config knob that redirects this). And separately, a repo created any
other way — including a repo created directly in Gitea's `engineering`
org itself, not just some other org — **never appears in Gerrit at all**,
regardless of org: mirroring only ever runs Gerrit → Gitea, one-way (see
below); nothing pulls or imports the other direction. So any Gitea org
other than `engineering` (nothing stops someone creating one — Gitea's
org self-service creation is not disabled anywhere in this setup) is
completely outside this system in both directions at once: nothing
placed there can ever reach Gerrit, Gerrit can never be made to replicate
into it, and it gets none of `engineering`'s governance either (its
Pull-Requests-unit-disable and branch-protection safeguards are applied
per-project by `ggadmin-project`, which itself can only ever target
`engineering` — see ADMIN.md's "Add a project"). Treat it as a fully
unmanaged, ungoverned space if it appears — not a smaller/alternate
version of the real workflow. See INSTALL.md gotcha 17.

Use Gerrit's **replication plugin**, not Gitea's pull-mirror:

- It's push-based and event-driven (fires on ref-update), vs. Gitea's
  pull-mirror which polls on an interval — Gitea stays in sync
  immediately after submit.
- Scope the refspec to `refs/heads/*:refs/heads/*` and
  `refs/tags/*:refs/tags/*` only — **exclude `refs/changes/*`**. Since
  `refs/heads/*` only moves when a change is submitted, this gives
  "mirror only on merge" behavior without extra logic.
- Authenticate the replication job as a dedicated service account that
  is the *only* identity with Write on the Gitea repo's Code unit. Every
  human on the **working team** gets Read there via team permissions
  alone — but that's not the whole story for org **Owners** (the `admins`
  LDAP group): Gitea Owners always have full admin on every org repo,
  inherent to being an Owner and not something team/unit permissions can
  strip. Confirmed live: an Owner-team account could force-push straight
  to a mirrored repo, bypassing Gerrit review entirely, with team
  permissions alone. A branch-protection rule *is* needed after all —
  restricting push (including force-push) to the replication service
  account's team, with admin bypass explicitly blocked — see ADMIN.md's
  "Add a project" for the exact step, confirmed to actually block Owners
  while leaving replication itself working.

## 3. Linking Gerrit changes to Gitea issues/kanban

- Commit message convention: include a trailer such as
  `Fixes org/repo#123`. Gitea parses closing keywords on any push that
  lands commits on the default branch, including pushes from the
  replication bot, so a merged Gerrit change auto-closes the linked
  Gitea issue — confirmed working end to end in `scripts/install/09-smoke-test.sh`
  (issue closed ~12s after Gerrit submit).

  **It does not, however, move the issue's card on a Gitea Projects
  board.** Tested directly: closing an issue linked to a project-board
  card left the card sitting in its original column, just visually
  marked closed — Gitea 1.27.1 has no auto-move-on-close automation (no
  such option exists anywhere in its column settings, only "Set Default"
  for newly-added issues), unlike GitHub Projects' workflow automation.
  If a kanban board is in use, moving cards for closed issues is a manual
  step. Note also that Gitea has no REST API for Projects at all in this
  version, so this can't be scripted around either.
- Gerrit itself won't render that link, so a lightweight webhook is a
  natural next step (Gerrit event-stream → post a comment on the Gitea
  issue with the change URL/status) for visibility *during* review, not
  just at merge. Not needed for the initial setup since there is no CI
  yet, but worth revisiting.

## 4. End-to-end flow

1. Work is planned as a Gitea Issue, prioritized on a Gitea Kanban
   board.
2. Dev clones/pushes to **Gerrit**
   (`git push origin HEAD:refs/for/main`); the commit message references
   the Gitea issue.
3. Review happens in Gerrit (currently just the `Code-Review` label —
   `Verified` isn't configured yet, since it's normally cast by a CI bot
   and there's no CI wired up; see "Open items" below).
4. On submit, Gerrit merges to the branch and the replication plugin
   pushes the new ref to Gitea.
5. Gitea ingests the push and auto-closes the linked issue (**not** its
   kanban card, if it's on one — see section 3).
6. Wiki stays a normal writable Gitea repo (not mirrored) for docs.

Every step from 1 onward assumes a developer's LDAP `developers`-group
membership actually grants working Gitea access (repo read, issue
write, wiki write) — worth calling out because it silently didn't for a
while: a Gitea API quirk (see INSTALL.md gotcha 11) meant the
`Developers` team's org-wide grant never actually took effect, so
developers got `404` on the repo, its issues, and its wiki the entire
time despite every setup script reporting success. Confirmed fixed by
testing as alice (an actual `developers`-group account, not an admin)
directly against steps 1 and 6 above, end to end.

## 5. Customer branch delivery (Gerrit ↔ GitLab)

Delivery to a customer on GitLab isn't one-directional forever: the
customer modifies the code, and after some time we pull their changes
back in before adding new material and delivering again. Gerrit's job
is only to review *our own* work within each such round — there's no
need to (and no attempt to) preserve Gerrit history *across* a
pull-from-customer event. Each pull is treated as the start of a fresh,
unrelated line of work, same as if it were a new project.

**Model: one Gerrit branch per cycle.** A "cycle" runs from one import
of the customer's code to the next delivery (or next import, if we
deliver more than once before hearing back from them). Each cycle gets
its own Gerrit branch, seeded with a single commit whose tree is an
exact copy of whatever the customer currently has. Our own changes land
on that branch through the normal Gerrit review flow (sections 1-2).
When it's time to deliver, the branch's tip is squash-exported back to
the customer, structurally scrubbed of Gerrit-internal trailers exactly
as before. When the customer later sends more of their own changes, we
don't try to merge them into the old cycle branch — we start an
entirely new one, seeded fresh from their new tree. This sidesteps ever
needing a three-way merge across histories that Gerrit and the
customer's GitLab have no real shared ancestor for.

### One-time setup per customer

```sh
git remote add customer-<name> <gitlab-url>
git fetch customer-<name>
git checkout -b customer-<name>-sync customer-<name>/main
```

### Start a cycle (import from the customer)

```sh
git fetch customer-<name>
CYCLE=customer/<name>/$(date +%F)-import   # add a suffix if more than one import lands the same day

git checkout --orphan "$CYCLE" customer-<name>/main
git commit -m "Import from <name> as of $(date +%F)

Baseline for this cycle's work; nothing to diff against yet, since it's
simply what the customer currently has."
git push gerrit HEAD:refs/heads/$CYCLE
```

Pushed directly (not through `refs/for/`) since there's nothing of
*ours* to code-review yet — it's just "this is what the customer has
now." Needs Gerrit's "Create Reference" access right on
`refs/heads/customer/*`, granted to whichever maintainers run this
procedure. Gerrit's replication refspec (`refs/heads/*:refs/heads/*`,
section 2) picks the new branch up into Gitea automatically — no extra
config needed there.

Anyone who wants to see what the customer actually changed can diff
this new seed commit against the *previous* cycle's final delivered
commit (the last squash commit pushed to `customer-<name>/main`) — that
diff is the real "what did the customer do" review, even though branch
creation itself isn't gated on it.

### Work within a cycle

Normal flow, just targeting the cycle branch instead of `main`:
`git push gerrit HEAD:refs/for/$CYCLE`, reviewed and submitted like any
other change.

### Deliver (export) a cycle

Same mechanism as a single delivery: full tree replace onto the
customer's current tip, message built from commit **subjects only** so
`Change-Id:` and any other trailer never has a path into the customer
repo, tracked with a `Synced-From:` trailer we mint ourselves. The only
difference from a flat, single-branch model is that `LAST` is scoped to
*this cycle's branch*: either the cycle's own seed commit (first
delivery of the cycle) or the previous delivery's `Synced-From:` value
(if delivering the same cycle more than once before the next import).

```sh
git fetch gerrit
git fetch customer-<name>
git checkout customer-<name>-sync
git reset --hard customer-<name>/main

NEW=$(git rev-parse gerrit/$CYCLE)
LAST=$(git log -1 --format='%(trailers:key=Synced-From,valueonly)' customer-<name>/main)
if [ -z "$LAST" ]; then
  LAST=$(git rev-list --max-parents=0 "$NEW")   # this cycle's own seed commit
fi

git rm -rf --ignore-unmatch . >/dev/null
git checkout gerrit/$CYCLE -- .
git add -A

{
  echo "Sync internal $CYCLE as of $(git rev-parse --short "$NEW") ($(date +%F))"
  echo
  git log --no-merges --format='* %s' "$LAST".."$NEW"
  echo
  echo "Synced-From: $NEW"
} > /tmp/customer-sync-msg.txt

git commit -F /tmp/customer-sync-msg.txt
git push customer-<name> customer-<name>-sync:main
```

### Next cycle

When the customer sends more changes, go back to "Start a cycle" — a
brand-new branch, seeded fresh, no attempt to reconcile it with the
just-finished cycle branch. This is also how customer-made edits get
absorbed: whatever they changed is simply part of what the next cycle's
seed commit imports, not something silently overwritten. Old cycle
branches are inert once delivered; delete or archive them per whatever
retention policy the team settles on (open item, below).

## Open items / future work

- Gerrit → Gitea webhook for in-review visibility on issues.
- CI/CD placement (deferred): likely pre-merge Verified checks in
  Gerrit, with post-merge pipelines against the mirrored repo in Gitea
  for deploy/release once needed.
- Retention/naming policy for old customer cycle branches (see section
  5) once there's enough real cycle history to know what's worth
  keeping.

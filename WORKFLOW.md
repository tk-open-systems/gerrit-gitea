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
    Gerrit, not Gitea PRs.
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

## 2. Repo mirroring (Gerrit → Gitea, merge-only)

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
  human gets Read there — that is the read-only enforcement, rather than
  a branch-protection rule bolted on afterward.

## 3. Linking Gerrit changes to Gitea issues/kanban

- Commit message convention: include a trailer such as
  `Fixes org/repo#123`. Gitea parses closing keywords on any push that
  lands commits on the default branch, including pushes from the
  replication bot, so a merged Gerrit change auto-closes the linked
  Gitea issue and moves its card on a Gitea Projects board.
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
3. Review happens in Gerrit (Code-Review/Verified labels, patchsets).
4. On submit, Gerrit merges to the branch and the replication plugin
   pushes the new ref to Gitea.
5. Gitea ingests the push, auto-closes the linked issue, and moves the
   kanban card.
6. Wiki stays a normal writable Gitea repo (not mirrored) for docs.

## Open items / future work

- Gerrit → Gitea webhook for in-review visibility on issues.
- CI/CD placement (deferred): likely pre-merge Verified checks in
  Gerrit, with post-merge pipelines against the mirrored repo in Gitea
  for deploy/release once needed.

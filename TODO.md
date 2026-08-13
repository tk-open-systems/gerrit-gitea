# TODO

Sysadmin/infra setup is done — see [SYSADMIN.md](SYSADMIN.md)'s Status
checklist and the `scripts/` directory. What's left is workflow-side, per
WORKFLOW.md's "Open items / future work":

- [ ] Gerrit → Gitea webhook for in-review issue visibility (Gerrit
      event-stream → comment on the linked Gitea issue with the change
      URL/status). Not needed until there's more review-time activity to
      surface; revisit then.
- [ ] Decide CI/CD placement: likely pre-merge Verified checks in Gerrit,
      post-merge pipelines against the mirrored repo in Gitea for
      deploy/release. Deferred until there's a real pipeline to wire up.
- [ ] Roll out the `Fixes org/repo#123` commit-trailer convention to the
      team (documented in WORKFLOW.md section 3, verified working in
      `scripts/09-smoke-test.sh` — this item is about team adoption, not
      more engineering).
- [ ] Settle a retention/naming policy for old customer cycle branches
      (documented in WORKFLOW.md section 5). Deferred until there's
      enough real cycle history across customers to know what's worth
      keeping.

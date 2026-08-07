# TODO

- [ ] Set up the Gerrit replication plugin config for this
- [ ] Configure Gitea LDAP group-to-team mapping
- [ ] Build Gerrit → Gitea webhook for in-review issue visibility
- [ ] Create dedicated Gerrit replication service account (Write-only on Gitea's Code unit)
- [ ] Configure per-repo Gitea units (disable Pull Requests, set Code read-only, Issues/Wiki/Projects writable)
- [ ] Document the commit-message trailer convention (`Fixes org/repo#123`) for the team
- [ ] Bind Gerrit to LDAP groups and set up `All-Projects` inherited access rights

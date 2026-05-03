# add_reviewer

Request a review from specific GitHub users or teams.

Allowed params:

```json
{
  "reviewers": ["alice", "bob"],
  "team_reviewers": ["security-team"]
}
```

Use when the diff touches an area that clearly needs a specific expert:
- auth/security changes → security team
- database migrations → DBA or backend lead
- public API changes → API owners

Do not request reviewers already assigned.

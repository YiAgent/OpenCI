# link_linear

Synchronize the issue or branch state with Linear.

Allowed params:

```json
{
  "linear_issue_id": "LIN-123",
  "body": "GitHub issue linked: https://github.com/owner/repo/issues/123"
}
```

Execution contract:

- `linear_issue_id` may be a Linear UUID or issue identifier.
- The executor writes a Linear comment through the Linear GraphQL API.
- The executor skips this skill when no Linear token is configured and records
  that skip in the audit comment.

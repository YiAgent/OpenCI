# create_branch

Create a deterministic branch associated with the issue.

Allowed params:

```json
{
  "branch": "feature/issue-123-short-title",
  "base": "main"
}
```

The executor skips creation when the branch already exists.


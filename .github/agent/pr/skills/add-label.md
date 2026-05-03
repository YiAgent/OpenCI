# add_label

Add one or more labels to the pull request.

Allowed params:

```json
{
  "labels": ["area:auth", "needs-security-review"]
}
```

Use existing repository labels when possible. Do not add labels already
present (check `gate-results.json`.labels_applied before recommending).

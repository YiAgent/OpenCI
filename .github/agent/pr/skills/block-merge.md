# block_merge

Add the `do-not-merge` label to prevent the PR from being merged.

Allowed params:

```json
{
  "reason": "Short explanation shown in the PR comment."
}
```

Use ONLY when:
- `secrets_found=true` in gate-results.json
- A critical security or data-loss risk is clearly identifiable from the diff

Do not use for style issues or subjective concerns.
High-risk skill: only executed for trusted actors (OWNER/MEMBER/COLLABORATOR).

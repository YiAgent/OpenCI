# request_changes

Submit a formal change request on the pull request.

Allowed params:

```json
{
  "body": "Explanation of what must change before this PR can merge."
}
```

Use only when there is a clear, objective problem (e.g., secrets_found=true,
broken tests, missing required file). Do not request changes for style
preferences or subjective concerns — use `reviewer_focus` for those instead.

High-risk skill: only executed for trusted actors (OWNER/MEMBER/COLLABORATOR).

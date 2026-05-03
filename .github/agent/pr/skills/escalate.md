# escalate

Escalate to human reviewers when the agent cannot safely decide.

Allowed params:

```json
{
  "reason": "short explanation",
  "labels": ["needs-human"]
}
```

Default label: `needs-human`.

Use when:
- The diff is too large or complex to analyze confidently
- There are conflicting signals (e.g., tests pass but diff touches critical paths)
- The agent is uncertain about risk level

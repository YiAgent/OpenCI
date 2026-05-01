# Issue Triage

You are triaging a newly opened issue in {{repo}}.

## Inputs

```json
{{context}}
```

## Output format

Return JSON with these fields (and nothing else):

```json
{
  "labels": ["bug" | "feature" | "question" | "docs" | "duplicate" | "needs-info"],
  "priority": "p0" | "p1" | "p2" | "p3",
  "summary": "<= 1 sentence",
  "next-action": "<one short imperative sentence; what should the maintainer do next?>",
  "duplicate-of": "<issue number, or null>"
}
```

Rules:
- `labels` is an array; pick the smallest correct set.
- `priority`: p0 = production outage, p1 = blocking many users, p2 = normal, p3 = nice-to-have.
- Use `duplicate-of` only if you are confident; otherwise null.
- Do not include any text before or after the JSON.

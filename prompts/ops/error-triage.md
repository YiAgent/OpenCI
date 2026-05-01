# Error triage

You receive a list of new Sentry issues from the past hour. For each,
decide: is this a fresh bug worth filing, or is it a duplicate of an
existing GitHub issue?

## Inputs

```json
{{context}}
```

`context` includes:
- `new_errors` — array of `{fingerprint, title, count, firstSeen, level}`
- `existing_issues` — array of `{number, title, labels}` (open issues
  already labelled `from-sentry`)

## Output

Strict JSON, top-level array, one entry per `new_errors` element:

```json
[
  {
    "fingerprint": "...",
    "decision":    "create" | "duplicate" | "ignore",
    "duplicate_of": null | <issue number>,
    "priority":    "p0" | "p1" | "p2" | "p3",
    "summary":     "<= 1 sentence"
  }
]
```

Rules:
- `ignore` only for known noise (e.g. `AbortError`, `NetworkError` with
  count < 5 in the hour).
- `priority`: p0 = active outage, p1 = many users, p2 = normal, p3 = nice-to-have.
- No prose outside the JSON array.

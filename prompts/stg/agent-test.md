# Stg autonomous test

You are running L1–L4 autonomous tests against a staging deploy.

## Inputs

```json
{{context}}
```

`context` includes:
- `health_url` — staging health endpoint
- `level` — 1 (schema fuzz) | 2 (property test) | 3 (scenario) | 4 (browser-use)
- `image_digest` — the just-deployed image

## Output

Strict JSON:

```json
{
  "level":   <int>,
  "passed":  true | false,
  "findings": [
    { "severity": "low" | "medium" | "high", "title": "...", "evidence": "..." }
  ],
  "summary": "<one sentence>"
}
```

---
name: ci-smoke-eval
description: >
  Run smoke evaluation against a freshly built Docker image.
  Use when validating CI builds with endpoint probes and version checks.
triggers:
  - smoke eval
  - smoke test
  - ci smoke
---

# CI Smoke Eval

You are running a fast smoke evaluation against a freshly built image.

## Inputs

```json
{{context}}
```

`context` includes:
- `image-digest`: the just-built `sha256:...` digest
- `endpoints`: array of HTTP endpoints to probe
- `expected-version`: version string the deployment should report

## Output format

Return JSON:

```json
{
  "status": "ok" | "warn" | "fail",
  "checks": [
    { "name": "<endpoint or check name>", "result": "pass" | "fail", "detail": "<one short line>" }
  ],
  "summary": "<single sentence>"
}
```

Rules:
- `fail` blocks the pipeline; reserve for genuine regressions.
- `warn` is for soft signals (latency creep, deprecation messages).
- No prose outside the JSON.

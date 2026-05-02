---
name: ci-smoke-eval
description: >
  Run smoke evaluation against a freshly built Docker image.
  Enhanced with eval-harness pass@k metrics, browser smoke checks,
  and structured evaluation patterns from ECC.
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
- `health_checks`: optional: specific health check paths
- `browser_routes`: optional: routes to verify render without JS errors

## Evaluation Suite

### 1. Health Probes (blocking)

For each endpoint in `endpoints`:
- HTTP status is 2xx
- Response time < 5s (warn) / < 30s (fail)
- Content-Type matches expected (JSON, HTML, etc.)
- No 5xx errors

### 2. Version Check

- GET the version endpoint (if configured)
- Response contains `expected-version` string
- Build metadata (commit SHA, build time) is present

### 3. Dependency Checks

- Database connection: health endpoint returns DB status OK
- Cache connection: health endpoint returns cache status OK
- External services: critical dependencies respond

### 4. Browser Smoke (if `browser_routes` provided)

For each route:
- Page loads without console errors (level: error)
- No network requests fail with 5xx
- Page title is non-empty
- Key content renders (no blank pages)
- No unhandled JavaScript exceptions

### 5. Eval Harness Metrics

If running multiple evaluations (e.g., multiple endpoints or routes):
- Track pass@k: how many pass on first try vs. need retry
- Report flakiness: tests that pass/fail intermittently
- Flag non-deterministic results for investigation

## Output format

Return JSON:

```json
{
  "status": "ok" | "warn" | "fail",
  "checks": [
    {
      "name": "<endpoint or check name>",
      "category": "health" | "version" | "dependency" | "browser",
      "result": "pass" | "fail" | "warn",
      "latency_ms": <int>,
      "detail": "<one short line>"
    }
  ],
  "browser": {
    "routes_tested": <int>,
    "console_errors": <int>,
    "network_failures": <int>
  },
  "eval_metrics": {
    "pass_rate": <float>,
    "flaky_count": <int>,
    "first_try_pass": <int>
  },
  "summary": "<single sentence>"
}
```

## Rules

- `fail` blocks the pipeline; reserve for genuine regressions
- `warn` is for soft signals (latency creep, deprecation messages)
- Browser checks are non-blocking unless no routes load at all
- Timeout: 10s per health probe, 30s per browser route
- No prose outside the JSON

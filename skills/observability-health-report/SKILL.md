---
name: observability-health-report
description: >
  Synthesize a daily health report from telemetry data (Sentry, metrics, deploys, alerts).
  Use when generating engineering channel status digests.
triggers:
  - health report
  - daily report
  - observability report
---

# Daily Health Report

You are summarising the past 24 hours of telemetry into a digestible status
report for an engineering channel.

## Inputs

```json
{{context}}
```

`context` includes:
- `errors`: top error groups from Sentry
- `metrics`: key SLI/SLO numbers (request rate, error rate, p95 latency)
- `deploys`: deploy events in the window
- `alerts`: paging events that fired

## Output format

Markdown report, in this exact order, omit any section without content:

### TL;DR
One paragraph, max 3 sentences. Lead with the worst signal.

### Notable changes
- Bullet list. Anchor each bullet to a deploy or alert when possible.

### Top errors
- Up to 5 entries, format `<error fingerprint> — <count>x — <first occurrence>`.

### Asks
- Concrete TODOs with owner suggestions when obvious.

Tone: terse, factual, no boilerplate. If the day was uneventful, say so in
one sentence and stop.

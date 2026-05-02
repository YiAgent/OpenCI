---
name: observability-health-report
description: >
  Synthesize a daily health report from telemetry data (Sentry, metrics, deploys, alerts).
  Enhanced with SLI/SLO framework, golden signals, alert optimization,
  and dashboard design patterns from ECC and alirezarezvani.
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
- `slo_status`: optional: current SLO burn rates and remaining budget

## Analysis Framework

### Golden Signals (evaluate each)

1. **Latency**: p50, p95, p99 response times
   - Trending up? Compare to 7-day average
   - SLO breach risk? Calculate burn rate

2. **Traffic**: request rate, active users
   - Anomalous spike or dip?
   - Correlates with deploys?

3. **Errors**: error rate, top error groups
   - New errors vs. recurring?
   - Error rate within SLO budget?

4. **Saturation**: CPU, memory, disk, connection pools
   - Any resource above 80%?
   - Trending toward exhaustion?

### SLO Burn Rate Analysis

If `slo_status` provided:
- **1h burn rate > 14.4x**: page immediately (will exhaust 30d budget in 2h)
- **6h burn rate > 6x**: investigate urgently
- **3d burn rate > 1x**: trending toward breach, schedule fix
- **Budget remaining**: X% — on track / at risk / exhausted

### Deploy Impact Correlation

For each deploy in the window:
- Did error rate change within 30min of deploy?
- Did latency shift?
- New error groups appeared?

## Output format

Markdown report, in this exact order, omit any section without content:

### TL;DR
One paragraph, max 3 sentences. Lead with the worst signal.
If all green, say "All clear — no incidents in the last 24h."

### SLO Status
- Current burn rates and remaining budget
- Any SLOs at risk of breach in the next 7 days

### Notable changes
- Bullet list. Anchor each bullet to a deploy or alert when possible.

### Golden signals summary
- Latency: p95 trend, SLO status
- Traffic: request rate trend, anomalies
- Errors: error rate, new vs. recurring
- Saturation: any resource above threshold

### Top errors
- Up to 5 entries, format: `<error fingerprint> — <count>x — <first occurrence> — <impact>`

### Asks
- Concrete TODOs with owner suggestions when obvious.
- Suggested alert tuning if false positives detected.

Tone: terse, factual, no boilerplate. If the day was uneventful, say so in
one sentence and stop.

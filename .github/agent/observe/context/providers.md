# Provider Signal Guide

This document helps the Agent correctly interpret signals from each monitoring provider.

## Sentry

**What it measures**: Application-level errors and crashes.

Signal interpretation:
- `error_rate` spike immediately after deploy → almost certainly deployment-caused
- `crash_free_rate` drop → user-impacting, likely needs rollback
- `new_issues_count` spike → new code paths hit with bugs
- `apdex` < 0.7 → significant user experience degradation

Caution:
- `error_rate` can spike briefly as old instances drain (false positive in first 2 min of deploy)
- `new_issues_count` often spikes on canary due to new code paths — judge by severity, not count alone

## PostHog

**What it measures**: Business KPIs and user behavior.

Signal interpretation:
- `funnel_conversion` drop → product-impacting, correlate with Sentry errors
- `event_{name}_count` drop → feature regression or user-impacting bug
- `active_users` drop → broad availability issue
- `error_event_count` spike → JS errors or API failures surfacing to frontend

Caution:
- PostHog reflects user-facing impact, not server-side errors
- Low `active_users` in low-traffic windows is normal — don't alert outside business hours
- `funnel_conversion` has natural variance — only alert if drop is >15% from baseline

## Axiom

**What it measures**: Log-level operational signals.

Signal interpretation:
- `log_error_rate` spike → backend errors not yet surfacing in Sentry (async jobs, background workers)
- `request_p99_ms` spike → infrastructure or database latency
- `log_warn_count` trend → early warning before errors

Caution:
- Axiom lags by 1-3 minutes in high-volume scenarios
- `log_error_rate` includes expected errors (404s, auth failures) — use `AXIOM_APL` to filter

## Datadog

**What it measures**: Infrastructure health and APM performance.

Signal interpretation:
- `cpu_usage` > 90% → risk of OOM or slowdown, but not rollback-worthy alone
- `memory_usage` > 95% → immediate risk, check for memory leak in new deployment
- `p99_latency_ms` spike → APM traces will show which service/operation
- `requests_per_second` drop → possible availability issue upstream

Caution:
- Infra metrics lag by 1-2 minutes
- CPU spike during deploy is normal (container startup) — ignore first 5 min

## LangSmith

**What it measures**: LLM chain/agent reliability and quality.

Signal interpretation:
- `run_error_rate` spike → LLM API errors, context length exceeded, or tool call failures
- `run_p99_latency_ms` spike → model timeout, complex chains, or API rate limits
- `total_cost_usd` spike → runaway agent loops, token explosion, or unexpected traffic
- `eval_score` drop → prompt regression after model or prompt change
- `feedback_score` drop → user-visible quality degradation

Caution:
- LLM latency is naturally high and variable — p99 > 10s is acceptable for complex agents
- `total_cost_usd` must be evaluated against request volume — cost per request matters more
- `eval_score` reflects offline evals which may lag — don't use for real-time rollback decisions

## Cross-Provider Correlation

When multiple providers show signals simultaneously:

| Pattern | Interpretation |
|---------|---------------|
| Sentry ↑ + PostHog funnel ↓ | User-facing bug — high priority |
| Datadog CPU ↑ + Sentry latency ↑ | Infrastructure saturation |
| Axiom errors ↑ + Sentry quiet | Background job failures |
| LangSmith errors ↑ + Sentry quiet | AI feature degraded, not core app |
| PostHog ↓ + others normal | Analytics tracking issue, not an incident |
| All services degrade together | Infrastructure event or dependency outage |

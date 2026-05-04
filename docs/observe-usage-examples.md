# Observability Usage Examples

How to wire the observability providers in your project.
Copy relevant sections into your deploy / on-observe workflow.

## Example A: Minimal — Sentry only (post-deploy canary watch)

```yaml
uses: YiAgent/OpenCI/.github/workflows/reusable-observability.yml@v3
with:
  environment: production
  mode: canary-watch
  providers: sentry
secrets:
  SENTRY_TOKEN: ${{ secrets.SENTRY_TOKEN }}
```

## Example B: AI product — Sentry + PostHog + LangSmith

```yaml
uses: YiAgent/OpenCI/.github/workflows/reusable-observability.yml@v3
with:
  environment: production
  mode: multi-observe
  providers: sentry,posthog,langsmith
  posthog-events: purchase,ai_chat_started,ai_chat_completed
  posthog-funnel-id: "12345"
  langsmith-project: my-ai-app
  langsmith-eval-dataset: golden-set-v3
  thresholds-file: .github/observe-thresholds.yml
secrets:
  SENTRY_TOKEN:        ${{ secrets.SENTRY_TOKEN }}
  POSTHOG_API_KEY:     ${{ secrets.POSTHOG_API_KEY }}
  POSTHOG_PROJECT_ID:  ${{ secrets.POSTHOG_PROJECT_ID }}
  LANGSMITH_API_KEY:   ${{ secrets.LANGSMITH_API_KEY }}
  anthropic-api-key:   ${{ secrets.ANTHROPIC_API_KEY }}
```

## Example C: Full stack — all 5 providers

```yaml
uses: YiAgent/OpenCI/.github/workflows/reusable-observability.yml@v3
with:
  environment: production
  mode: multi-observe
  observe-window: 30m
  providers: sentry,posthog,axiom,datadog,langsmith

  # Sentry
  sentry-env: production

  # PostHog
  posthog-events: purchase,signup,api_call
  posthog-funnel-id: "67890"

  # Axiom
  axiom-dataset: production-logs

  # Datadog
  datadog-env: production
  datadog-service: api

  # LangSmith
  langsmith-project: production-agents
  langsmith-run-type: chain

  thresholds-file: .github/observe-thresholds.yml
secrets:
  SENTRY_TOKEN:        ${{ secrets.SENTRY_TOKEN }}
  POSTHOG_API_KEY:     ${{ secrets.POSTHOG_API_KEY }}
  POSTHOG_PROJECT_ID:  ${{ secrets.POSTHOG_PROJECT_ID }}
  AXIOM_TOKEN:         ${{ secrets.AXIOM_TOKEN }}
  AXIOM_ORG_ID:        ${{ secrets.AXIOM_ORG_ID }}
  DD_API_KEY:          ${{ secrets.DD_API_KEY }}
  DD_APP_KEY:          ${{ secrets.DD_APP_KEY }}
  LANGSMITH_API_KEY:   ${{ secrets.LANGSMITH_API_KEY }}
  anthropic-api-key:   ${{ secrets.ANTHROPIC_API_KEY }}
```

## Example D: Custom PostHog HogQL for domain-specific business metrics

For e-commerce: measure revenue impact of a deploy.
PostHog HogQL counts revenue events in the window.

```yaml
with:
  mode: multi-observe
  posthog-events: checkout_completed,checkout_failed,refund_initiated
  thresholds-file: .github/observe-thresholds.yml
```

Custom `.github/observe-thresholds.yml`:

```yaml
event_checkout_completed_count:
  warning:   80      # % of baseline (set per your traffic)
  critical:  50
  direction: low
event_checkout_failed_count:
  warning:   10
  critical:  30
  direction: high
```

## Example E: Custom Axiom APL for structured log metrics

If your logs have structured fields like `path`, `status_code`, `duration_ms`,
use `axiom-apl` to get precise metrics instead of the built-in `log_error_rate`.

```yaml
with:
  mode: multi-observe
  axiom-apl: |
    ['production-logs']
    | where _time > ago(30m)
    | where path startswith "/api/"
    | summarize
        name = "api_error_rate",
        value = todouble(countif(status_code >= 500)) / todouble(count())
    | union (
        ['production-logs']
        | where _time > ago(30m)
        | where path startswith "/api/"
        | summarize name = "api_p99_ms", value = percentile(duration_ms, 99)
      )
```

## The 4-stage multi-observe pipeline

When `mode: multi-observe`, the workflow runs a 4-stage agentic pipeline:

1. **Collect** — Adapters pull metrics from each configured provider (Sentry, PostHog, Axiom, Datadog, LangSmith)
2. **Normalize** — Merge metrics, evaluate against configurable thresholds
3. **Agent** — Claude acts as incident-analyst, assessing state (healthy/degraded/critical) and planning actions
4. **Execute** — Allowed actions: `trigger_rollback`, `create_incident`, `notify`, `extend_observe`, `promote_canary`, `escalate`

## Secrets Reference

| Secret | Where to find it |
|--------|-----------------|
| `SENTRY_TOKEN` | sentry.io → Settings → API Tokens |
| `POSTHOG_API_KEY` | PostHog → Project Settings → Personal API Keys |
| `POSTHOG_PROJECT_ID` | PostHog → Project Settings → Project ID |
| `AXIOM_TOKEN` | Axiom → Settings → API Tokens |
| `AXIOM_ORG_ID` | Axiom → Settings → Organisation ID (cloud only) |
| `DD_API_KEY` | Datadog → Organization Settings → API Keys |
| `DD_APP_KEY` | Datadog → Organization Settings → Application Keys |
| `LANGSMITH_API_KEY` | LangSmith → Settings → API Keys |
| `anthropic-api-key` | Required for `multi-observe` mode (Claude incident analyst) |

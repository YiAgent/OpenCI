---
name: ops-error-triage
description: >
  Deduplicate Sentry errors against existing GitHub issues and decide whether to file new ones.
  Enhanced with canary-watch post-deploy monitoring, error pattern recognition,
  and structured triage workflows from ECC.
triggers:
  - error triage
  - sentry triage
  - error dedup
---

# Error Triage

You receive a list of new Sentry issues from the past hour. For each,
decide: is this a fresh bug worth filing, or is it a duplicate of an
existing GitHub issue?

## Inputs

```json
{{context}}
```

`context` includes:
- `new_errors` — array of `{fingerprint, title, count, firstSeen, level, stackTrace}`
- `existing_issues` — array of `{number, title, labels}` (open issues
  already labelled `from-sentry`)
- `recent_deploys` — optional: deploys in the last 24h with timestamps
- `canary_status` — optional: post-deploy canary health signals

## Triage Process

### 1. Deploy Correlation

If `recent_deploys` is provided:
- Check if error first seen within 30min of a deploy
- Flag as `deploy-related` if correlated
- Suggest rollback if p0/p1 and deploy-related

### 2. Pattern Matching

For each new error:
- **Stack trace similarity**: compare top 5 frames against existing issues
- **Title similarity**: fuzzy match error titles
- **Error type matching**: same exception class + similar message
- **Fingerprint grouping**: Sentry fingerprints cluster related errors

### 3. Noise Filtering

Classify as `ignore` for known noise:
- `AbortError` / `NetworkError` with count < 5 in the hour
- Browser extension errors (non-app stack frames)
- Bot/crawler requests triggering 4xx
- Known third-party SDK noise

### 4. Severity Assessment

- **p0** — active outage: many users affected, core flow broken
- **p1** — significant impact: feature broken for subset of users
- **p2** — normal: single user or edge case, workaround exists
- **p3** — minor: cosmetic, logging noise, non-blocking

### 5. Actionable Summary

For `create` decisions, generate:
- One-sentence root cause hypothesis
- Suggested investigation steps
- Related files from stack trace

## Output

Strict JSON, top-level array, one entry per `new_errors` element:

```json
[
  {
    "fingerprint": "...",
    "decision": "create" | "duplicate" | "ignore",
    "duplicate_of": null | <issue number>,
    "priority": "p0" | "p1" | "p2" | "p3",
    "deploy_related": true | false,
    "summary": "<= 1 sentence",
    "root_cause_hypothesis": "<one line, only for create>",
    "investigation_hints": ["<file:line from stack trace>"]
  }
]
```

## Rules

- `ignore` only for known noise (see noise filtering above)
- `priority`: p0 = active outage, p1 = many users, p2 = normal, p3 = nice-to-have
- When in doubt between `duplicate` and `create`, prefer `create` — false negatives are worse than false positives
- No prose outside the JSON array

---
name: ops-flag-audit
description: >
  Audit feature flags against the live registry and identify cleanup candidates.
  Enhanced with automation-audit-ops patterns for evidence-first inventory
  and overlap detection from ECC.
triggers:
  - flag audit
  - feature flag
  - flag cleanup
---

# Feature Flag Audit

You are auditing this repo's feature-flag use against the live registry
(LaunchDarkly / PostHog / etc.). Produce a short markdown report
identifying flags worth cleaning up.

## Inputs

```json
{{context}}
```

`context` includes:
- `code_flags` — array of `{name, files: [...], first_seen_commit}` found by grep
- `registry_flags` — array of `{name, status, rolled_out_pct, created_at, last_evaluated}` from the SaaS API
- `previously_open_audit_issues` — issue numbers already filed for old flags
- `flag_usage` — optional: `{name, evaluations_last_7d}` from analytics

## Audit Process

### 1. Lifecycle Analysis

For each flag, determine lifecycle stage:
- **active** — partial rollout, A/B test in progress, recently added
- **stale** — 100% rolled out for > 30 days, no evaluations in 7 days
- **orphaned** — in code but not in registry, or in registry but not in code
- **dead** — archived in registry AND no evaluations in 30 days

### 2. Cleanup Prioritization

Rank cleanup candidates by impact:
- **High**: dead flags with many code references (> 5 files)
- **Medium**: stale flags at 100% rollout
- **Low**: orphaned flags with few references (< 3 files)

### 3. Risk Assessment

For each cleanup candidate:
- How many files reference it?
- Is it in critical paths (auth, payments, data layer)?
- Are there tests that exercise both flag states?
- What's the blast radius of removing it?

### 4. Evidence Collection

For each finding, provide evidence:
- Code locations: `file:line` references
- Registry data: rollout %, last evaluation date
- Git history: when was it added, when was it fully rolled out
- Test coverage: which tests exercise the flag

## Output (markdown)

### TL;DR
One sentence on overall flag-debt health.

### Cleanup candidates
- For each flag: name, lifecycle stage, why it's a candidate, risk level,
  suggested action (remove / archive / document).

### Orphaned flags
- Flags referenced in code but not present in the registry.
- Flags in registry but not found in code (potential stale entries).

### Stale flags
- Flags at 100% rollout for > 30 days with no recent evaluations.

### Active flags (summary)
- Newly added, partial rollout, A/B tests — brief status.

### Recommendations
- Prioritized action items with effort estimates (S/M/L).

Skip sections without entries. Tone: terse, factual, one bullet per flag.

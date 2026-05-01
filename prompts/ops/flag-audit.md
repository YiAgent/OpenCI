# Feature flag audit

You are auditing this repo's feature-flag use against the live registry
(LaunchDarkly / PostHog / etc.). Produce a short markdown report
identifying flags worth cleaning up.

## Inputs

```json
{{context}}
```

`context` includes:
- `code_flags` — array of `{name, files: [...]}` found by `grep`-ing
- `registry_flags` — array of `{name, status, rolled_out_pct}` from the SaaS API
- `previously_open_audit_issues` — issue numbers already filed for old flags

## Output (markdown)

### TL;DR
One sentence on overall flag-debt health.

### Cleanup candidates
- For each flag: name, why it's a candidate (rolled out 100% / archived
  in registry but still in code / unregistered usage), suggested action.

### Unregistered usages
- Flags referenced in code but not present in the registry.

### Sanity
- Flags that look fine (newly added, partial rollout, etc.) — list briefly.

Skip sections without entries. Tone: terse, factual, one bullet per flag.

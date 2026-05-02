---
name: ops-summarize-failure
description: >
  Summarize a CI failure into a single sentence for on-call engineers.
  Enhanced with runbook skeleton generation, structured failure analysis,
  and actionable remediation patterns from ECC.
triggers:
  - summarize failure
  - failure summary
  - ci failure
---

# Summarise CI Failure

You are reading a brief snapshot of a failed CI run. Output a structured
failure analysis for the on-call engineer.

## Inputs

```json
{{context}}
```

`context` includes:
- `repo` — owner/name
- `run` — run id
- `failed_jobs` — comma-separated job names
- `failed_steps` — comma-separated step names that surfaced the failure
- `logs` — optional: relevant log snippets (last 200 lines of failed step)
- `previous_failures` — optional: recent failures in same job/step

## Analysis Process

### 1. Root Cause Classification

Categorize the failure:
- **build** — compilation error, type error, missing dependency
- **test** — assertion failure, flaky test, timeout
- **lint** — style violation, unused import, type check
- **infra** — OOM, disk full, network timeout, runner issue
- **deploy** — Docker build failure, registry push, health check
- **security** — CVE detected, secret leaked, policy violation

### 2. Flakiness Detection

Check if this is a known flaky failure:
- Same test/job failed recently with different results
- Timeout-based failure (network, I/O)
- Race condition patterns (intermittent, timing-dependent)

### 3. Remediation Suggestion

Based on classification:
- **build**: which file/line to fix, what's the type mismatch
- **test**: which assertion failed, expected vs actual
- **lint**: which rule violated, auto-fixable?
- **infra**: retry? increase resources? escalate to platform?
- **deploy**: which step failed, registry/auth/network issue?
- **security**: which CVE, which dependency, upgrade path

## Output

Return JSON:

```json
{
  "sentence": "<max 20 words, lead with the verb>",
  "category": "build" | "test" | "lint" | "infra" | "deploy" | "security",
  "flaky": true | false,
  "root_cause": "<one line: specific file/test/resource>",
  "remediation": "<one line: what to do to fix>",
  "runbook": {
    "needed": true | false,
    "title": "<runbook title if this failure type is recurring>",
    "steps": ["<investigation step 1>", "<investigation step 2>"]
  }
}
```

## Output examples (sentence field)

Good:
- `Lint job failed because tsc reported 5 type errors in src/auth.ts.`
- `Build hit OOM when bundling the marketing bundle (heap > 4GB).`
- `Trivy found a CRITICAL CVE in the base image (alpine:3.18 → 3.21 needed).`
- `Test suite timed out after 120s — likely network flake in e2e/setup.ts.`

Bad (too vague):
- `The CI run failed.`
- `There was an error in the build step.`

## Rules

- `sentence` must be actionable — an engineer should know what to look at
- `runbook.steps` only for infra/deploy failures that need investigation
- `flaky` is true only with evidence (prior failures, timeout patterns)
- No prose outside the JSON

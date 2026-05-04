# Workflow Test Report: observability.yml

**File**: `.github/workflows/observability.yml`
**Date**: 2026-05-04
**Reusable target**: `YiAgent/OpenCI/.github/workflows/reusable-observability.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

---

## Overview

The `observability.yml` workflow is a thin event-routing entry point that delegates all work to `reusable-observability.yml`. It defines four trigger types (`workflow_run`, `repository_dispatch`, `schedule`, `workflow_dispatch`) and three jobs (`observe-canary`, `observe-drift`, `verify-fix`), each conditionally activated and calling the same reusable workflow with a different `mode` input.

### Validation Results

| Check | Result |
|-------|--------|
| YAML syntax (`yaml.safe_load`) | **PASS** |
| actionlint | **SKIPPED** -- binary not installed; manual analysis performed |
| Reusable workflow file exists locally | **PASS** -- `.github/workflows/reusable-observability.yml` present |
| SHA pin validity | **PASS** -- `f62931b` is commit "Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults" |
| SHA in manifest.yml | **PASS** -- line 104: `YiAgent/OpenCI: "f62931bd0e2b73800512625a9fc5118557957ff3"` |
| `workflow_run` target workflow name | **PASS** -- `reusable-prd.yml` has `name: prd` |
| Runner label (`blacksmith-2vcpu-ubuntu-2404`) | **INFO** -- custom runner; not `ubuntu-latest` |

---

## Node-by-Node Status

### Triggers (`on:`)

| Trigger | Config | Status |
|---------|--------|--------|
| `workflow_run` | `workflows: [prd]`, `types: [completed]` | **PASS** -- `reusable-prd.yml` is named `prd` |
| `repository_dispatch` | `types: [observe-window-complete]` | **WARN** -- see Issue #2 below |
| `schedule` | `*/15 * * * *` (canary), `0 4 * * *` (drift) | **PASS** |
| `workflow_dispatch` | `mode` input, default `canary-watch` | **WARN** -- see Issue #1 below |

### Permissions (top-level)

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
  pages: write
```

**Status**: **WARN** -- overly broad. The reusable workflow sets `permissions: {}` at the top level and scopes per-job (e.g., `contents: read`, `issues: write`). Since reusable workflows inherit caller permissions but can only narrow (not expand), the caller's broad grants are effectively narrowed by the reusable workflow's `permissions: {}`. However, the caller itself declares `contents: write` and `pages: write` which are never used. See Issue #3.

### Concurrency

```yaml
concurrency:
  group: observability-${{ github.event_name }}-${{ github.event.workflow_run.id || github.event.schedule || github.run_id }}
  cancel-in-progress: false
```

**Status**: **PASS** -- sensible grouping. The reusable workflow uses a slightly different key expression but both are functionally equivalent for preventing collisions.

### Job: `observe-canary`

| Field | Value | Status |
|-------|-------|--------|
| `if` | `schedule && schedule == '*/15 * * * *'` | **PASS** |
| `uses` | reusable-observability.yml@f62931b | **PASS** |
| `with.mode` | `canary-watch` | **PASS** -- matches reusable workflow's expected values |
| `with.runner` | `blacksmith-2vcpu-ubuntu-2404` | **INFO** -- custom runner |
| `secrets` | 3 of 8 mapped (anthropic-api-key, sentry-token, datadog-api-key) | **PASS** -- remaining 5 are optional |

### Job: `observe-drift`

| Field | Value | Status |
|-------|-------|--------|
| `if` | `schedule && schedule == '0 4 * * *'` | **PASS** |
| `uses` | reusable-observability.yml@f62931b | **PASS** |
| `with.mode` | `terraform-drift` | **PASS** |
| `with.infra-dir` | `${{ vars.INFRA_DIR \|\| 'infrastructure' }}` | **PASS** |
| `with.runner` | `blacksmith-2vcpu-ubuntu-2404` | **INFO** -- custom runner |
| `secrets` | 3 of 8 mapped | **PASS** |

### Job: `verify-fix`

| Field | Value | Status |
|-------|-------|--------|
| `if` | `(workflow_run && conclusion == 'success') \|\| repository_dispatch \|\| (workflow_dispatch && mode == 'verify-fix')` | **WARN** -- see Issue #1 and #2 |
| `uses` | reusable-observability.yml@f62931b | **PASS** |
| `with.mode` | `verify-fix` | **PASS** |
| `with.runner` | `blacksmith-2vcpu-ubuntu-2404` | **INFO** -- custom runner |
| `secrets` | 3 of 8 mapped | **PASS** |

---

## Issues Found

### Issue 1 -- `workflow_dispatch` with default `canary-watch` triggers NO job [MEDIUM]

**Severity**: MEDIUM
**Category**: Logic gap

The `workflow_dispatch` default for `mode` is `canary-watch`. However:

- `observe-canary` requires `github.event_name == 'schedule'` -- will NOT fire on `workflow_dispatch`
- `observe-drift` requires `github.event_name == 'schedule'` -- will NOT fire on `workflow_dispatch`
- `verify-fix` requires `inputs.mode == 'verify-fix'` -- will NOT fire when `mode` defaults to `canary-watch`

**Result**: A manual `workflow_dispatch` run with the default settings does nothing. All three jobs are skipped.

**Fix options**:
1. Add `|| (github.event_name == 'workflow_dispatch' && inputs.mode == 'canary-watch')` to the `observe-canary` condition
2. Change the `workflow_dispatch` default to `verify-fix` (the only mode that actually runs on dispatch)
3. Add a fourth catch-all job for `workflow_dispatch`

### Issue 2 -- `repository_dispatch` triggers `verify-fix` for ANY event type [LOW]

**Severity**: LOW
**Category**: Logic gap

The `repository_dispatch` trigger is configured for type `observe-window-complete`, but the `verify-fix` job's `if` condition only checks `github.event_name == 'repository_dispatch'` without filtering by `github.event.action`. This means ANY `repository_dispatch` event (not just `observe-window-complete`) will trigger the `verify-fix` job.

**Fix**: Add `&& github.event.action == 'observe-window-complete'` to the `repository_dispatch` branch of the `verify-fix` condition, or create a separate job for `observe-window-complete`.

### Issue 3 -- Top-level permissions are overly broad [LOW]

**Severity**: LOW
**Category**: Security hygiene

The caller declares:
```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
  pages: write
```

The reusable workflow sets `permissions: {}` and scopes per-job, so the broad grants are effectively narrowed. However, `contents: write` and `pages: write` are unnecessary at the caller level. Best practice is to declare only what's needed:

```yaml
permissions:
  contents: read
  issues: write
  pull-requests: write
  id-token: write
```

### Issue 4 -- Runner label is a custom Blacksmith runner [INFO]

**Severity**: INFO
**Category**: Portability

All three jobs specify `runner: blacksmith-2vcpu-ubuntu-2404`. This is a custom runner (likely Blacksmith CI). The reusable workflow defaults to `ubuntu-latest`. If this workflow is forked or run in a different environment without Blacksmith runners, all jobs will hang waiting for a runner that never appears.

**Recommendation**: Document the runner requirement or make it configurable via `vars.RUNNER_LABEL`.

### Issue 5 -- 5 of 8 reusable secrets are not passed [INFO]

**Severity**: INFO
**Category**: Completeness

The reusable workflow accepts 8 optional secrets. The caller only passes 3 (`anthropic-api-key`, `sentry-token`, `datadog-api-key`). The missing 5 are:

| Secret | Used by |
|--------|---------|
| `posthog-api-key` | PostHog adapter |
| `axiom-token` | Axiom adapter |
| `axiom-org-id` | Axiom adapter |
| `datadog-app-key` | Datadog adapter |
| `langsmith-api-key` | LangSmith adapter |

Since all are `required: false` and the caller doesn't configure multi-provider modes, this is not a bug -- but it means the `observe-canary` and other jobs can only use Sentry and Datadog (partial) monitoring. The `providers` input defaults to `sentry` in the reusable workflow, so this is acceptable for the current use case.

### Issue 6 -- SHA pin is 2 commits behind HEAD [INFO]

**Severity**: INFO
**Category**: Maintenance

The pinned SHA `f62931b` is 2 commits behind the current HEAD (`a2ec443`):

```
a2ec443 Merge pull request #80 from YiAgent/chore/bump-after-79
ca8a3a6 chore(manifest): bump SHA after #79 (bot-id default)
f62931b Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults  <-- pinned
```

This is consistent with `manifest.yml` line 104, so it appears intentional (the manifest controls SHA bumps).

---

## Test Cases for Automation

### TC-01: YAML Syntax Validation
```
Input: observability.yml
Assert: yaml.safe_load() succeeds without exception
```

### TC-02: Reusable Workflow File Exists
```
Input: uses: reference in each job
Assert: .github/workflows/reusable-observability.yml exists locally
```

### TC-03: SHA Pin Is Valid Git Object
```
Input: SHA from uses: directive
Assert: git cat-file -t <SHA> returns "commit"
```

### TC-04: SHA Matches Manifest
```
Input: SHA from uses: directive
Assert: same SHA appears in manifest.yml
```

### TC-05: All Job Modes Match Reusable Workflow
```
Input: mode values passed in with: blocks
Assert: each mode is in {canary-watch, terraform-drift, verify-fix, post-deploy, canary}
```

### TC-06: workflow_dispatch Default Mode Has a Matching Job
```
Input: workflow_dispatch.inputs.mode.default value
Assert: at least one job's if: condition can be true for that default mode when event_name == 'workflow_dispatch'
Current: FAIL -- default "canary-watch" has no matching job on workflow_dispatch
```

### TC-07: Schedule Cron Expressions Are Valid
```
Input: cron values from schedule: trigger
Assert: each cron expression has 5 fields and valid ranges
Current: PASS -- "*/15 * * * *" and "0 4 * * *"
```

### TC-08: Concurrency Group Uses github.event_name
```
Input: concurrency.group expression
Assert: includes github.event_name to separate events
Current: PASS
```

### TC-09: All Secret References Use Correct Casing
```
Input: secrets: blocks in each job
Assert: secret names match UPPER_SNAKE convention (GitHub requirement)
Current: PASS -- ANTHROPIC_API_KEY, SENTRY_TOKEN, DD_API_KEY
```

### TC-10: workflow_run Target Workflow Exists by Name
```
Input: workflows: [prd]
Assert: a workflow file with name: prd exists
Current: PASS -- reusable-prd.yml has name: prd
```

### TC-11: Permissions Do Not Request Unused Scopes
```
Input: top-level permissions
Assert: each permission scope is used by at least one job
Current: WARN -- pages: write and contents: write are unused at caller level
```

### TC-12: repository_dispatch Event Type Filtered in Job Condition
```
Input: repository_dispatch types and job if: conditions
Assert: job conditions filter by github.event.action when repository_dispatch is used
Current: FAIL -- verify-fix triggers on any repository_dispatch, not just observe-window-complete
```

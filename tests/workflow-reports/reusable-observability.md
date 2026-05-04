# Workflow Test Report: reusable-observability.yml

**File**: `.github/workflows/reusable-observability.yml`
**Lines**: 907
**Tested**: 2026-05-04
**actionlint**: Not installed on test runner (manual review performed)

---

## Overview

This is a reusable workflow (`on: workflow_call`) that serves as a unified post-deploy observability entry point. It combines three legacy workflows into one mode-routed workflow with four distinct jobs:

| Job | Mode | Purpose | Timeout |
|-----|------|---------|---------|
| `canary-watch` | `canary-watch` | 3-sigma deviation detection on Sentry error rates | 5 min |
| `terraform-drift` | `terraform-drift` | Daily Terraform state drift detection | 30 min |
| `verify-fix` | `verify-fix` | Sentry-based verification after PR fix merges | 30 min |
| `multi-observe` | `post-deploy` / `canary` | Multi-provider observability with AI agent analysis | 20 min |

All jobs are advisory -- they file issues but never block deploys.

---

## Inputs/Secrets/Outputs Definition

### Inputs (24 total)

| Input | Type | Required | Default | Used By |
|-------|------|----------|---------|---------|
| `openci-ref` | string | false | `main` | All jobs |
| `runner` | string | false | `ubuntu-latest` | All jobs |
| `mode` | string | false | `""` | Router for all jobs |
| `infra-dir` | string | false | `infrastructure` | `terraform-drift` |
| `environment` | string | false | `production` | `multi-observe` |
| `providers` | string | false | `sentry` | `multi-observe` |
| `observe-window` | string | false | `30m` | `multi-observe` |
| `image-tag` | string | false | `""` | `multi-observe` |
| `thresholds-file` | string | false | `""` | `multi-observe` |
| `sentry-org` | string | false | `""` | `canary-watch`, `multi-observe` |
| `sentry-project` | string | false | `""` | `canary-watch`, `multi-observe` |
| `sentry-env` | string | false | `production` | `multi-observe` |
| `posthog-project-id` | string | false | `""` | `multi-observe` |
| `posthog-host` | string | false | `https://app.posthog.com` | `multi-observe` |
| `posthog-events` | string | false | `""` | `multi-observe` |
| `posthog-funnel-id` | string | false | `""` | `multi-observe` |
| `axiom-dataset` | string | false | `""` | `multi-observe` |
| `axiom-apl` | string | false | `""` | `multi-observe` |
| `datadog-site` | string | false | `datadoghq.com` | `multi-observe` |
| `datadog-service` | string | false | `""` | `multi-observe` |
| `datadog-env` | string | false | `production` | `multi-observe` |
| `datadog-queries` | string | false | `""` | `multi-observe` |
| `langsmith-project` | string | false | `""` | `multi-observe` |
| `langsmith-run-type` | string | false | `all` | `multi-observe` |
| `langsmith-eval-dataset` | string | false | `""` | `multi-observe` |

### Secrets (8 total, all optional)

| Secret | Used By |
|--------|---------|
| `sentry-token` | `canary-watch`, `verify-fix`, `multi-observe` |
| `anthropic-api-key` | `multi-observe` (agent stage) |
| `posthog-api-key` | `multi-observe` |
| `axiom-token` | `multi-observe` |
| `axiom-org-id` | `multi-observe` |
| `datadog-api-key` | `multi-observe` |
| `datadog-app-key` | `multi-observe` |
| `langsmith-api-key` | `multi-observe` |

### Outputs

None defined. The workflow does not declare any `outputs:` under `workflow_call`.

---

## Node-by-Node Status

### Top-Level Configuration

| Item | Status | Notes |
|------|--------|-------|
| `name:` | OK | `observability` |
| `on.workflow_call` | OK | Correctly defined with inputs and secrets |
| `permissions: {}` | OK | Empty at top level; per-job permissions override |
| `concurrency` | WARN | Uses `github.event.schedule`, `github.event.workflow_run.id`, `github.event.inputs.mode` -- all are dead refs in `workflow_call` context. The fallback to `inputs.mode` and then `github.run_id` makes this functionally safe, but the dead branches are confusing. |

### Job: `canary-watch`

| Item | Status | Notes |
|------|--------|-------|
| `if:` condition | WARN | Contains dead branches: `github.event_name == 'schedule'` and `github.event_name == 'workflow_dispatch'` can never be true in a `workflow_call` context. Only the `workflow_call && inputs.mode == 'canary-watch'` branch is live. |
| `runs-on` | OK | `${{ inputs.runner }}` |
| `timeout-minutes` | OK | 5 |
| `permissions` | OK | `contents: read`, `issues: write` |
| Step: harden-runner | OK | SHA `f808768d...` = `v2.17.0` |
| Step: checkout | OK | SHA `11bd7190...` = `v4.2.2` |
| Step: Resolve OpenCI ref | OK | Correctly handles explicit input vs workflow_ref parsing |
| Step: Checkout OpenCI | OK | Checks out `YiAgent/OpenCI` to `.openci/` |
| Step: Has recent deploy? | OK | Reads `vars.PRD_LAST_DEPLOY`, parses dates cross-platform (GNU/BSD) |
| Step: Fetch rates from Sentry | OK | Falls back gracefully when creds missing |
| Step: Run canary-watch atom | OK | Uses local action `./.openci/actions/prd/canary-watch` |

### Job: `terraform-drift`

| Item | Status | Notes |
|------|--------|-------|
| `if:` condition | WARN | Same dead-branch issue as `canary-watch` |
| `runs-on` | OK | `${{ inputs.runner }}` |
| `timeout-minutes` | OK | 30 |
| `permissions` | OK | Includes `id-token: write` for OIDC |
| `continue-on-error` | OK | `true` -- advisory job |
| Steps | OK | Same harden-runner + checkout + OpenCI ref pattern |
| Step: terraform-drift action | OK | Passes `infra-dir` with 3-level fallback (`inputs` -> `vars` -> default) |

### Job: `verify-fix`

| Item | Status | Notes |
|------|--------|-------|
| `if:` condition | WARN | `github.event_name == 'workflow_run'` is dead in `workflow_call` context. Also references `github.event.workflow_run.conclusion` which is unreachable. |
| `runs-on` | OK | `${{ inputs.runner }}` |
| `timeout-minutes` | OK | 30 |
| `permissions` | OK | `contents: read`, `issues: write`, `pull-requests: write` |
| Step: Find associated PR | WARN | Uses `github.event.workflow_run.head_sha` which is empty in `workflow_call` context. Falls back gracefully with notice. |
| Step: Wait 15 minutes | OK | Conditional on PR being found |
| Step: Verify fix action | OK | Uses local action |

### Job: `multi-observe`

| Item | Status | Notes |
|------|--------|-------|
| `if:` condition | OK | Correctly checks `workflow_call && inputs.mode` |
| `runs-on` | OK | `${{ inputs.runner || 'ubuntu-latest' }}` |
| `timeout-minutes` | OK | 20 |
| `permissions` | OK | `contents: read`, `issues: write`, `actions: write` |
| Stage 1: Collect | OK | 5 provider adapters, all `continue-on-error: true` |
| Stage 2: Normalize | OK | Python script merges metrics, evaluates thresholds |
| Stage 3: Agent | OK | Claude harness for incident analysis |
| Stage 4: Execute | OK | `actions/github-script` for incident creation, rollback dispatch |
| Step: Upload artifact | OK | SHA `ea165f8d...` = `v4.6.2` |
| Step: github-script | OK | SHA `60a0d830...` = `v7.0.1` |
| Step: Write summary | OK | Always runs, writes to `GITHUB_STEP_SUMMARY` |

---

## SHA Pinning Verification

| Action | SHA | Tag | Status |
|--------|-----|-----|--------|
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | v2.17.0 | OK |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 | OK |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` | v4.6.2 | OK |
| `actions/github-script` | `60a0d83039c74a4aee543508d2ffcb1c3799cdea` | v7.0.1 | OK |

All external actions are SHA-pinned. Local actions (`.openci/actions/...`) use path references, which is correct.

---

## Callers Analysis

### Caller: `.github/workflows/observability.yml`

**Triggers**: `workflow_run` (prd), `repository_dispatch`, `schedule` (2 crons), `workflow_dispatch`

**Jobs that call the reusable** (3):

| Caller Job | Mode Passed | Runner | Secrets Passed |
|------------|-------------|--------|----------------|
| `observe-canary` | `canary-watch` | `blacksmith-2vcpu-ubuntu-2404` | `anthropic-api-key`, `sentry-token`, `datadog-api-key` |
| `observe-drift` | `terraform-drift` | `blacksmith-2vcpu-ubuntu-2404` | `anthropic-api-key`, `sentry-token`, `datadog-api-key` |
| `verify-fix` | `verify-fix` | `blacksmith-2vcpu-ubuntu-2404` | `anthropic-api-key`, `sentry-token`, `datadog-api-key` |

**SHA used by caller**: `f62931bd0e2b73800512625a9fc5118557957ff3`

### Input/Secret Mismatch Analysis

**Inputs**: The caller passes `mode`, `runner`, and `infra-dir` (drift only). These all match the reusable's declared inputs. No mismatches.

**Secrets**: The caller passes 3 secrets. The reusable declares 8. The 5 unpassed secrets (`posthog-api-key`, `axiom-token`, `axiom-org-id`, `datadog-app-key`, `langsmith-api-key`) are all optional and only used by the `multi-observe` job, which is never triggered by the caller (no `post-deploy` or `canary` mode is dispatched). This is correct behavior.

**Missing caller job**: The caller has no job that dispatches `mode: post-deploy` or `mode: canary` to the `multi-observe` job. This means the `multi-observe` pipeline is only reachable via `workflow_dispatch` (manual) or if another workflow calls it.

---

## Issues Found

### HIGH

1. **Dead code paths in job `if:` conditions (lines 193-195, 342-344, 389-391)**
   The `github.event_name == 'schedule'` and `github.event_name == 'workflow_dispatch'` and `github.event_name == 'workflow_run'` branches in job conditions are unreachable when the workflow is invoked via `workflow_call`. In `workflow_call` context, `github.event_name` is always `"workflow_call"`. These dead branches add confusion and maintenance burden, though they do not cause runtime errors.

2. **`verify-fix` job references `github.event.workflow_run.head_sha` (line 434)**
   In `workflow_call` context, `github.event.workflow_run` is undefined. The step handles this gracefully (outputs a notice and skips), but the step can never produce a meaningful result when called as a reusable workflow. The `verify-fix` mode is effectively a no-op unless the caller forwards the correct SHA via an input -- which it does not.

### MEDIUM

3. **Concurrency group references unreachable event fields (lines 179-185)**
   The concurrency expression references `github.event.schedule`, `github.event.workflow_run.id`, and `github.event.inputs.mode`, all of which are empty/undefined in `workflow_call` context. The fallback chain (`inputs.mode || github.run_id`) prevents errors, but the dead references make the expression harder to reason about.

4. **No `outputs:` defined on the reusable workflow**
   The `multi-observe` job produces `has_violations`, `max_severity`, and `violations_count` step outputs, and writes a `metrics.json` artifact, but the reusable workflow does not expose any `workflow_call` outputs. Callers cannot programmatically react to observability results.

5. **`verify-fix` does not pass `head_sha` from caller**
   The caller (`observability.yml`) triggers `verify-fix` on `workflow_run` events where `github.event.workflow_run.head_sha` is available, but the reusable workflow accesses it via `github.event.workflow_run.head_sha` directly -- which is empty in `workflow_call` context. A `head-sha` input should be added to bridge this.

### LOW

6. **Caller uses hardcoded SHA for reusable reference (line 36)**
   The caller pins to `f62931bd0e2b73800512625a9fc5118557957ff3` which is a commit SHA, not a tag. This is secure but requires manual updates. The reusable's header comment suggests using `@v3`.

7. **Runner label mismatch**
   The caller uses `blacksmith-2vcpu-ubuntu-2404` while the reusable defaults to `ubuntu-latest`. This is intentional (caller overrides), but the comment in the reusable says "Defaults to ubuntu-latest for open-source compatibility" -- worth noting that production callers use a different runner.

8. **`multi-observe` job is unreachable from current caller**
   No caller job dispatches `mode: post-deploy` or `mode: canary`. The `multi-observe` pipeline (the most complex job) is only reachable via manual `workflow_dispatch` or a separate caller.

---

## Test Cases for Automation

### TC-1: YAML Syntax Validation
```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/reusable-observability.yml'))"
```
**Expected**: No exception raised.

### TC-2: Schema Validation -- `on.workflow_call` Structure
```
Assert: parsed['on']['workflow_call']['inputs'] exists and is a dict
Assert: parsed['on']['workflow_call']['secrets'] exists and is a dict
Assert: All inputs have 'type', 'required', 'default' keys
Assert: All secrets have 'required' key
```

### TC-3: Job Mode Routing -- Correct `if:` Conditions
```
For each job in [canary-watch, terraform-drift, verify-fix, multi-observe]:
  Assert: job['if'] contains 'workflow_call'
  Assert: job['if'] contains the expected mode string
```

### TC-4: SHA Pinning -- All External Actions Pinned
```
For each step with 'uses:' that does NOT start with './':
  Assert: uses value contains '@' followed by 40-char hex SHA
```

### TC-5: Secret References -- All Referenced Secrets Declared
```
Extract all secrets.X from expression interpolations
Assert: each is declared in on.workflow_call.secrets
```
**Findings to verify**: `secrets.sentry-token`, `secrets.anthropic-api-key`, `secrets.posthog-api-key`, `secrets.axiom-token`, `secrets.axiom-org-id`, `secrets.datadog-api-key`, `secrets.datadog-app-key`, `secrets.langsmith-api-key` -- all declared.

### TC-6: Input References -- All Referenced Inputs Declared
```
Extract all inputs.X from expression interpolations
Assert: each is declared in on.workflow_call.inputs
```

### TC-7: Permissions -- Job-Level Overrides Present
```
For each job:
  Assert: job['permissions'] is defined (top-level is empty {})
  Assert: 'contents: read' is present (least privilege)
```

### TC-8: Caller Compatibility -- Input Names Match
```
Parse caller observability.yml
For each 'with:' key in caller jobs:
  Assert: key exists in reusable's on.workflow_call.inputs
For each 'secrets:' key in caller jobs:
  Assert: key exists in reusable's on.workflow_call.secrets
```

### TC-9: Artifact Upload Presence
```
Assert: multi-observe job has a step using actions/upload-artifact
Assert: upload step has 'if: always()' to ensure metrics are always captured
```

### TC-10: Harden-Runner Present in All Jobs
```
For each job:
  Assert: first step uses step-security/harden-runner
  Assert: egress-policy is set to 'audit'
```

### TC-11: `continue-on-error` on Advisory Jobs
```
Assert: terraform-drift job has continue-on-error: true
Assert: multi-observe adapter steps have continue-on-error: true
```

### TC-12: `multi-observe` Agent Stage Guard Condition
```
Assert: agent step's 'if' checks normalize.outputs.has_violations or mode == 'canary'
Assert: execute step's 'if' is 'always()'
Assert: read-plan step's 'if' is 'always()'
```

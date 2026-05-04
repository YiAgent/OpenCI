# Workflow Test Report: issue-ops.yml

**File:** `.github/workflows/issue-ops.yml`
**Tested:** 2026-05-04
**Tools:** actionlint v1.7.7, Python yaml.safe_load, manual analysis

---

## Overview

`issue-ops.yml` is a thin event-routing entrypoint for the issue agent domain. It does not contain any build steps itself -- it fans out to a single reusable workflow (`reusable-issue.yml`) across four jobs, each gated by event type. The reusable workflow handles a multi-stage pipeline: ingest, enrich, agent planning, and guarded execution.

**Summary verdict: PASS with observations.** No syntax errors, no actionlint violations, all references resolve. One SHA staleness observation and several design notes below.

---

## Node-by-Node Status

### 1. Trigger Events (`on:`)

| Trigger | Status | Notes |
|---------|--------|-------|
| `issues` (opened, reopened, edited, closed) | PASS | Standard issue lifecycle events |
| `issue_comment` (created) | PASS | Enables @-mention agent response |
| `schedule` (cron `0 2 * * *`) | PASS | Daily at 02:00 UTC for maintenance |
| `repository_dispatch` (linear-issue-started, sentry-issue) | PASS | External webhook integration |
| `workflow_dispatch` (mode, model inputs) | PASS | Manual trigger with choice/string inputs |

**Observation:** Python's `yaml.safe_load` parses `on:` as boolean `true` (a known YAML 1.1 quirk). GitHub Actions handles this correctly -- not a bug, but worth noting if parsing workflows programmatically.

### 2. Permissions

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
  actions: read
```

| Permission | Required By | Status |
|-----------|-------------|--------|
| `contents: write` | `execute` job (creates branches, pushes) | PASS |
| `issues: write` | `maintenance`, `ingest`, `execute` jobs | PASS |
| `pull-requests: write` | `execute` job | PASS |
| `id-token: write` | `agent` job (OIDC for Claude API) | PASS |
| `actions: read` | Artifact download in `enrich`/`agent` | PASS |

**Observation:** These are top-level permissions inherited by all jobs. The reusable workflow's individual jobs narrow their own permissions via `permissions:` at the job level, which is the correct pattern. However, `contents: write` and `pull-requests: write` are granted to the `lifecycle` and `maintenance` jobs that only need `issues: write`. The reusable workflow's job-level permissions override this, so no actual over-privilege occurs at runtime.

### 3. Concurrency

```yaml
concurrency:
  group: issue-ops-${{ github.event.issue.number || github.event.client_payload.id || github.run_id }}
  cancel-in-progress: false
```

| Aspect | Status | Notes |
|--------|--------|-------|
| Group key resolution | PASS | Falls through: issue number -> client_payload.id -> run_id |
| cancel-in-progress: false | PASS | Conservative; queued runs wait rather than cancel |
| Schedule collision | NOTE | Schedule runs use `github.run_id` (always unique), so no grouping for cron |

**Observation:** For `repository_dispatch` events without `client_payload.id`, the expression would fall through to `github.run_id`, effectively disabling concurrency grouping. This is safe but worth documenting for external dispatchers.

### 4. Jobs

#### 4.1 `lifecycle` Job

| Aspect | Value | Status |
|--------|-------|--------|
| Condition | `github.event_name == 'issues' \|\| github.event_name == 'issue_comment'` | PASS |
| Reusable workflow | `YiAgent/OpenCI/.github/workflows/reusable-issue.yml@f62931bd...` | PASS |
| Mode | `lifecycle` | PASS |
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS (custom runner) |
| Model | `${{ vars.AI_MODEL || '' }}` | PASS |
| Secrets passed | 6 (all optional) | PASS |

**Observation:** `workflow_dispatch` with `mode: lifecycle` does NOT trigger this job (falls to `manual` instead). This is correct by design -- the `manual` job handles all `workflow_dispatch` events except `maintenance`.

#### 4.2 `ingest` Job

| Aspect | Value | Status |
|--------|-------|--------|
| Condition | `github.event_name == 'repository_dispatch'` | PASS |
| Reusable workflow | Same SHA | PASS |
| Mode | `ingest` | PASS |
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS |

No issues.

#### 4.3 `maintenance` Job

| Aspect | Value | Status |
|--------|-------|--------|
| Condition | `github.event_name == 'schedule' \|\| (github.event_name == 'workflow_dispatch' && inputs.mode == 'maintenance')` | PASS |
| Reusable workflow | Same SHA | PASS |
| Mode | `maintenance` | PASS |
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS |

No issues.

#### 4.4 `manual` Job

| Aspect | Value | Status |
|--------|-------|--------|
| Condition | `github.event_name == 'workflow_dispatch' && inputs.mode != 'maintenance'` | PASS |
| Reusable workflow | Same SHA | PASS |
| Mode | `${{ inputs.mode }}` | PASS |
| Model | `${{ inputs.model \|\| vars.AI_MODEL \|\| '' }}` | PASS |

**Observation:** This job has a richer model fallback chain (`inputs.model || vars.AI_MODEL || ''`) compared to the other three jobs (`vars.AI_MODEL || ''`). This is correct -- manual dispatch allows the operator to override the model.

### 5. SHA References

| SHA | Object Type | Commit Message | Status |
|-----|------------|----------------|--------|
| `f62931bd0e2b73800512625a9fc5118557957ff3` | commit | "Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults" | PASS (exists) |

**SHA staleness:** The referenced SHA (`f62931b`) is 2 commits behind current HEAD (`5a278f0` / `a2ec443`). The manifest.yml at HEAD still references `f62931bd`, and the latest commit (`5a278f0`) bumps the manifest to `a2ec4435`. This means issue-ops.yml is consistent with the manifest at commit `1536450` but is behind the latest manifest update. **Not a bug** -- the SHA is valid and the reusable workflow at that ref is functional. The bump to `a2ec4435` would be a separate update PR.

**Consistency check:** All four jobs use the identical SHA `f62931bd...`, which is correct. No mixed SHA references.

### 6. Reusable Workflow Resolution

| Reference | Local File Exists | Status |
|-----------|------------------|--------|
| `YiAgent/OpenCI/.github/workflows/reusable-issue.yml@f62931bd...` | `.github/workflows/reusable-issue.yml` exists at HEAD | PASS |

The reusable workflow file exists locally. At runtime, GitHub resolves the `@SHA` reference against the remote `YiAgent/OpenCI` repository, not the local file. The local file serves as the development copy.

**Reusable workflow interface match:**

| Input | Passed by issue-ops.yml | Declared in reusable | Match |
|-------|------------------------|---------------------|-------|
| `mode` | Yes (per-job string) | Yes (string, default: lifecycle) | PASS |
| `runner` | Yes (`blacksmith-2vcpu-ubuntu-2404`) | Yes (string, default: ubuntu-latest) | PASS |
| `model` | Yes (per-job expression) | Yes (string, default: "") | PASS |
| `openci-ref` | No | Yes (string, default: main) | PASS (optional, uses default) |
| `issue-stale-days` | No | Yes (number, default: 60) | PASS (optional) |
| `issue-close-days` | No | Yes (number, default: 14) | PASS (optional) |
| `pr-stale-days` | No | Yes (number, default: 30) | PASS (optional) |
| `pr-close-days` | No | Yes (number, default: 7) | PASS (optional) |
| `lock-after-days` | No | Yes (number, default: 30) | PASS (optional) |

All secrets are passed through correctly. The reusable workflow declares all 6 secrets as `required: false`.

### 7. Secret References

| Secret | Passed | Required by Reusable | Status |
|--------|--------|---------------------|--------|
| `ANTHROPIC_API_KEY` | Yes | No (optional) | PASS |
| `ANTHROPIC_BASE_URL` | Yes | No (optional) | PASS |
| `SENTRY_TOKEN` | Yes | No (optional) | PASS |
| `LINEAR_TOKEN` | Yes | No (optional) | PASS |
| `SLACK_WEBHOOK_URL` | Yes | No (optional) | PASS |
| `MCP_DISPATCH_TOKEN` | Yes | No (optional) | PASS |

### 8. Variable References

| Variable | Context | Status |
|----------|---------|--------|
| `vars.AI_MODEL` | Model selection fallback | PASS |
| `inputs.mode` | workflow_dispatch mode selection | PASS |
| `inputs.model` | workflow_dispatch model override | PASS |

### 9. Runner Labels

All four jobs specify `runner: blacksmith-2vcpu-ubuntu-2404`. This is a custom Blacksmith runner label (a third-party GitHub Actions runner service). The reusable workflow defaults to `ubuntu-latest` if no runner is provided, so the override is intentional.

**Observation:** If the Blacksmith runner pool is unavailable or the label is misconfigured, all four jobs will fail with a runner resolution error. The reusable workflow's default of `ubuntu-latest` provides a safe fallback if the caller omits the runner input.

---

## Issues Found

### No CRITICAL or HIGH issues.

### MEDIUM

| # | Issue | Details | Recommendation |
|---|-------|---------|----------------|
| M1 | SHA is 2 commits behind HEAD | `f62931b` is behind `a2ec443` (the current manifest SHA). The bump commit `5a278f0` updates the manifest but issue-ops.yml still references the old SHA. | Update SHA to `a2ec4435` in a coordinated manifest-bump PR. Functional but stale. |
| M2 | Broad top-level permissions | `contents: write` and `pull-requests: write` are granted at workflow level but only needed by the `execute` stage. The reusable workflow's job-level permissions override this, so no runtime over-privilege occurs. | Consider moving to job-level permissions in the reusable workflow (already done) -- no action needed here. |

### LOW

| # | Issue | Details | Recommendation |
|---|-------|---------|----------------|
| L1 | YAML `on:` parsed as boolean | Python's `yaml.safe_load` converts `on:` to `{true: ...}`. GitHub Actions handles this correctly. | Use `yaml.safe_load` with a custom constructor if programmatic parsing is needed. |
| L2 | No `workflow_dispatch` mode=lifecycle routing to `lifecycle` job | `workflow_dispatch` with `mode: lifecycle` routes to `manual`, not `lifecycle`. The `lifecycle` job only fires on `issues`/`issue_comment` events. | This is by design. Document if confusing to operators. |
| L3 | Blacksmith runner dependency | All jobs depend on `blacksmith-2vcpu-ubuntu-2404`. If the Blacksmith service is down, the workflow cannot run. | Consider adding a fallback runner or documenting the dependency. |

---

## Test Cases for Automation

### Trigger Validation

| TC | Test Case | Trigger | Expected Job(s) | Expected Mode |
|----|-----------|---------|-----------------|---------------|
| T1 | New issue opened | `issues: opened` | `lifecycle` | lifecycle |
| T2 | Issue comment created | `issue_comment: created` | `lifecycle` | lifecycle |
| T3 | Issue edited | `issues: edited` | `lifecycle` | lifecycle |
| T4 | Issue closed | `issues: closed` | `lifecycle` | lifecycle |
| T5 | Daily schedule | `schedule` (cron) | `maintenance` | maintenance |
| T6 | Sentry webhook dispatch | `repository_dispatch: sentry-issue` | `ingest` | ingest |
| T7 | Linear webhook dispatch | `repository_dispatch: linear-issue-started` | `ingest` | ingest |
| T8 | Manual dispatch (lifecycle) | `workflow_dispatch` mode=lifecycle | `manual` | lifecycle |
| T9 | Manual dispatch (ingest) | `workflow_dispatch` mode=ingest | `manual` | ingest |
| T10 | Manual dispatch (maintenance) | `workflow_dispatch` mode=maintenance | `maintenance` | maintenance |
| T11 | Manual dispatch (custom model) | `workflow_dispatch` mode=lifecycle, model=glm-4-flash | `manual` | lifecycle (with model override) |

### Conditional Logic

| TC | Test Case | Condition | Expected |
|----|-----------|-----------|----------|
| T12 | Only one job fires per event | `issues` event | `lifecycle` runs; `ingest`, `maintenance`, `manual` skipped |
| T13 | No job fires for irrelevant event | `push` event | No jobs run (workflow not triggered) |
| T14 | Maintenance excludes non-maintenance dispatch | `workflow_dispatch` mode=lifecycle | `maintenance` skipped, `manual` runs |
| T15 | Manual excludes maintenance | `workflow_dispatch` mode=maintenance | `manual` skipped, `maintenance` runs |

### Concurrency

| TC | Test Case | Scenario | Expected |
|----|-----------|----------|----------|
| T16 | Concurrent issue events queue | Two rapid edits on issue #42 | Second run queued (cancel-in-progress: false) |
| T17 | Different issues don't conflict | Issue #42 and #43 triggered simultaneously | Both run in parallel (different concurrency groups) |
| T18 | Schedule runs are unique | Two scheduled runs | Both run (github.run_id is unique) |

### Secrets and Variables

| TC | Test Case | Scenario | Expected |
|----|-----------|----------|----------|
| T19 | Missing ANTHROPIC_API_KEY | Secret not set | Reusable workflow handles gracefully (optional) |
| T20 | vars.AI_MODEL set | Variable configured | Model passed to reusable workflow |
| T21 | vars.AI_MODEL unset | Variable not configured | Empty string passed; reusable workflow uses its default |
| T22 | Manual model override | inputs.model=glm-4-flash | Model override takes precedence over vars.AI_MODEL |

### SHA and Reference Integrity

| TC | Test Case | Check | Expected |
|----|-----------|-------|----------|
| T23 | SHA exists in remote | Verify `f62931bd...` is a valid commit in YiAgent/OpenCI | Commit exists |
| T24 | All 4 jobs use same SHA | Compare SHA across all `uses:` lines | Identical SHA |
| T25 | Reusable workflow file exists at SHA | Check `.github/workflows/reusable-issue.yml` at the pinned SHA | File exists and is valid YAML |
| T26 | Input types match | Verify `with:` values match reusable workflow's `inputs:` schema | All types compatible |

---

## actionlint Output

```
(no output -- clean pass)
```

## YAML Validation

```
YAML VALID -- python3 yaml.safe_load() succeeded without error
```

## Manifest Consistency

The SHA `f62931bd0e2b73800512625a9fc5118557957ff3` matches the `YiAgent/OpenCI` entry in `manifest.yml` at commit `1536450`. A newer manifest bump (`5a278f0`) updates this to `a2ec4435`, which has not yet been applied to issue-ops.yml. This is a normal lag in the bump workflow and not a defect.

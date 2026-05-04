# Workflow Test Report: reusable-issue.yml

**File:** `.github/workflows/reusable-issue.yml`
**Test Date:** 2026-05-04
**Tester:** Automated analysis

---

## Overview

`reusable-issue.yml` is a reusable workflow (`workflow_call`) implementing a 4-stage agent-driven issue orchestrator pipeline:

| Stage | Job | Purpose |
|-------|-----|---------|
| Stage 1 | `maintenance` | Stale issue/PR cleanup + scheduled follow-ups (conditional) |
| Stage 1 | `Ingest` | Deterministic issue management + normalized payload (conditional) |
| Stage 2 | `enrich` | Merges shared/domain agent workspace |
| Stage 3 | `agent` | Claude returns `issue-action-plan/v1` |
| Stage 4 | `execute` | Guarded allowlisted mutations + audit trail |

The `maintenance` and `ingest` jobs are mutually exclusive based on the `mode` input. The `enrich` -> `agent` -> `execute` chain runs only for non-maintenance modes.

---

## Inputs/Secrets/Outputs Definition

### Inputs (9 total, all optional with defaults)

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `openci-ref` | string | `main` | OpenCI ref to vendor for `./.openci` references |
| `runner` | string | `ubuntu-latest` | Runner label for all jobs |
| `mode` | string | `lifecycle` | `lifecycle` \| `maintenance` \| `ingest` |
| `model` | string | `""` | Override AI model name |
| `issue-stale-days` | number | `60` | Days before issue is marked stale |
| `issue-close-days` | number | `14` | Days before stale issue is closed |
| `pr-stale-days` | number | `30` | Days before PR is marked stale |
| `pr-close-days` | number | `7` | Days before stale PR is closed |
| `lock-after-days` | number | `30` | Days before thread is locked |

### Secrets (6 total, all optional)

| Secret | Used In |
|--------|---------|
| `anthropic-api-key` | `agent` job (Claude harness) |
| `api-base-url` | `agent` job (Claude harness) |
| `sentry-token` | `enrich` job (workspace build) |
| `linear-token` | `enrich` job (workspace build), `execute` job |
| `slack-webhook-url` | `execute` job (notify webhook) |
| `mcp-dispatch-token` | `execute` job (MCP dispatch) |

### Outputs

**None defined.** The reusable workflow does not expose any `workflow_call.outputs`. Job-level outputs (`ingest-json`, `issue-number`, `plan-subject`, `action-plan`, `reasoning`, `plan-hash`, `workspace-artifact`) are used internally between jobs but not surfaced to callers.

---

## Node-by-Node Status

### Top-Level Configuration

| Property | Value | Status |
|----------|-------|--------|
| `name` | `issue` | OK |
| `on.workflow_call` | Present | OK |
| `permissions` | `{}` (empty) | OK -- per-job permissions override |
| `concurrency` | `issue-${{ ... }}` | WARN -- see issues below |

### Job: `maintenance`

| Property | Value | Status |
|----------|-------|--------|
| Condition | `inputs.mode == 'maintenance' \|\| inputs.mode == 'stale'` | WARN -- `stale` is not a selectable mode in the caller |
| Runner | `${{ inputs.runner }}` | OK |
| Timeout | 30 min | OK |
| Permissions | `contents: read`, `issues: write`, `pull-requests: write` | OK |
| Steps | 4 steps | OK |

**Steps:**

1. `step-security/harden-runner@f808768d...` -- OK, SHA-pinned
2. `actions/stale@b5d41d4e...` -- OK, all input mappings correct
3. `dessant/lock-threads@7266a7ce...` -- OK
4. `actions/github-script@60a0d830...` -- OK, follow-up processing logic

### Job: `ingest`

| Property | Value | Status |
|----------|-------|--------|
| Condition | `inputs.mode != 'maintenance' && inputs.mode != 'stale'` | OK |
| Runner | `${{ inputs.runner }}` | OK |
| Timeout | 10 min | OK |
| Permissions | `contents: read`, `issues: write` | OK |
| Outputs | `ingest-json`, `issue-number`, `plan-subject` | OK |
| Steps | 7 steps | OK |

**Steps:**

1. `step-security/harden-runner` -- OK
2. `actions/checkout` (caller repo) -- OK, SHA-pinned
3. `actions/checkout` (OpenCI repo) -- OK, refs `${{ inputs.openci-ref }}`
4. `stefanbuck/github-issue-parser@cb6e9715...` -- OK, `continue-on-error: true`
5. `redhat-plumbers-in-action/advanced-issue-labeler@b80ae64e...` (area) -- OK
6. `redhat-plumbers-in-action/advanced-issue-labeler@b80ae64e...` (severity) -- OK
7. `Collect duplicate candidates` -- bash script from `.openci/` path
8. `Pack ingest payload` -- bash script from `.openci/` path
9. `actions/upload-artifact` -- OK, SHA-pinned

### Job: `enrich`

| Property | Value | Status |
|----------|-------|--------|
| `needs` | `ingest` | OK |
| Runner | `${{ inputs.runner }}` | OK |
| Timeout | 10 min | OK |
| Permissions | `contents: read`, `issues: read`, `actions: read` | OK |
| Outputs | `workspace-artifact` | OK |
| Steps | 6 steps | OK |

**Steps:**

1. `step-security/harden-runner` -- OK
2. `actions/checkout` (caller repo) -- OK
3. `actions/checkout` (OpenCI repo) -- OK
4. `actions/download-artifact` -- OK, matches upload name pattern
5. `Build merged agent workspace` -- bash script, uses `secrets.linear-token` / `secrets.sentry-token` presence checks
6. `actions/upload-artifact` -- OK

### Job: `agent`

| Property | Value | Status |
|----------|-------|--------|
| `needs` | `[ingest, enrich]` | OK |
| Runner | `${{ inputs.runner }}` | OK |
| Timeout | 15 min | OK |
| Permissions | `contents: read`, `issues: read`, `actions: read`, `id-token: write` | OK |
| Outputs | `action-plan`, `reasoning`, `plan-hash` | OK |
| Steps | 6 steps | OK |

**Steps:**

1. `step-security/harden-runner` -- OK
2. `actions/checkout` (caller repo) -- OK
3. `actions/checkout` (OpenCI repo) -- OK
4. `actions/download-artifact` -- OK
5. `api-key-gate` (local action) -- OK, gates on `anthropic-api-key`
6. `claude-harness` (local action) -- OK, conditionally skipped
7. `extract-plan` (local action) -- OK

**Note:** `id-token: write` permission is declared but not visibly used by any step. May be required by local actions internally.

### Job: `execute`

| Property | Value | Status |
|----------|-------|--------|
| `needs` | `[ingest, enrich, agent]` | OK |
| Runner | `${{ inputs.runner }}` | OK |
| Timeout | 10 min | OK |
| Permissions | `contents: write`, `issues: write`, `pull-requests: write` | OK |
| Steps | 4 steps | OK |

**Steps:**

1. `step-security/harden-runner` -- OK
2. `actions/download-artifact` -- OK
3. `actions/checkout` (OpenCI repo) -- OK
4. `execute-plan` (local action) -- OK, receives action-plan, plan-hash, issue-number, etc.

---

## SHA Reference Audit

### External Actions (9 unique, all SHA-pinned)

| Action | SHA | Status |
|--------|-----|--------|
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | OK |
| `actions/stale` | `b5d41d4e1d5dceea10e7104786b73624c18a190f` | OK |
| `dessant/lock-threads` | `7266a7ce5c1df01b1c6db85bf8cd86c737dadbe7` | OK |
| `actions/github-script` | `60a0d83039c74a4aee543508d2ffcb1c3799cdea` | OK |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | OK |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` | OK |
| `actions/download-artifact` | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | OK |
| `stefanbuck/github-issue-parser` | `cb6e97157cbf851e3a393ff8d57c93a484cc323f` | OK |
| `redhat-plumbers-in-action/advanced-issue-labeler` | `b80ae64e3e156e9c111b075bfa04b295d54e8e2e` | OK |

All external actions are SHA-pinned (no mutable tag references). This is a security best practice.

### Local Actions (4, via `.openci/` checkout)

| Action | Path | Status |
|--------|------|--------|
| `api-key-gate` | `.openci/actions/_common/api-key-gate` | OK |
| `claude-harness` | `.openci/actions/_common/claude-harness` | OK |
| `extract-plan` | `.openci/actions/issue/extract-plan` | OK |
| `execute-plan` | `.openci/actions/issue/execute-plan` | OK |

These are resolved via the OpenCI checkout at `${{ inputs.openci-ref }}`, not via SHA pinning. The security boundary is the `openci-ref` input (defaults to `main`).

### Bash Scripts (3, via `.openci/` checkout)

| Script | Stage |
|--------|-------|
| `.openci/actions/issue/collect-duplicates/collect-duplicates.sh` | Ingest |
| `.openci/actions/issue/pack-ingest/pack-ingest.sh` | Ingest |
| `.openci/actions/issue/build-workspace/build-workspace.sh` | Enrich |

---

## Callers Analysis

### Single Caller: `issue-ops.yml`

All 4 jobs in `issue-ops.yml` reference the reusable workflow at:
```
YiAgent/OpenCI/.github/workflows/reusable-issue.yml@f62931bd0e2b73800512625a9fc5118557957ff3
```

**SHA Status:** `f62931bd0e2b73800512625a9fc5118557957ff3` resolves to commit `f62931b` (Merge PR #79). Current HEAD is `a2ec443` (2 commits ahead). The caller SHA is stale -- it references a commit from before the most recent merges.

### Caller Jobs vs Reusable Inputs Mapping

| Caller Job | `mode` | `runner` | `model` | Condition |
|------------|--------|----------|---------|-----------|
| `lifecycle` | `lifecycle` | `blacksmith-2vcpu-ubuntu-2404` | `${{ vars.AI_MODEL \|\| '' }}` | `issues` or `issue_comment` events |
| `ingest` | `ingest` | `blacksmith-2vcpu-ubuntu-2404` | `${{ vars.AI_MODEL \|\| '' }}` | `repository_dispatch` events |
| `maintenance` | `maintenance` | `blacksmith-2vcpu-ubuntu-2404` | `${{ vars.AI_MODEL \|\| '' }}` | `schedule` or `workflow_dispatch` with `mode == 'maintenance'` |
| `manual` | `${{ inputs.mode }}` | `blacksmith-2vcpu-ubuntu-2404` | `${{ inputs.model \|\| vars.AI_MODEL \|\| '' }}` | `workflow_dispatch` with `mode != 'maintenance'` |

### Secrets Mapping (all 4 caller jobs pass the same set)

| Caller Secret | Reusable Secret |
|---------------|-----------------|
| `secrets.ANTHROPIC_API_KEY` | `anthropic-api-key` |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` |
| `secrets.SENTRY_TOKEN` | `sentry-token` |
| `secrets.LINEAR_TOKEN` | `linear-token` |
| `secrets.SLACK_WEBHOOK_URL` | `slack-webhook-url` |
| `secrets.MCP_DISPATCH_TOKEN` | `mcp-dispatch-token` |

**Match status:** All 6 reusable secrets are passed by all 4 caller jobs. No missing or extra secrets.

### Inputs Not Passed by Caller

The following reusable inputs are never explicitly set by `issue-ops.yml` (they rely on defaults):

- `openci-ref` (default: `main`)
- `issue-stale-days` (default: `60`)
- `issue-close-days` (default: `14`)
- `pr-stale-days` (default: `30`)
- `pr-close-days` (default: `7`)
- `lock-after-days` (default: `30`)

This is acceptable since all have sensible defaults, but it means the caller cannot tune stale/close behavior without modifying the reusable workflow.

---

## Issues Found

### [WARN-1] Concurrency group references `github.event.*` in reusable context

**Location:** Lines 69-77

```yaml
concurrency:
  group: >-
    issue-${{
      github.event.issue.number
      || github.event.client_payload.id
      || github.event.schedule
      || github.run_id
    }}
  cancel-in-progress: ${{ github.event_name == 'issues' }}
```

**Problem:** In a `workflow_call` context, `github.event` reflects the **caller's** event, not the callee's. While this works because the caller's event fields are propagated, the `cancel-in-progress` condition `github.event_name == 'issues'` will be evaluated as a string comparison in the callee context. The expression evaluates correctly (`'issues' == 'issues'` is truthy), but the design couples the reusable workflow's concurrency behavior to the caller's event type. If a different caller invokes this workflow with a different event, cancellation semantics may be unexpected.

**Risk:** Medium. Works correctly with current sole caller but fragile for reuse.

### [WARN-2] `mode: stale` handled in conditions but not exposed as input option

**Location:** Line 82, 167

The `maintenance` job condition is `inputs.mode == 'maintenance' || inputs.mode == 'stale'`, and the `ingest` condition excludes both. However, the `mode` input has no documentation of `stale` as a valid value (description says "lifecycle | maintenance | ingest"), and the caller never passes `stale`.

**Risk:** Low. Dead code path -- `stale` mode is unreachable from any current caller.

### [WARN-3] Caller SHA is stale

**Location:** `issue-ops.yml` lines 40, 55, 70, 85

All 4 jobs reference `@f62931bd0e2b73800512625a9fc5118557957ff3` (commit `f62931b`, PR #79 merge). Current HEAD is `a2ec443` (2 commits ahead: `ca8a3a6` chore/manifest bump, `a2ec443` merge PR #80).

**Risk:** Medium. The caller pins to an older version. If the reusable workflow has changed since `f62931b`, the caller will use the stale version. This is by design (SHA pinning for reproducibility) but should be bumped after workflow changes.

### [INFO-4] `id-token: write` in `agent` job -- unused by visible steps

**Location:** Line 311

The `agent` job declares `id-token: write` permission, but no visible step uses OIDC tokens. The local actions (`api-key-gate`, `claude-harness`, `extract-plan`) may require this internally.

**Risk:** Low. Likely needed by `claude-harness` for Anthropic API authentication or similar.

### [INFO-5] `openci-ref` defaults to `main` -- mutable reference

**Location:** Line 17

The `openci-ref` input defaults to `main`, which means local actions and bash scripts are resolved from the `main` branch at runtime. This is mutable -- a push to `main` changes behavior for all in-flight workflows. However, the caller overrides this implicitly (it uses `main` default) and could pin to a SHA if needed.

**Risk:** Low. Intentional design for development velocity.

### [INFO-6] Model default is empty string, resolved at usage site

**Location:** Lines 30-32, 351

The `model` input defaults to `""`. At the usage site (line 351), it is resolved as `${{ inputs.model || 'claude-sonnet-4-5-20250929' }}`. This means the default model is `claude-sonnet-4-5-20250929` unless overridden.

**Risk:** None. Clean fallback pattern.

### [INFO-7] No `workflow_call.outputs` defined

The reusable workflow defines job-level outputs but does not expose any at the `workflow_call` level. Callers cannot access `action-plan`, `issue-number`, or other artifacts from the reusable workflow.

**Risk:** Low. The `issue-ops.yml` caller does not need outputs (it's a fire-and-forget orchestrator), but other potential callers might.

---

## Test Cases for Automation

### TC-1: YAML Syntax Validation
- **Input:** Parse file with `yaml.safe_load()`
- **Expected:** No exceptions
- **Status:** PASS

### TC-2: Actionlint Validation
- **Input:** Run `actionlint` on file
- **Expected:** No errors or warnings
- **Status:** SKIP (actionlint not installed)

### TC-3: All External Actions SHA-Pinned
- **Input:** Extract all `uses:` references matching `*@` pattern
- **Expected:** All match 40-char hex SHA
- **Status:** PASS -- 9/9 actions SHA-pinned

### TC-4: Caller Secrets Match Reusable Secrets
- **Input:** Compare secrets defined in `workflow_call.secrets` with secrets passed in `issue-ops.yml`
- **Expected:** Exact match (no missing, no extra)
- **Status:** PASS -- all 6 secrets match

### TC-5: Caller Inputs Match Reusable Inputs
- **Input:** Compare inputs passed in `issue-ops.yml` with defined `workflow_call.inputs`
- **Expected:** All passed inputs exist in definition; unpassed inputs have defaults
- **Status:** PASS -- 3 inputs passed (`mode`, `runner`, `model`), 6 rely on defaults

### TC-6: Job Dependency Chain Integrity
- **Input:** Verify `needs:` references resolve to existing job names
- **Expected:** `enrich` -> `ingest`, `agent` -> `[ingest, enrich]`, `execute` -> `[ingest, enrich, agent]`
- **Status:** PASS

### TC-7: Mutual Exclusivity of `maintenance` and `ingest`
- **Input:** Check conditional logic for overlapping mode values
- **Expected:** No mode triggers both jobs simultaneously
- **Status:** PASS -- `maintenance` checks `==` for `maintenance`/`stale`; `ingest` checks `!=` for both

### TC-8: Artifact Name Consistency
- **Input:** Verify upload/download artifact names match across jobs
- **Expected:** `ingest` uploads `issue-ingest-${{ github.run_id }}`, `enrich` downloads same
- **Status:** PASS

### TC-9: Concurrency Group Expression Validity
- **Input:** Verify all `${{ }}` expressions in concurrency group are syntactically valid
- **Expected:** No unresolved references
- **Status:** PASS (expressions are valid, though behavior in reusable context is coupled to caller)

### TC-10: Permission Escalation Check
- **Input:** Compare top-level `permissions: {}` with per-job permissions
- **Expected:** No job requests permissions beyond what the caller grants
- **Status:** PASS -- top-level is empty, per-job scopes are appropriate

### TC-11: Runner Label Injection
- **Input:** Verify `${{ inputs.runner }}` is used safely without string interpolation in `run:` blocks
- **Expected:** Runner label only appears in `runs-on:` contexts
- **Status:** PASS -- `inputs.runner` is only referenced in `runs-on:` fields

### TC-12: Secret Exposure in Logs
- **Input:** Check that secrets are only passed via `with:` or `env:` to trusted actions/scripts, never in `run:` echo statements
- **Expected:** No `echo $SECRET` patterns
- **Status:** PASS -- secrets are passed to actions via `with:` parameters or `env:` with descriptive names

---

## Summary

| Category | Count |
|----------|-------|
| Total Issues | 7 |
| CRITICAL | 0 |
| HIGH | 0 |
| WARN | 3 |
| INFO | 4 |
| Test Cases | 12 |
| Tests PASS | 11 |
| Tests SKIP | 1 (actionlint unavailable) |

**Overall Assessment:** The reusable workflow is well-structured with proper SHA pinning, appropriate per-job permissions, clean conditional logic, and correct artifact passing. The 3 warnings are non-blocking: concurrency coupling (fragile for multi-caller reuse), unreachable `stale` mode code path, and stale caller SHA reference. No critical or high-severity issues found.

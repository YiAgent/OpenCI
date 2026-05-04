# Workflow Test Report: reusable-pr.yml

**Generated:** 2026-05-04
**File:** `.github/workflows/reusable-pr.yml`
**Lines:** 930
**Jobs:** 19

---

## Overview

`reusable-pr.yml` is a reusable workflow (`workflow_call`) that implements the PR quality gate for the OpenCI platform. It defines a multi-stage pipeline: Stage 1 (Gate) runs deterministic checks fan-out from `preflight` + `detect-language`; Stage 2 (Enrich) builds agent workspace from gate results; Stage 3 (Agent) runs AI-powered PR review; Stage 4 (Execute) posts results and executes allowlisted actions.

**Stage structure:**
- Stage 1 (Gate): preflight, detect-language, auto-label, auto-assign-fallback, validate-pr-title, validate-pr-desc, scan-deps, scan-secrets, scan-sonarcloud, verify-sha, lint, test, coverage, build-check, ai-review, eval-prompt, copilot-review
- Stage 2 (Enrich): enrich
- Stage 3 (Agent): agent
- Stage 4 (Execute): execute

**Required checks (block merge):** lint, test, scan-deps, validate-pr-title, validate-pr-desc, build-check
**Advisory checks (don't block):** coverage, scan-secrets, scan-sonarcloud, ai-review, eval-prompt, copilot-review

---

## Inputs/Secrets/Outputs Definition

### Inputs (9 defined)

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `model` | string | false | `""` | Override AI model name |
| `openci-ref` | string | false | `main` | OpenCI ref for ./.openci/* references |
| `language` | string | false | `""` | Override detected language |
| `enable-ai-review` | boolean | false | `true` | Enable AI review |
| `enable-eval` | boolean | false | `false` | Enable prompt evaluation |
| `coverage-threshold` | number | false | `80` | Coverage threshold percentage |
| `pr-review-prompt-path` | string | false | `""` | Custom prompt path for AI review |
| `enable-copilot-review` | boolean | false | `false` | Request Copilot review on PRs |
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |

### Secrets (6 defined, all optional)

| Secret | Required | Description |
|--------|----------|-------------|
| `api-base-url` | false | Custom Anthropic-compatible base URL |
| `anthropic-api-key` | false | Anthropic API key |
| `codecov-token` | false | Codecov upload token |
| `sonar-token` | false | SonarCloud token |
| `snyk-token` | false | Snyk token |
| `release-pat` | false | PAT for Copilot review |

### Outputs

No workflow-level outputs defined. Job-level outputs exist:
- `detect-language.outputs.language` -- detected language
- `detect-language.outputs.package-manager` -- detected package manager
- `test.outputs.coverage-file` -- path to coverage file
- `enrich.outputs.workspace-artifact` -- artifact name for agent workspace
- `agent.outputs.plan` -- action plan JSON from AI review
- `agent.outputs.skip-reason` -- reason if agent was skipped

---

## Node-by-Node Status

### Top-level Configuration

| Field | Value | Status |
|-------|-------|--------|
| `name` | `pr` | OK |
| `on.workflow_call` | Defined | OK |
| `permissions` | `{}` (empty, least privilege) | OK |
| `concurrency` | `pr-${{ github.event.pull_request.number \|\| github.ref }}` | OK |
| `cancel-in-progress` | `true` | OK |

### Jobs

| # | Job | needs | if | runner | timeout | permissions | Status |
|---|-----|-------|----|--------|---------|-------------|--------|
| 1 | `preflight` | -- | -- | inputs.runner | 2min | contents:read | OK |
| 2 | `detect-language` | preflight | -- | inputs.runner | 2min | contents:read | OK |
| 3 | `auto-label` | preflight | `github.event.pull_request != null` | inputs.runner | 3min | contents:read, pull-requests:write | OK |
| 4 | `auto-assign-fallback` | preflight | PR event + no reviewers | inputs.runner | 3min | contents:read, pull-requests:write | OK |
| 5 | `validate-pr-title` | preflight | `github.event.pull_request != null` | inputs.runner | 2min | contents:read | OK |
| 6 | `validate-pr-desc` | preflight | `github.event.pull_request != null` | inputs.runner | 2min | contents:read | OK |
| 7 | `scan-deps` | preflight | `github.event.pull_request != null` | inputs.runner | 5min | contents:read, pull-requests:write | OK |
| 8 | `scan-secrets` | preflight | -- | inputs.runner | 5min | contents:read | OK |
| 9 | `scan-sonarcloud` | preflight | -- | inputs.runner | 10min | contents:read | OK |
| 10 | `verify-sha` | preflight | -- | inputs.runner | 5min | contents:read | OK |
| 11 | `lint` | detect-language | -- | inputs.runner | 10min | contents:read | OK |
| 12 | `test` | detect-language | -- | inputs.runner | 15min | contents:read | OK |
| 13 | `coverage` | test | -- | inputs.runner | 5min | contents:read | OK |
| 14 | `build-check` | detect-language | -- | inputs.runner | 15min | contents:read | OK |
| 15 | `ai-review` | lint, test | `inputs.enable-ai-review == true` | inputs.runner | 15min | contents:read, pull-requests:write, id-token:write | OK |
| 16 | `eval-prompt` | ai-review | `always() && inputs.enable-eval == true` | inputs.runner | 10min | contents:read, pull-requests:write | OK |
| 17 | `copilot-review` | preflight | `inputs.enable-copilot-review == true && github.event.pull_request != null` | inputs.runner | 3min | contents:read, pull-requests:write | OK |
| 18 | `enrich` | lint, test, validate-pr-title, scan-deps, scan-secrets, verify-sha | `always() && PR event && all required success` | inputs.runner | 5min | contents:read, pull-requests:read | OK |
| 19 | `agent` | enrich | `inputs.enable-ai-review == true` | inputs.runner | 15min | contents:read, pull-requests:write, id-token:write | OK |
| 20 | `execute` | enrich, agent | `always() && needs.agent.result == 'success'` | inputs.runner | 5min | pull-requests:write, issues:write, contents:read | WARN |

### SHA-Pinned Actions

| Action | SHA | Comment | Matches Manifest |
|--------|-----|---------|-----------------|
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 | YES |
| `actions/download-artifact` | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | v4.3.0 | YES |
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | v2.17.0 | YES |
| `dorny/paths-filter` | `de90cc6fb38fc0963ad72b210f1f284cd68cea36` | v3.0.2 | YES |

All SHA refs match the `manifest.yml` definitions.

### Local Actions Referenced (21 total)

All 21 local action paths and 2 scripts resolve to existing files on disk:
- 17 actions under `actions/pr/`
- 3 actions under `actions/_common/`
- 2 scripts under `.github/scripts/`

---

## Callers Analysis

### Caller: `pull-request.yml`

**Trigger:** `pull_request: [opened, synchronize, reopened, ready_for_review]`, `workflow_dispatch`
**SHA ref:** `YiAgent/OpenCI/.github/workflows/reusable-pr.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

**Inputs passed (4 of 9):**

| Input Passed | Callee Input | Match |
|-------------|-------------|-------|
| `enable-ai-review: true` | `enable-ai-review` | OK |
| `enable-eval: true` | `enable-eval` | OK |
| `runner: blacksmith-2vcpu-ubuntu-2404` | `runner` | OK |
| `model: ${{ vars.AI_MODEL \|\| '' }}` | `model` | OK |

**Inputs NOT passed (5):** `openci-ref`, `language`, `coverage-threshold`, `pr-review-prompt-path`, `enable-copilot-review` -- all optional, will use defaults.

**Secrets passed (2 of 6):**

| Secret Passed | Callee Secret | Match |
|--------------|---------------|-------|
| `secrets.ANTHROPIC_API_KEY` | `anthropic-api-key` | OK |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` | OK |

**Secrets NOT passed (4):** `codecov-token`, `sonar-token`, `snyk-token`, `release-pat` -- all optional. The preflight job probes for these and adjusts behavior accordingly.

**Caller permissions** are broader than callee needs (caller declares `checks:write`, `issues:write`, `security-events:write`, `statuses:write`, `packages:read` which the callee never uses). This is harmless but unnecessarily broad.

---

## Issues Found

### WARN: `execute` job uses `inputs.openci-ref` directly instead of resolved ref

**Severity:** MEDIUM
**Location:** Line 912, `execute` job, "Checkout OpenCI for execute actions" step
**Details:** Every other job (16 of 17 that check out OpenCI) uses a "Resolve OpenCI workflow ref" step that falls back to parsing `github.workflow_ref` when `inputs.openci-ref` is not explicitly set. The `execute` job skips this resolution step entirely and uses `${{ inputs.openci-ref }}` directly (defaulting to `main`).

**Impact:** In practice this is likely fine because the default is `main`, matching the resolution fallback. However, if a caller passes a non-default `openci-ref` that resolves differently through the workflow_ref parsing logic, the `execute` job could use a different ref than the other jobs. This is a consistency issue, not a correctness bug in normal usage.

**Recommendation:** Add the "Resolve OpenCI workflow ref" step to the `execute` job for consistency with all other jobs.

### INFO: Caller permissions are broader than necessary

**Severity:** LOW
**Location:** `pull-request.yml` lines 14-23
**Details:** The caller declares `security-events:write`, `statuses:write`, `packages:read`, and `checks:write` which the reusable workflow never requests. Since the reusable workflow sets `permissions: {}` at the top level and specifies per-job permissions, the caller's broader permissions are inherited by the jobs but unused. This is harmless but violates least-privilege principle.

### INFO: No workflow-level outputs

**Severity:** LOW
**Location:** Top-level of `reusable-pr.yml`
**Details:** The workflow defines useful job-level outputs (`agent.outputs.plan`, `enrich.outputs.workspace-artifact`, etc.) but does not promote any to workflow-level `outputs:`. Callers cannot access these outputs without also calling the workflow in a way that surfaces them.

### INFO: `eval-prompt` condition uses `always()` despite depending on `ai-review`

**Severity:** LOW
**Location:** Line 669
**Details:** `eval-prompt` has `if: always() && inputs.enable-eval == true` and `needs: [ai-review]`. The `always()` means it will run even if `ai-review` fails or is skipped. This appears intentional (eval should run regardless of AI review success), but is worth noting since `ai-review` failure would mean the eval runs without the review context.

### INFO: `enrich` condition lists `scan-secrets` in needs but not in the `if` result checks

**Severity:** LOW
**Location:** Lines 763-771
**Details:** The `enrich` job has `needs: [lint, test, validate-pr-title, scan-deps, scan-secrets, verify-sha]` but its `if` condition only checks results for `lint`, `test`, `validate-pr-title`, `scan-deps`, and `verify-sha`. The `scan-secrets` result is not explicitly checked (though `always()` plus the absence of `needs.scan-secrets.result == 'success'` means enrich will run even if scan-secrets fails). This appears intentional since scan-secrets is advisory, but the inconsistency between `needs` list and `if` checks is worth documenting.

---

## Test Cases for Automation

### TC-01: YAML Syntax Validity
- **Action:** Parse with `yaml.safe_load()`
- **Expected:** No parse errors
- **Result:** PASS

### TC-02: Actionlint Clean
- **Action:** Run `actionlint .github/workflows/reusable-pr.yml`
- **Expected:** No errors or warnings
- **Result:** PASS (zero output = clean)

### TC-03: All SHA Refs Match Manifest
- **Action:** Compare SHA pins against `manifest.yml`
- **Expected:** All 4 external actions match manifest entries
- **Result:** PASS (all 4 match)

### TC-04: All Local Action Paths Exist
- **Action:** Verify all 21 `./.openci/actions/*` paths and 2 script paths exist on disk
- **Expected:** All resolve to existing files
- **Result:** PASS (all 23 exist)

### TC-05: Caller Input/Secret Compatibility
- **Action:** Verify `pull-request.yml` passes valid inputs and secrets
- **Expected:** No unknown inputs/secrets, no missing required inputs/secrets
- **Result:** PASS (4 valid inputs, 2 valid secrets, all required satisfied)

### TC-06: Job Dependency DAG is Acyclic
- **Action:** Build dependency graph from `needs` declarations
- **Expected:** No cycles, all referenced jobs exist
- **Result:** PASS (linear stages: preflight -> detect-language -> lint/test/build-check -> ai-review -> enrich -> agent -> execute)

### TC-07: Output References are Valid
- **Action:** Check all `needs.X.outputs.Y` references match defined outputs
- **Expected:** All references resolve to defined outputs
- **Result:** PASS (`needs.test.outputs.coverage-file`, `needs.agent.outputs.plan` both defined)

### TC-08: Permissions are Least-Privilege at Top Level
- **Action:** Verify top-level `permissions: {}`
- **Expected:** Empty permissions, per-job overrides
- **Result:** PASS (top-level `{}`, all 19 jobs declare own permissions)

### TC-09: `execute` Job Ref Resolution Consistency
- **Action:** Check that `execute` job uses the same openci-ref resolution pattern as all other jobs
- **Expected:** All jobs use the "Resolve OpenCI workflow ref" step pattern
- **Result:** FAIL -- `execute` job uses `${{ inputs.openci-ref }}` directly (line 912) without the resolution step

### TC-10: Concurrency Group Correctness
- **Action:** Verify concurrency group includes PR number for deduplication
- **Expected:** `pr-${{ github.event.pull_request.number || github.ref }}`
- **Result:** PASS

### TC-11: Harden Runner Present in All Jobs
- **Action:** Verify every job has `step-security/harden-runner` as first step
- **Expected:** All 19 jobs include harden-runner with `egress-policy: audit`
- **Result:** PASS (all 19 jobs have it)

### TC-12: `persist-credentials: false` on All Checkouts
- **Action:** Verify all `actions/checkout` uses have `persist-credentials: false`
- **Expected:** No checkout without this flag
- **Result:** PASS (all 17 checkout steps include it)

### TC-13: Conditional Jobs Skip Correctly
- **Action:** Verify PR-only jobs have `github.event.pull_request != null` guards
- **Expected:** auto-label, auto-assign-fallback, validate-pr-title, validate-pr-desc, scan-deps all gated
- **Result:** PASS (all 5 have the condition)

---

## Summary

| Category | Count |
|----------|-------|
| Total Jobs | 19 |
| actionlint Errors | 0 |
| YAML Errors | 0 |
| SHA Mismatches | 0 |
| Missing Local Actions | 0 |
| Caller Mismatches | 0 |
| MEDIUM Issues | 1 (execute job ref inconsistency) |
| LOW Issues | 3 (broad caller perms, no workflow outputs, enrich scan-secrets check) |
| Test Cases | 13 (12 PASS, 1 FAIL) |

The workflow is structurally sound and well-designed with defense-in-depth (harden-runner, persist-credentials:false, per-job permissions, SHA-pinned actions). The one actionable finding is the `execute` job's inconsistent openci-ref resolution pattern.

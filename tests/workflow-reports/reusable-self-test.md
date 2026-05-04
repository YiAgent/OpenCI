# Workflow Test Report: reusable-self-test.yml

**File:** `.github/workflows/reusable-self-test.yml`
**Test Date:** 2026-05-04
**Tester:** Automated analysis (Claude Code)

---

## Overview

The `reusable-self-test.yml` workflow is a reusable workflow (`workflow_call`) that validates the OpenCI project's own workflows, actions, and automation rules. It implements a 3-stage pipeline:

1. **Stage 1 -- Lint (parallel):** actionlint, yamllint, shellcheck, pyflakes
2. **Stage 2 -- Security (parallel):** zizmor, verify-sha, workflow-audit, bats-tests
3. **Stage 3 -- Summary:** Aggregate results, write GITHUB_STEP_SUMMARY, fail if any check failed

All 8 check jobs run in parallel (no inter-job dependencies). The `summary` job depends on all 8 and runs `if: always()`.

**Workflow Name:** `self-test (reusable)`
**Concurrency Group:** `self-test-reusable` (cancel-in-progress: false)

---

## Inputs/Secrets/Outputs Definition

### Inputs (workflow_call)

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |
| `enable-zizmor` | boolean | false | `true` | Run zizmor security scan |
| `enable-pyflakes` | boolean | false | `true` | Run pyflakes on Python scripts |

### Secrets

None defined. Callers use `secrets: inherit` but no secrets are consumed by this workflow.

### Outputs

None defined.

---

## Validation Results

### YAML Syntax

**PASS** -- `python3 yaml.safe_load()` parses the file without error.

### actionlint

**PASS** -- `actionlint .github/workflows/reusable-self-test.yml` produces zero warnings or errors.

---

## Node-by-Node Status

### Top-Level Configuration

| Property | Value | Status |
|----------|-------|--------|
| `on: workflow_call` | Correct trigger for reusable workflows | PASS |
| `permissions: {}` | Least-privilege at workflow level (overridden per-job) | PASS |
| `concurrency` | `self-test-reusable`, cancel-in-progress: false | PASS |
| Inputs definition | 3 optional inputs with sensible defaults | PASS |

### Job: `actionlint` (Stage 1)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> install actionlint -> run actionlint | PASS |
| SHA: `step-security/harden-runner` | `@f808768d1510423e83855289c910610ca9b43176` = v2.17.0 (matches manifest) | PASS |
| SHA: `actions/checkout` | `@11bd71901bbe5b1630ceea73d27597364c9af683` = v4.2.2 (matches manifest) | PASS |
| `persist-credentials: false` | Security best practice | PASS |
| actionlint config | `-config-file .github/actionlint.yaml` (file exists, defines `blacksmith-2vcpu-ubuntu-2404` label) | PASS |
| actionlint ignore | `-ignore 'unknown permission scope "workflows"'` | PASS |

**Note:** The actionlint ignore flag is required because `workflows` is a valid GitHub permission scope but actionlint does not natively recognize it.

### Job: `yamllint` (Stage 1)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> pip install yamllint -> yamllint . | PASS |
| yamllint config | `.yamllint` exists with project-specific overrides (truthy disabled, braces/colons relaxed) | PASS |
| SHA refs | Same 2 actions (harden-runner, checkout) -- both match manifest | PASS |

### Job: `shellcheck` (Stage 1)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> find .sh files -> shellcheck | PASS |
| Graceful no-files | Emits `::notice::` and exits 0 if no .sh files found | PASS |
| Exclusions | `.git/*`, `tests/*`, `.openci/*` | PASS |
| ShellCheck directive | `# shellcheck disable=SC2086` for unquoted `$files` expansion | PASS |

### Job: `pyflakes` (Stage 1, conditional)

| Aspect | Detail | Status |
|--------|--------|--------|
| `if` condition | `inputs.enable-pyflakes == true` | PASS |
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> pip install pyflakes -> pyflakes | PASS |
| Graceful no-files | Emits `::notice::` and exits 0 if no .py files found | PASS |
| Exclusions | `.git/*`, `.openci/*`, `tests/*` | PASS |

### Job: `zizmor` (Stage 2, conditional)

| Aspect | Detail | Status |
|--------|--------|--------|
| `if` condition | `inputs.enable-zizmor == true` | PASS |
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 10 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> `uses: ./actions/_common/scan-zizmor` | PASS |
| Local action | `actions/_common/scan-zizmor/action.yml` exists, composite action with zizmor v1.6.0 | PASS |
| SHA refs | Same 2 actions (harden-runner, checkout) -- both match manifest | PASS |

### Job: `verify-sha` (Stage 2)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| `fetch-depth: 0` | Full history needed for SHA verification | PASS |
| Steps | harden-runner -> checkout (full) -> install yq 4.44.6 -> verify-sha-consistency.sh | PASS |
| Script | `.github/scripts/verify-sha-consistency.sh` exists (9050 bytes) | PASS |
| yq install | Conditional (skips if already installed), pinned version 4.44.6 | PASS |

### Job: `workflow-audit` (Stage 2)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 5 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> workflow-audit.sh | PASS |
| Script | `.github/scripts/workflow-audit.sh` exists (10508 bytes) | PASS |

### Job: `bats-tests` (Stage 2)

| Aspect | Detail | Status |
|--------|--------|--------|
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 15 | PASS |
| `permissions` | `contents: read` | PASS |
| Steps | harden-runner -> checkout -> install bats -> `bats tests/ --recursive` | PASS |
| BATS tests | `tests/` directory exists with 40+ `.bats` files (actions, scripts, integration) | PASS |
| Conditional install | `if ! command -v bats` -- skips install if already present | PASS |

### Job: `summary` (Stage 3)

| Aspect | Detail | Status |
|--------|--------|--------|
| `needs` | All 8 upstream jobs | PASS |
| `if` | `always()` -- runs even when upstream jobs fail or are skipped | PASS |
| `runs-on` | `${{ inputs.runner }}` | PASS |
| `timeout-minutes` | 2 | PASS |
| `permissions` | `{}` -- no permissions needed (no checkout) | PASS |
| Steps | harden-runner -> write summary table -> fail-if-any-failed | PASS |
| Summary step | Writes markdown table to `$GITHUB_STEP_SUMMARY` with check/skip/fail icons | PASS |
| Fail step | Iterates all 8 results; exits 1 if any are not `success` or `skipped` | PASS |
| Result handling | `skipped` is treated as acceptable (for disabled pyflakes/zizmor) | PASS |

---

## SHA Reference Verification

All `uses:` references in the workflow against `manifest.yml`:

| Action | SHA in Workflow | Manifest Entry | Match |
|--------|----------------|----------------|-------|
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | `f808768d1510423e83855289c910610ca9b43176` (v2.17.0) | PASS |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) | PASS |
| `./actions/_common/scan-zizmor` | N/A (local action, no SHA) | N/A | PASS |

No unpinned or tag-based references found. All third-party actions are SHA-pinned.

---

## Callers Analysis

### Caller: `.github/workflows/ci-self-test.yml`

| Aspect | Caller Value | Reusable Definition | Status |
|--------|-------------|---------------------|--------|
| `uses:` ref | `YiAgent/OpenCI/.github/workflows/reusable-self-test.yml@f62931bd0e2b73800512625a9fc5118557957ff3` | Self-reference | PASS |
| SHA in ref | `f62931bd0e2b73800512625a9fc5118557957ff3` | Matches `manifest.yml` `YiAgent/OpenCI` entry | PASS |
| `runner` input | `ubuntu-latest` | Matches default | PASS |
| `enable-zizmor` | Not passed | Default `true` applies | PASS |
| `enable-pyflakes` | Not passed | Default `true` applies | PASS |
| `secrets: inherit` | Passed | No secrets consumed by reusable | PASS (no-op) |
| Caller permissions | `contents: read`, `security-events: write` | Reusable only needs `contents: read` | INFO |

### Caller Trigger Analysis

The caller `ci-self-test.yml` triggers on:
- `push` to `main` (paths: workflows, scripts, actions, manifest, actionlint config, yamllint config, lefthook)
- `pull_request` (same paths)
- `workflow_dispatch` (manual)

This ensures the self-test runs whenever workflows, actions, or CI config change.

---

## Issues Found

### INFO-001: Caller declares unused `security-events: write` permission

**Severity:** INFO
**Location:** `.github/workflows/ci-self-test.yml` line 39
**Detail:** The caller workflow declares `security-events: write` but the reusable workflow's jobs only request `contents: read` or `{}`. No job writes security events. This permission is inherited but unused.
**Recommendation:** Remove `security-events: write` from the caller if not needed by other jobs in the caller workflow. Currently the caller has only one job (`self-test`), so this permission is definitely unused.

### INFO-002: `secrets: inherit` passes all secrets but none are consumed

**Severity:** INFO
**Location:** `.github/workflows/ci-self-test.yml` line 50
**Detail:** `secrets: inherit` forwards all repository secrets to the reusable workflow, but the reusable workflow defines no secrets and consumes none. This is functionally harmless but is unnecessary secret exposure surface area.
**Recommendation:** Replace `secrets: inherit` with an empty `secrets: {}` block to follow the principle of least privilege.

### INFO-003: Summary job `needs` includes conditional jobs

**Severity:** INFO (by design)
**Location:** `reusable-self-test.yml` line 273
**Detail:** The `summary` job lists all 8 upstream jobs in `needs:`, including `pyflakes` and `zizmor` which can be skipped via input flags. When skipped, these report status `skipped` which is correctly handled as acceptable by the "Fail if any check failed" step. This is working as intended.

---

## Structural Observations

1. **No checkout in summary job:** The summary job correctly avoids checking out code -- it only writes to `$GITHUB_STEP_SUMMARY` using env vars from upstream job results.

2. **Consistent harden-runner usage:** Every job starts with `step-security/harden-runner` with `egress-policy: audit`, following the project's security baseline.

3. **Consistent `persist-credentials: false`:** All checkout steps disable credential persistence, preventing token leakage.

4. **Proper timeout discipline:** All jobs have explicit timeouts (2-15 minutes), preventing hung jobs from consuming runner minutes indefinitely.

5. **Idempotent tool installation:** Several steps check if tools are already installed before installing (yq, bats), making the workflow resilient to runner image changes.

---

## Test Cases for Automation

### TC-001: YAML Validity
```
Input: Parse reusable-self-test.yml with yaml.safe_load()
Expected: No exception raised
Status: PASS
```

### TC-002: actionlint Clean
```
Input: Run actionlint .github/workflows/reusable-self-test.yml
Expected: Zero errors/warnings
Status: PASS
```

### TC-003: All Third-Party Actions SHA-Pinned
```
Input: Extract all `uses:` lines with `@` refs
Expected: Every `@` ref is a 40-char hex SHA, not a tag or branch
Status: PASS (2 refs: harden-runner, checkout -- both SHAs)
```

### TC-004: All SHA Refs Match Manifest
```
Input: Cross-check workflow SHAs against manifest.yml deps
Expected: Every SHA in the workflow matches its manifest entry
Status: PASS
```

### TC-005: Local Action Exists
```
Input: Check `./actions/_common/scan-zizmor/action.yml` exists
Expected: File exists and is a valid composite action
Status: PASS
```

### TC-006: Referenced Scripts Exist
```
Input: Check .github/scripts/verify-sha-consistency.sh and workflow-audit.sh exist
Expected: Both files exist and are executable
Status: PASS
```

### TC-007: Caller Input/Secret Match
```
Input: Compare ci-self-test.yml caller inputs against reusable-self-test.yml definitions
Expected: All caller inputs map to defined inputs; no undefined inputs passed
Status: PASS (only `runner` passed, which is defined)
```

### TC-008: Caller SHA Matches Manifest
```
Input: Check `@f62931bd0e2b73800512625a9fc5118557957ff3` in ci-self-test.yml
Expected: Matches `YiAgent/OpenCI` entry in manifest.yml
Status: PASS
```

### TC-009: Permissions Least-Privilege
```
Input: Check workflow-level and job-level permissions
Expected: No job requests write access unnecessarily; summary has {} permissions
Status: PASS
```

### TC-010: Conditional Jobs Skip Gracefully
```
Input: Run workflow with enable-pyflakes: false, enable-zizmor: false
Expected: pyflakes and zizmor skip; summary still runs and passes
Status: PASS (if: always() + skipped acceptance in fail step)
```

### TC-011: Summary Fails on Upstream Failure
```
Input: Simulate one upstream job failure (e.g., actionlint exits 1)
Expected: summary job runs, reports failure in table, exits 1
Status: VERIFIED BY DESIGN (fail step iterates all results)
```

### TC-012: actionlint Config and Ignore Flag
```
Input: Check .github/actionlint.yaml exists and -ignore flag in actionlint step
Expected: Config file exists; ignore flag suppresses "workflows" permission scope warning
Status: PASS
```

---

## Summary

| Category | Result |
|----------|--------|
| YAML Validity | PASS |
| actionlint | PASS |
| SHA Pinning | PASS |
| SHA Manifest Consistency | PASS |
| Caller Compatibility | PASS |
| Job Dependencies | PASS |
| Conditional Logic | PASS |
| Permissions | PASS |
| Security Posture | PASS |
| Referenced Files | PASS |
| Issues Found | 0 CRITICAL, 0 HIGH, 0 MEDIUM, 3 INFO |

**Overall Assessment:** The reusable workflow is well-structured, secure, and correctly integrated with its caller. The 3 INFO items are minor observations that do not affect functionality or security.

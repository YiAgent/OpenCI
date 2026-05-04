# Workflow Test Report: ci-self-test.yml

**Date:** 2026-05-04
**Commit:** a2ec443 (HEAD -> main)
**Tool:** Manual analysis + python3 YAML validation (actionlint not available locally)

---

## Overview

| Field | Value |
|-------|-------|
| File | `.github/workflows/ci-self-test.yml` |
| Name | `ci-self-test` |
| Lines | 51 |
| Type | Entry workflow (delegates to reusable) |
| Reusable ref | `YiAgent/OpenCI/.github/workflows/reusable-self-test.yml@f62931bd0e2b73800512625a9fc5118557957ff3` |
| Purpose | Dogfooding -- validates OpenCI's own workflows, actions, and automation rules using the same CI patterns it ships to consumers |

**Architecture:** Thin entry wrapper that triggers on relevant file changes and delegates all work to `reusable-self-test.yml`. The reusable workflow runs 8 parallel checks (actionlint, yamllint, shellcheck, pyflakes, zizmor, verify-sha, workflow-audit, bats-tests) then aggregates results in a summary job.

---

## Node-by-Node Status

### Trigger Events (`on:`)

| Trigger | Status | Notes |
|---------|--------|-------|
| `push` to `main` | PASS | Path-filtered to relevant files only |
| `pull_request` | PASS | Same path filters as push (consistent) |
| `workflow_dispatch` | PASS | Allows manual triggering |
| Path filters | PASS | All 8 referenced paths verified to exist in repo |

**Path filter entries verified:**
- `.github/workflows/**` -- exists (24 workflow files)
- `.github/scripts/**` -- exists (3 scripts: preflight-secrets.sh, verify-sha-consistency.sh, workflow-audit.sh)
- `actions/**` -- exists (11 action directories)
- `manifest.yml` -- exists
- `manifest-pending.yml` -- exists
- `.github/actionlint.yaml` -- exists
- `.yamllint` -- exists
- `lefthook.yml` -- exists

### Permissions

| Permission | Status | Notes |
|------------|--------|-------|
| `contents: read` | PASS | Minimal read-only access, appropriate for lint/test |
| `security-events: write` | INFO | Declared at caller level but unused by reusable workflow |

The reusable workflow declares `permissions: {}` at workflow level and sets per-job permissions. The `security-events: write` permission in the caller has no effect since no job in the reusable workflow consumes it. This is harmless but unnecessary.

### Concurrency

| Field | Value | Status |
|-------|-------|--------|
| Group | `ci-self-test-${{ github.event.pull_request.number \|\| github.ref }}` | PASS |
| cancel-in-progress | `true` | PASS |

**Note:** For `workflow_dispatch` events, `github.event.pull_request.number` is empty, so the group resolves to `ci-self-test-refs/heads/<branch>`. Multiple dispatches on the same branch will cancel each other. This is generally desirable behavior (prevents stale runs) but worth documenting.

### Jobs

#### `self-test`

| Field | Value | Status |
|-------|-------|--------|
| Uses (reusable) | `YiAgent/OpenCI/.github/workflows/reusable-self-test.yml@f62931...` | PASS |
| `runner` input | `ubuntu-latest` | PASS |
| `secrets` | `inherit` | PASS |

**Reusable workflow internals (verified via local file):**

| Job | Timeout | Conditional | Status |
|-----|---------|-------------|--------|
| `actionlint` | 5 min | Always | PASS |
| `yamllint` | 5 min | Always | PASS |
| `shellcheck` | 5 min | Always | PASS |
| `pyflakes` | 5 min | `inputs.enable-pyflakes == true` (default) | PASS |
| `zizmor` | 10 min | `inputs.enable-zizmor == true` (default) | PASS |
| `verify-sha` | 5 min | Always | PASS |
| `workflow-audit` | 5 min | Always | PASS |
| `bats-tests` | 15 min | Always | PASS |
| `summary` | 2 min | `if: always()` | PASS |

**Job dependency graph (from reusable workflow):**
```
actionlint ──────┐
yamllint ────────┤
shellcheck ──────┤
pyflakes ────────┼──→ summary
zizmor ──────────┤
verify-sha ──────┤
workflow-audit ──┤
bats-tests ──────┘
```

All 8 check jobs run in parallel; summary always runs and fails if any check failed (excluding skipped).

### SHA References

| Reference | SHA | In manifest.yml | Object exists | Status |
|-----------|-----|-----------------|---------------|--------|
| reusable-self-test.yml | `f62931bd0e2b73800512625a9fc5118557957ff3` | Yes (`YiAgent/OpenCI` entry) | Yes (commit) | PASS |

**Content verification:** The reusable workflow file at the pinned SHA is byte-identical to the current local copy (md5: `5564f6444673c79092c9186488501c7e`). No drift detected.

### Secrets / Variables

| Reference | Status | Notes |
|-----------|--------|-------|
| `secrets: inherit` | PASS | Passes all caller secrets to reusable workflow |
| No direct `secrets.*` usage | PASS | Neither ci-self-test.yml nor reusable-self-test.yml directly reference secrets |
| Composite actions | PASS | `scan-zizmor` action does not reference secrets |

### Runner Labels

| Context | Label | Status |
|---------|-------|--------|
| Caller input | `ubuntu-latest` | PASS |
| actionlint config | `blacksmith-2vcpu-ubuntu-2404` | INFO (config only, not used by this workflow) |

The `.github/actionlint.yaml` defines `blacksmith-2vcpu-ubuntu-2404` as a known self-hosted label for actionlint validation purposes. The workflow correctly uses `ubuntu-latest` (GitHub-hosted).

### Referenced Files / Scripts

| File | Exists | Status |
|------|--------|--------|
| `.github/workflows/reusable-self-test.yml` | Yes | PASS |
| `.github/scripts/verify-sha-consistency.sh` | Yes | PASS |
| `.github/scripts/workflow-audit.sh` | Yes | PASS |
| `actions/_common/scan-zizmor/action.yml` | Yes | PASS |
| `.github/actionlint.yaml` | Yes | PASS |
| `.yamllint` | Yes | PASS |
| `tests/` (bats tests) | Yes (20+ .bats files) | PASS |

### YAML Syntax

| Check | Result |
|-------|--------|
| `python3 yaml.safe_load()` | VALID |

### actionlint

| Check | Result |
|-------|--------|
| Local run | SKIPPED (actionlint not installed locally; CI installs it) |

---

## Issues Found

### MEDIUM -- Unused `security-events: write` permission

**Location:** `ci-self-test.yml` line 39
**Issue:** The caller declares `security-events: write` but the reusable workflow's `permissions: {}` override means no job inherits this permission. No job in the reusable workflow uploads SARIF or uses security events.
**Recommendation:** Remove `security-events: write` from the caller to follow least-privilege. If a future job needs it, add it then.
**Severity:** MEDIUM (no functional impact, but violates least-privilege principle)

### INFO -- Concurrency group collapses for workflow_dispatch

**Location:** `ci-self-test.yml` line 42
**Issue:** For `workflow_dispatch` events, the concurrency group resolves to `ci-self-test-refs/heads/<branch>`, meaning multiple dispatches on the same branch cancel each other.
**Recommendation:** Consider appending `github.run_id` for dispatch events if concurrent manual runs should be allowed: `ci-self-test-${{ github.event.pull_request.number || github.run_id || github.ref }}`
**Severity:** LOW (current behavior is likely desired for most use cases)

### INFO -- actionlint not testable locally

**Issue:** `actionlint` binary is not installed in the local environment. The workflow's actionlint step installs it at runtime via a download script.
**Recommendation:** Document local setup or add a devcontainer/pre-commit hook for local actionlint.
**Severity:** LOW (CI handles this correctly)

---

## Test Cases for Automation

### TC-01: Trigger on workflow file change
- **Action:** Modify `.github/workflows/ci-self-test.yml` and push to a PR branch
- **Expected:** Workflow triggers, all 8 checks run, summary job produces a table
- **Verify:** Check GITHUB_STEP_SUMMARY for the summary table

### TC-02: Trigger on script change
- **Action:** Modify `.github/scripts/verify-sha-consistency.sh` and push to a PR branch
- **Expected:** Workflow triggers (path filter matches `.github/scripts/**`)

### TC-03: No trigger on unrelated file change
- **Action:** Modify `README.md` and push to a PR branch
- **Expected:** Workflow does NOT trigger (no path filter match)

### TC-04: workflow_dispatch manual trigger
- **Action:** Manually dispatch the workflow from GitHub UI
- **Expected:** Workflow runs all checks regardless of path filters

### TC-05: Concurrency cancellation
- **Action:** Push two rapid commits to the same PR branch
- **Expected:** First run is cancelled, second run completes

### TC-06: Reusable workflow SHA pinning
- **Action:** Verify `f62931bd0e2b73800512625a9fc5118557957ff3` resolves to a valid commit containing `.github/workflows/reusable-self-test.yml`
- **Expected:** SHA resolves, file exists at that commit
- **Automated check:** `git cat-file -t <SHA>` returns `commit`

### TC-07: Manifest consistency
- **Action:** Verify the SHA in `ci-self-test.yml` matches `manifest.yml` entry for `YiAgent/OpenCI`
- **Expected:** SHAs are identical
- **Automated check:** Extract SHA from both files, compare

### TC-08: Reusable workflow content drift
- **Action:** Compare `reusable-self-test.yml` at pinned SHA vs HEAD
- **Expected:** Files are identical (no drift)
- **Automated check:** `git show <SHA>:path | md5sum` vs `md5sum local-file`

### TC-09: All referenced paths exist
- **Action:** Verify all paths in the `paths:` filter arrays exist in the repository
- **Expected:** All paths resolve to files or directories
- **Automated check:** `test -e <path>` for each entry

### TC-10: Secrets inheritance
- **Action:** Verify `secrets: inherit` is present and no direct `secrets.*` references exist in the caller
- **Expected:** `secrets: inherit` is set; no `${{ secrets.X }}` in ci-self-test.yml

### TC-11: Permission scope validation
- **Action:** Verify declared permissions are sufficient for all jobs in the reusable workflow
- **Expected:** Each job's per-job permissions are a subset of or equal to the caller's declared permissions

### TC-12: Summary job always-runs behavior
- **Action:** Simulate a failure in one of the 8 check jobs
- **Expected:** Summary job still runs (`if: always()`), reports the failure in the table, and exits non-zero

### TC-13: BATS test suite existence
- **Action:** Verify `tests/` directory contains `.bats` files
- **Expected:** At least one `.bats` file exists
- **Automated check:** `find tests -name '*.bats' | wc -l` returns > 0

---

## Summary

| Category | Pass | Info | Medium | High | Critical |
|----------|------|------|--------|------|----------|
| Triggers | 3 | 0 | 0 | 0 | 0 |
| Permissions | 1 | 1 | 1 | 0 | 0 |
| Concurrency | 2 | 1 | 0 | 0 | 0 |
| SHA References | 1 | 0 | 0 | 0 | 0 |
| Secrets | 1 | 0 | 0 | 0 | 0 |
| Runner Labels | 1 | 1 | 0 | 0 | 0 |
| Referenced Files | 7 | 0 | 0 | 0 | 0 |
| YAML Syntax | 1 | 0 | 0 | 0 | 0 |
| **Total** | **17** | **3** | **1** | **0** | **0** |

**Overall assessment:** The workflow is well-structured and correctly configured. One MEDIUM issue (unused `security-events: write` permission) should be addressed. The SHA pinning, manifest consistency, and content drift checks all pass. The reusable workflow architecture is clean with proper parallel execution and a reliable summary aggregation pattern.

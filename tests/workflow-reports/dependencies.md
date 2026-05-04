# Workflow Test Report: dependencies.yml

**File:** `.github/workflows/dependencies.yml`
**Reusable workflow:** `YiAgent/OpenCI/.github/workflows/reusable-deps.yml@f62931bd0e2b73800512625a9fc5118557957ff3`
**Local reusable:** `.github/workflows/reusable-deps.yml` (exists)
**Test date:** 2026-05-04
**HEAD SHA:** `a2ec4435856d81e53e39206e371d021cab9159eb`

---

## Overview

`dependencies.yml` is a thin caller wrapper that delegates entirely to the reusable workflow `reusable-deps.yml`. Its sole purpose is to auto-merge Renovate bot patch-level dependency PRs once all required checks pass. It triggers on `pull_request_target` (opened, labeled, synchronize, reopened) and `workflow_dispatch`.

The workflow is 21 lines long, has a single job (`deps`) that calls the reusable workflow, and passes one input (`runner`).

---

## Validation Results

| Check | Status | Detail |
|-------|--------|--------|
| YAML syntax | PASS | `yaml.safe_load` succeeds |
| actionlint (caller) | PASS | No warnings or errors |
| actionlint (reusable) | PASS | No warnings or errors |
| Local reusable file exists | PASS | `.github/workflows/reusable-deps.yml` present |
| SHA exists in git history | PASS | `f62931bd` resolves to merge commit PR #79 |
| Manifest SHA consistency | PASS | Manifest `YiAgent/OpenCI` SHA matches workflow reference |

---

## Node-by-Node Status

### 1. Trigger (`on:`)

```yaml
on:
  pull_request_target:
    types: [opened, labeled, synchronize, reopened]
  workflow_dispatch:
```

| Aspect | Status | Notes |
|--------|--------|-------|
| YAML boolean key | PASS | Python YAML parses `on` as `True` (boolean); GitHub Actions handles this correctly |
| `pull_request_target` event | PASS | Correct event for cross-fork PR automation (runs in base branch context with secret access) |
| Event types | PASS | `opened`, `labeled`, `synchronize`, `reusable` -- covers all relevant states for Renovate PRs |
| `workflow_dispatch` | INFO | Allows manual triggering, but the reusable job is gated on `renovate[bot]` + `patch` label, so manual dispatch will skip the job silently |

**Security note:** `pull_request_target` is a security-sensitive trigger. The reusable workflow only runs `gh pr merge --auto` without interpolating PR body/title into shell commands, which is safe. The `step-security/harden-runner` with egress auditing adds defense in depth.

### 2. Permissions

```yaml
permissions:
  contents: write
  pull-requests: write
```

| Aspect | Status | Notes |
|--------|--------|-------|
| Scope | PASS | Minimal required permissions for `gh pr merge` |
| Reusable workflow override | PASS | Reusable sets `permissions: {}` at top level, then grants `contents: write` and `pull-requests: write` at job level. This is the correct pattern -- caller grants broad, reusable restricts |

### 3. Concurrency

```yaml
concurrency:
  group: dependencies-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: false
```

| Aspect | Status | Notes |
|--------|--------|-------|
| Group key (PR events) | PASS | `dependencies-<PR#>` groups all runs for the same PR |
| Group key (dispatch) | PASS | `|| github.run_id` fallback ensures unique group per manual run |
| cancel-in-progress | PASS | `false` is correct -- auto-merge should not be cancelled mid-flight |

**Concurrency mismatch (MEDIUM):** The reusable workflow defines its own concurrency group `dep-auto-merge-${{ github.event.pull_request.number }}` with `cancel-in-progress: true`. On `workflow_dispatch`, `github.event.pull_request.number` is empty, producing group key `dep-auto-merge-` (static). However, this is mitigated because the job's `if` condition prevents execution on dispatch.

### 4. Job: `deps`

```yaml
jobs:
  deps:
    uses: YiAgent/OpenCI/.github/workflows/reusable-deps.yml@f62931bd0e2b73800512625a9fc5118557957ff3
    with:
      runner: blacksmith-2vcpu-ubuntu-2404
```

| Aspect | Status | Notes |
|--------|--------|-------|
| SHA pinning | PASS | Full 40-char SHA, consistent with manifest |
| SHA currency | INFO | SHA is `f62931bd` (PR #79), HEAD is `a2ec443` (PR #80). Two commits behind HEAD. Not a bug -- the reusable workflow content has not changed between these commits |
| Runner override | INFO | `blacksmith-2vcpu-ubuntu-2404` overrides the default `ubuntu-latest`. This is a Blacksmith.sh hosted runner and requires Blacksmith to be configured on the consuming repository |
| No secrets passed | PASS | Reusable workflow uses `github.token` implicitly; no additional secrets needed |
| No inputs beyond runner | PASS | Reusable workflow only declares `runner` as an optional input |

### 5. Reusable Workflow: `reusable-deps.yml`

| Aspect | Status | Notes |
|--------|--------|-------|
| `workflow_call` trigger | PASS | Correct reusable workflow pattern |
| `runner` input | PASS | Optional, defaults to `ubuntu-latest` |
| Job `if` condition | PASS | Correctly gates on `renovate[bot]` user AND `patch` label |
| `timeout-minutes: 3` | PASS | Appropriate for a single `gh` CLI call |
| `step-security/harden-runner` | PASS | SHA `f808768d` matches manifest entry |
| `gh pr merge --auto --squash` | PASS | Uses `--auto` (respects branch protection), `--squash` merge method |
| Shell safety | PASS | `set -euo pipefail` in run block; variables quoted |
| No PR field interpolation | PASS | Only `$PR_NUMBER` and `$REPO` used in shell, both from trusted env vars |

---

## Issues Found

### MEDIUM -- Concurrency group empty on `workflow_dispatch`

**File:** `reusable-deps.yml` line 34
**Detail:** The reusable workflow's concurrency group `dep-auto-merge-${{ github.event.pull_request.number }}` produces an empty suffix on `workflow_dispatch` events, resulting in group key `dep-auto-merge-`. All manual dispatch runs would share the same concurrency group.
**Mitigation:** The job `if` condition prevents execution on non-Renovate PRs, so dispatch runs never reach the concurrency-sensitive step. Low practical risk.
**Suggested fix:** Add `|| github.run_id` fallback to the reusable workflow's concurrency group, matching the caller's pattern.

### LOW -- Manifest path inconsistency for `dep-auto-merge`

**File:** `manifest.yml` line 257
**Detail:** The manifest workflow catalog entry for `dep-auto-merge` lists `path: .github/workflows/deps.yml`, but the actual reusable file is `.github/workflows/reusable-deps.yml`. The file `deps.yml` does not exist at the documented path.
**Impact:** Documentation/tooling that reads the manifest to locate workflows will point to a nonexistent file.

### INFO -- SHA behind HEAD by 2 commits

**Detail:** The workflow references SHA `f62931bd` (PR #79), but HEAD is `a2ec443` (PR #80). The manifest entry for `YiAgent/OpenCI` also still shows `f62931bd`. The two intervening commits (`ca8a3a6`, `a2ec443`) are a manifest SHA bump and its merge, not changes to the reusable workflow content.
**Impact:** None -- the reusable workflow content at `f62931bd` is identical to `a2ec443`. SHA bumping is a separate tracked process.

### INFO -- Blacksmith runner requires external configuration

**Detail:** The runner label `blacksmith-2vcpu-ubuntu-2404` is a Blacksmith.sh hosted runner. This will fail on repositories that have not installed the Blacksmith GitHub App and configured self-hosted runners. The reusable workflow defaults to `ubuntu-latest` as a fallback.
**Impact:** Only relevant for downstream consumers that copy this caller pattern without Blacksmith configured.

---

## Test Cases for Automation

### TC-1: YAML Validity
- **Action:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/dependencies.yml'))"`
- **Expected:** No exception
- **Status:** PASS

### TC-2: Actionlint Clean
- **Action:** `actionlint .github/workflows/dependencies.yml`
- **Expected:** Zero warnings, zero errors
- **Status:** PASS

### TC-3: Actionlint Clean (Reusable)
- **Action:** `actionlint .github/workflows/reusable-deps.yml`
- **Expected:** Zero warnings, zero errors
- **Status:** PASS

### TC-4: SHA Pinning (40-char hex)
- **Action:** Extract SHA from `uses:` line, verify it is exactly 40 hex characters
- **Expected:** `f62931bd0e2b73800512625a9fc5118557957ff3` (40 chars)
- **Status:** PASS

### TC-5: SHA Exists in Git History
- **Action:** `git rev-parse f62931bd0e2b73800512625a9fc5118557957ff3`
- **Expected:** Resolves without error
- **Status:** PASS

### TC-6: Manifest SHA Consistency
- **Action:** Compare SHA in `uses:` with `deps.YiAgent/OpenCI` in `manifest.yml`
- **Expected:** Exact match
- **Status:** PASS

### TC-7: Reusable Workflow File Exists Locally
- **Action:** `ls .github/workflows/reusable-deps.yml`
- **Expected:** File exists
- **Status:** PASS

### TC-8: No Secrets Required
- **Action:** Verify `reusable-deps.yml` `workflow_call` declares no `secrets:` block
- **Expected:** No secrets input; only `github.token` used
- **Status:** PASS

### TC-9: Harden-Runner SHA Matches Manifest
- **Action:** Compare `step-security/harden-runner@<SHA>` in reusable workflow with manifest entry
- **Expected:** `f808768d1510423e83855289c910610ca9b43176` matches
- **Status:** PASS

### TC-10: Permissions Minimality
- **Action:** Verify top-level permissions only request `contents: write` and `pull-requests: write`
- **Expected:** No additional permissions (e.g., `issues: write`, `actions: write`)
- **Status:** PASS

### TC-11: PR Field Not Interpolated into Shell
- **Action:** Inspect `run:` blocks in reusable workflow; verify no `github.event.pull_request.title`, `.body`, `.head.ref` etc. are used in shell commands
- **Expected:** Only `PR_NUMBER` and `REPO` env vars used in `gh` command
- **Status:** PASS

### TC-12: `pull_request_target` Security Review
- **Action:** Verify the workflow does not check out or execute code from the PR head branch
- **Expected:** No `actions/checkout` step with `ref: ${{ github.event.pull_request.head.sha }}` or similar
- **Status:** PASS -- no checkout step exists; only `gh pr merge` is executed

---

## Summary

| Category | Count |
|----------|-------|
| PASS | 12 |
| INFO (advisory) | 3 |
| MEDIUM | 1 |
| HIGH | 0 |
| CRITICAL | 0 |

**Overall assessment:** The workflow is well-structured, secure, and follows best practices. The single MEDIUM issue (empty concurrency group on dispatch) has no practical impact due to the job's `if` gate. The LOW manifest path inconsistency should be corrected for tooling accuracy. No blocking issues found.

# Workflow Test Report: reusable-deps.yml

**File:** `.github/workflows/reusable-deps.yml`
**Workflow Name:** `dep-auto-merge`
**Date:** 2026-05-04
**Status:** PASS with advisory notes

---

## Overview

`reusable-deps.yml` is a reusable workflow that automatically enables GitHub's native auto-merge (squash) on Renovate bot pull requests that carry the `patch` label. It is designed to be called from a thin wrapper workflow triggered by `pull_request_target`. The workflow is minimal: a single job with two steps (harden-runner + `gh pr merge --auto`).

---

## Inputs/Secrets/Outputs Definition

### Inputs

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `runner` | `string` | `false` | `ubuntu-latest` | Runner label for all jobs |

### Secrets

None defined. The workflow uses `github.token` from the caller's context (implicit).

### Outputs

None defined.

---

## Node-by-Node Status

### Top-Level: `on.workflow_call`

- **Status:** PASS
- Defines one optional input (`runner`) with a sensible default.
- No secrets or outputs declared -- consistent with the workflow's simplicity.
- Note: The file header comment (line 15) states "No inputs or secrets required" but the workflow does define the `runner` input. This is a documentation inconsistency (see Issues).

### Top-Level: `permissions`

- **Status:** PASS
- Set to `permissions: {}` (empty) at the workflow level, which is the correct pattern for a reusable workflow. This means the reusable workflow inherits whatever permissions the caller grants.
- The caller (`dependencies.yml`) grants `contents: write` and `pull-requests: write`, which satisfies the job-level permissions below.

### Top-Level: `concurrency`

- **Status:** PASS (advisory)
- Group: `dep-auto-merge-${{ github.event.pull_request.number }}`
- `cancel-in-progress: true`
- Note: For `workflow_dispatch` events (also defined in the caller), `github.event.pull_request.number` will be empty/null, making the concurrency group `dep-auto-merge-`. This is a non-issue in practice since the `if:` condition requires a PR context, but it means `workflow_dispatch` invocations will always share a single concurrency group and cancel each other.

### Job: `enable-auto-merge`

- **Status:** PASS

#### `runs-on`

- Uses `${{ inputs.runner }}` -- correctly parameterized.
- Caller passes `blacksmith-2vcpu-ubuntu-2404` (Blacksmith hosted runner).

#### `timeout-minutes: 3`

- **Status:** PASS
- Appropriate for a single-step job that just runs `gh pr merge`.

#### `if:` condition

- **Status:** PASS
```yaml
github.event.pull_request.user.login == 'renovate[bot]' &&
contains(github.event.pull_request.labels.*.name, 'patch')
```
- Correctly gates execution to only Renovate PRs with the `patch` label.
- Uses string comparison for bot login (correct; `==` does case-insensitive string compare on GitHub).
- Uses `contains()` on label array (correct pattern).

#### `permissions`

- **Status:** PASS
- `contents: write` -- required for `gh pr merge`.
- `pull-requests: write` -- required for `gh pr merge --auto`.
- Both are subsets of what the caller grants.

#### Step 1: `step-security/harden-runner`

- **Status:** PASS
- SHA: `f808768d1510423e83855289c910610ca9b43176`
- Manifest match: **YES** -- matches `manifest.yml` entry for `step-security/harden-runner` (v2.17.0).
- Parameter: `egress-policy: audit` (non-blocking, appropriate for a low-risk job).

#### Step 2: `gh pr merge --auto`

- **Status:** PASS (advisory)
- Uses environment variables for `PR_NUMBER`, `REPO`, and `GH_TOKEN` -- correct pattern, no shell injection risk.
- Command: `gh pr merge "$PR_NUMBER" --repo "$REPO" --auto --squash`
  - `--auto`: enables auto-merge (waits for required checks).
  - `--squash`: squash merge strategy.
  - Variables are double-quoted in the shell command.
- `set -euo pipefail` at the top of the run block -- correct error handling.
- Advisory: Relies on `gh` CLI being available on the runner. Standard on GitHub-hosted runners. Blacksmith runners (`blacksmith-2vcpu-ubuntu-2404`) also include `gh`.

---

## Callers Analysis

### Caller: `.github/workflows/dependencies.yml`

| Aspect | Value | Status |
|--------|-------|--------|
| Trigger | `pull_request_target: [opened, labeled, synchronize, reopened]` + `workflow_dispatch` | PASS |
| `uses:` ref | `YiAgent/OpenCI/.github/workflows/reusable-deps.yml@f62931bd...` | PASS |
| SHA in manifest | `f62931bd0e2b73800512625a9fc5118557957ff3` (YiAgent/OpenCI bootstrap) | PASS |
| Input: `runner` | `blacksmith-2vcpu-ubuntu-2404` | PASS |
| Secrets passed | None | PASS (none needed) |
| Top-level permissions | `contents: write`, `pull-requests: write` | PASS (matches job needs) |
| Concurrency | `dependencies-${{ github.event.pull_request.number \|\| github.run_id }}` | PASS |
| `cancel-in-progress` | `false` (caller) vs `true` (reusable) | Note: Caller allows concurrent runs; reusable cancels within its own group. The reusable's concurrency group is a subset. |

### Input/Secret Match Verification

| Input/Secret | Reusable Defines | Caller Passes | Match |
|-------------|-----------------|---------------|-------|
| `runner` (input) | Yes (default: `ubuntu-latest`) | Yes (`blacksmith-2vcpu-ubuntu-2404`) | PASS |
| secrets | None defined | None passed | PASS |

---

## Issues Found

### MEDIUM -- Documentation/Comment Mismatch

**Location:** Lines 1-19 (file header comment)

The file header comment refers to the file as `dep-auto-merge.yml` (line 2) and states "No inputs or secrets required -- uses the caller's github.token" (line 15). However:
1. The actual filename is `reusable-deps.yml` (renamed in commit `f9b5e83`).
2. The workflow does define an input (`runner`).

**Impact:** Misleading for developers reading the source. No runtime impact.
**Recommendation:** Update the header comment to reference `reusable-deps.yml` and document the `runner` input.

### LOW -- Name/Filename Divergence

**Location:** Line 20 (`name: dep-auto-merge`) vs filename `reusable-deps.yml`

The workflow `name:` field is `dep-auto-merge` while the file is named `reusable-deps.yml`. This is cosmetic but can cause confusion in the GitHub Actions UI where the name is displayed.

**Impact:** Minor UX confusion. No functional impact.
**Recommendation:** Consider aligning the `name:` with the filename (e.g., `name: deps-auto-merge` or `name: reusable-deps`).

### LOW -- Concurrency Group for workflow_dispatch

**Location:** Line 34

The concurrency group `${{ github.event.pull_request.number }}` will be empty for `workflow_dispatch` events, resulting in a group named `dep-auto-merge-`. Multiple `workflow_dispatch` runs would contend on the same group.

**Impact:** Low. The `if:` condition on the job will skip execution for `workflow_dispatch` since there's no PR context, so the concurrency group is never actually used for those runs.
**Recommendation:** No action needed, but adding `|| github.run_id` (as the caller does) would be more defensive.

### ADVISORY -- actionlint Not Available

`actionlint` is not installed in the current environment (Go toolchain not available). Full linting could not be performed. The YAML syntax was validated via Python's `yaml.safe_load` and manual review.

---

## SHA Pinning Audit

| Action | SHA in Workflow | SHA in manifest.yml | Match |
|--------|----------------|---------------------|-------|
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | `f808768d1510423e83855289c910610ca9b43176` (v2.17.0) | PASS |

All third-party action references are pinned to 40-character commit SHAs. No tag-only or branch-only references.

---

## Test Cases for Automation

### TC-1: YAML Validity

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/reusable-deps.yml'))"
```
**Expected:** Exit code 0, no exceptions.

### TC-2: Schema -- workflow_call inputs exist

```yaml
# Assert: on.workflow_call.inputs.runner is defined
# Assert: inputs.runner.type == 'string'
# Assert: inputs.runner.required == false
# Assert: inputs.runner.default == 'ubuntu-latest'
```

### TC-3: SHA Pinning

```bash
# Extract all uses: references
# Assert: every third-party action uses a 40-char hex SHA (not a tag or branch)
# Assert: each SHA matches the corresponding entry in manifest.yml
```

### TC-4: Permission Model

```yaml
# Assert: top-level permissions is empty ({})
# Assert: job enable-auto-merge has permissions.contents == 'write'
# Assert: job enable-auto-merge has permissions.pull-requests == 'write'
```

### TC-5: Condition Logic

```yaml
# Assert: job if: condition checks for 'renovate[bot]' user login
# Assert: job if: condition checks for 'patch' label
```

### TC-6: Caller Input Match

```bash
# For each caller workflow:
#   Assert: all inputs passed match declared inputs in reusable workflow
#   Assert: no undeclared inputs are passed
#   Assert: no required inputs are missing
```

### TC-7: Shell Safety

```yaml
# Assert: run: block uses 'set -euo pipefail'
# Assert: all env vars used in shell commands are double-quoted
# Assert: no direct interpolation of github.event fields into shell commands
```

### TC-8: Concurrency Group

```yaml
# Assert: concurrency group includes a unique identifier (PR number or run ID)
# Assert: cancel-in-progress is explicitly set
```

### TC-9: Harden-Runner Present

```yaml
# Assert: first step in every job uses step-security/harden-runner
# Assert: egress-policy is set (audit or block)
```

### TC-10: Timeout Defined

```yaml
# Assert: every job has timeout-minutes set
# Assert: timeout is reasonable (< 30 minutes for this workflow type)
```

---

## Summary

| Category | Count |
|----------|-------|
| CRITICAL issues | 0 |
| HIGH issues | 0 |
| MEDIUM issues | 1 (documentation mismatch) |
| LOW issues | 2 (name divergence, concurrency for workflow_dispatch) |
| ADVISORY notes | 1 (actionlint unavailable) |
| SHA consistency | PASS (1/1 actions match manifest) |
| Caller compatibility | PASS (inputs match, permissions sufficient) |
| Security posture | PASS (harden-runner, no shell injection, minimal permissions) |

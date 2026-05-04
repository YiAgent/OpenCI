# Workflow Test Report: ci.yml

**Tested:** 2026-05-04
**File:** `.github/workflows/ci.yml`
**HEAD:** `a2ec443` (Merge pull request #80)
**actionlint:** PASS (no errors)
**YAML syntax:** VALID

---

## Overview

- **Trigger:** `push` to `main` branch + `workflow_dispatch` (manual)
- **Jobs:** 2 -- `ci` (reusable call) and `harness-test` (BATS)
- **Reusable deps:** `YiAgent/OpenCI/.github/workflows/reusable-ci.yml@f62931bd`
- **Runner:** `blacksmith-2vcpu-ubuntu-2404` (third-party Blacksmith runner)
- **Concurrency:** `ci-${{ github.ref }}`, cancel-in-progress: false

---

## Node-by-Node Status

### Trigger Configuration

- **Status:** PASS
- **Details:** `push` triggers on `main` only; `workflow_dispatch` allows manual runs. Both are correctly configured. No `paths`/`paths-ignore` filters (appropriate for a CI pipeline that should run on every main push).

### Top-Level Permissions

- **Status:** WARN
- **Details:** Grants `contents: read`, `packages: write`, `id-token: write`, `actions: write`, `issues: write`, `security-events: write`, `pull-requests: write`. The `harness-test` job only needs `contents: read` and overrides this correctly at the job level. However, the top-level `issues: write` and `pull-requests: write` are not needed by any step directly in ci.yml -- they exist to be inherited by the reusable workflow via `secrets: inherit` (reusable-ci.yml scopes permissions per-job). This is not harmful but is broader than minimal.

### Concurrency

- **Status:** PASS
- **Details:** Group `ci-${{ github.ref }}` means only one CI run per branch at a time. `cancel-in-progress: false` ensures every main push gets a full build (correct per the reusable-ci.yml comment: "every main commit deserves a fully completed build").

---

### Job: `ci`

**Uses:** `YiAgent/OpenCI/.github/workflows/reusable-ci.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

#### Input: `openci-ref`
- **Status:** PASS
- **Details:** Set to `${{ github.sha }}` -- the exact commit being built. Correct.

#### Input: `registry`
- **Status:** PASS
- **Details:** Hardcoded `ghcr.io`. Matches the default in reusable-ci.yml. Consistent with manifest conventions.

#### Input: `image-name`
- **Status:** PASS
- **Details:** `${{ vars.IMAGE_NAME || github.event.repository.name }}` -- uses repository variable if set, falls back to repo name. Correct pattern.

#### Input: `enable-ai-smoke`
- **Status:** PASS
- **Details:** Set to `true`. Enables AI smoke evaluation stage in the reusable workflow.

#### Input: `runner`
- **Status:** WARN
- **Details:** Set to `blacksmith-2vcpu-ubuntu-2404`. This is a third-party runner (Blacksmith) that requires a Blacksmith subscription and self-hosted runner registration. The reusable-ci.yml defaults to `ubuntu-latest` when not specified. If the Blacksmith runner is unavailable, the workflow will queue indefinitely. Note: an orphaned commit `7608a42` ("fix(ci): switch from blacksmith to ubuntu-latest runner") exists in the repo but is NOT on the main branch -- it appears to be a stale/abandoned fix.

#### Secrets: `inherit`
- **Status:** PASS
- **Details:** All repository secrets are passed to the reusable workflow. The reusable workflow declares `registry-token`, `anthropic-api-key`, and `api-base-url` as optional secrets. No missing required secrets.

---

### Reusable Workflow: reusable-ci.yml (internal analysis)

#### SHA Reference Consistency
- **Status:** PASS
- **Details:** ci.yml references `@f62931bd0e2b73800512625a9fc5118557957ff3`. This SHA:
  - Exists in the repository (resolves to "Merge pull request #79")
  - Matches the `YiAgent/OpenCI` entry in `manifest.yml` (line 104)
  - All 8 internal `resolve-openci` references in reusable-ci.yml also point to this same SHA

#### Manifest SHA vs HEAD
- **Status:** WARN
- **Details:** The manifest SHA `f62931bd` is 2 commits behind the current HEAD (`a2ec443`). The latest commits are:
  - `a2ec443` -- Merge PR #80 (chore/bump-after-79)
  - `ca8a3a6` -- chore(manifest): bump SHA after #79

  The manifest was updated to `f62931bd` in commit `ca8a3a6` but has NOT been bumped to `a2ec443`. This means the workflow is pinning to a SHA that is 2 commits behind HEAD. This is acceptable if intentional (the SHA is verified), but the verify-sha-consistency job may flag this if it expects the manifest to track HEAD.

#### Stage 1: Build
- **Status:** PASS
- **Jobs:** preflight -> detect-language -> build-docker (sequential chain)
- **Details:** Properly gated. Preflight probes secrets. Detect-language runs the detect script. Build-docker uses the composite action.

#### Stage 2: Verify (parallel)
- **Status:** PASS
- **Jobs:** scan-image, sign-image, verify-sha, generate-sbom, check-migration (conditional), eval-smoke (conditional)
- **Details:** All depend on `build-docker`. check-migration gated by `inputs.run-migration == true` (false by default). eval-smoke gated by `inputs.enable-ai-smoke == true` (true in ci.yml).

#### Stage 3: Agent (failure-only)
- **Status:** PASS
- **Jobs:** enrich -> agent
- **Details:** enrich runs `if: always()` to aggregate results. Agent runs only when `has-failures == 'true'` and `enable-failure-agent == true`.

#### Stage 4: Dispatch
- **Status:** PASS
- **Jobs:** execute
- **Details:** Evaluates deploy gate. auto-deploy defaults to false, so deploy-ready will be false unless explicitly enabled.

---

### Job: `harness-test`

#### Step: harden-runner
- **Status:** PASS
- **Details:** `step-security/harden-runner@f808768d` -- SHA matches manifest entry (v2.17.0). Egress policy set to audit.

#### Step: checkout
- **Status:** PASS
- **Details:** `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` -- SHA matches manifest entry (v4.2.2). `persist-credentials: false` is correct security practice.

#### Step: Install bats
- **Status:** PASS
- **Details:** Conditional install via `apt-get`. Uses `set -euo pipefail`. Correct pattern for CI.

#### Step: Run BATS test suite
- **Status:** PASS
- **Details:** Runs `bats tests/ --recursive`. BATS test files confirmed to exist at `tests/scripts/*.bats`, `tests/actions/*.bats`, `tests/integration/*.bats`.

---

## Cross-Reference: Third-Party Action SHAs

All `uses:` references in ci.yml are pinned to 40-char commit SHAs. Verified against `manifest.yml`:

| Action | SHA in ci.yml | Manifest SHA | Match |
|--------|---------------|--------------|-------|
| step-security/harden-runner | f808768d... | f808768d... (v2.17.0) | YES |
| actions/checkout | 11bd71901... | 11bd71901... (v4.2.2) | YES |
| YiAgent/OpenCI (reusable) | f62931bd... | f62931bd... | YES |

---

## Issues Found

### 1. [MEDIUM] Manifest SHA is 2 commits behind HEAD

The `YiAgent/OpenCI` SHA in `manifest.yml` is `f62931bd` (PR #79 merge), but HEAD is `a2ec443` (PR #80 merge). The manifest bump for PR #80 has not been done. This may cause the verify-sha-consistency job to report drift if it compares manifest SHA against the current commit.

**Location:** `manifest.yml` line 104
**Recommendation:** Bump the manifest SHA to `a2ec4435856d81e53e39206e371d021cab9159eb` in a follow-up PR.

### 2. [MEDIUM] Third-party runner dependency (Blacksmith)

Both jobs use `blacksmith-2vcpu-ubuntu-2404`, a third-party runner from Blacksmith. This requires an active Blacksmith subscription and registered runners. If the runner becomes unavailable, all CI jobs will queue indefinitely with no fallback.

**Location:** Lines 32 and 37
**Recommendation:** Consider adding a fallback strategy or documenting the Blacksmith dependency. The reusable-ci.yml correctly defaults to `ubuntu-latest`, but ci.yml overrides this.

### 3. [LOW] Top-level permissions broader than necessary for ci.yml itself

The top-level `permissions` block includes `issues: write` and `pull-requests: write`, but ci.yml's own jobs do not directly use these permissions. They exist for the reusable workflow, which scopes permissions per-job. While not harmful (reusable-ci.yml declares `permissions: {}` at its top level and scopes per-job), the broad top-level declaration in ci.yml could confuse auditors.

**Location:** Lines 11-18
**Recommendation:** Consider narrowing the top-level permissions to only what ci.yml's own jobs need (`contents: read`), since the reusable workflow manages its own permissions.

### 4. [LOW] Orphaned commit references ubuntu-latest switch

Commit `7608a42` ("fix(ci): switch from blacksmith to ubuntu-latest runner") exists in the repository but is not reachable from any branch. It modified ci.yml to use `ubuntu-latest` instead of `blacksmith-2vcpu-ubuntu-2404`. This commit appears to be abandoned.

**Recommendation:** Either cherry-pick this change to main or delete the orphaned commit to avoid confusion.

### 5. [INFO] No `needs:` dependency between `ci` and `harness-test`

The two jobs (`ci` and `harness-test`) run in parallel with no dependency. This is intentional -- the BATS tests are independent of the reusable CI pipeline. However, if a failure in `harness-test` should also block deployment, it is not currently wired into the reusable-ci.yml deploy gate.

**Recommendation:** If harness-test failures should block deploys, consider adding it as a dependency or integrating its results into the deploy gate.

---

## Test Cases for Automation

### test_trigger_push_main
- **Type:** Trigger validation
- **Description:** Verify workflow fires on push events to the `main` branch only.
- **Method:** Parse `on.push.branches` and assert `['main']`.
- **Expected:** `branches: [main]`

### test_trigger_workflow_dispatch
- **Type:** Trigger validation
- **Description:** Verify `workflow_dispatch` is enabled for manual runs.
- **Method:** Assert `on.workflow_dispatch` key exists.
- **Expected:** `workflow_dispatch` present with no inputs (not restricted).

### test_sha_manifest_consistency
- **Type:** SHA validation
- **Description:** Verify the reusable workflow SHA in ci.yml matches the `YiAgent/OpenCI` entry in manifest.yml.
- **Method:** Extract SHA from `jobs.ci.uses` and compare with `deps.YiAgent/OpenCI` in manifest.yml.
- **Expected:** Exact match.

### test_sha_exists_in_repo
- **Type:** SHA validation
- **Description:** Verify the referenced SHA `f62931bd0e2b73800512625a9fc5118557957ff3` is a valid commit in the repository.
- **Method:** Run `git rev-parse <SHA>` and verify it resolves.
- **Expected:** Returns a valid 40-char SHA.

### test_reusable_workflow_file_exists
- **Type:** File existence
- **Description:** Verify `.github/workflows/reusable-ci.yml` exists locally.
- **Method:** File existence check.
- **Expected:** File present.

### test_third_party_actions_pinned
- **Type:** Security
- **Description:** Verify all `uses:` references are pinned to 40-char commit SHAs (no tag/branch refs).
- **Method:** Regex match all `uses:` lines against `[a-f0-9]{40}`.
- **Expected:** All references pinned.

### test_permissions_not_overbroad
- **Type:** Security
- **Description:** Verify top-level permissions are documented and intentional.
- **Method:** Compare declared permissions against actual job requirements.
- **Expected:** No `write` permission without documented justification.

### test_bats_tests_exist
- **Type:** File existence
- **Description:** Verify BATS test files exist under `tests/` for the harness-test job.
- **Method:** Glob `tests/**/*.bats`.
- **Expected:** At least one `.bats` file found.

### test_concurrency_group
- **Type:** Configuration
- **Description:** Verify concurrency group uses `github.ref` to scope per-branch.
- **Method:** Parse `concurrency.group` expression.
- **Expected:** Contains `${{ github.ref }}`.

### test_cancel_in_progress_false
- **Type:** Configuration
- **Description:** Verify `cancel-in-progress` is false (every main commit gets a full build).
- **Method:** Parse `concurrency.cancel-in-progress`.
- **Expected:** `false`

### test_runner_label
- **Type:** Configuration
- **Description:** Verify runner label is set consistently across both jobs.
- **Method:** Compare `jobs.ci.with.runner` with `jobs.harness-test.runs-on`.
- **Expected:** Both equal `blacksmith-2vcpu-ubuntu-2404`.

### test_secrets_inherit
- **Type:** Configuration
- **Description:** Verify secrets are passed via `inherit` to the reusable workflow.
- **Method:** Parse `jobs.ci.secrets`.
- **Expected:** `secrets: inherit`

### test_harden_runner_present
- **Type:** Security
- **Description:** Verify every job starts with step-security/harden-runner.
- **Method:** Check first step of each job.
- **Expected:** `step-security/harden-runner` as first step.

### test_checkout_persist_credentials_false
- **Type:** Security
- **Description:** Verify checkout steps use `persist-credentials: false`.
- **Method:** Check `actions/checkout` `with` parameters.
- **Expected:** `persist-credentials: false` on all checkout steps.

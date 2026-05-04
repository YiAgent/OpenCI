# Workflow Test Report: reusable-stg.yml

**File:** `.github/workflows/reusable-stg.yml`
**Tested:** 2026-05-04
**Branch:** main (HEAD at `7608a42`)

---

## Overview

`reusable-stg.yml` is a reusable workflow implementing the staging deploy pipeline per SPEC section 5.4. It supports two deployment mechanisms selected via the `deploy-type` input:

- **docker** (default) -- SSH + docker compose/run on a remote host
- **k8s** -- `kubectl set image` on a Kubernetes cluster

The serial chain is: `preflight -> coverage-gate | perf-baseline -> deploy-docker|deploy-k8s -> run-migration? -> smoke-test -> (auto-rollback-docker | notify-observability | schedule-prd-dispatch | notify-deployed)`

Concurrency is serialized per ref (`cancel-in-progress: false`) to prevent half-applied deployments.

---

## Inputs/Secrets/Outputs Definition

### Inputs (17 total)

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `openci-ref` | string | false | `main` | OpenCI ref for `.openci/*` vendoring |
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |
| `image-digest` | string | false | (none) | Container image digest |
| `image-name` | string | false | (none) | Container image name |
| `registry` | string | false | `ghcr.io` | Container registry |
| `app-name` | string | false | (none) | Application name |
| `health-url` | string | false | (none) | Health check URL |
| `k8s-namespace` | string | false | `staging` | Kubernetes namespace |
| `run-migration` | boolean | false | `false` | Run DB migration after deploy |
| `deploy-type` | string | false | `docker` | `docker` or `k8s` |
| `ssh-host` | string | false | `""` | SSH target host (docker) |
| `ssh-user` | string | false | `deploy` | SSH user (docker) |
| `ssh-port` | string | false | `"22"` | SSH port (docker) |
| `deploy-mode` | string | false | `compose` | `compose` or `run` (docker) |
| `compose-file` | string | false | `docker-compose.yml` | Compose file path |
| `compose-project-dir` | string | false | `~` | Compose working directory |
| `docker-run-args` | string | false | `""` | Extra docker run args |

### Secrets (8 total, all optional)

| Name | Used By |
|------|---------|
| `kubeconfig-stg` | preflight (k8s check), deploy-k8s |
| `ssh-key-stg` | preflight (docker check), deploy-docker, auto-rollback-docker |
| `slack-webhook-url` | preflight, notify-deployed |
| `sentry-token` | notify-observability |
| `datadog-api-key` | notify-observability |
| `posthog-api-key` | notify-observability |
| `langsmith-api-key` | notify-observability |
| `axiom-token` | notify-observability |

### Outputs (1 total)

| Name | Description | Value |
|------|-------------|-------|
| `deploy-time` | ISO 8601 deploy timestamp | `jobs.deploy-k8s.outputs.deploy-time \|\| jobs.deploy-docker.outputs.deploy-time` |

---

## Node-by-Node Status

### 1. `preflight` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 2 min
- **Permissions:** `contents: read`
- **Steps:**
  1. `step-security/harden-runner` @ `f808768d` -- SHA verified OK
  2. `actions/checkout` @ `11bd7190` -- SHA verified OK
  3. "Resolve OpenCI workflow ref" -- shell script parses ref from input or `workflow_ref`
  4. `actions/checkout` (YiAgent/OpenCI) -- checks out `.openci/` directory
  5. "Probe secrets" -- runs `.github/scripts/preflight-secrets.sh` (exists in repo); validates required secrets based on `deploy-type`
  6. `./.openci/actions/deploy/preflight` -- exists in repo
- **Issues:** None

### 2. `coverage-gate` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: read`
- **Condition:** `vars.STG_COVERAGE_THRESHOLD != ''` (skipped when var is unset)
- **Steps:**
  1. harden-runner, checkout, openci-ref resolution, openci checkout (same pattern)
  2. `actions/download-artifact` @ `d3f86a10` (v4.3.0) -- SHA verified OK; `continue-on-error: true`
  3. `./.openci/actions/pr/check-coverage` -- exists in repo
- **Issues:** None

### 3. `perf-baseline` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Permissions:** `contents: read`, `actions: write`
- **`continue-on-error: true`** -- soft-gated, never blocks deploy
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/stg/perf-baseline` (exists)
- **Issues:** None

### 4. `deploy-k8s` -- CONDITIONAL PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Permissions:** `contents: read`
- **Condition:** `inputs.deploy-type == 'k8s'`
- **Needs:** `[preflight, coverage-gate, perf-baseline]`
- **Outputs:** `deploy-time`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/stg/deploy-k8s` (exists)
- **Issues:**
  - **[HIGH]** Requires `secrets.kubeconfig-stg` but caller (`deploy.yml`) does not pass it. Will fail at runtime if `deploy-type == 'k8s'`.

### 5. `deploy-docker` -- CONDITIONAL PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Permissions:** `contents: read`
- **Condition:** `inputs.deploy-type != 'k8s'`
- **Needs:** `[preflight, coverage-gate, perf-baseline]`
- **Outputs:** `deploy-time`, `previous-image`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/deploy/docker` (exists)
- **Issues:**
  - **[HIGH]** Requires `secrets.ssh-key-stg` but caller (`deploy.yml`) does not pass it. Will fail at runtime.
  - **[CRITICAL]** `image-digest` input is not passed by caller. The constructed `image-ref` becomes `ghcr.io/owner/name@` (empty digest), which will fail.

### 6. `run-migration` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`
- **Condition:** `inputs.run-migration == true && (needs.deploy-k8s.result == 'success' || needs.deploy-docker.result == 'success')`
- **Needs:** `[deploy-k8s, deploy-docker]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/_common/run-migration` (exists)
- **Issues:** None. Correctly handles skipped-when-false and post-deploy sequencing.

### 7. `smoke-test` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`
- **Condition:** `always() && (deploy success) && (migration success or skipped)`
- **Needs:** `[deploy-k8s, deploy-docker, run-migration]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/stg/smoke-test` (exists)
- **Issues:** None. `always()` combined with explicit result checks is correct for serial chain.

### 8. `auto-rollback-docker` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`, `issues: write`
- **Condition:** `always() && smoke-test failed && deploy-docker succeeded`
- **Needs:** `[deploy-docker, smoke-test]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/deploy/auto-rollback-docker` (exists)
- **Issues:**
  - **[MEDIUM]** No `auto-rollback-k8s` counterpart. K8s rollbacks rely on native deployment strategies, which is acceptable but worth noting.

### 9. `notify-observability` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: read`
- **`continue-on-error: true`**
- **Condition:** `always() && deploy succeeded`
- **Needs:** `[deploy-k8s, deploy-docker, smoke-test]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/integrations/notify-deploy` (exists)
- **Issues:** None. Correctly fires deploy markers even when smoke-test fails.

### 10. `schedule-prd-dispatch` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 3 min
- **Permissions:** `contents: read`, `actions: write`
- **Condition:** `smoke-test succeeded && vars.PRD_OBSERVATION_MINUTES != ''`
- **Needs:** `[deploy-k8s, deploy-docker, smoke-test]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/_common/schedule-prd-dispatch` (exists)
- **Issues:** None. Correctly gates on smoke-test success and observation window var.

### 11. `notify-deployed` -- PASS

- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: read`
- **Condition:** `always()`
- **Needs:** `[deploy-k8s, deploy-docker, smoke-test]`
- **Steps:** harden-runner, checkout, openci-ref, openci checkout, `./.openci/actions/_common/notify-deployed` (exists)
- **Issues:** None. Uses complex ternary for status field -- syntactically correct.

---

## Callers Analysis

### Caller: `.github/workflows/deploy.yml`

**Reference:** `YiAgent/OpenCI/.github/workflows/reusable-stg.yml@f62931bd0e2b73800512625a9fc5118557957ff3`
- **SHA verified:** OK (commit exists on YiAgent/OpenCI)

**Inputs passed (11 of 17):**

| Caller Input | Reusable Input | Status |
|---|---|---|
| `app-name` | `app-name` | OK |
| `image-name` | `image-name` | OK |
| `health-url` | `health-url` | OK |
| `runner` | `runner` | OK (overridden to `blacksmith-2vcpu-ubuntu-2404`) |
| `deploy-type` | `deploy-type` | OK |
| `ssh-host` | `ssh-host` | OK |
| `ssh-user` | `ssh-user` | OK |
| `ssh-port` | `ssh-port` | OK |
| `deploy-mode` | `deploy-mode` | OK |
| `compose-file` | `compose-file` | OK |
| `compose-project-dir` | `compose-project-dir` | OK |

**Inputs NOT passed (6):**

| Input | Default | Impact |
|---|---|---|
| `image-digest` | (none) | **CRITICAL** -- deploy image-ref will have empty digest |
| `openci-ref` | `main` | OK -- uses default |
| `registry` | `ghcr.io` | OK -- uses default |
| `k8s-namespace` | `staging` | OK -- uses default |
| `run-migration` | `false` | OK -- uses default |
| `docker-run-args` | `""` | OK -- uses default |

**Secrets passed (3 of 8):**

| Caller Secret | Reusable Secret | Status |
|---|---|---|
| `SLACK_WEBHOOK_URL` | `slack-webhook-url` | OK |
| `SENTRY_TOKEN` | `sentry-token` | OK |
| `DD_API_KEY` | `datadog-api-key` | OK |

**Secrets NOT passed (5):**

| Secret | Required By | Impact |
|---|---|---|
| `ssh-key-stg` | deploy-docker, auto-rollback-docker | **HIGH** -- Docker deploy will fail |
| `kubeconfig-stg` | deploy-k8s | HIGH -- K8s deploy will fail (but caller defaults to `docker` type) |
| `posthog-api-key` | notify-observability | LOW -- optional observability |
| `langsmith-api-key` | notify-observability | LOW -- optional observability |
| `axiom-token` | notify-observability | LOW -- optional observability |

**Output usage:** The `deploy-time` output is not directly consumed by `deploy.yml` itself. It is used internally by `schedule-prd-dispatch` via `needs.*.outputs`.

---

## Issues Found

### CRITICAL

| # | Issue | Location | Detail |
|---|---|---|---|
| 1 | **Missing `image-digest` input from caller** | `deploy.yml` -> `stg` job | The caller does not pass `image-digest`. Both `deploy-k8s` and `deploy-docker` construct `image-ref` as `registry/owner/name@${{ inputs.image-digest }}`, which will resolve to an empty digest, causing deploy failure. The `stg-agent-test` job in the same file uses `vars.STG_IMAGE_DIGEST` but this is not wired into the reusable call. |

### HIGH

| # | Issue | Location | Detail |
|---|---|---|---|
| 2 | **Missing `ssh-key-stg` secret from caller** | `deploy.yml` -> `stg` secrets | Docker deploy requires `secrets.ssh-key-stg` for SSH authentication. Preflight will fail the secrets probe. |
| 3 | **Missing `kubeconfig-stg` secret from caller** | `deploy.yml` -> `stg` secrets | K8s deploy requires `secrets.kubeconfig-stg`. Not critical since default deploy-type is `docker`, but will fail if `deploy-type` is set to `k8s`. |

### MEDIUM

| # | Issue | Location | Detail |
|---|---|---|---|
| 4 | **No `auto-rollback-k8s` job** | `reusable-stg.yml` | Docker path has `auto-rollback-docker` on smoke-test failure, but K8s path has no equivalent. K8s relies on native rollback strategies which may not be configured. |
| 5 | **Repetitive "Resolve OpenCI workflow ref" step** | All 11 jobs | The same 10-line shell script block is duplicated in every job. Could be extracted to a composite action or shared script for maintainability. |

### LOW

| # | Issue | Location | Detail |
|---|---|---|---|
| 6 | **Runner label mismatch** | `deploy.yml` | Caller uses `blacksmith-2vcpu-ubuntu-2404` (Blacksmith runner) while the reusable default is `ubuntu-latest`. This is intentional but consumers must ensure the runner label is available in their environment. |
| 7 | **`image-digest` is optional but semantically required** | `reusable-stg.yml` inputs | `image-digest` is marked `required: false` with no default, yet it is used unconditionally in deploy steps. Should either be `required: true` or the deploy steps should validate it is non-empty. |
| 8 | **`image-name` and `app-name` are optional but unconditionally used** | `reusable-stg.yml` inputs | Same pattern as above -- these have no defaults and are used in deploy and notification steps without guards. |

---

## Test Cases for Automation

### Structural Tests

| ID | Test | Expected |
|----|------|----------|
| T-01 | YAML parses without error | `yaml.safe_load` succeeds |
| T-02 | `actionlint` passes with exit code 0 | No warnings or errors |
| T-03 | All `uses:` SHA references resolve to valid commits | Each SHA exists on GitHub |
| T-04 | All local action paths (`./.openci/actions/...`) have `action.yml` | 11/11 paths valid |
| T-05 | `preflight-secrets.sh` script exists in `.github/scripts/` | File exists |
| T-06 | Top-level `permissions: {}` (no default permissions) | Verified |
| T-07 | Each job defines explicit `permissions` | All 11 jobs have scoped permissions |

### Input/Secret Contract Tests

| ID | Test | Expected |
|----|------|----------|
| T-08 | All caller inputs match reusable input names | No typos or mismatches |
| T-09 | All caller secret names match reusable secret names | No typos or mismatches |
| T-10 | `image-digest` is passed by caller OR has a default | **FAIL** -- neither condition met |
| T-11 | Required-for-deploy secrets (`ssh-key-stg` or `kubeconfig-stg`) are passed | **FAIL** -- neither is passed |

### Conditional Logic Tests

| ID | Test | Expected |
|----|------|----------|
| T-12 | `deploy-k8s` runs only when `deploy-type == 'k8s'` | Condition verified |
| T-13 | `deploy-docker` runs only when `deploy-type != 'k8s'` | Condition verified |
| T-14 | `run-migration` is skipped when `run-migration == false` | Condition verified |
| T-15 | `smoke-test` runs with `always()` but checks deploy success | Condition verified |
| T-16 | `auto-rollback-docker` fires only on smoke-test failure + docker success | Condition verified |
| T-17 | `coverage-gate` skips when `STG_COVERAGE_THRESHOLD` var is empty | Condition verified |
| T-18 | `perf-baseline` uses `continue-on-error: true` | Verified |
| T-19 | `notify-observability` uses `continue-on-error: true` | Verified |
| T-20 | `notify-deployed` runs with `always()` regardless of upstream results | Verified |

### Dependency Chain Tests

| ID | Test | Expected |
|----|------|----------|
| T-21 | `preflight` has no dependencies (runs first) | `needs: []` |
| T-22 | `coverage-gate` and `perf-baseline` depend only on `preflight` | Verified |
| T-23 | `deploy-k8s` and `deploy-docker` depend on all three gate jobs | `needs: [preflight, coverage-gate, perf-baseline]` |
| T-24 | `run-migration` depends on both deploy jobs | Verified |
| T-25 | `smoke-test` depends on deploy + migration | Verified |
| T-26 | Post-deploy jobs depend on deploy + smoke-test | Verified |

### Concurrency Tests

| ID | Test | Expected |
|----|------|----------|
| T-27 | Concurrency group is `deploy-stg-${{ github.ref }}` | Verified |
| T-28 | `cancel-in-progress: false` | Verified (never abandon half-deployed) |

### Output Tests

| ID | Test | Expected |
|----|------|----------|
| T-29 | `deploy-time` output uses fallback chain (`deploy-k8s \|\| deploy-docker`) | Verified |
| T-30 | `deploy-docker` exposes `previous-image` output for rollback | Verified |

---

## Summary

| Category | Count |
|----------|-------|
| actionlint | PASS (0 errors) |
| YAML syntax | PASS |
| SHA references | 3/3 verified |
| Local actions | 11/11 exist |
| CRITICAL issues | 1 |
| HIGH issues | 2 |
| MEDIUM issues | 2 |
| LOW issues | 3 |
| Total test cases | 30 |

**Bottom line:** The reusable workflow itself is well-structured with correct conditional logic, proper dependency chains, pinned SHA references, and scoped permissions. However, the primary caller (`deploy.yml`) has a **critical missing `image-digest` input** that would cause deploy failure at runtime, and is missing the `ssh-key-stg` secret required for the default docker deploy path. These caller-side gaps must be fixed before this workflow can succeed in production.

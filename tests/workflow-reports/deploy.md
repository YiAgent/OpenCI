# Workflow Test Report: deploy.yml

**File:** `.github/workflows/deploy.yml`
**Tested:** 2026-05-04
**HEAD:** `a2ec4435856d81e53e39206e371d021cab9159eb`

---

## Overview

`deploy.yml` is a routing workflow that dispatches staging and production deployments
to reusable workflows (`reusable-stg.yml` and `reusable-prd.yml`). It also contains
two inline jobs: `stg-agent-test` (L1-L4 autonomous staging tests) and `poll`
(observation-window dispatch). The workflow triggers on `workflow_run` (ci/release
completions) and `workflow_dispatch` (manual override).

---

## Validation Results

| Check                        | Result |
|------------------------------|--------|
| YAML syntax (Python yaml)   | VALID  |
| actionlint                   | PASS (0 errors, 0 warnings) |
| Reusable workflow exists (stg) | YES - `.github/workflows/reusable-stg.yml` |
| Reusable workflow exists (prd) | YES - `.github/workflows/reusable-prd.yml` |
| Local composite action `./actions/stg/agent-test` | EXISTS |
| Local composite action `./actions/_common/poll-prd-dispatch` | EXISTS |

---

## Node-by-Node Status

### 1. Trigger Events (`on:`)

| Event              | Config                                           | Status |
|--------------------|--------------------------------------------------|--------|
| `workflow_run`     | Workflows: `ci`, `release`; Types: `completed`   | OK     |
| `workflow_dispatch`| Input: `mode` (string, default `stg`)            | OK     |

**Notes:** The `workflow_dispatch` mode input accepts `stg`, `prd`, and `poll`.
Both `stg` and `prd` jobs have explicit `if:` guards that match on `inputs.mode`.
The `poll` job similarly guards on `inputs.mode == 'poll'`. No trigger misfires detected.

### 2. Permissions

Top-level permissions granted:

| Permission       | Value   | Rationale / Status |
|------------------|---------|--------------------|
| `contents`       | write   | Needed for release creation in prd reusable |
| `packages`       | read    | Container registry access |
| `id-token`       | write   | OIDC / keyless signing |
| `pull-requests`  | write   | PR comments from agent tests |
| `deployments`    | write   | Deployment status updates |
| `actions`        | write   | Repository dispatch / variable writes |
| `issues`         | write   | Auto-rollback issue creation |

**Status:** OK. The top-level permissions are a superset needed by all downstream
jobs. The inline `stg-agent-test` and `poll` jobs correctly narrow permissions at
the job level (principle of least privilege).

### 3. Concurrency

```yaml
group: deploy-${{ github.event_name }}-${{ github.event.workflow_run.id || github.ref }}
cancel-in-progress: false
```

**Status:** OK. The group key is unique per workflow_run ID (or ref for dispatch).
`cancel-in-progress: false` is correct for deploy workflows -- never abandon a
half-applied deployment.

**Note:** The reusable workflows define their own concurrency groups internally
(`deploy-stg-${{ github.ref }}`, `deploy-prd-${{ github.ref }}`). These are
independent and do not conflict.

### 4. Job: `stg`

| Property          | Value | Status |
|-------------------|-------|--------|
| Condition         | `(workflow_run.name == 'ci' && conclusion == 'success') \|\| (dispatch && mode == 'stg')` | OK |
| Uses              | `YiAgent/OpenCI/.github/workflows/reusable-stg.yml@f62931bd...` | OK |
| SHA in manifest?  | Yes -- `f62931bd0e2b73800512625a9fc5118557957ff3` matches manifest entry | OK |

**Input mapping analysis:**

| Input passed       | Source                     | Status |
|--------------------|----------------------------|--------|
| `app-name`         | `vars.APP_NAME \|\| repo.name` | OK |
| `image-name`       | `vars.IMAGE_NAME \|\| repo.name` | OK |
| `health-url`       | `vars.STG_HEALTH_URL`      | OK |
| `runner`           | `blacksmith-2vcpu-ubuntu-2404` (hardcoded) | WARN -- see Issues |
| `deploy-type`      | `vars.DEPLOY_TYPE \|\| 'docker'` | OK |
| `ssh-host`         | `vars.STG_SSH_HOST`        | OK |
| `ssh-user`         | `vars.STG_SSH_USER \|\| 'deploy'` | OK |
| `ssh-port`         | `vars.STG_SSH_PORT \|\| '22'` | OK |
| `deploy-mode`      | `vars.DEPLOY_MODE \|\| 'compose'` | OK |
| `compose-file`     | `vars.COMPOSE_FILE \|\| 'docker-compose.yml'` | OK |
| `compose-project-dir` | `vars.COMPOSE_PROJECT_DIR \|\| '~'` | OK |
| **`image-digest`** | **NOT PASSED**             | **ISSUE** |

**Secret mapping analysis:**

| Secret passed       | Source                    | Reusable expects   | Status |
|---------------------|---------------------------|--------------------| --------|
| `slack-webhook-url` | `secrets.SLACK_WEBHOOK_URL` | `slack-webhook-url` | OK |
| `sentry-token`      | `secrets.SENTRY_TOKEN`    | `sentry-token`     | OK |
| `datadog-api-key`   | `secrets.DD_API_KEY`      | `datadog-api-key`  | OK |
| **`ssh-key-stg`**   | **NOT PASSED**            | `ssh-key-stg`      | **ISSUE** |

### 5. Job: `prd`

| Property          | Value | Status |
|-------------------|-------|--------|
| Condition         | `(workflow_run.name == 'release' && conclusion == 'success') \|\| (dispatch && mode == 'prd')` | OK |
| Uses              | `YiAgent/OpenCI/.github/workflows/reusable-prd.yml@f62931bd...` | OK |
| SHA in manifest?  | Yes -- matches manifest entry | OK |

**Input mapping analysis:**

| Input passed       | Source                     | Status |
|--------------------|----------------------------|--------|
| `app-name`         | `vars.APP_NAME \|\| repo.name` | OK |
| `image-name`       | `vars.IMAGE_NAME \|\| repo.name` | OK |
| `health-url`       | `vars.PRD_HEALTH_URL`      | OK |
| `runner`           | `blacksmith-2vcpu-ubuntu-2404` (hardcoded) | WARN |
| `deploy-type`      | `vars.DEPLOY_TYPE \|\| 'docker'` | OK |
| `ssh-host`         | `vars.PRD_SSH_HOST`        | OK |
| `ssh-user`         | `vars.PRD_SSH_USER \|\| 'deploy'` | OK |
| `ssh-port`         | `vars.PRD_SSH_PORT \|\| '22'` | OK |
| `deploy-mode`      | `vars.DEPLOY_MODE \|\| 'compose'` | OK |
| `compose-file`     | `vars.COMPOSE_FILE \|\| 'docker-compose.yml'` | OK |
| `compose-project-dir` | `vars.COMPOSE_PROJECT_DIR \|\| '~'` | OK |
| **`image-digest`** | **NOT PASSED**             | **CRITICAL** |
| **`stg-image-digest`** | **NOT PASSED**         | **CRITICAL** |
| **`stg-deploy-time`**  | **NOT PASSED**         | **CRITICAL** |

**Secret mapping analysis:**

| Secret passed        | Source                      | Reusable expects    | Status |
|----------------------|-----------------------------|---------------------| ------ |
| `anthropic-api-key`  | `secrets.ANTHROPIC_API_KEY` | `anthropic-api-key` | OK |
| `api-base-url`       | `secrets.ANTHROPIC_BASE_URL`| `api-base-url`      | OK |
| `slack-webhook-url`  | `secrets.SLACK_WEBHOOK_URL` | `slack-webhook-url` | OK |
| `sentry-token`       | `secrets.SENTRY_TOKEN`      | `sentry-token`      | OK |
| `datadog-api-key`    | `secrets.DD_API_KEY`        | `datadog-api-key`   | OK |
| **`ssh-key-prd`**    | **NOT PASSED**              | `ssh-key-prd`       | **ISSUE** |
| **`kubeconfig-prd`** | **NOT PASSED**              | `kubeconfig-prd`    | **ISSUE** |

### 6. Job: `stg-agent-test`

| Property          | Value | Status |
|-------------------|-------|--------|
| Condition         | `workflow_run.name == 'ci' && conclusion == 'success'` | OK (only runs after CI success) |
| `needs`           | `stg` | OK (runs after staging deploy) |
| Runner            | `blacksmith-2vcpu-ubuntu-2404` | OK |
| Timeout           | 30 min | OK |
| Matrix            | `level: [1, 2, 3, 4]` | OK |
| `fail-fast`       | false | OK (all levels run independently) |

**Steps:**
1. `step-security/harden-runner` -- SHA matches manifest -- OK
2. `actions/checkout` -- SHA matches manifest -- OK
3. Gate step (skip if `ANTHROPIC_API_KEY` missing) -- OK
4. `./actions/stg/agent-test` composite action -- EXISTS locally -- OK
5. `actions/upload-artifact` -- SHA matches manifest -- OK

**Permissions (job-level override):**
- `contents: read` -- OK
- `id-token: write` -- OK (for OIDC token exchange)

### 7. Job: `poll`

| Property          | Value | Status |
|-------------------|-------|--------|
| Condition         | `workflow_dispatch && mode == 'poll'` | OK |
| Runner            | `blacksmith-2vcpu-ubuntu-2404` | OK |
| Timeout           | 5 min | OK |

**Steps:**
1. `step-security/harden-runner` -- SHA matches manifest -- OK
2. `actions/checkout` -- SHA matches manifest -- OK
3. `./actions/_common/poll-prd-dispatch` -- EXISTS locally -- OK
4. Conditional `gh api` dispatch loop -- OK

**Permissions (job-level override):**
- `contents: read` -- OK
- `actions: write` -- OK (needed for `gh api ... /dispatches`)

### 8. SHA Reference Audit

| Reference                                         | SHA (first 8) | In manifest? | Status |
|---------------------------------------------------|---------------|--------------|--------|
| `YiAgent/OpenCI/.github/workflows/reusable-stg.yml@` | `f62931bd` | Yes | OK (stale -- see note) |
| `YiAgent/OpenCI/.github/workflows/reusable-prd.yml@` | `f62931bd` | Yes | OK (stale -- see note) |
| `step-security/harden-runner@`                    | `f808768d`    | Yes (v2.17.0) | OK |
| `actions/checkout@`                               | `11bd7190`    | Yes (v4.2.2)  | OK |
| `actions/upload-artifact@`                        | `ea165f8d`    | Yes (v4.6.2)  | OK |

**Staleness note:** HEAD is at `a2ec443` (2 commits ahead of `f62931b`). The
reusable workflow SHA `f62931bd` is consistent with the manifest but does not
include the latest 2 commits (`ca8a3a6`, `a2ec443`). This is expected if the
manifest was last bumped after PR #79 and the subsequent commits are unrelated
to the reusable workflows. However, consumers get a slightly older version of
the reusable workflows until the next manifest bump.

---

## Issues Found

### CRITICAL

#### C1: `image-digest` not passed to `prd` job

**Location:** Lines 56-81 (prd job `with:` block)
**Impact:** The `prd` reusable workflow requires `image-digest` for deploy steps
(`deploy-k8s`, `deploy-docker`, `auto-rollback`). Without it, the image ref
constructs to `ghcr.io/<owner>/<name>@` (empty digest), causing deployment failure.
The `pre-check` job also uses it for observe-window verification.
**Fix:** Add `image-digest: ${{ vars.PRD_IMAGE_DIGEST }}` (or derive from the
triggering release workflow output) to the prd `with:` block.

#### C2: `stg-image-digest` and `stg-deploy-time` not passed to `prd` job

**Location:** Lines 56-81 (prd job `with:` block)
**Impact:** The `prd` reusable workflow's `pre-check` job uses `stg-image-digest`
and `stg-deploy-time` for observe-window verification. Without these, the
pre-check either fails or skips the staging-to-production safety gate, potentially
allowing unvalidated images to deploy to production.
**Fix:** Add:
```yaml
stg-image-digest: ${{ vars.STG_IMAGE_DIGEST }}
stg-deploy-time:  ${{ vars.STG_DEPLOY_TIME }}
```

#### C3: `image-digest` not passed to `stg` job

**Location:** Lines 31-54 (stg job `with:` block)
**Impact:** Same as C1 but for staging. The `deploy-docker` and `deploy-k8s` steps
in `reusable-stg.yml` construct the image ref using `image-digest`. An empty digest
means the deploy step references an invalid image.
**Fix:** Add `image-digest: ${{ vars.STG_IMAGE_DIGEST }}` to the stg `with:` block.

### HIGH

#### H1: `ssh-key-stg` not passed to `stg` reusable workflow

**Location:** Lines 51-54 (stg job `secrets:` block)
**Impact:** The `reusable-stg.yml` preflight step runs a secrets probe that
requires `SSH_KEY_STG` when `deploy-type == 'docker'` (the default). Without it,
the preflight fails and blocks the entire staging deployment.
**Fix:** Add `ssh-key-stg: ${{ secrets.SSH_KEY_STG }}` to the stg `secrets:` block.

#### H2: `ssh-key-prd` not passed to `prd` reusable workflow

**Location:** Lines 76-81 (prd job `secrets:` block)
**Impact:** Same as H1 but for production Docker deploy. The preflight requires
`SSH_KEY_PRD` for Docker-type deploys.
**Fix:** Add `ssh-key-prd: ${{ secrets.SSH_KEY_PRD }}` to the prd `secrets:` block.

#### H3: `kubeconfig-prd` not passed to `prd` reusable workflow

**Location:** Lines 76-81 (prd job `secrets:` block)
**Impact:** If `deploy-type` is set to `k8s`, the preflight requires
`KUBECONFIG_PRD`. Without it, K8s deploys fail. This is only critical when
K8s deploy type is selected.
**Fix:** Add `kubeconfig-prd: ${{ secrets.KUBECONFIG_PRD }}` to the prd `secrets:` block.

### MEDIUM

#### M1: Runner label hardcoded to `blacksmith-2vcpu-ubuntu-2404`

**Location:** Lines 42, 67, 93, 138
**Impact:** The reusable workflows default to `ubuntu-latest`. The deploy.yml
overrides this to a Blacksmith runner. If the repo moves off Blacksmith or the
runner label changes, all four locations must be updated. Also, self-hosted
runners named `blacksmith-*` may not be available in forks.
**Fix:** Consider using a variable: `runner: ${{ vars.DEPLOY_RUNNER || 'ubuntu-latest' }}`

#### M2: `kubeconfig-stg` not passed to `stg` reusable workflow

**Location:** Lines 51-54 (stg job `secrets:` block)
**Impact:** If `deploy-type` is set to `k8s`, the preflight requires
`KUBECONFIG_STG`. Low severity because the default deploy type is `docker`.
**Fix:** Add `kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}` to the stg `secrets:` block.

#### M3: Observability secrets not forwarded

**Location:** stg `secrets:` block (lines 51-54)
**Impact:** The `reusable-stg.yml` `notify-observability` step accepts optional
secrets: `posthog-api-key`, `langsmith-api-key`, `axiom-token`. These are not
passed from `deploy.yml`. Observability notifications will be incomplete if
these integrations are configured.
**Fix:** Add optional secret forwards:
```yaml
posthog-api-key:   ${{ secrets.POSTHOG_API_KEY }}
langsmith-api-key: ${{ secrets.LANGSMITH_API_KEY }}
axiom-token:       ${{ secrets.AXIOM_TOKEN }}
```
(Same applies to the `prd` job.)

### LOW

#### L1: `vars.DEPLOY_MODE` shared across stg and prd

**Location:** Lines 47, 72
**Impact:** Both stg and prd use `vars.DEPLOY_MODE`. If staging needs `compose`
but production needs `run`, there is no way to differentiate with a single variable.
**Fix:** Consider `vars.STG_DEPLOY_MODE` / `vars.PRD_DEPLOY_MODE` with fallback
to `vars.DEPLOY_MODE`.

#### L2: `vars.COMPOSE_FILE` and `vars.COMPOSE_PROJECT_DIR` shared across stg and prd

**Location:** Lines 48-49, 73-74
**Impact:** Same as L1 -- staging and production may need different compose files
or project directories.
**Fix:** Same pattern: per-environment vars with fallback.

---

## Test Cases for Automation

### TC1: YAML Syntax Validation
```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))"
Expected: exit 0
```

### TC2: actionlint Static Analysis
```
actionlint .github/workflows/deploy.yml
Expected: exit 0, no output
```

### TC3: SHA Manifest Consistency
```
For each `uses:` with `@<sha>` in deploy.yml:
  - Verify SHA exists in manifest.yml deps section
Expected: all SHAs match manifest entries
```

### TC4: Reusable Workflow Existence
```
For each `uses:` referencing a local reusable workflow:
  - Verify the file exists at the referenced path
Expected: reusable-stg.yml and reusable-prd.yml both exist
```

### TC5: Required Inputs Coverage
```
For each reusable workflow called from deploy.yml:
  - Collect all `required: true` inputs from the reusable workflow definition
  - Verify every required input is passed in the `with:` block
Expected: no required input is missing
Current: FAILS -- image-digest, stg-image-digest, stg-deploy-time not passed
```

### TC6: Required Secrets Coverage
```
For each reusable workflow called from deploy.yml:
  - Collect all secrets used in steps (even if `required: false`)
  - Verify secrets needed for default deploy paths are forwarded
Expected: ssh-key-stg, ssh-key-prd are passed for docker deploy path
Current: FAILS -- ssh-key-stg and ssh-key-prd missing
```

### TC7: Condition Logic -- Staging Trigger
```
Simulate: workflow_run event, workflow.name == 'ci', conclusion == 'success'
Expected: stg job runs, prd job skipped, stg-agent-test runs, poll skipped
```

### TC8: Condition Logic -- Production Trigger
```
Simulate: workflow_run event, workflow.name == 'release', conclusion == 'success'
Expected: prd job runs, stg job skipped, stg-agent-test skipped, poll skipped
```

### TC9: Condition Logic -- Manual Staging Dispatch
```
Simulate: workflow_dispatch, inputs.mode == 'stg'
Expected: stg job runs, prd job skipped, stg-agent-test skipped, poll skipped
```

### TC10: Condition Logic -- Manual Production Dispatch
```
Simulate: workflow_dispatch, inputs.mode == 'prd'
Expected: prd job runs, stg job skipped, stg-agent-test skipped, poll skipped
```

### TC11: Condition Logic -- Poll Dispatch
```
Simulate: workflow_dispatch, inputs.mode == 'poll'
Expected: poll job runs, stg/prd/stg-agent-test all skipped
```

### TC12: Condition Logic -- Failed Workflow Run
```
Simulate: workflow_run event, workflow.name == 'ci', conclusion == 'failure'
Expected: all jobs skipped (stg condition requires 'success')
```

### TC13: Concurrency Group Uniqueness
```
Verify concurrency group key produces unique values for:
  - Different workflow_run IDs
  - Different refs on dispatch
Expected: no collisions between concurrent deploys
```

### TC14: Agent Test Gate -- Missing API Key
```
Simulate: stg-agent-test runs but ANTHROPIC_API_KEY is empty
Expected: gate step sets skip=true, agent-test action skipped, artifact upload skipped
```

### TC15: Agent Test Matrix Independence
```
Verify fail-fast: false means all 4 matrix levels run even if one fails
Expected: levels 1-4 all execute independently
```

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3     |
| HIGH     | 3     |
| MEDIUM   | 3     |
| LOW      | 2     |

The workflow is syntactically valid and passes actionlint. The structural design
(trigger routing, concurrency, permissions, matrix strategy) is sound. However,
there are critical missing input and secret forwards that would cause deployment
failures at runtime -- particularly the missing `image-digest` for both stg and
prd, and missing SSH keys for Docker deploy paths. These must be addressed before
the workflow can successfully deploy.

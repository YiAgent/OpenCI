# Workflow Test Report: reusable-prd.yml

**File:** `.github/workflows/reusable-prd.yml`
**Date:** 2026-05-04
**actionlint:** PASS (no errors)
**YAML syntax:** VALID

---

## Overview

Reusable production deploy workflow implementing SPEC section 5.5. It provides a full deploy pipeline with environment gate, supporting both Kubernetes and Docker deployment modes. The pipeline includes preflight checks, a human approval gate via `environment: production`, migration support, smoke testing, auto-rollback on failure, GitHub release creation, and observability notifications.

**Critical sequence:**
```
preflight -> pre-check -> deploy-k8s | deploy-docker -> run-migration? -> smoke-test
                          |                                              |
                          +-> auto-rollback (on smoke failure)           +-> create-release + notify-deployed + notify-observability
```

---

## Inputs/Secrets/Outputs Definition

### Inputs (18 total)

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `model` | string | false | `""` | AI model name override |
| `openci-ref` | string | false | `main` | OpenCI ref for .openci/* vendor references |
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |
| `image-digest` | string | false | - | Container image digest |
| `stg-image-digest` | string | false | - | Staging image digest (for pre-check) |
| `stg-deploy-time` | string | false | - | Staging deploy timestamp (for observe window) |
| `image-name` | string | false | - | Container image name |
| `registry` | string | false | `ghcr.io` | Container registry |
| `app-name` | string | false | - | Application name |
| `health-url` | string | false | - | Health check endpoint URL |
| `observation-minutes` | number | false | `30` | Observe window duration |
| `k8s-namespace` | string | false | `production` | K8s namespace |
| `run-migration` | boolean | false | `false` | Whether to run DB migration |
| `deploy-type` | string | false | `docker` | Deployment mechanism: docker or k8s |
| `ssh-host` | string | false | `""` | Target server hostname/IP (docker) |
| `ssh-user` | string | false | `deploy` | SSH user (docker) |
| `ssh-port` | string | false | `"22"` | SSH port (docker) |
| `deploy-mode` | string | false | `compose` | Docker deploy mode: compose or run |
| `compose-file` | string | false | `docker-compose.yml` | Path to docker-compose.yml |
| `compose-project-dir` | string | false | `~` | Working directory on server |
| `docker-run-args` | string | false | `""` | Extra args for docker run |

### Secrets (10 total, all optional)

| Secret | Description |
|--------|-------------|
| `anthropic-api-key` | Anthropic API key for AI changelog |
| `api-base-url` | Custom Anthropic-compatible base URL |
| `kubeconfig-prd` | Kubeconfig for production K8s |
| `ssh-key-prd` | SSH key for docker deploy |
| `slack-webhook-url` | Slack notification webhook |
| `sentry-token` | Sentry error tracking token |
| `datadog-api-key` | Datadog monitoring API key |
| `posthog-api-key` | PostHog analytics API key |
| `langsmith-api-key` | LangSmith tracing API key |
| `axiom-token` | Axiom logging token |

### Outputs

None defined at the workflow level. Job-level outputs exist:
- `deploy-k8s` outputs: `deploy-time`, `previous-revision`
- `deploy-docker` outputs: `deploy-time`, `previous-image`

---

## Node-by-Node Status

### Job: `preflight`
- **Status:** PASS
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 2 min
- **Permissions:** `contents: read`
- **Dependencies:** None
- **Steps:**
  1. `step-security/harden-runner@f808768d...` -- SHA-pinned, OK
  2. `actions/checkout@11bd7190...` -- SHA-pinned, OK
  3. Resolve OpenCI workflow ref (shell) -- parses `inputs.openci-ref` or `workflow_ref`
  4. Checkout OpenCI for local actions (`YiAgent/OpenCI` at resolved ref)
  5. Probe secrets -- calls `.github/scripts/preflight-secrets.sh` (EXISTS locally). Branches on `deploy-type`: requires `KUBECONFIG_PRD` for k8s, `SSH_KEY_PRD` for docker.
  6. `./.openci/actions/deploy/preflight` -- local composite action

### Job: `pre-check`
- **Status:** PASS
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 45 min
- **Permissions:** `contents: read`
- **Dependencies:** `preflight`
- **Steps:**
  1. harden-runner, checkout, resolve-ref, checkout-openci (same pattern)
  2. `./.openci/actions/prd/pre-check` -- checks image-digest alignment, observe window, optional Sentry error rate gate
- **Notes:** Uses `vars.SENTRY_ORG` and `vars.SENTRY_PROJECT` repo variables.

### Job: `deploy-k8s`
- **Status:** PASS
- **Condition:** `inputs.deploy-type == 'k8s'`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Environment:** `production` (human gate)
- **Permissions:** `contents: read`
- **Dependencies:** `pre-check`
- **Outputs:** `deploy-time`, `previous-revision`
- **Steps:** standard pattern + `./.openci/actions/prd/deploy-k8s`

### Job: `deploy-docker`
- **Status:** PASS
- **Condition:** `inputs.deploy-type != 'k8s'`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Environment:** `production` (human gate)
- **Permissions:** `contents: read`
- **Dependencies:** `pre-check`
- **Outputs:** `deploy-time`, `previous-image`
- **Steps:** standard pattern + `./.openci/actions/deploy/docker`

### Job: `run-migration`
- **Status:** PASS
- **Condition:** `inputs.run-migration == true && (needs.deploy-k8s.result == 'success' || needs.deploy-docker.result == 'success')`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Environment:** `production`
- **Permissions:** `contents: read`
- **Dependencies:** `[deploy-k8s, deploy-docker]`
- **Steps:** standard pattern + `./.openci/actions/_common/run-migration`
- **Notes:** Uses `vars.MIGRATION_APPLY_CMD` with fallback `'false'`.

### Job: `smoke-test`
- **Status:** PASS
- **Condition:** `always() && (deploy-k8s success OR deploy-docker success) && (run-migration success OR skipped)`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`
- **Dependencies:** `[deploy-k8s, deploy-docker, run-migration]`
- **Steps:** standard pattern + `./.openci/actions/prd/smoke-test`

### Job: `auto-rollback` (K8s)
- **Status:** PASS
- **Condition:** `always() && smoke-test failure && deploy-k8s success`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`, `issues: write`
- **Dependencies:** `[deploy-k8s, smoke-test]`
- **Steps:** standard pattern + configure kubectl from base64 kubeconfig + `./.openci/actions/prd/auto-rollback`
- **Notes:** Decodes `kubeconfig-prd` secret from base64, writes to `$RUNNER_TEMP`, masks it.

### Job: `auto-rollback-docker`
- **Status:** PASS
- **Condition:** `always() && smoke-test failure && deploy-docker success`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Permissions:** `contents: read`, `issues: write`
- **Dependencies:** `[deploy-docker, smoke-test]`
- **Steps:** standard pattern + `./.openci/actions/deploy/auto-rollback-docker`

### Job: `create-release`
- **Status:** PASS
- **Condition:** `github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: write`
- **Dependencies:** `smoke-test`
- **Steps:** standard pattern + `./.openci/actions/prd/create-release`
- **Notes:** Only runs on tag pushes. Uses `anthropic-api-key` and `api-base-url` secrets for AI changelog generation.

### Job: `notify-observability`
- **Status:** PASS
- **Condition:** `always() && (deploy-k8s success OR deploy-docker success)`
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: read`
- **continue-on-error:** true
- **Dependencies:** `[deploy-k8s, deploy-docker, smoke-test]`
- **Steps:** standard pattern + `./.openci/actions/integrations/notify-deploy`
- **Notes:** Fans out to 5 observability platforms (Sentry, Datadog, PostHog, LangSmith, Axiom), each gated by `vars.ENABLE_*` flags.

### Job: `notify-deployed`
- **Status:** PASS
- **Condition:** `always()` (always runs)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Permissions:** `contents: read`
- **Dependencies:** `[deploy-k8s, deploy-docker, smoke-test]`
- **Steps:** standard pattern + `./.openci/actions/_common/notify-deployed`
- **Notes:** Sends Slack notification with computed status string.

---

## Callers Analysis

### Caller: `.github/workflows/deploy.yml`

**Reference:** `YiAgent/OpenCI/.github/workflows/reusable-prd.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

**SHA verification:** `f62931b` resolves locally -- "Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults". Valid.

**Caller condition:**
```yaml
if: >-
  (github.event_name == 'workflow_run'
    && github.event.workflow_run.name == 'release'
    && github.event.workflow_run.conclusion == 'success')
  || (github.event_name == 'workflow_dispatch' && inputs.mode == 'prd')
```

**Inputs passed by caller vs. reusable definition:**

| Caller Input | Reusable Input | Match? |
|-------------|---------------|--------|
| `app-name: ${{ vars.APP_NAME \|\| ... }}` | `app-name` | OK |
| `image-name: ${{ vars.IMAGE_NAME \|\| ... }}` | `image-name` | OK |
| `health-url: ${{ vars.PRD_HEALTH_URL }}` | `health-url` | OK |
| `runner: blacksmith-2vcpu-ubuntu-2404` | `runner` | OK |
| `deploy-type: ${{ vars.DEPLOY_TYPE \|\| 'docker' }}` | `deploy-type` | OK |
| `ssh-host: ${{ vars.PRD_SSH_HOST }}` | `ssh-host` | OK |
| `ssh-user: ${{ vars.PRD_SSH_USER \|\| 'deploy' }}` | `ssh-user` | OK |
| `ssh-port: ${{ vars.PRD_SSH_PORT \|\| '22' }}` | `ssh-port` | OK |
| `deploy-mode: ${{ vars.DEPLOY_MODE \|\| 'compose' }}` | `deploy-mode` | OK |
| `compose-file: ${{ vars.COMPOSE_FILE \|\| 'docker-compose.yml' }}` | `compose-file` | OK |
| `compose-project-dir: ${{ vars.COMPOSE_PROJECT_DIR \|\| '~' }}` | `compose-project-dir` | OK |

**Inputs NOT passed by caller (use defaults):**
- `model` (default: `""`)
- `openci-ref` (default: `main`)
- `image-digest` (no default -- will be empty)
- `stg-image-digest` (no default)
- `stg-deploy-time` (no default)
- `registry` (default: `ghcr.io`)
- `observation-minutes` (default: `30`)
- `k8s-namespace` (default: `production`)
- `run-migration` (default: `false`)
- `docker-run-args` (default: `""`)

**Secrets passed by caller:**

| Caller Secret | Reusable Secret | Match? |
|--------------|----------------|--------|
| `secrets.ANTHROPIC_API_KEY` | `anthropic-api-key` | OK |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` | OK |
| `secrets.SLACK_WEBHOOK_URL` | `slack-webhook-url` | OK |
| `secrets.SENTRY_TOKEN` | `sentry-token` | OK |
| `secrets.DD_API_KEY` | `datadog-api-key` | OK |

**Secrets NOT passed (gracefully skipped):**
- `kubeconfig-prd` -- only needed for k8s deploy
- `ssh-key-prd` -- only needed for docker deploy (MISSING from caller)
- `posthog-api-key`
- `langsmith-api-key`
- `axiom-token`

---

## Issues Found

### MEDIUM: Caller does not pass `ssh-key-prd` secret

The `deploy.yml` caller does not map `ssh-key-prd` to any caller secret. For docker deploys (the default `deploy-type`), the preflight job requires `SSH_KEY_PRD` as a mandatory secret. This will cause the preflight to fail for any consumer that does not provide this secret via some other mechanism.

**Impact:** If `deploy-type == 'docker'` (the default), the preflight step will fail with "Missing Secret: SSH_KEY_PRD" unless the consuming repository has configured this secret at the org or environment level and uses `secrets: inherit`.

**Fix:** Add `ssh-key-prd: ${{ secrets.PRD_SSH_KEY }}` (or similar) to the `deploy.yml` caller's `secrets:` block.

### MEDIUM: Caller does not pass `image-digest` input

The `deploy.yml` caller does not pass `image-digest`. Several downstream jobs construct the full image reference as `${{ inputs.registry }}/${{ github.repository_owner }}/${{ inputs.image-name }}@${{ inputs.image-digest }}`. An empty `image-digest` will produce an invalid image reference (e.g., `ghcr.io/owner/app@`), which will fail at deploy time.

**Impact:** Both `deploy-k8s` and `deploy-docker` jobs will produce malformed image refs. The `pre-check` job's observe-window logic also depends on `stg-image-digest` and `stg-deploy-time`.

**Fix:** The caller should populate `image-digest` from the triggering workflow_run's outputs or from repository variables (e.g., `vars.IMAGE_DIGEST`).

### LOW: `image-digest`, `stg-image-digest`, `stg-deploy-time` have no defaults

These three inputs are `required: false` with no default value, meaning they will be empty strings when not provided. The workflow does not validate their presence before use in downstream jobs. Only `pre-check` and the deploy jobs consume them, but empty values will cause silent failures or invalid image references rather than a clear error.

### LOW: Duplicated "Resolve OpenCI workflow ref" step

The identical 12-line shell block for resolving the OpenCI ref is copy-pasted into all 11 jobs. This is a maintenance burden. Consider extracting it into a composite action or using a reusable workflow pattern.

### INFO: `create-release` condition may never fire via `workflow_call`

The `create-release` job has `if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')`. When invoked via `workflow_call` (as from `deploy.yml`), `github.event_name` will be `workflow_run` or `workflow_dispatch`, not `push`. This job will only fire when the workflow is triggered directly by a tag push event (which the current triggers do not include -- only `workflow_call` is defined).

### INFO: No `workflow_dispatch` or tag-push triggers

The file header comments mention `workflow_dispatch` (manual emergency) and `push tags v*` as triggers, but the `on:` block only defines `workflow_call`. The comments are aspirational or the triggers were removed. This is not a bug but a documentation inconsistency.

### INFO: Top-level `permissions: {}` is correct

The workflow sets `permissions: {}` at the top level (deny-all) and grants per-job permissions. This is a security best practice.

---

## Test Cases for Automation

### TC-01: YAML Syntax Validation
- **Action:** Parse with `yaml.safe_load()`
- **Expected:** No exception
- **Status:** PASS

### TC-02: actionlint Static Analysis
- **Action:** Run `actionlint reusable-prd.yml`
- **Expected:** No errors
- **Status:** PASS

### TC-03: All `uses:` Actions Have SHA Pins
- **Action:** Grep for `uses:` lines; verify all external actions use `@<40-char-hex>` format
- **Expected:** All external actions SHA-pinned
- **Status:** PASS (22 SHA-pinned refs: 11x harden-runner, 11x checkout)

### TC-04: Local Actions Exist at Runtime
- **Action:** Verify all `./.openci/actions/...` paths are checked out before use
- **Expected:** Each job checks out `.openci` before referencing local actions
- **Status:** PASS (all 11 jobs follow checkout-then-use pattern)

### TC-05: Mutual Exclusion of Deploy Jobs
- **Action:** Verify `deploy-k8s` has `if: inputs.deploy-type == 'k8s'` and `deploy-docker` has `if: inputs.deploy-type != 'k8s'`
- **Expected:** Exactly one deploy job runs
- **Status:** PASS

### TC-06: Smoke Test Runs After Migration
- **Action:** Verify `smoke-test` depends on `[deploy-k8s, deploy-docker, run-migration]` and condition checks migration result
- **Expected:** Smoke test waits for migration if enabled
- **Status:** PASS

### TC-07: Auto-Rollback Triggers on Smoke Failure
- **Action:** Verify `auto-rollback` condition: `always() && smoke-test failure && deploy-k8s success`
- **Expected:** Rollback only when deploy succeeded but smoke failed
- **Status:** PASS (both k8s and docker variants)

### TC-08: Caller Input Compatibility
- **Action:** Compare `deploy.yml` caller inputs against `reusable-prd.yml` input definitions
- **Expected:** All caller inputs map to defined inputs; no typos
- **Status:** PASS (11 inputs match)

### TC-09: Caller Secret Compatibility
- **Action:** Compare `deploy.yml` caller secrets against `reusable-prd.yml` secret definitions
- **Expected:** All mapped secrets have matching names
- **Status:** PASS (5 secrets mapped correctly). Note: `ssh-key-prd` not mapped (see Issues).

### TC-10: Preflight Script Exists
- **Action:** Check `.github/scripts/preflight-secrets.sh` exists and is executable
- **Expected:** File exists with valid shell syntax
- **Status:** PASS

### TC-11: Concurrency Group
- **Action:** Verify concurrency group prevents parallel production deploys
- **Expected:** `group: deploy-prd-${{ github.ref }}`, `cancel-in-progress: false`
- **Status:** PASS

### TC-12: Environment Gate
- **Action:** Verify `deploy-k8s`, `deploy-docker`, and `run-migration` use `environment: { name: production }`
- **Expected:** Human approval gate present on deploy and migration jobs
- **Status:** PASS

### TC-13: Permission Scoping
- **Action:** Verify top-level `permissions: {}` and per-job least-privilege grants
- **Expected:** No job has excessive permissions
- **Status:** PASS. Only `auto-rollback*` and `create-release` have write permissions (`issues: write` and `contents: write` respectively).

### TC-14: `notify-deployed` Always Runs
- **Action:** Verify `notify-deployed` has `if: always()` and depends on all deploy + smoke jobs
- **Expected:** Slack notification sent regardless of outcome
- **Status:** PASS

### TC-15: SHA Reference Validity
- **Action:** Verify `f62931bd0e2b73800512625a9fc5118557957ff3` exists in git history
- **Expected:** SHA resolves to a valid commit
- **Status:** PASS (resolves to "Merge pull request #79")

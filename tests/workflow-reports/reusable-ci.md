# Workflow Test Report: reusable-ci.yml

**Generated:** 2026-05-04
**File:** `.github/workflows/reusable-ci.yml`
**Workflow name:** `ci`

---

## Overview

This is a reusable workflow (`workflow_call`) implementing a 4-stage CI pipeline for the OpenCI AI-agent CI platform. It builds a Docker image, runs parallel verification jobs (scan, sign, SBOM, SHA consistency, optional migration/AI smoke), aggregates results through an enrichment step, optionally runs an AI failure-analysis agent, and dispatches a deploy workflow on clean builds.

**actionlint result:** PASS (no errors)
**YAML syntax:** VALID

---

## Inputs/Secrets/Outputs Definition

### Inputs (12)

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `model` | string | no | `""` | Override AI model name |
| `openci-ref` | string | no | `"main"` | OpenCI ref for ./.openci/* references |
| `runner` | string | no | `"ubuntu-latest"` | Runner label for all jobs |
| `language` | string | no | `""` | Override detected language |
| `registry` | string | no | `"ghcr.io"` | Container registry |
| `image-name` | string | **yes** | — | Image name for Docker tags |
| `enable-ai-smoke` | boolean | no | `false` | Run AI smoke eval |
| `run-migration` | boolean | no | `false` | Run migration check |
| `enable-failure-agent` | boolean | no | `true` | Run AI failure-analysis agent |
| `auto-deploy` | boolean | no | `false` | Auto-trigger deploy on clean build |
| `deploy-workflow` | string | no | `"deploy.yml"` | Deploy workflow filename |
| `deploy-environment` | string | no | `"staging"` | Deploy environment name |

### Secrets (3, all optional)

| Name | Description |
|------|-------------|
| `api-base-url` | Custom Anthropic-compatible base URL |
| `registry-token` | Token for registry push (falls back to `github.token`) |
| `anthropic-api-key` | Anthropic API key for AI features |

### Outputs (3)

| Name | Source | Description |
|------|--------|-------------|
| `image-digest` | `jobs.build-docker.outputs.image-digest` | sha256 digest of pushed image |
| `deploy-time` | `jobs.build-docker.outputs.completed-at` | ISO 8601 build completion timestamp |
| `deploy-ready` | `jobs.execute.outputs.deploy-ready` | `'true'` when safe to deploy |

---

## Node-by-Node Status

### Stage 1: Build

#### `preflight` (line 117)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 2 min
- **Permissions:** `contents: read`
- **Steps:**
  1. `step-security/harden-runner@f808768...` -- egress-policy: audit -- **PASS** (SHA matches manifest)
  2. `actions/checkout@11bd7190...` -- persist-credentials: false -- **PASS** (SHA matches manifest)
  3. `YiAgent/OpenCI/actions/_common/resolve-openci@f62931bd...` -- **PASS** (SHA matches manifest key `YiAgent/OpenCI`)
  4. Shell: `preflight-secrets.sh` -- **PASS** (script exists at `.github/scripts/preflight-secrets.sh`)
- **Issues:** None

#### `detect-language` (line 141)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 2 min
- **Needs:** `preflight`
- **Permissions:** `contents: read`
- **Outputs:** `language`, `package-manager`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. Shell: `detect-language/detect.sh` via `.openci/` (vendored at runtime) -- **PASS** (by design, `.openci/` is populated by resolve-openci)
- **Issues:** None

#### `build-docker` (line 166)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 30 min
- **Needs:** `detect-language`
- **Permissions:** `contents: read`, `packages: write`, `id-token: write`
- **Outputs:** `image-digest`, `image-tag-sha`, `completed-at`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `./.openci/actions/ci/build-docker` with image-name, registry, registry-token -- **PASS**
- **Issues:** None

### Stage 2: Verify (parallel)

#### `scan-image` (line 196)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Needs:** `build-docker`
- **Permissions:** `contents: read`, `security-events: write`
- **Outputs:** `vulnerabilities-found`, `critical-count`, `high-count`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `./.openci/actions/ci/scan-image` with image-ref (composed from registry/owner/image-name@digest) -- **PASS**
- **Issues:** None

#### `sign-image` (line 222)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Needs:** `build-docker`
- **Permissions:** `contents: read`, `packages: write`, `id-token: write`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `docker/login-action@74a5d142...` (v3.4.0) -- **PASS** (SHA matches manifest)
  5. `./.openci/actions/ci/sign-image` -- **PASS**
- **Issues:** None

#### `generate-sbom` (line 249)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Needs:** `build-docker`
- **Permissions:** `contents: read`
- **Outputs:** `sbom-ref`
- **Steps:**
  1. harden-runner -- **PASS**
  2. Shell: Records image-ref as sbom-ref output and emits a notice -- **PASS**
- **Issues:**
  - **NOTE:** This job does not actually generate an SBOM file. It only records the image reference. The actual SBOM attestation may be handled by a separate process or this is a stub for future implementation. The output `sbom-ref` is set but never consumed by any downstream job in this workflow.

#### `check-migration` (line 270)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 10 min
- **Needs:** `build-docker`
- **Condition:** `if: inputs.run-migration == true`
- **Permissions:** `contents: read`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `./.openci/actions/ci/check-migration` with `migration-cmd: ${{ vars.MIGRATION_DRY_RUN_CMD || 'false' }}` -- **PASS**
- **Issues:**
  - **NOTE:** Uses `vars.MIGRATION_DRY_RUN_CMD` (repository-level variable) which is not declared as an input. This is fine functionally but means the behavior depends on repo configuration outside this workflow's contract.

#### `eval-smoke` (line 291)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Needs:** `build-docker`
- **Condition:** `if: inputs.enable-ai-smoke == true`
- **Permissions:** `contents: read`, `pull-requests: write`, `id-token: write`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `./.openci/actions/ci/eval-smoke` with image-digest, anthropic-api-key, api-base-url, model -- **PASS**
- **Issues:** None

#### `verify-sha` (line 317)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Needs:** `build-docker`
- **Permissions:** `contents: read`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout with `fetch-depth: 0` -- **PASS**
  3. Install yq -- **PASS**
  4. Shell: `verify-sha-consistency.sh` -- **PASS** (script exists at `.github/scripts/verify-sha-consistency.sh`)
- **Issues:** None

### Stage 3: Agent (failure-only)

#### `enrich` (line 346)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Needs:** all Stage 1 + Stage 2 jobs (7 dependencies)
- **Condition:** `if: always()`
- **Permissions:** `contents: read`, `actions: read`
- **Outputs:** `has-failures`, `deploy-blocked`, `agent-context`
- **Steps:**
  1. harden-runner -- **PASS**
  2. Shell: Summarizes all Stage 2 results, builds `ci-context.json` -- **PASS**
  3. Write `ci-context.json` artifact -- **PASS**
  4. `actions/upload-artifact@ea165f8d...` (v4.6.2) -- **PASS** (SHA matches manifest)
- **Issues:** None

#### `agent` (line 470)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 15 min
- **Needs:** `enrich`
- **Condition:** `needs.enrich.result == 'success' && inputs.enable-failure-agent == true && needs.enrich.outputs.has-failures == 'true'`
- **Permissions:** `contents: read`, `issues: write`, `actions: read`
- **Steps:**
  1. harden-runner -- **PASS**
  2. checkout -- **PASS**
  3. resolve-openci -- **PASS**
  4. `actions/download-artifact@d3f86a10...` (v4.3.0) -- **PASS** (SHA matches manifest)
  5. `./.openci/actions/_common/claude-harness` with task, API keys, model, allowed-tools, github-token, openci-ref -- **PASS**
- **Issues:** None

### Stage 4: Dispatch

#### `execute` (line 508)
- **Runner:** `${{ inputs.runner }}`
- **Timeout:** 5 min
- **Needs:** all 9 previous jobs
- **Condition:** `if: always()`
- **Permissions:** `actions: write`, `contents: read`
- **Outputs:** `deploy-ready`
- **Steps:**
  1. harden-runner -- **PASS**
  2. Shell: Evaluate deploy gate (deploy-ready = !deploy-blocked && auto-deploy) -- **PASS**
  3. Shell: Trigger deploy workflow via `gh workflow run` (conditional on deploy-ready) -- **PASS**
  4. Shell: Write job summary to `$GITHUB_STEP_SUMMARY` (always runs) -- **PASS**
- **Issues:**
  - **NOTE:** Line 571 uses env var name `MIGN_RESULT` instead of `MIGRATION_RESULT`. This is a minor typo in the env var name but is used consistently within the step (the printf on line 595 references `$MIGN_RESULT`), so it functions correctly. It's just a readability concern.

---

## Callers Analysis

### Caller: `.github/workflows/ci.yml`

**Reference:** `uses: YiAgent/OpenCI/.github/workflows/reusable-ci.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

**Inputs passed:**

| Input | Value | Matches Reusable? |
|-------|-------|-------------------|
| `openci-ref` | `${{ github.sha }}` | YES (string) |
| `registry` | `ghcr.io` | YES (string) |
| `image-name` | `${{ vars.IMAGE_NAME \|\| github.event.repository.name }}` | YES (required string) |
| `enable-ai-smoke` | `true` | YES (boolean) |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | YES (string, overrides default) |

**Inputs NOT passed (use defaults):**
- `model` (default: `""`)
- `language` (default: `""`)
- `run-migration` (default: `false`)
- `enable-failure-agent` (default: `true`)
- `auto-deploy` (default: `false`)
- `deploy-workflow` (default: `"deploy.yml"`)
- `deploy-environment` (default: `"staging"`)

**Secrets:** `secrets: inherit` -- passes all repository secrets to the reusable workflow. The reusable declares 3 optional secrets (`api-base-url`, `registry-token`, `anthropic-api-key`).

**Caller permissions:** The caller declares broad permissions (`contents: read`, `packages: write`, `id-token: write`, `actions: write`, `issues: write`, `security-events: write`, `pull-requests: write`). The reusable workflow declares `permissions: {}` at the top level and then per-job permissions. In reusable workflows, the caller's permissions are the ceiling; the reusable's per-job permissions are a subset. This is correct.

**Concurrency:** The caller declares `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: false }`. The reusable intentionally does NOT declare concurrency (comment on line 112-113 explains this avoids deadlock detection). This is correct.

---

## Issues Found

### No CRITICAL issues

### No HIGH issues

### MEDIUM

1. **`generate-sbom` job is a stub** (line 249-268)
   - The job records an image reference as `sbom-ref` but does not actually generate an SBOM. The output `sbom-ref` is never consumed by any downstream job.
   - **Impact:** Low. The job name and output suggest SBOM generation is expected. If this is intentional (SBOM generated elsewhere), it should be documented. If it's a placeholder, it should be completed.

2. **`MIGN_RESULT` env var typo** (line 571)
   - The env var is named `MIGN_RESULT` instead of the expected `MIGRATION_RESULT`. It is used consistently within the step (line 595), so it works, but reduces readability.
   - **Impact:** Low. Functional but confusing.

### LOW

3. **`check-migration` uses undeclared repo variable** (line 289)
   - References `vars.MIGRATION_DRY_RUN_CMD` which is a repository-level variable, not an input. This is fine functionally but means behavior depends on external configuration.
   - **Impact:** Informational.

4. **Local composite actions depend on runtime vendoring** (lines 189, 218, 245, 287, 310, 497)
   - All `./.openci/actions/...` references are resolved at runtime after `resolve-openci` checks out the OpenCI repo. This is by design but means the workflow cannot be tested without the vendoring step.
   - **Impact:** Informational. Expected behavior for this architecture.

5. **`generate-sbom` does not checkout the repo** (line 249)
   - Unlike all other Stage 2 jobs, `generate-sbom` does not run `actions/checkout` or `resolve-openci`. It only needs the image digest from the build output, so this is technically correct, but it's inconsistent with the pattern of other jobs.
   - **Impact:** Informational. No functional issue.

---

## Test Cases for Automation

### Input Validation

| ID | Test | Expected |
|----|------|----------|
| TC-01 | Call with `image-name` unset | Workflow should fail (required input) |
| TC-02 | Call with `image-name: "test-app"` and all defaults | All Stage 1 + 2 jobs should run; `check-migration` and `eval-smoke` skipped |
| TC-03 | Call with `run-migration: true` | `check-migration` job should execute |
| TC-04 | Call with `enable-ai-smoke: true` | `eval-smoke` job should execute |
| TC-05 | Call with `enable-failure-agent: false` | `agent` job should be skipped even on failures |
| TC-06 | Call with `auto-deploy: true` and clean build | `execute` should set `deploy-ready: true` and trigger deploy |
| TC-07 | Call with `auto-deploy: false` and clean build | `execute` should set `deploy-ready: false` |

### Dependency Chain

| ID | Test | Expected |
|----|------|----------|
| TC-08 | `preflight` fails | All downstream jobs should be skipped |
| TC-09 | `detect-language` fails | `build-docker` and all downstream skipped |
| TC-10 | `build-docker` fails | All Stage 2 jobs skipped; `enrich` runs (always); `agent` runs if `enable-failure-agent` and `has-failures` |
| TC-11 | `scan-image` finds critical CVEs | `enrich` sets `deploy-blocked: true`; `execute` sets `deploy-ready: false` |
| TC-12 | `sign-image` fails | `enrich` sets `deploy-blocked: true` |
| TC-13 | `verify-sha` fails | `enrich` sets `has-failures: true` but NOT `deploy-blocked` |
| TC-14 | All Stage 2 jobs pass | `enrich` sets `has-failures: false`, `deploy-blocked: false` |

### Security

| ID | Test | Expected |
|----|------|----------|
| TC-15 | All SHAs in `uses:` match `manifest.yml` | No mismatches (currently all match except `YiAgent/OpenCI` self-ref which uses repo-level key) |
| TC-16 | No `@v*`, `@main`, `@master` tag references | All external actions pinned to 40-char SHAs |
| TC-17 | `persist-credentials: false` on all checkout steps | No credentials leaked |
| TC-18 | `harden-runner` present as first step in every job | All 11 jobs have it |

### Output Verification

| ID | Test | Expected |
|----|------|----------|
| TC-19 | `image-digest` output is set after `build-docker` succeeds | Output matches pushed image digest |
| TC-20 | `deploy-time` output is set after `build-docker` succeeds | ISO 8601 timestamp |
| TC-21 | `deploy-ready` output reflects gate logic | `"true"` only when `deploy-blocked=false` AND `auto-deploy=true` |

### Caller Compatibility

| ID | Test | Expected |
|----|------|----------|
| TC-22 | Caller `ci.yml` passes all required inputs | `image-name` is provided |
| TC-23 | Caller `secrets: inherit` covers all declared secrets | All 3 optional secrets available |
| TC-24 | Caller permissions ceiling covers all per-job permissions | `packages: write`, `id-token: write`, `security-events: write`, `issues: write`, `actions: write`, `pull-requests: write` all present in caller |

# Workflow Test Report: reusable-docs.yml

**File:** `.github/workflows/reusable-docs.yml`
**Tested:** 2026-05-04
**SHA (caller pin):** `f62931bd0e2b73800512625a9fc5118557957ff3`
**Latest local commit:** `d1c259697c6cdaac61a7c08a758df6e9ece1395a`

---

## Overview

`reusable-docs.yml` is a reusable workflow implementing a 4-stage documentation quality and agentic sync pipeline:

| Stage | Job | Purpose |
|-------|-----|---------|
| 1 | `lint` | Deterministic doc quality gate (markdownlint, link check, spell check, required docs) |
| 2 | `detect` | Git-history drift detection, API staleness analysis; builds docs-workspace artifact |
| 3 | `agent` | AI-powered docs-sync agent (claude-harness) producing an action plan JSON |
| 4 | `execute` | Apply high-confidence updates (PR), build + deploy GitHub Pages, post sticky comment |

**Trigger matrix (caller-defined):**
- `push:main` -- all 4 stages
- `pull_request` (docs/\*\*, \*.md) -- Stage 1 only (lint gate)
- `schedule` / `workflow_dispatch` -- all 4 stages
- `release:published` -- all 4 stages

---

## Inputs/Secrets/Outputs Definition

### Inputs (12 total, all optional)

| Input | Type | Default | Referenced In |
|-------|------|---------|---------------|
| `openci-ref` | string | `main` | detect, agent, execute (Resolve OpenCI workflow ref) |
| `runner` | string | `ubuntu-latest` | all jobs (`runs-on`) |
| `docs-path` | string | `docs` | lint (markdownlint, link check, spell check), detect, execute (build) |
| `build-cmd` | string | `""` | execute (Build docs site) |
| `site-dir` | string | `site` | execute (Build docs site) |
| `markdownlint-config` | string | `""` | lint (markdownlint) |
| `enable-spell-check` | boolean | `false` | lint (Spell check step) |
| `api-spec-path` | string | `""` | detect (drift detection) |
| `api-source-path` | string | `""` | detect (drift detection) |
| `deploy-docs` | boolean | `true` | execute (Upload Pages, Deploy Pages) |
| `enable-agent` | boolean | `true` | agent (job-level `if`) |
| `model` | string | `""` | agent (claude-harness, defaults to `claude-sonnet-4-5-20250929`) |

**Validation:** All 12 defined inputs are referenced at least once. All referenced inputs are defined. No orphaned or phantom inputs.

### Secrets (2 total, both optional)

| Secret | Required | Referenced In |
|--------|----------|---------------|
| `anthropic-api-key` | false | agent (api-key-gate, claude-harness) |
| `api-base-url` | false | agent (claude-harness) |

**Validation:** Both defined secrets are referenced. No phantom secret references.

### Job Outputs

| Job | Output Key | Source |
|-----|-----------|--------|
| `detect` | `needs-update` | `steps.detect.outputs.needs-update` |
| `detect` | `workspace-artifact` | Hardcoded: `docs-detect-${{ github.run_id }}` |
| `agent` | `plan` | `steps.extract.outputs.plan` |
| `agent` | `skip-reason` | `steps.extract.outputs.skip-reason` |
| `execute` | `docs-pr-url` | `steps.apply.outputs.pr-url` |
| `execute` | `docs-pr-number` | `steps.apply.outputs.pr-number` |

---

## Node-by-Node Status

### Top-level

| Check | Status | Notes |
|-------|--------|-------|
| YAML syntax | PASS | `yaml.safe_load` succeeds |
| actionlint | PASS | No errors or warnings |
| `permissions: {}` | PASS | Correctly drops all default permissions; each job declares its own |
| `name:` | PASS | Set to `docs` |
| No top-level `concurrency` | PASS | Comment explains caller owns concurrency lock (ref: #68) |
| Security: no github.event in run: | PASS | All event payloads forwarded via `env:` variables |

### Stage 1 -- `lint` Job

| Check | Status | Notes |
|-------|--------|-------|
| `needs` | PASS | None (first stage) |
| `if` | PASS | None (always runs) |
| `runs-on` | PASS | `${{ inputs.runner }}` |
| `timeout-minutes` | PASS | 10 |
| `permissions` | PASS | `contents: read` (least privilege) |
| Step 1: Harden Runner | PASS | SHA `f808768` = `step-security/harden-runner@v2.17.0` |
| Step 2: Checkout | PASS | SHA `11bd719` = `actions/checkout@v4.2.2`, `persist-credentials: false` |
| Step 3: markdownlint | PASS | Handles missing docs dir gracefully; config file optional; uses `npx --yes markdownlint-cli@0.44.0` |
| Step 4: Link check | PASS | `continue-on-error: true` (advisory); uses `markdown-link-check@3.13.6`; handles missing docs dir |
| Step 5: Spell check | PASS | Gated on `inputs.enable-spell-check == true`; `continue-on-error: true`; uses `cspell@8` |
| Step 6: Required docs | PASS | Checks for `README.md`; clear error message on missing |

### Stage 2 -- `detect` Job

| Check | Status | Notes |
|-------|--------|-------|
| `needs` | PASS | `lint` (correct dependency) |
| `if` | PASS | `github.event_name != 'pull_request'` -- skips on PR-only runs |
| `runs-on` | PASS | `${{ inputs.runner }}` |
| `timeout-minutes` | PASS | 10 |
| `permissions` | PASS | `contents: read`, `pull-requests: read` |
| `outputs` | PASS | `needs-update` from step; `workspace-artifact` hardcoded with `github.run_id` |
| Step 1: Harden Runner | PASS | SHA pinned correctly |
| Step 2: Checkout (full history) | PASS | `fetch-depth: 0` for drift detection; `persist-credentials: false` |
| Step 3: Resolve OpenCI ref | PASS | Falls back to `workflow_ref` when input is empty; strips `refs/heads/` and `refs/tags/` |
| Step 4: Checkout OpenCI | PASS | Cross-repo checkout of `YiAgent/OpenCI` at resolved ref into `.openci/` |
| Step 5: Run drift detection | PASS | Uses local composite action `.openci/actions/docs/detect` |

### Stage 3 -- `agent` Job

| Check | Status | Notes |
|-------|--------|-------|
| `needs` | PASS | `detect` (correct) |
| `if` | PASS | `inputs.enable-agent == true && needs.detect.outputs.needs-update == 'true'` |
| `runs-on` | PASS | `${{ inputs.runner }}` |
| `timeout-minutes` | PASS | 20 (appropriate for AI agent) |
| `permissions` | PASS | `contents: read`, `pull-requests: read`, `id-token: write` |
| `outputs` | PASS | `plan` and `skip-reason` from extract step |
| Step 1: Harden Runner | PASS | SHA pinned |
| Step 2: Checkout | PASS | SHA pinned, `persist-credentials: false` |
| Step 3: Resolve OpenCI ref | PASS | Same pattern as detect |
| Step 4: Checkout OpenCI | PASS | Cross-repo checkout |
| Step 5: Download artifact | PASS | SHA `d3f86a1` = `actions/download-artifact@v4.3.0`; artifact name matches detect output |
| Step 6: API key gate | PASS | Uses `.openci/actions/_common/api-key-gate`; skips gracefully when key missing |
| Step 7: Claude harness | PASS | Gated on `steps.gate.outputs.skip != 'true'`; uses `.openci/actions/_common/claude-harness` |
| Step 8: Extract plan | PASS | Uses `.openci/actions/docs/extract-plan`; handles both success and skip |

### Stage 4 -- `execute` Job

| Check | Status | Notes |
|-------|--------|-------|
| `needs` | PASS | `[detect, agent]` (both stages) |
| `if` | PASS | `always() && github.event_name != 'pull_request' && needs.detect.result != 'skipped'` |
| `runs-on` | PASS | `${{ inputs.runner }}` |
| `timeout-minutes` | PASS | 15 |
| `environment` | PASS | `github-pages` (required for deploy-pages action) |
| `permissions` | PASS | `contents: write`, `pull-requests: write`, `issues: write`, `pages: write`, `id-token: write` |
| `outputs` | PASS | `docs-pr-url` and `docs-pr-number` from apply step |
| Step 1: Harden Runner | PASS | SHA pinned |
| Step 2: Checkout | PASS | SHA pinned, `persist-credentials: false` |
| Step 3: Resolve OpenCI ref | PASS | Same pattern |
| Step 4: Checkout OpenCI | PASS | Cross-repo checkout |
| Step 5: Apply docs updates | PASS | Gated on `agent.result == 'success' && agent.outputs.plan != ''` |
| Step 6: Build docs site | WARNING | See Issues section -- `bash -c "$CMD"` omits `set -euo pipefail` in subshell |
| Step 7: Upload Pages | PASS | Gated on `inputs.deploy-docs == true`; SHA `fc324d3` = `actions/upload-pages-artifact@v3.0.1` |
| Step 8: Deploy Pages | PASS | Gated on `inputs.deploy-docs == true`; SHA `cd2ce8f` = `actions/deploy-pages@v4.0.5` |
| Step 9: Sticky comment | PASS | Uses `actions/github-script@v7`; all event data via `env:` (no direct interpolation); deduplicates by marker |
| Step 10: Job summary | PASS | Writes to `$GITHUB_STEP_SUMMARY` |

---

## Callers Analysis

### Single Caller: `.github/workflows/docs.yml`

**Line 30:**
```yaml
uses: YiAgent/OpenCI/.github/workflows/reusable-docs.yml@f62931bd0e2b73800512625a9fc5118557957ff3
```

**SHA Pin Status:** The caller references `f62931b`. The latest local commit touching `reusable-docs.yml` is `d1c2596`. The caller's SHA is NOT an ancestor of the latest commit, suggesting the caller's pin may point to a commit on a different branch or has been force-pushed past. **This may indicate the caller is out of date.**

### Caller Inputs vs. Reusable Definition

| Reusable Input | Caller Passes | Match? |
|----------------|---------------|--------|
| `openci-ref` | (not passed) | OK -- defaults to `main` |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | OK -- overrides default |
| `docs-path` | `${{ vars.DOCS_DIR \|\| 'docs' }}` | OK |
| `build-cmd` | `${{ vars.DOCS_BUILD_CMD \|\| '' }}` | OK |
| `site-dir` | `${{ vars.DOCS_SITE_DIR \|\| 'site' }}` | OK |
| `markdownlint-config` | (not passed) | OK -- defaults to `""` |
| `enable-spell-check` | (not passed) | OK -- defaults to `false` |
| `api-spec-path` | (not passed) | OK -- defaults to `""` |
| `api-source-path` | (not passed) | OK -- defaults to `""` |
| `deploy-docs` | (not passed) | OK -- defaults to `true` |
| `enable-agent` | `true` | OK |
| `model` | `${{ vars.AI_MODEL \|\| '' }}` | OK |

### Caller Secrets vs. Reusable Definition

| Reusable Secret | Caller Passes | Match? |
|-----------------|---------------|--------|
| `anthropic-api-key` | `${{ secrets.ANTHROPIC_API_KEY }}` | OK |
| `api-base-url` | `${{ secrets.ANTHROPIC_BASE_URL }}` | OK |

**No input/secret mismatches found between caller and reusable.**

### Caller Permissions vs. Reusable Needs

The caller declares broad permissions (`contents: write`, `pull-requests: write`, `issues: write`, `pages: write`, `id-token: write`). The reusable workflow uses `permissions: {}` at top level and per-job scoping. The caller's permissions are sufficient for all jobs.

### Caller Concurrency

```yaml
concurrency:
  group: docs-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

This correctly avoids the deadlock scenario documented in the reusable (comment on line 98-99, ref: #68).

---

## Issues Found

### MEDIUM -- `bash -c "$CMD"` missing `set -euo pipefail`

**Location:** `execute` job, "Build docs site" step (line 442)
**Code:**
```yaml
run: |
  set -euo pipefail
  if [ -z "$CMD" ]; then
    ...
  else
    bash -c "$CMD"
  fi
```

The outer shell has `set -euo pipefail`, but `bash -c "$CMD"` spawns a **new child shell** that does NOT inherit those settings. If the build command fails with a non-zero exit code, `bash -c` will propagate it, so this is not a silent failure. However, if the command has partial failures (e.g., a pipeline where only the last command's exit code matters), errors could be missed.

**Recommendation:** Change to `bash -euo pipefail -c "$CMD"` or `bash -c "set -euo pipefail; $CMD"`.

### LOW -- Caller SHA pin may be stale

**Location:** `docs.yml` line 30
The caller pins to `f62931bd0e2b73800512625a9fc5118557957ff3`, but the latest commit on `reusable-docs.yml` is `d1c259697c6cdaac61a7c08a758df6e9ece1395a`. The two SHAs are not ancestor-related, meaning the caller may be referencing an older or different-branch version.

**Recommendation:** Update the caller's SHA pin to `d1c2596` after verifying the latest changes are intentional.

### LOW -- `always()` on `execute` may mask upstream failures

**Location:** `execute` job `if` condition (line 365-368)
The `always()` ensures the execute job runs even when `detect` or `agent` jobs fail. While this is intentional (for Pages deploy and sticky comment), it means a failing `detect` job won't block `execute`. The guard `needs.detect.result != 'skipped'` only prevents execution when detect was skipped (PR events), not when it fails.

**Recommendation:** Consider adding `needs.detect.result != 'failure'` if the intent is to only proceed with deployment when detection succeeds.

### INFO -- Local composite actions not available locally

The workflow references 4 local composite actions via `.openci/` checkout:
- `.openci/actions/docs/detect`
- `.openci/actions/_common/api-key-gate`
- `.openci/actions/_common/claude-harness`
- `.openci/actions/docs/extract-plan`
- `.openci/actions/docs/execute-plan`

These actions live in the `YiAgent/OpenCI` repository and are checked out at runtime. They cannot be validated statically in this repo. Any breaking changes to those actions would silently break this workflow.

### INFO -- `npx --yes` version pinning

The workflow pins `markdownlint-cli@0.44.0`, `markdown-link-check@3.13.6`, and `cspell@8` via `npx --yes`. While version pinning is good practice, `cspell@8` uses a major version range rather than an exact version, which could pull in minor/patch releases with breaking behavior.

---

## Test Cases for Automation

### TC-1: YAML Validity
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/reusable-docs.yml')); print('PASS')"
```

### TC-2: actionlint Clean
```bash
actionlint .github/workflows/reusable-docs.yml
# Expected: exit code 0, no output
```

### TC-3: All Inputs Have Defaults
Verify every input in `on.workflow_call.inputs` has a `default` key (since all are `required: false`).

### TC-4: All Defined Inputs Are Referenced
Grep for every `inputs.<name>` in the file and verify each defined input appears at least once.

### TC-5: All Defined Secrets Are Referenced
Grep for every `secrets.<name>` in the file and verify each defined secret appears at least once.

### TC-6: No `github.event.*` in `run:` Blocks
Verify that no `run:` block contains direct `github.event.*` interpolation (should use `env:` variables instead).

### TC-7: SHA Pins Match Commented Versions
For each `uses: org/repo@SHA # vX.Y.Z`, verify the SHA matches the claimed version tag.

### TC-8: Job Dependency Graph Validity
Verify:
- `detect.needs` contains `lint`
- `agent.needs` contains `detect`
- `execute.needs` contains `[detect, agent]`
- No circular dependencies

### TC-9: Conditional Logic Correctness
- `detect` skips on `pull_request` events
- `agent` only runs when `enable-agent == true` AND `needs-update == 'true'`
- `execute` runs on `always()` but not on PRs, and not when `detect` was skipped
- `execute` only applies updates when `agent` succeeded with a non-empty plan

### TC-10: Permissions Minimality
Verify each job declares only the permissions it needs (no wildcard `*` permissions).

### TC-11: Caller Input/Secret Parity
For each caller of this reusable, verify:
- Every `with:` key maps to a defined input
- Every `secrets:` key maps to a defined secret
- No required inputs are missing

### TC-12: Artifact Name Consistency
Verify `detect` job's `workspace-artifact` output matches the `download-artifact` step's `name` in the `agent` job.

### TC-13: `persist-credentials: false` on All Checkouts
Verify every `actions/checkout` usage includes `persist-credentials: false`.

### TC-14: Harden Runner Present in Every Job
Verify every job has `step-security/harden-runner` as its first step.

### TC-15: Timeout Set on Every Job
Verify every job has `timeout-minutes` defined.

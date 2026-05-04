# Workflow Test Report: docs.yml

**File:** `.github/workflows/docs.yml`
**Reusable workflow:** `.github/workflows/reusable-docs.yml`
**Tested:** 2026-05-04
**actionlint:** PASS (no errors)
**YAML syntax:** VALID

---

## Overview

`docs.yml` is a thin event-routing workflow that delegates entirely to the reusable workflow `reusable-docs.yml` at pinned SHA `f62931bd0e2b73800512625a9fc5118557957ff3`. The reusable workflow implements a 4-stage documentation pipeline:

1. **Stage 1 (Lint)** -- markdownlint, link check, spell check, required docs gate
2. **Stage 2 (Detect)** -- git-history drift detection, builds docs-workspace artifact
3. **Stage 3 (Agent)** -- claude-harness produces a docs-action-plan JSON when drift is detected
4. **Stage 4 (Execute)** -- apply updates (new branch + PR), build + deploy Pages, post sticky comment

The caller (`docs.yml`) defines triggers, top-level permissions, concurrency, and passes inputs/secrets to the reusable workflow.

---

## Node-by-Node Status

### Triggers (`on:`)

| Trigger | Config | Status |
|---------|--------|--------|
| `pull_request` | paths: `docs/**`, `**/*.md` | OK -- scoped to doc changes |
| `push` | branches: `[main]` | OK -- runs full pipeline on main |
| `schedule` | `0 9 * * 1` (Monday 09:00 UTC) | OK -- weekly cron |
| `release` | types: `[published]` | OK |
| `workflow_dispatch` | (no inputs) | OK -- manual trigger |

**Note:** The caller defines 5 trigger events but the reusable workflow's `detect` and `execute` stages skip on `pull_request` events (via `if: github.event_name != 'pull_request'`). On PRs, only Stage 1 (lint) runs. This is by design per the comment in the reusable workflow.

### Permissions

**Caller top-level permissions:**
```yaml
contents:      write
pull-requests: write
issues:        write
pages:         write
id-token:      write
```

**Reusable workflow `permissions: {}` (empty)** -- each job defines its own minimal permissions:

| Job | Permissions | Status |
|-----|------------|--------|
| `lint` | contents: read | OK -- minimal |
| `detect` | contents: read, pull-requests: read | OK -- minimal |
| `agent` | contents: read, pull-requests: read, id-token: write | OK -- id-token needed for OIDC |
| `execute` | contents: write, pull-requests: write, issues: write, pages: write, id-token: write | OK -- needs write for Pages deploy + PR creation |

The top-level caller permissions are wider than needed (write everywhere), but the reusable workflow correctly narrows per-job. The reusable's empty `permissions: {}` at the workflow level ensures job-level permissions take effect.

### Concurrency

```yaml
group: docs-${{ github.event.pull_request.number || github.ref }}
cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

- PRs: concurrency group is `docs-<PR_NUMBER>`, cancel-in-progress = `true` (new pushes cancel stale runs)
- Push/schedule/dispatch: concurrency group is `docs-<REF>`, cancel-in-progress = `false`
- The reusable workflow has **no** concurrency block (correct -- caller owns the lock per comment referencing issue #68)

**Status:** OK

### Jobs and Dependency Chain

```
docs.yml
  └── docs (calls reusable-docs.yml@SHA)
        ├── lint (no dependencies)
        ├── detect (needs: lint) [skipped on PR]
        ├── agent (needs: detect) [conditional: enable-agent AND needs-update]
        └── execute (needs: [detect, agent]) [always(), not PR, detect not skipped]
```

**Status:** OK -- dependency chain is sound. `execute` uses `always()` to run even when `agent` is skipped (e.g., no drift or missing API key).

### SHA References

| Reference | SHA | Manifest SHA | Match |
|-----------|-----|-------------|-------|
| `YiAgent/OpenCI/.github/workflows/reusable-docs.yml@...` | `f62931bd...` | `f62931bd...` | YES |
| `step-security/harden-runner` | `f808768d...` | `f808768d...` | YES |
| `actions/checkout` | `11bd7190...` | `11bd7190...` | YES |
| `actions/download-artifact` | `d3f86a10...` | `d3f86a10...` | YES |
| `actions/upload-pages-artifact` | `fc324d35...` | `fc324d35...` | YES |
| `actions/deploy-pages` | `cd2ce8fc...` | `cd2ce8fc...` | YES |
| `actions/github-script` | `60a0d830...` | `60a0d830...` | YES |

All 7 third-party action SHAs are pinned to 40-character commit hashes and match the manifest.

### Secret/Variable References

**Secrets passed:**
| Secret | Reusable input | Required | Status |
|--------|---------------|----------|--------|
| `secrets.ANTHROPIC_API_KEY` | `anthropic-api-key` | No | OK |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` | No | OK |

**Variables used (with fallbacks):**
| Variable | Fallback | Used for |
|----------|----------|----------|
| `vars.DOCS_BUILD_CMD` | `''` | build-cmd input |
| `vars.DOCS_DIR` | `'docs'` | docs-path input |
| `vars.DOCS_SITE_DIR` | `'site'` | site-dir input |
| `vars.AI_MODEL` | `''` | model input |

All inputs map correctly to reusable workflow definitions. No required inputs are missing.

### Runner Labels

The caller passes `runner: blacksmith-2vcpu-ubuntu-2404` to the reusable workflow. This is a Blacksmith runner (third-party CI acceleration service). The reusable workflow's default is `ubuntu-latest`. If the Blacksmith runner is unavailable or misconfigured, the workflow will fail at runtime.

**Status:** OK (intentional override), but worth noting the dependency on an external runner provider.

### Input Mapping Audit

**6 inputs passed** (all match reusable definitions):
- `build-cmd`, `docs-path`, `site-dir`, `enable-agent`, `runner`, `model`

**6 inputs use defaults** (not passed by caller):
- `openci-ref` (default: `main`)
- `markdownlint-config` (default: `""`)
- `enable-spell-check` (default: `false`)
- `api-spec-path` (default: `""`)
- `api-source-path` (default: `""`)
- `deploy-docs` (default: `true`)

### Local Composite Actions

The reusable workflow references 5 local composite actions via `./.openci/actions/...`:
- `.openci/actions/docs/detect`
- `.openci/actions/_common/api-key-gate`
- `.openci/actions/_common/claude-harness`
- `.openci/actions/docs/extract-plan`
- `.openci/actions/docs/execute-plan`

These are checked out at runtime from `YiAgent/OpenCI` repo (Step 2 in each stage: "Checkout OpenCI for ..."). They do **not** exist in the local working tree -- this is expected because they're fetched from the remote repo at the pinned SHA during the workflow run.

---

## Issues Found

### MEDIUM -- Version comment mismatch for Pages actions

**File:** `.github/workflows/reusable-docs.yml`, lines 449 and 456

The version comments in the reusable workflow disagree with the manifest:
- Line 449: `actions/upload-pages-artifact@...  # v3.0.1` -- manifest says `v5.0.0`
- Line 456: `actions/deploy-pages@...  # v4.0.5` -- manifest says `v5.0.0`

The SHAs are identical (correct), but the inline comments are stale. This can mislead reviewers into thinking the workflow uses older versions.

**Fix:** Update the comments to match the manifest:
```yaml
uses: actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9  # v5.0.0
uses: actions/deploy-pages@cd2ce8fcbc39b97be8ca5fce6e763baed58fa128  # v5.0.0
```

### LOW -- No `workflow_dispatch` inputs defined

The caller workflow supports `workflow_dispatch` but defines no inputs. This means manual runs always use default variable values. Adding optional inputs for `build-cmd`, `docs-path`, etc. would allow manual overrides without editing the file.

### INFO -- Caller permissions are wider than necessary

The caller's top-level `permissions` block grants `write` to `contents`, `pull-requests`, `issues`, `pages`, and `id-token`. The reusable workflow correctly narrows per-job, but the caller's top-level block could be `permissions: {}` (empty) since the reusable jobs each declare their own. This is a defense-in-depth consideration, not a bug.

### INFO -- Blacksmith runner dependency

The runner `blacksmith-2vcpu-ubuntu-2404` is a third-party CI runner from Blacksmith. If the service is down or the org doesn't have access, the workflow will queue indefinitely. Consider adding a fallback or documenting the requirement.

---

## Test Cases for Automation

### TC-1: YAML Syntax Validation
- **Action:** Parse `docs.yml` with `yaml.safe_load()`
- **Expected:** No parse errors

### TC-2: actionlint Pass
- **Action:** Run `actionlint .github/workflows/docs.yml`
- **Expected:** Zero errors, zero warnings

### TC-3: SHA Consistency with Manifest
- **Action:** Extract all `uses:` SHAs from both `docs.yml` and `reusable-docs.yml`, compare against `manifest.yml`
- **Expected:** All SHAs match manifest entries

### TC-4: Input Schema Validation
- **Action:** Compare `with:` keys in `docs.yml` job `docs` against `workflow_call.inputs` in `reusable-docs.yml`
- **Expected:** Every `with:` key exists in the reusable's input definitions; no required inputs are missing

### TC-5: Secret Schema Validation
- **Action:** Compare `secrets:` keys in `docs.yml` job `docs` against `workflow_call.secrets` in `reusable-docs.yml`
- **Expected:** Every secret key exists in the reusable's secret definitions; no required secrets are missing

### TC-6: Reusable Workflow File Exists
- **Action:** Verify the `uses:` reference resolves to an existing file (for local refs) or a valid remote SHA
- **Expected:** File exists at the referenced path/SHA

### TC-7: Concurrency Group Expression
- **Action:** Validate the `concurrency.group` expression uses valid GitHub context properties
- **Expected:** `github.event.pull_request.number` and `github.ref` are valid in all trigger contexts

### TC-8: Permission Escalation Check
- **Action:** Verify reusable workflow jobs don't request permissions beyond what the caller grants
- **Expected:** Each job's permissions are a subset of the caller's top-level permissions

### TC-9: Deprecated Pattern Scan
- **Action:** Search for `::set-output`, `::save-state`, `set-output`, `save-state` in both files
- **Expected:** No deprecated patterns found

### TC-10: Trigger-Skip Consistency
- **Action:** Verify that jobs with `if: github.event_name != 'pull_request'` are downstream-only (not the entry point)
- **Expected:** `lint` runs on all triggers; `detect`, `agent`, `execute` skip on PR only

### TC-11: Version Comment Accuracy
- **Action:** Compare inline `# vX.Y.Z` comments after `uses:` references against the manifest version comments
- **Expected:** All version comments match

### TC-12: Local Composite Action Availability
- **Action:** For `./.openci/actions/*` references, verify the checkout step that provides them runs before the step that uses them
- **Expected:** Each stage has a "Checkout OpenCI for ..." step before any `./.openci/` reference

### TC-13: Default Value Fallback Expressions
- **Action:** Validate that `${{ vars.X || 'default' }}` expressions have valid fallback values
- **Expected:** All fallback values are sensible (non-empty strings or appropriate defaults)

### TC-14: Cron Schedule Validity
- **Action:** Parse the cron expression `0 9 * * 1`
- **Expected:** Valid 5-field cron (Monday at 09:00 UTC)

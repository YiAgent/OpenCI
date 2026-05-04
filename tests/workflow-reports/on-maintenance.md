# Workflow Test Report: on-maintenance.yml

**File:** `.github/workflows/on-maintenance.yml`
**Date:** 2026-05-04
**Validated with:** actionlint v1.7.7, Python yaml.safe_load, manual analysis

---

## Overview

`on-maintenance.yml` is the unified maintenance entry point that replaces the former `security.yml`. It acts as a mode dispatcher: depending on the trigger event and schedule, it resolves an execution mode and routes to either the reusable maintenance pipeline (full/scan-only/deps-only), a SHA integrity check (pr-review), or a feature flag audit (flag-audit).

### Trigger-to-mode mapping

| Trigger                  | Mode         | Job(s) executed       |
|--------------------------|--------------|-----------------------|
| `schedule` Mon 02:00 UTC | `full`       | `maintenance`         |
| `schedule` Mon 15:00 UTC | `flag-audit` | `flag-audit`          |
| `push` (main, path-filtered) | `pr-review` | `verify-sha`     |
| `pull_request` (path-filtered) | `pr-review` | `verify-sha`   |
| `workflow_dispatch`      | user-chosen  | depends on mode       |

### Job dependency graph

```
resolve-mode
  |---> maintenance   (mode NOT in [pr-review, flag-audit])
  |---> verify-sha    (mode == pr-review)
  |---> flag-audit    (mode == flag-audit)
```

All three downstream jobs depend solely on `resolve-mode`. They are mutually exclusive by their `if:` conditions.

---

## Node-by-Node Status

### Triggers (`on:`)

| Node | Status | Notes |
|------|--------|-------|
| `schedule` cron `0 2 * * 1` | PASS | Monday 02:00 UTC. Comment says "full sweep" -- correct. |
| `schedule` cron `0 15 * * 1` | PASS | Monday 15:00 UTC = 23:00 BJT. Comment says "Monday 23:00 BJT" -- correct. |
| `push` paths filter | PASS | Filters on `manifest.yml`, `actions/**/action.yml`, `.github/workflows/**.yml`, `.github/scripts/**`. Matches relevant files. |
| `pull_request` paths filter | PASS | Same paths as push. Consistent. |
| `workflow_dispatch` inputs | PASS | `mode` is a choice input with valid options: full, scan-only, deps-only, flag-audit. Default is `full`. |

### Permissions (workflow-level)

| Permission | Value | Used by |
|------------|-------|---------|
| `contents` | `read` | All jobs (checkout, ls-tree) |
| `security-events` | `write` | Reusable workflow (SARIF upload) |
| `packages` | `read` | Not directly used in this file; may be needed by reusable workflow |
| `id-token` | `write` | `flag-audit` job (claude-harness OIDC) |
| `issues` | `write` | `flag-audit` job (gh issue create) |
| `actions` | `write` | Reusable workflow (summary writes) |
| `pull-requests` | `read` | Reusable workflow (check-updates lists PRs) |

**Status:** PASS -- permissions are well-scoped. Individual jobs further narrow permissions where needed.

### Concurrency

| Setting | Value | Status |
|---------|-------|--------|
| `group` | `maintenance-${{ github.event_name }}-${{ github.ref }}` | PASS |
| `cancel-in-progress` | `false` | PASS -- safe for scheduled runs (won't cancel in-flight maintenance) |

The concurrency group correctly separates by event type and ref, so a scheduled run won't collide with a push-triggered run.

### Job: `resolve-mode`

| Node | Status | Notes |
|------|--------|-------|
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS -- custom runner, used consistently across all jobs |
| Timeout | 2 min | PASS -- sufficient for mode resolution |
| `step-security/harden-runner` SHA | `f808768d...` | PASS -- matches `manifest.yml` |
| `actions/checkout` SHA | `11bd71901bbe...` | PASS -- matches `manifest.yml` |
| Step `resolve` logic | PASS | Correctly handles workflow_dispatch (with fallback to `full`), push/pull_request (`pr-review`), and both schedule crons. |
| Step `openci-ref` logic | PASS | Strips `refs/heads/` and `refs/tags/` prefix from `workflow_ref` to extract the branch/tag name. |
| Outputs | PASS | `mode` and `openci-ref` are both wired to `$GITHUB_OUTPUT`. |

### Job: `maintenance`

| Node | Status | Notes |
|------|--------|-------|
| `needs` | `resolve-mode` | PASS |
| `if:` condition | PASS | Excludes `pr-review` and `flag-audit` modes using `fromJSON` + `contains`. Correctly skips when mode is handled by other jobs. |
| Reusable workflow ref | `YiAgent/OpenCI/.github/workflows/reusable-maintenance.yml@f62931bd...` | PASS -- SHA matches `manifest.yml` entry for `YiAgent/OpenCI`. File exists at that SHA (verified via `git ls-tree`). |
| `with` inputs | PASS | `mode`, `openci-ref`, `image-ref`, `runner` all correctly wired. `image-ref` uses `${{ vars.IMAGE_REF || '' }}` with empty fallback. |
| `secrets` | PASS | Explicitly maps `anthropic-api-key` and `api-base-url`. Note: `secrets:inherit` is not used (comment explains kebab-case mismatch). `snyk-token` from reusable workflow is optional and correctly omitted. |

### Job: `verify-sha`

| Node | Status | Notes |
|------|--------|-------|
| `needs` | `resolve-mode` | PASS |
| `if:` condition | PASS | Runs only when mode is `pr-review`. |
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS |
| Timeout | 5 min | PASS |
| Permissions | `contents: read` | PASS -- narrows from workflow-level |
| `step-security/harden-runner` SHA | PASS | Matches manifest |
| `actions/checkout` SHA | PASS | Uses `fetch-depth: 0` (required for `git ls-tree` in verify script) and `persist-credentials: false` (security best practice) |
| yq install step | PASS | Installs v4.44.6. Uses `command -v yq` guard to skip if already present. |
| Verify script step | PASS | References `.github/scripts/verify-sha-consistency.sh` which exists locally (251 lines, well-structured). |

### Job: `flag-audit`

| Node | Status | Notes |
|------|--------|-------|
| `needs` | `resolve-mode` | PASS |
| `if:` condition | PASS | Runs only when mode is `flag-audit`. |
| Runner | `blacksmith-2vcpu-ubuntu-2404` | PASS |
| Timeout | 15 min | PASS -- AI agent calls can take time |
| Permissions | `contents: read`, `issues: write`, `id-token: write` | PASS -- correctly scoped for checkout + issue creation + OIDC |
| Step `openci-ref` | PASS | Duplicates the ref-resolution logic (same pattern as `resolve-mode`). This is intentional -- each job resolves independently. |
| Checkout YiAgent/OpenCI | PASS | Checks out to `.openci` path with resolved ref. |
| Composite action reference | `./.openci/actions/_common/flag-audit` | PASS -- `actions/_common/flag-audit/action.yml` exists locally. Uses claude-harness composite action. |
| Inputs to flag-audit | PASS | `github-token` uses `${{ github.token }}`, `anthropic-api-key` and `api-base-url` from secrets. |

### Reusable Workflow: `reusable-maintenance.yml`

| Node | Status | Notes |
|------|--------|-------|
| File exists locally | PASS | `.github/workflows/reusable-maintenance.yml` present |
| Inputs match caller | PASS | `mode`, `openci-ref`, `image-ref`, `runner` -- all declared and typed correctly |
| Secrets match caller | PASS | `anthropic-api-key` (required: false), `api-base-url` (required: false), `snyk-token` (required: false) |
| Job graph | PASS | 4-stage pipeline: detect-language -> scan-codeql, scan-secrets, trivy-fs, check-updates -> enrich -> agent -> summary |
| Mode routing in reusable | PASS | `full` = all stages, `scan-only` = scans + enrich, `deps-only` = check-updates + enrich |

### Composite Action: `flag-audit/action.yml`

| Node | Status | Notes |
|------|--------|-------|
| File exists locally | PASS | `actions/_common/flag-audit/action.yml` present |
| Inputs | PASS | `flag-pattern` (optional), `github-token` (required), `anthropic-api-key` (required), `api-base-url` (optional), `model` (optional) |
| claude-harness reference | `./.openci/actions/_common/claude-harness` | Uses vendored OpenCI checkout -- correct |
| Issue creation | PASS | Uses `gh issue create` with labels `tech-debt,priority:p3,ops-generated` |

### Script: `verify-sha-consistency.sh`

| Node | Status | Notes |
|------|--------|-------|
| File exists locally | PASS | `.github/scripts/verify-sha-consistency.sh` (251 lines) |
| Dependencies | PASS | Requires `yq` (installed in workflow step) and `manifest.yml` + `manifest-pending.yml` |
| Logic | PASS | Validates 40-char hex SHAs, checks manifest for all `uses:` refs, rejects deprecated actions, rejects pending actions, validates self-referencing SHAs via `git ls-tree` |

---

## Issues Found

### No Critical or High Issues

### Medium Issues

1. **Duplicated OpenCI ref resolution logic** (lines 103-112 in `resolve-mode`, lines 185-194 in `flag-audit`)
   - The same shell snippet to extract the ref from `WORKFLOW_REF` is repeated. This is a maintainability concern -- if the logic needs to change, two places must be updated.
   - **Severity:** MEDIUM (maintainability)
   - **Recommendation:** Acceptable for now since each job runs in isolation and can't share shell code. Could be extracted to a local composite action if more jobs are added.

2. **`packages: read` permission may be unnecessary** (line 54)
   - No step in this workflow or its referenced reusable workflow visibly uses the `packages` permission.
   - **Severity:** LOW (security best practice -- minimize permissions)
   - **Recommendation:** Verify if the reusable workflow or any composite action needs it; remove if not.

3. **`actions: write` permission is broad** (line 57)
   - The comment explains it's for `reusable-maintenance.summary`, but the summary job in the reusable workflow only writes to `$GITHUB_STEP_SUMMARY` (which does not require `actions: write`). The `actions: write` permission may only be needed if the reusable workflow uses `actions/cache` or similar.
   - **Severity:** LOW
   - **Recommendation:** Verify if the reusable workflow actually needs `actions: write`; tighten if possible.

### Low / Informational

4. **No `actions: read` permission at workflow level** -- The reusable workflow's `scan-codeql` job declares `actions: read` at the job level, which overrides the workflow-level `actions: write`. This is correct but worth noting for clarity.

5. **Schedule cron comment alignment** -- The comment `# Monday 23:00 BJT -- flag audit` is correct (UTC+8), but BJT is not a standard timezone abbreviation in all contexts. Minor readability concern.

---

## Test Cases for Automation

### Trigger tests

| ID | Test | Expected |
|----|------|----------|
| T-01 | Push to `main` changing `manifest.yml` | Workflow triggers, mode resolves to `pr-review` |
| T-02 | Push to `main` changing unrelated file (e.g., `README.md`) | Workflow does NOT trigger (path filter) |
| T-03 | Pull request changing `.github/workflows/ci.yml` | Workflow triggers, mode resolves to `pr-review` |
| T-04 | Pull request changing `src/index.ts` | Workflow does NOT trigger (path filter) |
| T-05 | `workflow_dispatch` with mode=`full` | `maintenance` job runs |
| T-06 | `workflow_dispatch` with mode=`scan-only` | `maintenance` job runs |
| T-07 | `workflow_dispatch` with mode=`deps-only` | `maintenance` job runs |
| T-08 | `workflow_dispatch` with mode=`flag-audit` | `flag-audit` job runs |
| T-09 | `workflow_dispatch` with no mode input | Defaults to `full`, `maintenance` job runs |
| T-10 | Schedule `0 2 * * 1` (Monday 02:00 UTC) | Mode resolves to `full` |
| T-11 | Schedule `0 15 * * 1` (Monday 15:00 UTC) | Mode resolves to `flag-audit` |

### Mode resolution tests

| ID | Test | Expected |
|----|------|----------|
| T-20 | Mode = `pr-review` | Only `verify-sha` job runs; `maintenance` and `flag-audit` are skipped |
| T-21 | Mode = `flag-audit` | Only `flag-audit` job runs; `maintenance` and `verify-sha` are skipped |
| T-22 | Mode = `full` | Only `maintenance` job runs; `verify-sha` and `flag-audit` are skipped |
| T-23 | Mode = `scan-only` | Only `maintenance` job runs (passes `scan-only` to reusable) |
| T-24 | Mode = `deps-only` | Only `maintenance` job runs (passes `deps-only` to reusable) |

### SHA integrity tests

| ID | Test | Expected |
|----|------|----------|
| T-30 | All third-party `uses:` refs in workflow are 40-char hex SHAs | `actionlint` and `verify-sha-consistency.sh` pass |
| T-31 | `YiAgent/OpenCI` SHA in reusable workflow call matches `manifest.yml` | SHA `f62931bd...` matches |
| T-32 | `actions/checkout` SHA matches `manifest.yml` | SHA `11bd71901bbe...` matches |
| T-33 | `step-security/harden-runner` SHA matches `manifest.yml` | SHA `f808768d...` matches |
| T-34 | No actions reference `manifest-pending.yml` entries | PASS (pending is empty `{}`) |
| T-35 | No deprecated actions (per SPEC Appendix B.2) | PASS |

### Reusable workflow integration tests

| ID | Test | Expected |
|----|------|----------|
| T-40 | `reusable-maintenance.yml` exists at pinned SHA | Verified via `git ls-tree f62931bd...` |
| T-41 | Reusable workflow accepts all `with:` inputs from caller | Inputs match: `mode`, `openci-ref`, `image-ref`, `runner` |
| T-42 | Reusable workflow accepts all `secrets:` from caller | Secrets match: `anthropic-api-key`, `api-base-url` |
| T-43 | `snyk-token` secret is optional (not passed by caller) | Reusable workflow declares it `required: false` |

### Security tests

| ID | Test | Expected |
|----|------|----------|
| T-50 | No hardcoded secrets or API keys in workflow | PASS -- all secrets via `${{ secrets.* }}` |
| T-51 | `persist-credentials: false` on all checkout steps | PASS -- all checkout steps set this |
| T-52 | `harden-runner` is first step in every job | PASS -- present in all 4 jobs |
| T-53 | Job permissions are narrowed from workflow-level where possible | PASS -- `verify-sha` and `flag-audit` declare job-level permissions |
| T-54 | User inputs (`inputs.mode`) are not directly interpolated in `run:` without env var | PASS -- `INPUT_MODE` is passed via `env:` block |
| T-55 | `egress-policy: audit` on all harden-runner steps | PASS |

### Concurrency tests

| ID | Test | Expected |
|----|------|----------|
| T-60 | Two scheduled runs for the same ref do not cancel each other | `cancel-in-progress: false` |
| T-61 | Push and schedule runs for the same ref use different concurrency groups | Group includes `github.event_name` |

### Runner tests

| ID | Test | Expected |
|----|------|----------|
| T-70 | All jobs use `blacksmith-2vcpu-ubuntu-2404` runner | PASS -- consistent across `resolve-mode`, `verify-sha`, `flag-audit`; reusable workflow receives it via `with: runner` |

---

## Summary

| Category | Count |
|----------|-------|
| Critical issues | 0 |
| High issues | 0 |
| Medium issues | 2 (duplicated ref logic, possibly unnecessary `packages: read`) |
| Low issues | 2 (`actions: write` may be broader than needed, BJT comment) |
| actionlint errors | 0 |
| YAML syntax errors | 0 |
| SHA mismatches | 0 |
| Missing referenced files | 0 |

**Overall assessment:** The workflow is well-structured, follows security best practices (SHA pinning, harden-runner, minimal persist-credentials, env-var isolation for user inputs), and has clear mode-based routing. The medium issues are maintainability concerns, not functional bugs.

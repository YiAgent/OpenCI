# Workflow Test Report: pull-request.yml

Generated: 2026-05-04

## Overview

- **File**: `.github/workflows/pull-request.yml`
- **Name**: `pull-request`
- **Purpose**: Event entry that fires the PR quality gate on every pull request. Calls `reusable-pr.yml` for all deterministic PR checks.
- **Lines**: 40 (thin caller shim)
- **actionlint**: PASS (no errors)
- **YAML syntax**: PASS (`yaml.safe_load` succeeds)
- **SHA pinned reusable workflow**: `YiAgent/OpenCI/.github/workflows/reusable-pr.yml@f62931bd0e2b73800512625a9fc5118557957ff3`
- **SHA exists locally**: YES (verified via `git cat-file -t`)
- **Reusable workflow exists at SHA**: YES (verified via `git show`)

## Node-by-Node Status

### Trigger Events (`on:`)

| Event | Types | Status | Notes |
|-------|-------|--------|-------|
| `pull_request` | `opened`, `synchronize`, `reopened`, `ready_for_review` | OK | Standard PR lifecycle events |
| `workflow_dispatch` | (none) | OK | Manual trigger supported |

### Permissions

| Scope | Value | Notes |
|-------|-------|-------|
| `contents` | `read` | Minimal read access |
| `actions` | `read` | Required for artifact download |
| `checks` | `write` | Required for check status reporting |
| `issues` | `write` | Required for commenting on related issues |
| `pull-requests` | `write` | Required for PR comments and labels |
| `security-events` | `write` | Required for security scanning |
| `id-token` | `write` | Required for OIDC (Anthropic API auth) |
| `statuses` | `write` | Required for commit status updates |
| `packages` | `read` | Required for container registry access |

Status: OK -- caller elevates permissions appropriately; reusable workflow sets `permissions: {}` at top level and grants per-job.

### Concurrency

| Setting | Value | Status |
|---------|-------|--------|
| Group | `pull-request-${{ github.event.pull_request.number \|\| github.run_id }}` | OK |
| Cancel-in-progress | `false` | NOTE -- see Issues |

The reusable workflow defines its own concurrency (`pr-${{ github.event.pull_request.number || github.ref }}`, `cancel-in-progress: true`) but the caller's concurrency takes precedence at the workflow level.

### Jobs

The caller defines a single job `checks` that delegates to the reusable workflow.

| Job | Status | Notes |
|-----|--------|-------|
| `checks` | OK | Calls `reusable-pr.yml` with all inputs and secrets |

### Inputs Passed to Reusable Workflow

| Input | Value | Status | Notes |
|-------|-------|--------|-------|
| `enable-ai-review` | `true` | OK | Enables AI code review |
| `enable-eval` | `true` | OK | Enables prompt evaluation |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | WARN | Custom runner label; see Issues |
| `model` | `${{ vars.AI_MODEL \|\| '' }}` | OK | Falls back to empty (callee defaults to `claude-sonnet-4-5-20250929`) |

### Secrets Passed to Reusable Workflow

| Secret | Source | Status | Notes |
|--------|--------|--------|-------|
| `anthropic-api-key` | `secrets.ANTHROPIC_API_KEY` | OK | Required for AI review |
| `api-base-url` | `secrets.ANTHROPIC_BASE_URL` | OK | Optional custom Anthropic endpoint |

### Reusable Workflow Internal Structure (reusable-pr.yml @ pinned SHA)

The reusable workflow contains 16 jobs with the following dependency chain:

```
preflight
  ├── detect-language
  │     ├── lint
  │     ├── test
  │     │     └── coverage
  │     └── build-check
  ├── auto-label (conditional: PR event)
  ├── auto-assign-fallback (conditional: no reviewers)
  ├── validate-pr-title (conditional: PR event)
  ├── validate-pr-desc (conditional: PR event)
  ├── scan-deps (conditional: PR event)
  ├── scan-secrets
  ├── scan-sonarcloud
  ├── verify-sha
  └── copilot-review (conditional: enable-copilot-review)
        
Stage 2: enrich (needs: lint, test, validate-pr-title, scan-deps, scan-secrets, verify-sha)
  └── Stage 3: agent (needs: enrich)
        └── Stage 4: execute (needs: enrich, agent)
```

### SHA Reference Verification

All third-party action SHAs in the reusable workflow match `manifest.yml`:

| Action | SHA | Manifest Match |
|--------|-----|---------------|
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) | OK |
| `actions/download-artifact` | `d3f86a106a0bac45b974a628896c90dbdf5c8093` (v4.3.0) | OK |
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` (v2.17.0) | OK |
| `dorny/paths-filter` | `de90cc6fb38fc0963ad72b210f1f284cd68cea36` (v3.0.2) | OK |

### Local Composite Actions Referenced (all exist at pinned SHA)

All 18 composite actions under `actions/pr/` and 3 under `actions/_common/` exist at `f62931bd`:

- `actions/pr/agent-review`, `auto-assign-fallback`, `auto-label`, `build-check`, `check-coverage`, `enrich`, `eval-prompt`, `execute-plan`, `extract-plan`, `lint-code`, `review-ai`, `scan-deps`, `scan-secrets`, `scan-sonarcloud`, `test-unit`, `validate-pr-description`, `validate-pr-title`
- `actions/_common/api-key-gate`, `check-trust`, `claude-harness`, `detect-language`

### Scripts Referenced (all exist at pinned SHA)

- `.github/scripts/preflight-secrets.sh` -- OK
- `.github/scripts/verify-sha-consistency.sh` -- OK

## Issues Found

### WARN: Custom Runner Label (Medium)

**Location**: Line 35 -- `runner: blacksmith-2vcpu-ubuntu-2404`

The caller overrides the runner to `blacksmith-2vcpu-ubuntu-2404` (a Blacksmith runner). The reusable workflow defaults to `ubuntu-latest`. This means:
- The workflow requires the Blacksmith GitHub App to be installed and configured on the repository.
- If the Blacksmith runner is unavailable (e.g., in a fork or if the app is uninstalled), all 16 jobs will fail with "no runner available."
- Fork contributors cannot run this workflow without access to the Blacksmith runner.

**Recommendation**: Document the Blacksmith runner dependency. Consider a fallback strategy for forks, or use `ubuntu-latest` as the default with Blacksmith as an optional override via a repository variable.

### INFO: Trailing Whitespace in Model Expression (Low)

**Location**: Line 36 -- `model: ${{ vars.AI_MODEL || ''  }}`

There is a double space before `}}`. This is syntactically valid but cosmetically inconsistent. No functional impact.

### INFO: Concurrency Cancel-in-Progress is False (Low)

**Location**: Line 28 -- `cancel-in-progress: false`

The caller sets `cancel-in-progress: false`, meaning multiple runs for the same PR will queue rather than cancel. This is intentional (the comment in the reusable workflow sets `cancel-in-progress: true` for the callee, but the caller overrides it). This means rapid pushes to a PR branch will accumulate queued workflow runs rather than cancelling superseded ones, which can waste runner minutes.

**Recommendation**: Confirm this is intentional. If the team pushes frequently to PR branches, consider setting this to `true`.

### INFO: enable-copilot-review Not Passed (Low)

The caller does not pass `enable-copilot-review` to the reusable workflow. The reusable workflow defaults this to `false`. If Copilot review is desired, the caller must explicitly set `enable-copilot-review: true`. This appears intentional based on the caller's design.

### INFO: Manifest SHA Matches Current Bump Cycle (OK)

The pinned SHA `f62931bd0e2b73800512625a9fc5118557957ff3` matches the entry in `manifest.yml` line 104:
```
YiAgent/OpenCI: "f62931bd0e2b73800512625a9fc5118557957ff3"
```
The current HEAD is `a2ec4435` (4 commits ahead). The SHA is valid but not the latest. This is expected for pinned references.

## Test Cases for Automation

### TC-1: YAML Syntax Validation
```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/pull-request.yml'))"
```
Expected: Exit code 0, no exceptions.

### TC-2: actionlint Validation
```
actionlint .github/workflows/pull-request.yml
```
Expected: No errors or warnings.

### TC-3: Reusable Workflow Exists at Pinned SHA
```
git show f62931bd0e2b73800512625a9fc5118557957ff3:.github/workflows/reusable-pr.yml
```
Expected: File content returned (exit code 0).

### TC-4: All Third-Party Action SHAs Match Manifest
For each `uses:` line with a SHA (excluding `./` local refs), extract the action name and SHA, then verify against `manifest.yml`. All must match.

### TC-5: All Local Composite Actions Exist at Pinned SHA
For each `./.openci/actions/...` reference in the reusable workflow, verify the directory exists at the pinned SHA via `git ls-tree`.

### TC-6: All Referenced Scripts Exist at Pinned SHA
For each `.github/scripts/...` reference, verify the file exists at the pinned SHA.

### TC-7: Concurrency Group Expression Validity
Verify the expression `${{ github.event.pull_request.number || github.run_id }}` produces a valid string for both PR and dispatch events.

### TC-8: Permission Escalation Check
Verify the caller's permissions are a superset of what the reusable workflow's jobs require. The caller must grant `checks:write`, `pull-requests:write`, `issues:write`, `id-token:write`, and `statuses:write`.

### TC-9: Secret Propagation Check
Verify that all secrets referenced in the reusable workflow's `secrets:` block are passed by the caller. Missing required secrets will cause runtime failures.

### TC-10: Runner Label Availability
Verify that the runner label `blacksmith-2vcpu-ubuntu-2404` is available on the target repository. This requires checking the repository's self-hosted runner configuration (not verifiable from the workflow file alone).

### TC-11: Input Type Consistency
Verify that input types in the caller match the reusable workflow's input schema:
- `enable-ai-review`: boolean -> boolean (OK)
- `enable-eval`: boolean -> boolean (OK)
- `runner`: string -> string (OK)
- `model`: string -> string (OK)

### TC-12: Workflow Name Uniqueness
Verify no other workflow in the repository has the same `name: pull-request` value, which could cause check name collisions in the GitHub UI.

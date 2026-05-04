# Workflow Test Report: reusable-agent.yml

**File:** `.github/workflows/reusable-agent.yml`
**Date:** 2026-05-04
**Tested by:** Claude automated analysis

---

## Overview

`reusable-agent.yml` (internal name: `claude-harness`) is the central reusable workflow that wraps the `actions/_common/claude-harness` composite action. It provides a single pre-configured entrypoint for AI agent tasks across OpenCI and downstream consumers (e.g. EvolveCI). Callers supply only `task`, `prompt`/`prompt-path`, and `api-key`; all MCP servers, CI permissions, tool whitelists, and Slack env are pre-configured here.

**Structure:** 2 jobs (`preflight` -> `ai-task`), both on configurable runner.

---

## Inputs/Secrets/Outputs Definition

### Inputs (14 total)

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `openci-ref` | string | false | `main` | OpenCI ref for vendoring .openci/* |
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |
| `task` | string | **true** | -- | Logical task name |
| `prompt` | string | false | `""` | Direct prompt text or slash command |
| `prompt-path` | string | false | `""` | Path to prompt file (relative to caller repo) |
| `context` | string | false | `"{}"` | JSON object for {{name}} placeholder rendering |
| `model` | string | false | `claude-sonnet-4-5-20250929` | Claude model ID |
| `max-turns` | number | false | `10` | Maximum agent turns |
| `system-prompt` | string | false | `""` | Optional system prompt |
| `api-provider` | string | false | `anthropic` | API provider: anthropic/bedrock/vertex/foundry |
| `timeout-minutes` | number | false | `15` | Job timeout in minutes |
| `extra-allowed-tools` | string | false | `""` | Extra tools to allow |
| `extra-disallowed-tools` | string | false | `""` | Tools to explicitly disallow |
| `mcp-config` | string | false | `""` | JSON string or path for --mcp-config |
| `use-sticky-comment` | boolean | false | `true` | Use sticky comment for PR/Issue dedup |
| `extra-env` | string | false | `"{}"` | JSON object of additional env vars |

### Secrets (12 total)

| Secret | Required | Referenced in Steps | Passed by Callers |
|--------|----------|---------------------|-------------------|
| `api-key` | false | Yes (lines 156, 250) | Yes |
| `oauth-token` | false | Yes (lines 157, 251) | No |
| `api-base-url` | false | Yes (line 252) | Yes |
| `github-token` | false | Yes (lines 193, 256) | No (uses fallback `github.token`) |
| `slack-webhook` | false | Yes (line 257) | Yes |
| `sentry-token` | false | **No** | Yes |
| `datadog-api-key` | false | **No** | Yes |
| `datadog-app-key` | false | **No** | No |
| `posthog-api-key` | false | **No** | No |
| `langsmith-api-key` | false | **No** | No |
| `axiom-token` | false | **No** | No |
| `slack-webhook-url` | false | **No** | No |

### Outputs (4 total)

| Output | Source | Status |
|--------|--------|--------|
| `execution-file` | `jobs.ai-task.outputs.execution-file` | OK - matches step output |
| `session-id` | `jobs.ai-task.outputs.session-id` | OK - matches step output |
| `structured-output` | `jobs.ai-task.outputs.structured-output` | OK - matches step output |
| `prompt-source` | `jobs.ai-task.outputs.prompt-source` | OK - matches step output |

---

## Node-by-Node Status

### Top-Level

| Property | Value | Status |
|----------|-------|--------|
| `name` | `claude-harness` | OK |
| `permissions` | `{}` (empty) | OK - least-privilege default |
| `concurrency` | `claude-harness-${{ github.run_id }}` | INFO - `run_id` is unique per run; group never collides. `cancel-in-progress: false` is effectively a no-op. |

### Job: `preflight`

| Property | Value | Status |
|----------|-------|--------|
| `runs-on` | `${{ inputs.runner }}` | OK |
| `timeout-minutes` | 2 | OK |
| `permissions` | `contents: read` | OK |

**Steps:**

1. **Harden Runner** - `step-security/harden-runner@f808768d1510423e83855289c910610ca9b43176` (v2.17.0)
   - SHA matches manifest.yml. OK.

2. **Checkout** - `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2)
   - SHA matches manifest.yml. `persist-credentials: false`. OK.

3. **Check required credentials** - Shell step
   - Validates that `api-key` or `oauth-token` is provided, or `api-provider` is bedrock/vertex/foundry.
   - Uses proper `::error title=` annotation. OK.

### Job: `ai-task`

| Property | Value | Status |
|----------|-------|--------|
| `needs` | `preflight` | OK - correct dependency |
| `runs-on` | `${{ inputs.runner }}` | OK |
| `timeout-minutes` | `${{ inputs.timeout-minutes }}` | OK |
| `permissions` | `contents: write, pull-requests: write, issues: write, actions: read, id-token: write` | INFO - see note below |

**Permissions note:** `id-token: write` is declared but not directly used by any step in this workflow or the composite action. It may be needed by `anthropics/claude-code-action` (the underlying action) or by downstream Claude operations (e.g. OIDC-based auth for cloud providers). LOW risk.

**Steps:**

1. **Harden Runner** - Same SHA. OK.

2. **Checkout** - Same SHA. Uses `secrets.github-token || github.token` for token. OK.

3. **Determine OpenCI ref to vendor** (id: `openci_ref`)
   - Parses `github.workflow_ref` to extract the OpenCI ref when called cross-repo.
   - Uses parameter expansion (not eval), low injection risk.
   - Logic: explicit input > workflow_ref extraction > fallback to 'main'. OK.

4. **Vendor OpenCI source** - `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`
   - Checks out `YiAgent/OpenCI` at the resolved ref into `.openci/`. OK.

5. **Run claude-harness composite** (id: `harness`) - `uses: ./.openci/actions/_common/claude-harness`
   - Passes 21 inputs to the composite. OK.
   - Maps `api-provider` to boolean flags (`use-bedrock`, `use-vertex`, `use-foundry`). OK.

### Action SHA Verification

| Action | SHA in Workflow | SHA in manifest.yml | Status |
|--------|-----------------|---------------------|--------|
| `step-security/harden-runner` | `f808768d1510423e83855289c910610ca9b43176` | `f808768d1510423e83855289c910610ca9b43176` | MATCH |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | `11bd71901bbe5b1630ceea73d27597364c9af683` | MATCH |

---

## Callers Analysis

### Internal Callers (this repo)

| File | Line | SHA | Status |
|------|------|-----|--------|
| `.github/workflows/agent.yml` | 43 | `f62931bd0e2b73800512625a9fc5118557957ff3` | OK - SHA is ancestor of HEAD |

### Caller Input/Secret Mapping (agent.yml -> reusable-agent.yml)

**Inputs passed by agent.yml:**

| agent.yml input | reusable input | Status |
|-----------------|----------------|--------|
| `inputs.task` | `task` | OK |
| `inputs.prompt` | `prompt` | OK |
| `inputs.prompt-path` | `prompt-path` | OK |
| `inputs.model \|\| vars.AI_MODEL \|\| ''` | `model` | OK - good fallback chain |
| `blacksmith-2vcpu-ubuntu-2404` | `runner` | OK - overrides default |
| (not passed) | `openci-ref` | OK - uses default `main` |
| (not passed) | `context` | OK - uses default `{}` |
| (not passed) | `max-turns` | OK - uses default `10` |
| (not passed) | `system-prompt` | OK - uses default `""` |
| (not passed) | `api-provider` | OK - uses default `anthropic` |
| (not passed) | `timeout-minutes` | OK - uses default `15` |
| (not passed) | `extra-allowed-tools` | OK - uses default `""` |
| (not passed) | `extra-disallowed-tools` | OK - uses default `""` |
| (not passed) | `mcp-config` | OK - uses default `""` |
| (not passed) | `use-sticky-comment` | OK - uses default `true` |
| (not passed) | `extra-env` | OK - uses default `{}` |

**Secrets passed by agent.yml:**

| agent.yml secret source | reusable secret | Status |
|-------------------------|-----------------|--------|
| `secrets.ANTHROPIC_API_KEY` | `api-key` | OK |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` | OK |
| `secrets.SLACK_WEBHOOK_URL` | `slack-webhook` | OK |
| `secrets.SENTRY_TOKEN` | `sentry-token` | WARNING - declared but never referenced in any step |
| `secrets.DD_API_KEY` | `datadog-api-key` | WARNING - declared but never referenced in any step |
| (not passed) | `oauth-token` | OK - optional |
| (not passed) | `github-token` | OK - falls back to `github.token` |
| (not passed) | `datadog-app-key` | OK - optional, unused |
| (not passed) | `posthog-api-key` | OK - optional, unused |
| (not passed) | `langsmith-api-key` | OK - optional, unused |
| (not passed) | `axiom-token` | OK - optional, unused |
| (not passed) | `slack-webhook-url` | OK - optional, unused |

### External Callers

Cannot verify external callers (e.g. EvolveCI) from this repo alone. The workflow is designed for cross-repo consumption via `YiAgent/OpenCI/.github/workflows/reusable-agent.yml@<sha>`.

---

## Issues Found

### MEDIUM - 7 secrets declared but never referenced in workflow steps

**Secrets:** `sentry-token`, `datadog-api-key`, `datadog-app-key`, `posthog-api-key`, `langsmith-api-key`, `axiom-token`, `slack-webhook-url`

These secrets are declared in the `on.workflow_call.secrets:` block but no step in the reusable workflow reads them. They are not passed to the composite action either. Two of them (`sentry-token`, `datadog-api-key`) are actively mapped by the `agent.yml` caller, meaning the caller is providing secrets that silently go nowhere.

**Impact:** Callers may believe these secrets are being used for observability integrations, but they are not wired to anything.

**Recommendation:** Either wire these secrets to the composite action (if it supports them) or remove them from the declaration to avoid caller confusion. If they are reserved for future use, add a comment.

### LOW - Duplicate Slack webhook secret names

The reusable declares both `slack-webhook` and `slack-webhook-url` as separate secrets. Only `slack-webhook` is referenced in steps. This is confusing for callers who may pass `slack-webhook-url` expecting it to work.

**Recommendation:** Remove `slack-webhook-url` or consolidate to a single name.

### LOW - Concurrency group uses `github.run_id`

The concurrency group `claude-harness-${{ github.run_id }}` uses the run ID which is unique per workflow run. This means the group never collides, making `cancel-in-progress: false` a no-op. If the intent is to prevent parallel runs for the same task, a group like `claude-harness-${{ inputs.task }}-${{ github.ref }}` would be more appropriate.

**Note:** The caller `agent.yml` uses `agent-${{ inputs.task }}-${{ github.run_id }}` which has the same issue.

### INFO - `id-token: write` permission declared but unused in workflow steps

The `ai-task` job declares `id-token: write` but no step in the reusable workflow or the composite action directly uses OIDC token exchange. This may be required by `anthropics/claude-code-action` internally. Verify with the action's documentation.

### INFO - Caller SHA is stale (not a bug, but worth noting)

The `agent.yml` caller references `f62931bd0e2b73800512625a9fc5118557957ff3` which is an ancestor of HEAD but not the current HEAD (`a2ec4435`). No commits have modified `reusable-agent.yml` between these SHAs, so behavior is identical, but the caller should be updated to reference the latest verified SHA.

### INFO - Composite inputs not exposed by reusable

The composite action accepts several inputs that the reusable workflow does not expose:
- `session-timeout-ms` (default: 3000000ms / 50 min)
- `use-commit-signing` / `ssh-signing-key`
- `extra-permissions`
- `plugins` / `plugin-marketplaces`
- `allowed-bots` / `bot-id` / `bot-name`
- `base-branch`
- `classify-inline-comments` / `include-fix-links`
- `comment-id` / `branch-name`

These all have sensible defaults in the composite, so this is by design (the reusable is a curated subset). Documenting this intentional limitation would help maintainers.

---

## Test Cases for Automation

### TC-1: YAML Syntax Validation
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/reusable-agent.yml'))"
```
**Expected:** No exception.

### TC-2: Actionlint Validation
```bash
actionlint .github/workflows/reusable-agent.yml
```
**Expected:** No errors.

### TC-3: SHA Consistency with Manifest
For every `uses:` line with a pinned SHA, verify the SHA matches `manifest.yml`.
```bash
# Extract SHAs from workflow, cross-check against manifest.yml
grep -oP 'uses:.*@([a-f0-9]{40})' .github/workflows/reusable-agent.yml
```
**Expected:** All SHAs match manifest entries.

### TC-4: Secret Reference Validity
Every `secrets.<name>` reference in steps must have a corresponding declaration in `on.workflow_call.secrets:`.
```bash
# Extract referenced secret names, verify they are declared
grep -oP 'secrets\.\K[\w-]+' .github/workflows/reusable-agent.yml | sort -u
```
**Expected:** All referenced secrets (`api-key`, `oauth-token`, `api-base-url`, `github-token`, `slack-webhook`) are declared. PASS.

### TC-5: Input Reference Validity
Every `inputs.<name>` reference must have a corresponding declaration in `on.workflow_call.inputs:`.
```bash
grep -oP 'inputs\.\K[\w-]+' .github/workflows/reusable-agent.yml | sort -u
```
**Expected:** All referenced inputs are declared. PASS.

### TC-6: Preflight Credential Gate
Verify that the preflight job correctly rejects runs without credentials when `api-provider` is `anthropic`.
**Expected:** Job fails with `::error title=Missing credentials::` annotation.

### TC-7: Cross-Repo Ref Resolution
Test the `Determine OpenCI ref to vendor` step logic:
- When called from `YiAgent/OpenCI` repo: extracts ref from `workflow_ref`
- When called from external repo with default input: falls back to `main`
- When called with explicit `openci-ref` input: uses that value

### TC-8: Caller Input Compatibility
For each known caller, verify that all `with:` keys match declared inputs and all `secrets:` keys match declared secrets.
```bash
# For agent.yml:
grep -A20 'uses:.*reusable-agent.yml' .github/workflows/agent.yml
```
**Expected:** No undefined input or secret names. PASS.

### TC-9: Output Passthrough
Verify that all 4 declared outputs are properly wired from `jobs.ai-task.outputs.*` to `steps.harness.outputs.*`.
**Expected:** `execution-file`, `session-id`, `structured-output`, `prompt-source` all pass through. PASS.

### TC-10: Permissions Least-Privilege
Verify top-level `permissions: {}` is set and each job declares only the permissions it needs.
**Expected:** Top-level empty, `preflight` has `contents: read`, `ai-task` has scoped write permissions. PASS.

---

## Summary

| Category | Count |
|----------|-------|
| CRITICAL issues | 0 |
| HIGH issues | 0 |
| MEDIUM issues | 1 (7 unused secrets) |
| LOW issues | 2 (duplicate slack secret, run_id concurrency) |
| INFO items | 3 (id-token, stale SHA, unexposed composite inputs) |
| actionlint | PASS |
| YAML syntax | PASS |
| SHA consistency | PASS |
| Secret/input references | PASS |
| Caller compatibility | PASS |

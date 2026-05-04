# Workflow Test Report: agent.yml

## Overview

- **File**: `.github/workflows/agent.yml`
- **Name**: `agent`
- **Purpose**: Manual dispatch entry point for the AI harness -- the single surface for ad-hoc Claude tasks in OpenCI's dogfooding.
- **Trigger**: `workflow_dispatch` (manual only)
- **Jobs**: 1 (`agent`) -- delegates entirely to a reusable workflow
- **Reusable deps**: `YiAgent/OpenCI/.github/workflows/reusable-agent.yml@f62931bd0e2b73800512625a9fc5118557957ff3`
- **Lint result**: actionlint passed (exit 0), YAML syntax valid

## Node-by-Node Status

### Trigger Configuration (`on:`)

- **Status**: PASS
- **Event**: `workflow_dispatch` only -- correct for a manual-entry shim.
- **Inputs**:
  | Input | Type | Required | Default | Status |
  |-------|------|----------|---------|--------|
  | `task` | string | yes | `claude-default` | PASS -- required, has sensible default |
  | `prompt` | string | no | `""` | PASS -- optional direct prompt text |
  | `prompt-path` | string | no | `""` | PASS -- optional path to prompt file |
  | `model` | string | no | `""` | PASS -- falls back to `vars.AI_MODEL` then reusable default |
- **Details**: No scheduled triggers, no push/PR triggers. This is intentional -- the file is a manual-only shim. Consumers compose their own scheduled/event-driven workflows that invoke the reusable directly.

### Permissions

- **Status**: PASS (with note)
- **Granted**: `contents: write`, `issues: write`, `pull-requests: write`, `id-token: write`, `actions: read`
- **Details**: Broad permissions, appropriate for an AI agent that may commit files, create issues, post PR comments, and query workflow runs. These are inherited by the reusable workflow call. The reusable also declares its own permissions at the job level, which take precedence during execution.

### Concurrency

- **Status**: WARN
- **Group**: `agent-${{ inputs.task }}-${{ github.run_id }}`
- **cancel-in-progress**: `false`
- **Details**: The group includes `github.run_id`, which is unique per workflow run. This means the concurrency group is always unique -- no two runs will ever share a group. The `cancel-in-progress: false` setting is therefore a no-op. If the intent is to prevent overlapping runs of the same task, the group should use `github.ref` or omit `github.run_id`. See Issues #1 below.

### Job: `agent`

#### Reusable Workflow Call

- **Status**: PASS
- **Target**: `YiAgent/OpenCI/.github/workflows/reusable-agent.yml@f62931bd0e2b73800512625a9fc5118557957ff3`
- **SHA validity**: The SHA `f62931bd0e2b73800512625a9fc5118557957ff3` exists in the repository history (commit: "Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults"). It matches `manifest.yml` line 104 (`YiAgent/OpenCI` entry).
- **SHA currency**: HEAD is `a2ec443` (2 commits ahead of the referenced SHA). The reusable-agent.yml file has NOT changed between the referenced SHA and HEAD, so the pinned version is functionally current.
- **Local file**: `reusable-agent.yml` exists locally and matches the expected reusable workflow structure.

#### Inputs Passed

| agent.yml input | Expression | Reusable input | Status |
|----------------|------------|----------------|--------|
| `task` | `${{ inputs.task }}` | `task` (required) | PASS |
| `prompt` | `${{ inputs.prompt }}` | `prompt` (optional) | PASS |
| `prompt-path` | `${{ inputs.prompt-path }}` | `prompt-path` (optional) | PASS |
| `model` | `${{ inputs.model \|\| vars.AI_MODEL \|\| '' }}` | `model` (optional, default `claude-sonnet-4-5-20250929`) | PASS -- 3-tier fallback chain |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | `runner` (optional, default `ubuntu-latest`) | PASS -- consistent with other workflows |

**Not passed** (using reusable defaults):
- `openci-ref` (default: `main`)
- `context` (default: `"{}"`)
- `max-turns` (default: `10`)
- `system-prompt` (default: `""`)
- `api-provider` (default: `anthropic`)
- `timeout-minutes` (default: `15`)
- `extra-allowed-tools` (default: `""`)
- `extra-disallowed-tools` (default: `""`)
- `mcp-config` (default: `""`)
- `use-sticky-comment` (default: `true`)
- `extra-env` (default: `"{}"`)

All unpassed inputs have sensible defaults in the reusable. No issues.

#### Secrets Mapping

| Repo secret (UPPER_SNAKE_CASE) | Reusable input (kebab-case) | Status |
|-------------------------------|---------------------------|--------|
| `secrets.ANTHROPIC_API_KEY` | `api-key` | PASS |
| `secrets.ANTHROPIC_BASE_URL` | `api-base-url` | PASS |
| `secrets.SLACK_WEBHOOK_URL` | `slack-webhook` | PASS |
| `secrets.SENTRY_TOKEN` | `sentry-token` | PASS |
| `secrets.DD_API_KEY` | `datadog-api-key` | PASS |

**Not mapped** (optional, not provided):
- `oauth-token`, `github-token` (reusable falls back to `github.token`)
- `datadog-app-key`, `posthog-api-key`, `langsmith-api-key`, `axiom-token`
- `slack-webhook-url` (separate from `slack-webhook` in the reusable -- see Issues #2)

The explicit mapping is correct and necessary. The comment in the workflow explains why `secrets: inherit` does not work here (kebab-case vs UPPER_SNAKE_CASE naming mismatch).

### Runner

- **Status**: PASS
- **Label**: `blacksmith-2vcpu-ubuntu-2404`
- **Details**: Custom Blacksmith runner, consistent with other workflows in the repo (`ci.yml`, `deploy.yml`, `release.yml`, `dependencies.yml`, `docs.yml`). The reusable workflow's default is `ubuntu-latest`; this override selects a larger runner for AI workloads.

## Issues Found

1. **[MEDIUM] Concurrency group includes `github.run_id`, making deduplication ineffective**
   - **Location**: Line 38, `concurrency.group`
   - **Current**: `agent-${{ inputs.task }}-${{ github.run_id }}`
   - **Problem**: `github.run_id` is unique per run, so every dispatch gets its own concurrency group. Two concurrent runs of the same task will never cancel each other. `cancel-in-progress: false` is redundant.
   - **Recommendation**: If the intent is to allow only one run per task at a time, use `agent-${{ inputs.task }}` (or `agent-${{ inputs.task }}-${{ github.ref }}`). If the intent is to never cancel (current behavior), the concurrency block could be removed entirely to reduce noise.
   - **Impact**: No functional breakage, but the concurrency guard provides no protection against overlapping runs.

2. **[LOW] `slack-webhook-url` reusable secret input not mapped**
   - **Location**: Lines 56-61, `secrets:` block
   - **Details**: The reusable workflow declares both `slack-webhook` and `slack-webhook-url` as separate optional secret inputs. Agent.yml maps `secrets.SLACK_WEBHOOK_URL` to `slack-webhook` only. The `slack-webhook-url` input is not provided. This is likely intentional (one mapping is sufficient), but the naming is confusing -- two similarly-named secret inputs in the reusable could cause mapping errors in other callers.
   - **Impact**: None if `slack-webhook` is the canonical input. Potential confusion for maintainers.

3. **[LOW] `context` input not exposed via `workflow_dispatch`**
   - **Details**: The reusable workflow supports a `context` input (JSON object with placeholder variables for prompt rendering). Agent.yml does not expose this as a `workflow_dispatch` input, so callers using this manual shim cannot pass context variables without editing the workflow.
   - **Impact**: Minor -- the default `"{}"` is safe. Consumers who need context can invoke the reusable directly.

4. **[LOW] Hardcoded runner label**
   - **Location**: Line 53, `runner: blacksmith-2vcpu-ubuntu-2404`
   - **Details**: The runner label is hardcoded rather than being a `workflow_dispatch` input. If the Blacksmith runner becomes unavailable, the workflow must be edited rather than overridden at dispatch time.
   - **Impact**: Minor -- consistent with other workflows, and the reusable default (`ubuntu-latest`) provides a fallback pattern.

5. **[INFO] SHA reference is 2 commits behind HEAD**
   - **Location**: Line 43, reusable workflow `uses:` ref
   - **Details**: The pinned SHA `f62931b` is 2 commits behind HEAD (`a2ec443`). However, `reusable-agent.yml` has not changed between these commits, so the reference is functionally current. The SHA matches `manifest.yml`.
   - **Impact**: None currently. Future changes to `reusable-agent.yml` will require a SHA bump.

## Test Cases for Automation

```
test_case_1: "YAML syntax validation"
  command: python3 -c "import yaml; yaml.safe_load(open('.github/workflows/agent.yml'))"
  expected: exit 0

test_case_2: "actionlint passes"
  command: actionlint .github/workflows/agent.yml
  expected: exit 0, no output

test_case_3: "SHA in uses: matches manifest.yml"
  description: Extract the 40-char SHA from the `uses:` line in agent.yml and verify it matches the YiAgent/OpenCI entry in manifest.yml.
  method: grep -oP '@\K[0-9a-f]{40}' .github/workflows/agent.yml | xargs -I{} grep -q {} manifest.yml

test_case_4: "SHA exists in git history"
  description: Verify the referenced SHA is a valid commit in the repository.
  command: git cat-file -t <sha> == "commit"

test_case_5: "Reusable workflow file exists locally"
  description: Verify .github/workflows/reusable-agent.yml exists and has `workflow_call` trigger.
  command: grep -q "workflow_call" .github/workflows/reusable-agent.yml

test_case_6: "Required input 'task' is forwarded"
  description: Verify agent.yml passes inputs.task to the reusable workflow.
  method: Parse YAML, check `jobs.agent.with.task` references `inputs.task`

test_case_7: "Model fallback chain is correct"
  description: Verify model expression uses the 3-tier fallback: inputs.model || vars.AI_MODEL || ''
  method: Regex match on the model expression in the with: block

test_case_8: "All mapped secrets use correct repo secret names"
  description: Verify secret references use UPPER_SNAKE_CASE names (ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, SLACK_WEBHOOK_URL, SENTRY_TOKEN, DD_API_KEY).
  method: Parse YAML, validate secrets block references match expected names.

test_case_9: "Permissions are appropriate for AI agent"
  description: Verify permissions include at minimum: contents: write, issues: write, pull-requests: write.
  method: Parse YAML, check permissions block.

test_case_10: "Concurrency group includes inputs.task"
  description: Verify the concurrency group string includes the task input for logical grouping.
  method: Regex match on concurrency.group expression.

test_case_11: "No hardcoded secrets or API keys"
  description: Scan the file for patterns matching API keys, tokens, or passwords.
  command: grep -iE '(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|xoxb-)' .github/workflows/agent.yml
  expected: no matches

test_case_12: "Reusable workflow inputs match expected schema"
  description: Verify the reusable workflow declares all inputs that agent.yml passes (task, prompt, prompt-path, model, runner).
  method: Cross-reference agent.yml with: block keys against reusable-agent.yml inputs: block.
```

## Summary

| Category | Count |
|----------|-------|
| PASS | 7 |
| WARN | 1 |
| FAIL | 0 |
| Issues (MEDIUM) | 1 |
| Issues (LOW) | 3 |
| Issues (INFO) | 1 |

The workflow is well-structured and functionally correct. The only actionable issue is the concurrency group configuration (Issue #1), which provides no actual deduplication due to including `github.run_id`. All other findings are minor or informational.

---
title: Issue Workflow Redesign
description: Design for consolidating issue automation into deterministic ingest, context enrichment, agent planning, and guarded execution.
---

# Issue Workflow Redesign

## Purpose

The issue workflow should behave as a single agent-driven control plane for all issue-related events. The current design routes each event type into separate jobs such as auto-label, duplicate detection, AI triage, slash commands, Linear branching, Sentry triage, and stale handling. That shape works, but it makes OpenCI responsible for too many partial business workflows.

The redesigned workflow consolidates issue handling into one pipeline:

```text
on-issue.yml
  -> issue.yml
     -> Stage 1: Ingest
     -> Stage 2: Enrich
     -> Stage 3: Agent Plan
     -> Stage 4: Guarded Execute
```

The core rule is simple: deterministic issue management runs before the agent, uncertain business decisions go to the agent, and all mutations are executed by a guarded allowlisted executor.

## Goals

- Route all issue-related events through one reusable workflow.
- Replace custom slash-command handling with agent interpretation of comments and issue context.
- Prefer mature community actions for deterministic issue management.
- Pass normalized issue, repository, shared agent workspace, issue-specific workspace, MCP, and external-tracker context to one agent step.
- Keep the agent read/plan-only; execute mutations in a separate policy-checked stage.
- Leave an audit trail for every agent-driven mutation.

## Non-Goals

- The workflow will not maintain a custom command DSL such as `/assign`, `/label`, or `/priority`.
- The agent will not receive unrestricted write access to GitHub.
- Stale processing will not require LLM judgment by default.
- OpenCI will not encode repository-specific triage policy directly in workflow YAML; consumers provide agent workspace files under `.github/agent/`.

## Architecture

### Entry Workflow

`.github/workflows/on-issue.yml` remains a thin event entrypoint. It listens to issue-domain events and calls `.github/workflows/issue.yml`.

Supported events:

- `issues`: `opened`, `edited`, `reopened`, `closed`
- `issue_comment`: `created`
- `schedule`: maintenance cadence
- `repository_dispatch`: external issue sources such as Linear or Sentry
- `workflow_dispatch`: manual reruns and maintenance operations

The entrypoint should not contain business logic. Its job is to normalize event access, pass `mode` when needed, and inherit secrets.

### Reusable Workflow

`.github/workflows/issue.yml` becomes the only public issue-domain reusable. Instead of exposing many modes such as `auto-label`, `dedupe`, `ai-triage`, `command`, and `linear-branch`, it exposes a smaller contract:

| Mode | Purpose |
| --- | --- |
| `lifecycle` | Main issue and comment processing pipeline. |
| `maintenance` | Deterministic stale, lock, and cleanup work. |
| `ingest` | External tracker or observability events entering the issue pipeline. |

Default event routing should choose the mode automatically. Consumers can use `workflow_dispatch` or `workflow_call` to force a mode for debugging or integration.

## Stage 1: Ingest

Stage 1 performs deterministic issue-management work. It should use mature GitHub Actions or small normalization wrappers, not agent judgment.

Responsibilities:

- Parse GitHub Issue Forms into structured JSON.
- Apply basic form-driven labels such as `type:*`, `area:*`, and `severity:*`.
- Collect duplicate candidates without automatically closing the issue.
- Run first-interaction or welcome behavior when configured.
- Run stale/lock behavior for scheduled maintenance.
- Emit a normalized `ingest.json` payload for later stages.

Recommended action choices:

- Use an issue-form parser such as `zentered/issue-forms-body-parser` or `stefanbuck/github-issue-parser` for structured issue data.
- Use an issue-focused labeler such as `github/issue-labeler` or `redhat-plumbers-in-action/advanced-issue-labeler` for issue labels.
- Use `actions/stale` for stale and close behavior.
- Avoid `actions/labeler` as the issue labeler. It is primarily a pull request labeler based on changed files and branches.

Example output:

```json
{
  "event": {
    "name": "issues",
    "action": "opened"
  },
  "issue": {
    "number": 42,
    "title": "bug: deployment check fails",
    "body": "...",
    "labels": ["type:bug"]
  },
  "form": {
    "area": "ci",
    "severity": "high"
  },
  "management": {
    "labels_applied": ["type:bug", "area:ci", "severity:high"],
    "duplicate_candidates": [],
    "stale_action": null
  }
}
```

## Stage 2: Enrich

Stage 2 collects context for the agent. It must not mutate issues.

Inputs:

- Stage 1 `ingest.json`
- shared agent instructions from `.github/agent/shared/context/AGENTS.md`
- issue-specific instructions from `.github/agent/issue/context/AGENTS.md`
- shared skills from `.github/agent/shared/skills/*.md`
- issue-specific skills from `.github/agent/issue/skills/*.md`
- `CODEOWNERS`
- recent issue comments
- related issues and PRs
- external tracker context such as Linear
- observability context such as Sentry
- MCP task registry when configured
- environment-variable allowlist and secret availability metadata

The output is a merged `agent-context.json`. The merge order is deterministic:

1. Shared context and shared skills.
2. Issue-specific context and issue-specific skills.
3. Runtime event data, repository data, external context, MCP task metadata, and environment metadata.

Issue-specific files may narrow or extend shared behavior, but they should not silently override executor safety policy. Conflicts are recorded in the enriched payload so the agent and executor can choose `escalate` when the contract is ambiguous.

Cross-job transfer must use artifacts or compact job outputs. A raw path such as `/tmp/agent-context.json` is not valid across GitHub Actions jobs because each job runs in a separate environment.

Recommended files:

```text
.github/
  agent/
    shared/
      context/
        AGENTS.md
      skills/
        escalate.md
        add-comment.md
        notify.md

    issue/
      context/
        AGENTS.md
      mcp-tasks.json
      skills/
        add-label.md
        assign-issue.md
        duplicate.md
        branch-create.md
        linear-sync.md
        mcp-task.md
        schedule-followup.md
```

Each `context/` directory has exactly one context entrypoint named `AGENTS.md`. This mirrors starting a dedicated Claude CLI-style agent session: the workflow provides the agent with its instructions, available tools, memory-like context, MCP task registry, and allowed environment metadata as one prepared workspace instead of scattering policy across unrelated Markdown files.

The Enrich job should materialize the merged workspace explicitly, either as a JSON payload or as an artifact directory:

```text
agent-workspace/
  context/
    shared/AGENTS.md
    issue/AGENTS.md
  skills/
    shared/*.md
    issue/*.md
  runtime/
    ingest.json
    related-issues.json
    comments.json
    external-context.json
    mcp-tasks.json
    env-metadata.json
```

The agent receives this merged workspace as if it were a dedicated issue-management agent environment. Shared files define behavior available to every agent domain. Issue files define the issue agent's local behavior, tools, memory, MCP tasks, and environment contract.

## Stage 3: Agent Plan

Stage 3 is the only intelligent decision point. The agent receives the enriched context and returns a structured action plan. It does not directly mutate GitHub state.

The agent should be prompted as an issue lifecycle operator with access to the merged shared and issue-specific workspace. If the context is ambiguous, it should choose `escalate` rather than guess.

Required output schema:

```json
{
  "version": "issue-action-plan/v1",
  "reasoning": "Short explanation of the decision.",
  "actions": [
    {
      "id": "a1",
      "skill": "add_label",
      "params": {
        "labels": ["priority:p2"]
      },
      "risk": "low"
    }
  ],
  "skip_reason": null
}
```

Allowed skills:

| Skill | Purpose |
| --- | --- |
| `add_label` | Add one or more labels. |
| `remove_label` | Remove one or more labels. |
| `set_priority` | Normalize priority labels. |
| `assign_issue` | Assign maintainers or teams. |
| `add_comment` | Post a maintainer-facing or user-facing comment. |
| `close_issue` | Close with a reason. |
| `reopen_issue` | Reopen with a reason. |
| `mark_duplicate` | Mark and comment with a duplicate reference. |
| `create_branch` | Create an associated development branch. |
| `link_linear` | Sync issue state or links to Linear through the guarded executor. |
| `dispatch_mcp_task` | Start an allowed MCP-backed downstream task through repository dispatch. |
| `schedule_followup` | Schedule a deterministic follow-up marker and maintenance reminder. |
| `notify` | Send a configured webhook notification. |
| `escalate` | Mark for human review. |

## Stage 4: Guarded Execute

Stage 4 validates and executes the agent plan. This stage owns all write permissions.

Validation requirements:

- Validate the plan against the `issue-action-plan/v1` schema.
- Reject unknown skills.
- Reject parameters that do not match the skill schema.
- Enforce actor and event policies.
- Enforce idempotency using a stable plan hash.
- Redact secrets and sensitive values before comments.
- Produce a durable audit comment or step summary.

Policy examples:

- Comments from outside collaborators cannot trigger `close_issue`, `reopen_issue`, `create_branch`, or `dispatch_mcp_task`.
- Security issues must not receive public comments that repeat vulnerability details.
- `mark_duplicate` requires a concrete `duplicate_of` issue number.
- `create_branch` must derive a deterministic branch name and skip if it already exists.
- `dispatch_mcp_task` must reference a task declared in merged `runtime/mcp-tasks.json`.
- `link_linear` requires `linear-token` and writes a Linear comment through GraphQL.
- `schedule_followup` writes an issue marker and is fulfilled by maintenance scanning.
- `escalate` always adds a human-review label and may notify configured channels.

Audit comment format:

```md
<!-- openci-agent-run: <run_id>:<plan_hash> -->
OpenCI issue agent executed:

- add_label: priority:p2
- add_comment: requested reproduction details

Reasoning:
<short reasoning>
```

The executor should skip duplicate execution when the same `plan_hash` has already been recorded on the issue.

## Event Behavior

| Event | Behavior |
| --- | --- |
| `issues.opened` | Run the full lifecycle pipeline. |
| `issues.edited` | Rebuild context and run agent, but rely on idempotency to avoid repeated comments or duplicate branches. |
| `issues.reopened` | Run the full lifecycle pipeline with reopen context. |
| `issues.closed` | Enrich and optionally let the agent sync external trackers; no default mutation. |
| `issue_comment.created` | Do not parse custom slash commands. Treat the comment as context, then let the agent plan within executor policy. |
| `schedule` | Run deterministic maintenance. Stale and lock should not require agent judgment by default. |
| `repository_dispatch` | Convert external events into issue context, enrich with tracker data, then let the agent plan allowed actions. |
| `workflow_dispatch` | Manually rerun `lifecycle`, `maintenance`, or `ingest`. |

## Mapping From Current Design

| Current flow | New location |
| --- | --- |
| `auto-label` | Stage 1 issue-form parser and issue labeler. |
| `detect-duplicates` | Stage 1 duplicate candidate collection. |
| `ai-triage` | Stage 3 agent planning. |
| `auto-assign` | Stage 4 executor action from agent plan. |
| `parse-command` / `execute-command` | Removed. Comments are interpreted by the agent. |
| `linear-branch` | Stage 4 `create_branch` and `link_linear` skills. |
| `sentry-triage` | Stage 2 external context or Stage 1 ingest source, then agent planning. |
| `stale` / `lock-resolved` | Stage 1 maintenance mode. |
| `welcome-contributor` | Stage 1 deterministic interaction or Stage 4 agent comment, depending on configuration. |

## Files To Add Or Change

Add:

```text
.github/agent/shared/context/AGENTS.md
.github/agent/shared/skills/escalate.md
.github/agent/shared/skills/add-comment.md
.github/agent/shared/skills/notify.md
.github/agent/issue/context/AGENTS.md
.github/agent/issue/skills/add-label.md
.github/agent/issue/skills/assign-issue.md
.github/agent/issue/skills/duplicate.md
.github/agent/issue/skills/branch-create.md
.github/agent/issue/skills/linear-sync.md
.github/agent/issue/skills/mcp-task.md
```

Rewrite:

```text
.github/workflows/on-issue.yml
.github/workflows/issue.yml
docs/SPEC.md
README.md
manifest.yml
```

Remove:

```text
actions/issue/parse-command/
actions/issue/execute-command/
```

Deprecate or fold into the new stages:

```text
actions/issue/ai-triage/
actions/issue/auto-assign/
actions/issue/detect-duplicates/
actions/issue/auto-label/
actions/_common/error-triage/
```

## Security Model

The security boundary is between planning and execution.

The agent receives repository and issue context, then returns intent. It should not hold broad write permissions and should not directly call GitHub mutation APIs. The executor owns `issues: write`, `contents: write`, and external tracker tokens only when a validated plan requires them.

The executor policy is part of the repository contract and is loaded into the merged agent context through `AGENTS.md`. Consumers can tighten it without changing the reusable workflow. OpenCI should provide conservative defaults that prefer `escalate` over risky mutation.

## Validation Plan

Minimum tests:

- `issues.opened` with a valid bug form creates normalized context and an agent plan.
- Missing form fields are captured in `ingest.json` and can lead to `needs-info`.
- Duplicate candidates are passed to the agent without automatic closure.
- A contributor comment is interpreted by the agent but blocked from high-risk execution.
- A maintainer comment can trigger allowed actions through the same agent path.
- Re-running the same event does not duplicate audit comments or branches.
- Security-like content produces labels/escalation without public sensitive detail.
- Scheduled maintenance runs stale/lock without invoking the agent by default.
- Linear or Sentry dispatch events are converted into enriched context.
- Unknown agent skills are rejected by the executor.

## Migration Sequence

1. Add shared and issue-specific agent workspaces under `.github/agent/`.
2. Introduce Stage 1 and Stage 2 wrappers while keeping existing atom actions available.
3. Replace `ai-triage` with the Stage 3 agent plan contract.
4. Add the Stage 4 executor with schema validation, allowlist, and audit comments.
5. Remove slash-command jobs and custom command actions.
6. Fold duplicate detection, assignment, Linear, and Sentry behavior into the new staged pipeline.
7. Update README, SPEC, manifest, and tests to document the new public contract.

## References

- [`github/issue-labeler`](https://github.com/github/issue-labeler) is issue-focused and supports issue body/title regex labeling.
- [`redhat-plumbers-in-action/advanced-issue-labeler`](https://github.com/marketplace/actions/advanced-issue-labeler) supports GitHub Issue Forms when paired with an issue parser.
- [`zentered/issue-forms-body-parser`](https://github.com/marketplace/actions/github-issue-forms-body-parser) parses GitHub Issue Forms into structured data.
- [`actions/stale`](https://github.com/actions/stale) supports issue and pull request stale/close management and should be pinned in the manifest.
- [`actions/labeler`](https://github.com/actions/labeler) is primarily a pull request labeler and should not be the issue form labeler.

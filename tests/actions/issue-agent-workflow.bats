#!/usr/bin/env bats
# Structural tests for the issue agent orchestrator workflow.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOW="${PROJECT_ROOT}/.github/workflows/issue.yml"
  ENTRY="${PROJECT_ROOT}/.github/workflows/on-issue.yml"
}

@test "issue workflow exposes the three consolidated modes" {
  grep -q 'lifecycle | maintenance | ingest' "$WORKFLOW"
  grep -q 'mode: lifecycle' "$ENTRY"
  grep -q 'mode: ingest' "$ENTRY"
  grep -q 'mode: maintenance' "$ENTRY"
}

@test "issue workflow uses four staged jobs" {
  grep -q 'Stage 1 · Ingest' "$WORKFLOW"
  grep -q 'Stage 2 · Enrich' "$WORKFLOW"
  grep -q 'Stage 3 · Agent Plan' "$WORKFLOW"
  grep -q 'Stage 4 · Guarded Execute' "$WORKFLOW"
}

@test "issue workflow no longer references custom slash-command actions" {
  run grep -E 'parse-command|execute-command|slash-command' "$WORKFLOW"
  [ "$status" -eq 1 ]
}

@test "issue workflow uses mature issue management actions in ingest and maintenance" {
  grep -q 'stefanbuck/github-issue-parser@[0-9a-f]\{40\}' "$WORKFLOW"
  grep -q 'redhat-plumbers-in-action/advanced-issue-labeler@[0-9a-f]\{40\}' "$WORKFLOW"
  grep -q 'actions/stale@[0-9a-f]\{40\}' "$WORKFLOW"
}

@test "issue workflow builds merged shared and issue agent workspace" {
  grep -q '.github/agent/shared/context/AGENTS.md' "$WORKFLOW"
  grep -q '.github/agent/issue/context/AGENTS.md' "$WORKFLOW"
  grep -q 'agent-workspace/agent-context.json' "$WORKFLOW"
}

@test "guarded executor validates issue-action-plan version and allowlist" {
  grep -q "issue-action-plan/v1" "$WORKFLOW"
  grep -q "Unknown issue agent skill" "$WORKFLOW"
  grep -q "openci-agent-run" "$WORKFLOW"
}

@test "guarded executor implements external issue skills" {
  grep -q "https://api.linear.app/graphql" "$WORKFLOW"
  grep -q "openci-mcp-task" "$WORKFLOW"
  grep -q "openci-followup" "$WORKFLOW"
  grep -q "NOTIFY_WEBHOOK_URL" "$WORKFLOW"
}

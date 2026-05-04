#!/usr/bin/env bats
# Structural tests for the issue agent orchestrator workflow.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-issue.yml"
  ENTRY="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  BUILD_WORKSPACE="${PROJECT_ROOT}/actions/issue/build-workspace/build-workspace.sh"
  EXECUTE_JS="${PROJECT_ROOT}/actions/issue/execute-plan/execute.js"
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
  grep -q '.github/agent/shared/context/AGENTS.md' "$BUILD_WORKSPACE"
  grep -q '.github/agent/issue/context/AGENTS.md' "$BUILD_WORKSPACE"
  grep -q 'agent-workspace/agent-context.json' "$BUILD_WORKSPACE"
}

@test "guarded executor validates issue-action-plan version and allowlist" {
  grep -q "issue-action-plan/v1" "$EXECUTE_JS"
  grep -q "Unknown issue agent skill" "$EXECUTE_JS"
  grep -q "openci-agent-run" "$EXECUTE_JS"
}

@test "guarded executor implements external issue skills" {
  grep -q "https://api.linear.app/graphql" "$EXECUTE_JS"
  grep -q "openci-mcp-task" "$EXECUTE_JS"
  grep -q "openci-followup" "$EXECUTE_JS"
  grep -q "NOTIFY_WEBHOOK_URL" "$EXECUTE_JS"
}

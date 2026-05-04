#!/usr/bin/env bats
# Structural tests for pull-request.yml event routing logic.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENTRY="${PROJECT_ROOT}/.github/workflows/pull-request.yml"
}

# ---------------------------------------------------------------------------
# Trigger declarations
# ---------------------------------------------------------------------------

@test "on-pr declares pull_request trigger" {
  grep -q 'pull_request:' "$ENTRY"
}

@test "pull_request trigger includes opened type" {
  grep -A1 'pull_request:' "$ENTRY" | grep -q 'opened'
}

@test "pull_request trigger includes synchronize type" {
  grep -A1 'pull_request:' "$ENTRY" | grep -q 'synchronize'
}

@test "pull_request trigger includes reopened type" {
  grep -A1 'pull_request:' "$ENTRY" | grep -q 'reopened'
}

@test "pull_request trigger includes ready_for_review type" {
  grep -A1 'pull_request:' "$ENTRY" | grep -q 'ready_for_review'
}

@test "on-pr declares workflow_dispatch trigger" {
  grep -q 'workflow_dispatch:' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Job configuration
# ---------------------------------------------------------------------------

@test "single checks job calls reusable pr.yml workflow" {
  grep -q 'uses: YiAgent/OpenCI/.github/workflows/reusable/pr\.yml' "$ENTRY"
}

@test "checks job enables AI review" {
  grep -q 'enable-ai-review: true' "$ENTRY"
}

@test "checks job enables eval" {
  grep -q 'enable-eval:.*true' "$ENTRY"
}

@test "checks job specifies runner" {
  grep -q 'runner:.*blacksmith-2vcpu-ubuntu-2404' "$ENTRY"
}

@test "checks job passes anthropic-api-key secret" {
  grep -q 'anthropic-api-key:' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

@test "concurrency group includes PR number" {
  grep -q 'github.event.pull_request.number' "$ENTRY"
}

@test "concurrency group falls back to run_id" {
  grep -q 'github.run_id' "$ENTRY"
}

@test "cancel-in-progress is false" {
  grep -q 'cancel-in-progress: false' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

@test "workflow requests contents: read permission" {
  grep -q 'contents: read' "$ENTRY"
}

@test "workflow requests actions: read permission" {
  grep -q 'actions: read' "$ENTRY"
}

@test "workflow requests checks: write permission" {
  grep -q 'checks: write' "$ENTRY"
}

@test "workflow requests issues: write permission" {
  grep -q 'issues: write' "$ENTRY"
}

@test "workflow requests pull-requests: write permission" {
  grep -q 'pull-requests: write' "$ENTRY"
}

@test "workflow requests security-events: write permission" {
  grep -q 'security-events: write' "$ENTRY"
}

@test "workflow requests id-token: write permission" {
  grep -q 'id-token: write' "$ENTRY"
}

@test "workflow requests statuses: write permission" {
  grep -q 'statuses: write' "$ENTRY"
}

@test "workflow requests packages: read permission" {
  grep -q 'packages: read' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Negative checks
# ---------------------------------------------------------------------------

@test "on-pr does not declare schedule trigger" {
  run grep -q 'schedule:' "$ENTRY"
  [ "$status" -eq 1 ]
}

@test "on-pr does not declare repository_dispatch trigger" {
  run grep -q 'repository_dispatch:' "$ENTRY"
  [ "$status" -eq 1 ]
}

@test "on-pr does not declare issues trigger" {
  # Extract the on: block (before permissions:) and check for issues: trigger
  run bash -c "sed -n '/^on:/,/^permissions:/p' '$ENTRY' | grep -q 'issues:'"
  [ "$status" -eq 1 ]
}

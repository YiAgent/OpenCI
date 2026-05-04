#!/usr/bin/env bats
# Structural tests for issue-ops.yml event routing logic.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENTRY="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
}

# ---------------------------------------------------------------------------
# Trigger declarations
# ---------------------------------------------------------------------------

@test "on-issue declares issues trigger with opened, reopened, edited, closed types" {
  grep -q 'issues:' "$ENTRY"
  grep -q 'opened' "$ENTRY"
  grep -q 'reopened' "$ENTRY"
  grep -q 'edited' "$ENTRY"
  grep -q 'closed' "$ENTRY"
}

@test "on-issue declares issue_comment trigger with created type" {
  grep -q 'issue_comment:' "$ENTRY"
  grep -A1 'issue_comment:' "$ENTRY" | grep -q 'created'
}

@test "on-issue declares schedule trigger with daily cron" {
  grep -q 'schedule:' "$ENTRY"
  grep -q '0 2 \* \* \*' "$ENTRY"
}

@test "on-issue declares repository_dispatch with linear-issue-started and sentry-issue types" {
  grep -q 'repository_dispatch:' "$ENTRY"
  grep -q 'linear-issue-started' "$ENTRY"
  grep -q 'sentry-issue' "$ENTRY"
}

@test "on-issue declares workflow_dispatch with mode choice input" {
  grep -q 'workflow_dispatch:' "$ENTRY"
  grep -q 'mode:' "$ENTRY"
  grep -q 'type: choice' "$ENTRY"
  grep -q 'default: lifecycle' "$ENTRY"
}

@test "on-issue workflow_dispatch mode options include lifecycle, maintenance, ingest" {
  grep -q 'options: \[lifecycle, maintenance, ingest\]' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Job conditional routing
# ---------------------------------------------------------------------------

@test "lifecycle job runs on issues and issue_comment events" {
  grep -q "github.event_name == 'issues'" "$ENTRY"
  grep -q "github.event_name == 'issue_comment'" "$ENTRY"
}

@test "ingest job runs on repository_dispatch event" {
  grep -q "github.event_name == 'repository_dispatch'" "$ENTRY"
}

@test "maintenance job runs on schedule and workflow_dispatch with maintenance mode" {
  grep -q "github.event_name == 'schedule'" "$ENTRY"
  grep -q "inputs.mode == 'maintenance'" "$ENTRY"
}

@test "manual job runs on workflow_dispatch when mode is not maintenance" {
  grep -q "github.event_name == 'workflow_dispatch'" "$ENTRY"
  grep -q "inputs.mode != 'maintenance'" "$ENTRY"
}

# ---------------------------------------------------------------------------
# Job mode parameters
# ---------------------------------------------------------------------------

@test "lifecycle job passes mode: lifecycle" {
  grep -A2 'lifecycle:' "$ENTRY" | grep -q 'if:'
  grep -q 'mode: lifecycle' "$ENTRY"
}

@test "ingest job passes mode: ingest" {
  grep -q 'mode: ingest' "$ENTRY"
}

@test "maintenance job passes mode: maintenance" {
  grep -q 'mode: maintenance' "$ENTRY"
}

@test "manual job passes the dispatch input mode dynamically" {
  # shellcheck disable=SC2016  # \$ is for grep BRE, not shell expansion
  grep -q 'mode: \${{ inputs.mode }}' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Reusable workflow reference
# ---------------------------------------------------------------------------

@test "all four jobs call the same reusable workflow issue.yml" {
  local count
  count=$(grep -c 'uses: YiAgent/OpenCI/.github/workflows/reusable-issue\.yml' "$ENTRY")
  [ "$count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

@test "concurrency group includes issue number for issue events" {
  grep -q 'github.event.issue.number' "$ENTRY"
}

@test "concurrency group includes client_payload id for repository_dispatch" {
  grep -q 'github.event.client_payload.id' "$ENTRY"
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

@test "workflow requests contents: write permission" {
  grep -q 'contents: write' "$ENTRY"
}

@test "workflow requests issues: write permission" {
  grep -q 'issues: write' "$ENTRY"
}

@test "workflow requests pull-requests: write permission" {
  grep -q 'pull-requests: write' "$ENTRY"
}

@test "workflow requests id-token: write permission" {
  grep -q 'id-token: write' "$ENTRY"
}

@test "workflow requests actions: read permission" {
  grep -q 'actions: read' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Secrets propagation
# ---------------------------------------------------------------------------

@test "all jobs pass anthropic-api-key secret" {
  local count
  count=$(grep -c 'anthropic-api-key:' "$ENTRY")
  [ "$count" -eq 4 ]
}

@test "all jobs pass api-base-url secret" {
  local count
  count=$(grep -c 'api-base-url:' "$ENTRY")
  [ "$count" -eq 4 ]
}

@test "all jobs pass sentry-token secret" {
  local count
  count=$(grep -c 'sentry-token:' "$ENTRY")
  [ "$count" -eq 4 ]
}

@test "all jobs pass linear-token secret" {
  local count
  count=$(grep -c 'linear-token:' "$ENTRY")
  [ "$count" -eq 4 ]
}

@test "all jobs pass slack-webhook-url secret" {
  local count
  count=$(grep -c 'slack-webhook-url:' "$ENTRY")
  [ "$count" -eq 4 ]
}

@test "all jobs pass mcp-dispatch-token secret" {
  local count
  count=$(grep -c 'mcp-dispatch-token:' "$ENTRY")
  [ "$count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

@test "all jobs specify the same runner" {
  local count
  count=$(grep -c 'runner: blacksmith-2vcpu-ubuntu-2404' "$ENTRY")
  [ "$count" -eq 4 ]
}

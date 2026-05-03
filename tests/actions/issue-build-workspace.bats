#!/usr/bin/env bats
# Tests for actions/issue/build-workspace/build-workspace.sh
#
# The script assembles the merged agent workspace from OpenCI defaults
# and caller overrides. It expects to run from the repo root and reads:
#   ISSUE_NUMBER, REPO, HAS_LINEAR_TOKEN, HAS_SENTRY_TOKEN
#
# Since it calls `gh` (GitHub CLI) and `jq`, we mock `gh` on PATH and
# rely on a real `jq` being installed.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/build-workspace/build-workspace.sh"
  WORK_DIR="$(mktemp -d)"

  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"

  # All script operations happen relative to cwd, so we work inside WORK_DIR.
  cd "$WORK_DIR"

  # Create mock gh that returns valid JSON for view and list subcommands.
  mkdir -p "$WORK_DIR/bin"
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "$1" in
  issue)
    case "$2" in
      view)
        echo '{"comments":[],"labels":[{"name":"bug"}],"assignees":[],"state":"open","url":"https://github.com/test/repo/issues/42","title":"Test issue","body":"Hello"}'
        ;;
      list)
        echo '[{"number":42,"title":"Test issue","state":"open","labels":[{"name":"bug"}],"url":"https://github.com/test/repo/issues/42"}]'
        ;;
      *)
        echo '{}'
        ;;
    esac
    ;;
  *)
    echo '{}'
    ;;
esac
MOCK
  chmod +x "$WORK_DIR/bin/gh"
  export PATH="$WORK_DIR/bin:$PATH"

  # Default env vars
  export REPO="test/repo"
  export ISSUE_NUMBER="42"
  export HAS_LINEAR_TOKEN="false"
  export HAS_SENTRY_TOKEN="false"
}

teardown() {
  rm -rf "$WORK_DIR"
  rm -f "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------------------
# Helper: create the pre-existing ingest.json that the script expects
# to find at agent-workspace/runtime/ingest.json (written by upstream stages).
# ---------------------------------------------------------------------------
seed_ingest() {
  mkdir -p "$WORK_DIR/agent-workspace/runtime"
  echo '{"issue":{"number":42,"title":"Test issue","body":"Hello"}}' \
    > "$WORK_DIR/agent-workspace/runtime/ingest.json"
}

# ---------------------------------------------------------------------------
# Helper: run the script from $WORK_DIR, seeding ingest.json first.
# ---------------------------------------------------------------------------
run_build() {
  seed_ingest
  cd "$WORK_DIR"
  run bash "$SCRIPT"
}

# ===========================================================================
# 1. Directory structure is created correctly
# ===========================================================================
@test "creates all five agent-workspace subdirectories" {
  run_build
  [ "$status" -eq 0 ]
  [ -d "$WORK_DIR/agent-workspace/context/shared" ]
  [ -d "$WORK_DIR/agent-workspace/context/issue" ]
  [ -d "$WORK_DIR/agent-workspace/skills/shared" ]
  [ -d "$WORK_DIR/agent-workspace/skills/issue" ]
  [ -d "$WORK_DIR/agent-workspace/runtime" ]
}

# ===========================================================================
# 2. OpenCI default AGENTS.md is copied when present
# ===========================================================================
@test "copies OpenCI default shared AGENTS.md" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared/context"
  echo "# OpenCI Shared Agents" > "$WORK_DIR/.openci/.github/agent/shared/context/AGENTS.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/context/shared/AGENTS.md" ]
  grep -q "OpenCI Shared Agents" "$WORK_DIR/agent-workspace/context/shared/AGENTS.md"
}

@test "copies OpenCI default issue AGENTS.md" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/issue/context"
  echo "# OpenCI Issue Agents" > "$WORK_DIR/.openci/.github/agent/issue/context/AGENTS.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/context/issue/AGENTS.md" ]
  grep -q "OpenCI Issue Agents" "$WORK_DIR/agent-workspace/context/issue/AGENTS.md"
}

# ===========================================================================
# 3. Caller override AGENTS.md overwrites OpenCI default
# ===========================================================================
@test "caller .github AGENTS.md overwrites OpenCI default for shared context" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared/context"
  echo "# OpenCI Default" > "$WORK_DIR/.openci/.github/agent/shared/context/AGENTS.md"
  mkdir -p "$WORK_DIR/.github/agent/shared/context"
  echo "# Caller Override" > "$WORK_DIR/.github/agent/shared/context/AGENTS.md"

  run_build
  [ "$status" -eq 0 ]
  grep -q "Caller Override" "$WORK_DIR/agent-workspace/context/shared/AGENTS.md"
  ! grep -q "OpenCI Default" "$WORK_DIR/agent-workspace/context/shared/AGENTS.md"
}

@test "caller .github AGENTS.md overwrites OpenCI default for issue context" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/issue/context"
  echo "# OpenCI Issue Default" > "$WORK_DIR/.openci/.github/agent/issue/context/AGENTS.md"
  mkdir -p "$WORK_DIR/.github/agent/issue/context"
  echo "# Caller Issue Override" > "$WORK_DIR/.github/agent/issue/context/AGENTS.md"

  run_build
  [ "$status" -eq 0 ]
  grep -q "Caller Issue Override" "$WORK_DIR/agent-workspace/context/issue/AGENTS.md"
  ! grep -q "OpenCI Issue Default" "$WORK_DIR/agent-workspace/context/issue/AGENTS.md"
}

@test "no AGENTS.md anywhere does not cause failure" {
  run_build
  [ "$status" -eq 0 ]
  [ ! -f "$WORK_DIR/agent-workspace/context/shared/AGENTS.md" ]
  [ ! -f "$WORK_DIR/agent-workspace/context/issue/AGENTS.md" ]
}

# ===========================================================================
# 4. Skill files are merged from both sources
# ===========================================================================
@test "copies OpenCI default shared skill files" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared/skills"
  echo "# Triage Skill" > "$WORK_DIR/.openci/.github/agent/shared/skills/triage.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/skills/shared/triage.md" ]
  grep -q "Triage Skill" "$WORK_DIR/agent-workspace/skills/shared/triage.md"
}

@test "copies OpenCI default issue skill files" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/issue/skills"
  echo "# Diagnose Skill" > "$WORK_DIR/.openci/.github/agent/issue/skills/diagnose.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/skills/issue/diagnose.md" ]
  grep -q "Diagnose Skill" "$WORK_DIR/agent-workspace/skills/issue/diagnose.md"
}

@test "caller .github skill files are also copied" {
  mkdir -p "$WORK_DIR/.github/agent/shared/skills"
  echo "# Custom Skill" > "$WORK_DIR/.github/agent/shared/skills/custom.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/skills/shared/custom.md" ]
  grep -q "Custom Skill" "$WORK_DIR/agent-workspace/skills/shared/custom.md"
}

@test "skill files from both OpenCI and caller coexist" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared/skills"
  echo "# Default Skill" > "$WORK_DIR/.openci/.github/agent/shared/skills/default.md"
  mkdir -p "$WORK_DIR/.github/agent/shared/skills"
  echo "# Caller Skill" > "$WORK_DIR/.github/agent/shared/skills/caller.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/skills/shared/default.md" ]
  [ -f "$WORK_DIR/agent-workspace/skills/shared/caller.md" ]
}

@test "missing skill directories do not cause failure" {
  run_build
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 5. CODEOWNERS is copied to runtime
# ===========================================================================
@test "CODEOWNERS is copied to runtime when present" {
  mkdir -p "$WORK_DIR/.github"
  echo "* @team-leads" > "$WORK_DIR/.github/CODEOWNERS"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/CODEOWNERS" ]
  grep -q "@team-leads" "$WORK_DIR/agent-workspace/runtime/CODEOWNERS"
}

@test "missing CODEOWNERS does not cause failure" {
  run_build
  [ "$status" -eq 0 ]
  [ ! -f "$WORK_DIR/agent-workspace/runtime/CODEOWNERS" ]
}

# ===========================================================================
# 6. .mcp.json is copied; falls back to empty mcpServers when missing
# ===========================================================================
@test ".mcp.json is copied to runtime/mcp-config.json" {
  echo '{"mcpServers":{"github":{"command":"gh"}}}' > "$WORK_DIR/.mcp.json"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-config.json" ]
  jq -e '.mcpServers.github' "$WORK_DIR/agent-workspace/runtime/mcp-config.json"
}

@test "missing .mcp.json falls back to empty mcpServers" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-config.json" ]
  jq -e '.mcpServers' "$WORK_DIR/agent-workspace/runtime/mcp-config.json"
  local count
  count="$(jq '.mcpServers | length' "$WORK_DIR/agent-workspace/runtime/mcp-config.json")"
  [ "$count" -eq 0 ]
}

# ===========================================================================
# 7. MCP tasks are merged with dedup
# ===========================================================================
@test "MCP tasks are merged from multiple sources with dedup by name" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared"
  mkdir -p "$WORK_DIR/.github/agent/shared"

  cat > "$WORK_DIR/.openci/.github/agent/shared/mcp-tasks.json" <<'EOF'
{"tasks":[{"name":"triage","description":"auto triage"},{"name":"label","description":"auto label"}]}
EOF
  cat > "$WORK_DIR/.github/agent/shared/mcp-tasks.json" <<'EOF'
{"tasks":[{"name":"triage","description":"overridden triage"},{"name":"notify","description":"send notification"}]}
EOF

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json" ]

  # triage appears once (caller wins due to merge order), label and notify both present
  local count
  count="$(jq '.tasks | length' "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json")"
  [ "$count" -eq 3 ]

  # unique_by keeps the first occurrence; the earliest source wins
  jq -e '.tasks[] | select(.name == "triage") | .description == "auto triage"' \
    "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json"
}

@test "mcp-tasks.json starts empty when no sources exist" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json" ]
  local count
  count="$(jq '.tasks | length' "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json")"
  [ "$count" -eq 0 ]
}

@test "MCP tasks from all four source paths are considered" {
  mkdir -p "$WORK_DIR/.openci/.github/agent/shared"
  mkdir -p "$WORK_DIR/.openci/.github/agent/issue"
  mkdir -p "$WORK_DIR/.github/agent/shared"
  mkdir -p "$WORK_DIR/.github/agent/issue"

  echo '{"tasks":[{"name":"a","description":"from openci shared"}]}' \
    > "$WORK_DIR/.openci/.github/agent/shared/mcp-tasks.json"
  echo '{"tasks":[{"name":"b","description":"from openci issue"}]}' \
    > "$WORK_DIR/.openci/.github/agent/issue/mcp-tasks.json"
  echo '{"tasks":[{"name":"c","description":"from github shared"}]}' \
    > "$WORK_DIR/.github/agent/shared/mcp-tasks.json"
  echo '{"tasks":[{"name":"d","description":"from github issue"}]}' \
    > "$WORK_DIR/.github/agent/issue/mcp-tasks.json"

  run_build
  [ "$status" -eq 0 ]
  local count
  count="$(jq '.tasks | length' "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json")"
  [ "$count" -eq 4 ]
}

# ===========================================================================
# 8. Live issue data is fetched when ISSUE_NUMBER is set
# ===========================================================================
@test "fetches live issue data when ISSUE_NUMBER is set" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/issue-live.json" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/related-issues.json" ]

  # The mock gh returns valid JSON with expected fields
  jq -e '.state' "$WORK_DIR/agent-workspace/runtime/issue-live.json"
  jq -e '.url' "$WORK_DIR/agent-workspace/runtime/issue-live.json"
}

@test "related issues is a JSON array when gh succeeds" {
  run_build
  [ "$status" -eq 0 ]
  local type
  type="$(jq -r 'type' "$WORK_DIR/agent-workspace/runtime/related-issues.json")"
  [ "$type" = "array" ]
}

# ===========================================================================
# 9. Falls back to {} / [] when gh fails
# ===========================================================================
@test "issue-live.json falls back to {} when gh issue view fails" {
  # Replace mock gh with one that always fails
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  run_build
  [ "$status" -eq 0 ]

  local content
  content="$(cat "$WORK_DIR/agent-workspace/runtime/issue-live.json")"
  [ "$content" = "{}" ]
}

@test "related-issues.json falls back to [] when gh issue list fails" {
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  run_build
  [ "$status" -eq 0 ]

  local content
  content="$(cat "$WORK_DIR/agent-workspace/runtime/related-issues.json")"
  [ "$content" = "[]" ]
}

# ===========================================================================
# 10. env-metadata.json reflects HAS_LINEAR_TOKEN and HAS_SENTRY_TOKEN
# ===========================================================================
@test "env-metadata.json reports both tokens as false by default" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/runtime/env-metadata.json" ]
  jq -e '.linear_token_available == false' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
  jq -e '.sentry_token_available == false' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
}

@test "env-metadata.json reports linear_token_available true when HAS_LINEAR_TOKEN=true" {
  export HAS_LINEAR_TOKEN="true"
  run_build
  [ "$status" -eq 0 ]
  jq -e '.linear_token_available == true' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
  jq -e '.sentry_token_available == false' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
}

@test "env-metadata.json reports sentry_token_available true when HAS_SENTRY_TOKEN=true" {
  export HAS_SENTRY_TOKEN="true"
  run_build
  [ "$status" -eq 0 ]
  jq -e '.linear_token_available == false' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
  jq -e '.sentry_token_available == true' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
}

@test "env-metadata.json reports both tokens true when both are set" {
  export HAS_LINEAR_TOKEN="true"
  export HAS_SENTRY_TOKEN="true"
  run_build
  [ "$status" -eq 0 ]
  jq -e '.linear_token_available == true' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
  jq -e '.sentry_token_available == true' "$WORK_DIR/agent-workspace/runtime/env-metadata.json"
}

# ===========================================================================
# 11. agent-context.json has correct structure
# ===========================================================================
@test "agent-context.json contains all required top-level keys" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/agent-context.json" ]
  jq -e '.ingest'              "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.live_issue'          "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.related_issues'      "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.env'                 "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.workspace_layout'    "$WORK_DIR/agent-workspace/agent-context.json"
}

@test "agent-context.json ingest matches seeded ingest.json" {
  run_build
  [ "$status" -eq 0 ]
  jq -e '.ingest.issue.number == 42' "$WORK_DIR/agent-workspace/agent-context.json"
}

@test "agent-context.json live_issue comes from gh mock" {
  run_build
  [ "$status" -eq 0 ]
  jq -e '.live_issue.state == "open"' "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.live_issue.url' "$WORK_DIR/agent-workspace/agent-context.json"
}

@test "agent-context.json related_issues is an array" {
  run_build
  [ "$status" -eq 0 ]
  local type
  type="$(jq -r '.related_issues | type' "$WORK_DIR/agent-workspace/agent-context.json")"
  [ "$type" = "array" ]
}

@test "agent-context.json env reflects token availability" {
  export HAS_LINEAR_TOKEN="true"
  run_build
  [ "$status" -eq 0 ]
  jq -e '.env.linear_token_available == true' "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.env.sentry_token_available == false' "$WORK_DIR/agent-workspace/agent-context.json"
}

@test "agent-context.json workspace_layout has expected paths" {
  run_build
  [ "$status" -eq 0 ]
  jq -e '.workspace_layout.context[0] == "context/shared/AGENTS.md"' \
    "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.workspace_layout.context[1] == "context/issue/AGENTS.md"' \
    "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.workspace_layout.mcp_tasks == "runtime/mcp-tasks.json"' \
    "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.workspace_layout.skills.shared' \
    "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.workspace_layout.skills.issue' \
    "$WORK_DIR/agent-workspace/agent-context.json"
}

# ===========================================================================
# 12. prompt.md contains expected instructions
# ===========================================================================
@test "prompt.md is created with agent instructions" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/prompt.md" ]
}

@test "prompt.md identifies as OpenCI issue agent" {
  run_build
  [ "$status" -eq 0 ]
  grep -q "OpenCI issue agent" "$WORK_DIR/agent-workspace/prompt.md"
}

@test "prompt.md lists required reading files" {
  run_build
  [ "$status" -eq 0 ]
  grep -q "context/shared/AGENTS.md" "$WORK_DIR/agent-workspace/prompt.md"
  grep -q "context/issue/AGENTS.md" "$WORK_DIR/agent-workspace/prompt.md"
  grep -q "agent-context.json" "$WORK_DIR/agent-workspace/prompt.md"
  grep -q "ingest.json" "$WORK_DIR/agent-workspace/prompt.md"
  grep -q "mcp-tasks.json" "$WORK_DIR/agent-workspace/prompt.md"
}

@test "prompt.md specifies issue-action-plan/v1 JSON output format" {
  run_build
  [ "$status" -eq 0 ]
  grep -q "issue-action-plan/v1" "$WORK_DIR/agent-workspace/prompt.md"
  grep -q '"actions"' "$WORK_DIR/agent-workspace/prompt.md"
  grep -q '"skip_reason"' "$WORK_DIR/agent-workspace/prompt.md"
}

@test "prompt.md instructs to use only workspace skills" {
  run_build
  [ "$status" -eq 0 ]
  grep -q "Only use skills present in agent-workspace/skills/" "$WORK_DIR/agent-workspace/prompt.md"
}

# ===========================================================================
# 13. Works when ISSUE_NUMBER is empty (skips gh calls)
# ===========================================================================
@test "skips gh calls and writes fallbacks when ISSUE_NUMBER is empty" {
  export ISSUE_NUMBER=""
  run_build
  [ "$status" -eq 0 ]

  local live related
  live="$(cat "$WORK_DIR/agent-workspace/runtime/issue-live.json")"
  related="$(cat "$WORK_DIR/agent-workspace/runtime/related-issues.json")"
  [ "$live" = "{}" ]
  [ "$related" = "[]" ]
}

@test "skips gh calls when ISSUE_NUMBER is unset" {
  unset ISSUE_NUMBER
  run_build
  [ "$status" -eq 0 ]

  local live related
  live="$(cat "$WORK_DIR/agent-workspace/runtime/issue-live.json")"
  related="$(cat "$WORK_DIR/agent-workspace/runtime/related-issues.json")"
  [ "$live" = "{}" ]
  [ "$related" = "[]" ]
}

@test "still produces valid agent-context.json when ISSUE_NUMBER is empty" {
  export ISSUE_NUMBER=""
  run_build
  [ "$status" -eq 0 ]
  jq -e '.live_issue' "$WORK_DIR/agent-workspace/agent-context.json"
  jq -e '.related_issues' "$WORK_DIR/agent-workspace/agent-context.json"
}

# ===========================================================================
# Edge cases
# ===========================================================================
@test "caller-only skills (no OpenCI defaults) work correctly" {
  mkdir -p "$WORK_DIR/.github/agent/issue/skills"
  echo "# Custom Issue Skill" > "$WORK_DIR/.github/agent/issue/skills/custom-issue.md"

  run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK_DIR/agent-workspace/skills/issue/custom-issue.md" ]
  grep -q "Custom Issue Skill" "$WORK_DIR/agent-workspace/skills/issue/custom-issue.md"
}

@test "mcp-config.json is valid JSON even with complex .mcp.json" {
  cat > "$WORK_DIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "github": {
      "command": "gh",
      "args": ["api"]
    },
    "linear": {
      "command": "npx",
      "args": ["-y", "@linear/mcp"]
    }
  }
}
EOF

  run_build
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.github.command == "gh"' "$WORK_DIR/agent-workspace/runtime/mcp-config.json"
  jq -e '.mcpServers.linear.command == "npx"' "$WORK_DIR/agent-workspace/runtime/mcp-config.json"
}

@test "script succeeds with completely empty repo (no sources at all)" {
  # Remove all optional source directories — just the bare cwd
  run_build
  [ "$status" -eq 0 ]
  [ -d "$WORK_DIR/agent-workspace/runtime" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-tasks.json" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/mcp-config.json" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/env-metadata.json" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/issue-live.json" ]
  [ -f "$WORK_DIR/agent-workspace/runtime/related-issues.json" ]
  [ -f "$WORK_DIR/agent-workspace/agent-context.json" ]
  [ -f "$WORK_DIR/agent-workspace/prompt.md" ]
}

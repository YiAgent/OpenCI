#!/usr/bin/env bats
# End-to-end integration test that simulates a downstream caller (EvolveCI)
# invoking the OpenCI claude-harness composite. We don't run claude-code-action
# itself — we drive the harness's two shell scripts (resolve-prompt.sh and
# compose-args.sh) with the same inputs the workflows would supply, and assert
# the resulting (prompt, claude_args, settings) trio is shaped correctly for
# claude-code-action@v1.x.
#
# Why this matters: action.yml is YAML glue. The "real work" of the harness —
# deciding what tools Claude gets, where the prompt comes from, what env vars
# survive into the bash context — happens in those two shell scripts. If they
# behave correctly together, the GitHub Actions composite will too.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HARNESS_DIR="${PROJECT_ROOT}/actions/_common/claude-harness"
  RESOLVE="${HARNESS_DIR}/resolve-prompt.sh"
  COMPOSE="${HARNESS_DIR}/compose-args.sh"

  WORK_DIR="$(mktemp -d)"
  export GITHUB_WORKSPACE="${WORK_DIR}"
  export GITHUB_REPOSITORY="YiAgent/EvolveCI"
  export GITHUB_RUN_ID="999999"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_EVENT_NAME="schedule"
  export GITHUB_REF="refs/heads/main"
  export GITHUB_SHA="0123456789abcdef"
  export GITHUB_ACTOR="github-actions[bot]"

  # Stage a fake EvolveCI checkout — the slash command files are what the
  # harness will resolve against (priority 1: /slash-command).
  mkdir -p "${WORK_DIR}/.claude/commands"
  printf '# /heartbeat\nCheck health of {{repo}} run {{run_url}}.\n' \
    > "${WORK_DIR}/.claude/commands/heartbeat.md"
  printf '# /triage\nTriage failures in {{repo}}. Run id={{run_id}}.\n' \
    > "${WORK_DIR}/.claude/commands/triage.md"
  printf '# /daily-report\n24h summary for {{repo}}.\n' \
    > "${WORK_DIR}/.claude/commands/daily-report.md"
  printf '# /weekly-report\nWeekly deep-dive for {{repo}}.\n' \
    > "${WORK_DIR}/.claude/commands/weekly-report.md"
}

teardown() {
  rm -rf "${WORK_DIR}"
  unset GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_EVENT_NAME \
        GITHUB_REF GITHUB_SHA GITHUB_ACTOR
  unset TASK MODEL MAX_TURNS SYSTEM_PROMPT EXTRA_ALLOWED_TOOLS EXTRA_DISALLOWED \
        MCP_CONFIG_INPUT SLACK_WEBHOOK API_BASE_URL EXTRA_ENV_JSON
}

# ── Helpers ──────────────────────────────────────────────────────────────────
out_kv() {
  local file="$1" key="$2"
  grep -m1 "^${key}=" "$file" | sed "s/^${key}=//"
}

out_multiline() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block=0 }
    !in_block && $0 ~ "^"k"<<" { delim=substr($0, length(k)+3); in_block=1; next }
    in_block && $0 == delim { exit }
    in_block { print }
  ' "$file"
}

# Simulates the full action.yml run: resolve-prompt.sh, then compose-args.sh,
# emitting both into a shared GITHUB_OUTPUT-style file.
simulate_call() {
  local task="$1" prompt_arg="$2" extra_tools="${3:-}" mcp="${4:-}" sys="${5:-}"
  local out
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$RESOLVE" "$task" "$prompt_arg" "" "$HARNESS_DIR" "{}" >/dev/null

  TASK="$task" \
  MODEL="claude-sonnet-4-5-20250929" \
  MAX_TURNS="20" \
  SYSTEM_PROMPT="$sys" \
  EXTRA_ALLOWED_TOOLS="$extra_tools" \
  EXTRA_DISALLOWED="" \
  MCP_CONFIG_INPUT="$mcp" \
  SLACK_WEBHOOK="https://hooks.slack.com/services/T/B/C" \
  API_BASE_URL="https://api.anthropic.com" \
  EXTRA_ENV_JSON="{}" \
  GITHUB_OUTPUT="$out" bash "$COMPOSE" >/dev/null
  echo "$out"
}

# ── EvolveCI workflow simulations ────────────────────────────────────────────

@test "heartbeat: resolves /heartbeat slash command + builds standard claude_args" {
  out="$(simulate_call heartbeat /heartbeat)"
  [ "$(out_kv "$out" prompt-source)" = "slash-command" ]
  body="$(out_multiline "$out" prompt)"
  [[ "$body" == *"Check health of YiAgent/EvolveCI"* ]]
  [[ "$body" == *"https://github.com/YiAgent/EvolveCI/actions/runs/999999"* ]]
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--model claude-sonnet-4-5-20250929"* ]]
  [[ "$args" == *"--max-turns 20"* ]]
  [[ "$args" == *"--allowedTools"* ]]
  [[ "$args" == *"Bash(jq)"* ]]
  [[ "$args" != *"--system-prompt"* ]]
  rm -f "$out"
}

@test "daily-report: settings.env carries SLACK_WEBHOOK_URL + ANTHROPIC_BASE_URL" {
  out="$(simulate_call daily-report /daily-report)"
  settings="$(out_kv "$out" settings)"
  echo "$settings" | jq -e '.env.SLACK_WEBHOOK_URL == "https://hooks.slack.com/services/T/B/C"' >/dev/null
  echo "$settings" | jq -e '.env.ANTHROPIC_BASE_URL == "https://api.anthropic.com"' >/dev/null
  rm -f "$out"
}

@test "weekly-report: prompt body is non-empty and contains rendered repo" {
  out="$(simulate_call weekly-report /weekly-report)"
  body="$(out_multiline "$out" prompt)"
  [[ "$body" == *"Weekly deep-dive for YiAgent/EvolveCI"* ]]
  rm -f "$out"
}

@test "triage: extra-allowed-tools is appended without losing baseline tools" {
  extras="Bash(bash lib/redact-log.sh),Bash(bash lib/),Bash(cut),Bash(tr)"
  out="$(simulate_call triage /triage "$extras")"
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"Read"* ]]
  [[ "$args" == *"Bash(bash lib/redact-log.sh)"* ]]
  [[ "$args" == *"Bash(bash lib/)"* ]]
  [[ "$args" == *"Bash(cut)"* ]]
  [[ "$args" == *"Bash(gh api)"* ]]
  [[ "$args" == *"mcp__github_ci__get_ci_status"* ]]
  rm -f "$out"
}

@test "system-prompt option is honoured by compose-args" {
  out="$(simulate_call triage /triage "" "" "You are EvolveCI's careful CI agent.")"
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--system-prompt 'You are EvolveCI's careful CI agent.'"* ]] \
    || [[ "$args" == *"--system-prompt 'You are EvolveCI'\\''s"* ]]
  rm -f "$out"
}

@test "inline mcp-config JSON propagates as --mcp-config flag" {
  cfg='{"mcpServers":{"linear":{"command":"npx","args":["-y","@linear/mcp"]}}}'
  out="$(simulate_call triage /triage "" "$cfg")"
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--mcp-config '"*"linear"* ]]
  rm -f "$out"
}

@test "slash command without backing file → resolve fails (visible to caller)" {
  run bash "$RESOLVE" heartbeat /missing-cmd "" "$HARNESS_DIR" "{}"
  [ "${status}" -eq 1 ]
}

@test "OpenCI built-in prompt fallback works for tasks with no slash command" {
  # Simulate a caller that supplies just `task: pr/review` and no prompt arg.
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$RESOLVE" "pr/review" "" "" "$HARNESS_DIR" '{"repo":"acme/web"}' >/dev/null
  [ "$(out_kv "$out" prompt-source)" = "builtin" ]
  body="$(out_multiline "$out" prompt)"
  [[ "$body" == *"acme/web repository"* ]]
  rm -f "$out"
}

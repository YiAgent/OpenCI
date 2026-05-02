#!/usr/bin/env bats
# Tests for compose-args.sh — produces claude_args + settings for claude-code-action.
#
# Reads from env: TASK, MODEL, MAX_TURNS, SYSTEM_PROMPT, EXTRA_ALLOWED_TOOLS,
#                 EXTRA_DISALLOWED, MCP_CONFIG_INPUT, SLACK_WEBHOOK,
#                 API_BASE_URL, EXTRA_ENV_JSON
# Writes to GITHUB_OUTPUT:
#   claude-args  (multi-line)
#   settings     (single line JSON)

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/claude-harness/compose-args.sh"
  WORK_DIR="$(mktemp -d)"
  export GITHUB_WORKSPACE="${WORK_DIR}"
  export TASK="some/task"
  export MODEL="claude-sonnet-4-5-20250929"
  export MAX_TURNS="10"
  export SYSTEM_PROMPT=""
  export EXTRA_ALLOWED_TOOLS=""
  export EXTRA_DISALLOWED=""
  export MCP_CONFIG_INPUT=""
  export SLACK_WEBHOOK=""
  export API_BASE_URL=""
  export EXTRA_ENV_JSON="{}"
  export AUTH_TOKEN_PASSTHROUGH=""
}

teardown() {
  rm -rf "${WORK_DIR}"
  unset TASK MODEL MAX_TURNS SYSTEM_PROMPT EXTRA_ALLOWED_TOOLS EXTRA_DISALLOWED \
        MCP_CONFIG_INPUT SLACK_WEBHOOK API_BASE_URL EXTRA_ENV_JSON \
        AUTH_TOKEN_PASSTHROUGH
}

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

@test "baseline claude-args: model + max-turns + allowedTools" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--model claude-sonnet-4-5-20250929"* ]]
  [[ "$args" == *"--max-turns 10"* ]]
  [[ "$args" == *"--allowedTools"* ]]
  [[ "$args" == *"Read"* ]]
  [[ "$args" == *"Bash(git commit)"* ]]
  [[ "$args" == *"Bash(gh api)"* ]]
  [[ "$args" == *"mcp__github_ci__get_ci_status"* ]]
  rm -f "$out"
}

@test "no --disallowedTools when EXTRA_DISALLOWED is empty" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" != *"--disallowedTools"* ]]
  rm -f "$out"
}

@test "EXTRA_DISALLOWED produces a --disallowedTools line" {
  EXTRA_DISALLOWED="WebFetch,Bash(rm)"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--disallowedTools \"WebFetch,Bash(rm)\""* ]]
  rm -f "$out"
}

@test "EXTRA_ALLOWED_TOOLS appends to allowedTools without replacing baseline" {
  EXTRA_ALLOWED_TOOLS="Bash(npm test),mcp__custom__do"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"Read"* ]]                # baseline survives
  [[ "$args" == *"Bash(npm test)"* ]]      # extras appended
  [[ "$args" == *"mcp__custom__do"* ]]
  rm -f "$out"
}

@test "no --mcp-config flag when MCP_CONFIG_INPUT is empty" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" != *"--mcp-config"* ]]
  rm -f "$out"
}

@test "inline JSON MCP_CONFIG_INPUT becomes --mcp-config '<json>'" {
  MCP_CONFIG_INPUT='{"mcpServers":{"x":{"command":"npx"}}}'
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--mcp-config '"*"mcpServers"* ]]
  rm -f "$out"
}

@test "relative path MCP_CONFIG_INPUT resolves against GITHUB_WORKSPACE" {
  echo '{"mcpServers":{}}' > "$WORK_DIR/m.json"
  MCP_CONFIG_INPUT="m.json"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--mcp-config $WORK_DIR/m.json"* ]]
  rm -f "$out"
}

@test "missing relative MCP_CONFIG_INPUT → exit 1" {
  MCP_CONFIG_INPUT="nope.json"
  run bash "$SCRIPT"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"mcp-config not found"* ]]
}

@test "system prompt is appended via --system-prompt with single quoting" {
  SYSTEM_PROMPT="You are a careful CI agent."
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--system-prompt 'You are a careful CI agent.'"* ]]
  rm -f "$out"
}

@test "system prompt with embedded single quotes is escaped" {
  SYSTEM_PROMPT="don't break"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  args="$(out_multiline "$out" claude-args)"
  [[ "$args" == *"--system-prompt 'don'\\''t break'"* ]]
  rm -f "$out"
}

@test "settings.env contains SLACK_WEBHOOK_URL when slack-webhook is set" {
  SLACK_WEBHOOK="https://hooks.slack.com/services/AAA/BBB/CCC"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  [[ "$settings" == *"SLACK_WEBHOOK_URL"* ]]
  [[ "$settings" == *"hooks.slack.com"* ]]
  rm -f "$out"
}

@test "settings.env omits SLACK_WEBHOOK_URL when slack-webhook is empty" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  [[ "$settings" != *"SLACK_WEBHOOK_URL"* ]]
  rm -f "$out"
}

@test "settings.env contains ANTHROPIC_BASE_URL when api-base-url is set" {
  API_BASE_URL="https://proxy.example.com/v1"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  [[ "$settings" == *"ANTHROPIC_BASE_URL"* ]]
  [[ "$settings" == *"proxy.example.com"* ]]
  rm -f "$out"
}

@test "settings.env mirrors api-key into ANTHROPIC_AUTH_TOKEN" {
  AUTH_TOKEN_PASSTHROUGH="zhipu-xxx-yyy"
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  echo "$settings" | jq -e '.env.ANTHROPIC_AUTH_TOKEN == "zhipu-xxx-yyy"' >/dev/null
  rm -f "$out"
}

@test "settings.env auto-includes API_TIMEOUT_MS and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  echo "$settings" | jq -e '.env.API_TIMEOUT_MS == "3000000"' >/dev/null
  echo "$settings" | jq -e '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC == "1"' >/dev/null
  rm -f "$out"
}

@test "EXTRA_ENV_JSON can override auto-injected timeouts" {
  EXTRA_ENV_JSON='{"API_TIMEOUT_MS":"60000"}'
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  echo "$settings" | jq -e '.env.API_TIMEOUT_MS == "60000"' >/dev/null
  rm -f "$out"
}

@test "EXTRA_ENV_JSON values are merged into settings.env" {
  EXTRA_ENV_JSON='{"FOO":"bar","DEBUG":"1"}'
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  [[ "$settings" == *"\"FOO\":\"bar\""* ]]
  [[ "$settings" == *"\"DEBUG\":\"1\""* ]]
  rm -f "$out"
}

@test "settings is valid JSON" {
  SLACK_WEBHOOK="https://hooks.slack.com/x"
  API_BASE_URL="https://proxy.example.com"
  EXTRA_ENV_JSON='{"X":"y"}'
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" bash "$SCRIPT" >/dev/null
  settings="$(out_kv "$out" settings)"
  echo "$settings" | jq -e . >/dev/null
  rm -f "$out"
}

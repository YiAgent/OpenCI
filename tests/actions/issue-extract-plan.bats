#!/usr/bin/env bats
# Tests for actions/issue/extract-plan/extract-plan.sh

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/extract-plan/extract-plan.sh"
  TMPDIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${TMPDIR}/output.txt"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TMPDIR"
}

run_extract() {
  SKIPPED="${1:-false}" EXECUTION_FILE="${2:-}" run bash "$SCRIPT"
}

get_output_var() {
  local key="$1"
  grep -A1 "^${key}<<EOF$" "$GITHUB_OUTPUT" | tail -1
}

@test "skipped=true emits skip plan with skip_reason" {
  run_extract "true"
  [ "$status" -eq 0 ]
  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"skip_reason":"missing-anthropic-api-key"'
}

@test "missing execution file emits escalate plan" {
  run_extract "false" ""
  [ "$status" -eq 0 ]
  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"skill":"escalate"'
}

@test "valid execution file extracts plan" {
  local ef="${TMPDIR}/exec.json"
  echo '{"version":"issue-action-plan/v1","reasoning":"ok","actions":[],"skip_reason":null}' > "$ef"

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"version":"issue-action-plan/v1"'
}

@test "plan-hash is emitted" {
  local ef="${TMPDIR}/exec.json"
  echo '{"version":"issue-action-plan/v1","reasoning":"ok","actions":[],"skip_reason":null}' > "$ef"

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  grep -q '^plan-hash=' "$GITHUB_OUTPUT"
}

@test "unparseable execution file emits escalate fallback" {
  local ef="${TMPDIR}/exec.json"
  echo 'this is not json at all' > "$ef"

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"skill":"escalate"'
}

# ── JSONL transcript (claude-code-action@v1.x output format) ─────────────────

@test "JSONL: plan embedded as nested object in transcript" {
  # Mimic claude-code-action@v1: a JSONL stream of system/init then result/success
  # records, with the action plan attached as a structured field.
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized","model":"glm-5.1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"type":"result","subtype":"success","plan":{"version":"issue-action-plan/v1","reasoning":"detected","actions":[],"skip_reason":null},"is_error":false}
JSONL

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"reasoning":"detected"'
}

@test "JSONL: plan embedded inside markdown json fence in assistant text" {
  # Mimics the common case where the agent emits the plan as a fenced
  # code block in its final assistant message.
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized","model":"glm-5.1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is the plan:\n\n```json\n{\"version\":\"issue-action-plan/v1\",\"reasoning\":\"fenced\",\"actions\":[],\"skip_reason\":null}\n```\n"}]}}
{"type":"result","subtype":"success","is_error":false}
JSONL

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"reasoning":"fenced"'
}

@test "JSONL: only system + result records (no plan) → escalate fallback" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized","model":"glm-5.1"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":24311}
JSONL

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"skill":"escalate"'
}

@test "JSONL: plan with nested params objects is extracted (regression for #93)" {
  # The (?R) recursive perl regex broke when action plan had nested {} objects,
  # e.g. params:{"reason":"...","labels":["needs-human"]} inside an action entry.
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```json\n{\"version\":\"issue-action-plan/v1\",\"reasoning\":\"nested\",\"actions\":[{\"id\":\"escalate\",\"skill\":\"escalate\",\"params\":{\"reason\":\"not parseable\",\"labels\":[\"needs-human\"]},\"risk\":\"low\"}],\"skip_reason\":null}\n```"}]}}
{"type":"result","subtype":"success","is_error":false}
JSONL

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  echo "$plan" | grep -q '"reasoning":"nested"'
  echo "$plan" | grep -q '"params"'
}

@test "no crash when the second jq receives empty input (regression for #81)" {
  # The original bug: extract returned an empty string and the canonicalize
  # step `jq -c . <<<"$plan"` then crashed with 'Invalid numeric literal at
  # line 2, column 0', taking the workflow exit to 5. This regression test
  # forces every parse strategy to fail and confirms the script still exits
  # 0 with the FAIL_PLAN.
  local ef="${TMPDIR}/exec.jsonl"
  # Multi-line non-JSON content that defeats every parse strategy.
  printf 'not json at all\nstill not json\n12345 nope\n' > "$ef"

  run_extract "false" "$ef"
  [ "$status" -eq 0 ]

  local plan
  plan="$(get_output_var action-plan)"
  [ -n "$plan" ]
  echo "$plan" | grep -q '"skill":"escalate"'
}

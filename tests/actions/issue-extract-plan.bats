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

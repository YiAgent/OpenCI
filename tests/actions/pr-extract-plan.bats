#!/usr/bin/env bats
# Tests for actions/pr/extract-plan/extract-plan.sh

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/extract-plan/extract-plan.sh"
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
  grep -A1 "^${1}<<EOF$" "$GITHUB_OUTPUT" | tail -1
}

@test "skipped=true emits skip plan with skip_reason" {
  run_extract "true"
  [ "$status" -eq 0 ]
  local plan
  plan="$(get_output_var plan)"
  echo "$plan" | grep -q '"skip_reason":"missing-anthropic-api-key"'
}

@test "missing execution file emits escalate fallback plan" {
  run_extract "false" ""
  [ "$status" -eq 0 ]
  local plan
  plan="$(get_output_var plan)"
  echo "$plan" | grep -q '"skill":"escalate"'
}

@test "valid execution file extracts pr-action-plan/v1" {
  local ef="${TMPDIR}/exec.json"
  cat > "$ef" <<'JSON'
{"version":"pr-action-plan/v1","summary":"ok","risk":"low","risk_reason":"","reviewer_focus":[],"actions":[],"skip_reason":null}
JSON
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  local plan
  plan="$(get_output_var plan)"
  echo "$plan" | grep -q '"version":"pr-action-plan/v1"'
}

@test "skip-reason output is populated from plan" {
  run_extract "true"
  [ "$status" -eq 0 ]
  grep -q '^skip-reason=missing-anthropic-api-key$' "$GITHUB_OUTPUT"
}

@test "skip-reason is empty when plan has no skip_reason" {
  local ef="${TMPDIR}/exec.json"
  cat > "$ef" <<'JSON'
{"version":"pr-action-plan/v1","summary":"ok","risk":"low","risk_reason":"","reviewer_focus":[],"actions":[],"skip_reason":null}
JSON
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  grep -q '^skip-reason=$' "$GITHUB_OUTPUT"
}

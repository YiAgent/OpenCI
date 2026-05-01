#!/usr/bin/env bats
# Tests for actions/prd/check-error-rate/evaluate.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/prd/check-error-rate/evaluate.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/sentry"
}

@test "low traffic (<min-events) → skipped, passed=true, exit 0" {
  run env -i \
    STATS_TOTAL_FILE="${FIX}/total-low.json" \
    STATS_ERROR_FILE="${FIX}/errors-low.json" \
    BASELINE_ERROR_RATE="0.005" \
    THRESHOLD_MULTIPLIER="2.0" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Error Rate Check Skipped"* ]]
  [[ "${output}" == *"passed=true"* ]]
}

@test "high traffic + low error rate → passed, exit 0" {
  # 10000 total, 10 errors → 0.001 < 0.01 threshold
  run env -i \
    STATS_TOTAL_FILE="${FIX}/total-high.json" \
    STATS_ERROR_FILE="${FIX}/errors-low.json" \
    BASELINE_ERROR_RATE="0.005" \
    THRESHOLD_MULTIPLIER="2.0" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Error Rate OK"* ]]
  [[ "${output}" == *"passed=true"* ]]
}

@test "high traffic + high error rate → failed, exit 1" {
  # 10000 total, 500 errors → 0.05 > 0.01 threshold
  run env -i \
    STATS_TOTAL_FILE="${FIX}/total-high.json" \
    STATS_ERROR_FILE="${FIX}/errors-high.json" \
    BASELINE_ERROR_RATE="0.005" \
    THRESHOLD_MULTIPLIER="2.0" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Error Rate Exceeded"* ]]
  [[ "${output}" == *"passed=false"* ]]
}

@test "empty Sentry response → skipped (0 events < min)" {
  run env -i \
    STATS_TOTAL_FILE="${FIX}/empty.json" \
    STATS_ERROR_FILE="${FIX}/empty.json" \
    BASELINE_ERROR_RATE="0.005" \
    THRESHOLD_MULTIPLIER="2.0" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"passed=true"* ]]
}

@test "missing STATS_TOTAL → exit 2" {
  run env -i \
    STATS_ERROR_JSON='{"groups":[]}' \
    bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}${stderr:-}" == *"Missing STATS_TOTAL_JSON"* ]]
}

@test "writes outputs to GITHUB_OUTPUT when set" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env \
    STATS_TOTAL_FILE="${FIX}/total-high.json" \
    STATS_ERROR_FILE="${FIX}/errors-low.json" \
    BASELINE_ERROR_RATE="0.005" \
    THRESHOLD_MULTIPLIER="2.0" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}" >/dev/null
  grep -q '^total-events=' "$out"
  grep -q '^error-events=' "$out"
  grep -q '^error-rate='   "$out"
  grep -q '^passed=true$'  "$out"
  rm -f "$out"
}

@test "threshold scales with multiplier" {
  # 10000 total, 500 errors → 0.05 rate. With baseline=0.001 multiplier=100 threshold=0.1 → passes.
  run env -i \
    STATS_TOTAL_FILE="${FIX}/total-high.json" \
    STATS_ERROR_FILE="${FIX}/errors-high.json" \
    BASELINE_ERROR_RATE="0.001" \
    THRESHOLD_MULTIPLIER="100" \
    MIN_EVENTS="100" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Error Rate OK"* ]]
}

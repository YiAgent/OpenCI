#!/usr/bin/env bats
# Tests for actions/prd/canary-watch/detect.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/prd/canary-watch/detect.sh"
}

@test "no history → pass" {
  run env -i CURRENT_RATE="0.05" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no history"* ]]
  [[ "${output}" == *"regression=false"* ]]
}

@test "current within 3σ → pass" {
  # mean ≈ 0.0057, 3σ-window upper bound ≈ 0.008. Use 0.006 → safely inside.
  hist=$'0.005\n0.006\n0.005\n0.007\n0.006\n0.005\n0.006'
  run env -i CURRENT_RATE="0.006" HISTORY_RATES="$hist" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"regression=false"* ]]
  [[ "${output}" == *"Canary OK"* ]]
}

@test "current beyond 3σ → warning + advisory pass" {
  hist=$'0.005\n0.006\n0.005\n0.007\n0.006\n0.005\n0.006'
  run env -i CURRENT_RATE="0.10" HISTORY_RATES="$hist" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"regression=true"* ]]
  [[ "${output}" == *"::warning"* ]]
}

@test "current beyond 3σ + REGRESSION_FAILS → exit 1" {
  hist=$'0.005\n0.006\n0.005\n0.007\n0.006\n0.005\n0.006'
  run env -i CURRENT_RATE="0.10" HISTORY_RATES="$hist" REGRESSION_FAILS="true" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"regression=true"* ]]
}

@test "missing CURRENT_RATE → exit 2" {
  run env -i bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "writes outputs to GITHUB_OUTPUT" {
  hist=$'0.005\n0.006'
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i \
    GITHUB_OUTPUT="$out" CURRENT_RATE="0.005" HISTORY_RATES="$hist" \
    bash "${SCRIPT}" >/dev/null
  grep -q '^regression=' "$out"
  grep -q '^mean='       "$out"
  grep -q '^threshold='  "$out"
  rm -f "$out"
}

#!/usr/bin/env bats
# Tests for actions/prd/observe-window/check.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/prd/observe-window/check.sh"
}

iso_now_minus_min() {
  local minus="$1"
  if date -u -v "-${minus}M" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  date -u -d "-${minus} minutes" +%Y-%m-%dT%H:%M:%SZ
}

@test "missing STG_DEPLOY_TIME → exit 1" {
  run env -i bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Missing STG_DEPLOY_TIME"* ]]
}

@test "passes when elapsed exceeds required minutes" {
  ts="$(iso_now_minus_min 35)"
  run env -i STG_DEPLOY_TIME="$ts" OBSERVATION_MINUTES=30 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Observation Window OK"* ]]
}

@test "fails when elapsed is below required minutes" {
  ts="$(iso_now_minus_min 5)"
  run env -i STG_DEPLOY_TIME="$ts" OBSERVATION_MINUTES=30 bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Observation Window Too Early"* ]]
}

@test "passes when required is 0 (degenerate but valid)" {
  ts="$(iso_now_minus_min 0)"
  run env -i STG_DEPLOY_TIME="$ts" OBSERVATION_MINUTES=0 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "rejects unparseable timestamp" {
  run env -i STG_DEPLOY_TIME="not-a-date" OBSERVATION_MINUTES=30 bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Cannot parse timestamp"* ]]
}

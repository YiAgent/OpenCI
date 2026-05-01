#!/usr/bin/env bats
# Tests for actions/pr/check-coverage/compute.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/check-coverage/compute.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/coverage"
}

@test "missing file → exit 2" {
  run env -i COVERAGE_FILE="/no/such/file" THRESHOLD="80" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}${stderr:-}" == *"Coverage Artifact Missing"* ]]
}

@test "lcov 75% above pr threshold 70 → ok" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="70" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"coverage-percent=75.00"* ]]
  [[ "${output}" == *"passed=true"* ]]
}

@test "lcov 75% below pr threshold 80 → warn (still exit 0)" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="80" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning"* ]]
  [[ "${output}" == *"passed=false"* ]]
}

@test "lcov 75% below stg threshold 80 → exit 1" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="80" MODE="stg" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error"* ]]
}

@test "lcov 75% above stg threshold 60 → ok" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="60" MODE="stg" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "lcov 75% below prd threshold 80 → exit 1" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="80" MODE="prd" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
}

@test "go coverage 50% → 50.00" {
  run env -i COVERAGE_FILE="${FIX}/sample.out" THRESHOLD="40" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"coverage-percent=50.00"* ]]
}

@test "cobertura 87% → 87.00" {
  run env -i COVERAGE_FILE="${FIX}/cobertura.xml" THRESHOLD="80" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"coverage-percent=87.00"* ]]
}

@test "jacoco 80% → 80.00" {
  run env -i COVERAGE_FILE="${FIX}/jacoco.xml" THRESHOLD="80" MODE="pr" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"coverage-percent=80.00"* ]]
}

@test "unknown mode → exit 2" {
  run env -i COVERAGE_FILE="${FIX}/sample.info" THRESHOLD="80" MODE="bogus" bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "writes outputs to GITHUB_OUTPUT" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i \
    GITHUB_OUTPUT="$out" \
    COVERAGE_FILE="${FIX}/sample.info" \
    THRESHOLD="70" MODE="pr" \
    bash "${SCRIPT}" >/dev/null
  grep -q '^coverage-percent=75.00$' "$out"
  grep -q '^passed=true$' "$out"
  rm -f "$out"
}

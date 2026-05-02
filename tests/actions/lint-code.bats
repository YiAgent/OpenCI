#!/usr/bin/env bats
# Tests for actions/pr/lint-code/pick-flavor.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/lint-code/pick-flavor.sh"
}

@test "node → javascript flavor" {
  run env -i LANGUAGE=node bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=javascript"* ]]
}

@test "javascript → javascript flavor" {
  run env -i LANGUAGE=javascript bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=javascript"* ]]
}

@test "typescript → javascript flavor" {
  run env -i LANGUAGE=typescript bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=javascript"* ]]
}

@test "python → python flavor" {
  run env -i LANGUAGE=python bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=python"* ]]
}

@test "go → go flavor" {
  run env -i LANGUAGE=go bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=go"* ]]
}

@test "java → java flavor" {
  run env -i LANGUAGE=java bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=java"* ]]
}

@test "kotlin → java flavor" {
  run env -i LANGUAGE=kotlin bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=java"* ]]
}

@test "unknown language → ci_light flavor" {
  run env -i LANGUAGE=ruby bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=ci_light"* ]]
}

@test "empty language → ci_light flavor" {
  run env -i LANGUAGE= bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flavor=ci_light"* ]]
}

@test "emits notice annotation" {
  run env -i LANGUAGE=node bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice title=MegaLinter Flavor::"* ]]
}

@test "writes to GITHUB_OUTPUT when set" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i \
    GITHUB_OUTPUT="$out" \
    LANGUAGE=python \
    bash "${SCRIPT}" >/dev/null
  grep -q '^flavor=python$' "$out"
  rm -f "$out"
}

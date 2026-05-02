#!/usr/bin/env bats
# Tests for actions/pr/scan-sonarcloud graceful-skip logic

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/scan-sonarcloud/check-token.sh"
  ACTION="${PROJECT_ROOT}/actions/pr/scan-sonarcloud/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "empty token → skip=true" {
  run env -i SONAR_TOKEN= bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip=true"* ]]
}

@test "empty token → emits notice annotation" {
  run env -i SONAR_TOKEN= bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice title=SonarCloud Skipped::"* ]]
}

@test "set token → skip=false" {
  run env -i SONAR_TOKEN=abc123 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip=false"* ]]
}

@test "set token → no skip annotation emitted" {
  run env -i SONAR_TOKEN=abc123 bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"SonarCloud Skipped"* ]]
}

@test "writes skip to GITHUB_OUTPUT when set" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i GITHUB_OUTPUT="$out" SONAR_TOKEN= bash "${SCRIPT}" >/dev/null
  grep -q '^skip=true$' "$out"
  rm -f "$out"
}

@test "action.yml uses SonarCloud with 40-char SHA" {
  sha="$(grep 'uses:.*SonarSource' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "SonarCloud SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*SonarSource' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'SonarSource/sonarcloud-github-action:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "sonarcloud step is guarded by skip condition" {
  run grep "steps.check.outputs.skip" "${ACTION}"
  [ "${status}" -eq 0 ]
}

#!/usr/bin/env bats
# Structural tests for actions/pr/scan-deps/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/pr/scan-deps/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "uses dependency-review-action with a 40-char SHA" {
  sha="$(grep 'uses:.*dependency-review-action' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*dependency-review-action' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'actions/dependency-review-action:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

@test "fail-on-severity input has a default value" {
  run grep 'fail-on-severity' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "uses: composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

#!/usr/bin/env bats
# Structural tests for actions/security/scan-codeql/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/security/scan-codeql/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "uses composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares language input" {
  run grep 'language:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "all three CodeQL steps use the same 40-char SHA" {
  init_sha="$(grep 'codeql-action/init@' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  build_sha="$(grep 'codeql-action/autobuild@' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  analyze_sha="$(grep 'codeql-action/analyze@' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${init_sha}" ]
  [ "${init_sha}" = "${build_sha}" ]
  [ "${init_sha}" = "${analyze_sha}" ]
  [ "${#init_sha}" -eq 40 ]
}

@test "CodeQL SHA matches manifest.yml" {
  action_sha="$(grep 'codeql-action/init@' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'github/codeql-action:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

@test "has init step" {
  run grep 'codeql-action/init' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "has autobuild step" {
  run grep 'codeql-action/autobuild' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "has analyze step" {
  run grep 'codeql-action/analyze' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "analyze step uses language category" {
  run grep 'category:' "${ACTION}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"language:"* ]]
}

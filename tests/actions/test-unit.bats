#!/usr/bin/env bats
# Structural and contract tests for actions/pr/test-unit/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/pr/test-unit/action.yml"
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

@test "declares package-manager input" {
  run grep 'package-manager:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares coverage-file output" {
  run grep 'coverage-file:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "uses dorny/test-reporter with 40-char SHA" {
  sha="$(grep 'uses:.*dorny/test-reporter' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "test-reporter SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*dorny/test-reporter' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'dorny/test-reporter:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "uses upload-artifact with 40-char SHA" {
  sha="$(grep 'uses:.*actions/upload-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "upload-artifact SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*actions/upload-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'actions/upload-artifact:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

@test "handles node test command selection" {
  run grep -A5 'node)' "${ACTION}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pnpm test"* ]]
}

@test "handles python test command selection" {
  run grep -A3 'python)' "${ACTION}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pytest"* ]]
}

@test "handles go test command selection" {
  run grep -A3 'go)' "${ACTION}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"go test"* ]]
}

@test "unsupported language emits skip notice (not an error)" {
  # Previously errored with title=Unsupported Language; that broke PR checks
  # on repos with no recognized single-language unit test target. Now emits
  # a notice and exits 0 so multi-language / doc-only repos stay green.
  run grep 'title=Test Skipped' "${ACTION}"
  [ "${status}" -eq 0 ]
}

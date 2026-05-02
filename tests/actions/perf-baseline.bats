#!/usr/bin/env bats
# Structural tests for actions/stg/perf-baseline/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/stg/perf-baseline/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "uses composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares perf-dir input with default" {
  run grep -A4 'perf-dir:' "${ACTION}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tests/perf"* ]]
}

@test "declares enforce-perf input" {
  run grep 'enforce-perf:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares regress-threshold-percent input" {
  run grep 'regress-threshold-percent:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "skips gracefully when perf-dir absent and no health-url" {
  run grep 'Perf Baseline Skipped' "${ACTION}"
  [ "${status}" -eq 0 ]
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

@test "uses download-artifact with 40-char SHA" {
  sha="$(grep 'uses:.*actions/download-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "download-artifact SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*actions/download-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'actions/download-artifact:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "soft-gate by default (warning not error on regression)" {
  run grep '::warning title=' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "enforce-perf=true emits error and exits 1" {
  run grep 'enforce-perf' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "emits Perf Baseline Recorded on first run" {
  run grep 'Perf Baseline Recorded' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

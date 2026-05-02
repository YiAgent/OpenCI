#!/usr/bin/env bats
# Structural tests for actions/prd/terraform-drift/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/prd/terraform-drift/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "uses composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares infra-dir input" {
  run grep 'infra-dir:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "declares github-token input" {
  run grep 'github-token:' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "uses hashicorp/setup-terraform with 40-char SHA" {
  sha="$(grep 'uses:.*hashicorp/setup-terraform' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "setup-terraform SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*hashicorp/setup-terraform' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'hashicorp/setup-terraform:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

@test "skip gate when infra-dir absent" {
  run grep 'Terraform Drift Skipped' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "opens advisory issue on drift (exit code 2)" {
  run grep 'infra-drift' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "never blocks deploy (no exit 1 on drift)" {
  # exit 1 only appears in the unrelated 'set -e' context, not as hard fail for drift
  run grep -E '^\s+exit 1' "${ACTION}"
  [ "${status}" -ne 0 ]
}

#!/usr/bin/env bats
# Structural tests for actions/security/generate-sbom/action.yml

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/security/generate-sbom/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "uses composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "outputs SPDX-JSON format" {
  run grep 'spdx' "${ACTION}"
  [ "${status}" -eq 0 ]
}

@test "uses trivy-action with 40-char SHA" {
  sha="$(grep 'uses:.*aquasecurity/trivy-action' "${ACTION}" | grep -oE '[0-9a-f]{40}' | head -1)"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "trivy SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*aquasecurity/trivy-action' "${ACTION}" | grep -oE '[0-9a-f]{40}' | head -1)"
  manifest_sha="$(grep 'aquasecurity/trivy-action:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
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

@test "declares image-ref or image input" {
  run grep -E 'image' "${ACTION}"
  [ "${status}" -eq 0 ]
}

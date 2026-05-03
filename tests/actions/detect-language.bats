#!/usr/bin/env bats
# Tests for actions/_common/detect-language/detect.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/detect-language/detect.sh"
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
}

run_detect() {
  run bash "${SCRIPT}" "${FIXTURES}/$1"
  [ "${status}" -eq 0 ]
}

@test "node-project (default lock) → npm + .nvmrc version" {
  run_detect "node-project"
  [[ "${output}" == *"language=node"* ]]
  [[ "${output}" == *"package-manager=npm"* ]]
  [[ "${output}" == *"version-file=.nvmrc"* ]]
  [[ "${output}" == *"runtime-version=20.10.0"* ]]
}

@test "node-pnpm-project → pnpm" {
  run_detect "node-pnpm-project"
  [[ "${output}" == *"language=node"* ]]
  [[ "${output}" == *"package-manager=pnpm"* ]]
}

@test "node-yarn-project → yarn" {
  run_detect "node-yarn-project"
  [[ "${output}" == *"language=node"* ]]
  [[ "${output}" == *"package-manager=yarn"* ]]
}

@test "python-uv-project → python + uv + version" {
  run_detect "python-uv-project"
  [[ "${output}" == *"language=python"* ]]
  [[ "${output}" == *"package-manager=uv"* ]]
  [[ "${output}" == *"runtime-version=3.12.0"* ]]
}

@test "python-pip-project → python + pip" {
  run_detect "python-pip-project"
  [[ "${output}" == *"language=python"* ]]
  [[ "${output}" == *"package-manager=pip"* ]]
}

@test "go-project → go + go-mod + version" {
  run_detect "go-project"
  [[ "${output}" == *"language=go"* ]]
  [[ "${output}" == *"package-manager=go-mod"* ]]
  [[ "${output}" == *"version-file=go.mod"* ]]
  [[ "${output}" == *"runtime-version=1.22"* ]]
}

@test "java-maven-project → java + maven" {
  run_detect "java-maven-project"
  [[ "${output}" == *"language=java"* ]]
  [[ "${output}" == *"package-manager=maven"* ]]
  [[ "${output}" == *"version-file=pom.xml"* ]]
}

@test "java-gradle-project → java + gradle" {
  run_detect "java-gradle-project"
  [[ "${output}" == *"language=java"* ]]
  [[ "${output}" == *"package-manager=gradle"* ]]
}

@test "kotlin-gradle-kts-project (with .kt sources) → kotlin + gradle-kts" {
  run_detect "kotlin-gradle-kts-project"
  [[ "${output}" == *"language=kotlin"* ]]
  [[ "${output}" == *"package-manager=gradle-kts"* ]]
}

@test "java-gradle-kts but only .java sources → java + gradle-kts" {
  run_detect "java-gradle-kts-only-java-project"
  [[ "${output}" == *"language=java"* ]]
  [[ "${output}" == *"package-manager=gradle-kts"* ]]
}

@test "unknown-project → language=unknown" {
  run_detect "unknown-project"
  [[ "${output}" == *"language=unknown"* ]]
  [[ "${output}" == *"package-manager=unknown"* ]]
}

@test "emits ::notice annotation with detected language" {
  run_detect "node-project"
  [[ "${output}" == *"::notice title=Language Detected::"* ]]
  [[ "${output}" == *"language=node"* ]]
}

@test "writes to GITHUB_OUTPUT when set" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "${FIXTURES}/go-project" >/dev/null
  grep -q '^language=go$' "$out_file"
  grep -q '^package-manager=go-mod$' "$out_file"
  rm -f "$out_file"
}

@test "priority: node beats python when both markers present" {
  TMP="$(mktemp -d)"
  echo '{"name":"x"}' > "${TMP}/package.json"
  echo "[project]" > "${TMP}/pyproject.toml"
  run bash "${SCRIPT}" "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"language=node"* ]]
  rm -rf "${TMP}"
}

@test "priority: python beats go when both markers present" {
  TMP="$(mktemp -d)"
  echo "[project]" > "${TMP}/pyproject.toml"
  printf 'module x\n\ngo 1.22\n' > "${TMP}/go.mod"
  run bash "${SCRIPT}" "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"language=python"* ]]
  rm -rf "${TMP}"
}

@test "OVERRIDE env var bypasses filesystem detection" {
  TMP="$(mktemp -d)"
  # go.mod is present but OVERRIDE wins
  printf 'module x\n\ngo 1.22\n' > "${TMP}/go.mod"
  run env OVERRIDE=rust bash "${SCRIPT}" "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"language=rust"* ]]
  [[ "${output}" == *"package-manager=unknown"* ]]
  rm -rf "${TMP}"
}

@test "OVERRIDE writes to GITHUB_OUTPUT when set" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" OVERRIDE=python bash "${SCRIPT}" /tmp >/dev/null
  grep -q '^language=python$' "$out_file"
  grep -q '^package-manager=unknown$' "$out_file"
  rm -f "$out_file"
}

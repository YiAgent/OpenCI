#!/usr/bin/env bats
# Tests for actions/pr/lint-code/pick-flavor.sh
#
# Input (env): LANGUAGE
# Output: flavor=<value> to stdout + GITHUB_OUTPUT

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/lint-code/pick-flavor.sh"
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

run_pick() {
  run env -i LANGUAGE="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
}

stdout_flavor() {
  printf '%s\n' "${lines[@]}" | grep -m1 '^flavor=' | sed 's/^flavor=//'
}

ghout_flavor() {
  grep -m1 '^flavor=' "$GITHUB_OUTPUT" | sed 's/^flavor=//'
}

# ── 1. Language→flavor mapping ────────────────────────────────────────────────

@test "node → javascript" {
  run_pick "node"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "javascript" ]
}

@test "javascript → javascript" {
  run_pick "javascript"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "javascript" ]
}

@test "typescript → javascript" {
  run_pick "typescript"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "javascript" ]
}

@test "python → python" {
  run_pick "python"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "python" ]
}

@test "go → go" {
  run_pick "go"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "go" ]
}

@test "java → java" {
  run_pick "java"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "java" ]
}

@test "kotlin → java" {
  run_pick "kotlin"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "java" ]
}

# ── 2. Unknown language → ci_light ────────────────────────────────────────────

@test "unknown language → ci_light" {
  run_pick "rust"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "ci_light" ]
}

@test "empty LANGUAGE → ci_light" {
  run_pick ""
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "ci_light" ]
}

@test "ruby → ci_light" {
  run_pick "ruby"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "ci_light" ]
}

@test "csharp → ci_light" {
  run_pick "csharp"
  [ "$status" -eq 0 ]
  [ "$(stdout_flavor)" = "ci_light" ]
}

# ── 3. GITHUB_OUTPUT is written correctly ─────────────────────────────────────

@test "writes flavor to GITHUB_OUTPUT for node" {
  run_pick "node"
  [ "$status" -eq 0 ]
  [ "$(ghout_flavor)" = "javascript" ]
}

@test "writes flavor to GITHUB_OUTPUT for python" {
  run_pick "python"
  [ "$status" -eq 0 ]
  [ "$(ghout_flavor)" = "python" ]
}

@test "writes flavor to GITHUB_OUTPUT for unknown" {
  run_pick "haskell"
  [ "$status" -eq 0 ]
  [ "$(ghout_flavor)" = "ci_light" ]
}

# ── 4. Notice annotation is emitted ──────────────────────────────────────────

@test "emits ::notice with language and flavor" {
  run_pick "go"
  [ "$status" -eq 0 ]
  local notice
  notice="$(printf '%s\n' "${lines[@]}" | grep '::notice')"
  [[ "$notice" == *"language=go"* ]]
  [[ "$notice" == *"flavor=go"* ]]
}

# ── 5. Always exits 0 ────────────────────────────────────────────────────────

@test "exits 0 for all supported languages" {
  for lang in node javascript typescript python go java kotlin rust ruby ""; do
    run_pick "$lang"
    [ "$status" -eq 0 ]
  done
}

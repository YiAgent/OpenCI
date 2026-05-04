#!/usr/bin/env bats
# Tests for actions/pr/scan-sonarcloud/check-token.sh
#
# Input (env): SONAR_TOKEN
# Output: skip=true|false to stdout + GITHUB_OUTPUT

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/scan-sonarcloud/check-token.sh"
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

run_check() {
  run env -i SONAR_TOKEN="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
}

stdout_skip() {
  printf '%s\n' "${lines[@]}" | grep -m1 '^skip=' | sed 's/^skip=//'
}

ghout_skip() {
  grep -m1 '^skip=' "$GITHUB_OUTPUT" | sed 's/^skip=//'
}

# ── 1. Empty token → skip=true ───────────────────────────────────────────────

@test "empty SONAR_TOKEN → skip=true" {
  run_check ""
  [ "$status" -eq 0 ]
  [ "$(stdout_skip)" = "true" ]
}

@test "whitespace-only SONAR_TOKEN → skip=true" {
  run_check "   "
  [ "$status" -eq 0 ]
  [ "$(stdout_skip)" = "true" ]
}

@test "unset SONAR_TOKEN → skip=true" {
  run env -i GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local skip
  skip="$(printf '%s\n' "${lines[@]}" | grep -m1 '^skip=' | sed 's/^skip=//')"
  [ "$skip" = "true" ]
}

# ── 2. Non-empty token → skip=false ──────────────────────────────────────────

@test "valid SONAR_TOKEN → skip=false" {
  run_check "sq_abc123def456"
  [ "$status" -eq 0 ]
  [ "$(stdout_skip)" = "false" ]
}

@test "any non-empty string → skip=false" {
  run_check "my-token"
  [ "$status" -eq 0 ]
  [ "$(stdout_skip)" = "false" ]
}

# ── 3. GITHUB_OUTPUT ─────────────────────────────────────────────────────────

@test "writes skip=true to GITHUB_OUTPUT when empty" {
  run_check ""
  [ "$status" -eq 0 ]
  [ "$(ghout_skip)" = "true" ]
}

@test "writes skip=false to GITHUB_OUTPUT when set" {
  run_check "sq_token123"
  [ "$status" -eq 0 ]
  [ "$(ghout_skip)" = "false" ]
}

# ── 4. Notice annotation ─────────────────────────────────────────────────────

@test "emits notice when token is missing" {
  run_check ""
  [ "$status" -eq 0 ]
  local notice
  notice="$(printf '%s\n' "${lines[@]}" | grep '::notice')"
  [[ "$notice" == *"SonarCloud Skipped"* ]]
}

# ── 5. Exit code always 0 ────────────────────────────────────────────────────

@test "always exits 0 regardless of token state" {
  run_check ""
  [ "$status" -eq 0 ]
  run_check "valid-token"
  [ "$status" -eq 0 ]
}

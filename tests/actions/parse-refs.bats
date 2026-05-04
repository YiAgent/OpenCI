#!/usr/bin/env bats
# Tests for actions/prd/verify-fix/parse-refs.sh
#
# Input (env): PR_BODY
# Output: refs=<comma-separated> to stdout + GITHUB_OUTPUT

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/prd/verify-fix/parse-refs.sh"
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

run_parse() {
  run env -i PR_BODY="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
}

stdout_refs() {
  printf '%s\n' "${lines[@]}" | grep -m1 '^refs=' | sed 's/^refs=//'
}

ghout_refs() {
  grep -m1 '^refs=' "$GITHUB_OUTPUT" | sed 's/^refs=//'
}

# ── 1. Single ref extraction ─────────────────────────────────────────────────

@test "Closes #42 → refs=42" {
  run_parse "Closes #42"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "42" ]
}

@test "Fixes #100 → refs=100" {
  run_parse "Fixes #100"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "100" ]
}

@test "Resolves #7 → refs=7" {
  run_parse "Resolves #7"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "7" ]
}

# ── 2. Case insensitive ─────────────────────────────────────────────────────

@test "closes #42 (lowercase) → refs=42" {
  run_parse "closes #42"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "42" ]
}

@test "FIXES #10 (uppercase) → refs=10" {
  run_parse "FIXES #10"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "10" ]
}

# ── 3. Multiple refs ─────────────────────────────────────────────────────────

@test "Closes #42 and Fixes #100 → refs=100,42 (sorted unique)" {
  run_parse "Closes #42 and Fixes #100"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "100,42" ]
}

@test "three refs sorted and deduplicated" {
  run_parse "Closes #3, Fixes #1, Resolves #2"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "1,2,3" ]
}

# ── 4. Deduplication ─────────────────────────────────────────────────────────

@test "duplicate refs are deduplicated" {
  run_parse "Closes #42, Fixes #42"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "42" ]
}

# ── 5. No refs ───────────────────────────────────────────────────────────────

@test "no refs in body → refs is empty" {
  run_parse "This is a regular PR description with no issue references."
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "" ]
}

@test "empty body → refs is empty" {
  run_parse ""
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "" ]
}

# ── 6. Various keyword forms ─────────────────────────────────────────────────

@test "Close (singular) → refs=5" {
  run_parse "Close #5"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "5" ]
}

@test "Fix (singular) → refs=8" {
  run_parse "Fix #8"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "8" ]
}

@test "Resolve (singular) → refs=3" {
  run_parse "Resolve #3"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "3" ]
}

@test "Closed (past tense) → refs=11" {
  run_parse "Closed #11"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "11" ]
}

@test "Fixed (past tense) → refs=22" {
  run_parse "Fixed #22"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "22" ]
}

@test "Resolved (past tense) → refs=33" {
  run_parse "Resolved #33"
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "33" ]
}

# ── 7. GITHUB_OUTPUT ─────────────────────────────────────────────────────────

@test "writes refs to GITHUB_OUTPUT" {
  run_parse "Closes #42"
  [ "$status" -eq 0 ]
  [ "$(ghout_refs)" = "42" ]
}

@test "writes empty refs to GITHUB_OUTPUT when no matches" {
  run_parse "No refs here"
  [ "$status" -eq 0 ]
  [ "$(ghout_refs)" = "" ]
}

# ── 8. Mixed content ────────────────────────────────────────────────────────

@test "refs extracted from multi-line PR body" {
  run_parse $'## Summary\nThis PR fixes a bug.\n\nCloses #42\nFixes #100'
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "100,42" ]
}

@test "refs extracted from body with other text around them" {
  run_parse "This PR Fixes #55 and also addresses some other concerns."
  [ "$status" -eq 0 ]
  [ "$(stdout_refs)" = "55" ]
}

# ── 9. Notice annotation ─────────────────────────────────────────────────────

@test "emits notice with refs" {
  run_parse "Closes #42"
  [ "$status" -eq 0 ]
  local notice
  notice="$(printf '%s\n' "${lines[@]}" | grep '::notice')"
  [[ "$notice" == *"42"* ]]
}

@test "emits notice with (none) when no refs" {
  run_parse "No refs"
  [ "$status" -eq 0 ]
  local notice
  notice="$(printf '%s\n' "${lines[@]}" | grep '::notice')"
  [[ "$notice" == *"(none)"* ]]
}

# ── 10. Exit code always 0 ───────────────────────────────────────────────────

@test "always exits 0" {
  run_parse "Closes #42"
  [ "$status" -eq 0 ]
  run_parse ""
  [ "$status" -eq 0 ]
  run_parse "no refs at all"
  [ "$status" -eq 0 ]
}

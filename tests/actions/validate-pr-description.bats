#!/usr/bin/env bats
# Tests for actions/pr/validate-pr-description/check.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/pr/validate-pr-description/check.sh"
}

@test "passes with 'Closes #123'" {
  run env -i PR_BODY="Closes #123" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "passes with 'Fixes #5'" {
  run env -i PR_BODY="Fixes #5" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "passes with 'Resolves #99'" {
  run env -i PR_BODY="Resolves #99" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "case-insensitive (closes / FIXES / RESOLVES)" {
  for body in "closes #1" "FIXES #2" "RESOLVES #3"; do
    run env -i PR_BODY="${body}" PR_LABELS="" bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
  done
}

@test "passes with cross-repo issue ref org/repo#7" {
  run env -i PR_BODY="Closes acme/widgets#7" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "fails with empty body and no label" {
  run env -i PR_BODY="" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=PR Description"* ]]
}

@test "fails with body that mentions number but no closing keyword" {
  run env -i PR_BODY="See discussion #42" PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
}

@test "passes when no-issue label is present, even with empty body" {
  run env -i PR_BODY="" PR_LABELS="no-issue" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no-issue label present"* ]]
}

@test "no-issue label match is case-insensitive" {
  run env -i PR_BODY="" PR_LABELS="No-Issue" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "no-issue label works inside a comma-joined list" {
  run env -i PR_BODY="" PR_LABELS="bug,no-issue,priority:p2" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "label list trims whitespace around names" {
  run env -i PR_BODY="" PR_LABELS=" no-issue " bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "fails when an unrelated label is the only one" {
  run env -i PR_BODY="" PR_LABELS="bug" bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
}

@test "passes with multi-line body containing 'Closes #N'" {
  run env -i PR_BODY=$'## Summary\nFix the thing.\n\nCloses #42' PR_LABELS="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

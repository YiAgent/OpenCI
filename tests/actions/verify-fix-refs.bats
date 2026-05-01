#!/usr/bin/env bats
# Tests for actions/prd/verify-fix/parse-refs.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/prd/verify-fix/parse-refs.sh"
}

@test "Closes #42 → 42" {
  run env -i PR_BODY="Closes #42" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"refs=42"* ]]
}

@test "multiple refs are joined and de-duplicated" {
  run env -i PR_BODY=$'Fixes #1\nResolves #5\nCloses #1' bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"refs=1,5"* ]]
}

@test "case insensitive (CLOSES / fixes)" {
  run env -i PR_BODY=$'CLOSES #99\nfixes #100' bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"refs=100,99"* || "${output}" == *"refs=99,100"* ]]
}

@test "no refs → empty" {
  run env -i PR_BODY="just a regular PR" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"refs="* ]]
}

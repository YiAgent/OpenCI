#!/usr/bin/env bats
# Tests for actions/issue/detect-duplicates/extract-query.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/detect-duplicates/extract-query.sh"
}

@test "plain title returns meaningful tokens" {
  run env -i ISSUE_TITLE="Login button not working on mobile" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"login"* ]]
  [[ "${output}" == *"button"* ]]
  [[ "${output}" == *"mobile"* ]]
}

@test "strips feat: prefix" {
  run env -i ISSUE_TITLE="feat: add user authentication flow" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"user"* ]]
  [[ "${output}" == *"authentication"* ]]
  [[ "${output}" != *"feat"* ]]
}

@test "strips bug: prefix case-insensitively" {
  run env -i ISSUE_TITLE="Bug: Database connection fails on startup" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"database"* ]]
  [[ "${output}" != *"bug"* ]]
}

@test "strips docs: prefix" {
  run env -i ISSUE_TITLE="docs: Update API reference for v2" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"update"* ]]
  [[ "${output}" != *"docs"* ]]
}

@test "stop-words are filtered out" {
  run env -i ISSUE_TITLE="the authentication and the login for the user" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *" the "* ]]
  [[ "${output}" != *" and "* ]]
  [[ "${output}" != *" for "* ]]
  [[ "${output}" == *"authentication"* ]]
  [[ "${output}" == *"login"* ]]
  [[ "${output}" == *"user"* ]]
}

@test "short words (≤2 chars) are filtered out" {
  run env -i ISSUE_TITLE="An UI or to issue" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  # 'ui', 'or', 'to', 'an' are all ≤2 chars
  [[ "${output}" != *" ui "* ]]
  [[ "${output}" != *" or "* ]]
  [[ "${output}" != *" to "* ]]
  [[ "${output}" == *"issue"* ]]
}

@test "output is lowercased" {
  run env -i ISSUE_TITLE="Database Connection Error" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"database"* ]]
  [[ "${output}" != *"Database"* ]]
}

@test "at most 6 tokens returned" {
  run env -i ISSUE_TITLE="alpha bravo charlie delta echo foxtrot golf hotel" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  count=$(echo "${output}" | wc -w)
  [ "${count}" -le 6 ]
}

@test "empty title produces empty output" {
  run env -i ISSUE_TITLE="" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -z "$(echo "${output}" | tr -d ' ')" ]
}

@test "special chars are replaced with spaces" {
  run env -i ISSUE_TITLE="crash-on-startup / null-pointer" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"crash"* ]]
  [[ "${output}" == *"startup"* ]]
  [[ "${output}" == *"null"* ]]
  [[ "${output}" == *"pointer"* ]]
}

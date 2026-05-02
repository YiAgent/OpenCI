#!/usr/bin/env bats
# Tests for actions/issue/ai-triage/build-context.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/ai-triage/build-context.sh"
}

@test "produces valid JSON" {
  run env -i \
    REPO="owner/repo" \
    ISSUE_NUM="42" \
    ISSUE_TITLE="Something broke" \
    ISSUE_BODY="Details here" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  echo "${output}" | jq empty
}

@test "output contains correct repo field" {
  run env -i \
    REPO="acme/widget" \
    ISSUE_NUM="1" \
    ISSUE_TITLE="t" \
    ISSUE_BODY="b" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  repo="$(echo "${output}" | jq -r '.repo')"
  [ "${repo}" = "acme/widget" ]
}

@test "issue number is coerced to integer" {
  run env -i \
    REPO="r" \
    ISSUE_NUM="99" \
    ISSUE_TITLE="t" \
    ISSUE_BODY="b" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  num="$(echo "${output}" | jq '.issue')"
  [ "${num}" = "99" ]
  type="$(echo "${output}" | jq 'type')"
  [ "${type}" = '"object"' ]
  numtype="$(echo "${output}" | jq '.issue | type')"
  [ "${numtype}" = '"number"' ]
}

@test "title with double-quotes does not break JSON" {
  run env -i \
    REPO="r" \
    ISSUE_NUM="1" \
    ISSUE_TITLE='He said "hello"' \
    ISSUE_BODY="ok" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  echo "${output}" | jq empty
  title="$(echo "${output}" | jq -r '.title')"
  [ "${title}" = 'He said "hello"' ]
}

@test "body with newlines is preserved" {
  run env -i \
    REPO="r" \
    ISSUE_NUM="1" \
    ISSUE_TITLE="t" \
    ISSUE_BODY=$'line1\nline2' \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  echo "${output}" | jq empty
}

@test "injection attempt in title is neutralized" {
  run env -i \
    REPO="r" \
    ISSUE_NUM="1" \
    ISSUE_TITLE='$(rm -rf /); payload' \
    ISSUE_BODY="ok" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  echo "${output}" | jq empty
  title="$(echo "${output}" | jq -r '.title')"
  [ "${title}" = '$(rm -rf /); payload' ]
}

@test "output has all four required keys" {
  run env -i \
    REPO="r" \
    ISSUE_NUM="5" \
    ISSUE_TITLE="t" \
    ISSUE_BODY="b" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  for key in repo issue title body; do
    val="$(echo "${output}" | jq --arg k "$key" 'has($k)')"
    [ "${val}" = "true" ]
  done
}

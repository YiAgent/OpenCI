#!/usr/bin/env bats
# Tests for actions/_common/identify-pr-agent/identify.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/identify-pr-agent/identify.sh"
}

run_id() {
  run env -i PR_USER_LOGIN="$1" PR_HEAD_REF="$2" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "copilot-swe-agent[bot] login → copilot" {
  run_id "copilot-swe-agent[bot]" "feat/something"
  [[ "${output}" == *"agent-type=copilot"* ]]
}

@test "codex/<branch> head ref → codex" {
  run_id "alice" "codex/refactor-auth"
  [[ "${output}" == *"agent-type=codex"* ]]
}

@test "dev-agent/<id> head ref → openci" {
  run_id "alice" "dev-agent/123"
  [[ "${output}" == *"agent-type=openci"* ]]
}

@test "regular human PR → none" {
  run_id "alice" "feat/login"
  [[ "${output}" == *"agent-type=none"* ]]
}

@test "copilot login wins over branch name" {
  run_id "copilot-swe-agent[bot]" "feat/login"
  [[ "${output}" == *"agent-type=copilot"* ]]
}

@test "writes to GITHUB_OUTPUT" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i \
    GITHUB_OUTPUT="$out" PR_USER_LOGIN="alice" PR_HEAD_REF="codex/x" \
    bash "${SCRIPT}" >/dev/null
  grep -q '^agent-type=codex$' "$out"
  rm -f "$out"
}

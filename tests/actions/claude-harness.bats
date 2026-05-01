#!/usr/bin/env bats
# Tests for the resolve-prompt.sh shell logic that powers claude-harness.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/claude-harness/resolve-prompt.sh"
  ACTION_DIR="${PROJECT_ROOT}/actions/_common/claude-harness"
  WORK_DIR="$(mktemp -d)"
  export GITHUB_WORKSPACE="${WORK_DIR}"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

@test "missing task arg → exit 2" {
  run bash "${SCRIPT}" "" "" "${ACTION_DIR}"
  [ "${status}" -eq 2 ]
}

@test "missing action-dir arg → exit 2" {
  run bash "${SCRIPT}" "pr/review" "" ""
  [ "${status}" -eq 2 ]
}

@test "built-in prompt found for pr/review" {
  run bash "${SCRIPT}" "pr/review" "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/pr/review.md"* ]]
  [[ "${output}" == *"source=builtin"* ]]
}

@test "built-in prompt found for issue/triage" {
  run bash "${SCRIPT}" "issue/triage" "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/issue/triage.md"* ]]
}

@test "caller-supplied path takes priority over built-in" {
  caller_path=".agents/skills/custom-review.md"
  mkdir -p "${WORK_DIR}/.agents/skills"
  printf '# Custom\n' > "${WORK_DIR}/${caller_path}"

  run bash "${SCRIPT}" "pr/review" "${caller_path}" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${caller_path}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

@test "caller path missing → exit 1, error annotation" {
  run bash "${SCRIPT}" "pr/review" "does/not/exist.md" "${ACTION_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "no built-in for unknown task → exit 1" {
  run bash "${SCRIPT}" "unknown/task" "" "${ACTION_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "writes resolved-prompt to GITHUB_OUTPUT" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "pr/review" "" "${ACTION_DIR}" >/dev/null
  grep -q '^resolved-prompt=' "$out_file"
  grep -q '^prompt-source=builtin$' "$out_file"
  rm -f "$out_file"
}

@test "absolute caller path is honoured as-is" {
  abs_file="${WORK_DIR}/abs.md"
  printf '# abs\n' > "${abs_file}"
  run bash "${SCRIPT}" "pr/review" "${abs_file}" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${abs_file}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

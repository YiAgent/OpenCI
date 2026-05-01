#!/usr/bin/env bats
# Tests for resolve-prompt.sh — the shell logic that powers claude-harness.
#
# Signature (4 args): <task> <direct-prompt> <caller-prompt-path> <action-dir>
# Outputs to GITHUB_OUTPUT:
#   resolved-prompt-text  (non-empty when source=direct)
#   resolved-prompt-file  (non-empty when source ∈ {slash-command, caller, builtin})
#   prompt-source         (direct | slash-command | caller | builtin)

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
  run bash "${SCRIPT}" "" "" "" "${ACTION_DIR}"
  [ "${status}" -eq 2 ]
}

@test "missing action-dir arg → exit 2" {
  run bash "${SCRIPT}" "pr/review" "" "" ""
  [ "${status}" -eq 2 ]
}

@test "built-in prompt found for pr/review" {
  run bash "${SCRIPT}" "pr/review" "" "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/pr/review.md"* ]]
  [[ "${output}" == *"source=builtin"* ]]
}

@test "built-in prompt found for issue/triage" {
  run bash "${SCRIPT}" "issue/triage" "" "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/issue/triage.md"* ]]
}

@test "direct prompt text takes priority over built-in" {
  run bash "${SCRIPT}" "pr/review" "Just review this small change." "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=direct"* ]]
}

@test "slash command resolves to .claude/commands/<cmd>.md" {
  mkdir -p "${WORK_DIR}/.claude/commands"
  printf '# Heartbeat command\n' > "${WORK_DIR}/.claude/commands/heartbeat.md"
  run bash "${SCRIPT}" "pr/review" "/heartbeat" "" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=slash-command"* ]]
  [[ "${output}" == *"heartbeat.md"* ]]
}

@test "slash command without backing file → exit 1" {
  run bash "${SCRIPT}" "pr/review" "/missing-cmd" "" "${ACTION_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Slash command"* ]]
}

@test "direct prompt beats caller-supplied path" {
  mkdir -p "${WORK_DIR}/.agents/skills"
  printf '# caller\n' > "${WORK_DIR}/.agents/skills/x.md"
  run bash "${SCRIPT}" "pr/review" "literal text" ".agents/skills/x.md" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=direct"* ]]
}

@test "caller-supplied path takes priority over built-in" {
  caller_path=".agents/skills/custom-review.md"
  mkdir -p "${WORK_DIR}/.agents/skills"
  printf '# Custom\n' > "${WORK_DIR}/${caller_path}"

  run bash "${SCRIPT}" "pr/review" "" "${caller_path}" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${caller_path}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

@test "caller path missing → exit 1, error annotation" {
  run bash "${SCRIPT}" "pr/review" "" "does/not/exist.md" "${ACTION_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "no built-in for unknown task → exit 1" {
  run bash "${SCRIPT}" "unknown/task" "" "" "${ACTION_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "writes resolved-prompt-file + prompt-source to GITHUB_OUTPUT (builtin)" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "pr/review" "" "" "${ACTION_DIR}" >/dev/null
  grep -q '^resolved-prompt-file=.*prompts/pr/review.md$' "$out_file"
  grep -q '^prompt-source=builtin$' "$out_file"
  # Direct text path should be empty when source=builtin.
  grep -q '^resolved-prompt-text=$' "$out_file"
  rm -f "$out_file"
}

@test "writes resolved-prompt-text and resolved-prompt-file on direct input" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "pr/review" "Hello world" "" "${ACTION_DIR}" >/dev/null
  grep -q '^resolved-prompt-text=Hello world$' "$out_file"
  grep -q '^prompt-source=direct$' "$out_file"
  # Direct text is also written to a temp file so claude-code-action always gets a file path
  grep -qE '^resolved-prompt-file=/.+' "$out_file"
  rm -f "$out_file"
}

@test "absolute caller path is honoured as-is" {
  abs_file="${WORK_DIR}/abs.md"
  printf '# abs\n' > "${abs_file}"
  run bash "${SCRIPT}" "pr/review" "" "${abs_file}" "${ACTION_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${abs_file}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

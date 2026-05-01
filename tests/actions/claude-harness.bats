#!/usr/bin/env bats
# Tests for resolve-prompt.sh — the shell logic that powers claude-harness.
#
# Signature (5 args): <task> <direct-prompt> <caller-prompt-path> <action-dir> <context-json>
# Outputs to GITHUB_OUTPUT:
#   prompt-source   (direct | slash-command | caller | builtin)
#   prompt-path     (absolute file path; empty when source=direct)
#   prompt          (multi-line, Mustache-rendered final text)

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/claude-harness/resolve-prompt.sh"
  ACTION_DIR="${PROJECT_ROOT}/actions/_common/claude-harness"
  WORK_DIR="$(mktemp -d)"
  export GITHUB_WORKSPACE="${WORK_DIR}"
  unset GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_EVENT_NAME GITHUB_REF GITHUB_SHA GITHUB_ACTOR
}

teardown() {
  rm -rf "${WORK_DIR}"
}

# Helper: extract a single-line key from $GITHUB_OUTPUT
out_kv() {
  local file="$1" key="$2"
  grep -m1 "^${key}=" "$file" | sed "s/^${key}=//"
}

# Helper: extract multi-line heredoc value (key<<DELIM ... DELIM)
out_multiline() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block=0 }
    !in_block && $0 ~ "^"k"<<" { delim=substr($0, length(k)+3); in_block=1; next }
    in_block && $0 == delim { exit }
    in_block { print }
  ' "$file"
}

@test "missing task arg → exit 2" {
  run bash "${SCRIPT}" "" "" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 2 ]
}

@test "missing action-dir arg → exit 2" {
  run bash "${SCRIPT}" "pr/review" "" "" "" "{}"
  [ "${status}" -eq 2 ]
}

@test "built-in prompt found for pr/review" {
  run bash "${SCRIPT}" "pr/review" "" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/pr/review.md"* ]]
  [[ "${output}" == *"source=builtin"* ]]
}

@test "built-in prompt found for issue/triage" {
  run bash "${SCRIPT}" "issue/triage" "" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"prompts/issue/triage.md"* ]]
}

@test "direct prompt text takes priority over built-in" {
  run bash "${SCRIPT}" "pr/review" "Just review this small change." "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=direct"* ]]
}

@test "slash command resolves to .claude/commands/<cmd>.md" {
  mkdir -p "${WORK_DIR}/.claude/commands"
  printf '# Heartbeat command\n' > "${WORK_DIR}/.claude/commands/heartbeat.md"
  run bash "${SCRIPT}" "pr/review" "/heartbeat" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=slash-command"* ]]
  [[ "${output}" == *"heartbeat.md"* ]]
}

@test "slash command without backing file → exit 1" {
  run bash "${SCRIPT}" "pr/review" "/missing-cmd" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Slash command"* ]]
}

@test "direct prompt beats caller-supplied path" {
  mkdir -p "${WORK_DIR}/.agents/skills"
  printf '# caller\n' > "${WORK_DIR}/.agents/skills/x.md"
  run bash "${SCRIPT}" "pr/review" "literal text" ".agents/skills/x.md" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source=direct"* ]]
}

@test "caller-supplied path takes priority over built-in" {
  caller_path=".agents/skills/custom-review.md"
  mkdir -p "${WORK_DIR}/.agents/skills"
  printf '# Custom\n' > "${WORK_DIR}/${caller_path}"

  run bash "${SCRIPT}" "pr/review" "" "${caller_path}" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${caller_path}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

@test "caller path missing → exit 1, error annotation" {
  run bash "${SCRIPT}" "pr/review" "" "does/not/exist.md" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "no built-in for unknown task → exit 1" {
  run bash "${SCRIPT}" "unknown/task" "" "" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Prompt Not Found"* ]]
}

@test "writes prompt-source + prompt-path + prompt to GITHUB_OUTPUT (builtin)" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "pr/review" "" "" "${ACTION_DIR}" "{}" >/dev/null
  [ "$(out_kv "$out_file" prompt-source)" = "builtin" ]
  [[ "$(out_kv "$out_file" prompt-path)" == *"prompts/pr/review.md" ]]
  body="$(out_multiline "$out_file" prompt)"
  [ -n "$body" ]
  rm -f "$out_file"
}

@test "direct text becomes the prompt body verbatim" {
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "Hello world" "" "${ACTION_DIR}" "{}" >/dev/null
  [ "$(out_kv "$out_file" prompt-source)" = "direct" ]
  [ "$(out_kv "$out_file" prompt-path)" = "" ]
  [ "$(out_multiline "$out_file" prompt)" = "Hello world" ]
  rm -f "$out_file"
}

@test "absolute caller path is honoured as-is" {
  abs_file="${WORK_DIR}/abs.md"
  printf '# abs\n' > "${abs_file}"
  run bash "${SCRIPT}" "any" "" "${abs_file}" "${ACTION_DIR}" "{}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${abs_file}"* ]]
  [[ "${output}" == *"source=caller"* ]]
}

# ── Mustache substitution ────────────────────────────────────────────────────

@test "auto-injects {{repo}} from GITHUB_REPOSITORY" {
  caller="${WORK_DIR}/p.md"
  printf 'Repo is {{repo}} done.\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_REPOSITORY="myorg/myrepo" \
    GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" "{}" >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  [[ "$body" == *"Repo is myorg/myrepo done."* ]]
  rm -f "$out_file"
}

@test "auto-injects {{run_url}} from GITHUB_REPOSITORY+RUN_ID" {
  caller="${WORK_DIR}/p.md"
  printf 'See {{run_url}}\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_REPOSITORY="myorg/myrepo" GITHUB_RUN_ID="42" GITHUB_SERVER_URL="https://github.com" \
    GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" "{}" >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  [[ "$body" == *"https://github.com/myorg/myrepo/actions/runs/42"* ]]
  rm -f "$out_file"
}

@test "context JSON keys are substituted" {
  caller="${WORK_DIR}/p.md"
  printf 'Version: {{version}}, mode: {{mode}}.\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" \
    '{"version":"v1.2.3","mode":"dry-run"}' >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  [[ "$body" == *"Version: v1.2.3, mode: dry-run."* ]]
  rm -f "$out_file"
}

@test "context overrides auto-injected vars" {
  caller="${WORK_DIR}/p.md"
  printf '{{repo}}\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_REPOSITORY="auto/repo" \
    GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" \
    '{"repo":"override/repo"}' >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  [[ "$body" == *"override/repo"* ]]
  [[ "$body" != *"auto/repo"* ]]
  rm -f "$out_file"
}

@test "unmatched {{placeholder}} is left intact (no jq error)" {
  caller="${WORK_DIR}/p.md"
  printf 'Unknown: {{nope}}\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" "{}" >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  [[ "$body" == *"Unknown: {{nope}}"* ]]
  rm -f "$out_file"
}

@test "multi-line prompt body is preserved exactly" {
  caller="${WORK_DIR}/p.md"
  printf 'line one\nline two\nline three {{repo}}\n' > "$caller"
  out_file="$(mktemp)"
  GITHUB_REPOSITORY="x/y" \
    GITHUB_OUTPUT="$out_file" bash "${SCRIPT}" "any" "" "$caller" "${ACTION_DIR}" "{}" >/dev/null
  body="$(out_multiline "$out_file" prompt)"
  expected=$'line one\nline two\nline three x/y'
  [ "$body" = "$expected" ]
  rm -f "$out_file"
}

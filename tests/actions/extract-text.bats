#!/usr/bin/env bats
# Tests for actions/_common/extract-text/extract-text.sh

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/extract-text/extract-text.sh"
  TMPDIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${TMPDIR}/output.txt"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TMPDIR"
}

run_extract() {
  SKIPPED="${1:-false}" EXECUTION_FILE="${2:-}" run bash "$SCRIPT"
}

# Returns everything between the text<<EOF marker and its terminator.
get_text() {
  awk '
    /^text<<__OPENCI_TEXT_EOF__$/ {capture=1; next}
    /^__OPENCI_TEXT_EOF__$/ {capture=0}
    capture {print}
  ' "$GITHUB_OUTPUT"
}

@test "skipped=true emits empty text" {
  run_extract "true"
  [ "$status" -eq 0 ]
  [ -z "$(get_text)" ]
}

@test "missing execution file emits empty text" {
  run_extract "false" "${TMPDIR}/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$(get_text)" ]
}

@test "empty execution-file input emits empty text" {
  run_extract "false" ""
  [ "$status" -eq 0 ]
  [ -z "$(get_text)" ]
}

@test "JSONL: result record .result is extracted" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"## TL;DR\nAll clear."}
JSONL
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "$(printf '## TL;DR\nAll clear.')" ]
}

@test "JSONL: falls back to last assistant text when no result field" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final report"}]}}
{"type":"result","subtype":"success","is_error":false}
JSONL
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "final report" ]
}

@test "JSONL: multiple text blocks in one assistant message are concatenated" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"part one "},{"type":"text","text":"part two"}]}}
{"type":"result","subtype":"success","is_error":false}
JSONL
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "part one part two" ]
}

@test "single JSON object with .result is extracted" {
  local ef="${TMPDIR}/exec.json"
  echo '{"result":"single object report"}' > "$ef"
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "single object report" ]
}

@test "plain text file is passed through verbatim" {
  local ef="${TMPDIR}/exec.txt"
  printf 'just some markdown\nsecond line\n' > "$ef"
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "$(printf 'just some markdown\nsecond line')" ]
}

@test "result record is preferred over earlier assistant text" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"intermediate"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"authoritative"}
JSONL
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ "$(get_text)" = "authoritative" ]
}

@test "transcript with no text anywhere emits empty text" {
  local ef="${TMPDIR}/exec.jsonl"
  cat >"$ef" <<'JSONL'
{"type":"system","subtype":"init","message":"Claude Code initialized"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1234}
JSONL
  run_extract "false" "$ef"
  [ "$status" -eq 0 ]
  [ -z "$(get_text)" ]
}

#!/usr/bin/env bats
# Tests for actions/_common/api-key-gate/action.yml shell logic

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${TMPDIR}/output.txt"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TMPDIR"
}

run_gate() {
  # Inline the gate logic to avoid action runner dependency
  API_KEY="$1" run bash -c '
    if [ -z "$API_KEY" ]; then
      echo "skip=true" >> "$GITHUB_OUTPUT"
    else
      echo "skip=false" >> "$GITHUB_OUTPUT"
    fi
  '
}

@test "empty key outputs skip=true" {
  run_gate ""
  [ "$status" -eq 0 ]
  grep -q "^skip=true$" "$GITHUB_OUTPUT"
}

@test "present key outputs skip=false" {
  run_gate "sk-ant-abc123"
  [ "$status" -eq 0 ]
  grep -q "^skip=false$" "$GITHUB_OUTPUT"
}

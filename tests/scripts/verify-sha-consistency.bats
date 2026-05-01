#!/usr/bin/env bats
# Tests for .github/scripts/verify-sha-consistency.sh
#
# Each test sets up a tiny fake repo with a manifest + manifest-pending +
# a single fixture workflow, then runs the script with REPO_ROOT pointing
# at that fixture and asserts on exit code + stderr/stdout content.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/.github/scripts/verify-sha-consistency.sh"
  TMPDIR_TEST="$(mktemp -d)"
  REPO="${TMPDIR_TEST}/repo"
  mkdir -p "${REPO}/.github/workflows" "${REPO}/.github/scripts" "${REPO}/actions"

  # Minimal valid manifest.yml + manifest-pending.yml shared by most tests.
  cat >"${REPO}/manifest.yml" <<'YAML'
version: "1.7"
deps:
  actions/checkout:            "11bd71901bbe5b1630ceea73d27597364c9af683"
  step-security/harden-runner: "f808768d1510423e83855289c910610ca9b43176"
YAML

  cat >"${REPO}/manifest-pending.yml" <<'YAML'
version: "1.7"
deps:
  actions/setup-node: "<待验证 SHA>"
YAML

  export REPO_ROOT="${REPO}"
  export MANIFEST="${REPO}/manifest.yml"
  export PENDING="${REPO}/manifest-pending.yml"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

write_workflow() {
  local name="$1"
  local body="$2"
  printf '%s' "${body}" >"${REPO}/.github/workflows/${name}"
}

@test "exit 0 on a clean repo with no uses: references" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Checked 0 uses"* ]]
}

@test "exit 0 when SHA matches manifest" {
  write_workflow good.yml '
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - uses: step-security/harden-runner@f808768d1510423e83855289c910610ca9b43176
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Checked 2 uses, 0 error"* ]]
}

@test "rejects SHA mismatch (one bit flipped)" {
  # Last char flipped: ...683 -> ...684
  write_workflow bad.yml '
jobs:
  x:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af684
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"SHA mismatch"* ]]
}

@test "rejects @v* tag references" {
  write_workflow tag.yml '
jobs:
  x:
    steps:
      - uses: actions/checkout@v4
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"non-SHA uses"* ]]
}

@test "rejects @main branch references" {
  write_workflow main-ref.yml '
jobs:
  x:
    steps:
      - uses: actions/checkout@main
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"non-SHA uses"* ]]
}

@test "rejects pending-manifest entries that are referenced" {
  # Pretend setup-node has been verified in workflow but is still pending.
  write_workflow pending.yml '
jobs:
  x:
    steps:
      - uses: actions/setup-node@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Migrate after verification"* ]]
}

@test "rejects deprecated actions (Appendix B.2)" {
  # actions/stale is deprecated.
  write_workflow stale.yml '
jobs:
  x:
    steps:
      - uses: actions/stale@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Deprecated Action"* ]]
}

@test "rejects unknown actions not present in either manifest" {
  write_workflow unknown.yml '
jobs:
  x:
    steps:
      - uses: random/action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Unknown Action"* ]]
}

@test "allows local references (./actions/foo)" {
  mkdir -p "${REPO}/actions/foo"
  cat >"${REPO}/actions/foo/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: echo ok
YAML
  write_workflow local.yml '
jobs:
  x:
    steps:
      - uses: ./actions/foo
'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "scans actions/ subtree, not only workflows/" {
  mkdir -p "${REPO}/actions/_common/wrap"
  cat >"${REPO}/actions/_common/wrap/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: actions/checkout@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
YAML
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"SHA mismatch"* ]]
}

@test "rejects manifest.yml that itself contains placeholder SHA" {
  cat >"${REPO}/manifest.yml" <<'YAML'
version: "1.7"
deps:
  actions/checkout: "1234567890abcdef"
YAML
  run bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Invalid Manifest SHA"* ]]
}

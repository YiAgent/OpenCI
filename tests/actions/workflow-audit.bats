#!/usr/bin/env bats
# Tests for .github/scripts/workflow-audit.sh — each rule has a positive
# fixture (should fire) and a negative one (must not fire). Each scratch
# layout reuses the auditor's WORKFLOWS_DIR / ACTIONS_DIR / SCRIPTS_DIR
# overrides so the auditor sees only fixture content.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AUDIT="${PROJECT_ROOT}/.github/scripts/workflow-audit.sh"
  TMPDIR="$(mktemp -d)"
  WF="${TMPDIR}/wf"
  ACT="${TMPDIR}/act"
  SCR="${TMPDIR}/scr"
  mkdir -p "$WF" "$ACT" "$SCR"
  # required by R01 + W04 lookups
  cp "${PROJECT_ROOT}/manifest.yml" "${TMPDIR}/manifest.yml"
}

teardown() {
  rm -rf "$TMPDIR"
}

run_audit() {
  REPO_ROOT="$TMPDIR" \
  WORKFLOWS_DIR="$WF" \
  ACTIONS_DIR="$ACT" \
  SCRIPTS_DIR="$SCR" \
    bash "$AUDIT"
}

# ── W01 — empty permissions block at workflow level ──────────────────────────

@test "W01 fires on permissions: {} at workflow level" {
  cat >"$WF/example.yml" <<'YAML'
name: example
on: { push: { branches: [main] } }
permissions: {}
jobs: {}
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"W01"* ]]
}

@test "W01 ignores reusable-* files" {
  cat >"$WF/reusable-foo.yml" <<'YAML'
name: foo
on: { workflow_call: {} }
permissions: {}
jobs: {}
YAML
  run run_audit
  # Audit may still surface other rules, but no W01
  [[ "$output" != *"W01"* ]]
}

# ── W02 — invalid permission scope (e.g. 'workflows') ────────────────────────

@test "W02 fires on workflows: write" {
  cat >"$WF/bad-perm.yml" <<'YAML'
name: bad
on: { push: { branches: [main] } }
permissions:
  contents: read
  workflows: write
jobs: {}
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"W02"* ]]
}

@test "W02 accepts valid scopes" {
  cat >"$WF/good-perm.yml" <<'YAML'
name: good
on: { push: { branches: [main] } }
permissions:
  contents: write
  pull-requests: write
  id-token: write
jobs: {}
YAML
  run run_audit
  [[ "$output" != *"W02"* ]]
}

# ── W03 — entry + reusable share concurrency.group ───────────────────────────

@test "W03 fires when reusable redeclares the same concurrency group" {
  local sha="0000000000000000000000000000000000000000"
  cat >"$WF/entry.yml" <<'YAML'
name: entry
on: { push: { branches: [main] } }
permissions: { contents: read }
concurrency:
  group: entry-${{ github.ref }}
jobs:
  go:
    uses: ./.github/workflows/reusable-foo.yml@__SHA__
YAML
  sed -i.bak "s|__SHA__|${sha}|" "$WF/entry.yml" && rm -f "$WF/entry.yml.bak"
  cat >"$WF/reusable-foo.yml" <<'YAML'
name: reusable-foo
on: { workflow_call: {} }
permissions: {}
concurrency:
  group: entry-${{ github.ref }}
jobs:
  noop:
    runs-on: ubuntu-latest
    steps: [{ run: "echo hi" }]
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"W03"* ]]
}

@test "W03 silent when reusable uses a different group" {
  local sha="0000000000000000000000000000000000000000"
  cat >"$WF/entry.yml" <<'YAML'
name: entry
on: { push: { branches: [main] } }
permissions: { contents: read }
concurrency:
  group: entry-${{ github.ref }}
jobs:
  go:
    uses: ./.github/workflows/reusable-foo.yml@__SHA__
YAML
  sed -i.bak "s|__SHA__|${sha}|" "$WF/entry.yml" && rm -f "$WF/entry.yml.bak"
  cat >"$WF/reusable-foo.yml" <<'YAML'
name: reusable-foo
on: { workflow_call: {} }
permissions: {}
concurrency:
  group: foo-${{ github.run_id }}
jobs:
  noop:
    runs-on: ubuntu-latest
    steps: [{ run: "echo hi" }]
YAML
  run run_audit
  [[ "$output" != *"W03"* ]]
}

# ── A01 — dynamic uses ref in composite action ───────────────────────────────

@test "A01 fires when uses: ref interpolates an expression" {
  mkdir -p "$ACT/bad"
  cat >"$ACT/bad/action.yml" <<'YAML'
name: bad
description: dynamic uses
runs:
  using: composite
  steps:
    - id: pick
      shell: bash
      run: echo "v=javascript" >> "$GITHUB_OUTPUT"
    - uses: vendor/lib/${{ steps.pick.outputs.v }}@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"A01"* ]]
}

@test "A01 silent on static uses ref" {
  mkdir -p "$ACT/good"
  cat >"$ACT/good/action.yml" <<'YAML'
name: good
description: static uses
runs:
  using: composite
  steps:
    - uses: vendor/lib/javascript@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
YAML
  run run_audit
  [[ "$output" != *"A01"* ]]
}

# ── A02 — secrets.X expression inside composite YAML ─────────────────────────

@test "A02 fires on secrets.X anywhere in composite" {
  mkdir -p "$ACT/bad"
  cat >"$ACT/bad/action.yml" <<'YAML'
name: bad
description: leaks secrets context
inputs:
  k:
    description: |
      Pass as ${{ secrets.MY_SECRET }} from caller.
    required: false
    default: ""
runs:
  using: composite
  steps:
    - run: echo
      shell: bash
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"A02"* ]]
}

@test "A02 silent on plain prose docs" {
  mkdir -p "$ACT/good"
  cat >"$ACT/good/action.yml" <<'YAML'
name: good
description: clean
inputs:
  k:
    description: |
      Pass as a secret named MY_SECRET.
    required: false
    default: ""
runs:
  using: composite
  steps:
    - run: echo
      shell: bash
YAML
  run run_audit
  [[ "$output" != *"A02"* ]]
}

# ── R01 — reusable verify-sha checkout missing fetch-depth: 0 ─────────────────

@test "R01 fires when verify-sha-consistency.sh runs without fetch-depth: 0" {
  cat >"$WF/reusable-bad.yml" <<'YAML'
name: bad
on: { workflow_call: {} }
permissions: {}
jobs:
  vsha:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with: { persist-credentials: false }
      - run: bash .github/scripts/verify-sha-consistency.sh
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"R01"* ]]
}

@test "R01 silent when fetch-depth: 0 is set" {
  cat >"$WF/reusable-good.yml" <<'YAML'
name: good
on: { workflow_call: {} }
permissions: {}
jobs:
  vsha:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          persist-credentials: false
          fetch-depth: 0
      - run: bash .github/scripts/verify-sha-consistency.sh
YAML
  run run_audit
  [[ "$output" != *"R01"* ]]
}

# ── S01 — pipefail + echo|awk … exit ─────────────────────────────────────────

@test "S01 fires on echo \$VAR | awk … exit under pipefail" {
  cat >"$SCR/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
data=$(printf 'a\tb\nc\td\n')
val="$(echo "$data" | awk -F'\t' '$1 == "a" { print $2; exit }')"
echo "$val"
SH
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"S01"* ]]
}

@test "S01 silent on while-read here-string version" {
  cat >"$SCR/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
data=$(printf 'a\tb\nc\td\n')
val=""
while IFS=$'\t' read -r k v; do
  if [ "$k" = "a" ]; then val="$v"; break; fi
done <<<"$data"
echo "$val"
SH
  run run_audit
  [[ "$output" != *"S01"* ]]
}

# ── T01 — self-test/maintenance must include .github/scripts/** ──────────────

@test "T01 fires when ci-self-test.yml omits scripts/** from paths" {
  cat >"$WF/ci-self-test.yml" <<'YAML'
name: ci-self-test
on:
  push:
    paths:
      - ".github/workflows/**"
permissions: { contents: read }
jobs: {}
YAML
  run run_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"T01"* ]]
}

@test "T01 silent when scripts/** is included" {
  cat >"$WF/ci-self-test.yml" <<'YAML'
name: ci-self-test
on:
  push:
    paths:
      - ".github/workflows/**"
      - ".github/scripts/**"
permissions: { contents: read }
jobs: {}
YAML
  run run_audit
  [[ "$output" != *"T01"* ]]
}

# ── Smoke — actual repo passes the auditor ───────────────────────────────────

@test "auditor is clean against the live repository" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
# workflow-integrity.bats — Automated workflow integrity tests
# Generated from workflow test reports on 2026-05-04
# Run: bats tests/actions/workflow-integrity.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
  MANIFEST="$REPO_ROOT/manifest.yml"
}

# ============================================================================
# YAML Syntax Validation
# ============================================================================

@test "all workflow files are valid YAML" {
  for f in "$WORKFLOWS_DIR"/*.yml; do
    run python3 -c "import yaml; yaml.safe_load(open('$f'))"
    [ "$status" -eq 0 ]
  done
}

# ============================================================================
# SHA Reference Consistency
# ============================================================================

@test "all workflow SHA references are 40-char hex" {
  local bad_shas
  bad_shas=$(grep -rn 'uses:.*@' "$WORKFLOWS_DIR"/*.yml \
    | grep -v 'uses:.*@[a-f0-9]\{40\}' \
    | grep -v '# ' || true)
  [ -z "$bad_shas" ]
}

@test "manifest.yml exists and is valid YAML" {
  [ -f "$MANIFEST" ]
  run python3 -c "import yaml; yaml.safe_load(open('$MANIFEST'))"
  [ "$status" -eq 0 ]
}

# ============================================================================
# File Existence Checks
# ============================================================================

@test "all reusable workflows referenced by top-level workflows exist" {
  local missing=""
  # shellcheck disable=SC2013  # word-splitting on sorted unique refs is intentional
  for ref in $(grep -h 'uses:.*\.github/workflows/' "$WORKFLOWS_DIR"/*.yml \
    | grep -v '#' \
    | sed 's/.*\.github\/workflows\///' \
    | sed 's/@.*//' \
    | sort -u); do
    if [ ! -f "$WORKFLOWS_DIR/$ref" ]; then
      missing="$missing $ref"
    fi
  done
  [ -z "$missing" ]
}

@test "all referenced scripts exist" {
  local missing=""
  # shellcheck disable=SC2013  # word-splitting on sorted unique paths is intentional
  for script in $(grep -rh '\.github/scripts/' "$WORKFLOWS_DIR"/*.yml \
    | grep -oP '\.github/scripts/[\w\-\.]+' \
    | sort -u); do
    if [ ! -f "$REPO_ROOT/$script" ]; then
      missing="$missing $script"
    fi
  done
  [ -z "$missing" ]
}

@test "all referenced local actions exist" {
  local missing=""
  # shellcheck disable=SC2013  # word-splitting on sorted unique paths is intentional
  for action_path in $(grep -rh '\./\.openci/actions/' "$WORKFLOWS_DIR"/*.yml \
    | grep -oP '\.openci/actions/[\w\-/]+' \
    | sort -u); do
    # These are resolved at runtime from the pinned SHA, so we check the local actions/ dir
    local local_path="${action_path#.openci/}"
    # Check for action.yml, action.yaml, or .sh script
    if [ ! -f "$REPO_ROOT/$local_path/action.yml" ] && \
       [ ! -f "$REPO_ROOT/$local_path/action.yaml" ] && \
       [ ! -f "$REPO_ROOT/$local_path.sh" ]; then
      missing="$missing $action_path"
    fi
  done
  [ -z "$missing" ]
}

# ============================================================================
# Permission Hygiene
# ============================================================================

@test "no workflow declares attestations:write (causes startup_failure)" {
  local bad
  bad=$(grep -rn 'attestations:.*write' "$WORKFLOWS_DIR"/*.yml || true)
  [ -z "$bad" ]
}

# ============================================================================
# Naming Consistency
# ============================================================================

@test "reusable workflow names match filenames" {
  local mismatches=""
  for f in "$WORKFLOWS_DIR"/reusable-*.yml; do
    local filename
    filename=$(basename "$f" .yml)
    local name
    name=$(grep '^name:' "$f" | head -1 | sed 's/name: *//' | tr -d '"'"'"'')
    # The name should contain a recognizable part of the filename
    local suffix="${filename#reusable-}"
    if [[ "$name" != *"$suffix"* ]] && [[ "$suffix" != *"$name"* ]]; then
      mismatches="$mismatches\n$filename -> name='$name'"
    fi
  done
  [ -z "$mismatches" ]
}

# ============================================================================
# Concurrency
# ============================================================================

@test "agent.yml concurrency group does not include run_id" {
  run grep -A 3 'group:' "$WORKFLOWS_DIR/agent.yml"
  [[ "$output" != *"run_id"* ]]
}

# ============================================================================
# on-main-bump-sha.yml
# ============================================================================

@test "on-main-bump-sha.yml has concurrency group" {
  run grep 'group:' "$WORKFLOWS_DIR/on-main-bump-sha.yml"
  [ "$status" -eq 0 ]
}

@test "on-main-bump-sha.yml git add includes actions/ directory" {
  run grep 'git add' "$WORKFLOWS_DIR/on-main-bump-sha.yml"
  [[ "$output" == *"actions"* ]]
}

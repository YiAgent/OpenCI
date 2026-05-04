#!/usr/bin/env bats
# Structural tests for ci-self-test.yml event routing and configuration.
# Also verifies issue-ops.yml structural contracts.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENTRY="${PROJECT_ROOT}/.github/workflows/ci-self-test.yml"
  REUSABLE="${PROJECT_ROOT}/.github/workflows/self-test.yml"
}

# ---------------------------------------------------------------------------
# Event entry: trigger declarations
# ---------------------------------------------------------------------------

@test "ci-self-test declares push trigger" {
  grep -q 'push:' "$ENTRY"
}

@test "push trigger filters on workflow paths" {
  grep -A10 'push:' "$ENTRY" | grep -q '\.github/workflows/\*\*'
}

@test "push trigger filters on actions paths" {
  grep -A10 'push:' "$ENTRY" | grep -q 'actions/\*\*'
}

@test "push trigger filters on manifest.yml" {
  grep -A10 'push:' "$ENTRY" | grep -q 'manifest\.yml'
}

@test "push trigger filters on actionlint config" {
  grep -A10 'push:' "$ENTRY" | grep -q 'actionlint\.yaml'
}

@test "push trigger is limited to main branch" {
  grep -A3 'push:' "$ENTRY" | grep -q 'main'
}

@test "ci-self-test declares pull_request trigger" {
  grep -q 'pull_request:' "$ENTRY"
}

@test "pull_request trigger filters on workflow paths" {
  grep -A10 'pull_request:' "$ENTRY" | grep -q '\.github/workflows/\*\*'
}

@test "pull_request trigger filters on actions paths" {
  grep -A10 'pull_request:' "$ENTRY" | grep -q 'actions/\*\*'
}

@test "ci-self-test declares workflow_dispatch trigger" {
  grep -q 'workflow_dispatch:' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Event entry: job configuration
# ---------------------------------------------------------------------------

@test "single self-test job calls reusable workflow" {
  grep -q 'uses: YiAgent/OpenCI/.github/workflows/self-test\.yml@' "$ENTRY"
}

@test "self-test job inherits secrets" {
  grep -q 'secrets: inherit' "$ENTRY"
}

@test "self-test job specifies runner" {
  grep -q 'runner:.*ubuntu-latest' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Event entry: concurrency
# ---------------------------------------------------------------------------

@test "concurrency group includes PR number" {
  grep -q 'github.event.pull_request.number' "$ENTRY"
}

@test "concurrency group falls back to ref" {
  grep -q 'github.ref' "$ENTRY"
}

@test "cancel-in-progress is true for self-test" {
  grep -q 'cancel-in-progress: true' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Event entry: permissions
# ---------------------------------------------------------------------------

@test "workflow requests contents: read permission" {
  grep -q 'contents: read' "$ENTRY"
}

@test "workflow requests security-events: write permission" {
  grep -q 'security-events: write' "$ENTRY"
}

# ---------------------------------------------------------------------------
# Event entry: negative checks
# ---------------------------------------------------------------------------

@test "ci-self-test does not declare schedule trigger" {
  run grep -q 'schedule:' "$ENTRY"
  [ "$status" -eq 1 ]
}

@test "ci-self-test does not declare repository_dispatch trigger" {
  run grep -q 'repository_dispatch:' "$ENTRY"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Reusable workflow: trigger
# ---------------------------------------------------------------------------

@test "reusable workflow declares workflow_call trigger" {
  grep -q 'workflow_call:' "$REUSABLE"
}

# ---------------------------------------------------------------------------
# Reusable workflow: lint jobs
# ---------------------------------------------------------------------------

@test "reusable workflow has actionlint job" {
  grep -q 'actionlint:' "$REUSABLE"
}

@test "reusable workflow has yamllint job" {
  grep -q 'yamllint:' "$REUSABLE"
}

@test "reusable workflow has shellcheck job" {
  grep -q 'shellcheck:' "$REUSABLE"
}

@test "reusable workflow has pyflakes job" {
  grep -q 'pyflakes:' "$REUSABLE"
}

# ---------------------------------------------------------------------------
# Reusable workflow: security jobs
# ---------------------------------------------------------------------------

@test "reusable workflow has zizmor job" {
  grep -q 'zizmor:' "$REUSABLE"
}

@test "reusable workflow has verify-sha job" {
  grep -q 'verify-sha:' "$REUSABLE"
}

@test "reusable workflow has bats-tests job" {
  grep -q 'bats-tests:' "$REUSABLE"
}

# ---------------------------------------------------------------------------
# Reusable workflow: summary
# ---------------------------------------------------------------------------

@test "reusable workflow has summary job" {
  grep -q 'summary:' "$REUSABLE"
}

@test "summary job runs always" {
  grep -A5 'summary:' "$REUSABLE" | grep -q "if: always()"
}

@test "summary job needs all check jobs" {
  grep -A2 'summary:' "$REUSABLE" | grep -q 'actionlint'
  grep -A2 'summary:' "$REUSABLE" | grep -q 'yamllint'
  grep -A2 'summary:' "$REUSABLE" | grep -q 'shellcheck'
  grep -A2 'summary:' "$REUSABLE" | grep -q 'zizmor'
  grep -A2 'summary:' "$REUSABLE" | grep -q 'verify-sha'
  grep -A2 'summary:' "$REUSABLE" | grep -q 'bats-tests'
}

# ---------------------------------------------------------------------------
# Reusable workflow: security patterns
# ---------------------------------------------------------------------------

@test "every job starts with harden-runner" {
  # Count top-level job declarations (2-space indent followed by colon)
  local jobs
  jobs=$(grep -cE '^  [a-z][a-z0-9-]+:$' "$REUSABLE")
  local harden
  harden=$(grep -c 'step-security/harden-runner' "$REUSABLE")
  [ "$harden" -ge "$jobs" ]
}

@test "all external actions use SHA pins" {
  local bad=0
  while IFS= read -r ref; do
    if ! echo "$ref" | grep -qP '@[0-9a-f]{40}$'; then
      echo "FAIL: unpinned ref: $ref"
      bad=1
    fi
  done < <(grep -oP 'uses:\s+\K[^#\s]+' "$REUSABLE" | grep -v '^\./')
  [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Issue automation structural tests
# ---------------------------------------------------------------------------

@test "issue-ops.yml declares issues trigger" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'issues:' "$issue_entry"
}

@test "issue-ops.yml declares issue_comment trigger" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'issue_comment:' "$issue_entry"
}

@test "issue-ops.yml declares schedule trigger" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'schedule:' "$issue_entry"
}

@test "issue-ops.yml declares repository_dispatch trigger" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'repository_dispatch:' "$issue_entry"
}

@test "issue-ops.yml calls reusable issue.yml" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -qE 'uses:[[:space:]]+YiAgent/OpenCI/\.github/workflows/reusable/issue\.yml@[0-9a-f]{40}' "$issue_entry"
}

@test "issue-ops.yml has lifecycle job" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'lifecycle:' "$issue_entry"
}

@test "issue-ops.yml has ingest job" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'ingest:' "$issue_entry"
}

@test "issue-ops.yml has maintenance job" {
  local issue_entry="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
  grep -q 'maintenance:' "$issue_entry"
}

@test "labeler.yml exists for auto-labeling" {
  [ -f "${PROJECT_ROOT}/.github/labeler.yml" ]
}

@test "advanced-issue-labeler.yml exists for issue templates" {
  [ -f "${PROJECT_ROOT}/.github/advanced-issue-labeler.yml" ]
}

@test "issue templates directory exists" {
  [ -d "${PROJECT_ROOT}/.github/ISSUE_TEMPLATE" ]
}

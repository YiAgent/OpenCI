#!/usr/bin/env bats
# Integration tests for the full issue ingest pipeline.
#
# Tests the data flow: fixture event → pack-ingest → validate payload shape
# without requiring Claude or GitHub APIs. Exercises the shell pipeline
# exactly as the workflow does.
#
# NOTE: On macOS these tests may hit fork limits in BATS due to subshell nesting.
# They are designed to run in CI (Ubuntu) where process limits are not constrained.
# Run with: bats tests/integration/issue-pipeline.bats

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  EXTRACT_SCRIPT="${PROJECT_ROOT}/actions/issue/extract-plan/extract-plan.sh"
  FIXTURE_DIR="${PROJECT_ROOT}/tests/agentic/fixtures"

  WORK_DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${WORK_DIR}/output.txt"
  touch "${GITHUB_OUTPUT}"
}

# run_pack_ingest: executes pack-ingest.sh from WORK_DIR so relative paths resolve correctly.
run_pack_ingest() {
  (
    cd "${WORK_DIR}" || return 1
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    bash "${PROJECT_ROOT}/actions/issue/pack-ingest/pack-ingest.sh"
  )
}

teardown() {
  rm -rf "${WORK_DIR}"
  unset GITHUB_OUTPUT
}

# ── pack-ingest: payload construction ─────────────────────────────────────────

@test "pack-ingest produces valid JSON for a bug-report issue event" {
  ISSUE_JSON="$(cat "${FIXTURE_DIR}/issues/bug-report.json" | jq -c '.issue')"
  EVENT_NAME="issues" EVENT_ACTION="opened" MODE="lifecycle" REPO="YiAgent/OpenCI" \
  ISSUE_JSON="${ISSUE_JSON}" COMMENT_JSON="null" CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" AREA_LABELS="[]" SEVERITY_LABELS="[]" DUPLICATES_JSON="[]" \
  run_pack_ingest

  run jq -e '.' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]
}

@test "pack-ingest emits issue-number output for numbered issues" {
    ISSUE_JSON="$(cat "${FIXTURE_DIR}/issues/bug-report.json" | jq -c '.issue')"
  EVENT_NAME="issues" \
  EVENT_ACTION="opened" \
  MODE="lifecycle" \
  REPO="YiAgent/OpenCI" \
  ISSUE_JSON="${ISSUE_JSON}" \
  COMMENT_JSON="null" \
  CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" \
  AREA_LABELS="[]" \
  SEVERITY_LABELS="[]" \
  DUPLICATES_JSON="[]" \
  run_pack_ingest

  grep -q "issue-number=" "${GITHUB_OUTPUT}"
  issue_num=$(grep "^issue-number=" "${GITHUB_OUTPUT}" | sed 's/issue-number=//')
  [ "$issue_num" = "9001" ]
}

@test "pack-ingest ingest.json has required top-level fields" {
    ISSUE_JSON="$(cat "${FIXTURE_DIR}/issues/feature-request.json" | jq -c '.issue')"
  EVENT_NAME="issues" \
  EVENT_ACTION="opened" \
  MODE="lifecycle" \
  REPO="YiAgent/OpenCI" \
  ISSUE_JSON="${ISSUE_JSON}" \
  COMMENT_JSON="null" \
  CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" \
  AREA_LABELS="[]" \
  SEVERITY_LABELS="[]" \
  DUPLICATES_JSON="[]" \
  run_pack_ingest

  run jq -e '.event.name' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]

  run jq -e '.repo.name' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]

  run jq -e '.issue.number' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]
}

@test "pack-ingest preserves management labels_applied array" {
    ISSUE_JSON="$(cat "${FIXTURE_DIR}/issues/security-issue.json" | jq -c '.issue')"
  EVENT_NAME="issues" \
  EVENT_ACTION="opened" \
  MODE="lifecycle" \
  REPO="YiAgent/OpenCI" \
  ISSUE_JSON="${ISSUE_JSON}" \
  COMMENT_JSON="null" \
  CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" \
  AREA_LABELS='["security"]' \
  SEVERITY_LABELS='["priority:p0"]' \
  DUPLICATES_JSON="[]" \
  run_pack_ingest

  run jq -e '.management.labels_applied | length' \
    "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "pack-ingest handles maintenance mode without issue JSON" {
    EVENT_NAME="schedule" \
  EVENT_ACTION="" \
  MODE="maintenance" \
  REPO="YiAgent/OpenCI" \
  ISSUE_JSON="null" \
  COMMENT_JSON="null" \
  CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" \
  AREA_LABELS="[]" \
  SEVERITY_LABELS="[]" \
  DUPLICATES_JSON="[]" \
  run_pack_ingest

  run jq -e '.event.mode' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance"* ]]
}

# ── extract-plan: plan extraction from agent output ───────────────────────────

@test "extract-plan correctly extracts issue-action-plan/v1 from agent output" {
  mkdir -p "${WORK_DIR}"

  GOLDEN_PLAN="$(cat "${FIXTURE_DIR}/golden-plans/valid-triage-plan.json")"
  cat > "${WORK_DIR}/execution.txt" << EOF
Running issue agent...

Analysing workspace context...

\`\`\`json
${GOLDEN_PLAN}
\`\`\`

Agent completed successfully.
EOF

  SKIPPED="false" \
  EXECUTION_FILE="${WORK_DIR}/execution.txt" \
  bash "${EXTRACT_SCRIPT}"

  grep -q "action-plan<<" "${GITHUB_OUTPUT}"
  plan_json=$(awk '/^action-plan<</{found=1; next} found && /^EOF/{exit} found{print}' \
    "${GITHUB_OUTPUT}")
  echo "$plan_json" | jq -e '.version == "issue-action-plan/v1"'
}

@test "extract-plan emits skip when SKIPPED=true" {
  SKIPPED="true" \
  EXECUTION_FILE="/dev/null" \
  bash "${EXTRACT_SCRIPT}"

  run grep "action-plan" "${GITHUB_OUTPUT}"
  # When skipped, action-plan should be empty or contain empty actions
  [ "$status" -eq 0 ]
}

@test "extract-plan handles missing JSON gracefully (empty plan fallback)" {
  mkdir -p "${WORK_DIR}"
  cat > "${WORK_DIR}/execution.txt" << 'EOF'
Agent encountered an error and produced no output.
EOF

  SKIPPED="false" \
  EXECUTION_FILE="${WORK_DIR}/execution.txt" \
  bash "${EXTRACT_SCRIPT}"

  # Should not exit non-zero — graceful fallback
  grep -q "action-plan" "${GITHUB_OUTPUT}"
}

# ── end-to-end: ingest → validate → plan round-trip ──────────────────────────

@test "full pipeline round-trip: bug-report ingest → valid plan schema" {
    # Stage 1: pack ingest
  ISSUE_JSON="$(cat "${FIXTURE_DIR}/issues/bug-report.json" | jq -c '.issue')"
  EVENT_NAME="issues" \
  EVENT_ACTION="opened" \
  MODE="lifecycle" \
  REPO="YiAgent/OpenCI" \
  ISSUE_JSON="${ISSUE_JSON}" \
  COMMENT_JSON="null" \
  CLIENT_PAYLOAD_JSON="null" \
  FORM_JSON="{}" \
  AREA_LABELS="[]" \
  SEVERITY_LABELS="[]" \
  DUPLICATES_JSON="[]" \
  run_pack_ingest

  # Validate ingest payload
  run jq -e '.issue.number == 9001' "${WORK_DIR}/agent-workspace/runtime/ingest.json"
  [ "$status" -eq 0 ]

  # Stage 2: validate golden plan (simulating agent output)
  GOLDEN="$(cat "${FIXTURE_DIR}/golden-plans/valid-triage-plan.json")"
  echo "$GOLDEN" | jq -e '.version == "issue-action-plan/v1"'
  echo "$GOLDEN" | jq -e '.actions | length > 0'
  echo "$GOLDEN" | jq -e '.reasoning | length > 0'
}

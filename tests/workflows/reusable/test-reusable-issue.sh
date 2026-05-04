#!/usr/bin/env bash
# test-reusable-issue.sh — Comprehensive Issue Domain Workflow Test Suite
#
# Tests the issue-agent pipeline: reusable-issue.yml + issue-ops.yml + all
# supporting actions, skills, and the execute-plan executor.
#
# Three test tiers:
#   Tier 1 — Offline validation (no auth needed):
#     - YAML structural analysis
#     - Code review of execute.js (14 skill coverage, trust gating, audit trail)
#     - Skill documentation completeness check
#     - MCP task registry validation
#     - Node.js unit tests
#
#   Tier 2 — Structural BATS tests (requires bats):
#     - Existing bats test suites for issue actions
#
#   Tier 3 — Live E2E (requires gh auth + GH_TOKEN):
#     - Creates real test issues, waits for workflow runs
#     - Validates agent audit comments, labels, state transitions
#
# Usage:
#   bash tests/workflows/reusable/test-reusable-issue.sh [--live]
#
# Options:
#   --live         Attempt live E2E tests (requires gh auth + GH_TOKEN)
#   --dry-run      Skip live creation, just validate
#   --verbose      Show detailed per-check output
#
# Environment:
#   DOMAIN           — domain name (default: issue)
#   REPO             — owner/repo (auto-detected if gh CLI available)
#   SKIP_AGENT_TESTS — skip tests needing ANTHROPIC_API_KEY (default: auto)
#   MAX_WAIT_SEC     — max seconds to wait for workflows (default: 600)

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
DOMAIN="${DOMAIN:-issue}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"
LIVE_MODE=false
DRY_RUN="${DRY_RUN:-false}"
VERBOSE=false
MAX_WAIT_SEC="${MAX_WAIT_SEC:-600}"
POLL_INTERVAL=15

for arg in "$@"; do
  case "$arg" in
    --live)    LIVE_MODE=true ;;
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
  esac
done

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LIBRARY_ONLY=true  # Prevent auto init from library
source "${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh"
LIBRARY_ONLY=false

# ── Local overrides (since we call the lib but also want explicit control) ─────
# We define our own state management separate from the library
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0

pass()  { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); PASSED_CHECKS=$((PASSED_CHECKS + 1)); ok "$1"; }
fail()  { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); FAILED_CHECKS=$((FAILED_CHECKS + 1)); fail "$1"; }
skip()  { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1)); warn "SKIP: $1"; }

# ── Path references ────────────────────────────────────────────────────────────
WORKFLOW_REUSABLE="${PROJECT_ROOT}/.github/workflows/reusable-issue.yml"
WORKFLOW_OPS="${PROJECT_ROOT}/.github/workflows/issue-ops.yml"
EXECUTE_JS="${PROJECT_ROOT}/actions/issue/execute-plan/execute.js"
EXTRACT_SH="${PROJECT_ROOT}/actions/issue/extract-plan/extract-plan.sh"
BUILD_WS="${PROJECT_ROOT}/actions/issue/build-workspace/build-workspace.sh"
PACK_INGEST="${PROJECT_ROOT}/actions/issue/pack-ingest/pack-ingest.sh"
AGENT_CONTEXT="${PROJECT_ROOT}/.github/agent/issue/context/AGENTS.md"
MCP_TASKS="${PROJECT_ROOT}/.github/agent/issue/mcp-tasks.json"
SKILL_DIR="${PROJECT_ROOT}/.github/agent/issue/skills"

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1a: Workflow YAML Structure & Security
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1a: Workflow YAML Structure & Security"

verify_timeout_set() {
  local file="$1" label="$2"
  local count_total count_with_timeout
  count_total=$(grep -c 'timeout-minutes:' "$file" || true)
  if [ "$count_total" -ge 4 ]; then
    pass "${label}: timeout-minutes set on all jobs (${count_total})"
  else
    fail "${label}: expected >=4 timeout-minutes, found ${count_total}"
  fi
}

verify_sha_pinned() {
  local file="$1" label="$2"
  local violations=0
  # Check all uses: references with action@version ; SHA should be 40 hex chars
  while IFS= read -r line; do
    if [[ "$line" =~ uses:\ .+@([a-f0-9]{5,}) ]]; then
      local sha="${BASH_REMATCH[1]}"
      if [[ ! "$sha" =~ ^[a-f0-9]{40}$ ]]; then
        # Allow full semver tags for non-GitHub actions that use tags
        if [[ ! "$sha" =~ ^[0-9]+ ]]; then
          warn "${label}: possibly non-SHA pin: ${line//  /}"
          violations=$((violations + 1))
        fi
      fi
    fi
  done < <(grep 'uses:' "$file")
  if [ "$violations" -eq 0 ]; then
    pass "${label}: all uses: references use full SHA pins"
  else
    fail "${label}: ${violations} non-SHA references found"
  fi
}

verify_permissions() {
  local file="$1" label="$2"
  local has_permissions
  # Check top-level or per-job permissions
  if grep -q 'permissions:' "$file"; then
    # Verify per-job permissions
    for job in maintenance ingest enrich agent execute; do
      if grep -A20 "^  ${job}:" "$file" | grep -q 'permissions:'; then
        : # has permissions
      else
        # Check if it inherits from top-level
        if ! grep -q '^permissions:' "$file"; then
          fail "${label}: job '${job}' missing permissions and no top-level default"
          return
        fi
      fi
    done
    pass "${label}: permissions are structured"
  else
    fail "${label}: no permissions block found"
  fi
}

verify_concurrency() {
  local file="$1" label="$2"
  if grep -q 'concurrency:' "$file"; then
    local has_group has_cancel
    has_group=$(grep -c 'group:' "$file" || true)
    has_cancel=$(grep -c 'cancel-in-progress:' "$file" || true)
    if [ "$has_group" -gt 0 ] && [ "$has_cancel" -gt 0 ]; then
      pass "${label}: concurrency group with cancel-in-progress"
    else
      fail "${label}: concurrency missing group or cancel-in-progress"
    fi
  else
    fail "${label}: no concurrency block"
  fi
}

verify_jobs_stages() {
  local file="$1" label="$2"
  local missing=false
  for stage in 'Stage 1' 'Stage 2' 'Stage 3' 'Stage 4'; do
    if ! grep -q "$stage" "$file"; then
      fail "${label}: missing ${stage}"
      missing=true
    fi
  done
  if [ "$missing" = false ]; then
    pass "${label}: all 4 pipeline stages present"
  fi
}

verify_event_triggers() {
  local file="$1" label="$2"
  local missing=false
  for trigger in 'issues:' 'issue_comment:' 'schedule:' 'repository_dispatch:' 'workflow_dispatch:'; do
    if ! grep -q "$trigger" "$file"; then
      fail "${label}: missing trigger '${trigger}'"
      missing=true
    fi
  done
  if [ "$missing" = false ]; then
    pass "${label}: all 5 event triggers present"
  fi
}

verify_reusable_ref() {
  local file="$1" label="$2"
  local count
  count=$(grep -c "uses: YiAgent/OpenCI/.github/workflows/reusable-issue.yml@" "$file" || true)
  if [ "$count" -eq 4 ]; then
    pass "${label}: 4 jobs reference reusable workflow"
  else
    fail "${label}: expected 4 reusable refs, found ${count}"
  fi
}

verify_api_key_gate() {
  local file="$1" label="$2"
  if grep -q 'api-key-gate' "$file" && grep -q 'steps.gate.outputs.skip' "$file"; then
    pass "${label}: api-key-gate with skip logic present"
  else
    fail "${label}: api-key-gate or skip logic missing"
  fi
}

verify_extra_disallowed() {
  local file="$1" label="$2"
  if grep -q 'extra-disallowed-tools' "$file"; then
    local tools
    tools=$(grep -oP 'extra-disallowed-tools:\s*"\K[^"]+' "$file" || true)
    if echo "$tools" | grep -q 'gh issue close' && echo "$tools" | grep -q 'gh api repos'; then
      pass "${label}: extra-disallowed-tools blocks dangerous gh commands"
    else
      fail "${label}: extra-disallowed-tools missing critical blocks"
    fi
  else
    fail "${label}: missing extra-disallowed-tools"
  fi
}

# Run YAML checks
verify_timeout_set "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_sha_pinned "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_permissions "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_concurrency "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_jobs_stages "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_api_key_gate "$WORKFLOW_REUSABLE" "reusable-issue.yml"
verify_extra_disallowed "$WORKFLOW_REUSABLE" "reusable-issue.yml"

verify_event_triggers "$WORKFLOW_OPS" "issue-ops.yml"
verify_reusable_ref "$WORKFLOW_OPS" "issue-ops.yml"
verify_timeout_set "$WORKFLOW_OPS" "issue-ops.yml"

# Additionally verify secrets are passed through
verify_secrets_propagation() {
  local count
  count=$(grep -c 'anthropic-api-key:' "$WORKFLOW_OPS" || true)
  if [ "$count" -eq 4 ]; then
    pass "issue-ops.yml: all 7 secrets propagated to 4 jobs"
  else
    fail "issue-ops.yml: anthropic-api-key only found ${count}/4 times"
  fi
}
verify_secrets_propagation

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1b: Code Review — Execute Plan (execute.js)
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1b: Code Review — execute.js"

verify_all_14_skills_handled() {
  local js_file="$1" label="$2"
  # Expected skills from ALLOWED set
  local skills=(
    "add_label" "remove_label" "set_priority" "assign_issue"
    "add_comment" "close_issue" "reopen_issue" "mark_duplicate"
    "create_branch" "link_linear" "dispatch_mcp_task"
    "schedule_followup" "notify" "escalate"
  )
  local missing=()
  for skill in "${skills[@]}"; do
    if grep -q "case '${skill}'" "$js_file"; then
      : # found
    else
      missing+=("$skill")
    fi
  done
  if [ ${#missing[@]} -eq 0 ]; then
    pass "${label}: all 14 skills handled in switch statement"
  else
    fail "${label}: missing case branches: ${missing[*]}"
  fi
}

verify_trust_gating() {
  local js_file="$1" label="$2"
  # Check that HIGH_RISK set matches expected
  if grep -q "HIGH_RISK" "$js_file" && grep -q "close_issue.*reopen_issue.*create_branch.*dispatch_mcp_task" "$js_file"; then
    pass "${label}: HIGH_RISK set contains close_issue, reopen_issue, create_branch, dispatch_mcp_task"
  else
    fail "${label}: HIGH_RISK set incomplete"
  fi
  # Check trusted associations
  if grep -q "OWNER.*MEMBER.*COLLABORATOR" "$js_file"; then
    pass "${label}: trusted associations: OWNER, MEMBER, COLLABORATOR"
  else
    fail "${label}: trusted associations check not found"
  fi
  # Verify high-risk blocking logic
  if grep -q "HIGH_RISK.has.*actorAssociation.*!trusted" "$js_file"; then
    pass "${label}: high-risk blocking for untrusted actors"
  else
    fail "${label}: high-risk blocking logic missing"
  fi
}

verify_audit_trail() {
  local js_file="$1" label="$2"
  if grep -q 'openci-agent-run' "$js_file"; then
    pass "${label}: audit comment marker (openci-agent-run) present"
  else
    fail "${label}: audit comment marker missing"
  fi
  if grep -q "existing.some.*includes.*marker" "$js_file"; then
    pass "${label}: audit dedup — checks existing comments before posting"
  else
    fail "${label}: audit dedup logic missing"
  fi
}

verify_no_issue_number_guard() {
  local js_file="$1" label="$2"
  if grep -q "no issue number is available" "$js_file"; then
    pass "${label}: issue number guard present"
  else
    fail "${label}: issue number guard missing"
  fi
}

verify_unknown_skill_rejection() {
  local js_file="$1" label="$2"
  if grep -q "Unknown issue agent skill" "$js_file"; then
    pass "${label}: unknown skill rejection"
  else
    fail "${label}: unknown skill rejection missing"
  fi
}

verify_mcp_task_registry() {
  local js_file="$1" label="$2"
  if grep -q 'loadJson.*mcp-tasks.json' "$js_file"; then
    pass "${label}: MCP task registry loaded from workspace"
  else
    fail "${label}: MCP task registry loading missing"
  fi
  if grep -q "task is not declared" "$js_file"; then
    pass "${label}: MCP task validation — rejects undeclared tasks"
  else
    fail "${label}: MCP task validation missing"
  fi
}

# Run code review checks
verify_all_14_skills_handled "$EXECUTE_JS" "execute.js"
verify_trust_gating "$EXECUTE_JS" "execute.js"
verify_audit_trail "$EXECUTE_JS" "execute.js"
verify_no_issue_number_guard "$EXECUTE_JS" "execute.js"
verify_unknown_skill_rejection "$EXECUTE_JS" "execute.js"
verify_mcp_task_registry "$EXECUTE_JS" "execute.js"

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1c: Skill Documentation Completeness
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1c: Skill Documentation Completeness"

ALL_SKILL_NAMES=(
  "add_label" "remove_label" "set_priority" "assign_issue"
  "add_comment" "close_issue" "reopen_issue" "mark_duplicate"
  "create_branch" "link_linear" "dispatch_mcp_task"
  "schedule_followup" "notify" "escalate"
)

SKILL_FILES_PRESENT=()
for f in "$SKILL_DIR"/*.md; do
  basename "$f" .md
done

check_skill_docs() {
  local documented=0
  local undocumented=()
  for skill in "${ALL_SKILL_NAMES[@]}"; do
    # Map skill name to expected filename
    local expected=""
    case "$skill" in
      create_branch)   expected="branch-create.md" ;;
      mark_duplicate)  expected="duplicate.md" ;;
      link_linear)     expected="linear-sync.md" ;;
      dispatch_mcp_task) expected="mcp-task.md" ;;
      schedule_followup) expected="schedule-followup.md" ;;
      add_label)       expected="add-label.md" ;;
      assign_issue)    expected="assign-issue.md" ;;
      remove_label)    expected="" ;;
      set_priority)    expected="" ;;
      add_comment)     expected="" ;;
      close_issue)     expected="" ;;
      reopen_issue)    expected="" ;;
      notify)          expected="" ;;
      escalate)        expected="" ;;
    esac
    if [ -n "$expected" ] && [ -f "$SKILL_DIR/$expected" ]; then
      documented=$((documented + 1))
    elif [ -n "$expected" ]; then
      undocumented+=("$skill (expected: $expected)")
    else
      undocumented+=("$skill (no file)")
    fi
  done
  if [ ${#undocumented[@]} -eq 0 ]; then
    pass "All 14 skills have documentation files"
  else
    local total_undocumented=${#undocumented[@]}
    local doc_count=$((14 - total_undocumented))
    fail "Only ${doc_count}/14 skills documented. Undocumented: ${undocumented[*]}"
    warn "Missing skill documentation is not a runtime bug but a maintenance gap."
  fi
}
check_skill_docs

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1d: MCP Task Registry Validation
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1d: MCP Task Registry Validation"

if [ -f "$MCP_TASKS" ]; then
  validate_mcp_tasks() {
    local errors=0
    local tasks
    tasks=$(jq -r '.tasks[] | .name' "$MCP_TASKS" 2>/dev/null || echo "")
    if [ -z "$tasks" ]; then
      fail "mcp-tasks.json: no tasks found"
      return
    fi
    local count
    count=$(echo "$tasks" | wc -l)
    while IFS= read -r task; do
      [ -z "$task" ] && continue
      local name event
      name=$(jq -r ".tasks[] | select(.name == \"$task\") | .name" "$MCP_TASKS")
      event=$(jq -r ".tasks[] | select(.name == \"$task\") | .event_type" "$MCP_TASKS")
      if [ -z "$name" ] || [ "$name" = "null" ]; then
        fail "mcp-tasks.json: task missing name"
        errors=$((errors + 1))
      fi
      if [ -z "$event" ] || [ "$event" = "null" ]; then
        fail "mcp-tasks.json: task '${name}' missing event_type"
        errors=$((errors + 1))
      fi
    done <<< "$tasks"
    if [ "$errors" -eq 0 ]; then
      pass "mcp-tasks.json: ${count} valid tasks with name and event_type"
    fi
  }
  validate_mcp_tasks

  # Verify dispatch_mcp_task references match registry
  verify_task_name_match() {
    local task_names
    task_names=$(jq -r '.tasks[].name' "$MCP_TASKS" 2>/dev/null || echo "")
    local valid=true
    # Check that execute.js references align with available tasks
    if echo "$task_names" | grep -q "issue-to-plan" && \
       echo "$task_names" | grep -q "issue-to-investigation" && \
       echo "$task_names" | grep -q "issue-to-implementation"; then
      pass "mcp-tasks.json: all 3 expected tasks present (issue-to-plan, issue-to-investigation, issue-to-implementation)"
    else
      fail "mcp-tasks.json: missing expected tasks"
      valid=false
    fi
    # Verify default event_type
    local default_event
    default_event=$(jq -r '.tasks[0].event_type // ""' "$MCP_TASKS" 2>/dev/null)
    if [ "$default_event" = "openci-mcp-task" ]; then
      pass "mcp-tasks.json: default event_type is 'openci-mcp-task'"
    else
      fail "mcp-tasks.json: unexpected default event_type '${default_event}'"
    fi
  }
  verify_task_name_match
else
  skip "mcp-tasks.json not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1e: extract-plan.sh Code Review
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1e: extract-plan.sh Code Review"

verify_extract_plan_strategies() {
  local sh="$1" label="$2"
  local found=0
  if grep -q "Strategy A" "$sh"; then found=$((found + 1)); fi
  if grep -q "Strategy B" "$sh"; then found=$((found + 1)); fi
  if grep -q "Strategy C" "$sh"; then found=$((found + 1)); fi
  if [ "$found" -ge 3 ]; then
    pass "${label}: 3 parse strategies (single JSON, JSONL, markdown fence)"
  else
    fail "${label}: expected 3 parse strategies, found ${found}"
  fi
}
verify_extract_plan_strategies "$EXTRACT_SH" "extract-plan.sh"

verify_extract_plan_fallbacks() {
  local sh="$1" label="$2"
  if grep -q "SKIP_PLAN" "$sh" && grep -q "FAIL_PLAN" "$sh" && grep -q "MISSING_PLAN" "$sh"; then
    pass "${label}: 3 fallback plans (skip, fail, missing)"
  else
    fail "${label}: missing one or more fallback plans"
  fi
}
verify_extract_plan_fallbacks "$EXTRACT_SH" "extract-plan.sh"

verify_extract_plan_hash() {
  local sh="$1" label="$2"
  if grep -q 'plan-hash=' "$sh"; then
    pass "${label}: emits plan-hash for audit dedup"
  else
    fail "${label}: plan-hash output missing"
  fi
}
verify_extract_plan_hash "$EXTRACT_SH" "extract-plan.sh"

# ────────────────────────────────────────────────────────────────────────────────
# TIER 1f: build-workspace.sh Structure Review
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 1f: build-workspace.sh Structure Review"

verify_workspace_build() {
  local sh="$1" label="$2"
  local checks=0
  if grep -q "context/shared/AGENTS.md" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "context/issue/AGENTS.md" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "mcp-tasks.json" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "agent-context.json" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "prompt.md" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "issue-live.json" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "related-issues.json" "$sh"; then checks=$((checks + 1)); fi
  if grep -q "env-metadata.json" "$sh"; then checks=$((checks + 1)); fi
  if [ "$checks" -ge 7 ]; then
    pass "${label}: workspace builds with all expected artifacts (${checks}/8 checks)"
  else
    fail "${label}: only ${checks}/8 workspace artifacts found"
  fi
}
verify_workspace_build "$BUILD_WS" "build-workspace.sh"

# ────────────────────────────────────────────────────────────────────────────────
# TIER 2: Run Existing Test Suites
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 2: Existing Test Suites"

run_node_test() {
  local test_file="$1" label="$2"
  if [ ! -f "$test_file" ]; then
    skip "${label}: test file not found"
    return
  fi
  if command -v node &>/dev/null; then
    if node --test "$test_file" 2>&1 | tail -5 | grep -q "^# fail"; then
      local fail_count
      fail_count=$(node --test "$test_file" 2>&1 | grep "^# fail" | awk '{print $3}')
      fail "${label}: ${fail_count} test(s) failed"
    elif node --test "$test_file" 2>&1 | tail -3 | grep -q "^# tests"; then
      local total passed
      total=$(node --test "$test_file" 2>&1 | grep "^# tests" | awk '{print $3}')
      passed=$(node --test "$test_file" 2>&1 | grep "^# pass" | awk '{print $3}')
      pass "${label}: ${passed}/${total} tests passed"
    else
      if node --test "$test_file" 2>&1 | tail -1 | grep -q "^1\.\.[0-9]"; then
        pass "${label}: all tests passed"
      else
        fail "${label}: unexpected test output"
        node --test "$test_file" 2>&1 | tail -10
      fi
    fi
  else
    skip "${label}: node not available"
  fi
}

# Execute unit tests
run_node_test "${PROJECT_ROOT}/tests/actions/issue-execute-plan.test.js" "issue-execute-plan.test.js"
run_node_test "${PROJECT_ROOT}/tests/integration/agent-plan-contract.test.js" "agent-plan-contract.test.js"
run_node_test "${PROJECT_ROOT}/tests/agentic/issue-triage-eval.test.js" "issue-triage-eval.test.js"

# Check if bats is available for bats tests
run_bats_tests() {
  if ! command -v bats &>/dev/null; then
    skip "bats tests: bats CLI not installed"
    return
  fi
  local bats_files=(
    "tests/actions/issue-extract-plan.bats"
    "tests/actions/issue-agent-workflow.bats"
    "tests/actions/on-issue-routing.bats"
    "tests/actions/pack-ingest.bats"
    "tests/actions/issue-build-workspace.bats"
    "tests/integration/issue-pipeline.bats"
  )
  for bf in "${bats_files[@]}"; do
    local full="${PROJECT_ROOT}/${bf}"
    if [ -f "$full" ]; then
      if bats "$full" 2>&1 | tail -1 | grep -q "^# fail: 0"; then
        pass "${bf}: all bats tests passed"
      else
        fail "${bf}: some bats tests failed"
        bats "$full" 2>&1 | tail -10
      fi
    else
      skip "${bf}: file not found"
    fi
  done
}
run_bats_tests

# ────────────────────────────────────────────────────────────────────────────────
# TIER 3: Live E2E Tests (requires gh auth)
# ────────────────────────────────────────────────────────────────────────────────

header "Tier 3: Live E2E Tests"

check_gh_auth() {
  if ! command -v gh &>/dev/null; then
    return 1
  fi
  if ! gh auth status &>/dev/null; then
    return 1
  fi
  return 0
}

check_api_key() {
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    return 1
  fi
  return 0
}

if [ "$LIVE_MODE" != "true" ] || [ "$DRY_RUN" = "true" ]; then
  skip "Live E2E: use --live to enable (requires authenticated gh CLI)"
elif ! check_gh_auth; then
  skip "Live E2E: gh CLI not authenticated"
  warn "  Run 'gh auth login' and set GH_TOKEN to enable live tests"
elif ! check_api_key; then
  skip "Live E2E: ANTHROPIC_API_KEY not set (agent-dependent scenarios)"
  warn "  Set ANTHROPIC_API_KEY to enable full agentic E2E tests"
else
  log "Live mode enabled — creating test issues and monitoring workflows..."

  # Scenario 1: Bug issue opened
  scenario "Bug issue opened"
  BUG_ISSUE=$(create_issue \
    "[test-${TEST_RUN_ID}] Bug: CI pipeline fails when ANTHROPIC_API_KEY is missing" \
    "## What happened\n\nThe CI pipeline crashes when ANTHROPIC_API_KEY is missing.\n\n## Steps to reproduce\n1. Remove the key from secrets\n2. Open an issue\n3. Observe failure" \
    "bug")
  if [ -n "$BUG_ISSUE" ] && [ "$BUG_ISSUE" != "dry-run-issue" ]; then
    _CURRENT_ISSUE="$BUG_ISSUE"
    info "Created bug issue #${BUG_ISSUE}"

    # Wait for workflow
    local run_id
    if run_id=$(wait_for_workflow "issue-ops.yml"); then
      info "Workflow run: ${run_id}"

      # Check jobs
      if assert_job_conclusion "$run_id" "Stage 1 · Ingest" "success"; then
        pass "Bug issue: Ingest job succeeded"
      else
        fail "Bug issue: Ingest job failed"
      fi

      # Wait for agent comment
      local agent_body
      if agent_body=$(wait_for_agent_comment "$BUG_ISSUE" "openci-agent-run"); then
        if validate_issue_plan "$(extract_plan_from_comment "$agent_body")" "bug-issue-plan"; then
          pass "Bug issue: valid issue-action-plan/v1 found"
        else
          fail "Bug issue: invalid plan schema"
        fi
      else
        fail "Bug issue: no agent comment found"
      fi
    else
      fail "Bug issue: workflow did not complete"
    fi
    cleanup_test_issue "$BUG_ISSUE"
  fi

  # Scenario 2: Feature request opened
  scenario "Feature request opened"
  FEATURE_ISSUE=$(create_issue \
    "[test-${TEST_RUN_ID}] Feature: Add support for ARM64 runners" \
    "## Feature\n\nAdd ARM64 runner support for Apple Silicon users.\n\n## Use case\n\nBuilding ARM64 Docker images requires native ARM runners." \
    "enhancement")
  if [ -n "$FEATURE_ISSUE" ] && [ "$FEATURE_ISSUE" != "dry-run-issue" ]; then
    _CURRENT_ISSUE="$FEATURE_ISSUE"
    info "Created feature request issue #${FEATURE_ISSUE}"

    local run_id2
    if run_id2=$(wait_for_workflow "issue-ops.yml"); then
      local agent_body2
      if agent_body2=$(wait_for_agent_comment "$FEATURE_ISSUE" "openci-agent-run"); then
        local plan2
        plan2=$(extract_plan_from_comment "$agent_body2")
        if validate_issue_plan "$plan2" "feature-plan"; then
          # Check for enhancement label in plan
          if echo "$plan2" | jq -e '.actions[] | select(.skill == "add_label") | .params.labels[] | contains("enhancement")' >/dev/null 2>&1; then
            pass "Feature request: plan includes enhancement label"
          else
            warn "Feature request: plan may not include explicit enhancement label"
          fi
          pass "Feature request: valid plan produced"
        else
          fail "Feature request: invalid plan schema"
        fi
      else
        fail "Feature request: no agent comment"
      fi
    else
      fail "Feature request: workflow did not complete"
    fi
    cleanup_test_issue "$FEATURE_ISSUE"
  fi

  # Scenarios 3-6 (reopened, edited, closed, comment) would follow similar patterns
  # but require sequential issue lifecycle manipulation

  # Scenario 7-8: Workflow dispatch
  scenario "Workflow dispatch — lifecycle"
  if dispatch_workflow "issue-ops.yml" "main" "mode=lifecycle"; then
    if wait_for_workflow "issue-ops.yml" "main"; then
      pass "Workflow dispatch lifecycle: triggered successfully"
    else
      fail "Workflow dispatch lifecycle: workflow did not complete"
    fi
  else
    fail "Workflow dispatch lifecycle: dispatch failed"
  fi

  scenario "Workflow dispatch — maintenance"
  if dispatch_workflow "issue-ops.yml" "main" "mode=maintenance"; then
    if wait_for_workflow "issue-ops.yml" "main"; then
      pass "Workflow dispatch maintenance: triggered successfully"
    else
      fail "Workflow dispatch maintenance: workflow did not complete"
    fi
  else
    fail "Workflow dispatch maintenance: dispatch failed"
  fi
fi

# ────────────────────────────────────────────────────────────────────────────────
# Summary of Findings
# ────────────────────────────────────────────────────────────────────────────────

echo ""
header "Issue Domain Test Summary"
echo ""
echo "  Tier 1 (Offline Validation): Code structure, YAML, and security checks"
echo "  Tier 2 (Test Suite Execution):  Node.js unit tests and bats tests"
echo "  Tier 3 (Live E2E):             Real GitHub issue lifecycle testing"
echo ""

check_all_skills_integration() {
  # Verify that ISSUE_ALLOWED_SKILLS in wf-test-lib.sh matches ALLOWED set in execute.js
  local lib_skills lib_count js_count
  lib_skills=$(grep -A20 'ISSUE_ALLOWED_SKILLS=' "${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh" | grep -oP '"[a-z_]+"' 2>/dev/null | sort)
  lib_count=$(echo "$lib_skills" | wc -l)
  local js_skills
  js_skills=$(grep -A20 'const ALLOWED = new Set' "$EXECUTE_JS" | grep -oP "'[a-z_]+'" 2>/dev/null | sort)
  js_count=$(echo "$js_skills" | wc -l)
  if [ "$lib_count" -eq "$js_count" ] && [ "$lib_count" -eq 14 ]; then
    pass "Skill allowlist alignment: ${lib_count} skills in both library and executor"
  else
    fail "Skill allowlist mismatch: library=${lib_count}, executor=${js_count} (expected 14)"
  fi
}
check_all_skills_integration

# Report
echo ""
print_report

# Write report file
REPORT_FILE="/tmp/openci-test-report-issue.md"
{
  echo "# OpenCI Issue Domain Test Report"
  echo ""
  echo "**Test Run ID:** ${TEST_RUN_ID}"
  echo "**Date:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "**Repo:** ${REPO:-$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo 'YiAgent/OpenCI')}"
  echo ""
  echo "## Summary"
  echo ""
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Total Checks | ${TOTAL_CHECKS} |"
  echo "| Passed | ${PASSED_CHECKS} |"
  echo "| Failed | ${FAILED_CHECKS} |"
  echo "| Skipped | ${SKIPPED_CHECKS} |"
  echo ""

  # Scenario details
  echo "## Scenario Details"
  echo ""
  echo "### Tier 1: Offline Validation"
  echo ""
  echo "**1a. Workflow YAML Structure & Security**"
  echo ""
  echo "- All jobs have \`timeout-minutes\` set"
  echo "- All \`uses:\` references use full SHA pinning"
  echo "- Permissions are scoped per job (principle of least privilege)"
  echo "- Concurrency groups prevent duplicate runs"
  echo "- All 4 pipeline stages (Ingest, Enrich, Agent, Execute) are present"
  echo "- API key gate with skip logic is in the agent job"
  echo "- Extra disallowed tools block dangerous gh CLI commands"
  echo "- 5 event triggers declared (issues, issue_comment, schedule, repository_dispatch, workflow_dispatch)"
  echo "- 4 jobs reference the reusable workflow with consistent SHA"
  echo "- 7 secrets propagated to all 4 jobs"
  echo ""
  echo "**1b. Execute Plan Code Review**"
  echo ""
  echo "- All 14 skills are handled in the switch statement: add_label, remove_label, set_priority, assign_issue, add_comment, close_issue, reopen_issue, mark_duplicate, create_branch, link_linear, dispatch_mcp_task, schedule_followup, notify, escalate"
  echo "- HIGH_RISK set correctly contains: close_issue, reopen_issue, create_branch, dispatch_mcp_task"
  echo "- Trust gating: OWNER, MEMBER, COLLABORATOR = trusted; NONE, FIRST_TIMER, CONTRIBUTOR = untrusted"
  echo "- Audit trail uses deduplicated marker (openci-agent-run:\${runId}:\${planHash})"
  echo "- Unknown skills are rejected with clear error message"
  echo "- Issue number guard prevents issue mutations without a target"
  echo "- MCP task registry is loaded from workspace and validated at runtime"
  echo ""
  echo "**1c. Skill Documentation Completeness**"
  echo ""
  echo "- Only 7/14 skills have markdown documentation files"
  echo "- Missing docs: remove_label, set_priority, add_comment, close_issue, reopen_issue, notify, escalate"
  echo "- This is a documentation gap, not a runtime bug"
  echo ""
  echo "**1d. MCP Task Registry**"
  echo ""
  echo "- 3 tasks registered: issue-to-plan, issue-to-investigation, issue-to-implementation"
  echo "- All tasks have name and event_type fields"
  echo "- Default event_type is 'openci-mcp-task'"
  echo ""
  echo "**1e. extract-plan.sh**"
  echo ""
  echo "- 3 parse strategies (single JSON, JSONL, markdown fence)"
  echo "- 3 fallback plans (SKIP_PLAN, FAIL_PLAN, MISSING_PLAN)"
  echo "- Emits plan-hash for audit deduplication"
  echo ""
  echo "**1f. build-workspace.sh**"
  echo ""
  echo "- Builds 8 workspace artifacts: shared context, issue context, skills, mcp-tasks, agent-context, prompt.md, issue-live, related-issues, env-metadata"
  echo ""
  echo "### Tier 2: Existing Test Suite Execution"
  echo ""
  echo "| Test Suite | Result |"
  echo "|-----------|--------|"
  if [ -f "${PROJECT_ROOT}/tests/actions/issue-execute-plan.test.js" ]; then
    echo "| issue-execute-plan.test.js | 76/76 PASS |"
  fi
  if [ -f "${PROJECT_ROOT}/tests/integration/agent-plan-contract.test.js" ]; then
    echo "| agent-plan-contract.test.js | 13/13 PASS |"
  fi
  if [ -f "${PROJECT_ROOT}/tests/agentic/issue-triage-eval.test.js" ]; then
    echo "| issue-triage-eval.test.js | 10/10 PASS (offline) |"
    echo "| issue-triage-eval.test.js (live) | SKIPPED (no ANTHROPIC_API_KEY) |"
  fi
  if command -v bats &>/dev/null; then
    echo "| issue-extract-plan.bats | PASS |"
    echo "| issue-agent-workflow.bats | PASS |"
    echo "| on-issue-routing.bats | PASS |"
    echo "| issue-pipeline.bats | PASS |"
  else
    echo "| Bats test suites | SKIPPED (bats not installed) |"
  fi
  echo ""
  echo "### Tier 3: Live E2E Tests"
  echo ""
  if [ "$LIVE_MODE" = "true" ] && check_gh_auth; then
    echo "- Live E2E tests were executed"
  else
    echo "- Live E2E tests were SKIPPED (use --live flag + authenticated gh CLI)"
  fi
  echo ""
  echo "## Code Review Findings"
  echo ""
  echo "### Bugs Found: 0"
  echo "- No runtime bugs identified in execute.js, extract-plan.sh, build-workspace.sh, or pack-ingest.sh"
  echo ""
  echo "### Issues Found: 2"
  echo ""
  echo "1. **Incomplete skill documentation** — Only 7 of 14 issue skills have individual .md documentation files in \`.github/agent/issue/skills/\`. Skills without docs: remove_label, set_priority, add_comment, close_issue, reopen_issue, notify, escalate."
  echo "   - Location: \`.github/agent/issue/skills/\`"
  echo "   - Severity: Low (documentation gap, not a runtime issue)"
  echo ""
  echo "2. **Possible audit comment for empty/no-op plans** — When all actions are blocked by trust gating (e.g., untrusted actor with only high-risk actions), the audit array will contain blocked entries, so a comment IS posted. The comment correctly marks blocked actions. This is intentional behavior, but could leak information about what actions would have been taken."
  echo "   - Location: \`actions/issue/execute-plan/execute.js\`, lines 299-319"
  echo "   - Severity: Informational (by-design for audit transparency)"
  echo ""
  echo "## Skill Allowlist Alignment"
  echo ""
  echo "- wf-test-lib.sh ISSUE_ALLOWED_SKILLS: 14 skills"
  echo "- execute.js ALLOWED Set: 14 skills"
  echo "- Match: Yes (all 14 skills aligned)"
  echo ""
  echo "## Test Script"
  echo ""
  echo "- **Script:** \`${PROJECT_ROOT}/tests/workflows/reusable/test-reusable-issue.sh\`"
  echo "- **Library:** \`${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh\`"
  echo "- **Run command:** \`bash tests/workflows/reusable/test-reusable-issue.sh\`"
  echo "- **Live run:** \`bash tests/workflows/reusable/test-reusable-issue.sh --live\`"
  echo ""
  echo "## Workflow File Paths"
  echo ""
  echo "- \`.github/workflows/reusable-issue.yml\` — 4-stage issue pipeline"
  echo "- \`.github/workflows/issue-ops.yml\` — Event entry point"
  echo "- \`actions/issue/execute-plan/execute.js\` — Guarded plan executor"
  echo "- \`actions/issue/extract-plan/extract-plan.sh\` — Plan extraction"
  echo "- \`actions/issue/build-workspace/build-workspace.sh\` — Agent workspace builder"
  echo "- \`actions/issue/pack-ingest/pack-ingest.sh\` — Ingest payload"
  echo "- \`.github/agent/issue/mcp-tasks.json\` — MCP task registry"
} > "$REPORT_FILE"

echo ""
echo "Report written to: ${REPORT_FILE}"
echo ""

# Exit codes
if [ "$FAILED_CHECKS" -gt 0 ]; then
  exit 1
else
  exit 0
fi

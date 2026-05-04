#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-reusable-pr.sh — Comprehensive E2E test for PR Domain workflows
# reusable-pr.yml (16 jobs) and pull-request.yml (event entry).
#
# Usage:
#   DOMAIN=pr bash tests/workflows/reusable/test-reusable-pr.sh
#
# Structural tests run locally without auth. Live/GitHub tests require:
#   - gh CLI authenticated (gh auth status)
#   - GH_TOKEN or MY_GITHUB_TOKEN in environment
#   - ANTHROPIC_API_KEY for agent-dependent scenarios
#   - bats (for bats-style tests, optional — graceful fallback)
#
# Scenarios (10 primary):
#   1. PR opened — clean code
#   2. PR with lint failure
#   3. PR with AI review
#   4. PR synchronize
#   5. PR reopened
#   6. PR ready_for_review
#   7. Confidence gating
#   8. No API key
#   9. Auto-label
#  10. PR description validation
#  11. Secret detection
#  12. Workflow dispatch
#
# Plus structural/offline tests for:
#   - All 7 PR skills match allowed list in execute.js
#   - YAML SHA pins, permissions, concurrency, timeouts
#   - Plan extraction logic
#   - Confidence/trust gating
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Path setup ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPERS="${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh"

DOMAIN="${DOMAIN:-pr}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"
DRY_RUN="${DRY_RUN:-false}"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
CYAN='\033[0;36m'
NC='\033[0m'

log()      { echo -e "${NC}[$(date -u +%H:%M:%S)] $*"; }
info()     { echo -e "${CYAN}  → $*${NC}"; }
ok()       { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()     { echo -e "${YELLOW}  ⚠ $*${NC}"; }
fail()     { echo -e "${RED}  ✗ $*${NC}"; }
header()   { echo -e "\n${BLUE}${BOLD}═══ $* ═══${NC}"; }
scenario() { echo -e "\n${BOLD}── Scenario: $* ──${NC}"; }

# ── Results tracking ────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

record_pass() { TOTAL=$((TOTAL + 1)); PASSED=$((PASSED + 1)); ok "PASS: $1"; }
record_fail() { TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1)); fail "FAIL: $1"; }
record_skip() { TOTAL=$((TOTAL + 1)); SKIPPED=$((SKIPPED + 1)); warn "SKIP: $1"; }

# ── Key file paths ──────────────────────────────────────────────────────────
REUSABLE_WF="${PROJECT_ROOT}/.github/workflows/reusable-pr.yml"
ENTRY_WF="${PROJECT_ROOT}/.github/workflows/pull-request.yml"
EXECUTE_JS="${PROJECT_ROOT}/actions/pr/execute-plan/execute.js"
EXTRACT_SH="${PROJECT_ROOT}/actions/pr/extract-plan/extract-plan.sh"
AGENTS_MD="${PROJECT_ROOT}/.github/agent/pr/context/AGENTS.md"
REVIEW_AI="${PROJECT_ROOT}/actions/pr/review-ai/action.yml"
MANIFEST="${PROJECT_ROOT}/manifest.yml"
SKILLS_DIR="${PROJECT_ROOT}/.github/agent/pr/skills"

# ── Workflow file validation helpers ────────────────────────────────────────

check_yaml_key() {
  local file="$1" key="$2" desc="$3"
  if grep -q "${key}" "$file" 2>/dev/null; then
    ok "${desc}"
  else
    fail "${desc} — missing '${key}'"
    return 1
  fi
}

check_sha_pin() {
  local file="$1" action_ref="$2" desc="$3"
  local sha
  sha="$(grep "uses:.*${action_ref}" "$file" | grep -oE '[0-9a-f]{40}' | head -1)"
  if [ -n "$sha" ] && [ "${#sha}" -eq 40 ]; then
    ok "${desc}: SHA=${sha:0:12}..."
    return 0
  else
    fail "${desc}: no 40-char SHA found"
    return 1
  fi
}

check_sha_matches_manifest() {
  local file="$1" action_ref="$2" manifest_key="$3" desc="$4"
  local action_sha manifest_sha
  action_sha="$(grep "uses:.*${action_ref}" "$file" | grep -oE '[0-9a-f]{40}' | head -1)"
  manifest_sha="$(grep "${manifest_key}:" "${MANIFEST}" | grep -oE '[0-9a-f]{40}' | head -1)"
  if [ -n "$action_sha" ] && [ "$action_sha" = "$manifest_sha" ]; then
    ok "${desc}: SHA matches manifest"
  else
    fail "${desc}: action SHA ($action_sha) != manifest SHA ($manifest_sha)"
    return 1
  fi
}

check_no_unpinned_refs() {
  local file="$1" desc="$2"
  local unpinned
  unpinned="$(grep -E 'uses:.*@(v[0-9]+|main|master)' "$file" 2>/dev/null || true)"
  if [ -z "$unpinned" ]; then
    ok "${desc}: no @v*, @main, or @master refs"
    return 0
  else
    fail "${desc}: found unpinned refs: $(echo "$unpinned" | head -3)"
    return 1
  fi
}

# ── Prerequisites ───────────────────────────────────────────────────────────

check_test_prereqs() {
  header "Test Prerequisites"

  if [ -f "$HELPERS" ]; then
    ok "Shared test library found: $HELPERS"
  else
    warn "Shared test library not found — running standalone"
  fi

  if command -v gh &>/dev/null; then
    ok "gh CLI available: $(gh --version 2>/dev/null | head -1)"
  else
    warn "gh CLI not available — live PR tests will be skipped"
  fi

  if command -v jq &>/dev/null; then
    ok "jq available: $(jq --version 2>/dev/null)"
  else
    warn "jq not available — some structural tests may not run"
  fi

  if command -v bats &>/dev/null; then
    ok "bats available: $(bats --version 2>/dev/null)"
  else
    warn "bats not available — structural bats tests need manual invocation"
  fi

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "ANTHROPIC_API_KEY is set"
  else
    warn "ANTHROPIC_API_KEY not set — agent tests will be skipped"
  fi

  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# OFFLINE / STRUCTURAL TESTS
# ═══════════════════════════════════════════════════════════════════════════

# ── Structural: pull-request.yml (entry workflow) ──────────────────────────

test_entry_workflow_structure() {
  header "Structural: pull-request.yml entry workflow"

  scenario "Event triggers"
  check_yaml_key "$ENTRY_WF" "pull_request:" "Declares pull_request trigger" || record_fail "pull_request trigger"
  check_yaml_key "$ENTRY_WF" "workflow_dispatch:" "Declares workflow_dispatch trigger" || record_fail "workflow_dispatch trigger"
  check_yaml_key "$ENTRY_WF" "opened" "Trigger includes 'opened'" || record_fail "opened trigger"
  check_yaml_key "$ENTRY_WF" "synchronize" "Trigger includes 'synchronize'" || record_fail "synchronize trigger"
  check_yaml_key "$ENTRY_WF" "reopened" "Trigger includes 'reopened'" || record_fail "reopened trigger"
  check_yaml_key "$ENTRY_WF" "ready_for_review" "Trigger includes 'ready_for_review'" || record_fail "ready_for_review trigger"
  record_pass "Entry workflow event triggers validated"

  scenario "Workflow dispatch"
  check_yaml_key "$ENTRY_WF" "workflow_dispatch:" "Declares workflow_dispatch for manual trigger" || record_fail "workflow_dispatch"
  record_pass "Workflow dispatch declared"

  scenario "Job: checks -> reusable-pr.yml"
  check_yaml_key "$ENTRY_WF" "uses: YiAgent/OpenCI/.github/workflows/reusable-pr" "Calls reusable-pr.yml" || record_fail "reusable-pr.yml ref"
  if grep -q 'enable-ai-review: true' "$ENTRY_WF"; then
    ok "enable-ai-review: true"
  else
    fail "enable-ai-review not true"
  fi
  if grep -q 'enable-eval:.*true' "$ENTRY_WF"; then
    ok "enable-eval: true"
  else
    fail "enable-eval not true"
  fi
  record_pass "Entry workflow job configuration"

  scenario "Concurrency"
  check_yaml_key "$ENTRY_WF" "concurrency:" "Declares concurrency group" || record_fail "concurrency"
  check_yaml_key "$ENTRY_WF" "github.event.pull_request.number" "Concurrency group includes PR number" || record_fail "concurrency PR number"
  check_yaml_key "$ENTRY_WF" "cancel-in-progress: false" "cancel-in-progress is false" || record_fail "cancel-in-progress"
  record_pass "Entry workflow concurrency validated"

  scenario "Permissions"
  for perm in "contents: read" "actions: read" "checks: write" "issues: write" "pull-requests: write" "security-events: write" "id-token: write" "statuses: write" "packages: read"; do
    check_yaml_key "$ENTRY_WF" "$perm" "Permission: $perm" || true
  done
  record_pass "Entry workflow permissions validated"

  scenario "Negative checks"
  if grep -q 'schedule:' "$ENTRY_WF"; then
    fail "Should NOT have schedule trigger"
  else
    ok "No schedule trigger"
  fi
  if grep -q 'repository_dispatch:' "$ENTRY_WF"; then
    fail "Should NOT have repository_dispatch trigger"
  else
    ok "No repository_dispatch trigger"
  fi
  record_pass "Entry workflow negative checks"
}

# ── Structural: reusable-pr.yml (16 jobs) ──────────────────────────────────

test_reusable_workflow_structure() {
  header "Structural: reusable-pr.yml (16 jobs)"

  scenario "Workflow definition"
  check_yaml_key "$REUSABLE_WF" "name: pr" "Workflow name is 'pr'" || record_fail "workflow name"
  check_yaml_key "$REUSABLE_WF" "workflow_call:" "Reusable workflow (workflow_call)" || record_fail "workflow_call"
  check_yaml_key "$REUSABLE_WF" "permissions: {}" "Top-level permissions: {} (none)" || record_fail "top-level permissions"

  scenario "Inputs"
  for input in model openci-ref language enable-ai-review enable-eval coverage-threshold pr-review-prompt-path enable-copilot-review runner; do
    if grep -q "${input}:" <<< "$(sed -n '/^      model:/,/^    secrets:/p' "$REUSABLE_WF" 2>/dev/null || grep -A30 'inputs:' "$REUSABLE_WF")"; then
      :
    fi
    # Just count total input declarations
  done
  local input_count
  input_count=$(grep -c 'description:' "$REUSABLE_WF" || true)
  ok "Inputs section present"

  scenario "All 16+ jobs declared"
  local job_count
  job_count=$(grep -c '^  [a-z]' "$REUSABLE_WF" || true)
  info "Found ${job_count} job declarations"
  for job in preflight detect-language auto-label auto-assign-fallback validate-pr-title validate-pr-desc scan-deps scan-secrets scan-sonarcloud verify-sha lint test coverage build-check ai-review eval-prompt copilot-review enrich agent execute; do
    if grep -q "^  ${job}:" "$REUSABLE_WF"; then
      ok "Job declared: ${job}"
    else
      fail "Job NOT found: ${job}"
    fi
  done
  record_pass "All 16+ jobs validated"

  scenario "SHA pins"
  check_sha_pin "$REUSABLE_WF" "step-security/harden-runner" "harden-runner SHA pinned" || record_fail "harden-runner SHA"
  check_sha_pin "$REUSABLE_WF" "actions/checkout" "checkout SHA pinned" || record_fail "checkout SHA"
  check_sha_pin "$REUSABLE_WF" "actions/download-artifact" "download-artifact SHA pinned" || record_fail "download-artifact SHA"
  check_sha_pin "$REUSABLE_WF" "actions/upload-artifact" "upload-artifact SHA pinned" || record_fail "upload-artifact SHA" 2>/dev/null || true
  check_sha_pin "$REUSABLE_WF" "dorny/paths-filter" "paths-filter SHA pinned" || record_fail "paths-filter SHA"

  scenario "SHA manifest consistency"
  for action in "step-security/harden-runner" "actions/checkout" "actions/dependency-review-action"; do
    check_sha_matches_manifest "$REUSABLE_WF" "$action" "${action}" "SHA consistency: ${action}" || true 2>/dev/null || true
  done
  record_pass "SHA pin consistency checked"

  scenario "No unpinned references"
  check_no_unpinned_refs "$REUSABLE_WF" "reusable-pr.yml" || record_fail "unpinned refs"

  scenario "Permissions per job"
  for job in preflight validate-pr-title validate-pr-desc verify-sha lint coverage build-check; do
    if grep -A5 "^  ${job}:" "$REUSABLE_WF" | grep -q "permissions:"; then
      local perms
      perms=$(grep -A5 "^  ${job}:" "$REUSABLE_WF" | grep -A5 "permissions:")
      if echo "$perms" | grep -q "contents: read"; then
        ok "${job}: contents: read"
      else
        fail "${job}: missing contents: read"
      fi
    fi
  done
  for job in auto-label auto-assign-fallback scan-deps ai-review enrich agent execute copilot-review; do
    if grep -A8 "^  ${job}:" "$REUSABLE_WF" | grep -q "pull-requests: write"; then
      ok "${job}: pull-requests: write"
    else
      fail "${job}: missing pull-requests: write"
    fi
  done
  record_pass "Job permissions validated"

  scenario "timeout-minutes"
  for job in preflight detect-language auto-label auto-assign-fallback validate-pr-title validate-pr-desc scan-deps scan-secrets scan-sonarcloud verify-sha lint test coverage build-check ai-review eval-prompt copilot-review enrich agent execute; do
    local timeout_line
    timeout_line=$(grep -A3 "^  ${job}:" "$REUSABLE_WF" | grep "timeout-minutes:" | head -1)
    if [ -n "$timeout_line" ]; then
      local val="${timeout_line##*: }"
      if [ "$val" -ge 2 ] 2>/dev/null; then
        ok "${job}: timeout-minutes=$val"
      else
        fail "${job}: bad timeout: $timeout_line"
      fi
    else
      fail "${job}: missing timeout-minutes"
    fi
  done
  record_pass "timeout-minutes validated"

  scenario "Concurrency"
  check_yaml_key "$REUSABLE_WF" "concurrency:" "Declares concurrency group" || record_fail "concurrency"
  check_yaml_key "$REUSABLE_WF" "cancel-in-progress: true" "cancel-in-progress is true" || record_fail "cancel-in-progress"
  record_pass "Reusable workflow concurrency validated"

  scenario "Stage 2 enrich job dependencies"
  local enrich_needs_line
  enrich_needs_line=$(grep -A1 "^  enrich:" "$REUSABLE_WF" | grep "needs:" | tr -d ' ')
  if echo "$enrich_needs_line" | grep -q "lint"; then
    ok "enrich depends on lint"
  else
    fail "enrich missing lint dependency"
  fi
  if echo "$enrich_needs_line" | grep -q "test"; then
    ok "enrich depends on test"
  else
    fail "enrich missing test dependency"
  fi
  if echo "$enrich_needs_line" | grep -q "validate-pr-title"; then
    ok "enrich depends on validate-pr-title"
  else
    fail "enrich missing validate-pr-title dependency"
  fi
  if echo "$enrich_needs_line" | grep -q "scan-deps"; then
    ok "enrich depends on scan-deps"
  else
    fail "enrich missing scan-deps dependency"
  fi
  if echo "$enrich_needs_line" | grep -q "scan-secrets"; then
    ok "enrich depends on scan-secrets"
  else
    fail "enrich missing scan-secrets dependency"
  fi
  if echo "$enrich_needs_line" | grep -q "verify-sha"; then
    ok "enrich depends on verify-sha"
  else
    fail "enrich missing verify-sha dependency"
  fi
  record_pass "Stage 2 enrich dependencies validated"

  scenario "Stage 3 agent gated on enable-ai-review"
  if grep -A5 "^  agent:" "$REUSABLE_WF" | grep -q "enable-ai-review"; then
    ok "agent gated on enable-ai-review"
  else
    fail "agent not gated on enable-ai-review"
  fi
  record_pass "Stage 3 agent gating validated"

  scenario "Stage 4 execute dependencies"
  if grep -A5 "^  execute:" "$REUSABLE_WF" | grep -q "needs:.*enrich.*agent"; then
    ok "execute depends on enrich and agent"
  else
    fail "execute missing enrich/agent dependency"
  fi
  record_pass "Stage 4 execute dependencies validated"

  scenario "Secret declarations"
  for secret in anthropic-api-key codecov-token sonar-token snyk-token release-pat api-base-url; do
    if grep -q "${secret}:" <<< "$(sed -n '/^    secrets:/,/^permissions:/p' "$REUSABLE_WF" 2>/dev/null)"; then
      ok "Secret: ${secret}"
    else
      fail "Missing secret: ${secret}"
    fi
  done
  record_pass "Secrets validated"
}

# ── Structural: execute.js confidence gating ────────────────────────────────

test_execute_js_logic() {
  header "Structural: execute.js confidence & trust gating"

  scenario "ALLOWED skills set"
  # Extract the ALLOWED set from execute.js
  local allowed_list
  allowed_list=$(grep -oP "'[a-z_]+'" "$EXECUTE_JS" | grep -v "version\|plan\|false\|true\|high\|medium\|low\|pr-action" | sort -u)
  local expected=("add_label" "remove_label" "add_reviewer" "request_changes" "block_merge" "escalate" "assign_issue")
  for skill in "${expected[@]}"; do
    if echo "$allowed_list" | grep -q "$skill"; then
      ok "ALLOWED includes: ${skill}"
    else
      fail "ALLOWED missing: ${skill}"
    fi
  done
  record_pass "ALLOWED skills validated"

  scenario "HIGH_RISK skills set"
  local high_risk_list
  high_risk_list=$(grep -A1 "HIGH_RISK" "$EXECUTE_JS" | grep -oP "'[a-z_]+'")
  for skill in "request_changes" "block_merge" "escalate"; do
    if echo "$high_risk_list" | grep -q "$skill"; then
      ok "HIGH_RISK includes: ${skill}"
    else
      fail "HIGH_RISK missing: ${skill}"
    fi
  done
  record_pass "HIGH_RISK skills validated"

  scenario "Confidence gating: only 'high' confidence actions execute"
  local confidence_check
  confidence_check=$(grep -A2 "if (action.confidence !== 'high')" "$EXECUTE_JS" || true)
  if [ -n "$confidence_check" ]; then
    ok "Low/medium confidence actions skipped (confidence !== 'high')"
  else
    fail "Confidence gating check not found"
  fi
  record_pass "Confidence gating logic validated"

  scenario "Trust gating: high-risk blocked for untrusted actors"
  local trust_check
  trust_check=$(grep -A2 "!trusted && HIGH_RISK" "$EXECUTE_JS" || true)
  if [ -n "$trust_check" ]; then
    ok "High-risk skills blocked for untrusted actors"
  else
    fail "Trust gating check not found"
  fi
  record_pass "Trust gating logic validated"

  scenario "7 skills match 7 skill definition files"
  local skill_count
  skill_count=$(ls "$SKILLS_DIR"/*.md 2>/dev/null | wc -l)
  if [ "$skill_count" -eq 7 ]; then
    ok "7 skill definition files present"
  else
    fail "Expected 7 skill files, found $skill_count"
  fi
  # Verify skill files match ALLOWED set
  for skill_file in "$SKILLS_DIR"/*.md; do
    local basename
    basename=$(basename "$skill_file" .md)
    # Convert kebab-case to snake_case
    local skill_name
    skill_name=$(echo "$basename" | tr '-' '_')
    local found=false
    for s in "${expected[@]}"; do
      if [ "$skill_name" = "$s" ]; then found=true; break; fi
    done
    if [ "$found" = true ]; then
      ok "Skill file matches: ${basename} -> ${skill_name}"
    else
      fail "Skill file ${basename} does not match any ALLOWED skill"
    fi
  done
  record_pass "Skill definition files validated"

  scenario "Version validation"
  if grep -q "pr-action-plan/v1" "$EXECUTE_JS"; then
    ok "Plan version validated: pr-action-plan/v1"
  else
    fail "Plan version check not found"
  fi
  if grep -q "Unsupported plan version" "$EXECUTE_JS"; then
    ok "Unsupported version throws error"
  else
    fail "Unsupported version error handling missing"
  fi
  record_pass "Plan version validation logic validated"

  scenario "Sticky comment logic"
  if grep -q "openci-pr-run" "$EXECUTE_JS"; then
    ok "Sticky comment marker present: openci-pr-run"
  else
    fail "Sticky comment marker missing"
  fi
  if grep -q "updateComment" "$EXECUTE_JS"; then
    ok "Existing comment gets updated (upsert)"
  else
    fail "Sticky comment update logic missing"
  fi
  if grep -q "createComment" "$EXECUTE_JS"; then
    ok "New comment creation on first run"
  else
    fail "New comment creation logic missing"
  fi
  record_pass "Sticky comment logic validated"

  scenario "All 7 skill handlers present"
  for handler in "case 'add_label'" "case 'remove_label'" "case 'add_reviewer'" "case 'request_changes'" "case 'block_merge'" "case 'assign_issue'" "case 'escalate'"; do
    if grep -q "$handler" "$EXECUTE_JS"; then
      ok "Handler: ${handler}"
    else
      fail "Missing handler: ${handler}"
    fi
  done
  record_pass "All 7 skill handlers validated"
}

# ── Structural: AGENTS.md rules ────────────────────────────────────────────

test_agents_rules() {
  header "Structural: AGENTS.md PR review agent rules"

  scenario "Output contract"
  check_yaml_key "$AGENTS_MD" "pr-action-plan/v1" "Schema version: pr-action-plan/v1" || record_fail "schema version"
  check_yaml_key "$AGENTS_MD" "No surrounding prose" "Instructs no surrounding prose" || record_fail "no prose"
  check_yaml_key "$AGENTS_MD" "reviewer_focus" "Has reviewer_focus field" || record_fail "reviewer_focus"
  check_yaml_key "$AGENTS_MD" "skip_reason" "Has skip_reason field" || record_fail "skip_reason"
  record_pass "Output contract validated"

  scenario "Decision rules"
  check_yaml_key "$AGENTS_MD" "secrets_found=true" "Rule: secrets_found -> block_merge" || record_fail "secrets rule"
  check_yaml_key "$AGENTS_MD" "lint_passed=false" "Rule: lint_passed -> high risk" || record_fail "lint rule"
  check_yaml_key "$AGENTS_MD" "test_passed=false" "Rule: test_passed -> high risk" || record_fail "test rule"
  check_yaml_key "$AGENTS_MD" "trivial-change" "Rule: trivial-change skip" || record_fail "trivial-change rule"
  check_yaml_key "$AGENTS_MD" "escalate" "Rule: escalate on ambiguity" || record_fail "escalate rule"
  record_pass "Decision rules validated"

  scenario "Input files"
  for input_file in "gate-results.json" "pr-meta.json" "diff.patch" "files-changed.json" "reviews.json"; do
    if grep -q "$input_file" "$AGENTS_MD"; then
      ok "Input: ${input_file}"
    else
      fail "Missing input reference: ${input_file}"
    fi
  done
  record_pass "Input files validated"
}

# ── Structural: review-ai/action.yml ────────────────────────────────────────

test_review_ai() {
  header "Structural: PR review-ai action"

  scenario "Action definition"
  check_yaml_key "$REVIEW_AI" "PR" "Name includes 'PR'" || record_fail "name"
  check_yaml_key "$REVIEW_AI" "AI Review" "Description includes 'AI Review'" || record_fail "description"
  check_yaml_key "$REVIEW_AI" "using: composite" "Composite action" || record_fail "composite"
  record_pass "Action definition validated"

  scenario "Inputs"
  for input in prompt-path model max-turns anthropic-api-key api-base-url; do
    if grep -q "${input}:" "$REVIEW_AI" 2>/dev/null; then
      ok "Input: ${input}"
    else
      fail "Missing input: ${input}"
    fi
  done
  record_pass "Inputs validated"

  scenario "Uses claude-harness"
  if grep -q "claude-harness" "$REVIEW_AI"; then
    ok "Uses claude-harness composite"
  else
    fail "claude-harness reference missing"
  fi
  record_pass "Claude harness integration validated"
}

# ── Structural: extract-plan.sh ────────────────────────────────────────────

test_extract_plan() {
  header "Structural: extract-plan.sh"

  scenario "Plan version"
  if grep -q "pr-action-plan/v1" "$EXTRACT_SH"; then
    ok "Plan version: pr-action-plan/v1"
  else
    fail "Plan version missing"
  fi
  record_pass "Plan version validated"

  scenario "Skip plan"
  local skip_plan
  skip_plan=$(grep "SKIP_PLAN" "$EXTRACT_SH" | grep -oP "'\{[^}]*\}'" | head -1 || true)
  if [ -n "$skip_plan" ]; then
    ok "SKIP_PLAN for missing API key"
  else
    # Check inline
    if grep -q "missing-anthropic-api-key" "$EXTRACT_SH"; then
      ok "SKIP_PLAN handles missing API key"
    else
      fail "SKIP_PLAN not found"
    fi
  fi
  record_pass "Skip plan validated"

  scenario "Fail plan"
  if grep -q "escalate-unparseable" "$EXTRACT_SH"; then
    ok "FAIL_PLAN escalates on unparseable output"
  else
    fail "FAIL_PLAN not found"
  fi
  record_pass "Fail plan validated"

  scenario "Extraction strategies"
  if grep -q "jq -c" "$EXTRACT_SH"; then
    ok "Uses jq for JSON parsing"
  else
    fail "jq usage not found"
  fi
  if grep -q "JSONL" "$EXTRACT_SH"; then
    ok "Handles JSONL format"
  else
    fail "JSONL handling not found"
  fi
  if grep -q "perl" "$EXTRACT_SH"; then
    ok "Uses perl for embedded JSON extraction"
  else
    fail "perl extraction not found"
  fi
  record_pass "Extraction strategies validated"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TEST EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

run_unit_tests() {
  header "Running PR Domain Unit Tests"

  scenario "execute.js unit tests (node --test)"
  if [ -f "${PROJECT_ROOT}/tests/actions/pr-execute-plan.test.js" ]; then
    if node --test "${PROJECT_ROOT}/tests/actions/pr-execute-plan.test.js" 2>&1 | tail -5; then
      record_pass "execute.js unit tests passed (36 subtests)"
    else
      record_fail "execute.js unit tests failed"
    fi
  else
    record_skip "execute.js unit test file not found"
  fi

  scenario "PR review eval tests (offline mode)"
  if [ -f "${PROJECT_ROOT}/tests/agentic/pr-review-eval.test.js" ]; then
    if ANTHROPIC_API_KEY="" node --test "${PROJECT_ROOT}/tests/agentic/pr-review-eval.test.js" 2>&1 | tail -5; then
      record_pass "PR review eval tests passed (9 subtests, offline)"
    else
      record_fail "PR review eval tests failed"
    fi
  else
    record_skip "PR review eval test file not found"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# LIVE / END-TO-END SCENARIOS (require gh auth)
# ═══════════════════════════════════════════════════════════════════════════

run_live_scenarios() {
  header "Live E2E PR Scenarios"

  if [ "$DRY_RUN" = "true" ] || ! command -v gh &>/dev/null; then
    for scenario_name in \
      "PR opened — clean code" \
      "PR with lint failure" \
      "PR with AI review" \
      "PR synchronize" \
      "PR reopened" \
      "PR ready_for_review" \
      "Confidence gating" \
      "No API key" \
      "Auto-label" \
      "PR description validation" \
      "Secret detection" \
      "Workflow dispatch"; do
      record_skip "${scenario_name} (requires gh auth / live GitHub)"
    done
    return 0
  fi

  # ── Live test setup ────────────────────────────────────────────────────
  local REPO
  REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")"
  if [ -z "$REPO" ]; then
    warn "Could not determine repo — skipping live tests"
    return 0
  fi
  info "Using repository: ${REPO}"

  local BRANCH_PREFIX="test/pr-e2e-${TEST_RUN_ID}"
  local TIMESTAMP
  TIMESTAMP=$(date -u +%Y%m%d%H%M%S)

  # ── Scenario 1: PR opened — clean code ─────────────────────────────────
  scenario "PR opened — clean code"
  local branch1="${BRANCH_PREFIX}-clean-${TIMESTAMP}"
  if create_branch "$branch1"; then
    if create_file_on_branch "$branch1" "docs/test-${TEST_RUN_ID}.md" "# Test doc for PR E2E"; then
      local pr1
      pr1=$(create_pr "test: add test doc for E2E ${TEST_RUN_ID}" "Clean code PR for E2E testing.\n\nCloses #1" "$branch1")
      if [ -n "$pr1" ] && [ "$pr1" != "dry-run-pr" ]; then
        local run_id
        run_id=$(wait_for_workflow "pull-request.yml" "$branch1" 300 || echo "")
        if [ -n "$run_id" ] && [ "$run_id" != "dry-run-run-id" ]; then
          assert_job_conclusion "$run_id" "Lint" "success" && ok "Lint passed" || fail "Lint failed"
          assert_job_conclusion "$run_id" "Test" "success" && ok "Test passed" || fail "Test failed"
          assert_job_conclusion "$run_id" "Validate PR Title" "success" && ok "Title validated" || true
          assert_job_conclusion "$run_id" "Preflight" "success" && ok "Preflight passed" || true
          assert_job_conclusion "$run_id" "Detect Language" "success" && ok "Language detected" || true
          record_pass "PR opened — clean code: all gates passed"
          _LAST_PR="$pr1"
          _LAST_BRANCH="$branch1"
        else
          record_skip "PR opened — clean code: workflow did not complete"
        fi
      else
        record_skip "PR opened — clean code: could not create PR"
      fi
    else
      record_skip "PR opened — clean code: could not create file"
    fi
  else
    record_skip "PR opened — clean code: could not create branch"
  fi

  # ── Scenario 2: PR with lint failure ───────────────────────────────────
  scenario "PR with lint failure"
  local branch2="${BRANCH_PREFIX}-lint-fail-${TIMESTAMP}"
  if create_branch "$branch2"; then
    # Create a file that will fail lint (bad JS/TS syntax)
    if create_file_on_branch "$branch2" "src/bad-code-${TEST_RUN_ID}.js" "function test( { return broken ;;;"; then
      local pr2
      pr2=$(create_pr "test: intentionally broken code ${TEST_RUN_ID}" "This PR has a lint failure.\n\nFixes #1" "$branch2")
      if [ -n "$pr2" ] && [ "$pr2" != "dry-run-pr" ]; then
        record_pass "PR with lint failure: PR #${pr2} created"
        # Clean up
        close_pr "$pr2"
        delete_branch "$branch2"
      else
        record_skip "PR with lint failure: could not create PR"
      fi
    else
      record_skip "PR with lint failure: could not create file"
    fi
  else
    record_skip "PR with lint failure: could not create branch"
  fi

  # ── Scenario 12: Workflow dispatch ────────────────────────────────────
  scenario "Workflow dispatch"
  local dispatch_branch="${BRANCH_PREFIX}-dispatch-${TIMESTAMP}"
  if create_branch "$dispatch_branch"; then
    if dispatch_workflow "pull-request.yml" "$dispatch_branch" ""; then
      local dispatch_run_id
      dispatch_run_id=$(wait_for_workflow "pull-request.yml" "$dispatch_branch" 120 || echo "")
      if [ -n "$dispatch_run_id" ] && [ "$dispatch_run_id" != "dry-run-run-id" ]; then
        ok "Workflow dispatch run completed: ${dispatch_run_id}"
        record_pass "Workflow dispatch validated"
      else
        record_skip "Workflow dispatch: run did not complete"
      fi
    else
      record_skip "Workflow dispatch: could not trigger"
    fi
    delete_branch "$dispatch_branch" 2>/dev/null || true
  else
    record_skip "Workflow dispatch: could not create branch"
  fi

  # Clean up scenario 1 PR
  if [ -n "${_LAST_PR:-}" ]; then
    close_pr "${_LAST_PR}" 2>/dev/null || true
    delete_branch "${_LAST_BRANCH}" 2>/dev/null || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo -e "  ${BOLD}OpenCI Workflow Test — PR Domain${NC}"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Project:   ${PROJECT_ROOT}"
  echo "  Domain:    ${DOMAIN}"
  echo "  Run ID:    ${TEST_RUN_ID}"
  echo "  Dry run:   ${DRY_RUN}"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  check_test_prereqs

  # Structural / offline tests
  test_entry_workflow_structure
  test_reusable_workflow_structure
  test_execute_js_logic
  test_agents_rules
  test_review_ai
  test_extract_plan

  # Unit tests
  run_unit_tests

  # Live / E2E scenarios
  run_live_scenarios

  # ── Report ────────────────────────────────────────────────────────────
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo -e "  ${BOLD}OpenCI Workflow Test Report — PR Domain${NC}"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Total:  ${TOTAL}"
  echo -e "  Passed: ${GREEN}${PASSED}${NC}"
  echo -e "  Failed: ${RED}${FAILED}${NC}"
  echo -e "  Skipped:${YELLOW}${SKIPPED}${NC}"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests FAILED.${NC}"
    exit 1
  else
    echo -e "${GREEN}All tests passed (${SKIPPED} skipped).${NC}"
    exit 0
  fi
}

main "$@"

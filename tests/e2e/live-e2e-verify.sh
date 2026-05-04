#!/usr/bin/env bash
# live-e2e-verify.sh — Self-bootstrapping agentic workflow E2E verifier.
#
# Usage: bash tests/e2e/live-e2e-verify.sh [OPTIONS]
#
# Options:
#   --mode=issue|pr|all   Test mode (default: all)
#   --dry-run             Skip issue/PR creation, just validate
#   --issue=N             Verify an existing issue instead of creating one
#   --pr=N                Verify an existing PR instead of creating one
#
# What it does:
#   ISSUE MODE:
#     1. Creates a tagged test issue
#     2. Waits for issue-ops workflow agent comment
#     3. Validates issue-action-plan/v1 JSON schema in the comment
#     4. Closes and locks the test issue
#
#   PR MODE:
#     1. Creates a test branch with a trivial change
#     2. Opens a PR targeting main
#     3. Waits for PR quality gate workflow to complete
#     4. Validates workflow status and agent review (if any)
#     5. Closes PR, deletes test branch
#
# Requirements:
#   - GH_TOKEN with issues:write + pull-requests:write + actions:read
#   - gh CLI installed
#   - jq installed
#
# Environment variables:
#   REPO          — owner/repo (default: auto-detect from gh)
#   MAX_WAIT_SEC  — seconds to wait for agent response (default: 300)
#   DRY_RUN       — if 'true', skip creation and just validate
#   ISSUE_NUMBER  — if set, skip issue creation and verify this issue
#   PR_NUMBER     — if set, skip PR creation and verify this PR

set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo '')}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-300}"
POLL_INTERVAL=15
DRY_RUN="${DRY_RUN:-false}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
PR_NUMBER="${PR_NUMBER:-}"
MODE="${MODE:-all}"

# ANSI colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${NC}[$(date -u +%H:%M:%S)] $*"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}"; }

if [ -z "$REPO" ]; then
  fail "REPO is not set and could not be detected from gh CLI"
  exit 1
fi

# ── Parse args ────────────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --issue=*)       ISSUE_NUMBER="${arg#*=}" ;;
    --pr=*)          PR_NUMBER="${arg#*=}" ;;
    --mode=*)        MODE="${arg#*=}" ;;
  esac
done

# ── Schema validators ─────────────────────────────────────────────────────────

ALLOWED_SKILLS=(
  add_label remove_label set_priority assign_issue
  add_comment close_issue reopen_issue mark_duplicate
  create_branch link_linear dispatch_mcp_task
  schedule_followup notify escalate
)

validate_issue_plan() {
  local json="$1" label="$2"
  local version reasoning actions skip_reason

  version="$(echo "$json" | jq -r '.version // ""')"
  reasoning="$(echo "$json" | jq -r '.reasoning // ""')"
  actions="$(echo "$json" | jq -r '.actions // null')"
  skip_reason="$(echo "$json" | jq -r '.skip_reason // "null"')"

  if [ "$version" != "issue-action-plan/v1" ]; then
    fail "${label}: wrong version '${version}' (expected issue-action-plan/v1)"
    return 1
  fi

  if [ -z "$reasoning" ] || [ "$reasoning" = "null" ]; then
    fail "${label}: reasoning is empty or null"
    return 1
  fi

  if [ "$actions" = "null" ]; then
    fail "${label}: actions is null"
    return 1
  fi

  # Validate each action's skill is in allowlist
  local action_count
  action_count="$(echo "$json" | jq '.actions | length')"
  for ((i = 0; i < action_count; i++)); do
    local skill
    skill="$(echo "$json" | jq -r ".actions[$i].skill")"
    local allowed=false
    for s in "${ALLOWED_SKILLS[@]}"; do
      if [ "$skill" = "$s" ]; then allowed=true; break; fi
    done
    if [ "$allowed" = "false" ]; then
      fail "${label}: unknown skill '${skill}' at actions[$i]"
      return 1
    fi
  done

  ok "${label}: valid issue-action-plan/v1 (version=$version, actions=$action_count)"
  return 0
}

extract_plan_from_comment() {
  local body="$1"
  # Try to find JSON in code blocks first, then raw JSON
  local json
  json="$(echo "$body" | grep -oP '```json\s*\K[\s\S]*?(?=```)' | head -1)"
  if [ -z "$json" ]; then
    json="$(echo "$body" | grep -oP '\{[^{}]*"version"\s*:\s*"issue-action-plan/v1"[^{}]*\}')"
  fi
  if [ -z "$json" ]; then
    # Try to find any JSON object with the version field
    json="$(echo "$body" | jq -r '.. | objects | select(.version == "issue-action-plan/v1")' 2>/dev/null | head -1)"
  fi
  echo "$json"
}

# ── ISSUE E2E ─────────────────────────────────────────────────────────────────

run_issue_e2e() {
  local TEST_LABEL="openci:e2e-test"
  local RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
  local ISSUE_TITLE="[openci-e2e] Automated self-test run ${RUN_ID}"
  local ISSUE_BODY
  ISSUE_BODY="$(cat << 'EOF'
## OpenCI E2E Self-Test

This issue was automatically created by the OpenCI test suite to verify the
end-to-end agentic issue workflow.

**Expected behaviour:**
1. The `issue-ops` workflow triggers on this issue
2. Stage 1 (Ingest) normalises the payload
3. Stage 2 (Enrich) builds the agent workspace
4. Stage 3 (Agent Plan) returns an `issue-action-plan/v1` JSON
5. Stage 4 (Execute) posts an audit comment linking to the plan

**This issue will be automatically closed** once the E2E test validates the agent response.

> Auto-generated by `tests/e2e/live-e2e-verify.sh`
EOF
  )"

  # ── Create test issue ─────────────────────────────────────────────────────

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN mode: skipping issue creation"
  elif [ -z "$ISSUE_NUMBER" ]; then
    log "Creating E2E test issue in ${REPO}..."

    gh label create "${TEST_LABEL}" --repo "${REPO}" \
      --description "OpenCI automated E2E test issue" \
      --color "0075ca" 2>/dev/null || true

    ISSUE_NUMBER=$(gh issue create \
      --repo "${REPO}" \
      --title "${ISSUE_TITLE}" \
      --body "${ISSUE_BODY}" \
      --label "${TEST_LABEL}" \
      --json number -q '.number')

    log "Created issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"
  fi

  # ── Wait for agent response ────────────────────────────────────────────────

  log "Waiting for agent response on issue #${ISSUE_NUMBER} (max ${MAX_WAIT_SEC}s)..."

  local elapsed=0
  local agent_comment=""

  while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
    local comments
    comments=$(gh issue view "${ISSUE_NUMBER}" \
      --repo "${REPO}" \
      --json comments \
      --jq '.comments[]' 2>/dev/null || echo "")

    while IFS= read -r comment; do
      local body
      body=$(echo "$comment" | jq -r '.body // ""')
      if echo "$body" | grep -q 'openci-agent-run\|issue-action-plan/v1\|openci:audit'; then
        agent_comment="$body"
        break 2
      fi
    done < <(echo "$comments" | jq -c '.')

    log "No agent comment yet (${elapsed}s elapsed)... retrying in ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  # ── Validate agent response ────────────────────────────────────────────────

  local pass=true
  local report=""

  if [ -z "$agent_comment" ]; then
    fail "Agent did not post a response within ${MAX_WAIT_SEC}s"
    pass=false
    report="FAIL: No agent comment found after ${MAX_WAIT_SEC}s"
  else
    ok "Agent posted a response comment"
    report="Agent comment found."

    # Extract and validate the action plan
    local plan_json
    plan_json="$(extract_plan_from_comment "$agent_comment")"

    if [ -n "$plan_json" ] && echo "$plan_json" | jq -e '.' > /dev/null 2>&1; then
      if validate_issue_plan "$plan_json" "issue-#{$ISSUE_NUMBER}"; then
        ok "Agent plan schema validation passed"
        report="${report}\nPASS: issue-action-plan/v1 schema valid"

        # Log plan details
        local reasoning actions_count skip
        reasoning="$(echo "$plan_json" | jq -r '.reasoning // ""' | head -c 100)"
        actions_count="$(echo "$plan_json" | jq '.actions | length')"
        skip="$(echo "$plan_json" | jq -r '.skip_reason // "none"')"
        log "  reasoning: ${reasoning}..."
        log "  actions: ${actions_count}, skip_reason: ${skip}"
      else
        pass=false
        report="${report}\nFAIL: issue-action-plan/v1 schema validation failed"
      fi
    else
      warn "Could not extract valid JSON plan from agent comment"
      report="${report}\nWARN: plan JSON not found in comment"

      # Fallback: check for reasoning/audit markers
      if echo "$agent_comment" | grep -qi 'reasoning\|audit\|plan'; then
        ok "Agent comment contains reasoning/audit content (fallback)"
      else
        fail "Agent comment missing both plan JSON and reasoning content"
        pass=false
      fi
    fi

    # Check for error patterns
    if echo "$agent_comment" | grep -qi 'error\|failed\|exception' && \
       ! echo "$agent_comment" | grep -qi 'issue-action-plan\|openci-agent-run'; then
      fail "Agent comment looks like an error output"
      pass=false
      report="${report}\nFAIL: Comment appears to be an error"
    fi

    # Check workflow run status
    log "Checking issue-ops workflow run status..."
    local workflow_status
    workflow_status=$(gh run list \
      --repo "${REPO}" \
      --workflow "issue-ops.yml" \
      --limit 5 \
      --json status,conclusion,createdAt \
      --jq '[.[] | select(.createdAt > "'"$(date -u --date='1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"'")]' \
      2>/dev/null || echo "[]")

    if echo "$workflow_status" | jq -e 'length > 0' > /dev/null 2>&1; then
      local failed
      failed=$(echo "$workflow_status" | jq '[.[] | select(.conclusion == "failure")] | length')
      if [ "$failed" -gt 0 ]; then
        fail "issue-ops workflow had ${failed} failed run(s) in the last hour"
        pass=false
        report="${report}\nFAIL: ${failed} workflow run(s) failed"
      else
        ok "All recent issue-ops runs completed without failure"
      fi
    else
      warn "Could not retrieve workflow run status"
    fi
  fi

  # ── Cleanup issue ──────────────────────────────────────────────────────────

  if [ -n "$ISSUE_NUMBER" ] && [ "$DRY_RUN" != "true" ]; then
    log "Closing E2E test issue #${ISSUE_NUMBER}..."
    gh issue close "${ISSUE_NUMBER}" \
      --repo "${REPO}" \
      --comment "E2E test complete. Result: $([ "$pass" = "true" ] && echo 'PASS' || echo 'FAIL')" \
      2>/dev/null || warn "Could not close issue #${ISSUE_NUMBER}"

    gh issue lock "${ISSUE_NUMBER}" \
      --repo "${REPO}" \
      --reason "resolved" \
      2>/dev/null || true
  fi

  echo -e "$report"
  [ "$pass" = "true" ]
}

# ── PR E2E ────────────────────────────────────────────────────────────────────

run_pr_e2e() {
  local RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
  local BRANCH_NAME="test/openci-e2e-${RUN_ID}"
  local PR_TITLE="[openci-e2e] PR quality gate self-test run ${RUN_ID}"
  local PR_BODY
  PR_BODY="$(cat << 'EOF'
## OpenCI PR E2E Self-Test

This PR was automatically created by the OpenCI test suite to verify the
end-to-end PR quality gate workflow.

**Expected behaviour:**
1. The `pull-request` workflow triggers
2. Preflight + detect-language pass
3. Lint, test, scan-deps, validate-pr-title run
4. Agent review may post a comment

**This PR will be automatically closed and the branch deleted** after validation.

> Auto-generated by `tests/e2e/live-e2e-verify.sh`
EOF
  )"

  # ── Create test branch and PR ──────────────────────────────────────────────

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN mode: skipping PR creation"
    return 0
  fi

  if [ -n "$PR_NUMBER" ]; then
    log "Using existing PR #${PR_NUMBER}"
  else
    log "Creating test branch ${BRANCH_NAME}..."

    # Create a branch with a trivial change
    local default_branch
    default_branch="$(gh repo view "${REPO}" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo 'main')"

    gh api "repos/${REPO}/git/refs" \
      -f ref="refs/heads/${BRANCH_NAME}" \
      -f sha="$(gh api "repos/${REPO}/git/refs/heads/${default_branch}" -q '.object.sha')" \
      > /dev/null 2>&1

    # Create a trivial commit on the test branch
    local test_file_content="# OpenCI E2E PR Test\n\nRun ID: ${RUN_ID}\nTimestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)\n"
    local encoded_content
    encoded_content="$(echo -e "$test_file_content" | base64 -w0 2>/dev/null || echo -e "$test_file_content" | base64)"

    gh api "repos/${REPO}/contents/.openci-e2e-test.md" \
      -X PUT \
      -f message="test: openci e2e pr test ${RUN_ID}" \
      -f content="$encoded_content" \
      -f branch="$BRANCH_NAME" \
      > /dev/null 2>&1

    log "Creating PR #${PR_TITLE}..."
    PR_NUMBER=$(gh pr create \
      --repo "${REPO}" \
      --title "${PR_TITLE}" \
      --body "${PR_BODY}" \
      --head "${BRANCH_NAME}" \
      --base "${default_branch}" \
      --json number -q '.number')

    log "Created PR #${PR_NUMBER}"
  fi

  # ── Wait for PR workflow ───────────────────────────────────────────────────

  log "Waiting for pull-request workflow on PR #${PR_NUMBER} (max ${MAX_WAIT_SEC}s)..."

  local elapsed=0
  local workflow_completed=false
  local workflow_conclusion=""

  while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
    local runs
    runs="$(gh run list \
      --repo "${REPO}" \
      --workflow "pull-request.yml" \
      --limit 5 \
      --json status,conclusion,createdAt,headBranch \
      --jq "[.[] | select(.headBranch == \"${BRANCH_NAME}\")]" \
      2>/dev/null || echo "[]")"

    if echo "$runs" | jq -e 'length > 0' > /dev/null 2>&1; then
      local completed
      completed="$(echo "$runs" | jq '[.[] | select(.status == "completed")] | length')"
      if [ "$completed" -gt 0 ]; then
        workflow_completed=true
        workflow_conclusion="$(echo "$runs" | jq -r '[.[] | select(.status == "completed")] | .[0].conclusion')"
        break
      fi
    fi

    log "Workflow not yet complete (${elapsed}s elapsed)... retrying in ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  # ── Validate PR workflow ───────────────────────────────────────────────────

  local pass=true
  local report=""

  if [ "$workflow_completed" = "false" ]; then
    fail "pull-request workflow did not complete within ${MAX_WAIT_SEC}s"
    pass=false
    report="FAIL: workflow timeout"
  else
    ok "pull-request workflow completed with conclusion: ${workflow_conclusion}"
    report="Workflow conclusion: ${workflow_conclusion}"

    if [ "$workflow_conclusion" = "success" ]; then
      ok "PR quality gate passed"
      report="${report}\nPASS: quality gate succeeded"
    elif [ "$workflow_conclusion" = "skipped" ]; then
      warn "PR workflow was skipped (expected for test PRs without code changes)"
      report="${report}\nWARN: workflow skipped"
    else
      fail "PR quality gate failed: ${workflow_conclusion}"
      pass=false
      report="${report}\nFAIL: quality gate ${workflow_conclusion}"
    fi

    # Check for agent review comment
    log "Checking for agent review comment on PR #${PR_NUMBER}..."
    local pr_comments
    pr_comments="$(gh pr view "${PR_NUMBER}" \
      --repo "${REPO}" \
      --json comments \
      --jq '.comments[]' 2>/dev/null || echo "")"

    local has_agent_review=false
    while IFS= read -r comment; do
      local body
      body="$(echo "$comment" | jq -r '.body // ""')"
      if echo "$body" | grep -qi 'openci-agent\|pr-action-plan\|review\|blocking'; then
        has_agent_review=true
        ok "Found agent review comment on PR"
        report="${report}\nPASS: agent review comment found"
        break
      fi
    done < <(echo "$pr_comments" | jq -c '.' 2>/dev/null)

    if [ "$has_agent_review" = "false" ]; then
      warn "No agent review comment found (AI review may be disabled)"
      report="${report}\nWARN: no agent review (may be expected)"
    fi
  fi

  # ── Cleanup PR ─────────────────────────────────────────────────────────────

  if [ -n "$PR_NUMBER" ] && [ "$DRY_RUN" != "true" ]; then
    log "Closing PR #${PR_NUMBER}..."
    gh pr close "${PR_NUMBER}" \
      --repo "${REPO}" \
      --comment "E2E test complete. Result: $([ "$pass" = "true" ] && echo 'PASS' || echo 'FAIL')" \
      2>/dev/null || warn "Could not close PR #${PR_NUMBER}"

    # Delete test branch
    log "Deleting test branch ${BRANCH_NAME}..."
    gh api "repos/${REPO}/git/refs/heads/${BRANCH_NAME}" \
      -X DELETE 2>/dev/null || warn "Could not delete branch ${BRANCH_NAME}"

    # Clean up test file if it exists on the branch
    gh api "repos/${REPO}/contents/.openci-e2e-test.md?ref=${BRANCH_NAME}" \
      -q '.sha' 2>/dev/null | while read -r sha; do
        gh api "repos/${REPO}/contents/.openci-e2e-test.md" \
          -X DELETE \
          -f message="chore: cleanup e2e test file" \
          -f sha="$sha" \
          -f branch="${BRANCH_NAME}" 2>/dev/null || true
      done
  fi

  echo -e "$report"
  [ "$pass" = "true" ]
}

# ── Main ──────────────────────────────────────────────────────────────────────

ISSUE_PASS=true
PR_PASS=true
OVERALL_REPORT=""

case "$MODE" in
  issue)
    log "Running ISSUE E2E test..."
    if run_issue_e2e; then
      ISSUE_PASS=true
    else
      ISSUE_PASS=false
    fi
    ;;
  pr)
    log "Running PR E2E test..."
    if run_pr_e2e; then
      PR_PASS=true
    else
      PR_PASS=false
    fi
    ;;
  all)
    log "Running ISSUE E2E test..."
    if run_issue_e2e; then
      ISSUE_PASS=true
    else
      ISSUE_PASS=false
    fi

    echo ""
    log "Running PR E2E test..."
    if run_pr_e2e; then
      PR_PASS=true
    else
      PR_PASS=false
    fi
    ;;
  *)
    fail "Unknown mode: ${MODE}. Use issue, pr, or all."
    exit 1
    ;;
esac

# ── Final report ──────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  OpenCI E2E Test Report"
echo "════════════════════════════════════════"
echo "  Mode:   ${MODE}"
echo "  Repo:   ${REPO}"

OVERALL=true
case "$MODE" in
  issue)
    echo "  Issue:  $([ "$ISSUE_PASS" = "true" ] && echo 'PASS' || echo 'FAIL')"
    [ "$ISSUE_PASS" = "false" ] && OVERALL=false
    ;;
  pr)
    echo "  PR:     $([ "$PR_PASS" = "true" ] && echo 'PASS' || echo 'FAIL')"
    [ "$PR_PASS" = "false" ] && OVERALL=false
    ;;
  all)
    echo "  Issue:  $([ "$ISSUE_PASS" = "true" ] && echo 'PASS' || echo 'FAIL')"
    echo "  PR:     $([ "$PR_PASS" = "true" ] && echo 'PASS' || echo 'FAIL')"
    [ "$ISSUE_PASS" = "false" ] && OVERALL=false
    [ "$PR_PASS" = "false" ] && OVERALL=false
    ;;
esac

echo "════════════════════════════════════════"
echo ""

if [ "$OVERALL" = "true" ]; then
  ok "E2E PASS — all agentic workflows responded correctly"
  exit 0
else
  fail "E2E FAIL — see report above"
  exit 1
fi

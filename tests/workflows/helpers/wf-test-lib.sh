#!/usr/bin/env bash
# wf-test-lib.sh — Shared test library for OpenCI workflow E2E tests.
#
# Source this file in domain test scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/../helpers/wf-test-lib.sh"
#
# Environment variables (auto-loaded from Doppler if available):
#   GH_TOKEN           — GitHub personal access token
#   ANTHROPIC_API_KEY  — Claude API key for agentic workflows
#   DOPPLER_TOKEN      — Doppler service token (optional, for secrets)
#   REPO               — owner/repo (default: auto-detect from git remote)
#   MAX_WAIT_SEC       — seconds to wait for workflow (default: 600)
#   POLL_INTERVAL      — seconds between polls (default: 15)
#   DRY_RUN            — if 'true', skip live operations
#   SKIP_AGENT_TESTS   — if 'true', skip scenarios needing ANTHROPIC_API_KEY
#   SKIP_DOCKER_TESTS  — if 'true', skip scenarios needing Docker
#
# Test metadata set by each domain script before sourcing:
#   DOMAIN             — e.g. "issue", "pr", "agent", "ci", "docs", "maintenance"
#   TEST_RUN_ID        — unique ID for this test run (default: timestamp)

set -euo pipefail

# ── Path setup ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ── ANSI colours ────────────────────────────────────────────────────────────────

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

# ── Defaults ────────────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:-unknown}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_AGENT_TESTS="${SKIP_AGENT_TESTS:-false}"
SKIP_DOCKER_TESTS="${SKIP_DOCKER_TESTS:-false}"
TEST_LABEL="openci:test:${DOMAIN}:${TEST_RUN_ID}"
REPO="${REPO:-}"

# ── Results tracking ────────────────────────────────────────────────────────────

SCENARIOS_TOTAL=0
SCENARIOS_PASSED=0
SCENARIOS_FAILED=0
SCENARIOS_SKIPPED=0

record_pass()  { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL + 1)); SCENARIOS_PASSED=$((SCENARIOS_PASSED + 1)); ok "PASS: $1"; }
record_fail()  { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL + 1)); SCENARIOS_FAILED=$((SCENARIOS_FAILED + 1)); fail "FAIL: $1"; }
record_skip()  { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL + 1)); SCENARIOS_SKIPPED=$((SCENARIOS_SKIPPED + 1)); warn "SKIP: $1"; }

# ── Doppler secrets loading ─────────────────────────────────────────────────────

load_secrets() {
  # Try Doppler first
  if [ -n "${DOPPLER_TOKEN:-}" ] && command -v doppler &>/dev/null; then
    log "Loading secrets from Doppler (project: openci-test, config: prd)..."
    eval "$(doppler run --project openci-test --config prd -- env 2>/dev/null || true)"
  elif [ -x /tmp/doppler ] && [ -n "${DOPPLER_TOKEN:-}" ]; then
    log "Loading secrets from Doppler CLI (/tmp/doppler)..."
    export DOPPLER_TOKEN
    eval "$(/tmp/doppler run --project openci-test --config prd -- env 2>/dev/null || true)"
  fi

  # Prefer MY_GITHUB_TOKEN as GH_TOKEN if GH_TOKEN is not set
  if [ -z "${GH_TOKEN:-}" ] && [ -n "${MY_GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="$MY_GITHUB_TOKEN"
  fi
}

# ── Prerequisites check ─────────────────────────────────────────────────────────

check_prereqs() {
  local missing=()

  if ! command -v gh &>/dev/null; then
    missing+=("gh CLI (github.com/cli/cli)")
  fi
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing required tools: ${missing[*]}"
    exit 1
  fi

  # Detect repo if not set
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo '')"
    if [ -z "$REPO" ]; then
      # Fallback: parse from git remote
      REPO="$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]\(.*\)\.git|\1|' || echo '')"
    fi
  fi

  if [ -z "$REPO" ]; then
    fail "REPO is not set and could not be detected. Set REPO=owner/repo or ensure gh CLI is authenticated."
    exit 1
  fi

  log "Target repo: ${REPO}"
  log "Test run ID: ${TEST_RUN_ID}"
  log "Domain:      ${DOMAIN}"

  # Check auth status
  if ! gh auth status &>/dev/null; then
    warn "gh CLI is not authenticated — live tests will fail"
    warn "Run: gh auth login"
    if [ "$DRY_RUN" != "true" ]; then
      warn "Enabling DRY_RUN mode due to missing auth"
      DRY_RUN=true
    fi
  fi

  # Check API key
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    SKIP_AGENT_TESTS=true
    warn "ANTHROPIC_API_KEY not set — agent-dependent scenarios will be skipped"
  fi
}

# ── GitHub API helpers ──────────────────────────────────────────────────────────

ensure_label() {
  local label="$1" description="${2:-OpenCI automated test}" color="${3:-0075ca}"
  gh label create "${label}" --repo "${REPO}" \
    --description "${description}" \
    --color "${color}" 2>/dev/null || true
}

create_issue() {
  local title="$1" body="$2" labels="${3:-}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would create issue '${title}'"
    echo "dry-run-issue"
    return 0
  fi
  local extra_args=()
  [ -n "$labels" ] && extra_args+=(--label "$labels")
  gh issue create \
    --repo "${REPO}" \
    --title "${title}" \
    --body "${body}" \
    "${extra_args[@]}" \
    --json number -q '.number'
}

create_branch() {
  local branch="$1" base="${2:-main}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would create branch '${branch}'"
    return 0
  fi
  local base_sha
  base_sha="$(gh api "repos/${REPO}/git/refs/heads/${base}" -q '.object.sha')"
  gh api "repos/${REPO}/git/refs" \
    -f ref="refs/heads/${branch}" \
    -f sha="$base_sha" > /dev/null 2>&1
}

create_file_on_branch() {
  local branch="$1" path="$2" content="$3" message="${4:-test: add test file}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would create file '${path}' on branch '${branch}'"
    return 0
  fi
  local encoded
  encoded="$(echo -e "$content" | base64 -w0 2>/dev/null || echo -e "$content" | base64)"
  gh api "repos/${REPO}/contents/${path}" \
    -X PUT \
    -f message="$message" \
    -f content="$encoded" \
    -f branch="$branch" > /dev/null 2>&1
}

create_pr() {
  local title="$1" body="$2" branch="$3" base="${4:-main}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would create PR '${title}' from branch '${branch}'"
    echo "dry-run-pr"
    return 0
  fi
  gh pr create \
    --repo "${REPO}" \
    --title "${title}" \
    --body "${body}" \
    --head "${branch}" \
    --base "${base}" \
    --json number -q '.number'
}

create_draft_pr() {
  local title="$1" body="$2" branch="$3" base="${4:-main}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would create draft PR '${title}' from branch '${branch}'"
    echo "dry-run-draft-pr"
    return 0
  fi
  gh pr create \
    --repo "${REPO}" \
    --title "${title}" \
    --body "${body}" \
    --head "${branch}" \
    --base "${base}" \
    --draft \
    --json number -q '.number'
}

mark_pr_ready() {
  local pr="$1"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would mark PR #${pr} as ready for review"
    return 0
  fi
  gh pr ready "${pr}" --repo "${REPO}"
}

add_pr_comment() {
  local pr="$1" body="$2"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would comment on PR #${pr}"
    return 0
  fi
  gh pr comment "${pr}" --repo "${REPO}" --body "${body}"
}

add_issue_comment() {
  local issue="$1" body="$2"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would comment on issue #${issue}"
    return 0
  fi
  gh issue comment "${issue}" --repo "${REPO}" --body "${body}"
}

close_issue() {
  local issue="$1" reason="${2:-completed}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would close issue #${issue}"
    return 0
  fi
  gh issue close "${issue}" --repo "${REPO}" --reason "${reason}" 2>/dev/null || true
}

reopen_issue() {
  local issue="$1"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would reopen issue #${issue}"
    return 0
  fi
  gh issue reopen "${issue}" --repo "${REPO}" 2>/dev/null || true
}

edit_issue() {
  local issue="$1" title="${2:-}" body="${3:-}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would edit issue #${issue}"
    return 0
  fi
  local extra_args=()
  [ -n "$title" ] && extra_args+=(--title "$title")
  [ -n "$body" ] && extra_args+=(--body "$body")
  gh issue edit "${issue}" --repo "${REPO}" "${extra_args[@]}"
}

close_pr() {
  local pr="$1"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would close PR #${pr}"
    return 0
  fi
  gh pr close "${pr}" --repo "${REPO}" 2>/dev/null || true
}

delete_branch() {
  local branch="$1"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would delete branch '${branch}'"
    return 0
  fi
  gh api "repos/${REPO}/git/refs/heads/${branch}" -X DELETE 2>/dev/null || true
}

dispatch_workflow() {
  local workflow="$1" ref="${2:-main}" inputs="${3:-}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would dispatch workflow '${workflow}'"
    return 0
  fi
  local extra_args=()
  if [ -n "$inputs" ]; then
    # inputs is a JSON string or key=value pairs
    if echo "$inputs" | jq -e '.' >/dev/null 2>&1; then
      # It's JSON — convert to -f key=value
      while IFS='=' read -r key value; do
        [ -n "$key" ] && extra_args+=(-f "${key}=${value}")
      done < <(echo "$inputs" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    else
      # Already key=value format (space separated)
      for pair in $inputs; do
        extra_args+=(-f "$pair")
      done
    fi
  fi
  gh workflow run "${workflow}" --repo "${REPO}" --ref "${ref}" "${extra_args[@]}"
}

# ── Workflow monitoring ─────────────────────────────────────────────────────────

# Wait for a workflow run matching the given branch filter to complete.
# Returns the run databaseId via stdout.
wait_for_workflow() {
  local workflow_file="$1" branch_filter="${2:-}" timeout="${3:-$MAX_WAIT_SEC}"

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would wait for workflow '${workflow_file}'"
    echo "dry-run-run-id"
    return 0
  fi

  local elapsed=0
  local run_id=""

  while [ "$elapsed" -lt "$timeout" ]; do
    local runs_json
    runs_json="$(gh run list \
      --repo "${REPO}" \
      --workflow "${workflow_file}" \
      --limit 10 \
      --json databaseId,status,conclusion,headBranch,createdAt,event \
      2>/dev/null || echo "[]")"

    # Filter by branch if provided, otherwise take the most recent
    local match
    if [ -n "$branch_filter" ]; then
      match="$(echo "$runs_json" | jq -r \
        "[.[] | select(.headBranch == \"${branch_filter}\")] | sort_by(-.createdAt) | .[0]")"
    else
      match="$(echo "$runs_json" | jq -r '.[0]')"
    fi

    if [ "$match" != "null" ] && [ -n "$match" ]; then
      local status conclusion
      status="$(echo "$match" | jq -r '.status')"
      conclusion="$(echo "$match" | jq -r '.conclusion')"

      if [ "$status" = "completed" ]; then
        run_id="$(echo "$match" | jq -r '.databaseId')"
        info "Workflow completed: run_id=${run_id} conclusion=${conclusion}"
        echo "$run_id"
        return 0
      fi

      if [ -z "$run_id" ]; then
        run_id="$(echo "$match" | jq -r '.databaseId')"
        info "Workflow running: run_id=${run_id} status=${status} (${elapsed}s elapsed)"
      fi
    else
      info "Waiting for workflow '${workflow_file}' to start... (${elapsed}s elapsed)"
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  fail "Workflow '${workflow_file}' did not complete within ${timeout}s"
  echo ""
  return 1
}

# Wait for multiple workflow runs (e.g., issue-ops lifecycle + maintenance)
# Returns the last matching run ID
wait_for_workflow_runs() {
  local workflow_file="$1" min_runs="${2:-1}" timeout="${3:-$MAX_WAIT_SEC}"

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would wait for workflow runs of '${workflow_file}'"
    echo "dry-run-run-id"
    return 0
  fi

  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local completed_count
    completed_count="$(gh run list \
      --repo "${REPO}" \
      --workflow "${workflow_file}" \
      --limit 20 \
      --json status,createdAt \
      --jq "[.[] | select(.status == \"completed\")] | length" \
      2>/dev/null || echo "0")"

    if [ "$completed_count" -ge "$min_runs" ]; then
      local latest_id
      latest_id="$(gh run list \
        --repo "${REPO}" \
        --workflow "${workflow_file}" \
        --limit 5 \
        --json databaseId,status,conclusion \
        --jq '[.[] | select(.status == "completed")] | .[0].databaseId' \
        2>/dev/null)"
      echo "$latest_id"
      return 0
    fi

    info "Waiting for ${min_runs} completed runs (have ${completed_count})... (${elapsed}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  fail "Only ${completed_count:-0}/${min_runs} workflow runs completed within ${timeout}s"
  echo ""
  return 1
}

# Get JSON of all jobs in a run
get_workflow_jobs() {
  local run_id="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo '[]'
    return 0
  fi
  gh run view "${run_id}" --repo "${REPO}" --json jobs 2>/dev/null || echo '{}'
}

# Get logs for a specific job
get_job_logs() {
  local run_id="$1" job_name="$2"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY_RUN] Would fetch logs for job '${job_name}' in run ${run_id}"
    return 0
  fi
  gh run view "${run_id}" --repo "${REPO}" --log --job "${job_name}" 2>/dev/null || echo ""
}

# Get all logs for a run
get_run_logs() {
  local run_id="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY_RUN] Would fetch all logs for run ${run_id}"
    return 0
  fi
  gh run view "${run_id}" --repo "${REPO}" --log 2>/dev/null || echo ""
}

# ── Verification helpers ────────────────────────────────────────────────────────

# Assert a job concluded with a specific status
assert_job_conclusion() {
  local run_id="$1" job_name="$2" expected="${3:-success}"
  local jobs_json
  jobs_json="$(get_workflow_jobs "$run_id")"

  local conclusion
  conclusion="$(echo "$jobs_json" | jq -r \
    ".jobs[] | select(.name == \"${job_name}\") | .conclusion // \"NOT_FOUND\"")"

  if [ "$conclusion" = "$expected" ]; then
    ok "Job '${job_name}' concluded: ${conclusion}"
    return 0
  elif [ "$conclusion" = "NOT_FOUND" ]; then
    fail "Job '${job_name}' not found in run ${run_id}"
    return 1
  else
    fail "Job '${job_name}' expected '${expected}' but got '${conclusion}'"
    return 1
  fi
}

# Assert a job is NOT skipped
assert_job_not_skipped() {
  local run_id="$1" job_name="$2"
  local jobs_json
  jobs_json="$(get_workflow_jobs "$run_id")"

  local conclusion
  conclusion="$(echo "$jobs_json" | jq -r \
    ".jobs[] | select(.name == \"${job_name}\") | .conclusion // \"NOT_FOUND\"")"

  if [ "$conclusion" = "skipped" ]; then
    fail "Job '${job_name}' was unexpectedly skipped"
    return 1
  elif [ "$conclusion" = "NOT_FOUND" ]; then
    fail "Job '${job_name}' not found in run ${run_id}"
    return 1
  else
    ok "Job '${job_name}' ran (conclusion: ${conclusion})"
    return 0
  fi
}

# Assert a step output or log line contains a pattern
assert_step_output() {
  local run_id="$1" job_name="$2" pattern="$3" label="${4:-step output check}"
  local logs
  logs="$(get_job_logs "$run_id" "$job_name")"

  if echo "$logs" | grep -q "$pattern"; then
    ok "${label}: pattern '${pattern}' found in '${job_name}' logs"
    return 0
  else
    fail "${label}: pattern '${pattern}' NOT found in '${job_name}' logs"
    return 1
  fi
}

# Assert a step output does NOT contain a pattern (e.g., no errors)
assert_no_step_output() {
  local run_id="$1" job_name="$2" pattern="$3" label="${4:-negative step check}"
  local logs
  logs="$(get_job_logs "$run_id" "$job_name")"

  if echo "$logs" | grep -q "$pattern"; then
    fail "${label}: unexpected pattern '${pattern}' found in '${job_name}' logs"
    return 1
  else
    ok "${label}: pattern '${pattern}' NOT found in '${job_name}' logs"
    return 0
  fi
}

# ── Comment verification ────────────────────────────────────────────────────────

# Get all comments on an issue
get_issue_comments() {
  local issue="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[]"
    return 0
  fi
  gh issue view "${issue}" --repo "${REPO}" --json comments --jq '.comments[]' 2>/dev/null || echo ""
}

# Get all comments on a PR
get_pr_comments() {
  local pr="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[]"
    return 0
  fi
  gh pr view "${pr}" --repo "${REPO}" --json comments --jq '.comments[]' 2>/dev/null || echo ""
}

# Wait for an agent comment containing a marker on an issue
wait_for_agent_comment() {
  local issue="$1" marker="${2:-openci-agent-run}" timeout="${3:-$MAX_WAIT_SEC}"

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would wait for agent comment on issue #${issue}"
    echo '{"body": "{\"version\":\"issue-action-plan/v1\",\"reasoning\":\"dry-run\",\"actions\":[]}"}'
    return 0
  fi

  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local comments
    comments="$(get_issue_comments "$issue")"

    while IFS= read -r comment; do
      [ -z "$comment" ] && continue
      local body
      body="$(echo "$comment" | jq -r '.body // ""')"
      if echo "$body" | grep -q "$marker"; then
        ok "Agent comment found after ${elapsed}s"
        echo "$body"
        return 0
      fi
    done < <(echo "$comments" | jq -c '.' 2>/dev/null)

    info "Waiting for agent comment on issue #${issue}... (${elapsed}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  fail "No agent comment found on issue #${issue} within ${timeout}s"
  echo ""
  return 1
}

# Wait for an agent comment on a PR
wait_for_pr_agent_comment() {
  local pr="$1" marker="${2:-openci-agent}" timeout="${3:-$MAX_WAIT_SEC}"

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would wait for agent comment on PR #${pr}"
    return 0
  fi

  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local comments
    comments="$(get_pr_comments "$pr")"

    while IFS= read -r comment; do
      [ -z "$comment" ] && continue
      local body
      body="$(echo "$comment" | jq -r '.body // ""')"
      if echo "$body" | grep -q "$marker"; then
        ok "PR agent comment found after ${elapsed}s"
        echo "$body"
        return 0
      fi
    done < <(echo "$comments" | jq -c '.' 2>/dev/null)

    info "Waiting for agent comment on PR #${pr}... (${elapsed}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  warn "No agent comment found on PR #${pr} within ${timeout}s (may be expected without API key)"
  return 0  # Not a hard failure — agent may be disabled
}

# ── Schema validators ───────────────────────────────────────────────────────────

# Allowed issue skills (must match actions/issue/execute-plan/execute.js)
ISSUE_ALLOWED_SKILLS=(
  add_label remove_label set_priority assign_issue
  add_comment close_issue reopen_issue mark_duplicate
  create_branch link_linear dispatch_mcp_task
  schedule_followup notify escalate
)

ISSUE_HIGH_RISK_SKILLS=(close_issue reopen_issue create_branch dispatch_mcp_task)

# Allowed PR skills (must match actions/pr/execute-plan/execute.js)
PR_ALLOWED_SKILLS=(
  add_label remove_label add_reviewer request_changes
  block_merge escalate assign_issue
)

validate_issue_plan() {
  local json="$1" label="${2:-issue-plan}"
  local version reasoning actions

  if ! echo "$json" | jq -e '.' > /dev/null 2>&1; then
    fail "${label}: not valid JSON"
    return 1
  fi

  version="$(echo "$json" | jq -r '.version // ""')"
  reasoning="$(echo "$json" | jq -r '.reasoning // ""')"
  actions="$(echo "$json" | jq -r '.actions // null')"

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
    skill="$(echo "$json" | jq -r ".actions[$i].skill // \"\"")"
    local allowed=false
    for s in "${ISSUE_ALLOWED_SKILLS[@]}"; do
      if [ "$skill" = "$s" ]; then allowed=true; break; fi
    done
    if [ "$allowed" = "false" ]; then
      fail "${label}: unknown skill '${skill}' at actions[$i]"
      return 1
    fi
  done

  ok "${label}: valid issue-action-plan/v1 (version=${version}, actions=${action_count})"
  return 0
}

validate_pr_plan() {
  local json="$1" label="${2:-pr-plan}"
  local version reasoning actions

  if ! echo "$json" | jq -e '.' > /dev/null 2>&1; then
    fail "${label}: not valid JSON"
    return 1
  fi

  version="$(echo "$json" | jq -r '.version // ""')"
  reasoning="$(echo "$json" | jq -r '.reasoning // ""')"
  actions="$(echo "$json" | jq -r '.actions // null')"

  if [ "$version" != "pr-action-plan/v1" ]; then
    fail "${label}: wrong version '${version}' (expected pr-action-plan/v1)"
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

  local action_count
  action_count="$(echo "$json" | jq '.actions | length')"
  for ((i = 0; i < action_count; i++)); do
    local skill confidence
    skill="$(echo "$json" | jq -r ".actions[$i].skill // \"\"")"
    confidence="$(echo "$json" | jq -r ".actions[$i].confidence // \"medium\"")"

    local allowed=false
    for s in "${PR_ALLOWED_SKILLS[@]}"; do
      if [ "$skill" = "$s" ]; then allowed=true; break; fi
    done
    if [ "$allowed" = "false" ]; then
      fail "${label}: unknown skill '${skill}' at actions[$i]"
      return 1
    fi

    # Check confidence is valid
    case "$confidence" in
      high|medium|low) ;;
      *) fail "${label}: invalid confidence '${confidence}' at actions[$i]"; return 1 ;;
    esac
  done

  ok "${label}: valid pr-action-plan/v1 (version=${version}, actions=${action_count})"
  return 0
}

# Extract a plan JSON from an agent comment body
extract_plan_from_comment() {
  local body="$1"
  local json

  # Strategy 1: JSON code block
  json="$(echo "$body" | grep -oP '```json\s*\K[\s\S]*?(?=```)' | head -1)"
  [ -n "$json" ] && echo "$json" && return 0

  # Strategy 2: Direct JSON object with version field
  json="$(echo "$body" | jq -r '.. | objects | select(.version == "issue-action-plan/v1" or .version == "pr-action-plan/v1")' 2>/dev/null | head -1)"
  [ -n "$json" ] && [ "$json" != "null" ] && echo "$json" && return 0

  # Strategy 3: Raw JSON block
  json="$(echo "$body" | grep -oP '\{"version"\s*:\s*"[^"]+"[^}]*\}' | head -1)"
  [ -n "$json" ] && echo "$json" && return 0

  return 1
}

# ── Bug reporting ───────────────────────────────────────────────────────────────

file_bug_report() {
  local workflow="$1" scenario_name="$2" run_id="${3:-unknown}" details="${4:-}"

  local title="[bot] Workflow Test Failure: ${DOMAIN}/${workflow} — ${scenario_name}"

  # Check if a similar issue was already filed
  if gh issue list --repo "${REPO}" --search "${title}" --state open --json number \
    --jq 'length' 2>/dev/null | grep -qv '0' 2>/dev/null; then
    warn "Similar bug report already exists for '${scenario_name}', skipping"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would file bug report: ${title}"
    return 0
  fi

  local body
  body="$(cat <<ISSUE_BODY
## Automated Workflow Test Failure

**Workflow:** \`${workflow}\`
**Domain:** \`${DOMAIN}\`
**Scenario:** ${scenario_name}
**Run ID:** ${run_id}
**Test Run ID:** ${TEST_RUN_ID}
**Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

### Failure Details

\`\`\`
${details}
\`\`\`

### Workflow Run

[View run #${run_id}](https://github.com/${REPO}/actions/runs/${run_id})

---
Auto-generated by OpenCI workflow test framework (\`${DOMAIN}\` domain).
Label: \`test-failure\`
ISSUE_BODY
)"

  gh issue create \
    --repo "${REPO}" \
    --title "${title}" \
    --body "${body}" \
    --label "bug,test-failure" \
    --json url -q '.url' 2>/dev/null || warn "Could not file bug report"
}

# ── Cleanup ─────────────────────────────────────────────────────────────────────

cleanup_test_issue() {
  local issue="$1" result="${2:-completed}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would cleanup issue #${issue}"
    return 0
  fi
  [ -z "$issue" ] && return 0
  info "Cleaning up test issue #${issue}..."
  gh issue close "${issue}" --repo "${REPO}" --reason "completed" \
    --comment "OpenCI workflow test ($DOMAIN) ${result}. Test run: ${TEST_RUN_ID}" \
    2>/dev/null || warn "Could not close issue #${issue}"
  gh issue lock "${issue}" --repo "${REPO}" --reason "resolved" 2>/dev/null || true
}

cleanup_test_pr() {
  local pr="$1" branch="$2" result="${3:-completed}"
  if [ "$DRY_RUN" = "true" ]; then
    warn "DRY_RUN: would cleanup PR #${pr}"
    return 0
  fi
  [ -z "$pr" ] && return 0
  info "Cleaning up test PR #${pr}..."
  gh pr close "${pr}" --repo "${REPO}" \
    --comment "OpenCI workflow test ($DOMAIN) ${result}. Test run: ${TEST_RUN_ID}" \
    2>/dev/null || warn "Could not close PR #${pr}"
  [ -n "$branch" ] && delete_branch "$branch"
}

# Interrupt handler
_cleanup_on_interrupt() {
  echo ""
  warn "Interrupted! Cleaning up test resources..."
  if [ -n "${_CURRENT_ISSUE:-}" ]; then
    cleanup_test_issue "${_CURRENT_ISSUE}" "interrupted" || true
  fi
  if [ -n "${_CURRENT_PR:-}" ]; then
    cleanup_test_pr "${_CURRENT_PR}" "${_CURRENT_BRANCH:-}" "interrupted" || true
  fi
  exit 1
}

# ── Test runner ─────────────────────────────────────────────────────────────────

# Run a test scenario with automatic pass/fail tracking and cleanup
# Usage: run_scenario "scenario name" function_name [args...]
run_scenario() {
  local name="$1" func="$2"
  shift 2
  scenario "$name"

  local result=0
  if "$func" "$@" 2>&1 | while IFS= read -r line; do echo "  $line"; done; then
    result=0
    record_pass "$name"
  else
    result=$?
    record_fail "$name"
    file_bug_report "${WORKFLOW_FILE:-unknown}" "$name" "${_LAST_RUN_ID:-unknown}" \
      "Scenario '${name}' failed with exit code ${result}" || true
  fi

  return $result
}

# Like run_scenario but also captures the workflow run ID
run_workflow_scenario() {
  local name="$1" workflow_file="$2" branch="${3:-}"
  shift 3

  WORKFLOW_FILE="$workflow_file"
  scenario "$name"

  local run_id
  if run_id=$(wait_for_workflow "$workflow_file" "$branch"); then
    _LAST_RUN_ID="$run_id"
    if "$@" "$run_id"; then
      record_pass "$name"
    else
      record_fail "$name"
      file_bug_report "$workflow_file" "$name" "$run_id" \
        "Scenario '${name}' verification failed for run ${run_id}" || true
    fi
  else
    record_fail "$name"
    file_bug_report "$workflow_file" "$name" "timeout" \
      "Scenario '${name}' timed out waiting for workflow" || true
  fi
}

# ── Print report ────────────────────────────────────────────────────────────────

print_report() {
  echo ""
  echo "══════════════════════════════════════════════"
  echo -e "  ${BOLD}OpenCI Workflow Test Report — ${DOMAIN}${NC}"
  echo "══════════════════════════════════════════════"
  echo "  Repo:     ${REPO}"
  echo "  Domain:   ${DOMAIN}"
  echo "  Run ID:   ${TEST_RUN_ID}"
  echo "  Total:    ${SCENARIOS_TOTAL}"
  echo -e "  Passed:   ${GREEN}${SCENARIOS_PASSED}${NC}"
  echo -e "  Failed:   ${RED}${SCENARIOS_FAILED}${NC}"
  echo -e "  Skipped:  ${YELLOW}${SCENARIOS_SKIPPED}${NC}"
  echo "══════════════════════════════════════════════"
  echo ""

  if [ "$SCENARIOS_FAILED" -gt 0 ]; then
    return 1
  else
    return 0
  fi
}

# ── Initialisation ──────────────────────────────────────────────────────────────

# Trap interrupt for cleanup
trap _cleanup_on_interrupt SIGINT SIGTERM

# Auto-load secrets and check prerequisites if not in library-only mode
if [ "${LIBRARY_ONLY:-false}" != "true" ]; then
  load_secrets
  check_prereqs

  header "OpenCI Workflow Test: ${DOMAIN}"
  log "Repo: ${REPO}"
  log "Run ID: ${TEST_RUN_ID}"
  log "Dry run: ${DRY_RUN}"
  log "Skip agent tests: ${SKIP_AGENT_TESTS}"
  log "Skip docker tests: ${SKIP_DOCKER_TESTS}"
  echo ""
fi

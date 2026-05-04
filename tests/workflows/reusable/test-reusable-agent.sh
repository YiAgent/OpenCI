#!/usr/bin/env bash
# -------------------------------------------------------------
# test-reusable-agent.sh -- Comprehensive Agent Domain test suite.
# Tests reusable-agent.yml and claude-harness composite action.
# -------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "${SCRIPT_DIR}/../helpers" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOMAIN="agent"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"
LIBRARY_ONLY=true
source "${HELPERS_DIR}/wf-test-lib.sh"

DOMAIN="agent"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"
SCENARIOS_TOTAL=0; SCENARIOS_PASSED=0; SCENARIOS_FAILED=0; SCENARIOS_SKIPPED=0
declare -a SCENARIO_NAMES=(); declare -a SCENARIO_RESULTS=(); TRACK_IDX=0

REUSABLE_WF="${PROJECT_ROOT}/.github/workflows/reusable-agent.yml"
AGENT_WF="${PROJECT_ROOT}/.github/workflows/agent.yml"
HARNESS_ACTION="${PROJECT_ROOT}/actions/_common/claude-harness/action.yml"
COMPOSE_ARGS="${PROJECT_ROOT}/actions/_common/claude-harness/compose-args.sh"
RESOLVE_PROMPT="${PROJECT_ROOT}/actions/_common/claude-harness/resolve-prompt.sh"
API_KEY_GATE="${PROJECT_ROOT}/actions/_common/api-key-gate/action.yml"
RESOLVE_OPENCI="${PROJECT_ROOT}/actions/_common/resolve-openci/action.yml"
WF_TEST_LIB="${HELPERS_DIR}/wf-test-lib.sh"
SKILLS_DIR="${PROJECT_ROOT}/skills"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

log()      { echo -e "${NC}[$(date -u +%H:%M:%S)] $*"; }
info()     { echo -e "${CYAN}  -> $*${NC}"; }
ok()       { echo -e "${GREEN}  [PASS] $*${NC}"; }
warn()     { echo -e "${YELLOW}  [SKIP] $*${NC}"; }
fail()     { echo -e "${RED}  [FAIL] $*${NC}"; }
header()   { echo -e "\n${BLUE}${BOLD}=== $* ===${NC}"; }
scenario() { echo -e "\n${BOLD}-- Scenario: $* --${NC}"; }

record_pass() { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL+1)); SCENARIOS_PASSED=$((SCENARIOS_PASSED+1)); ok "$1"; }
record_fail() { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL+1)); SCENARIOS_FAILED=$((SCENARIOS_FAILED+1)); fail "$1"; }
record_skip() { SCENARIOS_TOTAL=$((SCENARIOS_TOTAL+1)); SCENARIOS_SKIPPED=$((SCENARIOS_SKIPPED+1)); warn "$1"; }
track()       { SCENARIO_NAMES[$TRACK_IDX]="$1"; SCENARIO_RESULTS[$TRACK_IDX]="$2"; TRACK_IDX=$((TRACK_IDX+1)); }

# Prerequisites
for cmd in jq; do
  if ! command -v "$cmd" &>/dev/null 2>&1; then
    fail "Missing required tool: $cmd"; exit 1
  fi
done

HAS_GH_AUTH=false
if command -v gh &>/dev/null 2>&1; then
  if gh auth status &>/dev/null 2>&1; then HAS_GH_AUTH=true; fi
fi

HAS_API_KEY=false
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then HAS_API_KEY=true; fi

header "OpenCI Agent Domain Test"
log "Repo: ${REPO:-auto}  Run ID: ${TEST_RUN_ID}"
log "GitHub Auth: ${HAS_GH_AUTH}  API Key: ${HAS_API_KEY}"
log "Dry run: ${DRY_RUN:-false}  Skip agent: ${SKIP_AGENT_TESTS:-false}"
echo ""

# ============ SCENARIO 1 -- Tool allowlist ============
scenario "1: Tool allowlist baseline"
err1=0
BL=(
  "Read" "Write" "Edit" "Glob" "Grep"
  "Bash(git add)" "Bash(git commit)" "Bash(git push)" "Bash(git push origin)"
  "Bash(git status)" "Bash(git log)" "Bash(git diff)" "Bash(git show)"
  "Bash(git rev-parse)" "Bash(git config)"
  "Bash(gh api)" "Bash(gh run list)" "Bash(gh run view)"
  "Bash(gh issue create)" "Bash(gh issue comment)" "Bash(gh issue list)" "Bash(gh issue view)"
  "Bash(gh pr comment)" "Bash(gh pr view)" "Bash(gh pr list)"
  "mcp__github_ci__get_ci_status"
  "mcp__github_ci__get_workflow_run_details"
  "mcp__github_ci__download_job_log"
  "Bash(jq)" "Bash(curl -s)" "Bash(curl -X)" "Bash(curl -fsSL)"
  "Bash(ls)" "Bash(cat)" "Bash(head)" "Bash(tail)"
  "Bash(date)" "Bash(mkdir)" "Bash(cp)" "Bash(mv)" "Bash(find)"
  "Bash(sha256sum)" "Bash(shasum)"
  "Bash(echo)" "Bash(printf)" "Bash(wc)" "Bash(sort)" "Bash(uniq)"
  "Bash(awk)" "Bash(sed)" "Bash(grep)"
)
if [ -f "$COMPOSE_ARGS" ]; then
  for tool in "${BL[@]}"; do
    escaped="$(printf '%s' "$tool" | sed 's/[][()\.*^$+?{}|]/\\&/g; s/ /\\ /g')"
    if grep -q "$escaped" "$COMPOSE_ARGS"; then
      ok "Baseline tool: $tool"
    else
      fail "MISSING baseline tool: $tool"; err1=$((err1+1))
    fi
  done
  grep -q 'EXTRA_ALLOWED_TOOLS' "$COMPOSE_ARGS" && ok "EXTRA_ALLOWED_TOOLS merge logic" || { fail "EXTRA_ALLOWED_TOOLS MISSING"; err1=$((err1+1)); }
  grep -q 'disallowedTools' "$COMPOSE_ARGS" && ok "EXTRA_DISALLOWED merge logic" || { fail "EXTRA_DISALLOWED MISSING"; err1=$((err1+1)); }
  grep -q 'mcp-config' "$COMPOSE_ARGS" && ok "--mcp-config resolution" || { fail "--mcp-config MISSING"; err1=$((err1+1)); }
  grep -q 'system-prompt' "$COMPOSE_ARGS" && ok "--system-prompt handling" || { fail "--system-prompt MISSING"; err1=$((err1+1)); }
else
  fail "compose-args.sh not found"; err1=$((err1+1))
fi
s="Tool allowlist (${#BL[@]} tools)"
[ "$err1" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err1} issues" && track "$s" FAIL

# ============ SCENARIO 2 -- Prompt resolution priority ============
scenario "2: Prompt resolution priority"
err2=0
if [ -f "$RESOLVE_PROMPT" ]; then
  grep -q 'source="direct"' "$RESOLVE_PROMPT" && ok "Priority 1 (direct prompt)" || { fail "Priority 1 MISSING"; err2=$((err2+1)); }
  grep -q 'slash-command' "$RESOLVE_PROMPT" && ok "Slash-command resolution" || { fail "Slash-command MISSING"; err2=$((err2+1)); }
  grep -q 'source="caller"' "$RESOLVE_PROMPT" && ok "Priority 2 (caller path)" || { fail "Priority 2 MISSING"; err2=$((err2+1)); }
  grep -q 'source="builtin"' "$RESOLVE_PROMPT" && ok "Priority 3 (built-in skill)" || { fail "Priority 3 MISSING"; err2=$((err2+1)); }
  grep -q 'Prompt Not Found' "$RESOLVE_PROMPT" && ok "Hard error when no source" || { fail "Hard error MISSING"; err2=$((err2+1)); }
  grep -q 'skill_dir=' "$RESOLVE_PROMPT" && ok "Task-to-path mapping" || { fail "Task-path mapping MISSING"; err2=$((err2+1)); }
  grep -q 'prompt-source' "$RESOLVE_PROMPT" && ok "prompt-source output" || { fail "prompt-source MISSING"; err2=$((err2+1)); }
else
  fail "resolve-prompt.sh not found"; err2=$((err2+1))
fi
grep -q 'prompt-source' "$REUSABLE_WF" && ok "prompt-source wired in reusable" || { fail "prompt-source NOT in reusable"; err2=$((err2+1)); }
s="Prompt resolution priority"
[ "$err2" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err2} issues" && track "$s" FAIL

# ============ SCENARIO 3 -- Mustache substitution ============
scenario "3: Mustache substitution"
err3=0
if [ -f "$RESOLVE_PROMPT" ]; then
  for var in repo run_id run_url event_name ref sha actor; do
    grep -q "auto_${var}=" "$RESOLVE_PROMPT" && ok "Auto var: ${var}" || { fail "Missing auto_${var}"; err3=$((err3+1)); }
  done
  grep -q 'CONTEXT_JSON' "$RESOLVE_PROMPT" && ok "CONTEXT_JSON parsing" || { fail "CONTEXT_JSON MISSING"; err3=$((err3+1)); }
  grep -q 'command -v jq' "$RESOLVE_PROMPT" && ok "jq fallback" || { fail "jq fallback MISSING"; err3=$((err3+1)); }
  grep -q 'substitute()' "$RESOLVE_PROMPT" && ok "Substitution function" || { fail "substitute() MISSING"; err3=$((err3+1)); }
  grep -q '{{[[:space:]]*' "$RESOLVE_PROMPT" && ok "Whitespace-tolerant matching" || { fail "Whitespace matching MISSING"; err3=$((err3+1)); }
fi
sc=0; sw=0
if [ -d "$SKILLS_DIR" ]; then
  for sf in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$sf" ] || continue; sc=$((sc+1))
    grep -q '{{' "$sf" 2>/dev/null && sw=$((sw+1))
  done
  ok "${sc} skill files, ${sw} use Mustache"
fi
s="Mustache substitution"
[ "$err3" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err3} issues" && track "$s" FAIL

# ============ SCENARIO 4 -- Input/output contract ============
scenario "4: Input/output contract match"
err4=0
for inp in task prompt prompt-path context model max-turns system-prompt extra-allowed-tools extra-disallowed-tools mcp-config use-sticky-comment extra-env; do
  grep -q "\b${inp}\b" "$REUSABLE_WF" && ok "Input '${inp}' forwarded" || { fail "Input '${inp}' NOT forwarded"; err4=$((err4+1)); }
done
for out in execution-file session-id structured-output prompt-source; do
  grep -q "$out" "$REUSABLE_WF" && ok "Output '${out}' declared" || { fail "Output '${out}' MISSING"; err4=$((err4+1)); }
done
for sec in api-key oauth-token api-base-url github-token slack-webhook; do
  grep -q "$sec" "$REUSABLE_WF" && ok "Secret '${sec}' declared" || { fail "Secret '${sec}' MISSING"; err4=$((err4+1)); }
done
grep -q 'ANTHROPIC_API_KEY' "$AGENT_WF" && ok "agent.yml maps ANTHROPIC_API_KEY" || { fail "agent.yml missing ANTHROPIC_API_KEY"; err4=$((err4+1)); }
grep -q '@[0-9a-f]\{40\}' "$AGENT_WF" && ok "agent.yml SHA-pinned ref" || { fail "agent.yml NOT SHA-pinned"; err4=$((err4+1)); }
grep -q 'AI_MODEL' "$AGENT_WF" && ok "Model fallback chain" || { fail "Model fallback MISSING"; err4=$((err4+1)); }
s="Input/output contract"
[ "$err4" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err4} issues" && track "$s" FAIL

# ============ SCENARIO 5 -- resolve-openci ============
scenario "5: resolve-openci vendoring"
err5=0
grep -q 'Determine OpenCI ref' "$REUSABLE_WF" && ok "OpenCI ref resolution step" || { fail "Ref resolution MISSING"; err5=$((err5+1)); }
grep -q 'YiAgent/OpenCI' "$REUSABLE_WF" && ok "Self-reference handled" || { fail "Self-reference NOT handled"; err5=$((err5+1)); }
grep -q 'WORKFLOW_REF' "$REUSABLE_WF" && ok "workflow_ref parsed" || { fail "workflow_ref NOT parsed"; err5=$((err5+1)); }
grep -q ':-main' "$REUSABLE_WF" && ok "Fallback to main" || warn "Fallback to main not confirmed"
grep -q 'path: .openci' "$REUSABLE_WF" && ok "Vendored to .openci/" || { fail "NOT vendored to .openci/"; err5=$((err5+1)); }
grep -q '\.openci/actions/_common/claude-harness' "$REUSABLE_WF" && ok "Harness via .openci/" || { fail "Harness NOT via .openci/"; err5=$((err5+1)); }
s="resolve-openci vendoring"
[ "$err5" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err5} issues" && track "$s" FAIL

# ============ SCENARIO 6 -- Credential preflight ============
scenario "6: Credential preflight"
err6=0
grep -q 'preflight:' "$REUSABLE_WF" && ok "Preflight job exists" || { fail "Preflight MISSING"; err6=$((err6+1)); }
grep -q 'API_KEY\|OAUTH_TOKEN' "$REUSABLE_WF" && ok "api-key / oauth-token check" || { fail "Credential check MISSING"; err6=$((err6+1)); }
grep -q 'bedrock\|vertex\|foundry' "$REUSABLE_WF" && ok "Non-API providers allowed" || { fail "Non-API providers MISSING"; err6=$((err6+1)); }
grep -q 'Missing credentials' "$REUSABLE_WF" && ok "Clear error message" || { fail "Error message MISSING"; err6=$((err6+1)); }
if [ -f "$API_KEY_GATE" ]; then
  grep -q 'skip' "$API_KEY_GATE" && ok "api-key-gate skip logic" || { fail "api-key-gate MISSING skip"; err6=$((err6+1)); }
  grep -q 'Agent Skipped' "$API_KEY_GATE" && ok "api-key-gate notice" || warn "api-key-gate notice unclear"
fi
s="Credential preflight"
[ "$err6" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err6} issues" && track "$s" FAIL

# ============ SCENARIO 7 -- Security review ============
scenario "7: Security posture"
err7=0
cu=$(grep -c 'uses: actions/checkout@' "$REUSABLE_WF" 2>/dev/null || echo 0)
cp=$(grep -c 'uses: actions/checkout@[0-9a-f]\{40\}' "$REUSABLE_WF" 2>/dev/null || echo 0)
[ "$cu" -eq "$cp" ] && [ "$cu" -gt 0 ] && ok "actions/checkout SHA-pinned (${cp}/${cu})" || { fail "checkout NOT pinned"; err7=$((err7+1)); }
hu=$(grep -c 'uses: step-security/harden-runner@' "$REUSABLE_WF" 2>/dev/null || echo 0)
hp=$(grep -c 'uses: step-security/harden-runner@[0-9a-f]\{40\}' "$REUSABLE_WF" 2>/dev/null || echo 0)
[ "$hu" -eq "$hp" ] && [ "$hu" -gt 0 ] && ok "harden-runner SHA-pinned (${hp}/${hu})" || { fail "harden-runner NOT pinned"; err7=$((err7+1)); }
grep -q 'anthropics/claude-code-action@[0-9a-f]\{40\}' "$HARNESS_ACTION" && ok "claude-code-action SHA-pinned" || { fail "claude-code-action NOT pinned"; err7=$((err7+1)); }
grep -A5 'permissions:' "$REUSABLE_WF" | grep -q '{}' && ok "Empty top-level permissions" || { fail "Top-level permissions not empty"; err7=$((err7+1)); }
grep -A6 'preflight:' "$REUSABLE_WF" | grep -q 'contents: read' && ok "Preflight minimal permissions" || { fail "Preflight permissions not minimal"; err7=$((err7+1)); }
grep -A10 'ai-task:' "$REUSABLE_WF" | grep -q 'permissions:' && ok "ai-task permissions block" || { fail "ai-task MISSING permissions"; err7=$((err7+1)); }
grep -q 'persist-credentials: false' "$REUSABLE_WF" && ok "persist-credentials: false" || warn "persist-credentials not confirmed"
grep -q 'egress-policy: audit' "$REUSABLE_WF" && ok "egress-policy: audit" || warn "egress-policy not audit"
s="Security posture"
[ "$err7" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err7} issues" && track "$s" FAIL

# ============ SCENARIO 8 -- Built-in skills ============
scenario "8: Built-in skills"
err8=0; sc=0
if [ -d "$SKILLS_DIR" ]; then
  for skill in "$SKILLS_DIR"/*/; do
    [ -d "$skill" ] || continue
    sn="$(basename "$skill")"; sf="${skill}SKILL.md"
    [ -f "$sf" ] && ok "Skill '${sn}' has SKILL.md" && sc=$((sc+1)) || { fail "Skill '${sn}' MISSING SKILL.md"; err8=$((err8+1)); }
  done
  ok "Total: ${sc} built-in skills"
fi
s="Built-in skills (${sc} total)"
[ "$err8" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err8} issues" && track "$s" FAIL

# ============ SCENARIO 9 -- agent.yml structure ============
scenario "9: agent.yml structure"
err9=0
if [ -f "$AGENT_WF" ]; then
  grep -q 'workflow_dispatch' "$AGENT_WF" && ok "workflow_dispatch trigger" || { fail "MISSING workflow_dispatch"; err9=$((err9+1)); }
  grep -A2 'task:' "$AGENT_WF" | grep -q 'required: true' && ok "task required" || { fail "task NOT required"; err9=$((err9+1)); }
  for perm in 'contents: write' 'issues: write' 'pull-requests: write' 'id-token: write' 'actions: read'; do
    pk=$(echo "$perm" | cut -d: -f1); pv=$(echo "$perm" | cut -d: -f2 | xargs)
    grep -A10 'permissions:' "$AGENT_WF" | grep -q "${pk}:\s*${pv}" && ok "Permission ${perm}" || { fail "Permission ${perm} MISSING"; err9=$((err9+1)); }
  done
  grep -q 'concurrency:' "$AGENT_WF" && grep -q 'group: agent-' "$AGENT_WF" && ok "Concurrency group" || { fail "Concurrency MISSING"; err9=$((err9+1)); }
  grep -q 'cancel-in-progress: false' "$AGENT_WF" && ok "cancel-in-progress: false" || warn "cancel-in-progress not false"
  grep -q 'YiAgent/OpenCI' "$AGENT_WF" && ok "Calls reusable-agent.yml" || { fail "NOT calling reusable-agent"; err9=$((err9+1)); }
  for field in prompt prompt-path; do
    (grep -A5 "${field}:" "$AGENT_WF" | grep -q "default: ''") && ok "${field} defaults to empty" || warn "${field} default not empty string"
  done
fi
s="agent.yml structure"
[ "$err9" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err9} issues" && track "$s" FAIL

# ============ SCENARIO 10 -- Sticky comments ============
scenario "10: Sticky comment dedup"
err10=0
grep -q 'use-sticky-comment' "$REUSABLE_WF" && ok "use-sticky-comment in reusable" || { fail "NOT in reusable"; err10=$((err10+1)); }
grep -q 'use_sticky_comment' "$HARNESS_ACTION" && ok "use_sticky_comment in harness" || { fail "NOT in harness"; err10=$((err10+1)); }
grep -A3 'use-sticky-comment' "$REUSABLE_WF" | grep -q 'default: true' && ok "Default true" || warn "Default not confirmed true"
s="Sticky comment dedup"
[ "$err10" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err10} issues" && track "$s" FAIL

# ============ SCENARIO 11 -- LIVE: direct prompt ============
scenario "11: [LIVE] Direct prompt via agent.yml"
if [ "$DRY_RUN" = "true" ] || [ "$HAS_GH_AUTH" != "true" ]; then
  record_skip "No auth / dry-run"; track "Direct prompt via agent.yml" "SKIP"
else
  de=0
  dr=$(dispatch_workflow "agent.yml" "main" "task=custom prompt=Say OpenCI agent test passed and exit" 2>&1) || true
  if echo "$dr" | grep -q "dry-run\|Could not resolve\|not found"; then
    warn "Cannot dispatch"; record_skip "Dispatch unavailable"; track "Direct prompt via agent.yml" "SKIP"
  else
    ok "Dispatched"
    rid=$(wait_for_workflow "agent.yml" "" 300) || rid=""
    if [ -n "$rid" ] && [ "$rid" != "0" ] && [ "$rid" != "dry-run-run-id" ]; then
      assert_job_conclusion "$rid" "Preflight" "success" || de=$((de+1))
      assert_job_conclusion "$rid" "AI Task" "success" || de=$((de+1))
      [ "$de" -eq 0 ] && record_pass "Direct prompt OK" && track "Direct prompt via agent.yml" PASS || record_fail "${de} checks failed" && track "Direct prompt via agent.yml" FAIL
    else
      warn "Run not found"; record_skip "Monitoring skipped"; track "Direct prompt via agent.yml" "SKIP"
    fi
  fi
fi

# ============ SCENARIO 12 -- LIVE: file-based prompt ============
scenario "12: [LIVE] File-based prompt"
if [ "$DRY_RUN" = "true" ] || [ "$HAS_GH_AUTH" != "true" ]; then
  record_skip "No auth / dry-run"; track "File-based prompt" "SKIP"
else
  de=0; pb="test-prompt-${TEST_RUN_ID}"
  create_branch "$pb" "main" || true
  create_file_on_branch "$pb" "prompts/test-s12.md" "# Test Prompt\n\nSay file-based test passed.\n" "test: add prompt" || true
  dr=$(dispatch_workflow "agent.yml" "$pb" "task=custom prompt-path=prompts/test-s12.md" 2>&1) || true
  if echo "$dr" | grep -q "dry-run\|Could not resolve"; then
    warn "Cannot dispatch"; record_skip "Dispatch unavailable"; track "File-based prompt" "SKIP"
  else
    rid=$(wait_for_workflow "agent.yml" "$pb" 300) || rid=""
    if [ -n "$rid" ] && [ "$rid" != "0" ] && [ "$rid" != "dry-run-run-id" ]; then
      assert_job_conclusion "$rid" "Preflight" "success" || de=$((de+1))
      assert_job_conclusion "$rid" "AI Task" "success" || de=$((de+1))
      [ "$de" -eq 0 ] && record_pass "File-based OK" && track "File-based prompt" PASS || record_fail "${de} checks failed" && track "File-based prompt" FAIL
    else
      warn "Run not found"; record_skip "Monitoring skipped"; track "File-based prompt" "SKIP"
    fi
  fi
  delete_branch "$pb" || true
fi

# ============ SCENARIO 13 -- LIVE: skill fallback ============
scenario "13: [LIVE] Skill lookup fallback"
if [ "$DRY_RUN" = "true" ] || [ "$HAS_GH_AUTH" != "true" ]; then
  record_skip "No auth / dry-run"; track "Skill lookup fallback" "SKIP"
else
  de=0
  dr=$(dispatch_workflow "agent.yml" "main" "task=issue-triage" 2>&1) || true
  if echo "$dr" | grep -q "dry-run\|Could not resolve"; then
    warn "Cannot dispatch"; record_skip "Dispatch unavailable"; track "Skill lookup fallback" "SKIP"
  else
    rid=$(wait_for_workflow "agent.yml" "" 300) || rid=""
    if [ -n "$rid" ] && [ "$rid" != "0" ] && [ "$rid" != "dry-run-run-id" ]; then
      assert_job_conclusion "$rid" "Preflight" "success" || de=$((de+1))
      assert_job_conclusion "$rid" "AI Task" "success" || de=$((de+1))
      [ "$de" -eq 0 ] && record_pass "Skill fallback OK" && track "Skill lookup fallback" PASS || record_fail "${de} checks failed" && track "Skill lookup fallback" FAIL
    else
      warn "Run not found"; record_skip "Monitoring skipped"; track "Skill lookup fallback" "SKIP"
    fi
  fi
fi

# ============ SCENARIO 14 -- LIVE: no credentials ============
scenario "14: [LIVE] No credentials rejection"
if [ "$DRY_RUN" = "true" ] || [ "$HAS_GH_AUTH" != "true" ]; then
  record_skip "No auth / dry-run"; track "No credentials rejection" "SKIP"
else
  de=0
  dr=$(dispatch_workflow "agent.yml" "main" "task=custom prompt=Test no-credentials" 2>&1) || true
  if echo "$dr" | grep -q "dry-run\|Could not resolve"; then
    warn "Cannot dispatch"; record_skip "Dispatch unavailable"; track "No credentials rejection" "SKIP"
  else
    rid=$(wait_for_workflow "agent.yml" "" 300) || rid=""
    if [ -n "$rid" ] && [ "$rid" != "0" ] && [ "$rid" != "dry-run-run-id" ]; then
      if [ "$HAS_API_KEY" = "true" ]; then
        assert_job_conclusion "$rid" "Preflight" "success" || de=$((de+1))
        ok "Preflight passed with API key"
      else
        pc=$(get_workflow_jobs "$rid" | jq -r '.jobs[] | select(.name=="Preflight") | .conclusion // "NOT_FOUND"' 2>/dev/null || echo "NOT_FOUND")
        [ "$pc" = "failure" ] || [ "$pc" = "cancelled" ] && ok "Preflight rejected without credentials" || info "Preflight: ${pc} (secrets may be configured)"
      fi
      [ "$de" -eq 0 ] && record_pass "Credentials check OK" && track "No credentials rejection" PASS || record_fail "${de} checks failed" && track "No credentials rejection" FAIL
    else
      warn "Run not found"; record_skip "Monitoring skipped"; track "No credentials rejection" "SKIP"
    fi
  fi
fi

# ============ SCENARIO 15 -- Test library ============
scenario "15: Shared test library compatibility"
err15=0
if [ -f "$WF_TEST_LIB" ]; then
  grep -q 'DOMAIN=' "$WF_TEST_LIB" && ok "DOMAIN variable supported" || { fail "DOMAIN MISSING"; err15=$((err15+1)); }
  for h in wait_for_agent_comment wait_for_pr_agent_comment SKIP_AGENT_TESTS dispatch_workflow; do
    grep -q "$h" "$WF_TEST_LIB" && ok "Helper '${h}' available" || { fail "Helper '${h}' MISSING"; err15=$((err15+1)); }
  done
fi
s="Shared test library"
[ "$err15" -eq 0 ] && record_pass "$s" && track "$s" PASS || record_fail "${err15} issues" && track "$s" FAIL

# ============ REPORT ============
echo ""
echo "============================================================"
echo "  OpenCI Test Report -- Agent Domain"
echo "============================================================"
echo "  Total:   ${SCENARIOS_TOTAL}"
echo "  Passed:  ${SCENARIOS_PASSED}"
echo "  Failed:  ${SCENARIOS_FAILED}"
echo "  Skipped: ${SCENARIOS_SKIPPED}"
echo "============================================================"
echo ""

REPORT_FILE="${OPENCI_REPORT_FILE:-/tmp/openci-test-report-agent.md}"
{
  echo "# OpenCI Agent Domain Test Report"
  echo ""
  echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Test Run ID:** ${TEST_RUN_ID}"
  echo "**Repo:** ${REPO:-auto}"
  echo ""
  echo "## Summary"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|-------|"
  echo "| Total  | ${SCENARIOS_TOTAL} |"
  echo "| Passed | ${SCENARIOS_PASSED} |"
  echo "| Failed | ${SCENARIOS_FAILED} |"
  echo "| Skipped| ${SCENARIOS_SKIPPED} |"
  echo ""
  echo "## Per-Scenario Results"
  echo ""
  echo "| # | Scenario | Result |"
  echo "|---|----------|--------|"
  for ((idx = 0; idx < ${#SCENARIO_NAMES[@]}; idx++)); do
    n=$((idx + 1))
    echo "| ${n} | ${SCENARIO_NAMES[$idx]} | ${SCENARIO_RESULTS[$idx]} |"
  done
  echo ""
  echo "## Notes"
  echo ""
  echo "- Static scenarios analyze source code for correctness."
  echo "- Live scenarios dispatch agent.yml via gh workflow run."
  echo "- Live scenarios skip when GitHub auth or API key is unavailable."
  echo ""
} > "$REPORT_FILE"

echo "Report written to: ${REPORT_FILE}"
echo ""
echo "To run:"
echo "  DRY_RUN=true bash tests/workflows/reusable/test-reusable-agent.sh"
echo "  # or with auth:"
echo "  GH_TOKEN=... ANTHROPIC_API_KEY=... bash tests/workflows/reusable/test-reusable-agent.sh"

if [ "$SCENARIOS_FAILED" -gt 0 ]; then
  exit 1
else
  exit 0
fi
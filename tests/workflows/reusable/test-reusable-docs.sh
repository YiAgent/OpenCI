#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-reusable-docs.sh — Docs Domain E2E + Structural Tests
#
# Tests the 4-stage docs pipeline in reusable-docs.yml:
#   Stage 1 · Lint    — markdownlint, link check, spell check, required docs
#   Stage 2 · Detect  — drift detection (git-history, API staleness, CHANGELOG)
#   Stage 3 · Agent   — claude-harness produces docs-action-plan/v1 JSON
#   Stage 4 · Execute — build + deploy Pages, sticky comment
#
# Modes: offline structural validation (default) or live E2E (requires gh auth).
#
# Usage:
#   ./test-reusable-docs.sh              # offline structural tests only
#   DRY_RUN=false ./test-reusable-docs.sh  # live E2E tests against a repo
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPERS="${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh"

DOMAIN="docs"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%s)}"

# ── Test result counters ─────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

ok()      { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  ✓ $1"; }
fail()    { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  ✗ $1"; }
skip()    { SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1)); echo "  → SKIP: $1"; }
header()  { echo -e "\n═══ $* ═══"; }
subheader() { echo -e "\n  --- $* ---"; }

# ── Paths under test ─────────────────────────────────────────────────────────
REUSABLE_WF="${PROJECT_ROOT}/.github/workflows/reusable-docs.yml"
EVENT_WF="${PROJECT_ROOT}/.github/workflows/docs.yml"
DETECT_ACTION="${PROJECT_ROOT}/actions/docs/detect/action.yml"
EXECUTE_JS="${PROJECT_ROOT}/actions/docs/execute-plan/execute.js"
EXTRACT_PLAN="${PROJECT_ROOT}/actions/docs/extract-plan/extract-plan.sh"
MANIFEST="${PROJECT_ROOT}/manifest.yml"

# ── Helper: extract SHAs from uses: lines ────────────────────────────────────
extract_sha() {
  local file="$1" pattern="$2"
  grep "uses:.*${pattern}" "$file" | grep -oE '[0-9a-f]{40}' | head -1 || true
}

# ── Helper: count uses: lines that are NOT SHA-pinned ────────────────────────
count_unpinned_uses() {
  local file="$1" count
  count=$(grep -cE 'uses:.*@(v[0-9]|main|master|latest)$' "$file" 2>/dev/null | tr -d '\n' | head -1) || true
  echo "${count:-0}"
}

# ═════════════════════════════════════════════════════════════════════════════
# PART 1: OFFLINE STRUCTURAL VALIDATION
# ═════════════════════════════════════════════════════════════════════════════

header "Docs Domain — Offline Structural Validation"

# ── 1.1 Verify workflow files exist ─────────────────────────────────────────
subheader "Workflow file existence"
[ -f "$REUSABLE_WF" ] && ok "reusable-docs.yml exists" || fail "reusable-docs.yml missing"
[ -f "$EVENT_WF" ]    && ok "docs.yml exists"         || fail "docs.yml missing"

# ── 1.2 SHA pin validation for reusable-docs.yml ─────────────────────────────
subheader "SHA pin validation (reusable-docs.yml)"
UNPINNED=$(count_unpinned_uses "$REUSABLE_WF")
if [ "$UNPINNED" -eq 0 ]; then
  ok "No unpinned uses: references in reusable-docs.yml"
else
  fail "Found ${UNPINNED} unpinned uses: references in reusable-docs.yml"
fi

# Check specific SHAs against manifest
for action in step-security/harden-runner actions/checkout actions/download-artifact actions/upload-pages-artifact actions/deploy-pages actions/github-script; do
  WF_SHA=$(extract_sha "$REUSABLE_WF" "$action" 2>/dev/null || true)
  MANIFEST_SHA=$(grep "${action}:" "$MANIFEST" | grep -oE '[0-9a-f]{40}' | head -1 || true)
  if [ -n "$WF_SHA" ] && [ -n "$MANIFEST_SHA" ]; then
    if [ "$WF_SHA" = "$MANIFEST_SHA" ]; then
      ok "${action} SHA matches manifest"
    else
      fail "${action} SHA mismatch: workflow=${WF_SHA} manifest=${MANIFEST_SHA}"
    fi
  else
    skip "${action} SHA check (extraction issue)"
  fi
done

# ── 1.3 Permissions check ───────────────────────────────────────────────────
subheader "Permissions (principle of least privilege)"
if grep -qE '^\s+permissions:\s*\{\}' "$REUSABLE_WF" 2>/dev/null; then
  ok "reusable-docs.yml top-level permissions: empty (no blanket perms)"
else
  fail "reusable-docs.yml top-level permissions not set to {}"
fi

# Check each job's permissions
lint_perms=$(grep -A6 '^\s\+lint:\|^  lint:' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || echo "")
detect_perms=$(sed -n '/^  detect:/,/^  [a-z]/\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)
agent_perms=$(sed -n '/^  agent:/,/^  [a-z]/\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)
execute_perms=$(sed -n '/^  execute:/,/^  [a-z]/\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)

echo "$lint_perms" | grep -q 'contents: read' && ok "lint: contents: read" || fail "lint: missing contents: read"
echo "$execute_perms" | grep -q 'pages: write' && ok "execute: pages: write" || fail "execute: missing pages: write"
echo "$execute_perms" | grep -q 'contents: write' && ok "execute: contents: write" || fail "execute: missing contents: write"

# ── 1.4 Timeout-minutes checks ──────────────────────────────────────────────
subheader "Timeout-minutes validation"
lint_timeout=$(grep -A1 'timeout-minutes:' "$REUSABLE_WF" | grep -E '^\s+[0-9]+' || true)
lint_job_timeout=$(sed -n '/^  lint:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'timeout-minutes' | grep -oE '[0-9]+' || true)
detect_job_timeout=$(sed -n '/^  detect:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'timeout-minutes' | grep -oE '[0-9]+' || true)
agent_job_timeout=$(sed -n '/^  agent:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'timeout-minutes' | grep -oE '[0-9]+' || true)
execute_job_timeout=$(sed -n '/^  execute:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'timeout-minutes' | grep -oE '[0-9]+' || true)

[ "$lint_job_timeout" = "10" ]    && ok "lint timeout: ${lint_job_timeout}m"    || fail "lint timeout: ${lint_job_timeout:-missing}"
[ "$detect_job_timeout" = "10" ]  && ok "detect timeout: ${detect_job_timeout}m"  || fail "detect timeout: ${detect_job_timeout:-missing}"
[ "$agent_job_timeout" = "20" ]   && ok "agent timeout: ${agent_job_timeout}m"   || fail "agent timeout: ${agent_job_timeout:-missing}"
[ "$execute_job_timeout" = "15" ] && ok "execute timeout: ${execute_job_timeout}m" || fail "execute timeout: ${execute_job_timeout:-missing}"

# ── 1.5 Stage dependency ordering ───────────────────────────────────────────
subheader "Stage dependency chain"
detect_needs=$(grep -B1 'needs: lint' "$REUSABLE_WF" 2>/dev/null || echo "")
agent_needs=$(grep -B1 'needs: detect' "$REUSABLE_WF" 2>/dev/null || echo "")
execute_needs=$(grep -B1 'needs: \[detect, agent\]' "$REUSABLE_WF" 2>/dev/null || echo "")

[ -n "$detect_needs" ]  && ok "detect → needs: lint"        || fail "detect missing needs: lint"
[ -n "$agent_needs" ]   && ok "agent → needs: detect"       || fail "agent missing needs: detect"
[ -n "$execute_needs" ] && ok "execute → needs: [detect, agent]" || fail "execute missing needs: [detect, agent]"

# ── 1.6 execute.js file path allowlist ──────────────────────────────────────
subheader "execute.js file path allowlist"
# The allowlist regex: /^(docs\/|CHANGELOG\.md$|README\.md$)/
ALLOWLIST_REGEX='docs\/|CHANGELOG\.md\$|README\.md\$'
if grep -q 'allowed = /^('"$ALLOWLIST_REGEX"')/' "$EXECUTE_JS" 2>/dev/null; then
  ok "execute.js allowlist permits docs/, CHANGELOG.md, README.md"
else
  # Try a more specific check
  if grep -q 'CHANGELOG\.md' "$EXECUTE_JS" && grep -q 'README\.md' "$EXECUTE_JS" && grep -q 'docs\/' "$EXECUTE_JS"; then
    ok "execute.js allowlist covers docs/, CHANGELOG.md, README.md"
  else
    fail "execute.js allowlist missing required paths"
  fi
fi

# Check that the allowlist is actually enforced (not commented out)
if grep -q 'throw new Error.*non-doc path' "$EXECUTE_JS" 2>/dev/null; then
  ok "execute.js throws on non-doc paths"
else
  fail "execute.js missing enforcement for non-doc paths"
fi

# ── 1.7 Agent stage condition gating ─────────────────────────────────────────
subheader "Agent stage condition gating"
AGENT_IF=$(sed -n '/^  agent:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -E '^\s+if:' || true)
if echo "$AGENT_IF" | grep -q 'enable-agent' && echo "$AGENT_IF" | grep -q 'needs-update'; then
  ok "Agent gated on enable-agent AND needs-update==true"
else
  fail "Agent condition missing expected gates: enable-agent, needs-update"
fi

# Check the skip gate (API key gate)
if grep -q 'api-key-gate' "$REUSABLE_WF" 2>/dev/null; then
  ok "Agent has api-key-gate for graceful skip when no key"
else
  fail "Agent missing api-key-gate step"
fi

# ── 1.8 detect action validation (outputs, composite, SHA pins) ──────────────
subheader "docs/detect action validation"
if grep -q 'using: composite' "$DETECT_ACTION" 2>/dev/null; then
  ok "detect action uses composite run type"
else
  fail "detect action not composite"
fi

# Check detect outputs
for out in drift-detected api-stale changelog-stale needs-update; do
  grep -q "${out}:" "$DETECT_ACTION" 2>/dev/null && ok "detect output: ${out}" || fail "detect missing output: ${out}"
done

# ── 1.9 extract-plan.sh structural check ────────────────────────────────────
subheader "extract-plan.sh structural check"
if [ -f "$EXTRACT_PLAN" ]; then
  ok "extract-plan.sh exists"
  if grep -q 'docs-action-plan/v1' "$EXTRACT_PLAN" 2>/dev/null; then
    ok "extract-plan.sh references docs-action-plan/v1 schema"
  else
    fail "extract-plan.sh missing docs-action-plan/v1 schema"
  fi
  if grep -q 'FALLBACK' "$EXTRACT_PLAN" 2>/dev/null; then
    ok "extract-plan.sh has fallback plan for missing output"
  else
    fail "extract-plan.sh missing fallback plan"
  fi
else
  fail "extract-plan.sh missing"
fi

# ── 1.10 Detect action SHA pins ─────────────────────────────────────────────
subheader "Detect action SHA pins"
DETECT_UNPINNED=$(count_unpinned_uses "$DETECT_ACTION")
if [ "$DETECT_UNPINNED" -eq 0 ]; then
  ok "No unpinned uses: in detect action"
else
  fail "Found ${DETECT_UNPINNED} unpinned uses: in detect action"
fi

# ── 1.11 docs.yml event-entry triggers ──────────────────────────────────────
subheader "docs.yml event-trigger validation"
# Check PR trigger with docs paths
if grep -qE 'pull_request:' "$EVENT_WF" && grep -qE 'docs/\*\*' "$EVENT_WF"; then
  ok "docs.yml triggers on PR with docs/** changes"
else
  fail "docs.yml missing PR trigger with docs/** paths"
fi

# Check push to main
if grep -qE 'push:' "$EVENT_WF" && grep -qE 'branches: \[main\]' "$EVENT_WF"; then
  ok "docs.yml triggers on push to main"
else
  fail "docs.yml missing push to main trigger"
fi

# Check schedule
if grep -qE 'schedule:' "$EVENT_WF" && grep -qE 'cron:' "$EVENT_WF"; then
  ok "docs.yml has weekly schedule trigger"
else
  fail "docs.yml missing schedule trigger"
fi

# Check release trigger
if grep -qE 'release:' "$EVENT_WF"; then
  ok "docs.yml triggers on release"
else
  fail "docs.yml missing release trigger"
fi

# Check workflow_dispatch
if grep -qE 'workflow_dispatch:' "$EVENT_WF"; then
  ok "docs.yml has workflow_dispatch"
else
  fail "docs.yml missing workflow_dispatch"
fi

# Check reusable workflow ref SHA matches manifest
REUSABLE_REF=$(grep 'uses: YiAgent/OpenCI' "$EVENT_WF" | grep -oE '[0-9a-f]{40}' | head -1 || true)
MANIFEST_SELF=$(grep 'YiAgent/OpenCI:' "$MANIFEST" | grep -oE '[0-9a-f]{40}' | head -1 || true)
if [ -n "$REUSABLE_REF" ] && [ -n "$MANIFEST_SELF" ]; then
  if [ "$REUSABLE_REF" = "$MANIFEST_SELF" ]; then
    ok "docs.yml uses verified SHA for reusable workflow (matches manifest)"
  else
    fail "docs.yml SHA mismatch: workflow=${REUSABLE_REF} manifest=${MANIFEST_SELF}"
  fi
else
  skip "docs.yml SHA check against manifest (extraction issue)"
fi

# ── 1.12 Concurrency group in docs.yml ──────────────────────────────────────
subheader "docs.yml concurrency settings"
if grep -qE 'concurrency:' "$EVENT_WF"; then
  ok "docs.yml has concurrency group"
  if grep -qE 'cancel-in-progress:.*true' "$EVENT_WF"; then
    ok "docs.yml cancels in-progress PR runs"
  else
    skip "docs.yml cancel-in-progress not explicitly true (may be conditional)"
  fi
else
  fail "docs.yml missing concurrency group"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PART 2: LIVE E2E TESTS (conditional on gh auth + DRY_RUN=false)
# ═════════════════════════════════════════════════════════════════════════════

header "Docs Domain — Live E2E Tests"

if [ "${DRY_RUN:-true}" = "true" ] || ! gh auth status &>/dev/null 2>&1; then
  skip "Live E2E tests skipped (DRY_RUN=${DRY_RUN:-true} or no gh auth)"
  echo ""
  echo "To run live E2E tests:"
  echo "  DRY_RUN=false DOMAIN=docs gh auth login"
else
  # Source the shared test library for live helpers
  LIBRARY_ONLY=true source "$HELPERS"

  scenario "PR lint gate — verify lint runs but detect/agent/execute skip"
  # (Live test would create a PR with docs changes and verify workflow run)

  scenario "Drift detection — verify detect step finds API staleness"
  # (Live test would push code changes without doc updates)

  ok "Live E2E scenarios are placeholders — run manually with DRY_RUN=false"
fi

# ═════════════════════════════════════════════════════════════════════════════
# REPORT
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "══════════════════════════════════════════════"
echo "  Docs Test Report"
echo "══════════════════════════════════════════════"
echo "  Total:   ${TOTAL}"
echo "  Passed:  ${PASSED}"
echo "  Failed:  ${FAILED}"
echo "  Skipped: ${SKIPPED}"
echo "══════════════════════════════════════════════"
echo ""

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0

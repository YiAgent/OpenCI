#!/usr/bin/env bash
# run-live-tests.sh — Unified test runner for OpenCI agentic workflows.
#
# Usage:
#   doppler run --project openci-test --config prd -- bash tests/e2e/run-live-tests.sh [OPTIONS]
#
# Options:
#   --dry-run           Skip live GitHub operations, run offline tests only
#   --skip-e2e          Skip live E2E tests (issue + PR creation)
#   --skip-agentic      Skip live agentic eval (Claude API calls)
#   --mode=issue|pr|all E2E mode (default: all)
#   --layer=N           Run only specific test layer (1-5)
#
# Test Layers:
#   1. Shell unit tests (BATS) — fast, offline
#   2. JavaScript unit tests — fast, offline
#   3. Integration pipeline tests — offline with fixtures
#   4. Agentic eval (Claude API) — requires ANTHROPIC_API_KEY
#   5. Live E2E (GitHub workflows) — requires GH_TOKEN + ANTHROPIC_API_KEY
#
# Environment variables (auto-injected by Doppler):
#   ANTHROPIC_API_KEY  — for live agentic eval
#   GH_TOKEN           — for GitHub API operations (or MY_GITHUB_TOKEN)
#   LINEAR_TOKEN        — optional, for Linear integration tests
#   SENTRY_AUTH_TOKEN   — optional, for Sentry integration tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Options ───────────────────────────────────────────────────────────────────

DRY_RUN=false
SKIP_E2E=false
SKIP_AGENTIC=false
E2E_MODE="all"
LAYER=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=true ;;
    --skip-e2e)     SKIP_E2E=true ;;
    --skip-agentic) SKIP_AGENTIC=true ;;
    --mode=*)       E2E_MODE="${arg#*=}" ;;
    --layer=*)      LAYER="${arg#*=}" ;;
  esac
done

# ── ANSI colours ──────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${NC}[$(date -u +%H:%M:%S)] $*"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
fail()  { echo -e "${RED}✗ $*${NC}"; }
header(){ echo -e "\n${BLUE}${BOLD}═══ $* ═══${NC}"; }

# ── Results tracking ──────────────────────────────────────────────────────────

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

record_pass()  { TOTAL=$((TOTAL + 1)); PASSED=$((PASSED + 1)); ok "$1"; }
record_fail()  { TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1)); fail "$1"; }
record_skip()  { TOTAL=$((TOTAL + 1)); SKIPPED=$((SKIPPED + 1)); warn "SKIP: $1"; }

should_run() {
  [ -z "$LAYER" ] || [ "$LAYER" = "$1" ]
}

# ── Secret detection ──────────────────────────────────────────────────────────

has_secret() {
  [ -n "${!1:-}" ] 2>/dev/null
}

# Prefer MY_GITHUB_TOKEN as GH_TOKEN if GH_TOKEN is not set
if [ -z "${GH_TOKEN:-}" ] && [ -n "${MY_GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$MY_GITHUB_TOKEN"
fi

log "OpenCI Live Test Runner"
log "======================="
log "Project root: ${PROJECT_ROOT}"
log "Mode: ${E2E_MODE}"
log "Dry run: ${DRY_RUN}"
log ""

log "Secret availability:"
log "  ANTHROPIC_API_KEY: $(has_secret ANTHROPIC_API_KEY && echo 'YES' || echo 'NO')"
log "  GH_TOKEN:          $(has_secret GH_TOKEN && echo 'YES' || echo 'NO')"
log "  LINEAR_TOKEN:      $(has_secret LINEAR_TOKEN && echo 'YES' || echo 'NO')"
log "  SENTRY_AUTH_TOKEN: $(has_secret SENTRY_AUTH_TOKEN && echo 'YES' || echo 'NO')"
log ""

# ── Layer 1: Shell unit tests (BATS) ─────────────────────────────────────────

if should_run "1"; then
  header "Layer 1: Shell Unit Tests (BATS)"

  if command -v bats &>/dev/null; then
    log "Running action shell tests..."
    if bats --tap --recursive "${PROJECT_ROOT}/tests/actions/" 2>&1 | tail -1; then
      record_pass "Action shell unit tests"
    else
      record_fail "Action shell unit tests"
    fi

    log "Running script tests..."
    if bats --tap --recursive "${PROJECT_ROOT}/tests/scripts/" 2>&1 | tail -1; then
      record_pass "Script unit tests"
    else
      record_fail "Script unit tests"
    fi
  else
    record_skip "BATS not installed — install with: apt-get install bats"
  fi
fi

# ── Layer 2: JavaScript unit tests ───────────────────────────────────────────

if should_run "2"; then
  header "Layer 2: JavaScript Unit Tests"

  if command -v node &>/dev/null; then
    for test_file in "${PROJECT_ROOT}"/tests/actions/*.test.js; do
      [ -f "$test_file" ] || continue
      local name
      name="$(basename "$test_file" .test.js)"
      log "Running ${name}..."
      if node --test "$test_file" 2>&1 | tail -1; then
        record_pass "JS: ${name}"
      else
        record_fail "JS: ${name}"
      fi
    done
  else
    record_skip "Node.js not installed"
  fi
fi

# ── Layer 3: Integration pipeline tests ──────────────────────────────────────

if should_run "3"; then
  header "Layer 3: Integration Pipeline Tests"

  if command -v bats &>/dev/null; then
    for test_file in "${PROJECT_ROOT}"/tests/integration/*.bats; do
      [ -f "$test_file" ] || continue
      local name
      name="$(basename "$test_file" .bats)"
      log "Running ${name}..."
      if bats --tap "$test_file" 2>&1 | tail -1; then
        record_pass "Integration: ${name}"
      else
        record_fail "Integration: ${name}"
      fi
    done

    for test_file in "${PROJECT_ROOT}"/tests/integration/*.test.js; do
      [ -f "$test_file" ] || continue
      local name
      name="$(basename "$test_file" .test.js)"
      log "Running ${name}..."
      if node --test "$test_file" 2>&1 | tail -1; then
        record_pass "Integration JS: ${name}"
      else
        record_fail "Integration JS: ${name}"
      fi
    done
  else
    record_skip "BATS not installed"
  fi
fi

# ── Layer 4: Agentic eval (Claude API) ───────────────────────────────────────

if should_run "4"; then
  header "Layer 4: Agentic Eval (Claude API)"

  if [ "$SKIP_AGENTIC" = "true" ]; then
    record_skip "Agentic eval (--skip-agentic)"
  elif ! has_secret ANTHROPIC_API_KEY; then
    record_skip "Agentic eval (ANTHROPIC_API_KEY not set)"
  else
    # Install SDK if needed
    if ! node -e "require('@anthropic-ai/sdk')" 2>/dev/null; then
      log "Installing Anthropic SDK..."
      npm install --no-save --prefix "$PROJECT_ROOT" @anthropic-ai/sdk 2>&1 | tail -1
    fi

    for test_file in "${PROJECT_ROOT}"/tests/agentic/*.test.js; do
      [ -f "$test_file" ] || continue
      local name
      name="$(basename "$test_file" .test.js)"
      log "Running ${name}..."
      if node --test "$test_file" 2>&1 | tail -5; then
        record_pass "Agentic: ${name}"
      else
        record_fail "Agentic: ${name}"
      fi
    done
  fi
fi

# ── Layer 5: Live E2E (GitHub workflows) ─────────────────────────────────────

if should_run "5"; then
  header "Layer 5: Live E2E (GitHub Workflows)"

  if [ "$SKIP_E2E" = "true" ]; then
    record_skip "Live E2E (--skip-e2e)"
  elif [ "$DRY_RUN" = "true" ]; then
    record_skip "Live E2E (--dry-run)"
  elif ! has_secret GH_TOKEN; then
    record_skip "Live E2E (GH_TOKEN not set)"
  elif ! has_secret ANTHROPIC_API_KEY; then
    record_skip "Live E2E (ANTHROPIC_API_KEY not set)"
  else
    log "Running live E2E tests (mode=${E2E_MODE})..."
    if bash "${SCRIPT_DIR}/live-e2e-verify.sh" --mode="${E2E_MODE}"; then
      record_pass "Live E2E (${E2E_MODE})"
    else
      record_fail "Live E2E (${E2E_MODE})"
    fi
  fi
fi

# ── Final report ──────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════"
echo -e "  ${BOLD}OpenCI Test Runner — Final Report${NC}"
echo "══════════════════════════════════════════════"
echo "  Total:   ${TOTAL}"
echo -e "  Passed:  ${GREEN}${PASSED}${NC}"
echo -e "  Failed:  ${RED}${FAILED}${NC}"
echo -e "  Skipped: ${YELLOW}${SKIPPED}${NC}"
echo "══════════════════════════════════════════════"
echo ""

if [ "$FAILED" -gt 0 ]; then
  fail "${FAILED} test(s) failed"
  exit 1
elif [ "$PASSED" -eq 0 ] && [ "$SKIPPED" -gt 0 ]; then
  warn "All tests were skipped — check secret availability"
  exit 0
else
  ok "All tests passed (${PASSED} passed, ${SKIPPED} skipped)"
  exit 0
fi

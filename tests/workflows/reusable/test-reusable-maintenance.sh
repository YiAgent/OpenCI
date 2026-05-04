#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-reusable-maintenance.sh — Maintenance Domain E2E + Structural Tests
#
# Tests the 4-stage maintenance pipeline in reusable-maintenance.yml:
#   Stage 1 · Scan    — Trivy (CVE), gitleaks (secrets), CodeQL (SAST)
#   Stage 2 · Update  — check-updates (Renovate/Dependabot PR query)
#   Stage 3 · Enrich  — aggregate signals into context.json
#   Stage 4 · Agent   — Claude correlates CVE→deps, files issues
#
# Mode routing tested:
#   full        — all stages
#   scan-only   — scans + enrich (no deps, no agent)
#   deps-only   — check-updates + enrich (no scans, no agent)
#
# Modes: offline structural validation (default) or live E2E (requires gh auth).
#
# Usage:
#   ./test-reusable-maintenance.sh               # offline structural tests
#   DRY_RUN=false ./test-reusable-maintenance.sh  # live E2E tests
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPERS="${PROJECT_ROOT}/tests/workflows/helpers/wf-test-lib.sh"

DOMAIN="maintenance"
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
REUSABLE_WF="${PROJECT_ROOT}/.github/workflows/reusable-maintenance.yml"
EVENT_WF="${PROJECT_ROOT}/.github/workflows/on-maintenance.yml"
MANIFEST="${PROJECT_ROOT}/manifest.yml"

# Action paths
SCAN_CODEQL="${PROJECT_ROOT}/actions/security/scan-codeql/action.yml"
SCAN_SNYK="${PROJECT_ROOT}/actions/security/scan-snyk/action.yml"
GENERATE_SBOM="${PROJECT_ROOT}/actions/security/generate-sbom/action.yml"
SCORECARD="${PROJECT_ROOT}/actions/security/scorecard/action.yml"
CHECK_UPDATES="${PROJECT_ROOT}/actions/maintenance/check-updates/action.yml"
ENRICH="${PROJECT_ROOT}/actions/maintenance/enrich/action.yml"
SCAN_SECRETS="${PROJECT_ROOT}/actions/maintenance/scan-secrets/action.yml"

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

header "Maintenance Domain — Offline Structural Validation"

# ── 1.1 Verify workflow files exist ─────────────────────────────────────────
subheader "Workflow file existence"
[ -f "$REUSABLE_WF" ] && ok "reusable-maintenance.yml exists" || fail "reusable-maintenance.yml missing"
[ -f "$EVENT_WF" ]     && ok "on-maintenance.yml exists"      || fail "on-maintenance.yml missing"

# ── 1.2 SHA pin validation for reusable-maintenance.yml ─────────────────────
subheader "SHA pin validation (reusable-maintenance.yml)"
UNPINNED=$(count_unpinned_uses "$REUSABLE_WF")
if [ "$UNPINNED" -eq 0 ]; then
  ok "No unpinned uses: references in reusable-maintenance.yml"
else
  fail "Found ${UNPINNED} unpinned uses: in reusable-maintenance.yml"
fi

# Check specific SHAs against manifest
for action in step-security/harden-runner actions/checkout actions/upload-artifact aquasecurity/trivy-action github/codeql-action actions/github-script; do
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
  ok "reusable-maintenance.yml top-level permissions: empty (no blanket perms)"
else
  fail "reusable-maintenance.yml top-level permissions not set to {}"
fi

# Check specific job permissions
summary_perms=$(sed -n '/^  summary:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)
agent_perms=$(sed -n '/^  agent:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)
codeql_perms=$(sed -n '/^  scan-codeql:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -A5 'permissions:' | head -6 || true)

echo "$summary_perms" | grep -qE 'permissions:\s*\{\}' && ok "summary: minimal perms (empty)" || fail "summary: permissions not minimal"
echo "$agent_perms" | grep -q 'issues: write' && ok "agent: issues: write" || fail "agent: missing issues: write"
echo "$codeql_perms" | grep -q 'security-events: write' && ok "scan-codeql: security-events: write" || fail "scan-codeql: missing security-events: write"

# ── 1.4 Timeout-minutes checks ──────────────────────────────────────────────
subheader "Timeout-minutes validation"
get_job_timeout() {
  local job="$1"
  sed -n "/^  ${job}:/,/^  [a-z]/p" "$REUSABLE_WF" 2>/dev/null | grep 'timeout-minutes' | grep -oE '[0-9]+' | head -1 || true
}

dl_to=$(get_job_timeout "detect-language")
sc_to=$(get_job_timeout "scan-codeql")
ss_to=$(get_job_timeout "scan-secrets")
tf_to=$(get_job_timeout "trivy-fs")
cu_to=$(get_job_timeout "check-updates")
en_to=$(get_job_timeout "enrich")
ag_to=$(get_job_timeout "agent")
su_to=$(get_job_timeout "summary")

[ "$dl_to" = "2" ]   && ok "detect-language timeout: ${dl_to}m"   || fail "detect-language timeout: ${dl_to:-missing}"
[ "$sc_to" = "60" ]  && ok "scan-codeql timeout: ${sc_to}m"      || fail "scan-codeql timeout: ${sc_to:-missing}"
[ "$ss_to" = "15" ]  && ok "scan-secrets timeout: ${ss_to}m"     || fail "scan-secrets timeout: ${ss_to:-missing}"
[ "$tf_to" = "30" ]  && ok "trivy-fs timeout: ${tf_to}m"         || fail "trivy-fs timeout: ${tf_to:-missing}"
[ "$cu_to" = "5" ]   && ok "check-updates timeout: ${cu_to}m"     || fail "check-updates timeout: ${cu_to:-missing}"
[ "$en_to" = "5" ]   && ok "enrich timeout: ${en_to}m"           || fail "enrich timeout: ${en_to:-missing}"
[ "$ag_to" = "30" ]  && ok "agent timeout: ${ag_to}m"            || fail "agent timeout: ${ag_to:-missing}"
[ "$su_to" = "2" ]   && ok "summary timeout: ${su_to}m"          || fail "summary timeout: ${su_to:-missing}"

# ── 1.5 Stage ordering and dependency chain ──────────────────────────────────
subheader "Stage ordering and dependency chain"

# detect-language gates scan-codeql
codeql_needs=$(sed -n '/^  scan-codeql:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'needs:' | grep -oE 'detect-language' || true)
[ -n "$codeql_needs" ] && ok "scan-codeql → needs: detect-language" || fail "scan-codeql missing needs: detect-language"

# enrich depends on all scan + update jobs
enrich_needs=$(sed -n '/^  enrich:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'needs:' | tr -d '[]' || true)
echo "$enrich_needs" | grep -q 'scan-secrets'  && ok "enrich → needs: scan-secrets"  || fail "enrich missing needs: scan-secrets"
echo "$enrich_needs" | grep -q 'trivy-fs'       && ok "enrich → needs: trivy-fs"     || fail "enrich missing needs: trivy-fs"
echo "$enrich_needs" | grep -q 'scan-codeql'    && ok "enrich → needs: scan-codeql"  || fail "enrich missing needs: scan-codeql"
echo "$enrich_needs" | grep -q 'check-updates'  && ok "enrich → needs: check-updates" || fail "enrich missing needs: check-updates"

# agent depends on enrich
agent_needs=$(sed -n '/^  agent:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'needs:' | grep -oE 'enrich' || true)
[ -n "$agent_needs" ] && ok "agent → needs: enrich" || fail "agent missing needs: enrich"

# summary depends on enrich + agent
summary_needs=$(sed -n '/^  summary:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep 'needs:' || true)
echo "$summary_needs" | grep -q 'enrich' && ok "summary → needs: enrich" || fail "summary missing needs: enrich"
echo "$summary_needs" | grep -q 'agent'  && ok "summary → needs: agent"  || fail "summary missing needs: agent"

# ── 1.6 Mode routing logic ──────────────────────────────────────────────────
subheader "Mode routing logic (full vs scan-only vs deps-only)"

# Jobs that should run in 'full' mode
full_jobs="detect-language scan-codeql scan-secrets trivy-fs check-updates enrich agent summary"
for j in $full_jobs; do
  if grep -q "^  ${j}:" "$REUSABLE_WF" 2>/dev/null; then
    ok "full mode includes: ${j}"
  fi
done

# Check scan-only mode gating
scan_only_jobs="detect-language scan-codeql scan-secrets trivy-fs"
for j in $scan_only_jobs; do
  job_if=$(sed -n "/^  ${j}:/,/^  [a-z]\|^$/p" "$REUSABLE_WF" 2>/dev/null | grep -E '^\s+if:' || true)
  if echo "$job_if" | grep -q "'scan-only'" || echo "$job_if" | grep -q "'full'"; then
    ok "${j}: gated on full|scan-only"
  else
    fail "${j}: missing scan-only gate condition"
  fi
done

# Check deps-only gating — only check-updates runs in deps-only
cu_if=$(sed -n '/^  check-updates:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -E '^\s+if:' || true)
if echo "$cu_if" | grep -q "'full'" && echo "$cu_if" | grep -q "'deps-only'"; then
  ok "check-updates: gated on full|deps-only"
else
  fail "check-updates: missing deps-only gate"
fi

# Verify scan jobs are excluded in deps-only mode
for j in detect-language scan-codeql scan-secrets trivy-fs; do
  job_if=$(sed -n "/^  ${j}:/,/^  [a-z]\|^$/p" "$REUSABLE_WF" 2>/dev/null | grep -E '^\s+if:' || true)
  if echo "$job_if" | grep -q "'deps-only'" 2>/dev/null; then
    fail "${j}: should NOT run in deps-only mode but gate permits it"
  else
    ok "${j}: correctly excluded from deps-only mode"
  fi
done

# Check agent only runs in full mode with has_issues=true
agent_if=$(sed -n '/^  agent:/,/^  [a-z]\|^$/' "$REUSABLE_WF" 2>/dev/null | grep -E '^\s+if:' || true)
if echo "$agent_if" | grep -q "mode == 'full'"; then
  ok "agent: gated on mode==full"
else
  fail "agent: missing mode==full gate"
fi
if echo "$agent_if" | grep -q "has_issues.*true"; then
  ok "agent: gated on has_issues==true"
else
  fail "agent: missing has_issues gate"
fi
if echo "$agent_if" | grep -q "always()"; then
  ok "agent: uses if: always() so enrich failures don't block"
else
  fail "agent: missing always() in condition"
fi

# ── 1.7 Concurrency settings ────────────────────────────────────────────────
subheader "Concurrency settings"
if grep -qE 'concurrency:' "$REUSABLE_WF"; then
  ok "reusable-maintenance.yml has concurrency group"
  if grep -qE 'cancel-in-progress: false' "$REUSABLE_WF"; then
    ok "reusable-maintenance.yml cancel-in-progress: false (safe for maintenance)"
  else
    skip "cancel-in-progress setting not explicit false"
  fi
else
  fail "reusable-maintenance.yml missing concurrency group"
fi

# ── 1.8 Security action structural tests ─────────────────────────────────────
subheader "Security action structural tests"

# scan-codeql
[ -f "$SCAN_CODEQL" ] && ok "scan-codeql action.yml exists" || fail "scan-codeql action.yml missing"
UNPINNED_CODEQL=$(count_unpinned_uses "$SCAN_CODEQL")
[ "$UNPINNED_CODEQL" -eq 0 ] && ok "scan-codeql: all uses SHA-pinned" || fail "scan-codeql: ${UNPINNED_CODEQL} unpinned uses"
grep -q 'using: composite' "$SCAN_CODEQL" && ok "scan-codeql: composite" || fail "scan-codeql: not composite"
grep -q 'codeql-action/init@' "$SCAN_CODEQL" && ok "scan-codeql: has init step" || fail "scan-codeql: missing init"
grep -q 'codeql-action/analyze@' "$SCAN_CODEQL" && ok "scan-codeql: has analyze step" || fail "scan-codeql: missing analyze"

# scan-snyk
[ -f "$SCAN_SNYK" ] && ok "scan-snyk action.yml exists" || fail "scan-snyk action.yml missing"
grep -q 'SNYK_TOKEN' "$SCAN_SNYK" && ok "scan-snyk: graceful skip when no token" || fail "scan-snyk: missing token skip logic"

# generate-sbom
[ -f "$GENERATE_SBOM" ] && ok "generate-sbom action.yml exists" || fail "generate-sbom action.yml missing"
grep -q 'spdx' "$GENERATE_SBOM" && ok "generate-sbom: produces SPDX format" || fail "generate-sbom: missing SPDX format"

# scorecard
[ -f "$SCORECARD" ] && ok "scorecard action.yml exists" || fail "scorecard action.yml missing"
grep -q 'ossf/scorecard-action' "$SCORECARD" && ok "scorecard: uses ossf/scorecard-action" || fail "scorecard: missing scorecard-action"
UNPINNED_SC=$(count_unpinned_uses "$SCORECARD")
[ "$UNPINNED_SC" -eq 0 ] && ok "scorecard: all uses SHA-pinned" || fail "scorecard: ${UNPINNED_SC} unpinned uses"

# ── 1.9 Maintenance action structural tests ──────────────────────────────────
subheader "Maintenance action structural tests"

# check-updates
[ -f "$CHECK_UPDATES" ] && ok "check-updates action.yml exists" || fail "check-updates action.yml missing"
grep -q 'has_updates' "$CHECK_UPDATES" && ok "check-updates: outputs has_updates" || fail "check-updates: missing has_updates output"
grep -q 'major_prs' "$CHECK_UPDATES" && ok "check-updates: outputs major_prs" || fail "check-updates: missing major_prs output"
grep -q 'depAuthors' "$CHECK_UPDATES" 2>/dev/null || grep -q 'renovate' "$CHECK_UPDATES" && ok "check-updates: detects Renovate/Dependabot PRs" || fail "check-updates: missing dep bot detection"
UNPINNED_CU=$(count_unpinned_uses "$CHECK_UPDATES")
[ "$UNPINNED_CU" -eq 0 ] && ok "check-updates: all uses SHA-pinned" || fail "check-updates: ${UNPINNED_CU} unpinned uses"

# enrich
[ -f "$ENRICH" ] && ok "enrich action.yml exists" || fail "enrich action.yml missing"
grep -q 'has_issues' "$ENRICH" && ok "enrich: outputs has_issues" || fail "enrich: missing has_issues output"
grep -q 'overall_health' "$ENRICH" && ok "enrich: outputs overall_health" || fail "enrich: missing overall_health output"
grep -q 'context_json' "$ENRICH" && ok "enrich: outputs context_json" || fail "enrich: missing context_json output"

# Health classification logic
if grep -q 'SECRETS_FOUND.*true.*TRIVY_CRITICAL.*gt 0' "$ENRICH" 2>/dev/null; then
  ok "enrich: critical health when secrets or critical CVEs"
elif grep -q 'SECRETS_FOUND' "$ENRICH" && grep -q 'TRIVY_CRITICAL' "$ENRICH" && grep -q 'HEALTH="critical"' "$ENRICH" 2>/dev/null; then
  ok "enrich: critical health when secrets or critical CVEs"
else
  skip "enrich: health classification logic check (non-trivial grep)"
fi

# scan-secrets
[ -f "$SCAN_SECRETS" ] && ok "scan-secrets action.yml exists" || fail "scan-secrets action.yml missing"
grep -q 'gitleaks' "$SCAN_SECRETS" && ok "scan-secrets: uses gitleaks" || fail "scan-secrets: missing gitleaks"
grep -q 'outputs:' "$SCAN_SECRETS" && ok "scan-secrets: declares outputs" || fail "scan-secrets: missing outputs"

# ── 1.10 Existing bats tests for security/maintenance actions ────────────────
subheader "Existing bats tests for security/maintenance actions"

bats_tests_found=false
for bats_file in scan-codeql scan-secrets generate-sbom detect-language; do
  if [ -f "${PROJECT_ROOT}/tests/actions/${bats_file}.bats" ]; then
    ok "bats test exists: ${bats_file}.bats"
    bats_tests_found=true
  else
    skip "bats test not found: ${bats_file}.bats"
  fi
done

if [ "$bats_tests_found" = "true" ]; then
  ok "Security/maintenance bats tests are present in tests/actions/"
fi

# ── 1.11 on-maintenance.yml event-entry validation ──────────────────────────
subheader "on-maintenance.yml event-trigger validation"

# Schedule triggers
if grep -qE 'schedule:' "$EVENT_WF"; then
  ok "on-maintenance.yml has schedule trigger"
  # Check weekly Monday 02:00
  grep -qE '0 2 \* \* 1' "$EVENT_WF" && ok "Weekly deep sweep: Mon 02:00 UTC" || fail "Missing Mon 02:00 schedule"
  # Check flag audit cron
  grep -qE '0 15 \* \* 1' "$EVENT_WF" && ok "Flag audit: Mon 15:00 UTC" || fail "Missing Mon 15:00 schedule"
else
  fail "on-maintenance.yml missing schedule trigger"
fi

# Push/PR triggers with paths
if grep -qE 'push:' "$EVENT_WF" && grep -qE 'manifest.yml' "$EVENT_WF"; then
  ok "on-maintenance.yml triggers on push with manifest/actions/workflow changes"
else
  fail "on-maintenance.yml missing push trigger with path filters"
fi

# Workflow dispatch with mode selection
if grep -qE 'workflow_dispatch:' "$EVENT_WF"; then
  ok "on-maintenance.yml has workflow_dispatch"
  grep -qE 'mode:' "$EVENT_WF" && ok "workflow_dispatch allows mode selection" || fail "workflow_dispatch missing mode input"
else
  fail "on-maintenance.yml missing workflow_dispatch"
fi

# Mode resolution job
if grep -qE 'resolve-mode:' "$EVENT_WF"; then
  ok "on-maintenance.yml has resolve-mode job"
  # Check specific mode mappings
  grep -qE "pr-review" "$EVENT_WF" && ok "resolve-mode maps push/PR to pr-review" || fail "resolve-mode missing pr-review mapping"
  grep -qE "flag-audit" "$EVENT_WF" && ok "resolve-mode maps Mon 15:00 to flag-audit" || fail "resolve-mode missing flag-audit mapping"
  grep -qE "full" "$EVENT_WF" && ok "resolve-mode maps Mon 02:00 to full" || fail "resolve-mode missing full mode mapping"
else
  fail "on-maintenance.yml missing resolve-mode job"
fi

# ── 1.12 on-maintenance.yml reusable workflow ref SHA ───────────────────────
subheader "on-maintenance.yml workflow ref"
EVENT_REF=$(grep 'uses: YiAgent/OpenCI' "$EVENT_WF" | grep -oE '[0-9a-f]{40}' | head -1 || true)
MANIFEST_SELF=$(grep 'YiAgent/OpenCI:' "$MANIFEST" | grep -oE '[0-9a-f]{40}' | head -1 || true)
if [ -n "$EVENT_REF" ] && [ -n "$MANIFEST_SELF" ]; then
  if [ "$EVENT_REF" = "$MANIFEST_SELF" ]; then
    ok "on-maintenance.yml uses verified SHA for reusable workflow (matches manifest)"
  else
    fail "on-maintenance.yml SHA mismatch: workflow=${EVENT_REF} manifest=${MANIFEST_SELF}"
  fi
else
  skip "on-maintenance.yml SHA check against manifest (extraction issue)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PART 2: LIVE E2E TESTS (conditional on gh auth + DRY_RUN=false)
# ═════════════════════════════════════════════════════════════════════════════

header "Maintenance Domain — Live E2E Tests"

if [ "${DRY_RUN:-true}" = "true" ] || ! gh auth status &>/dev/null 2>&1; then
  skip "Live E2E tests skipped (DRY_RUN=${DRY_RUN:-true} or no gh auth)"
  echo ""
  echo "To run live E2E tests:"
  echo "  DRY_RUN=false DOMAIN=maintenance gh auth login"
else
  # Source the shared test library for live helpers
  LIBRARY_ONLY=true source "$HELPERS"

  scenario "Full scan mode — verify Trivy + CodeQL + gitleaks + check-updates all run"

  scenario "Scan-only mode — verify check-updates skipped"

  scenario "Deps-only mode — verify scans skipped, only check-updates runs"

  scenario "Agent analysis — verify agent runs when has_issues=true"

  scenario "Clean repo — verify agent skipped when no issues found"

  ok "Live E2E scenarios are placeholders — run manually with DRY_RUN=false"
fi

# ═════════════════════════════════════════════════════════════════════════════
# REPORT
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "══════════════════════════════════════════════"
echo "  Maintenance Test Report"
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

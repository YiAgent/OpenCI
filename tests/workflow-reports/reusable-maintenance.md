# Workflow Test Report: reusable-maintenance.yml

**File:** `.github/workflows/reusable-maintenance.yml`
**Tested:** 2026-05-04
**actionlint:** PASS (exit 0, no errors)
**YAML syntax:** VALID

---

## Overview

A 4-stage reusable maintenance pipeline implementing parallel security scanning (CVE, secrets, SAST), dependency update querying, context enrichment, and AI-driven analysis. Supports three execution modes (`full`, `scan-only`, `deps-only`) with mode-based job gating.

**Job dependency graph:**
```
detect-language --> scan-codeql -------+
scan-secrets -------------------------+--> enrich --> agent --> summary
trivy-fs -----------------------------+       ^
check-updates -------------------------------+
```

---

## Inputs/Secrets/Outputs Definition

### Inputs (workflow_call)

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `openci-ref` | string | false | `main` | OpenCI ref to vendor for ./.openci/* references |
| `runner` | string | false | `ubuntu-latest` | Runner label for all jobs |
| `mode` | string | false | `full` | Execution mode: full / scan-only / deps-only |
| `image-ref` | string | false | `""` | Container image ref for Trivy image scan (skipped when empty) |

### Secrets (workflow_call)

| Name | Required | Used In |
|------|----------|---------|
| `anthropic-api-key` | false | `agent` job (claude-harness) |
| `api-base-url` | false | `agent` job (claude-harness) |
| `snyk-token` | false | **NOWHERE** - declared but never referenced |

### Outputs

None declared at the workflow level. Individual jobs expose outputs used internally.

---

## Node-by-Node Status

### Job: detect-language

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `inputs.mode == 'full' \|\| inputs.mode == 'scan-only'` |
| Runner | PASS | `${{ inputs.runner }}` (inherits caller override) |
| Timeout | PASS | 2 min |
| Permissions | PASS | `contents: read` (least privilege) |
| SHA pins | PASS | `step-security/harden-runner@f808768...`, `actions/checkout@11bd719...` |
| Composite action | PASS | `bash .openci/actions/_common/detect-language/detect.sh` exists in repo |
| OpenCI vendor | PASS | Resolves ref from input or `github.workflow_ref`, checks out YiAgent/OpenCI |

### Job: scan-codeql

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | Mode gate + `language != 'unknown'` |
| Dependency | PASS | `needs: detect-language` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 60 min |
| Permissions | PASS | `contents: read`, `security-events: write`, `actions: read` |
| SHA pins | PASS | All actions SHA-pinned |
| Composite action | PASS | `./.openci/actions/security/scan-codeql` exists in repo |
| Language mapping | PASS | `node -> javascript` for CodeQL compatibility |
| Output | PASS | `found` (always set to `false` after scan) |

### Job: scan-secrets

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `inputs.mode == 'full' \|\| inputs.mode == 'scan-only'` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 15 min |
| Permissions | PASS | `contents: read` |
| SHA pins | PASS | All actions SHA-pinned, including `upload-artifact@ea165f8...` |
| Composite action | PASS | `./.openci/actions/maintenance/scan-secrets` exists in repo |
| Artifact upload | PASS | Conditional on `found == 'true'`, 30-day retention |
| Outputs | PASS | `found`, `count` |

### Job: trivy-fs

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `inputs.mode == 'full' \|\| inputs.mode == 'scan-only'` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 30 min |
| Permissions | PASS | `contents: read`, `security-events: write` |
| SHA pins | PASS | `trivy-action@ed142fd...` (v0.36.0), `codeql-action/upload-sarif@48ab28a...` (v3.28.0) |
| Dual scan | PASS | SARIF for Security tab + JSON for programmatic count extraction |
| CVE extraction | PASS | `jq` with null-safe operators, defaults to 0 on missing file |
| Outputs | PASS | `critical`, `high`, `medium` |

### Job: check-updates

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `inputs.mode == 'full' \|\| inputs.mode == 'deps-only'` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 5 min |
| Permissions | PASS | `contents: read`, `pull-requests: read` |
| SHA pins | PASS | All actions SHA-pinned |
| Composite action | PASS | `./.openci/actions/maintenance/check-updates` exists in repo |
| Token | PASS | Uses `github.token` (not a secret) |
| Outputs | PASS | `has_updates`, `major_count`, `minor_count`, `patch_count`, `major_prs`, `minor_prs` |

### Job: enrich

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `always()` with mode gate covering all 3 modes |
| Dependency | PASS | `needs: [scan-secrets, trivy-fs, scan-codeql, check-updates]` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 5 min |
| Permissions | PASS | `contents: read` |
| Fallback values | PASS | All inputs use `\|\| 'false'` or `\|\| '0'` or `\|\| '[]'` defaults |
| Composite action | PASS | `./.openci/actions/maintenance/enrich` exists in repo |
| Outputs | PASS | `has_issues`, `overall_health`, `context_json` |

### Job: agent

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `always()` + `mode == 'full'` + `has_issues == 'true'` + `enrich.result != 'failure'` |
| Dependency | PASS | `needs: enrich` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 30 min |
| Permissions | PASS | `contents: read`, `issues: write`, `id-token: write` |
| Composite action | PASS | `./.openci/actions/_common/claude-harness` exists in repo |
| Secret refs | PASS | `${{ secrets.anthropic-api-key }}`, `${{ secrets.api-base-url }}` |
| Tools | PASS | `github_create_issue,github_list_issues` |

### Job: summary

| Check | Status | Notes |
|-------|--------|-------|
| Condition | PASS | `always()` + `enrich.result != 'skipped'` |
| Dependency | PASS | `needs: [enrich, agent]` |
| Runner | PASS | `${{ inputs.runner }}` |
| Timeout | PASS | 2 min |
| Permissions | PASS | `{}` (empty - no write access needed) |
| Summary output | PASS | Writes markdown table to `$GITHUB_STEP_SUMMARY` |

### Security Practices

| Check | Status | Notes |
|-------|--------|-------|
| Expression injection | PASS | No `${{ }}` in `run:` blocks; all passed via `env:` |
| Top-level permissions | PASS | `permissions: {}` (empty); each job declares least-privilege |
| Credential persistence | PASS | `persist-credentials: false` on all checkout steps |
| Harden runner | PASS | `step-security/harden-runner` on every job |

---

## Callers Analysis

### Caller: `.github/workflows/on-maintenance.yml`

**Reference:** `YiAgent/OpenCI/.github/workflows/reusable-maintenance.yml@f62931bd0e2b73800512625a9fc5118557957ff3`

**SHA verification:** The SHA `f62931bd0e2b73800512625a9fc5118557957ff3` matches `manifest.yml` entry for `YiAgent/OpenCI`. PASS.

**Input mapping:**

| Reusable Input | Caller Value | Match |
|----------------|-------------|-------|
| `mode` | `${{ needs.resolve-mode.outputs.mode }}` | PASS - dynamically resolved |
| `openci-ref` | `${{ needs.resolve-mode.outputs.openci-ref }}` | PASS - dynamically resolved |
| `image-ref` | `${{ vars.IMAGE_REF \|\| '' }}` | PASS - from repository variable |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | PASS - overrides default `ubuntu-latest` |

**Secret mapping:**

| Reusable Secret | Caller Value | Match |
|----------------|-------------|-------|
| `anthropic-api-key` | `${{ secrets.ANTHROPIC_API_KEY }}` | PASS |
| `api-base-url` | `${{ secrets.ANTHROPIC_BASE_URL }}` | PASS |
| `snyk-token` | NOT PASSED | OK (optional, unused in reusable) |

**Mode gating in caller:** The caller only invokes the reusable workflow when mode is NOT `pr-review` or `flag-audit`. Those modes are handled by separate jobs (`verify-sha`, `flag-audit`). PASS.

**Caller-only modes not in reusable:** `pr-review`, `flag-audit` are caller-side only and never reach the reusable workflow. This is correct by design.

---

## Issues Found

### MEDIUM: Unused `snyk-token` secret declaration

**Location:** Line 52
**Detail:** The `snyk-token` secret is declared in `on.workflow_call.secrets` but is never referenced by any job or step in the reusable workflow. It is dead configuration.
**Impact:** No functional impact. May confuse maintainers about which secrets are actually needed.
**Recommendation:** Remove the `snyk-token` declaration unless it is planned for future use.

### LOW: Static concurrency group

**Location:** Lines 57-59
**Detail:** `concurrency.group: maintenance-reusable` is a static string. When the reusable workflow is called multiple times concurrently (e.g., from different branches or events), they all share the same concurrency group. With `cancel-in-progress: false`, they queue sequentially.
**Impact:** Multiple maintenance runs may queue unnecessarily. The caller has its own concurrency group (`maintenance-${{ github.event_name }}-${{ github.ref }}`) which is dynamic and event-scoped, so the static group in the reusable is redundant.
**Recommendation:** Either remove the concurrency block from the reusable workflow (let the caller manage it) or make it dynamic with an input parameter.

### LOW: `always()` on enrich may run when all upstreams are skipped

**Location:** Line 293
**Detail:** The `enrich` job uses `if: always()` combined with a mode check. In `scan-only` mode, `check-updates` is skipped. In `deps-only` mode, `scan-secrets`, `trivy-fs`, and `scan-codeql` are all skipped. The `always()` ensures enrich still runs, which is intentional.
**Impact:** None - all enrich inputs have fallback defaults (`|| 'false'`, `|| '0'`, `|| '[]'`), so skipped upstreams produce safe defaults. This is well-designed.

### INFO: Dual Trivy scans (SARIF + JSON)

**Location:** Lines 208-231
**Detail:** `trivy-fs` runs Trivy twice on the same filesystem - once for SARIF upload and once for JSON extraction. This is necessary because the Trivy GitHub Action does not support multiple output formats in a single invocation.
**Impact:** Doubles scan time. Acceptable tradeoff for Security tab integration.

---

## Test Cases for Automation

### TC-01: Mode gating - scan-only skips check-updates and agent
```yaml
# Call with mode=scan-only
# EXPECT: detect-language, scan-codeql, scan-secrets, trivy-fs, enrich, summary RUN
# EXPECT: check-updates, agent SKIP
```

### TC-02: Mode gating - deps-only skips all scan jobs and agent
```yaml
# Call with mode=deps-only
# EXPECT: check-updates, enrich, summary RUN
# EXPECT: detect-language, scan-codeql, scan-secrets, trivy-fs, agent SKIP
```

### TC-03: Mode gating - full runs everything when issues found
```yaml
# Call with mode=full, ensure enrich returns has_issues=true
# EXPECT: all 7 jobs RUN including agent
```

### TC-04: Mode gating - full skips agent when no issues
```yaml
# Call with mode=full, ensure enrich returns has_issues=false
# EXPECT: agent SKIPPED, summary still RUNS
```

### TC-05: Language detection gates CodeQL
```yaml
# Call on a repo where detect-language returns 'unknown'
# EXPECT: scan-codeql SKIPPED (condition: language != 'unknown')
```

### TC-06: Language mapping - node to javascript
```yaml
# Call on a Node.js repo where detect-language returns 'node'
# EXPECT: scan-codeql receives language='javascript' (mapped via ternary)
```

### TC-07: OpenCI ref resolution - explicit input
```yaml
# Call with openci-ref='v1.2.3'
# EXPECT: all jobs check out YiAgent/OpenCI at ref v1.2.3
```

### TC-08: OpenCI ref resolution - fallback to workflow_ref
```yaml
# Call with openci-ref='' (empty)
# EXPECT: ref extracted from github.workflow_ref after '@' prefix
```

### TC-09: Enrich fallback values on skipped upstreams
```yaml
# Call with mode=deps-only (scan jobs skipped)
# EXPECT: enrich receives secrets_found='false', trivy_critical='0', codeql_found='false'
```

### TC-10: Agent secret forwarding
```yaml
# Call with mode=full, has_issues=true
# EXPECT: agent job receives anthropic-api-key and api-base-url from caller secrets
```

### TC-11: Summary renders correct health icon
```yaml
# Test all 3 health states:
#   overall_health=healthy       -> icon: checkmark
#   overall_health=needs-attention -> icon: warning
#   overall_health=critical       -> icon: alert
```

### TC-12: Caller mode filtering - pr-review does not invoke reusable
```yaml
# Trigger caller with push event (mode resolves to pr-review)
# EXPECT: reusable-maintenance workflow NOT called; verify-sha job RUNS instead
```

### TC-13: Caller mode filtering - flag-audit does not invoke reusable
```yaml
# Trigger caller with schedule "0 15 * * 1" (mode resolves to flag-audit)
# EXPECT: reusable-maintenance workflow NOT called; flag-audit job RUNS instead
```

### TC-14: Caller secret mapping correctness
```yaml
# Verify caller passes ANTHROPIC_API_KEY -> anthropic-api-key
# Verify caller passes ANTHROPIC_BASE_URL -> api-base-url
# Verify caller does NOT pass snyk-token (unused)
```

### TC-15: Caller runner override
```yaml
# Verify caller passes runner=blacksmith-2vcpu-ubuntu-2404
# Verify all jobs in reusable use blacksmith-2vcpu-ubuntu-2404, not ubuntu-latest
```

### TC-16: Concurrency - parallel calls queue correctly
```yaml
# Trigger two maintenance runs simultaneously
# EXPECT: second run queues (cancel-in-progress: false) or cancels first (if cancel-in-progress: true)
```

### TC-17: Security - no expression injection in run blocks
```yaml
# Static analysis: grep for ${{ }} in run: blocks
# EXPECT: zero matches (all expressions passed via env:)
```

### TC-18: Security - persist-credentials false on all checkouts
```yaml
# Static analysis: verify every actions/checkout step has persist-credentials: false
# EXPECT: all checkout steps include persist-credentials: false
```

---

## Summary

| Category | Result |
|----------|--------|
| actionlint | PASS (0 errors) |
| YAML syntax | VALID |
| SHA pinning | PASS (all 5 external actions pinned) |
| Composite actions | PASS (all 6 local actions exist in repo) |
| Expression injection | PASS (env: pattern used throughout) |
| Caller compatibility | PASS (inputs, secrets, modes all align) |
| Manifest SHA | PASS (caller SHA matches manifest.yml) |
| Issues | 1 MEDIUM (unused snyk-token), 2 LOW (concurrency group, always() note) |

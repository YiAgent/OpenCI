# OpenCI CI Domain Test Report

**Date:** 2026-05-04
**Repository:** /home/w1/projects/OpenCI
**Test script:** `tests/workflows/reusable/test-reusable-ci.sh`

---

## Summary

| Category | Tests | Pass | Fail | Skip |
|----------|-------|------|------|------|
| Static Analysis | 7 | 7 | 0 | 0 |
| Live Dispatch | 3 | 3 | 0 | 0 |
| **Total** | **10** | **10** | **0** | **0** |

---

## Scenario Results

### 1. Stage ordering & dependency DAG (PASS)

**Jobs found:** 11 (preflight, detect-language, build-docker, scan-image, sign-image, generate-sbom, check-migration, eval-smoke, verify-sha, enrich, agent, execute)

**Stage 1 (Build):**
- preflight (no needs, timeout: 2m)
- detect-language needs preflight
- build-docker needs detect-language

**Stage 2 (Verify, parallel):**
- All 6 jobs (scan-image, sign-image, generate-sbom, check-migration, eval-smoke, verify-sha) need build-docker
- No sibling-to-sibling dependencies (true parallel execution)
- Conditional jobs: check-migration (gated by `run-migration == true`), eval-smoke (gated by `enable-ai-smoke == true`)

**Stage 3 (Agent):**
- enrich needs build-docker + all 6 Stage 2 jobs, runs with `if: always()`
- agent needs enrich, gated by `enrich.result == 'success' && enable-failure-agent && has-failures == 'true'`

**Stage 4 (Dispatch):**
- execute needs build-docker + 6 Stage 2 jobs + enrich + agent, runs with `if: always()`

**Circular dependencies:** None detected (verified via adjacency list DFS)

---

### 2. SHA pin verification (PASS)

**Source manifest:** `manifest.yml`

**Findings:**
- 32 SHA-pinned uses: references in reusable-ci.yml
- 3 SHA-pinned references in ci.yml
- Zero non-SHA references (@v\*, @main, @master) found
- All external action SHAs match manifest.yml entries:

| Action | Manifest SHA | Verified |
|--------|-------------|----------|
| step-security/harden-runner | f808768d1510423e83855289c910610ca9b43176 | PASS |
| actions/checkout | 11bd71901bbe5b1630ceea73d27597364c9af683 | PASS |
| YiAgent/OpenCI (self-ref) | cd1b427370ebacb56cc9c0b418d6d8985c9be539 | PASS |
| docker/login-action | 74a5d142397b4f367a81961eba4e8cd7edddf772 | PASS |
| actions/upload-artifact | ea165f8d65b6e75b540449e92b4886f43607fa02 | PASS |
| actions/download-artifact | d3f86a106a0bac45b974a628896c90dbdf5c8093 | PASS |
| Local refs (./.openci/...) | N/A (allowed) | PASS |

**Existing bats coverage:** verify-sha-consistency.bats (13 tests) covering SHA mismatch, @v\* rejection, @main rejection, pending-manifest enforcement, deprecated action rejection, local reference exemption.

---

### 3. Permissions analysis (PASS)

**Top-level:** `permissions: {}` -- minimal, jobs explicitly opt in

**Per-job breakdown:**

| Job | Permissions | Purpose |
|-----|------------|---------|
| preflight | contents: read | Probe secrets only |
| detect-language | contents: read | File scanning |
| build-docker | contents: read, packages: write, id-token: write | Docker push + OIDC |
| scan-image | contents: read, security-events: write | SARIF upload |
| sign-image | contents: read, packages: write, id-token: write | Cosign + OIDC |
| generate-sbom | contents: read | Metadata only |
| check-migration | contents: read | Script only |
| eval-smoke | contents: read, pull-requests: write, id-token: write | PR comment + OIDC |
| verify-sha | contents: read | Script only |
| enrich | contents: read, actions: read | Read job results |
| agent | contents: read, issues: write, actions: read | File issues |
| execute | actions: write, contents: read | Dispatch deploy |

All 12 jobs have explicit permissions blocks. No unnecessary admin-level access.

---

### 4. Deploy gate logic (PASS)

**Gate formula** (execute job):
```
DEPLOY_READY="false"
if [ "${DEPLOY_BLOCKED:-true}" = "false" ] && [ "$AUTO_DEPLOY" = "true" ]; then
  DEPLOY_READY="true"
fi
```

**5 edge cases tested:** All pass. Key finding: `DEPLOY_BLOCKED:-true` default handles missing enrich output gracefully.

| Scenario | deploy-ready |
|----------|-------------|
| No blocks, no auto-deploy | false |
| Blocked + auto-deploy | false |
| Not blocked + auto-deploy | true |
| Unset deploy-blocked + auto-deploy | false |
| Not blocked + auto-deploy=false | false |

---

### 5. Enrich failure detection (PASS)

**13 edge cases tested:** All pass.

Key findings on deploy-blocked scope:
- HIGH CVEs only -> FAILURE but NOT deploy-blocked (advisory)
- SHA verification fail -> FAILURE but NOT deploy-blocked (advisory)
- Smoke eval fail -> FAILURE but NOT deploy-blocked (quality advisory)
- Build fail, CRITICAL CVEs, scan/sign/SBOM/migration fail -> FAILURE AND deploy-blocked

Key findings on has-failures scope:
- Skipped jobs -> no failure
- Empty string skipped results -> treated as no failure

Both `enrich` and `execute` use `if: always()` correctly.

---

### 6. Structural integrity (PASS)

**Concurrency:**
- reusable-ci.yml: No concurrency (caller-owned, prevents GH deadlock per issue #68)
- ci.yml: group: ci-${{ github.ref }}, cancel-in-progress: false

**Timeouts:** All 12 jobs have explicit timeout-minutes matching their expected runtime (2m for fast jobs, 30m for Docker build, 15m for agentic jobs).

**harden-runner coverage:** 12 uses, one per job.

**Output wiring:**
- image-digest -> build-docker.outputs.image-digest
- deploy-time -> build-docker.outputs.completed-at
- deploy-ready -> execute.outputs.deploy-ready

---

### 7. resolve-openci logic (PASS)

**Resolution order (3 paths):**
1. openci-ref is non-empty and not "main" -> use as-is
2. workflow_ref caller is YiAgent/OpenCI -> extract ref from @\<ref\>
3. Fall back to openci-ref (defaults to "main")

**CI domain usage:** Each Stage 1/2/3 job calls resolve-openci@cd1b42737... ci.yml passes `openci-ref: ${{ github.sha }}`.

---

### 8. Standard build preflight (PASS)

**ci.yml jobs:**
- ci: uses reusable-ci.yml@\<SHA\> with secrets: inherit
- harness-test: runs bats tests/ --recursive

**Triggers:** push to main, workflow_dispatch

---

### 9. AI smoke eval enablement (PASS)

- eval-smoke condition: `if: inputs.enable-ai-smoke == true`
- ci.yml passes enable-ai-smoke: true
- eval-smoke receives anthropic-api-key from secrets
- Action correctly forwards all parameters (key, base URL, model)

---

### 10. No API key behaviour (PASS)

- preflight marks ANTHROPIC_API_KEY as --optional (non-fatal if missing)
- agent has enable-failure-agent guard (defaults to true, can be disabled)
- deploy-ready output is independent of API key (reads DEPLOY_BLOCKED from enrich)
- Non-AI jobs fully independent of anthropic-api-key

---

## Verified Design Properties

1. **4-stage pipeline**: Build -> Verify -> Agent -> Dispatch, each stage gates the next
2. **No cancel-in-progress**: Every main commit completes fully
3. **Security-first**: SHA-pinned uses:, minimal top-level permissions, harden-runner on every job
4. **Resilient to partial failures**: enrich and execute use if: always(), outputs set before failure
5. **Deploy gate correctly scoped**: HIGH CVEs, SHA violations, smoke eval failures never block deploy
6. **Parallel Stage 2**: All verify jobs depend only on build-docker
7. **resolve-openci bootstrap**: Self-referencing resolution works for all callers

---

## Files Analyzed

- .github/workflows/reusable-ci.yml -- 11 jobs, 4 stages
- .github/workflows/ci.yml -- event-entry workflow
- manifest.yml -- SHA manifest (single source of truth)
- actions/ci/build-docker/action.yml -- Docker build
- actions/ci/scan-image/action.yml -- Trivy CVE scan
- actions/ci/sign-image/action.yml -- Cosign signing
- actions/ci/eval-smoke/action.yml -- AI smoke eval
- actions/ci/check-migration/action.yml -- migration dry-run
- actions/_common/resolve-openci/action.yml -- OpenCI ref resolver
- .github/scripts/verify-sha-consistency.sh -- SHA verification
- .github/scripts/preflight-secrets.sh -- secret preflight
- skills/ci-smoke-eval/SKILL.md -- smoke eval agent prompt
- skills/ci-failure-analyst/SKILL.md -- failure analyst prompt
- tests/workflows/helpers/wf-test-lib.sh -- shared test library
- tests/scripts/verify-sha-consistency.bats -- existing SHA bats tests
- tests/scripts/preflight-secrets.bats -- existing preflight bats tests

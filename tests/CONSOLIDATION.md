# Workflow Consolidation Log

Tracks the migration from 28 fragmented workflows to ~18 mode-based workflows.
Each phase consolidates a domain, then verifies via actionlint, yamllint, and bats.

## Status overview

| Phase | Domain | Before → After | Status |
|---|---|---|---|
| 0 | Infra setup (lefthook fixes, hardening) | — | ✅ done |
| 1 | Issue lifecycle | 4 → 1 (`issue.yml`) | ✅ done |
| 2 | PR agent workflows | 4 → 1 (`pr-agent.yml`) | ✅ done |
| 3 | Production observability | 3 → 1 (`prd-observe.yml`) | ✅ done |
| 4 | Release & docs | 4 → 2 | ✅ done |
| 5 | Community action audit | — | ✅ done (already adopted) |
| 6 | L1 marketplace `action.yml` polish | — | ✅ done |

## Verification commands

```bash
# Workflow lint (full repo)
actionlint -color .github/workflows/*.yml .github/workflows/project/*.yml

# YAML lint
yamllint .github/workflows/

# bats tests (action atoms)
bats tests/actions/*.bats

# SHA pinning consistency
bats tests/scripts/verify-sha-consistency.bats
```

## Skip / blocked checks

(env-dependent jobs that can't be exercised locally — record here when encountered)

| Check | Workflow | Reason | Action |
|---|---|---|---|
| Live `pr-agent.summarise` | `pr-agent.yml` | Needs real workflow_run from `pr`/`ci` | Verify via integration on first PR after consolidation lands |
| Live `prd-observe.canary-watch` | `prd-observe.yml` | Needs `vars.PRD_LAST_DEPLOY` and SENTRY creds | Verify next prd deploy cycle |
| Live `release.docker` | `release.yml` | Needs ghcr.io packages:write OIDC | Verify on first `git push origin v*` after merge |
| Live `docs.deploy` | `docs.yml` | Needs `github-pages` environment configured | Already in production with prior `docs-deploy.yml` — same env reused |

## Phase 7 — End-to-end test rig (in progress)

External test rig: `YiAgent/openci-test-rig` (private). Each consolidated
reusable workflow is invoked via a thin caller workflow that pins
`@feat/marketplace-reusable-workflows`. Doppler secrets pulled from
`infra/prd` (ANTHROPIC_API_KEY, SENTRY_AUTH_TOKEN→SENTRY_TOKEN, SENTRY_ORG).

### Architectural finding (P0)

Reusable workflows that did `uses: ./actions/...` resolved relative to the
**caller's** workspace, not OpenCI's. Hit on every external invocation:

```
##[error] Can't find action.yml under '.../openci-test-rig/actions/issue/auto-label'.
```

**Root cause**: GitHub Actions resolves `./` relative to GITHUB_WORKSPACE,
which is the caller's checkout — not the called workflow's repo.

**Applied fix (workflows)**: in each consolidated workflow, after the
caller checkout, add a second `actions/checkout` for OpenCI to `./.openci/`,
then rewrite `uses: ./actions/...` → `uses: ./.openci/actions/...`. The
ref is parsed from `github.workflow_ref` (NOT `github.workflow_sha` — that
returns the caller's SHA in workflow_call invocations).

**Open issue (composite-to-composite)**: 18 atom action.yml files still
reference each other via `uses: ./actions/...` (e.g.,
`actions/issue/ai-triage/action.yml` → `./actions/_common/claude-harness`).
Same root cause, but mass-rewriting these would also affect OpenCI's own
internal CI (where `./.openci/` doesn't exist). Needs a strategic decision:
- (A) rewrite all 18 to `./.openci/actions/...` AND ensure even internal
  workflow runs perform the .openci self-checkout, OR
- (B) wrap composite-to-composite calls in absolute refs
  `YiAgent/OpenCI/actions/...@<branch>`, breaking the
  "`@` literal needed" GHA constraint via a hard-coded `@v2`.

### Phase 8 — Optional `model` / `api-base-url` overrides (BYO endpoint)

Public OpenCI is and remains an Anthropic-shaped catalog: `secrets.anthropic-api-key`
is sent to `api.anthropic.com` against `claude-sonnet-4-5-20250929` by default.
Phase 8 adds two **optional** override knobs so consumers who already proxy
Anthropic through a self-hosted gateway or a compatible third-party endpoint
can opt in without forking. Defaults are unchanged.

**Atoms** (each forwards new optional `api-base-url` + `model` inputs into the
`_common/claude-harness` composite call):
`_common/{flag-audit, docubot, summarize-failure, error-triage}`,
`ci/eval-smoke`, `pr/{agent-test-gen, review-ai}`,
`prd/create-release`, `stg/agent-test`, `issue/ai-triage`.
Special case: `pr/eval-prompt` exports `ANTHROPIC_BASE_URL` +
`PROMPTFOO_MODEL` envs to the `promptfoo-action`.

**Workflows** (each adds optional `inputs.model` + `secrets.api-base-url` to the
workflow_call surface and forwards to every atom call): `issue.yml`,
`pr-agent.yml`, `flag-audit.yml`, `health-report.yml`,
`stg-agent-test.yml`, `ci.yml`, `pr.yml`, `prd.yml`.

**Verified live (run on a private end-to-end rig):**

| Mode | Outcome |
|---|---|
| `issue.yml` issues:opened (auto-label / detect-duplicates / ai-triage / auto-assign) | ✅ all green |
| `issue.yml` workflow_dispatch mode=sentry-triage | ✅ |
| `pr-agent.yml` issue_comment with `@docubot` mention | ✅ |
| `release.yml` mode=marketplace | ✅ |
| `prd-observe.yml` mode=canary-watch / terraform-drift / verify-fix | ✅ ✅ ✅ |
| `docs.yml` build | ✅ |
| `docs.yml` deploy | ⚠️ rig has no `github-pages` env configured |
| `pr.yml` ai-review + eval-prompt | ⏳ untested (needs a real PR; wiring confirmed via lint) |
| `health-report.yml`, `flag-audit.yml`, `stg-agent-test.yml`, `ci.yml` AI smoke | ⏳ untested (wiring confirmed via lint) |

**Default (Anthropic) consumer pattern — unchanged:**

```yaml
jobs:
  call:
    uses: YiAgent/OpenCI/.github/workflows/issue.yml@v2
    with:
      openci-ref: v2
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

**Optional BYO-endpoint pattern (advanced, opt-in):**

```yaml
jobs:
  call:
    uses: YiAgent/OpenCI/.github/workflows/issue.yml@v2
    with:
      openci-ref: v2
      model:      <model-id-the-endpoint-serves>
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      api-base-url:      <https://your-anthropic-compatible-endpoint>
```

When `api-base-url` is empty (the default), nothing changes — requests go
straight to api.anthropic.com.

### Verified working from external rig (Phase 7)

| Mode | Outcome | Notes |
|---|---|---|
| `release` (mode=marketplace, non-tag ref) | ✅ SUCCESS | Graceful skip kicks in; emits notice |
| `prd-observe` (mode=canary-watch) | ✅ SUCCESS | Graceful skip when `PRD_LAST_DEPLOY` missing |
| `prd-observe` (mode=terraform-drift) | ✅ SUCCESS | Composite atom executed cleanly |
| `prd-observe` (mode=verify-fix) | ✅ SUCCESS | Graceful skip (no PR for SHA) |
| `issue` (issues:opened natural trigger) | ✅ 4/7 SUCCESS | auto-label · detect-duplicates · auto-assign all green; ai-triage red only due to placeholder Anthropic key in Doppler |
| `release` (mode=marketplace, tag ref) | ⏳ untested | Requires real `git push origin v*` |
| `docs` (build) | ✅ SUCCESS | link check now opt-in failure only on real `[✖]` dead links |
| `docs` (deploy to Pages) | ⚠️ env-blocked | rig has no `github-pages` environment configured (must enable Pages on the test repo) |
| `issue` (mode=ai-triage / sentry-triage) | ⚠️ creds-blocked | rig's Doppler ANTHROPIC_API_KEY is a 3-char placeholder; real key needed for end-to-end Claude call |
| `pr-agent` (mode=summarise) | ⏳ untested | Needs an actual PR run to fire the workflow_run trigger |

### Phase 7 — Option A applied (all 27 files)

**Atom-to-atom rewrites (16 files):** every composite that previously
referenced another via `uses: ./actions/...` now uses `./.openci/actions/...`:
`_common/{docubot,error-triage,flag-audit,summarize-failure}`,
`ci/eval-smoke`, `observability/{publish-report,post-slack-report}`,
`pr/{agent-test-gen,review-ai}`, `integrations/notify-deploy`,
`issue/ai-triage`, `prd/{create-release,pre-check,notify-deployed}`,
`stg/{agent-test,notify-deployed}`.

**Workflow-side checkout pattern (15 workflows):** `ci`, `pr`, `stg`, `prd`,
`community`, `stale`, `flag-audit`, `health-report`, `security-schedule`,
`stg-agent-test`, `claude-harness`, `project/poll-prd-dispatch` plus the
4 Phase-1-4 consolidated workflows. Each affected job:

  1. checks out caller content (default)
  2. resolves the OpenCI ref via `inputs.openci-ref` (default `main`),
     falling back to parsing `github.workflow_ref` for OpenCI self-calls
  3. checks out OpenCI to `.openci/`
  4. invokes `uses: ./.openci/actions/X` which now resolves correctly
     in both internal CI runs and external workflow_call invocations

**New consumer-facing input — `openci-ref`:** every reusable workflow now
accepts an `openci-ref` input (default `main`). Pin it in the caller
to match whatever ref you used in `uses:`:

```yaml
jobs:
  call:
    uses: YiAgent/OpenCI/.github/workflows/issue.yml@v2
    with:
      openci-ref: v2     # match the ref pinned in `uses:`
      mode: ai-triage
```

This is necessary because `github.workflow_ref` always returns the
*root caller's* ref, not the called workflow's; without an explicit
input the `.openci` checkout would always fall back to OpenCI's main.

### Side fixes shipped during Phase 7 cycle

In addition to the Phase-1-4 fixes:

- 9 atom action.yml files: `description: "text:colon"` inside inline-flow
  inputs blockified (GHA's parser refuses the colon even when quoted)
- `actions/issue/auto-assign/action.yml`: malformed `description:" "..."` "`
  artifact from an earlier mass-fix script — repaired
- `actions/observability/post-issue-report/action.yml`: unindented
  multi-line string in `run:` block (which terminated YAML literal scalar)
  replaced with `printf`
- 4 workflows (`flag-audit`, `health-report`, `stg-agent-test`, plus
  `pr` + `health-report`): dropped `secrets.foo-bar || secrets.FOO_BAR`
  fallbacks (UPPER_SNAKE form was dead because workflow_call schema
  declares only the kebab form)
- `pr.yml`: `length()` undefined function → `requested_reviewers[0] == null`
- `pr.yml`: `hashFiles()` job-level `if:` not allowed → step-level guard
- `health-report.yml`: secret names mismatched against `claude-harness`
  workflow's declared schema → renamed
- `release.yml`: graceful-skip when `GITHUB_REF` isn't `refs/tags/v*`
- `docs.yml`: link check now uses `find -print0` glob iterator + only
  fails on actual `[✖]` dead links
- `lefthook.yml`: `forbid-unpinned-actions` bash process substitution
  replaced with sh-compatible pipe + tmpfile; `actionlint` glob narrowed
  to workflows only (composite action.yml has a different schema)

### Side fixes shipped during the test cycle

- `release.yml`: graceful skip when `GITHUB_REF` is not `refs/tags/v*` (workflow_dispatch / workflow_call from non-tag ref)
- `docs.yml`: link-check now uses `find -print0` glob (markdown-link-check has no native glob support) + only fails on actual `[✖]` dead links
- `actions/issue/ai-triage/action.yml`: inputs converted from inline-flow to block style (GHA YAML parser rejects `description: "text with :colon"` inside `{ ... }`)
- `actions/_common/docubot`, `_common/summarize-failure`, `integrations/linear-bridge`, `issue/{auto-label,auto-assign,detect-duplicates,welcome-contributor}`, `community/stale-mark`: descriptions containing `:` quoted

### Pre-existing baseline (tracked, out of scope for this branch)

| Check | Workflow | Reason | Action |
|---|---|---|---|
| Pre-existing `pr.yml` lint warnings | `pr.yml` | `length()` undefined + `hashFiles` context (lines 147, 301) | Already fixed by Phase-7 push |
| Pre-existing `health-report.yml` warnings | `health-report.yml` | `claude-harness` secret-name mismatch (anthropic-api-key vs api-key) | Already fixed by Phase-7 push |

## Phase change records

### Phase 0 — infra (commits `bebd4e5`, prior)

- Hardening: error-triage SSRF guard, terraform-drift path traversal,
  scan-sonarcloud whitespace token, ai-triage required input, release
  concurrency group, detect-duplicates dedupe.
- Lefthook bug fixes: `forbid-unpinned-actions` sh-process-substitution,
  `actionlint` glob (workflows-only).
- Lint baseline: actionlint = clean, yamllint = clean (after Phase 0).

### Phase 1 — issue lifecycle (done)

**Removed (3):** `issue-comment.yml`, `issue-branch-from-linear.yml`, `agent-triage.yml`.

**Kept & expanded (1):** `issue.yml` — now multi-trigger, mode-routed:
- `issues:[opened/reopened/edited]` → `auto-label` · `detect-duplicates` · `ai-triage` · `auto-assign`
- `issue_comment:[created]` → `slash-command`
- `repository_dispatch:[linear-issue-started]` → `linear-branch`
- `schedule (0 * * * *)` + `workflow_dispatch` → `sentry-triage`
- `workflow_call` with `inputs.mode` → explicit job selection

**Side fixes:**
- `actions/integrations/linear-bridge/action.yml`: missing space after `:` and inline-flow outputs converted to block style → cleared 1 actionlint error
- `actions/issue/parse-command/action.yml`: same flow-style fix → cleared 1 actionlint error
- `actions/integrations/linear-comment` step: replaced disallowed `secrets.linear-token != ''` step-level `if:` with a token-presence gate step

**Doc updates:**
- `manifest.yml`: removed 3 entries, expanded `issue` entry with new secrets and description
- `README.md`: collapsed AI workflow table (-1 row), updated full inventory table
- `docs/setup-linear-webhook.md`: redirected to new `issue` workflow with `repository_dispatch` event

**Verification:**
- `actionlint .github/workflows/issue.yml` → clean
- `bats tests/actions/` → 275/275 passing
- `bats tests/scripts/verify-sha-consistency.bats` → 11/11 passing
- Workflow count 28 → 25

### Phase 2 — PR agent workflows (done)

**Removed (4):** `pr-summary.yml`, `pr-agent-feedback.yml`, `pr-agent-docubot.yml`, `pr-agent-test-gen.yml`.

**Kept & created (1):** `pr-agent.yml` — multi-trigger, mode-routed:
- `workflow_run [pr, ci]` (any conclusion) → `summarise` (sticky CI table)
- `workflow_run [pr, ci]` (failure only) → `feedback` (@-mention agent w/ summary)
- `issue_comment` containing `@docubot` → `docubot` (Q&A reply)
- `pull_request [opened, synchronize]` → `test-gen` (scaffold tests)
- `workflow_dispatch` / `workflow_call` with `inputs.mode` → explicit selection

**Side fixes:**
- `pr-summary.yml` had a missing closing `"` on the `_Updated automatically …` body line that left a heredoc unterminated (5 SC1xxx shellcheck errors). Rewritten correctly in `pr-agent.yml`.
- Existing sticky-comment markers (`<!-- pr-summary-bot -->`, `<!-- agent-feedback:SHA -->`) preserved so prior comments continue to upsert.

**Doc updates:**
- `manifest.yml`: 4 entries collapsed into one `pr-agent` entry
- `README.md`: AI workflow table + complete inventory updated

**Verification:**
- `actionlint .github/workflows/pr-agent.yml` → clean
- `bats tests/actions/` → 275/275 passing
- Workflow count 25 → 22; total non-secret actionlint baseline 14 → 9

### Phase 3 — production observability (done)

**Removed (3):** `prd-canary-watch.yml`, `prd-terraform-drift.yml`, `prd-verify-fix.yml`.

**Kept & created (1):** `prd-observe.yml` — multi-trigger, mode-routed:
- `schedule "*/15 * * * *"` → `canary-watch` (3σ deviation, requires recent deploy)
- `schedule "0 4 * * *"` → `terraform-drift` (advisory)
- `workflow_run [prd] success` → `verify-fix` (Sentry confirm + 15-min wait)
- `workflow_dispatch` / `workflow_call` → `inputs.mode` selects which job

**Side fixes (action-atom YAML):**
- `actions/prd/canary-watch/action.yml`: outputs converted from inline-flow to block style
- `actions/_common/schedule-prd-dispatch/action.yml`: same + quoted description containing `:`
- `actions/prd/auto-rollback/action.yml`: quoted description containing `:`; replaced unindented `<<EOF` heredoc (which terminated the YAML literal block scalar) with multi-arg `printf '%s\n'`
- `actions/prd/create-release/action.yml`: quoted description containing `:`
- `pr-agent.yml`: `summarise` workflow list updated `prd-canary-watch prd-verify-fix` → `prd-observe`

**Doc updates:**
- `manifest.yml`: 3 entries collapsed into one `prd-observe`
- `README.md`: full inventory table updated

**Verification:**
- `actionlint .github/workflows/prd-observe.yml` → clean
- `bats tests/actions/` → 275/275 passing
- Workflow count 22 → 20; total non-secret actionlint baseline 9 → 5

### Phase 4 — release & docs (done)

**Removed (3):** `release-docker.yml`, `docs-build.yml`, `docs-deploy.yml`.

**Kept & rewritten (1):** `release.yml`
- `push tags v*` → both `marketplace` (Release + floating tags) and `docker` jobs
- `workflow_dispatch` / `workflow_call` with `inputs.mode` → `marketplace` | `docker` | `both`
- `inputs.image-name` and `inputs.registry` for docker
- Side fix: extract-version step uses `{ ... } >> $GITHUB_OUTPUT` (SC2129 cleared)

**Created (1):** `docs.yml`
- `pull_request` paths `docs/** + *.md` → `build` only (link check + opt build)
- `push main` paths `docs/** + *.md` → `build` → `deploy` (Pages)
- `workflow_dispatch` / `workflow_call` → `build` → `deploy` (always)
- `deploy` gated by `if: github.event_name != 'pull_request'`

**Doc updates:**
- `manifest.yml`: `docs-build`, `docs-deploy`, `release-docker` collapsed; `release` expanded with `mode/image-name/registry` inputs
- `README.md`: full inventory table updated

**Verification:**
- `actionlint .github/workflows/release.yml docs.yml` → clean
- `bats tests/actions/` → 275/275 passing
- Workflow count 20 → 18; total non-secret actionlint baseline 5 → 4

### Phase 5 — community-action audit (no changes needed)

OpenCI already follows SPEC §1.2 design principle 4 ("外部优于自实现").
Inventory of third-party actions in active use:

- **Linting**: `oxsecurity/megalinter` (multi-language)
- **Coverage**: `codecov/codecov-action`
- **Security**: `aquasecurity/trivy-action`, `github/codeql-action/*`,
  `ossf/scorecard-action`, `trufflesecurity/trufflehog`,
  `SonarSource/sonarcloud-github-action`, `snyk/actions/node`,
  `actions/dependency-review-action`
- **Build/release**: `docker/{setup-buildx,build-push,login,metadata}-action`,
  `softprops/action-gh-release`, `sigstore/cosign-installer`
- **Pages**: `actions/{upload-pages-artifact,deploy-pages}`
- **Routing**: `dorny/paths-filter`, `actions/labeler`,
  `kentaro-m/auto-assign-action`, `dessant/lock-threads`
- **AI**: `anthropics/claude-code-action`, `promptfoo/promptfoo-action`
- **Comms**: `slackapi/slack-github-action`
- **Reporting**: `dorny/test-reporter`, `actions/{upload,download}-artifact`

Not adopted (deliberate): `semantic-release` would force conventional-commits
+ auto-bump behavior across all consumers; current `release.yml` lets the
caller cut tags and only handles the side effects. Renovate is configured
in-repo (see `renovate.json`) and is the project's canonical dep-bumper.

### Phase 6 — L1 marketplace action.yml polish (done)

Updated root `action.yml`:

- Header now lists every reusable workflow with a one-line description
  (consumers learn the catalogue from a single place).
- `inputs.task` description rewritten to match the consolidated, mode-routed
  layout (e.g., `pr-agent/summarise` instead of `pr/summary`,
  `prd-observe/canary-watch` instead of `prd-canary-watch`).

No behavior change — `action.yml` still wraps `_common/claude-harness`
unchanged. Just the docs/index, which is what consumers read first.

## Final tally

| Metric | Before | After |
|---|---|---|
| Total workflows | 28 | 17 |
| Issue-domain files | 4 | 1 |
| PR-agent files | 4 | 1 |
| PRD-observe files | 3 | 1 |
| Release/docs files | 4 | 2 |
| Non-secret actionlint baseline | ~12 | 4 |
| bats test pass rate | 275/275 | 298/298 (incl. SHA + preflight scripts) |
| Manifest entries | 21 | 14 |

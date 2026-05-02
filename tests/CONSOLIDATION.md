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
| 4 | Release & docs | 4 → 2 | ⏳ pending |
| 5 | Community action audit | — | ⏳ pending |
| 6 | L1 marketplace `action.yml` polish | — | ⏳ pending |

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

# Workflow Consolidation Log

Tracks the migration from 28 fragmented workflows to ~18 mode-based workflows.
Each phase consolidates a domain, then verifies via actionlint, yamllint, and bats.

## Status overview

| Phase | Domain | Before → After | Status |
|---|---|---|---|
| 0 | Infra setup (lefthook fixes, hardening) | — | ✅ done |
| 1 | Issue lifecycle | 4 → 1 (`issue.yml`) | ✅ done |
| 2 | PR agent workflows | 4 → 1 (`pr-agent.yml`) | ⏳ pending |
| 3 | Production observability | 3 → 1 (`prd-observe.yml`) | ⏳ pending |
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

# OpenCI

> Agentic GitHub Actions workflow library for CI/CD, security, observability,
> and AI-augmented development. Pin once, share everywhere.

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-OpenCI-blue.svg)](https://github.com/marketplace/actions/openci)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-fe5196.svg)](https://www.conventionalcommits.org)

---

## What this is

OpenCI is a curated set of GitHub Actions **reusable workflows** + supporting
**composite / atomic actions** that together cover the day-one needs of any
serious software project — with AI agents built into every stage of the
pipeline.

**Core capabilities:**

- PR quality gate (lint / test / scan-deps / scan-secrets / build-check / **AI review**)
- Build, push, sign, scan Docker images
- Deploy to staging and production with observation windows + auto-rollback
- **Agent-driven issue lifecycle** (deterministic ingest → enrichment → Claude planning → guarded execution)
- **Multi-provider observability** (Sentry / PostHog / Axiom / Datadog / LangSmith → Claude incident analyst)
- Release engineering (cosign keyless, AI changelog, Pages docs deploy)
- **Autonomous staging tests** (L1–L4 Playwright browser automation)
- **Docs sync agent** (drift detection → Claude action plan → auto-PR)
- **Maintenance analyst** (CVE correlation → dependency intelligence → auto-issue)

Consumers reference it via `uses: YiAgent/OpenCI/.github/workflows/reusable-<id>.yml@v3`.
No fork required.

## Architecture: dual-identity design

OpenCI has two clear identities:

1. **A normal project** that dogfoods its own workflows via 12 thin event-entry
   files (`agent.yml`, `ci.yml`, `pull-request.yml`, etc.)
2. **A tool library** that exposes **12 public reusable workflows** (`reusable-*.yml`)
   for external consumption

External users only call the `reusable-*.yml` files. The unprefixed event
entries are OpenCI's own dogfooding shims — write your own in your repo.

### The 4-stage agentic pipeline

Most reusable workflows follow a consistent 4-stage pattern:

| Stage | Purpose | Example |
| --- | --- | --- |
| **1. Ingest / Detect** | Deterministic data collection | Parse issue forms, detect language, build Docker, run lint |
| **2. Enrich** | Build agent workspace from stage 1 results | Merge gate results + live PR/issue data into context JSON |
| **3. Agent** | Claude produces a structured action plan | `pr-action-plan/v1`, `issue-action-plan/v1`, `docs-action-plan/v1`, `observe-action-plan/v1` |
| **4. Execute** | Guarded allowlisted execution of the plan | Post comments, create issues, trigger deploys, run rollbacks |

This pattern appears in: `reusable-pr`, `reusable-issue`, `reusable-docs`,
`reusable-observability`, and `reusable-ci` (failure-only agent stage).

### The Claude harness

All AI calls go through a single primitive: `actions/_common/claude-harness`.
It wraps `anthropics/claude-code-action` with:

- **Prompt resolution**: direct text → slash-command → caller-provided file → built-in `skills/<task>/SKILL.md`
- **Mustache templating**: `{{repo}}`, `{{run_id}}`, `{{actor}}` + arbitrary `context` JSON keys
- **Tool allowlist management**: baseline tools + caller-extensible `extra-allowed-tools`
- **Multi-provider support**: Anthropic, AWS Bedrock, Google Vertex AI, Microsoft Foundry
- **MCP server integration**: configurable via `mcp-config` input

## Five design principles

1. **Change frequency decides location.** Stable atoms live deep; volatile
   prompts and orchestration live near the top.
2. **Names mean something.** `reusable-pr.yml`, `reusable-ci.yml` — never
   abbreviated, never alias-dressed.
3. **Calls flow one direction.** Workflow → composite → atom → third-party
   action. No upward calls, no peer-to-peer between atoms.
4. **External over self-implementation.** We don't reinvent megalinter,
   trivy, cosign, codecov.
5. **Secure by default.** Every job runs `step-security/harden-runner`,
   every workflow declares `permissions: {}` then opts in per-job, every
   third-party action is pinned to a verified 40-char commit SHA enforced
   by [`verify-sha-consistency.sh`](.github/scripts/verify-sha-consistency.sh).

Full reasoning: [`docs/SPEC.md`](docs/SPEC.md).

## Quick start

Most consumers start with these references in their own `.github/workflows/`:

```yaml
# .github/workflows/on-pr.yml — PR quality gate with AI review
name: on-pr
on: { pull_request: }
jobs:
  quality:
    uses: YiAgent/OpenCI/.github/workflows/reusable-pr.yml@v3
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# .github/workflows/on-ci.yml — merge-to-main build + sign + scan
name: on-ci
on: { push: { branches: [main] } }
jobs:
  build:
    uses: YiAgent/OpenCI/.github/workflows/reusable-ci.yml@v3
    with:
      image-name: my-app
    secrets:
      registry-token: ${{ github.token }}
```

```yaml
# .github/workflows/on-deploy.yml — staging deploy
name: on-deploy-stg
on:
  workflow_run:
    workflows: [on-ci]
    types: [completed]
jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    uses: YiAgent/OpenCI/.github/workflows/reusable-stg.yml@v3
    with:
      image-digest: ${{ github.event.workflow_run.outputs.image-digest }}
      image-name: my-app
      app-name: my-app
      health-url: https://stg.example.com/health
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}
```

```yaml
# .github/workflows/on-issue.yml — agent-driven issue orchestration
name: on-issue
on:
  issues: { types: [opened, reopened, edited, closed] }
  issue_comment: { types: [created] }
  schedule:
    - cron: '0 2 * * *'   # daily stale sweep
jobs:
  orchestrate:
    uses: YiAgent/OpenCI/.github/workflows/reusable-issue.yml@v3
    with:
      mode: lifecycle
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# .github/workflows/on-agent.yml — ad-hoc AI tasks
name: on-agent
on: { workflow_dispatch: }
jobs:
  task:
    uses: YiAgent/OpenCI/.github/workflows/reusable-agent.yml@v3
    with:
      task: pr/review
      prompt: "Review the latest changes and summarize risks"
    secrets:
      api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

> Replace `@v3` with whichever stable major suits you. Pre-release work
> can pin a SHA from `main`; breaking changes are flagged in
> [`CHANGELOG.md`](CHANGELOG.md).

## Workflow catalogue

### Public reusable workflows (12)

External consumers call these via `uses:`:

| Reusable workflow | Purpose | Agentic |
| --- | --- | --- |
| [`reusable-pr.yml`](.github/workflows/reusable-pr.yml) | PR quality gate: lint / test / scan / build / coverage + AI review (4-stage) | Yes |
| [`reusable-ci.yml`](.github/workflows/reusable-ci.yml) | Merge-to-main: build + sign + scan + AI smoke eval + failure analyst (4-stage) | Yes |
| [`reusable-issue.yml`](.github/workflows/reusable-issue.yml) | Issue orchestrator: `lifecycle` / `maintenance` / `ingest` modes (4-stage) | Yes |
| [`reusable-agent.yml`](.github/workflows/reusable-agent.yml) | The Claude harness — single AI primitive for any task | Yes |
| [`reusable-stg.yml`](.github/workflows/reusable-stg.yml) | Staging deploy: docker/k8s + migration + smoke + auto-rollback | No |
| [`reusable-prd.yml`](.github/workflows/reusable-prd.yml) | Production deploy: environment gate + observation window + auto-rollback | Partial |
| [`reusable-observability.yml`](.github/workflows/reusable-observability.yml) | Post-deploy: multi-provider metrics → Claude incident analyst (4-stage) | Yes |
| [`reusable-release.yml`](.github/workflows/reusable-release.yml) | Marketplace + Docker release with cosign keyless signing | No |
| [`reusable-docs.yml`](.github/workflows/reusable-docs.yml) | Docs quality: lint + drift detection → Claude sync agent (4-stage) | Yes |
| [`reusable-maintenance.yml`](.github/workflows/reusable-maintenance.yml) | Security sweeps + dependency intelligence → Claude analyst (4-stage) | Yes |
| [`reusable-deps.yml`](.github/workflows/reusable-deps.yml) | Renovate patch PR auto-merge | No |
| [`reusable-self-test.yml`](.github/workflows/reusable-self-test.yml) | Workflow/action lint + security validation (actionlint, zizmor, bats) | No |

### Event entry files (12)

OpenCI dogfoods its own reusables via these thin shims:

| Event entry | Trigger | Delegates to |
| --- | --- | --- |
| `agent.yml` | `workflow_dispatch` | `reusable-agent.yml` |
| `ci.yml` | `push` main, `workflow_dispatch` | `reusable-ci.yml` + bats harness test |
| `pull-request.yml` | `pull_request`, `workflow_dispatch` | `reusable-pr.yml` |
| `issue-ops.yml` | `issues`, `issue_comment`, `schedule` | `reusable-issue.yml` |
| `release.yml` | `push` tags `v*`, `workflow_dispatch` | `reusable-release.yml` |
| `docs.yml` | `pull_request`, `push` main, `schedule`, `release` | `reusable-docs.yml` |
| `on-maintenance.yml` | `schedule`, `push`/`pull_request` (manifest/actions paths) | `reusable-maintenance.yml` |
| `auto-release.yml` | `push` main, `workflow_dispatch` | Standalone (conventional-commit version bump) |
| `on-main-bump-sha.yml` | `push` main, `workflow_dispatch` | Standalone (SHA self-reference bump) |
| `dependencies.yml` | `pull_request_target`, `workflow_dispatch` | `reusable-deps.yml` |
| `ci-self-test.yml` | `push`/`pull_request` (workflows/actions paths) | `reusable-self-test.yml` |
| `test.yml` | `workflow_dispatch` | Ad-hoc testing |

### Built-in AI skills (15)

Each skill has a `SKILL.md` prompt file under `skills/`:

| Skill | Domain | Used by |
| --- | --- | --- |
| `pr-review-agent` | Structured PR review action planning | `reusable-pr.yml` stage 3 |
| `pr-review` | PR code review | `reusable-agent.yml` (ad-hoc) |
| `pr-test-gen` | Test scaffold generation | `reusable-agent.yml` (ad-hoc) |
| `issue-orchestrate` | Issue lifecycle action planning | `reusable-issue.yml` stage 3 |
| `issue-triage` | Issue classification and prioritization | `reusable-agent.yml` (ad-hoc) |
| `ci-failure-analyst` | CI failure analysis and remediation | `reusable-ci.yml` stage 3 |
| `ci-smoke-eval` | Docker image smoke evaluation | `reusable-ci.yml` eval-smoke |
| `stg-agent-test` | Autonomous staging tests (L1–L4) | `reusable-stg.yml` (consumer) |
| `docs-sync-agent` | Documentation synchronization | `reusable-docs.yml` stage 3 |
| `maintenance-analyst` | CVE/dependency correlation | `reusable-maintenance.yml` stage 4 |
| `agents-ai-changelog` | Keep-a-Changelog release notes | `reusable-prd.yml` create-release |
| `agents-docubot` | Repository documentation Q&A | `reusable-agent.yml` (ad-hoc) |
| `ops-error-triage` | Sentry error deduplication | `reusable-observability.yml` |
| `ops-flag-audit` | Feature flag hygiene | `on-maintenance.yml` flag-audit |
| `ops-summarize-failure` | CI failure summarization | `reusable-agent.yml` (ad-hoc) |

## Integration points

- **Container registry:** `ghcr.io` by default; override via `registry` input.
- **AI provider:** Anthropic via `claude-code-action`. Set `ANTHROPIC_API_KEY`.
  Also supports AWS Bedrock, Google Vertex AI, Microsoft Foundry.
- **Observability:** Sentry / Datadog / PostHog / LangSmith / Axiom — all
  graceful-skip on missing tokens.
- **Notifications:** Slack via webhook URL.
- **Issue tracker bridge:** Linear via webhook (see
  [`docs/setup-linear-webhook.md`](docs/setup-linear-webhook.md)).

## Repository layout

```
.github/workflows/          # 13 event-entry shims + 12 reusable workflows
.github/scripts/            # cross-workflow shell helpers (verify-sha, etc.)
.github/ISSUE_TEMPLATE/     # bug / feature / question / security templates
.github/agent/              # shared + domain agent context and skill files
  shared/                   #   AGENTS.md + shared skills (add-comment, escalate, notify)
  pr/                       #   PR agent context + 8 skills
  issue/                    #   Issue agent context + 8 skills
  docs/                     #   Docs agent context + rules
  observe/                  #   Observability agent context + provider guides
actions/                    # 76 composite + atomic actions
  _common/                  #   shared building blocks (claude-harness, detect-language, etc.)
  pr/ ci/ stg/ prd/         #   stage-specific atoms
  integrations/             #   SaaS-specific atoms (sentry, datadog, posthog, etc.)
  issue/ security/ docs/    #   domain-specific atoms
  maintenance/ deploy/      #   ops atoms
skills/                     # 15 built-in Claude task prompts (SKILL.md files)
tests/                      # bats suites + fixtures + workflow reports
docs/                       # SPEC.md + setup guides + design plans
manifest.yml                # verified third-party SHAs (191 references, single source of truth)
```

## Status

- **191** third-party `uses:` references, **0** SHA-pinning violations
- **129** bats unit tests, all green
- **12** public reusable workflows, **12** event entry files
- **76** composite/atomic actions
- **15** built-in AI skills
- 4-stage agentic pipeline across PR, CI, Issue, Docs, Observability, Maintenance

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). The short version:

```bash
brew install yq bats-core jq shellcheck yamllint
brew install lefthook && lefthook install   # optional but recommended
git checkout -b feat/<short-name>
# ... make changes + write bats ...
bats tests/scripts/ tests/actions/
bash .github/scripts/verify-sha-consistency.sh
git commit -m "feat: ..." # Conventional Commits
gh pr create
```

Every PR runs `verify-sha-consistency` + the full bats suite + lint via
`reusable-pr.yml`. The CONTRIBUTING doc spells out the global constraints
every change must obey.

## Security

Found a vulnerability? See [`SECURITY.md`](SECURITY.md). Use GitHub's
private vulnerability reporting; **do not** open a public issue.

## Licence

MIT — see [`LICENSE`](LICENSE).

# OpenCI

> Reusable GitHub Actions workflow library for CI/CD, security, observability,
> and AI-augmented development. Pin once, share everywhere.

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-OpenCI-blue.svg)](https://github.com/marketplace/actions/openci)
[![on-security](https://github.com/YiAgent/OpenCI/actions/workflows/on-security.yml/badge.svg)](https://github.com/YiAgent/OpenCI/actions/workflows/on-security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-fe5196.svg)](https://www.conventionalcommits.org)

---

## What this is

OpenCI is a curated set of GitHub Actions **reusable workflows** + supporting
**composite / atomic actions** that together cover the day-one needs of any
serious software project:

- PR quality gate (lint / test / scan-deps / scan-secrets / build-check / AI review)
- Build, push, sign, scan Docker images
- Deploy to staging and production with observation windows + auto-rollback
- Incident-grade error rate gates, canary 3σ checks, fix verification
- Issue / community / stale lifecycle automation
- Release engineering (cosign keyless, AI changelog, Pages docs deploy)
- AI agent feedback, autonomous staging tests, docubot, Copilot review

Consumers reference it via `uses: YiAgent/OpenCI/.github/workflows/reusable/<id>.yml@v3`.
No fork required.

External users only call the **9 unprefixed reusable workflows** under
`.github/workflows/reusable/` — `ci.yml`, `pr.yml`, `issue.yml`,
`release.yml`, `deploy.yml`, `security.yml`, `docs.yml`, `deps.yml`,
`agent.yml`. The `_*.yml` siblings are private implementation files that
the public reusables route to internally; do not depend on their names.

OpenCI is **the generic CI/CD base layer**. It is consumed by domain-specific
extensions — for example `EvolveCI` adds AI-Agent-specific workflow patterns
on top of OpenCI without modifying it.

## Five design principles

1. **Change frequency decides location.** Stable atoms live deep; volatile
   prompts and orchestration live near the top.
2. **Names mean something.** `pr.yml`, `ci.yml`, `stg.yml`, `prd.yml`,
   `claude-harness.yml` — never abbreviated, never alias-dressed.
3. **Calls flow one direction.** Workflow → composite → atom → third-party
   action. No upward calls, no peer-to-peer between atoms.
4. **External over self-implementation.** We don't reinvent megalinter,
   trivy, cosign, codecov.
5. **Secure by default.** Every job runs `step-security/harden-runner`,
   every workflow declares `permissions: {}` then opts in per-job, every
   third-party action is pinned to a verified 40-char commit SHA enforced
   by [`verify-sha-consistency.yml`](.github/workflows/reusable/security.yml).

Full reasoning: [`docs/SPEC.md`](docs/SPEC.md).

## Quick start

Most consumers start with these four references in their own
`.github/workflows/` (the file names below are conventions — pick anything):

```yaml
# .github/workflows/on-pr.yml — runs on every PR
name: on-pr
on: { pull_request: }
jobs:
  quality:
    uses: YiAgent/OpenCI/.github/workflows/reusable/pr.yml@v3
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      codecov-token:     ${{ secrets.CODECOV_TOKEN }}
```

```yaml
# .github/workflows/on-ci.yml — runs on push to main
name: on-ci
on: { push: { branches: [main] } }
jobs:
  build:
    uses: YiAgent/OpenCI/.github/workflows/reusable/ci.yml@v3
    with:
      image-name: my-app
    secrets:
      registry-token: ${{ github.token }}
```

```yaml
# .github/workflows/on-deploy.yml — runs after CI succeeds (staging)
name: on-deploy-stg
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    uses: YiAgent/OpenCI/.github/workflows/reusable/deploy.yml@v3
    with:
      image-digest: ${{ github.event.workflow_run.outputs.image-digest }}
      image-name:   my-app
      app-name:     my-app
      health-url:   https://stg.example.com/health
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}
```

```yaml
# .github/workflows/on-deploy-prd.yml — fires from a tag or repository_dispatch
name: on-deploy-prd
on:
  push: { tags: ['v*'] }
  repository_dispatch: { types: [observe-window-complete] }
jobs:
  deploy:
    uses: YiAgent/OpenCI/.github/workflows/reusable/deploy.yml@v3
    with:
      image-digest:     ${{ github.event.client_payload.image-digest || vars.LAST_CI_DIGEST }}
      stg-image-digest: ${{ github.event.client_payload.stg-image-digest || vars.LAST_STG_DIGEST }}
      stg-deploy-time:  ${{ github.event.client_payload.stg-deploy-time || vars.LAST_STG_TIME }}
      image-name:       my-app
      app-name:         my-app
      health-url:       https://example.com/health
    secrets:
      kubeconfig-prd: ${{ secrets.KUBECONFIG_PRD }}
```

> Replace `@v3` with whichever stable major suits you. Pre-release work
> can pin a SHA from `main`; breaking changes are flagged in
> [`CHANGELOG.md`](CHANGELOG.md).

## AI-powered workflows

OpenCI ships AI-powered workflows at the top level alongside infrastructure
workflows. All call `claude-harness` under the hood with task-specific prompts.

### Available AI workflows

| Workflow | Description |
| --- | --- |
| [`pr.yml`](.github/workflows/reusable/pr.yml) | PR quality gate with optional AI review (`enable-ai-review: true`) |
| [`pr-agent.yml`](.github/workflows/reusable/pr.yml) | Unified PR-agent — sticky CI summary, agent feedback on failure, @docubot Q&A, test scaffolding (mode-routed) |
| [`issue.yml`](.github/workflows/reusable/issue.yml) | Unified issue domain — lifecycle, slash commands, Linear bridge, scheduled Sentry triage (mode-routed) |
| [`ci.yml`](.github/workflows/reusable/ci.yml) | Build + sign + optional AI smoke eval (`enable-ai-smoke: true`) |
| [`stg-agent-test.yml`](.github/workflows/reusable/deploy.yml) | L1–L4 autonomous staging tests |
| [`flag-audit.yml`](.github/workflows/reusable/security.yml) | Weekly feature-flag audit and tech-debt filing |
| [`health-report.yml`](.github/workflows/reusable/agent.yml) | Daily AI-synthesised observability digest → Issue + Slack |

### Usage examples

```yaml
# PR Review (AI-powered)
jobs:
  quality:
    uses: YiAgent/OpenCI/.github/workflows/reusable/pr.yml@v3
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# Issue Triage + Deduplication
jobs:
  triage:
    uses: YiAgent/OpenCI/.github/workflows/reusable/issue.yml@v3
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# Staging Agent Tests (after deploy)
jobs:
  agent-test:
    uses: YiAgent/OpenCI/.github/workflows/reusable/deploy.yml@v3
    with:
      health-url: ${{ vars.STG_HEALTH_URL }}
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Marketplace Action (single entrypoint)

For a unified single-step entrypoint, use the Marketplace action directly:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: YiAgent/OpenCI@v3
    with:
      task: pr/review
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Direct composite action reference

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: YiAgent/OpenCI/actions/pr/review-ai@v3
    with:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Workflow catalogue

OpenCI exposes **9 public reusable workflows** under
`.github/workflows/reusable/`. External users only call these; the
`_*.yml` siblings in the same directory are private implementation
files.

| Public reusable | Purpose |
| --- | --- |
| [`reusable/ci.yml`](.github/workflows/reusable/ci.yml) | Merge-to-main build + scan + sign + AI smoke + SHA drift verification |
| [`reusable/pr.yml`](.github/workflows/reusable/pr.yml) | PR quality gate (lint / test / scan / build / coverage) + opt-in AI review + opt-in pr-agent (summarise / feedback / docubot / test-gen) |
| [`reusable/issue.yml`](.github/workflows/reusable/issue.yml) | Issue lifecycle (auto-label / AI triage / dedupe / assign / slash commands / Linear bridge / Sentry triage) + first-contributor welcome + stale sweep |
| [`reusable/release.yml`](.github/workflows/reusable/release.yml) | Marketplace tagging + Docker image release with cosign (mode-routed) |
| [`reusable/deploy.yml`](.github/workflows/reusable/deploy.yml) | Unified deploy: staging / production / observe (canary, drift, verify-fix) / stg-agent-test (L1–L4) / poll-prd-dispatch (mode-routed by `mode` and `environment`) |
| [`reusable/security.yml`](.github/workflows/reusable/security.yml) | Weekly CodeQL / Trivy / SBOM / Scorecard / Snyk + flag-audit + manifest SHA drift check (mode-routed) |
| [`reusable/docs.yml`](.github/workflows/reusable/docs.yml) | Link-check on PR + optional build + Pages publish on main |
| [`reusable/deps.yml`](.github/workflows/reusable/deps.yml) | Renovate patch PR auto-merge |
| [`reusable/agent.yml`](.github/workflows/reusable/agent.yml) | Single Claude harness — generic ai-task + scheduled health-digest (multi-source observability synthesis) |

OpenCI also dogfoods these reusables via 9 thin `on-*.yml` event entries
at the top level of `.github/workflows/`. External consumers write their
own `on-*.yml` (any name) that `uses:` the reusables — see Quick start
above.

Full inputs/outputs/secrets contracts live in [`manifest.yml`](manifest.yml).

## Integration points

- **Container registry:** `ghcr.io` by default; override via `registry` input.
- **AI provider:** Anthropic via `claude-code-action`. Set `ANTHROPIC_API_KEY`.
- **Observability:** Sentry / Datadog / PostHog / LangSmith / Axiom — all
  graceful-skip on missing tokens.
- **Notifications:** Slack via webhook URL.
- **Secrets:** GitHub Secrets is fine; for larger fleets see
  [`docs/setup-doppler.md`](docs/setup-doppler.md).
- **Issue tracker bridge:** Linear via webhook (see
  [`docs/setup-linear-webhook.md`](docs/setup-linear-webhook.md)).

## Repository layout

```
.github/workflows/      # 9 on-*.yml event entries (dogfooding) + reusable/ subdir
.github/workflows/reusable/   # 9 public reusable workflows + 12 _*.yml private impls
.github/scripts/        # cross-workflow shell helpers
.github/ISSUE_TEMPLATE/ # bug / feature / question / security templates
actions/                # 83 composite + atomic actions
  _common/              #   shared building blocks (claude-harness, detect-language, etc.)
  pr/ ci/ stg/ prd/     #   stage-specific atoms
  integrations/         #   SaaS-specific atoms
  observability/        #   query-* + publish-* atoms
  issue/ community/     #   issue lifecycle atoms
  security/             #   weekly scan atoms
skills/                 # built-in Claude task prompts (consumer can override)
tests/                  # bats suites + fixtures
docs/                   # SPEC.md + setup guides
tasks/                  # P0..P4 implementation plan with status
manifest.yml            # verified third-party SHAs (single source of truth)
```

## Status

Implemented in this repo (see [`tasks/`](tasks) for per-task status):

- **191** third-party `uses:` references, **0** SHA-pinning violations
- **129** bats unit tests, all green
- 4 phases shipped end-to-end (P0 foundation → P4 opt-in advanced features)

Pending follow-ups are documented inline in each skeleton action with
`STATUS: skeleton` headers and `TODO` blocks pointing at the exact
manifest-pending SHA migration or live API call needed.

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
`pr.yml`. The CONTRIBUTING doc spells out the global constraints
(`GC1..GC7`) every change must obey.

## Security

Found a vulnerability? See [`SECURITY.md`](SECURITY.md). Use GitHub's
private vulnerability reporting; **do not** open a public issue.

## Licence

MIT — see [`LICENSE`](LICENSE).

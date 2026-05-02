# OpenCI

> Reusable GitHub Actions workflow library for CI/CD, security, observability,
> and AI-augmented development. Pin once, share everywhere.

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-OpenCI-blue.svg)](https://github.com/marketplace/actions/openci)
[![verify-sha-consistency](https://github.com/YiWang24/OpenCI/actions/workflows/verify-sha-consistency.yml/badge.svg)](https://github.com/YiWang24/OpenCI/actions/workflows/verify-sha-consistency.yml)
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

Consumers reference it via `uses: YiWang24/OpenCI/.github/workflows/<id>.yml@v2`.
No fork required.

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
   by [`verify-sha-consistency.yml`](.github/workflows/verify-sha-consistency.yml).

Full reasoning: [`docs/SPEC.md`](docs/SPEC.md).

## Quick start

Most consumers start with these four references in their own
`.github/workflows/`:

```yaml
# .github/workflows/pr.yml — runs on every PR
name: PR
on: { pull_request: }
jobs:
  quality:
    uses: YiWang24/OpenCI/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      codecov-token:     ${{ secrets.CODECOV_TOKEN }}
```

```yaml
# .github/workflows/ci.yml — runs on push to main
name: CI
on: { push: { branches: [main] } }
jobs:
  build:
    uses: YiWang24/OpenCI/.github/workflows/ci.yml@v2
    with:
      image-name: my-app
    secrets:
      registry-token: ${{ github.token }}
```

```yaml
# .github/workflows/stg.yml — runs after CI succeeds
name: STG
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    uses: YiWang24/OpenCI/.github/workflows/stg.yml@v2
    with:
      image-digest: ${{ github.event.workflow_run.outputs.image-digest }}
      image-name:   my-app
      app-name:     my-app
      health-url:   https://stg.example.com/health
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}
```

```yaml
# .github/workflows/prd.yml — fires from a tag or repository_dispatch
name: PRD
on:
  push: { tags: ['v*'] }
  repository_dispatch: { types: [observe-window-complete] }
jobs:
  deploy:
    uses: YiWang24/OpenCI/.github/workflows/prd.yml@v2
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

> Replace `@v2` with whichever stable major suits you. Pre-release work
> can pin a SHA from `main`; breaking changes are flagged in
> [`CHANGELOG.md`](CHANGELOG.md).

## AI-powered workflows

OpenCI ships AI-powered workflows at the top level alongside infrastructure
workflows. All call `claude-harness` under the hood with task-specific prompts.

### Available AI workflows

| Workflow | Description |
| --- | --- |
| [`pr.yml`](.github/workflows/pr.yml) | PR quality gate with optional AI review (`enable-ai-review: true`) |
| [`pr-agent-test-gen.yml`](.github/workflows/pr-agent-test-gen.yml) | Generate test scaffolds for new code |
| [`issue.yml`](.github/workflows/issue.yml) | Unified issue domain — lifecycle, slash commands, Linear bridge, scheduled Sentry triage (mode-routed) |
| [`ci.yml`](.github/workflows/ci.yml) | Build + sign + optional AI smoke eval (`enable-ai-smoke: true`) |
| [`stg-agent-test.yml`](.github/workflows/stg-agent-test.yml) | L1–L4 autonomous staging tests |
| [`pr-agent-feedback.yml`](.github/workflows/pr-agent-feedback.yml) | CI-failure summary comment on agent-opened PRs |
| [`flag-audit.yml`](.github/workflows/flag-audit.yml) | Weekly feature-flag audit and tech-debt filing |
| [`health-report.yml`](.github/workflows/health-report.yml) | Daily AI-synthesised observability digest → Issue + Slack |
| [`pr-agent-docubot.yml`](.github/workflows/pr-agent-docubot.yml) | Auto-generate docs/changelog comment on PRs |

### Usage examples

```yaml
# PR Review (AI-powered)
jobs:
  quality:
    uses: YiWang24/OpenCI/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# Issue Triage + Deduplication
jobs:
  triage:
    uses: YiWang24/OpenCI/.github/workflows/issue.yml@v2
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# Staging Agent Tests (after deploy)
jobs:
  agent-test:
    uses: YiWang24/OpenCI/.github/workflows/stg-agent-test.yml@v2
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
  - uses: YiWang24/OpenCI@v2
    with:
      task: pr/review
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Direct composite action reference

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: YiWang24/OpenCI/actions/pr/review-ai@v2
    with:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Workflow catalogue

| Workflow | Purpose |
| --- | --- |
| [`pr.yml`](.github/workflows/pr.yml) | PR quality gate (12 jobs) |
| [`ci.yml`](.github/workflows/ci.yml) | Merge-to-main build + scan + sign + AI smoke |
| [`stg.yml`](.github/workflows/stg.yml) | Staging deploy, smoke, notify, observability fan-out |
| [`prd.yml`](.github/workflows/prd.yml) | Production deploy with environment gate + auto-rollback |
| [`claude-harness.yml`](.github/workflows/claude-harness.yml) | Sole AI entry point (workflow form) |
| [`pr-summary.yml`](.github/workflows/pr-summary.yml) | Sticky PR comment aggregating run results |
| [`security-schedule.yml`](.github/workflows/security-schedule.yml) | Weekly CodeQL / Trivy / SBOM / Scorecard |
| [`health-report.yml`](.github/workflows/health-report.yml) | Daily AI-synthesised observability digest |
| [`issue.yml`](.github/workflows/issue.yml) | Unified issue domain — lifecycle (auto-label / AI triage / dedupe / assign), slash commands, Linear branch bridge, scheduled Sentry triage |
| [`community.yml`](.github/workflows/community.yml) | First-contributor welcome |
| [`stale.yml`](.github/workflows/stale.yml) | Stale-mark / close / lock |
| [`docs-build.yml`](.github/workflows/docs-build.yml) | Doc PR validation |
| [`docs-deploy.yml`](.github/workflows/docs-deploy.yml) | Pages publish on main |
| [`release-docker.yml`](.github/workflows/release-docker.yml) | Tag-driven Docker release with cosign |
| [`release.yml`](.github/workflows/release.yml) | Marketplace version tagging + floating major/minor tags |
| [`dep-auto-merge.yml`](.github/workflows/dep-auto-merge.yml) | Renovate patch PRs auto-merge |
| [`verify-sha-consistency.yml`](.github/workflows/verify-sha-consistency.yml) | Manifest enforcement |
| `pr-agent-{feedback,test-gen,docubot,review}.yml` | Opt-in AI agent enhancements |
| `prd-{canary-watch,verify-fix,terraform-drift}.yml` | Post-deploy advisory monitors |
| `flag-audit.yml` | Weekly cron flag-debt audit |
| `stg-agent-test.yml` | L1–L4 autonomous staging tests |

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
.github/workflows/      # 26 reusable workflows
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

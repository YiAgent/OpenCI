# CHANGELOG

## [1.0.0] - 2026-04-30

### Added

#### Atomic Actions
- `setup-node` — Node.js + pnpm + dependencies with `.tool-versions` support
- `setup-python` — Python + uv + dependencies
- `setup-go` — Go toolchain + dependencies
- `setup-docker` — Docker Buildx + registry login
- `build-image` — Multi-arch Docker build + push
- `deploy-ecs` — Deploy to AWS ECS
- `deploy-ec2` — Deploy to EC2 via SSH
- `deploy-lambda` — Deploy to AWS Lambda
- `deploy-vercel` — Deploy to Vercel
- `run-lint` — Lint with reviewdog annotations (ruff, eslint)
- `run-tests` — Run tests with coverage reporting
- `post-comment` — Upsert PR comment with ETag-aware deduplication
- `notify-slack` — Send Slack webhook messages
- `notify-email` — Send email via Resend API
- `notify-linear` — Create Linear issues
- `check-secrets` — Validate required/optional secrets exist
- `check-migrations` — Validate database migration files
- `check-dockerfile` — Lint Dockerfile for best practices
- `gate-publish` — Publish gate context artifact for downstream workflows
- `gate-consume` — Download + parse gate context artifact

#### Composite Middleware
- `setup-full-stack` — Chain: setup-node + setup-python + setup-redis
- `with-gate-context` — Chain: gate-consume + conditional skip

#### Reusable Workflows
- `pr-gate.yml` — Central PR preflight (detect changes, validate secrets, publish context)
- `pr-verify.yml` — Lint + type + test (triggered by gate via workflow_run)
- `pr-security.yml` — Security scanners: TruffleHog, pip-audit, npm audit, Semgrep, Dockerfile lint, license check, IaC scan
- `pr-quality.yml` — Code quality via reviewdog (ruff, eslint)
- `pr-agent-summary.yml` — Aggregate all PR signals into one rolling comment
- `stg-deploy.yml` — Staging deploy + integration tests + E2E
- `prd-release.yml` — Production deploy + smoke tests + E2E + GitHub release
- `prd-canary-watch.yml` — Canary monitoring (Sentry spike + health check, every 15 min)
- `reusable-verify.yml` — Backend + frontend verify (lint, type-check, tests)
- `reusable-build.yml` — Build artifacts (Docker image or frontend)
- `reusable-deploy.yml` — Deploy to target environment (ECS, Vercel, EC2)
- `reusable-gate-check.yml` — Thin gate consumer
- `self-test.yml` — Dogfooding: test own actions

#### Scripts
- `scripts/python/gate_consume.py` — Parse gate-context.json and emit outputs
- `scripts/python/pr_summary.py` — Build rolling PR summary comment
- `scripts/python/deploy_annotate.py` — Emit observability annotations (Sentry, Axiom, Datadog, PostHog)
- `scripts/bash/validate-secrets.sh` — Validate secrets against expected list
- `scripts/bash/wait-for-healthy.sh` — Poll health endpoint until ready

#### Project Files
- `README.md` — Usage docs with consumer examples
- `CHANGELOG.md` — This file
- `LICENSE` — MIT license
- `OWNERS` — Code ownership
- `.gitignore` — Git ignore rules

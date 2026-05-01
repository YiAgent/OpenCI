# actions

Shared CI/CD actions and reusable workflows for GitHub Actions.

## Quick Start

```yaml
# In your repo's workflow
- uses: your-name/actions/setup-node@v1
  with:
    install-deps: "true"
```

## Atomic Actions

### Environment Setup

| Action | Purpose |
|--------|---------|
| `setup-node` | Node.js + pnpm + dependencies |
| `setup-python` | Python + uv + dependencies |
| `setup-go` | Go toolchain + dependencies |
| `setup-docker` | Docker Buildx + registry login |

### Build

| Action | Purpose |
|--------|---------|
| `build-image` | Multi-arch Docker build + push |

### Deploy

| Action | Purpose |
|--------|---------|
| `deploy-ecs` | Deploy to AWS ECS |
| `deploy-ec2` | Deploy to EC2 via SSH |
| `deploy-lambda` | Deploy to AWS Lambda |
| `deploy-vercel` | Deploy to Vercel |

### Test & Lint

| Action | Purpose |
|--------|---------|
| `run-lint` | Lint with reviewdog annotations |
| `run-tests` | Run tests with coverage |

### Notifications

| Action | Purpose |
|--------|---------|
| `post-comment` | Upsert PR comment (ETag-aware) |
| `notify-slack` | Send Slack message |
| `notify-email` | Send email via Resend |
| `notify-linear` | Create Linear issue |

### Validation

| Action | Purpose |
|--------|---------|
| `check-secrets` | Validate secrets exist |
| `check-migrations` | Validate DB migrations |
| `check-dockerfile` | Lint Dockerfile |

### Gate

| Action | Purpose |
|--------|---------|
| `gate-publish` | Publish gate context artifact |
| `gate-consume` | Download + parse gate context |

## Reusable Workflows

### PR Stage

| Workflow | Purpose |
|----------|---------|
| `pr-gate.yml` | Central PR preflight (detect changes, validate secrets, publish context) |
| `pr-verify.yml` | Lint + type + test (triggered by gate) |
| `pr-security.yml` | Security scanners (triggered by gate) |
| `pr-quality.yml` | Code quality via reviewdog (triggered by gate) |
| `pr-agent-summary.yml` | Aggregate all signals into one PR comment |

### Staging

| Workflow | Purpose |
|----------|---------|
| `stg-deploy.yml` | Staging deploy + integration + E2E tests |

### Production

| Workflow | Purpose |
|----------|---------|
| `prd-release.yml` | Production deploy + smoke tests + release |
| `prd-canary-watch.yml` | Canary monitoring (every 15 min) |

### Reusable (Composable)

| Workflow | Purpose |
|----------|---------|
| `reusable-verify.yml` | Backend + frontend verify |
| `reusable-build.yml` | Build artifacts |
| `reusable-deploy.yml` | Deploy to target environment |
| `reusable-gate-check.yml` | Thin gate consumer |

### Self-Test

| Workflow | Purpose |
|----------|---------|
| `self-test.yml` | Dogfooding: test own actions |

## Consumer Examples

### Simple: PR Verification

```yaml
name: CI
on:
  pull_request:

permissions: {}

jobs:
  verify:
    uses: your-name/actions/.github/workflows/reusable-verify.yml@v1
    with:
      autofix: true
      use-real-secrets: true
      coverage-threshold: 50
    secrets: inherit
    permissions:
      contents: write
      pull-requests: read
```

### Full Lifecycle

```yaml
# PR gate
name: "PR: Gate"
on:
  pull_request:
    types: [opened, reopened, synchronize]

concurrency:
  group: pr-gate-${{ github.event.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write

jobs:
  gate:
    uses: your-name/actions/.github/workflows/pr-gate.yml@v1
    secrets: inherit

# PR verify (triggered by gate)
name: "PR: Verify"
on:
  workflow_run:
    workflows: ["PR: Gate"]
    types: [completed]

permissions: {}

jobs:
  verify:
    if: github.event.workflow_run.conclusion == 'success'
    uses: your-name/actions/.github/workflows/reusable-verify.yml@v1
    with:
      autofix: true
      use-real-secrets: true
    secrets: inherit
    permissions:
      contents: write
      pull-requests: read

# Staging deploy
name: "STG: Deploy"
on:
  push:
    branches: [main]

concurrency:
  group: deploy-stg-${{ github.ref }}
  cancel-in-progress: false

permissions: {}

jobs:
  deploy:
    uses: your-name/actions/.github/workflows/stg-deploy.yml@v1
    secrets: inherit
    permissions:
      contents: read
      packages: write
      id-token: write

# Production release
name: "PRD: Release"
on:
  push:
    tags: ['v*']

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

permissions: {}

jobs:
  release:
    uses: your-name/actions/.github/workflows/prd-release.yml@v1
    secrets: inherit
    permissions:
      contents: write
      packages: write
      id-token: write
```

### Using Atomic Actions Directly

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: your-name/actions/setup-node@v1
        with:
          install-deps: "true"
          working-directory: frontend
      - uses: your-name/actions/setup-python@v1
        with:
          install-deps: "true"
          working-directory: backend
      - uses: your-name/actions/build-image@v1
        with:
          context: .
          tags: myapp:${{ github.sha }}
      - uses: your-name/actions/deploy-ecs@v1
        with:
          service: my-service
          cluster: my-cluster
      - uses: your-name/actions/notify-slack@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK }}
          message: "Deployed ${{ github.sha }}"
```

## Security

- All third-party actions pinned by SHA with version comment
- `permissions: {}` at top level, override per-job
- Dynamic values flow through `env:` blocks (never inlined into `run:`)
- LLM agents are read-only; deterministic reporters handle writes

## Versioning

Semantic versioning with floating major tags:

```yaml
# Pin to exact version (preferred)
- uses: your-name/actions/setup-node@v1.2.0

# Pin to SHA (most secure)
- uses: your-name/actions/setup-node@a1b2c3d  # v1.2.0

# Floating major (convenient)
- uses: your-name/actions/setup-node@v1
```

## License

MIT

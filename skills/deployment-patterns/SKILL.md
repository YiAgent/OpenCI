---
name: deployment-patterns
description: >
  Review and generate deployment configurations: Docker, CI/CD, health checks, rollback strategies.
  Combines ECC deployment-patterns and docker-patterns for comprehensive deployment guidance.
  Use when creating or reviewing Dockerfiles, docker-compose, CI/CD pipelines, or deployment configs.
triggers:
  - deployment
  - docker
  - ci cd
  - deploy config
  - dockerfile
---

# Deployment Patterns

You are reviewing or generating deployment configuration for {{repo}}.

## Inputs

```json
{{context}}
```

`context` includes:
- `task` — "review" | "generate" | "optimize"
- `language` — primary language
- `framework` — web framework
- `target` — "docker" | "kubernetes" | "serverless" | "vm"
- `existing_config` — optional: current Dockerfile/docker-compose/CI config
- `requirements` — optional: specific requirements (scaling, regions, etc.)

## Dockerfile Best Practices

### Multi-stage Builds

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production && npm cache clean --force
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine AS production
WORKDIR /app
RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -s /bin/sh -D appuser
COPY --from=builder --chown=appuser:appgroup /app/dist ./dist
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
USER appuser
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/server.js"]
```

### Key Principles

- **Minimal base images**: alpine, distroless, scratch
- **Non-root user**: always run as non-root
- **Layer caching**: COPY package*.json before COPY .
- **No secrets in image**: use build args or runtime env
- **Health checks**: always include HEALTHCHECK
- **Specific versions**: never use `:latest` in production
- **.dockerignore**: exclude node_modules, .git, .env, tests

### Security Scanning

- Run Trivy/Grype in CI to scan images for CVEs
- Fail pipeline on CRITICAL/HIGH vulnerabilities
- Pin base image digests for reproducibility

## Docker Compose Patterns

### Service Configuration

```yaml
services:
  app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgresql://user:pass@db:5432/app
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
    networks:
      - backend

  db:
    image: postgres:16-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    secrets:
      - db_password
    networks:
      - backend
```

### Networking

- Use named networks for service isolation
- Only expose ports that need external access
- Use internal networks for inter-service communication

### Volumes & Data

- Named volumes for persistent data
- Bind mounts for development only
- Never mount sensitive files (use secrets)

## CI/CD Pipeline Patterns

### GitHub Actions

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
      - run: npm ci
      - run: npm test
      - run: npm run lint

  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/build-push-action@v5
        with:
          push: true
          tags: ${{ env.REGISTRY }}/${{ env.IMAGE }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: kubectl set image deployment/app app=${{ env.IMAGE }}:${{ github.sha }}
      - run: kubectl rollout status deployment/app --timeout=300s
```

### Deployment Strategies

- **Rolling update**: default, zero-downtime, gradual replacement
- **Blue-green**: two identical environments, instant switch
- **Canary**: route small % of traffic to new version, monitor, then full rollout
- **Rollback**: `kubectl rollout undo` or tag-based rollback

### Health Checks

- **Liveness**: is the process alive? (restart if fails)
- **Readiness**: is it ready to serve traffic? (remove from load balancer if fails)
- **Startup**: is it still starting up? (don't check liveness during startup)

## Output

Based on `task`:

### review
```markdown
### Issues Found
- List of problems with existing config

### Recommendations
- Prioritized improvements

### Positive Notes
- Good practices already in use
```

### generate
Provide complete, production-ready configuration files.

### optimize
```markdown
### Optimizations
- Size reduction opportunities
- Security improvements
- Performance improvements
- Cost reduction suggestions
```

## Rules

- Always include health checks
- Always use non-root users in containers
- Always pin versions (no `:latest`)
- Always scan for CVEs in CI
- Prefer multi-stage builds for smaller images
- Use secrets management, never hardcode credentials

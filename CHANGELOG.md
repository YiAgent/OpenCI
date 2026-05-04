# Changelog

> The current draft is maintained automatically by `release-drafter` on
> every PR merge to `main`. See the latest draft at
> <https://github.com/YiAgent/OpenCI/releases>.
>
> Pre-v1.7 history lives in [`docs/CHANGELOG-history.md`](docs/CHANGELOG-history.md).

## Unreleased — v3 agentic architecture (BREAKING)

**All workflows now use the `reusable-*.yml` naming convention. Event entries
are thin shims that delegate to reusable workflows. The 4-stage agentic
pipeline (Ingest → Enrich → Agent → Execute) is the standard pattern.**

### Reusable workflows (external consumers call these)

| Reusable workflow | Purpose |
| --- | --- |
| `reusable-pr.yml` | PR quality gate with AI review (4-stage) |
| `reusable-ci.yml` | Merge-to-main build + sign + scan + AI failure analyst (4-stage) |
| `reusable-issue.yml` | Issue orchestrator: lifecycle / maintenance / ingest (4-stage) |
| `reusable-agent.yml` | The Claude harness — single AI primitive |
| `reusable-stg.yml` | Staging deploy with auto-rollback |
| `reusable-prd.yml` | Production deploy with environment gate |
| `reusable-observability.yml` | Multi-provider observability → Claude incident analyst (4-stage) |
| `reusable-release.yml` | Marketplace + Docker release with cosign |
| `reusable-docs.yml` | Docs quality + sync agent (4-stage) |
| `reusable-maintenance.yml` | Security sweeps + dependency intelligence (4-stage) |
| `reusable-deps.yml` | Renovate patch PR auto-merge |
| `reusable-self-test.yml` | Workflow/action lint + security validation |

### Migration from v2

External consumers MUST update `uses:` references:

| Old (v2) | New (v3) |
| --- | --- |
| `YiAgent/OpenCI/.github/workflows/pr.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-pr.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/ci.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-ci.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/issue.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-issue.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/release.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-release.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/stg.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-stg.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/prd.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-prd.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/prd-observe.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-observability.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/security-schedule.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-maintenance.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/docs.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-docs.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/dep-auto-merge.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-deps.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/claude-harness.yml@v2` | `YiAgent/OpenCI/.github/workflows/reusable-agent.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/stg-agent-test.yml@v2` | Integrated into `deploy.yml` event entry (L1–L4 agent tests) |
| `YiAgent/OpenCI/.github/workflows/flag-audit.yml@v2` | Integrated into `on-maintenance.yml` event entry |
| `YiAgent/OpenCI/.github/workflows/health-report.yml@v2` | DROPPED — compose your own data-collection + `reusable-agent.yml` |
| `YiAgent/OpenCI/.github/workflows/community.yml@v2` | DROPPED — handled by `reusable-issue.yml` lifecycle mode |
| `YiAgent/OpenCI/.github/workflows/stale.yml@v2` | DROPPED — handled by `reusable-issue.yml` maintenance mode |
| `YiAgent/OpenCI/.github/workflows/pr-agent.yml@v2` | DROPPED — use `reusable-agent.yml` with `task: pr/review` |

**Why:** OpenCI now has two clear identities — (1) a normal project that
dogfoods its own workflows via 13 thin event-entry files, and (2) a tool
library that exposes 12 public `reusable-*.yml` workflows. The old layout
mixed events and `workflow_call` triggers in the same files.

**No deprecation grace period.** v2 paths return 404 starting v3.0.0.

### Key v3 changes

- **Agentic 4-stage pipeline** across PR, CI, Issue, Docs, Observability, Maintenance
- **15 built-in AI skills** under `skills/` with `SKILL.md` prompt files
- **Agent context system** under `.github/agent/` (shared, pr, issue, docs, observe domains)
- **Multi-provider observability** with Claude as incident analyst
- **Autonomous staging tests** (L1–L4 Playwright browser automation)
- **Docs sync agent** with drift detection and auto-PR
- **Maintenance analyst** with CVE/dependency correlation

## v1.7 (2026-04 — design)

- Implementation plan for the 33 SPEC items split across `tasks/P0..P4.md`.
- SPEC slim batches 1–3 (-1255 lines aggregate; structural prose conversion).
- Migration of EvolveCI design doc out of this repo.

For the v1.7 design rationale see [`docs/SPEC.md` §"变更日志"](docs/SPEC.md#变更日志).

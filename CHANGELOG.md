# Changelog

> The current draft is maintained automatically by `release-drafter` on
> every PR merge to `main`. See the latest draft at
> <https://github.com/YiAgent/OpenCI/releases>.
>
> Pre-v1.7 history lives in [`docs/CHANGELOG-history.md`](docs/CHANGELOG-history.md).

## Unreleased — v3 dual-identity refactor (BREAKING)

**Public reusable workflow paths moved to `reusable/` subdirectory.**
External consumers MUST update `uses:` references:

| Old (v2) | New (v3) |
| --- | --- |
| `YiAgent/OpenCI/.github/workflows/pr.yml@v2` | `YiAgent/OpenCI/.github/workflows/pr.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/ci.yml@v2` | `YiAgent/OpenCI/.github/workflows/ci.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/issue.yml@v2` | `YiAgent/OpenCI/.github/workflows/issue.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/release.yml@v2` | `YiAgent/OpenCI/.github/workflows/release.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/stg.yml@v2` | `YiAgent/OpenCI/.github/workflows/deploy.yml@v3` (with `environment: staging`) |
| `YiAgent/OpenCI/.github/workflows/prd.yml@v2` | `YiAgent/OpenCI/.github/workflows/deploy.yml@v3` (with `environment: production`) |
| `YiAgent/OpenCI/.github/workflows/prd-observe.yml@v2` | `YiAgent/OpenCI/.github/workflows/deploy.yml@v3` (with `mode: observe`) |
| `YiAgent/OpenCI/.github/workflows/stg-agent-test.yml@v2` | `YiAgent/OpenCI/.github/workflows/deploy.yml@v3` (with `mode: stg-test`) |
| `YiAgent/OpenCI/.github/workflows/security-schedule.yml@v2` | `YiAgent/OpenCI/.github/workflows/security.yml@v3` (with `mode: full`) |
| `YiAgent/OpenCI/.github/workflows/flag-audit.yml@v2` | `YiAgent/OpenCI/.github/workflows/security.yml@v3` (with `mode: flag-audit`) |
| `YiAgent/OpenCI/.github/workflows/docs.yml@v2` | `YiAgent/OpenCI/.github/workflows/docs.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/dep-auto-merge.yml@v2` | `YiAgent/OpenCI/.github/workflows/deps.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/claude-harness.yml@v2` | `YiAgent/OpenCI/.github/workflows/agent.yml@v3` |
| `YiAgent/OpenCI/.github/workflows/health-report.yml@v2` | DROPPED — write your own data-collect job + call `agent.yml` with `task: health-digest`, `prompt-path: .openci/skills/observability/daily-health-report/SKILL.md` (see EvolveCI's `agent-daily.yml` for canonical pattern) |
| `YiAgent/OpenCI/.github/workflows/community.yml@v2` | `YiAgent/OpenCI/.github/workflows/issue.yml@v3` (with `mode: welcome`) |
| `YiAgent/OpenCI/.github/workflows/stale.yml@v2` | `YiAgent/OpenCI/.github/workflows/issue.yml@v3` (with `mode: stale`) |
| `YiAgent/OpenCI/.github/workflows/pr-agent.yml@v2` | DROPPED — write your own thin event-driven workflow that calls `agent.yml` with the right `task` + `prompt-path` (e.g. `.openci/skills/pr-review/SKILL.md`); see EvolveCI's pattern |
| `YiAgent/OpenCI/.github/workflows/verify-sha-consistency.yml@v2` | `YiAgent/OpenCI/.github/workflows/security.yml@v3` (with `mode: verify-sha`) — also a job inside `reusable/ci.yml` |

**Why:** OpenCI now has two clear identities — (1) a normal project that
dogfoods its own workflows via 9 thin `on-*.yml` event entries at the
top level, and (2) a tool library that exposes 9 public reusable
workflows under `reusable/` for external consumption. The old layout
mixed events and `workflow_call` triggers in the same files.

**No deprecation grace period.** v2 paths return 404 starting v3.0.0.

## v1.7 (2026-04 — design)

- Implementation plan for the 33 SPEC items split across `tasks/P0..P4.md`.
- SPEC slim batches 1–3 (-1255 lines aggregate; structural prose conversion).
- Migration of EvolveCI design doc out of this repo.

For the v1.7 design rationale see [`docs/SPEC.md` §"变更日志"](docs/SPEC.md#变更日志).

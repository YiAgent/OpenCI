---
name: docs-sync-agent
description: Analyse code-doc drift and produce a structured update plan for the Stage 4 executor.
---

# docs/sync-agent

## Purpose

Analyse detected drift between code and documentation, then produce a
`docs-action-plan/v1` JSON object that Stage 4 can execute without further
human input.

## Input Workspace

Read ALL of these files before producing output:

| File | Content |
|------|---------|
| `docs-workspace/context.md` | Behavior rules, style guide, CHANGELOG format |
| `docs-workspace/detect.json` | Drift signals: which checks fired and what changed |
| `docs-workspace/code-changes.txt` | Content of recently changed source files (≤ 30 KB) |
| `docs-workspace/pr-diff.patch` | Unified diff of the triggering PR (PR mode only) |
| `docs-workspace/pr-files.json` | Code vs. doc file breakdown from the PR (PR mode only) |

## Output Contract

Return exactly ONE JSON object. Schema version: `docs-action-plan/v1`.
No surrounding prose. No markdown fences.

```json
{
  "version": "docs-action-plan/v1",
  "summary": "Short description of what needs updating and why (1-2 sentences)",
  "updates": [
    {
      "id": "u1",
      "type": "modify",
      "file": "docs/api/authentication.md",
      "section": "## Token Refresh",
      "reason": "New refresh_token parameter added in src/auth/token.ts",
      "content": "## Token Refresh\n\n...",
      "confidence": "high"
    },
    {
      "id": "u2",
      "type": "create",
      "file": "docs/api/webhooks.md",
      "reason": "Webhook feature added but has no documentation",
      "content": "# Webhooks\n\n...",
      "confidence": "high"
    }
  ],
  "skipped": [
    {
      "file": "src/internal/cache.ts",
      "reason": "Internal implementation change; does not affect public API"
    }
  ],
  "skip_reason": null
}
```

Set `skip_reason` to a non-null string (e.g. `"no_actionable_changes"`) and
return empty `updates` when no documentation changes are warranted.

## Analysis Approach

### 1. Read context.md first
Understand the project's documentation style, directory structure, and
CHANGELOG format before evaluating what needs to change.

### 2. Assess detect.json signals

| Signal | What to look for |
|--------|-----------------|
| `drift_detected: true` | Code files changed; check for new exports, changed function signatures, new configuration keys, behavior changes |
| `api_stale: true` | OpenAPI spec outdated; update endpoint descriptions, request/response schemas |
| `changelog_stale: true` | Unrecorded PRs in `unrecorded_prs`; generate CHANGELOG entries grouped by type |

### 3. Read code-changes.txt selectively
Focus on public API surfaces, not internal implementation details:
- Exported functions / classes / types
- CLI arguments or environment variables
- Configuration file schemas
- HTTP endpoints

### 4. Classify changes

| Change type | Needs doc update? |
|-------------|-------------------|
| New exported function or method | Yes — add to API reference |
| Changed function signature | Yes — update parameter docs |
| New config key | Yes — update configuration guide |
| Behavior change | Yes — update relevant guide |
| Internal refactor | No |
| Test additions | No |
| Dependency bump (non-breaking) | No |

### 5. Generate content
- Match the documentation style from `context.md`
- Use code examples in the project's primary language
- CHANGELOG entries must follow Keep a Changelog format (see context.md)
- `type: "modify"` — include the full updated section content
- `type: "create"` — include the full new file content

### 6. Confidence scoring
Only output `"confidence": "high"` when:
- The change is clearly visible in `code-changes.txt` or `pr-diff.patch`
- The required update is unambiguous (e.g. new exported symbol with no docs)
- You have enough context to write accurate content

Use `skipped` for everything else. Stage 4 only applies `high` confidence updates.

## CHANGELOG Generation Rules

When `changelog_stale: true`:
1. Read `unrecorded_prs` from `detect.json`
2. Classify each PR by label: `feat` → Added, `fix` → Fixed, `breaking` → Changed, else → Changed
3. Insert a new `## [Unreleased]` section (or append to an existing one) at the
   top of CHANGELOG.md, above any existing versioned releases
4. Format: `- PR title (#number)` under the appropriate subsection

Example:
```markdown
## [Unreleased]

### Added
- Support webhook event filtering (#42)

### Fixed
- Token refresh race condition (#41)
```

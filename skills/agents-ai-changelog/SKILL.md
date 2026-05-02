---
name: agents-ai-changelog
description: >
  Generate release notes in Keep a Changelog style from commit history.
  Enhanced with Conventional Commits parsing, breaking change detection,
  and structured changelog generation from ECC and alirezarezvani.
triggers:
  - changelog
  - release notes
  - ai changelog
---

# AI Changelog

You are writing release notes in Keep a Changelog style for `{{version}}`.

## Inputs

```json
{{context}}
```

`context` includes:
- `version` — tag being released (e.g. `v1.8.0`)
- `previous_tag` — last tag, may be empty for the first release
- `commits` — TAB-separated `sha\tsubject\tauthor`, oldest-last
- `prs` — optional: merged PRs with `{number, title, labels, body}`

## Parsing Rules

### Conventional Commits Mapping

| Prefix | Section | Notes |
|--------|---------|-------|
| `feat:` | Added | New features |
| `fix:` | Fixed | Bug fixes |
| `refactor:` | Changed | Code restructuring |
| `perf:` | Changed | Performance improvements |
| `docs:` | — | Skip unless consumer-facing |
| `test:` | — | Skip unless new test framework |
| `chore:` | — | Skip |
| `ci:` | — | Skip unless new workflow |
| `style:` | — | Skip |
| `build:` | Changed | Build system changes |
| `revert:` | Fixed | Reverted changes |
| `security` keyword | Security | Any commit mentioning security |

### Breaking Changes

Scan for:
- `BREAKING CHANGE:` in commit body
- `feat!:` or `fix!:` prefix (exclamation mark)
- PR labels: `breaking-change`, `major`
- These go in a **Breaking** section at the top

### Consumer-Facing Filtering

Skip unless consumer-facing:
- Internal refactors (no API change)
- Test additions/changes
- CI/CD configuration
- Documentation-only changes (unless they fix incorrect docs)
- Dependency bumps (unless they change behavior)

### PR Enrichment

If `prs` provided:
- Link to PR: `(#123)` at end of bullet
- Use PR body for detail if commit message is vague
- Group related PRs (e.g., multiple commits for one feature)

## Output (markdown only, no preamble)

```
## Breaking Changes

(if any — put this section first)

## Added

- ...

## Changed

- ...

## Fixed

- ...

## Security

(only if relevant)

## Removed / Deprecated

(only if relevant)
```

## Rules

- One bullet per commit/PR, lead with the verb.
- Format: `- <description>. (#<PR>)` when PR number available.
- Group related commits under a single bullet when they're part of the same feature.
- Maximum 30 bullets total. If more, group aggressively.
- Drop sections without entries.
- No "Updated dependencies" unless it changes behavior.
- No commit SHA references — use PR numbers or human-readable descriptions.

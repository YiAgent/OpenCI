# Documentation Structure

## Standard Layout

```
docs/
├── README.md           ← docs landing page / index
├── getting-started.md  ← installation, quickstart
├── configuration.md    ← all config keys with types and defaults
├── api/
│   ├── README.md       ← API overview
│   └── *.md            ← one file per major resource or module
├── guides/
│   └── *.md            ← task-oriented how-to guides
└── changelog/
    └── *.md            ← optional versioned changelogs
CHANGELOG.md            ← root-level Keep a Changelog file
README.md               ← root-level project README
```

## File Placement Rules

- New API surface → `docs/api/<module>.md` (create if absent)
- New configuration key → `docs/configuration.md` (modify existing)
- New guide or tutorial → `docs/guides/<topic>.md` (create if absent)
- Version release notes → `CHANGELOG.md` `## [Unreleased]` section

## Heading Conventions

- H1 (`#`) — document title, one per file
- H2 (`##`) — major sections (Overview, Parameters, Examples, Notes)
- H3 (`###`) — subsections within a major section
- H4+ — avoid; flatten if possible

## Code Block Languages

Use the project's actual language tag. Common examples:

```
```typescript
```javascript
```python
```go
```bash
```yaml
```json
```

Never use generic ` ```code ` or ` ```text ` for runnable examples.

## Link Style

- Relative links for internal docs: `[Configuration](../configuration.md)`
- Absolute URLs only for external resources
- Prefer named anchors over bare fragment links: `[Token Refresh](#token-refresh)`

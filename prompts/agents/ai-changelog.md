# AI changelog

You are writing release notes in Keep a Changelog style for `{{version}}`.

## Inputs

```json
{{context}}
```

`context` includes:
- `version` — tag being released (e.g. `v1.8.0`)
- `previous_tag` — last tag, may be empty for the first release
- `commits` — TAB-separated `sha\tsubject\tauthor`, oldest-last

## Output (markdown only, no preamble)

```
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

Rules:
- Group by Conventional Commits type (`feat` → Added, `fix` → Fixed,
  `refactor`/`perf` → Changed, `security` keyword → Security, etc.).
- One bullet per commit, lead with the verb. Reference PR numbers when
  in commit subjects (`feat: foo (#42)` → `- Foo. (#42)`).
- Skip `chore` / `docs` / `test` / `ci` unless they're consumer-facing.
- Drop sections without entries.

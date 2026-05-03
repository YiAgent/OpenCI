# CHANGELOG Format

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Structure

```markdown
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- New feature description (#PR_NUMBER)

### Changed
- Breaking or behavioral change (#PR_NUMBER)

### Fixed
- Bug fix description (#PR_NUMBER)

### Removed
- Removed feature (#PR_NUMBER)

## [1.2.0] - YYYY-MM-DD

### Added
- ...
```

## Subsection Mapping

| PR label(s) | CHANGELOG subsection |
|-------------|---------------------|
| `feat`, `feature`, `enhancement` | `### Added` |
| `fix`, `bugfix`, `bug` | `### Fixed` |
| `breaking`, `breaking-change` | `### Changed` |
| `remove`, `deprecated` | `### Removed` |
| `refactor`, `perf`, `chore`, `ci`, `docs` | `### Changed` (only if user-visible) |
| unlabeled | `### Changed` |

## Insertion Rules

1. Find or create the `## [Unreleased]` section at the top of the file,
   immediately after the file header (before the first versioned release).
2. Append new entries under the appropriate subsection (`### Added`, etc.).
3. Preserve all existing entries; never delete or reorder released versions.
4. Use the PR title as the entry text, appended with `(#NUMBER)`.
5. Keep entries to one line; no multi-line bullets.

## Example Entry

```markdown
- Add webhook event filtering support (#42)
```

Do NOT include:
- Implementation details
- Commit hashes
- Author attributions (these belong in git history)

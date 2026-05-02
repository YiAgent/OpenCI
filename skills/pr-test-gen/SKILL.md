---
name: pr-test-gen
description: >
  Generate test cases for newly added functions and classes in a PR diff.
  Use when auto-generating tests for uncovered code.
triggers:
  - test generation
  - generate tests
  - test gen
---

# Test generation

You are reading a PR diff. For each newly-added function or class
without test coverage, generate a single test that exercises the
golden path **and** at least one failure mode.

## Inputs

```json
{{context}}
```

`context` includes:
- `language` — node | python | go | java | kotlin
- `diff` — unified diff
- `existing_test_files` — paths the consumer suggests for output

## Output

Return a single JSON object:

```json
{
  "files": [
    { "path": "tests/foo.test.ts", "content": "<test source>" }
  ],
  "notes": "<one paragraph: what you covered, what you skipped, what's
            still risky>"
}
```

Rules:
- Mark generated test files with a leading `// [generated]` comment
  (or `# [generated]` in Python).
- Use the framework already present (vitest / jest / pytest / go test /
  junit) — do not introduce new deps.
- Skip flaky areas (timing / network / file I/O without setup).

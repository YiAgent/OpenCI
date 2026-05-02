---
name: pr-test-gen
description: >
  Generate test cases for newly added functions and classes in a PR diff.
  Enhanced with TDD RED-GREEN-REFACTOR workflow, property-based testing,
  and E2E testing patterns from ECC and Trail of Bits.
triggers:
  - test generation
  - generate tests
  - test gen
---

# Test Generation

You are reading a PR diff. For each newly-added function or class
without test coverage, generate comprehensive tests following the
RED-GREEN-REFACTOR methodology.

## Inputs

```json
{{context}}
```

`context` includes:
- `language` — node | python | go | java | kotlin
- `diff` — unified diff
- `existing_test_files` — paths the consumer suggests for output
- `test_framework` — optional: vitest | jest | pytest | go test | junit

## Test Strategy (apply in order)

### 1. Unit Tests (golden path + failure modes)

For each new function/method:
- **Happy path**: correct input → expected output
- **Boundary values**: empty, null, zero, max-length, min/max int
- **Error cases**: invalid input, missing required fields, type mismatches
- **Idempotency**: calling twice produces same result (if applicable)

### 2. Property-Based Tests (for pure functions)

When the function involves serialization, parsing, normalization, or
data transformation, generate property-based tests:
- **Roundtrip**: `deserialize(serialize(x)) ≈ x`
- **Idempotency**: `f(f(x)) === f(x)` for normalizers
- **Monotonicity**: `f(a) <= f(b)` when `a <= b` (for comparators)
- **Invariant preservation**: output always satisfies constraint X

Use the framework's property testing library if available (fast-check,
hypothesis, rapid, jqwik). If not available, write manual boundary tests.

### 3. Integration Tests (for API/DB handlers)

For functions that touch external systems:
- Mock the external dependency, assert correct calls
- Test error handling when dependency fails
- Test timeout/retry behavior if present

### 4. E2E Smoke (for critical user flows)

If the PR introduces a new endpoint or page:
- Generate a Playwright/selenium test that exercises the happy path
- Use Page Object Model pattern for selectors
- Include `data-testid` attributes in suggestions if missing

## Output

Return a single JSON object:

```json
{
  "files": [
    { "path": "tests/foo.test.ts", "content": "<test source>" }
  ],
  "coverage_notes": "<what's covered, what's skipped, what's still risky>",
  "property_tests": ["<list of properties tested>"],
  "missing_test_ids": ["<components needing data-testid>"]
}
```

## Rules

- Mark generated test files with `// [generated]` (or `# [generated]` in Python).
- Use the framework already present — do not introduce new deps.
- Follow the AAA pattern: Arrange, Act, Assert.
- Each test tests ONE thing. No mega-tests with 10 assertions.
- Test names describe behavior: `returns empty array when no items match`.
- Skip flaky areas (timing, network, file I/O without setup).
- Minimum 80% branch coverage target for new code.

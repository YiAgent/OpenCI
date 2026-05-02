---
name: stg-agent-test
description: >
  Run L1-L4 autonomous tests against a staging deployment.
  Enhanced with Playwright browser automation, visual regression,
  accessibility testing, and Page Object Model patterns from ECC.
triggers:
  - staging test
  - stg test
  - agent test
---

# Staging Autonomous Test

You are running L1-L4 autonomous tests against a staging deploy.

## Inputs

```json
{{context}}
```

`context` includes:
- `health_url` — staging health endpoint
- `level` — 1 (schema fuzz) | 2 (property test) | 3 (scenario) | 4 (browser)
- `image_digest` — the just-deployed image
- `base_url` — staging base URL for browser tests
- `routes` — optional: specific routes to test (default: auto-discover)

## Test Levels

### L1: Schema Fuzz

Validate API contract stability:
- For each endpoint: send requests with valid/invalid types, missing fields, extra fields
- Assert response schema matches OpenAPI/JSON Schema spec
- Check for 5xx on malformed input (should be 4xx)
- Verify error response format is consistent

### L2: Property Tests

Validate business logic invariants:
- List → Create → Read → Delete lifecycle
- Pagination: page 1 and page 2 have no overlap
- Filtering: filtered results ⊆ unfiltered results
- Sorting: verify order is correct for numeric/date fields
- Idempotency: same PUT twice → same response

### L3: Scenario Tests

Validate critical user flows end-to-end:
- Registration → Login → Profile update → Logout
- Create resource → Share → View as recipient
- Search → Filter → Sort → Paginate
- Error recovery: invalid input → fix → success

### L4: Browser Tests (Playwright)

Run visual and functional browser tests:

**Setup:**
- Auto-detect dev server (check common ports 3000, 5173, 8080)
- Use Page Object Model: one class per page/route
- Store selectors as constants, never inline strings

**Smoke Suite (always run):**
- Each route loads without console errors
- Key interactive elements are visible and clickable
- Navigation between primary routes works

**Interaction Suite:**
- Form submissions: valid data → success, invalid → error messages
- Modal/dialog open/close cycles
- Dropdown, tab, accordion interactions
- Keyboard navigation (Tab, Enter, Escape)

**Visual Regression:**
- Screenshot each route at desktop (1280x720) and mobile (375x812)
- Compare against baseline (if provided) or flag for manual review
- Check for layout shifts, overflow, overlapping elements

**Accessibility:**
- Run axe-core on each page
- Check: color contrast, ARIA labels, keyboard focus order
- Flag any `[role]` without accessible name

## Output

Strict JSON:

```json
{
  "level": <int>,
  "passed": true | false,
  "findings": [
    {
      "severity": "low" | "medium" | "high" | "critical",
      "category": "schema" | "property" | "scenario" | "visual" | "a11y" | "functional",
      "title": "...",
      "evidence": "...",
      "screenshot": "<path if L4>"
    }
  ],
  "coverage": {
    "routes_tested": <int>,
    "routes_total": <int>,
    "endpoints_tested": <int>
  },
  "summary": "<one sentence>"
}
```

## Rules

- L4 browser tests: wait for network idle before assertions
- Use `data-testid` attributes for selectors; fall back to ARIA roles
- Screenshot on failure always (full page)
- Timeout: 30s per test, 5min per suite
- No prose outside the JSON

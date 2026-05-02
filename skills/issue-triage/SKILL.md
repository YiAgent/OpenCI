---
name: issue-triage
description: >
  Classify and prioritize newly opened issues with labels, priority, and next actions.
  Enhanced with blueprint-style complexity estimation, decomposition suggestions,
  and multi-session construction planning from ECC.
triggers:
  - triage
  - issue triage
  - classify issue
---

# Issue Triage

You are triaging a newly opened issue in {{repo}}.

## Inputs

```json
{{context}}
```

`context` includes:
- `title` — issue title
- `body` — issue description
- `labels` — existing labels on the issue
- `author` — who opened it
- `similar_issues` — optional: previously triaged similar issues

## Triage Process

### 1. Classification

Determine issue type:
- **bug** — something is broken, regression, incorrect behavior
- **feature** — new functionality, enhancement request
- **question** — how-to, clarification, usage question
- **docs** — documentation gap, typo, missing guide
- **infra** — CI/CD, deployment, tooling, dependency issues
- **security** — vulnerability, auth issue, data exposure risk

### 2. Priority Assessment

- **p0** — production outage, data loss, security breach → immediate action
- **p1** — blocking many users, major feature broken → within 24h
- **p2** — normal bug/feature, single user or workaround exists → next sprint
- **p3** — nice-to-have, cosmetic, edge case → backlog

### 3. Complexity Estimation

Estimate effort:
- **S** — < 4 hours, single file change, well-understood
- **M** — 1-3 days, multiple files, some investigation needed
- **L** — 3-7 days, cross-cutting, design decisions required
- **XL** — > 1 week, architectural changes, needs planning

### 4. Decomposition Check

For L/XL issues, suggest whether to decompose:
- Can it be split into independent sub-issues?
- What's the minimum viable first step?
- Are there prerequisites or blockers?

### 5. Duplicate Detection

- Match against existing issues by title similarity, error messages, stack traces
- Only flag as duplicate if confident (>80% similarity)

## Output format

Return JSON with these fields (and nothing else):

```json
{
  "labels": ["bug" | "feature" | "question" | "docs" | "infra" | "security"],
  "priority": "p0" | "p1" | "p2" | "p3",
  "complexity": "S" | "M" | "L" | "XL",
  "summary": "<= 1 sentence",
  "next-action": "<one short imperative sentence; what should the maintainer do next?>",
  "duplicate-of": "<issue number, or null>",
  "decompose": true | false,
  "suggested_sub_issues": ["<brief titles, only if decompose=true>"]
}
```

## Rules

- `labels` is an array; pick the smallest correct set
- Use `duplicate-of` only if you are confident; otherwise null
- `decompose` is true only for L/XL issues that can be meaningfully split
- Do not include any text before or after the JSON

# pr/review-agent

## Purpose

Analyze a pull request and produce a structured action plan for the Stage 4 executor.

## Input Workspace

Read ALL of these files before producing output:

| File | Content |
|------|---------|
| `agent-workspace/gate-results.json` | Stage 1 check outcomes: lint/test/coverage/secrets/size |
| `agent-workspace/pr-meta.json` | PR metadata: number, title, author, base/head, linked issues |
| `agent-workspace/diff.patch` | Unified diff, capped at ~40 KB |
| `agent-workspace/files-changed.json` | Full file list with additions/deletions/change type |
| `agent-workspace/reviews.json` | Existing reviews and PR comments |
| `agent-workspace/context.md` | Behavior rules (merged shared + pr-specific AGENTS.md) |
| `agent-workspace/skills/*.md` | Available action skill definitions |

## Output Contract

Return exactly ONE JSON object. Schema version: `pr-action-plan/v1`.
No surrounding prose. No markdown fences.

```json
{
  "version": "pr-action-plan/v1",
  "summary": "3-5 sentences describing what changed and why",
  "risk": "low|medium|high",
  "risk_reason": "one sentence",
  "reviewer_focus": ["at most 3 specific items"],
  "actions": [
    {
      "id": "a1",
      "skill": "add_label",
      "params": { "labels": ["needs-security-review"] },
      "reason": "modifies auth logic",
      "confidence": "high|medium|low"
    }
  ],
  "skip_reason": null
}
```

## Analysis Approach

1. Read `gate-results.json` first — this tells you what Stage 1 already found.
2. Read `context.md` for decision rules specific to this repo.
3. Review `diff.patch` and `files-changed.json` for behavioral risk.
4. Check `reviews.json` — do not repeat concerns already raised by human reviewers.
5. Select actions from `skills/*.md`. Only recommend skills in that list.

## Language-Aware Analysis

The diff may span any language stack. Treat Gate results as authoritative:
- `lint_passed` came from MegaLinter running the appropriate language flavor
- `test_passed` came from language-specific test runners (pytest/go test/gradle/jest)
- `coverage` was computed by the test runner and Codecov

Do not re-analyze syntax or run your own lint mentally. Focus on:
- Behavioral risk: what could go wrong at runtime?
- Security: auth, secrets, input validation, SQL, XSS
- Reviewer guidance: what should a human specifically look at?

---
name: issue-orchestrate
description: Plan guarded GitHub issue lifecycle actions from an enriched OpenCI agent workspace.
---

# Issue Orchestrate

You are operating as the OpenCI issue agent.

Read the prepared issue-agent workspace before deciding:

- shared context: `.github/agent/shared/context/AGENTS.md` or `agent-workspace/context/shared/AGENTS.md`
- issue context: `.github/agent/issue/context/AGENTS.md` or `agent-workspace/context/issue/AGENTS.md`
- skills under `agent-workspace/skills/`
- runtime JSON under `agent-workspace/runtime/`
- merged context at `agent-workspace/agent-context.json`

## Output Format (CRITICAL)

Return **ONLY** a single JSON object. No markdown fences, no prose, no
explanation outside the JSON. The parser expects a bare JSON object as the
entire response.

```json
{
  "version": "issue-action-plan/v1",
  "reasoning": "short audit explanation",
  "actions": [
    {"id": "add-label-bug", "skill": "add_label", "params": {"labels": ["bug"]}, "risk": "low"}
  ],
  "skip_reason": null
}
```

Available skills (14): `add_label`, `remove_label`, `set_priority`,
`assign_issue`, `add_comment`, `close_issue`, `reopen_issue`,
`mark_duplicate`, `create_branch`, `link_linear`, `dispatch_mcp_task`,
`schedule_followup`, `notify`, `escalate`.

Each action object requires: `id` (string), `skill` (one of the 14 above),
`params` (object), `risk` ("low" or "high").

High-risk skills (`close_issue`, `reopen_issue`, `create_branch`,
`dispatch_mcp_task`) require trusted actor association and will be
silently skipped for untrusted contributors.

If the safe action is unclear, return an `escalate` action with
`needs-human` label or an empty plan with `skip_reason`.


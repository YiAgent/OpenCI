# dispatch_mcp_task

Dispatch an allowed downstream MCP-backed task.

Allowed params:

```json
{
  "task": "issue-to-plan",
  "event_type": "openci-mcp-task",
  "payload": {}
}
```

Execution contract:

- The task name must be present in `agent-workspace/runtime/mcp-tasks.json`.
- The executor dispatches a `repository_dispatch` event with the task payload.
- Use this only for accepted downstream task types, not for arbitrary commands.

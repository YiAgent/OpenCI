# notify

Request an external notification through the guarded executor.

Allowed params:

```json
{
  "channel": "maintainers",
  "body": "short message"
}
```

The executor may ignore this skill when no notification integration is
configured.

Execution contract:

- The executor sends a JSON webhook payload to the configured Slack-compatible
  webhook URL.
- If no webhook is configured, the executor records a skip in the audit comment.

# schedule_followup

Schedule a deterministic follow-up for an issue.

Allowed params:

```json
{
  "due_at": "2026-05-10T14:00:00Z",
  "days": 7,
  "reason": "Check whether the reporter provided reproduction steps.",
  "task": "issue-followup"
}
```

Execution contract:

- Use either `due_at` or `days`.
- `days` must be between 1 and 90.
- The executor writes a machine-readable issue marker and adds
  `followup:scheduled`.
- The maintenance job scans scheduled follow-ups and comments when they are due.

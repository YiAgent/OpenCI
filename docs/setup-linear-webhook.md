# Setup: Linear webhook → GitHub branch automation

This wires Linear's "issue → In Progress" event into OpenCI's unified
`issue.yml` workflow. The event enters `mode: ingest`, is enriched with
issue-agent context, and the issue agent can return a guarded
`create_branch` / `link_linear` action plan. The executor creates the
branch and posts back to Linear only when the plan passes policy.

> Linear's webhook can't talk to GitHub Actions directly. You need a
> small bridge function (Cloudflare Worker / AWS Lambda / similar). A
> reference implementation lives at `examples/linear-webhook-bridge/`.

## 1. Deploy the bridge

```bash
cd examples/linear-webhook-bridge
# Cloudflare Worker example:
wrangler deploy
```

Set these vars on the worker:

| Var | Source |
| --- | --- |
| `LINEAR_WEBHOOK_SIGNING_SECRET` | Linear → Settings → API → Webhooks → "Signing secret" |
| `GITHUB_TOKEN` | Fine-grained PAT scoped to your repo with **Contents: read & write** + **Actions: read** |
| `GITHUB_OWNER` | e.g. `acme` |
| `GITHUB_REPO`  | e.g. `widgets` |

## 2. Register Linear webhook

Linear → Settings → API → Webhooks → New:

- **URL**: `https://<your-worker>.workers.dev`
- **Events**: `Issue`
- **Trigger**: `Updated`
- **Filter**: `state name equals "In Progress"` (optional; the worker also filters)

## 3. Add `LINEAR_TOKEN` to GitHub repo secrets

Used by the guarded executor when the agent returns a `link_linear` action:

```
gh secret set LINEAR_TOKEN --body "lin_api_..."
```

If you skip this step, Linear comment-back is skipped.

If you call `issue.yml` directly, map the repository secret into the reusable
workflow secret:

```yaml
secrets:
  linear-token: ${{ secrets.LINEAR_TOKEN }}
```

## 4. Test it

In Linear, move any test issue to `In Progress`. Within ~30 seconds
your repo should show an `issue` workflow run triggered by
`repository_dispatch / linear-issue-started`. Branch creation depends on
the agent plan and executor policy.

If nothing happens:

1. Check the worker logs (`wrangler tail`) — signature mismatch is the
   most common failure (different secret in worker env vs Linear).
2. Check GitHub repo Actions tab → look for an `issue` workflow run
   triggered by `repository_dispatch / linear-issue-started`.
3. Verify the GitHub PAT has the **Contents: write** scope.

## Branch naming

When the agent chooses `create_branch`, branches should be derived from
issue labels:

| Linear label includes | Prefix |
| --- | --- |
| `bug` | `fix/` |
| `feature` or `enhancement` | `feat/` |
| (anything else) | `chore/` |

Slug = lowercased title with non-alphanumeric chars collapsed to `-`.
Capped at ~50 chars to keep branch names sane.

## Idempotency

If you toggle a Linear issue's state in/out of `In Progress`, the
worker fires multiple times. The executor checks if the branch already
exists and records a skipped action instead of creating a duplicate.

# Setup: Linear webhook → GitHub branch automation

This wires Linear's "issue → In Progress" event to the `linear-branch`
job inside OpenCI's unified `issue.yml` workflow, which creates a feature
branch named after the Linear issue and posts the branch URL back to
Linear. (Routed by `repository_dispatch.action == 'linear-issue-started'`
or by calling `issue.yml` with `mode: linear-branch`.)

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

Used by `actions/integrations/linear-comment` to post back to Linear:

```
gh secret set LINEAR_TOKEN --body "lin_api_..."
```

If you skip this step, the workflow still creates the branch — it just
doesn't comment back on the Linear issue.

## 4. Test it

In Linear, move any test issue to `In Progress`. Within ~30 seconds
your repo should show a new branch like `feat/aic-123-add-login` and
the Linear issue should get a "Branch created: …" comment.

If nothing happens:

1. Check the worker logs (`wrangler tail`) — signature mismatch is the
   most common failure (different secret in worker env vs Linear).
2. Check GitHub repo Actions tab → look for an `issue` workflow run
   triggered by `repository_dispatch / linear-issue-started`.
3. Verify the GitHub PAT has the **Contents: write** scope.

## Branch naming

Branches are derived from issue labels:

| Linear label includes | Prefix |
| --- | --- |
| `bug` | `fix/` |
| `feature` or `enhancement` | `feat/` |
| (anything else) | `chore/` |

Slug = lowercased title with non-alphanumeric chars collapsed to `-`.
Capped at ~50 chars to keep branch names sane.

## Idempotency

If you toggle a Linear issue's state in/out of `In Progress`, the
worker fires multiple times. The action checks if the branch already
exists and emits `Branch already exists: …` instead of creating a
duplicate.

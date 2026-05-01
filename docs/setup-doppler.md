# Setup: Doppler integration

[Doppler](https://www.doppler.com) is one of several secret managers
OpenCI's `Source` column references in `ENV_MATRIX.md`. The `load-doppler`
atom is a thin wrapper that loads secrets from a Doppler config into the
GitHub Actions environment, gated on the consumer providing
`DOPPLER_TOKEN`.

> Doppler is **opt-in**. Skip this whole document if you keep secrets in
> GitHub-secrets / AWS Secrets Manager / Vault.

## Why

GitHub Secrets is fine for a handful of variables. Past that you start
copy-pasting values across stg/prd, or leaking secrets into Workflow
runs by listing them in `env:` blocks. A secret manager:

- centralises rotation
- gives per-environment scopes
- audits which CI run pulled which secret

## Install

In the consumer repo:

```bash
# 1. Install Doppler CLI on dev machines (CI installs automatically)
brew install dopplerhq/cli/doppler

# 2. One-time auth + config
doppler login
doppler setup --project <your-project> --config stg
```

Push the resulting `doppler.yaml` to the repo (it doesn't contain secrets).

## CI wiring

Create a single `DOPPLER_TOKEN` GitHub secret per environment (use the
"service token" type for CI). Then in your stg / prd workflow:

```yaml
- uses: YiWang24/OpenCI/actions/_common/load-doppler@<sha>
  with:
    config: stg                       # which Doppler config to pull
  env:
    DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN_STG }}
```

The atom calls `doppler secrets download --no-file --format docker` and
appends the result to `$GITHUB_ENV`, so subsequent steps read variables
as if they were declared in `env:`.

## Graceful skip

If `DOPPLER_TOKEN` is unset the atom emits
`::notice title=Doppler Skipped` and exits 0. This means consumers can
add the wiring before they're ready to use Doppler, and flip on later
with no workflow changes.

## Pairing with validate-env

`actions/_common/validate-env` runs **after** `load-doppler` so the
matrix check sees the secrets that were just loaded:

```yaml
- uses: YiWang24/OpenCI/actions/_common/load-doppler@<sha>
  with: { config: stg }
  env: { DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN_STG }} }

- uses: YiWang24/OpenCI/actions/_common/validate-env@<sha>
  with: { target-env: stg }
```

If a variable is required in stg per `infra/ENV_MATRIX.md` but absent
from the Doppler config, validate-env stops the workflow with
`::error title=Missing Env Var::<NAME>` before the deploy hits k8s.

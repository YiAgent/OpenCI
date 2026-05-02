# Environment Variable Matrix (template)

> Copy this file to `infra/ENV_MATRIX.md` in your **consumer** repository.
> The actions/_common/validate-env atom (P2-20) parses it on every deploy
> and blocks runs where required variables are missing.

## Format

```
| Var Name | Required In | Source | Description |
| -------- | ----------- | ------ | ----------- |
| <name>   | dev,stg,prd | doppler | <one-line description> |
```

- `Required In` is a **comma-separated** list of environments. Spaces are tolerated.
- `Source` values: `doppler` | `github-secrets` | `aws-secrets-manager` | `vault` | `inline` (last resort, never for secrets).
- Extra columns past the first three are ignored, so you can add owner / link columns freely.

## Example

| Var Name | Required In | Source | Description |
| -------- | ----------- | ------ | ----------- |
| DATABASE_URL          | dev,stg,prd | doppler         | Postgres connection string |
| REDIS_URL             | stg,prd     | doppler         | Cache + queue backend |
| ANTHROPIC_API_KEY     | dev,stg,prd | doppler         | LLM provider; required by AI atoms |
| SENTRY_TOKEN          | stg,prd     | github-secrets  | Sentry release / error-rate gate |
| DATADOG_API_KEY       | prd         | github-secrets  | APM ingest |
| KUBECONFIG_STG        | stg         | github-secrets  | base64 kubeconfig (staging cluster) |
| KUBECONFIG_PRD        | prd         | github-secrets  | base64 kubeconfig (production cluster) |
| FEATURE_FLAG_PROVIDER | dev,stg,prd | inline          | "growthbook" or "launchdarkly" |

## Notes

- Anything in `Source: inline` lives in the workflow / Dockerfile and is
  treated as **public**. Never put credentials there.
- `validate-env` only checks **presence**, not value validity. A typo in
  the value still gets through; trust your runtime to fail fast.
- The matrix file is the source-of-truth for which env an env-var is
  expected in. The `Source` column documents *where* it's stored, not
  enforced by CI.

## Example wiring

```yaml
# .github/workflows/<consumer-stg>.yml
jobs:
  validate-env:
    uses: YiAgent/OpenCI/.github/workflows/reusable/deploy.yml@v3
    # ... or invoke the validate-env atom directly:
  custom:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: YiAgent/OpenCI/actions/_common/validate-env@<sha>
        with:
          target-env: stg
        env:
          DATABASE_URL:    ${{ secrets.DATABASE_URL }}
          REDIS_URL:       ${{ secrets.REDIS_URL }}
          KUBECONFIG_STG:  ${{ secrets.KUBECONFIG_STG }}
          # ...
```

The atom reads `infra/ENV_MATRIX.md` from the **consumer** repo's
checkout, so make sure the file is committed before stg/prd deploy
workflows run.

# Summarise CI failure

You are reading a brief snapshot of a failed CI run. Output **one
sentence** (max 20 words) describing the most likely root cause an
on-call engineer should look at first. No markdown, no preamble.

## Inputs

```json
{{context}}
```

`context` includes:
- `repo` — owner/name
- `run` — run id
- `failed_jobs` — comma-separated job names
- `failed_steps` — comma-separated step names that surfaced the failure

## Output

A single sentence. Lead with the verb. No "the run shows that…" filler.

Examples (good):
- `Lint job failed because tsc reported 5 type errors in src/auth.ts.`
- `Build hit OOM when bundling the marketing bundle (heap > 4GB).`
- `Trivy found a CRITICAL CVE in the base image (alpine:3.18 → 3.21 needed).`

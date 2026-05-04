# Workflow Test Report: on-main-bump-sha.yml

**File:** `.github/workflows/on-main-bump-sha.yml`
**Date:** 2026-05-04
**Purpose:** Auto-bump the YiAgent/OpenCI self-reference SHA in `manifest.yml` after every merge to main, opening a follow-up PR when the SHA is stale.

---

## Overview

| Property | Value |
|---|---|
| Name | `Auto-bump self SHA` |
| Triggers | `push` (branches: `[main]`), `workflow_dispatch` |
| Jobs | 1 (`bump`) |
| Runner | `ubuntu-latest` |
| Timeout | 10 minutes |
| Permissions | `contents: write`, `pull-requests: write` |
| Concurrency | Not set |
| Reusable workflows | None (standalone job) |
| Secrets required | `RELEASE_PAT` (PAT with `repo` + `workflow` scopes; falls back to `github.token`) |
| YAML validity | VALID |
| actionlint | Not available for testing |

**Current state:**
- Manifest SHA (`f62931bd0e2b73800512625a9fc5118557957ff3`) differs from HEAD (`a2ec4435856d81e53e39206e371d021cab9159eb`), meaning the workflow would currently detect a bump is needed.
- The manifest SHA resolves to a valid commit (`f62931b` = "Merge pull request #79") and its tree contains `.github/workflows/`.

---

## Node-by-Node Status

### Triggers

| Trigger | Config | Status |
|---|---|---|
| `push` | `branches: [main]` | OK - Fires on every merge/push to main |
| `workflow_dispatch` | No inputs defined | OK - Allows manual triggering; no inputs needed since the workflow reads the manifest |

### Permissions

| Scope | Level | Status |
|---|---|---|
| `contents` | `write` | OK - Required for pushing branches and committing |
| `pull-requests` | `write` | OK - Required for `gh pr create` |
| `workflows` | Not listed | NOTE - Workflow file updates require a PAT with `workflow` OAuth scope (documented in comments); default `GITHUB_TOKEN` lacks this scope |

### Job: `bump`

| Property | Value | Status |
|---|---|---|
| `runs-on` | `ubuntu-latest` | OK |
| `timeout-minutes` | 10 | OK - Sufficient for the operations |
| `needs` | None | OK - Single job, no dependencies |
| `if` | None | OK - Always runs |

### Step 0: Harden Runner

| Property | Value | Status |
|---|---|---|
| `uses` | `step-security/harden-runner@f808768d1510423e83855289c910610ca9b43176` | OK |
| SHA match (manifest) | Yes (`f808768...` = `v2.17.0`) | OK |
| `egress-policy` | `audit` | OK |

### Step 1: Checkout

| Property | Value | Status |
|---|---|---|
| `uses` | `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` | OK |
| SHA match (manifest) | Yes (`11bd719...` = `v4.2.2`) | OK |
| `fetch-depth` | 0 | OK - Full history needed for `git ls-tree` and SHA walking |
| `persist-credentials` | true | OK - Needed so `git push` uses the PAT |
| `token` | `${{ secrets.RELEASE_PAT \|\| github.token }}` | OK - PAT provides `workflow` scope for pushing workflow files |

### Step 2: Install yq

| Property | Value | Status |
|---|---|---|
| Download URL | `https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64` | WARN - Uses `latest` tag (non-deterministic) |
| Install path | `/usr/local/bin/yq` | OK |

### Step 3: Check if SHA needs bumping (id: `check`)

| Property | Value | Status |
|---|---|---|
| Reads | `manifest.yml` via `yq` | OK |
| Outputs | `skip`, `current_sha`, `new_sha` | OK |
| Logic | See analysis below | WARN - Edge case in validation logic |

**Logic analysis:**

```
current_sha = manifest.yml deps["YiAgent/OpenCI"]
head_sha = git rev-parse HEAD

1. If current_sha is empty -> skip (manifest has no entry)
2. If git ls-tree current_sha .github/workflows/ succeeds AND current_sha == head_sha -> skip (already current)
3. Otherwise -> bump
```

The logic correctly triggers a bump when the manifest SHA differs from HEAD. However, it does not independently verify that the manifest SHA is a valid commit -- `git ls-tree` on an invalid SHA returns empty (handled by `|| true`), which causes the workflow to proceed to bump regardless. This is acceptable because `bump-self-sha.sh` does its own resolution.

### Step 4: Run bump-self-sha.sh

| Property | Value | Status |
|---|---|---|
| `if` | `steps.check.outputs.skip != 'true'` | OK - Conditional on check step |
| Script | `scripts/bump-self-sha.sh` | OK - File exists, executable |
| Script location | `/home/wy/projects/YiAgent/openCI/scripts/bump-self-sha.sh` | OK |

**Script behavior:** Fetches `origin/main`, walks back up to 20 commits to find one containing `.github/workflows/`, updates `manifest.yml` and all workflow files via `perl -pi -e` global substitution.

### Step 5: Commit and open PR

| Property | Value | Status |
|---|---|---|
| `if` | `steps.check.outputs.skip != 'true'` | OK |
| `GH_TOKEN` | `${{ secrets.RELEASE_PAT \|\| github.token }}` | OK |
| `NEW_SHA` | `${{ steps.check.outputs.new_sha }}` | WARN - May differ from what `bump-self-sha.sh` resolved |
| `OLD_SHA` | `${{ steps.check.outputs.current_sha }}` | OK |
| Branch name | `chore/bump-self-sha-${NEW_SHA:0:8}` | OK |
| `git add` | `manifest.yml .github/workflows/` | WARN - Does not include `actions/` directory (bump script also updates files there) |
| `gh pr create` | `2>/dev/null \|\| true` | WARN - Silently suppresses PR creation errors |
| PR label | `chore` | OK |

---

## Issues Found

### MEDIUM: Missing `concurrency` group

**Impact:** If multiple merges land on `main` in quick succession, multiple bump workflows run simultaneously. Each may create a competing PR branch, leading to duplicate or conflicting PRs.

**Recommendation:** Add a concurrency group:
```yaml
concurrency:
  group: bump-self-sha
  cancel-in-progress: true
```

### MEDIUM: SHA mismatch between check step and bump script

**Impact:** The check step captures `new_sha` as `git rev-parse HEAD` at the time the workflow checkout happened. The `bump-self-sha.sh` script independently fetches `origin/main` and may resolve a different SHA (e.g., if a new commit landed between checkout and script execution). The PR title/body will reference the check step's SHA, while the actual manifest update uses the script's SHA.

**Recommendation:** Either (a) have the bump script output the resolved SHA and use that in the PR step, or (b) have the check step skip the `new_sha` output and let the commit step read it from the script's changes.

### MEDIUM: `git add` does not include `actions/` directory

**Impact:** The `bump-self-sha.sh` script searches both `.github/workflows/` and `actions/` directories for SHA references. If any file under `actions/` contains the old SHA and gets updated by the script, the changes will not be committed because `git add` only stages `manifest.yml .github/workflows/`.

**Recommendation:** Change to:
```bash
git add manifest.yml .github/workflows/ actions/
```

### LOW: Non-deterministic yq download

**Impact:** `https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64` fetches whatever `latest` points to. A compromised or breaking release could affect the workflow.

**Recommendation:** Pin to a specific version:
```bash
YQ_VERSION="v4.44.1"
sudo wget -qO /usr/local/bin/yq \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
```

### LOW: Silent PR creation failure

**Impact:** `gh pr create ... 2>/dev/null || true` suppresses all errors, including legitimate failures (network errors, permission issues, label "chore" not existing). If the PR fails to create, the branch is pushed but no PR is opened, and the workflow reports success.

**Recommendation:** Only suppress the "already exists" case:
```bash
gh pr create \
  --title "chore(manifest): bump YiAgent/OpenCI SHA to ${short_new}" \
  --body-file /tmp/pr-body.md \
  --base main \
  --head "$branch" \
  --label "chore" 2>&1 || {
    echo "::warning::PR creation failed (may already exist)"
  }
```

### LOW: `workflow_dispatch` has no inputs

**Impact:** Manual dispatch always runs the full check-and-bump logic. A `dry-run` input would be useful for diagnostics without side effects.

**Recommendation:** Add an optional `dry-run` input:
```yaml
workflow_dispatch:
  inputs:
    dry-run:
      description: 'Print actions without making changes'
      required: false
      type: boolean
      default: false
```

### INFO: No concurrency group across workflows

**Impact:** This workflow has no interaction with other workflows, so this is informational only. Other workflows in the repo (ci.yml, agent.yml, etc.) do define concurrency groups.

---

## Test Cases for Automation

### TC-01: Trigger on push to main

- **Action:** Push a commit to the `main` branch.
- **Expected:** The workflow triggers and the `bump` job starts.
- **Verify:** Check workflow run in Actions tab.

### TC-02: Trigger via workflow_dispatch

- **Action:** Manually dispatch the workflow from the Actions tab.
- **Expected:** The workflow triggers and the `bump` job starts.
- **Verify:** Check workflow run in Actions tab.

### TC-03: Skip when SHA is current

- **Setup:** Set `manifest.yml` `deps["YiAgent/OpenCI"]` to the current HEAD SHA.
- **Action:** Trigger the workflow.
- **Expected:** The "Check if SHA needs bumping" step sets `skip=true`. Steps 4 and 5 are skipped. Workflow succeeds.

### TC-04: Skip when YiAgent/OpenCI not in manifest

- **Setup:** Remove `YiAgent/OpenCI` from `manifest.yml` `deps`.
- **Action:** Trigger the workflow.
- **Expected:** The check step sets `skip=true` with a notice. Steps 4 and 5 are skipped.

### TC-05: Bump and create PR when SHA is stale

- **Setup:** Set `manifest.yml` `deps["YiAgent/OpenCI"]` to an older commit SHA (e.g., `f62931b`).
- **Action:** Trigger the workflow.
- **Expected:**
  - Check step sets `skip=false` with `current_sha=f62931b...` and `new_sha=<HEAD>`.
  - `bump-self-sha.sh` runs and updates manifest.yml and workflow files.
  - A new branch `chore/bump-self-sha-<short>` is created and pushed.
  - A PR is opened against `main` with the correct title and body.
  - Workflow succeeds.

### TC-06: PAT fallback to github.token

- **Setup:** Remove or unset the `RELEASE_PAT` secret.
- **Action:** Trigger the workflow.
- **Expected:** Checkout uses `github.token`. The bump script runs. The `git push` step may fail (default token lacks `workflow` scope), but the rest of the workflow runs for diagnostics.

### TC-07: Correct SHA in manifest after bump

- **Setup:** Pre-condition: manifest SHA is stale.
- **Action:** Complete TC-05.
- **Verify:** After the PR merges, `manifest.yml` `deps["YiAgent/OpenCI"]` equals the new HEAD SHA. All workflow files referencing the old SHA are updated.

### TC-08: Branch naming collision

- **Setup:** A branch `chore/bump-self-sha-<short>` already exists from a previous run.
- **Action:** Trigger the workflow when SHA is stale.
- **Expected:** `git push origin "$branch"` may fail or overwrite. The `gh pr create` may fail with "already exists" (suppressed by `|| true`). Workflow should still succeed without creating duplicate PRs.

### TC-09: Timeout behavior

- **Setup:** Simulate a slow network or large repository.
- **Action:** Trigger the workflow.
- **Expected:** If the job exceeds 10 minutes, GitHub Actions kills it. The workflow run shows a timeout failure.

### TC-10: Hardened runner egress audit

- **Action:** Trigger the workflow.
- **Verify:** The `step-security/harden-runner` step logs egress connections. The `Install yq` step's download to `github.com` appears in the audit log.

### TC-11: `actions/` directory changes are staged

- **Setup:** Ensure an `actions/` subdirectory file contains the old SHA.
- **Action:** Trigger the workflow when SHA is stale.
- **Expected:** The bump script updates the file, but `git add` only stages `manifest.yml .github/workflows/`. The `actions/` change is NOT committed. (This is a known gap -- see MEDIUM issue above.)

### TC-12: Concurrent runs do not conflict

- **Setup:** Push two commits to `main` in rapid succession.
- **Action:** Both trigger the workflow.
- **Expected:** Without a concurrency group, both run to completion and may create competing PR branches. (This is a known gap -- see MEDIUM issue above.)

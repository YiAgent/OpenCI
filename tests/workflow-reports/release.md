# Workflow Test Report: release.yml

**File:** `.github/workflows/release.yml`
**Tested:** 2026-05-04
**YAML syntax:** Valid
**actionlint:** Pass (clean, 0 errors on both `release.yml` and `reusable-release.yml`)

---

## Overview

`release.yml` is the **event entrypoint** for tagged releases. It delegates all work to the reusable workflow `reusable-release.yml` via a single `uses:` call. The reusable workflow handles two parallel jobs: marketplace tagging (GitHub Release + floating semver tags) and Docker image release (build, push, cosign keyless sign).

| Property | Value |
|----------|-------|
| Triggers | `push: tags: ["v*"]`, `workflow_dispatch` (mode input) |
| Jobs | 1 caller job (`release`) that delegates to reusable workflow |
| Reusable workflow | `YiAgent/OpenCI/.github/workflows/reusable-release.yml@f62931bd...` |
| Runner | `blacksmith-2vcpu-ubuntu-2404` (overridden from reusable default `ubuntu-latest`) |
| Concurrency | `release-${{ github.ref }}`, cancel-in-progress: false |
| Top-level permissions | `contents: write`, `packages: write`, `id-token: write`, `attestations: write` |

---

## Node-by-Node Status

### 1. Trigger Events (`on:`)

| Trigger | Config | Status |
|---------|--------|--------|
| `push.tags` | `["v*"]` | PASS - Correct glob for version tags |
| `workflow_dispatch.inputs.mode` | string, default `"both"`, not required | PASS |

### 2. Top-level Permissions

| Permission | Declared | Used By Reusable Jobs | Verdict |
|------------|----------|----------------------|---------|
| `contents: write` | Yes | marketplace job declares it | PASS |
| `packages: write` | Yes | docker job declares it | PASS |
| `id-token: write` | Yes | docker job declares it (for cosign OIDC) | PASS |
| `attestations: write` | Yes | Not declared by any reusable job | WARN - unnecessary, see Issue #1 |

### 3. Concurrency

| Field | Value | Status |
|-------|-------|--------|
| Group | `release-${{ github.ref }}` | PASS - Per-tag concurrency prevents parallel releases of the same tag |
| cancel-in-progress | `false` | PASS - Releases should never be cancelled mid-flight |

**Note:** The reusable workflow defines its own concurrency group as `release` (no ref suffix). When called, the caller's concurrency group takes precedence, so per-tag isolation is maintained.

### 4. SHA Pinning

| Reference | SHA | Manifest Match |
|-----------|-----|---------------|
| `YiAgent/OpenCI/.github/workflows/reusable-release.yml@f62931bd0e2b73800512625a9fc5118557957ff3` | `f62931bd...` | PASS - Matches `manifest.yml` entry for `YiAgent/OpenCI` |

Verified: SHA `f62931b` resolves to commit "Merge pull request #79 from YiAgent/fix/claude-harness-bot-defaults" in local history.

### 5. Reusable Workflow Inputs

| Input | Passed Value | Reusable Default | Status |
|-------|-------------|-----------------|--------|
| `mode` | `${{ inputs.mode \|\| 'both' }}` | `both` | PASS - Falls back correctly |
| `image-name` | `${{ vars.IMAGE_NAME \|\| github.event.repository.name }}` | `""` | PASS - Falls back to repo name |
| `registry` | `ghcr.io` | `ghcr.io` | PASS |
| `runner` | `blacksmith-2vcpu-ubuntu-2404` | `ubuntu-latest` | WARN - see Issue #2 |

### 6. Reusable Workflow Internal Jobs

#### 6a. `marketplace` job
- **Condition:** `push` event OR `workflow_dispatch`/`workflow_call` with mode `both`/`marketplace`
- **Runner:** `${{ inputs.runner }}` (resolves to `blacksmith-2vcpu-ubuntu-2404`)
- **Timeout:** 10 min
- **Permissions:** `contents: write`
- **Steps:** harden-runner, checkout, resolve OpenCI ref, checkout OpenCI, extract version, generate changelog, create GitHub Release, update floating tags
- **Status:** PASS

#### 6b. `docker` job
- **Condition:** `push` event OR `workflow_dispatch`/`workflow_call` with mode `both`/`docker`
- **Runner:** `${{ inputs.runner }}` (resolves to `blacksmith-2vcpu-ubuntu-2404`)
- **Timeout:** 20 min
- **Permissions:** `contents: read`, `packages: write`, `id-token: write`
- **Steps:** harden-runner, checkout, resolve OpenCI ref, checkout OpenCI, setup-buildx, login, metadata, build-push, sign-image
- **Local action:** `./.openci/actions/ci/sign-image` (checked out at runtime from `YiAgent/OpenCI`)
- **Status:** PASS - sign-image action exists at `actions/ci/sign-image/action.yml` in the OpenCI repo

### 7. Third-Party Action SHA Verification (reusable workflow)

| Action | SHA | In manifest.yml | Status |
|--------|-----|-----------------|--------|
| `step-security/harden-runner` | `f808768d...` | Yes | PASS |
| `actions/checkout` | `11bd7190...` | Yes | PASS |
| `docker/setup-buildx-action` | `b5ca5143...` | Yes | PASS |
| `docker/login-action` | `74a5d142...` | Yes | PASS |
| `docker/metadata-action` | `902fa8ec...` | Yes | PASS |
| `docker/build-push-action` | `26343531...` | Yes | PASS |
| `softprops/action-gh-release` | `b4309332...` | Yes | PASS |
| `sigstore/cosign-installer` | `59acb626...` | Yes (via sign-image action) | PASS |

---

## Issues Found

### Issue #1: Unnecessary `attestations: write` permission [MEDIUM]

**Location:** `release.yml` line 19

The caller declares `attestations: write` at the top level, but no job in the reusable workflow declares or uses this permission. This is a known source of `startup_failure` errors when the GitHub App or token lacks the `attestations:write` scope (see commit `50ce456` which removed this from `ci.yml` for the same reason).

**Impact:** Low in practice because the reusable workflow's `permissions: {}` at the top level means the called workflow uses its own per-job permissions, not the caller's. However, declaring an unused permission is inconsistent with the pattern used elsewhere in the repo.

**Recommendation:** Remove `attestations: write` from `release.yml` line 19 to match the pattern in other workflows and avoid confusion.

### Issue #2: Runner override uses Blacksmith label [LOW]

**Location:** `release.yml` line 31

The runner is set to `blacksmith-2vcpu-ubuntu-2404`, which is a Blacksmith CI runner. This requires the Blacksmith GitHub App to be installed on the repository. If the app is not installed or the runner is unavailable, jobs will queue indefinitely.

The reusable workflow defaults to `ubuntu-latest`, which is the standard GitHub-hosted runner. The override is intentional but creates a hard dependency on Blacksmith availability.

**Impact:** If Blacksmith is down or the app is uninstalled, releases will hang.

**Recommendation:** Document the Blacksmith dependency. Consider adding a fallback or making the runner configurable via repository variables.

### Issue #3: Reusable workflow concurrency group differs from caller [LOW]

**Location:** `reusable-release.yml` line 62

The reusable workflow defines `concurrency.group: release` (no ref suffix), while the caller defines `release-${{ github.ref }}`. The caller's concurrency group takes precedence when the reusable is invoked via `workflow_call`, so this is not a runtime issue. However, the inconsistency could cause confusion if the reusable workflow is ever invoked directly (e.g., via `workflow_dispatch` on the reusable itself).

**Impact:** No runtime impact when called via `release.yml`.

### Issue #4: Comment in reusable workflow references stale org name [LOW]

**Location:** `reusable-release.yml` line 13

The comment shows `uses: YiWang24/OpenCI/...` but the actual reference in `release.yml` uses `YiAgent/OpenCI/...`. The comment is documentation-only and does not affect execution.

---

## Test Cases for Automation

### TC-1: YAML Syntax Validation
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('PASS')"
```

### TC-2: actionlint Clean Pass
```bash
actionlint .github/workflows/release.yml .github/workflows/reusable-release.yml
# Expected: exit 0, no output
```

### TC-3: SHA Pinning Consistency
```bash
# Extract SHA from release.yml
SHA=$(grep -oP '@\K[a-f0-9]{40}' .github/workflows/release.yml)
# Verify it exists in manifest.yml
grep -q "$SHA" manifest.yml && echo "PASS" || echo "FAIL"
```

### TC-4: Reusable Workflow Exists
```bash
test -f .github/workflows/reusable-release.yml && echo "PASS" || echo "FAIL"
```

### TC-5: No Unpinned Action References (no @v1, @main, @master)
```bash
grep -nP '@(v\d+|main|master)\b' .github/workflows/release.yml && echo "FAIL" || echo "PASS"
```

### TC-6: No Hardcoded Secrets
```bash
grep -niP '(api[_-]?key|token|password|secret)\s*[:=]\s*["\x27][A-Za-z0-9]' .github/workflows/release.yml && echo "FAIL" || echo "PASS"
```

### TC-7: Permissions Minimal (no wildcards)
```bash
grep -qP 'permissions:.*\*' .github/workflows/release.yml && echo "FAIL" || echo "PASS"
```

### TC-8: Concurrency Group Uses github.ref
```bash
grep -q 'release-\${{ github.ref }}' .github/workflows/release.yml && echo "PASS" || echo "FAIL"
```

### TC-9: Trigger Configuration Correct
```bash
# YAML parses 'on' as boolean True; override to use scalar key
python3 -c "
import yaml
class L(yaml.SafeLoader): pass
L.add_constructor('tag:yaml.org,2002:bool', lambda l, n: l.construct_scalar(n))
wf = yaml.load(open('.github/workflows/release.yml'), Loader=L)
tags = wf['on']['push']['tags']
assert 'v*' in tags, 'Missing v* tag trigger'
assert 'workflow_dispatch' in wf['on'], 'Missing workflow_dispatch'
print('PASS')
"
```

### TC-10: Reusable Workflow Inputs Match Declaration
```bash
python3 -c "
import yaml
class L(yaml.SafeLoader): pass
L.add_constructor('tag:yaml.org,2002:bool', lambda l, n: l.construct_scalar(n))
caller = yaml.load(open('.github/workflows/release.yml'), Loader=L)
reusable = yaml.load(open('.github/workflows/reusable-release.yml'), Loader=L)
caller_inputs = set(caller['jobs']['release']['with'].keys())
reusable_inputs = set(reusable['on']['workflow_call']['inputs'].keys())
missing = caller_inputs - reusable_inputs
assert not missing, f'Caller passes unknown inputs: {missing}'
print('PASS')
"
```

### TC-11: sign-image Action Exists in Repo
```bash
test -f actions/ci/sign-image/action.yml && echo "PASS" || echo "FAIL"
```

### TC-12: Runner Label Is Not Empty
```bash
python3 -c "
import yaml
class L(yaml.SafeLoader): pass
L.add_constructor('tag:yaml.org,2002:bool', lambda l, n: l.construct_scalar(n))
wf = yaml.load(open('.github/workflows/release.yml'), Loader=L)
runner = wf['jobs']['release']['with']['runner']
assert runner.strip(), 'Runner label is empty'
print(f'PASS - runner={runner}')
"
```

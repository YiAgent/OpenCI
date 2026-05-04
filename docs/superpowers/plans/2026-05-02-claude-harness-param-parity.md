# Claude Harness — Upstream Parameter Parity

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the missing `anthropics/claude-code-action@v1` inputs through the `_common/claude-harness` wrapper so downstream callers gain full control over inline-comment classification, fix links, additional permissions, session timeout, plugins, commit signing, and bot identity — without breaking any of the 13 existing harness callers.

**Architecture:** All new inputs are optional with safe defaults that reproduce current behaviour. Phase 1 touches `action.yml` (new inputs + `with:` pass-throughs) and `compose-args.sh` (timeout). Phase 2 adds plugin and identity pass-throughs, also only in `action.yml`.

**Tech Stack:** GitHub Actions composite action (YAML), bash, `anthropics/claude-code-action@v1` (pinned to `12310e4417c3473095c957cb311b3cf59a38d659`)

---

## Correction from pre-plan analysis

`use_foundry` is **not a bug**. The official action at the pinned SHA does have `use_foundry` as a first-class input (confirmed via GitHub API). The harness already passes it correctly on line 222 of `action.yml`. No fix needed.

---

## File Map

| File | Change |
|------|--------|
| `actions/_common/claude-harness/action.yml` | Add new inputs; update `with:` block on the `Run claude-code-action` step; update `additional_permissions` block |
| `actions/_common/claude-harness/compose-args.sh` | Replace hardcoded `API_TIMEOUT_MS: "3000000"` with value from env |

No new files. No changes to downstream callers (all new inputs are optional with defaults matching current behaviour).

---

## Phase 1 — High-Priority Quick Wins

### Task 1: Add `classify-inline-comments` and `include-fix-links` inputs

These are single-input pass-throughs. The official action default for both is `true`, so the harness default must also be `true` to preserve existing behaviour.

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`

- [ ] **Step 1: Add the two inputs to the `inputs:` block** (after the existing `use-sticky-comment` input)

```yaml
  classify-inline-comments:
    description: |
      Buffer inline comments and classify them with Claude Haiku before posting.
      Set to "false" to post all inline comments immediately (useful in pure
      automation pipelines where every comment is intentional).
    required: false
    default: "true"
  include-fix-links:
    description: |
      Attach a "Fix this" link to each review comment that opens Claude Code
      with the issue pre-loaded. Set to "false" to suppress these links in
      fully-automated review jobs.
    required: false
    default: "true"
```

- [ ] **Step 2: Pass the inputs through in the `with:` block of the `Run claude-code-action` step** (after the existing `use_sticky_comment:` line)

```yaml
        classify_inline_comments:  ${{ inputs.classify-inline-comments }}
        include_fix_links:         ${{ inputs.include-fix-links }}
```

- [ ] **Step 3: Verify no YAML parse errors**

```bash
cd /Users/wy/projects/yiagent/OpenCI
python3 -c "import yaml; yaml.safe_load(open('actions/_common/claude-harness/action.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add actions/_common/claude-harness/action.yml
git commit -m "feat(harness): add classify-inline-comments and include-fix-links inputs"
```

---

### Task 2: Make `additional_permissions` additive

Currently `additional_permissions: actions: read` is hardcoded in `action.yml`. The `mcp__github_ci__*` tools in the baseline tool list **require** `actions: read` to work, so this permission must never be removed. The fix is to expose an `extra-permissions` input that is appended after the hardcoded floor — not a full override.

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`

- [ ] **Step 1: Add `extra-permissions` input** (after `extra-disallowed-tools`)

```yaml
  extra-permissions:
    description: |
      Additional GitHub Actions permissions to grant, in YAML block scalar form.
      These are APPENDED to the hardcoded floor permission "actions: read" which
      is always present because the baseline tool list includes mcp__github_ci__*
      tools that require it.
      Example: "contents: write\npull-requests: write"
    required: false
    default: ""
```

- [ ] **Step 2: Update the `additional_permissions:` block in the `Run claude-code-action` step**

Replace the current hardcoded block:
```yaml
        additional_permissions: |
          actions: read
```

With a block that appends the caller's extras:
```yaml
        additional_permissions: |
          actions: read
          ${{ inputs.extra-permissions }}
```

- [ ] **Step 3: Verify YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('actions/_common/claude-harness/action.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add actions/_common/claude-harness/action.yml
git commit -m "feat(harness): add extra-permissions (additive, keeps actions:read floor)"
```

---

### Task 3: Expose configurable session timeout

`compose-args.sh` hardcodes `API_TIMEOUT_MS: "3000000"` (50 min). Long-running overnight analysis jobs need more; quick PR comment handlers need less. Expose as `session-timeout-ms`.

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`
- Modify: `actions/_common/claude-harness/compose-args.sh`

- [ ] **Step 1: Add `session-timeout-ms` input to `action.yml`** (after `max-turns`)

```yaml
  session-timeout-ms:
    description: |
      Maximum milliseconds Claude Code waits for an API response per request.
      Default 3 000 000 ms (50 min) is appropriate for long agent loops.
      Reduce for quick PR handlers (e.g. "120000" = 2 min).
    required: false
    default: "3000000"
```

- [ ] **Step 2: Thread the new input through the `Compose claude_args & settings` step env block in `action.yml`**

Add one line to the `env:` block of the compose step (after `EXTRA_ENV_JSON`):
```yaml
        SESSION_TIMEOUT_MS:  ${{ inputs.session-timeout-ms }}
```

- [ ] **Step 3: Update `compose-args.sh` to use the env var instead of the hardcoded literal**

Find the line:
```bash
          API_TIMEOUT_MS:       "3000000",
```

Replace with:
```bash
          API_TIMEOUT_MS:       ($ENV.SESSION_TIMEOUT_MS // "3000000"),
```

Wait — that's jq syntax. The full jq block in `compose-args.sh` already has access to shell env vars via `$ENV` in jq. But `SESSION_TIMEOUT_MS` is a shell env var, not a jq `--arg`. The cleanest fix is to pass it as an arg. Find the jq call and add `--arg timeout "${SESSION_TIMEOUT_MS:-3000000}"`:

```bash
  settings_json="$(jq -nc \
    --arg slack      "${SLACK_WEBHOOK:-}" \
    --arg base_url   "${API_BASE_URL:-}" \
    --arg auth_token "${AUTH_TOKEN_PASSTHROUGH:-}" \
    --arg timeout    "${SESSION_TIMEOUT_MS:-3000000}" \
    --argjson extra  "${EXTRA_ENV_JSON:-{\}}" \
    '{
      env: (
        ({
          SLACK_WEBHOOK_URL:    $slack,
          ANTHROPIC_BASE_URL:   $base_url,
          ANTHROPIC_AUTH_TOKEN: $auth_token,
          API_TIMEOUT_MS:       $timeout,
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
        } | with_entries(select(.value != "")))
        + $extra
      )
    }')"
```

- [ ] **Step 4: Verify the compose script parses**

```bash
cd /Users/wy/projects/yiagent/OpenCI
bash -n actions/_common/claude-harness/compose-args.sh && echo "BASH OK"
```

Expected: `BASH OK`

- [ ] **Step 5: Smoke-test the jq block manually**

```bash
SLACK_WEBHOOK="" API_BASE_URL="" AUTH_TOKEN_PASSTHROUGH="" SESSION_TIMEOUT_MS="120000" EXTRA_ENV_JSON='{}' \
  bash -c '
    jq -nc \
      --arg slack      "" \
      --arg base_url   "" \
      --arg auth_token "" \
      --arg timeout    "120000" \
      --argjson extra  "{}" \
      "{env: (({API_TIMEOUT_MS: \$timeout, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: \"1\"} | with_entries(select(.value != \"\"))) + \$extra)}"
  '
```

Expected: JSON with `"API_TIMEOUT_MS": "120000"`

- [ ] **Step 6: Commit**

```bash
git add actions/_common/claude-harness/action.yml actions/_common/claude-harness/compose-args.sh
git commit -m "feat(harness): expose session-timeout-ms (replaces hardcoded 3000000)"
```

---

## Phase 2 — Medium-Priority Pass-Throughs

These are pure YAML additions: new `inputs:` entry + one `with:` line. No shell script changes.

### Task 4: Add plugin inputs

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`

- [ ] **Step 1: Add `plugins` and `plugin-marketplaces` inputs** (after `mcp-config`)

```yaml
  plugins:
    description: |
      Newline-separated list of Claude Code plugin identifiers to install before
      the agent run. Example: "anthropics/claude-code-plugin-foo@1.0.0"
    required: false
    default: ""
  plugin-marketplaces:
    description: |
      Newline-separated list of custom marketplace URLs used to resolve plugins.
    required: false
    default: ""
```

- [ ] **Step 2: Pass through in the `with:` block** (after `include_fix_links`)

```yaml
        plugins:             ${{ inputs.plugins }}
        plugin_marketplaces: ${{ inputs.plugin-marketplaces }}
```

- [ ] **Step 3: Verify YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('actions/_common/claude-harness/action.yml'))" && echo "YAML OK"
```

- [ ] **Step 4: Commit**

```bash
git add actions/_common/claude-harness/action.yml
git commit -m "feat(harness): add plugins and plugin-marketplaces inputs"
```

---

### Task 5: Add commit-signing inputs

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`

- [ ] **Step 1: Add `use-commit-signing` and `ssh-signing-key` inputs** (after `oauth-token`)

```yaml
  use-commit-signing:
    description: |
      Sign commits made by Claude. Set to "true" to enable GitHub API-based
      signing (no key needed), or set to "ssh" to use the ssh-signing-key input.
    required: false
    default: "false"
  ssh-signing-key:
    description: |
      SSH private key for signing commits when use-commit-signing is "ssh".
      Pass as a secret: ${{ secrets.CLAUDE_SSH_SIGNING_KEY }}.
    required: false
    default: ""
```

- [ ] **Step 2: Pass through in the `with:` block**

```yaml
        use_commit_signing: ${{ inputs.use-commit-signing }}
        ssh_signing_key:    ${{ inputs.ssh-signing-key }}
```

- [ ] **Step 3: Verify YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('actions/_common/claude-harness/action.yml'))" && echo "YAML OK"
```

- [ ] **Step 4: Commit**

```bash
git add actions/_common/claude-harness/action.yml
git commit -m "feat(harness): add use-commit-signing and ssh-signing-key inputs"
```

---

### Task 6: Add bot identity and base-branch inputs

**Files:**
- Modify: `actions/_common/claude-harness/action.yml`

- [ ] **Step 1: Add `bot-id`, `bot-name`, and `base-branch` inputs** (after `github-token`)

```yaml
  bot-id:
    description: |
      GitHub App bot ID for custom Claude Code GitHub Apps. Leave empty to use
      the default claude[bot] identity.
    required: false
    default: ""
  bot-name:
    description: |
      GitHub App bot display name. Leave empty to use the default "claude".
    required: false
    default: ""
  base-branch:
    description: |
      Base branch for new branches created by Claude. Leave empty to let the
      official action use its default (the repo's default branch).
    required: false
    default: ""
```

- [ ] **Step 2: Pass through in the `with:` block**

```yaml
        bot_id:      ${{ inputs.bot-id }}
        bot_name:    ${{ inputs.bot-name }}
        base_branch: ${{ inputs.base-branch }}
```

- [ ] **Step 3: Verify YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('actions/_common/claude-harness/action.yml'))" && echo "YAML OK"
```

- [ ] **Step 4: Commit**

```bash
git add actions/_common/claude-harness/action.yml
git commit -m "feat(harness): add bot-id, bot-name, base-branch inputs"
```

---

## Final Verification

- [ ] **Run full YAML validation on every action that calls the harness**

```bash
cd /Users/wy/projects/yiagent/OpenCI
python3 -c "
import yaml, glob, sys
errors = []
for f in glob.glob('actions/**/*.yml', recursive=True):
    try:
        yaml.safe_load(open(f))
    except Exception as e:
        errors.append(f'{f}: {e}')
if errors:
    print('\n'.join(errors)); sys.exit(1)
else:
    print(f'All {len(list(glob.glob(\"actions/**/*.yml\", recursive=True)))} YAML files OK')
"
```

Expected: all files OK with no errors

- [ ] **Verify backward compatibility: none of the 13 callers pass the new inputs (they all get safe defaults)**

```bash
grep -r "classify.inline\|include.fix\|extra.permissions\|session.timeout\|plugins\|commit.signing\|bot.id\|bot.name\|base.branch" \
  /Users/wy/projects/yiagent/OpenCI/actions --include="*.yml" \
  --exclude-path="*/claude-harness/*" | grep -v "^Binary" || echo "No callers use new inputs — backward compat confirmed"
```

Expected: output shows no existing callers use the new inputs

- [ ] **Open a PR**

```bash
git push -u origin claude/objective-galileo-742e23
gh pr create \
  --title "feat(harness): upstream parameter parity with claude-code-action@v1" \
  --body "$(cat <<'EOF'
## Summary
- Phase 1: classify-inline-comments, include-fix-links, extra-permissions (additive), session-timeout-ms
- Phase 2: plugins, plugin-marketplaces, use-commit-signing, ssh-signing-key, bot-id, bot-name, base-branch
- use_foundry confirmed correct — no change needed
- All new inputs are optional with defaults matching current behaviour; 0 breaking changes for the 13 existing callers

## Skipped (intentionally)
trigger_phrase, assignee_trigger, label_trigger — automation-only pipeline, no interactive triggers
allowed_non_write_users — flagged ⚠️ RISKY in official docs
track_progress, include_comments_by_actor, exclude_comments_by_actor — unnecessary in CI context
path_to_claude_code_executable, path_to_bun_executable — Nix edge case

## Test plan
- [ ] YAML validation passes for all 13 harness callers
- [ ] Existing callers run without specifying new inputs (backward compat)
- [ ] classify_inline_comments=false disables comment batching in PR review job
- [ ] session-timeout-ms=120000 reaches Claude Code as API_TIMEOUT_MS=120000
EOF
)"
```

---

## Parameters intentionally skipped

| Parameter | Reason |
|-----------|--------|
| `trigger_phrase` / `assignee_trigger` / `label_trigger` | All harness invocations are programmatic; no interactive triggers needed |
| `allowed_non_write_users` | Marked ⚠️ RISKY in official docs |
| `track_progress` | Interactive mode only |
| `include_comments_by_actor` / `exclude_comments_by_actor` | Not needed; callers control what events fire via workflow `on:` |
| `path_to_claude_code_executable` / `path_to_bun_executable` | Nix environment edge case only |
| `display_report` / `show_full_output` | Debug-only; out of scope |
| `allowed_bots` | Not needed; harness already controls bot identity via `bot-id`/`bot-name` |

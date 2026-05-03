#!/usr/bin/env bats
# Structural and contract tests for actions/pr/enrich/action.yml
# Stage 2 of the PR pipeline: builds agent workspace from Gate results + live PR data.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="${PROJECT_ROOT}/actions/pr/enrich/action.yml"
  MANIFEST="${PROJECT_ROOT}/manifest.yml"
}

# ── File existence and basic structure ────────────────────────────────────────

@test "action.yml exists" {
  [ -f "${ACTION}" ]
}

@test "action.yml is valid YAML" {
  if command -v yq >/dev/null 2>&1; then
    yq -e . "${ACTION}" >/dev/null
  else
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${ACTION}"
  fi
}

@test "uses composite run type" {
  run grep 'using: composite' "${ACTION}"
  [ "${status}" -eq 0 ]
}

# ── Inputs ───────────────────────────────────────────────────────────────────

@test "declares gate-lint-result input with skipped default" {
  grep 'gate-lint-result:' "${ACTION}"
  run grep -A2 'gate-lint-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "declares gate-test-result input with skipped default" {
  grep 'gate-test-result:' "${ACTION}"
  run grep -A2 'gate-test-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "declares gate-coverage-result input with skipped default" {
  grep 'gate-coverage-result:' "${ACTION}"
  run grep -A2 'gate-coverage-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "declares gate-secrets-result input with skipped default" {
  grep 'gate-secrets-result:' "${ACTION}"
  run grep -A2 'gate-secrets-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "declares gate-validate-title-result input with skipped default" {
  grep 'gate-validate-title-result:' "${ACTION}"
  # default: "skipped" is 3 lines after the input key (description, required, default).
  run grep -A4 'gate-validate-title-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "declares gate-scan-deps-result input with skipped default" {
  grep 'gate-scan-deps-result:' "${ACTION}"
  run grep -A4 'gate-scan-deps-result:' "${ACTION}"
  [[ "${output}" == *"skipped"* ]]
}

@test "all six gate inputs are optional (required: false)" {
  # Count required: false lines that appear under gate-*-result inputs.
  # Each gate input should have required: false.
  local count
  count=$(grep -c 'required: false' "${ACTION}")
  [ "${count}" -ge 6 ]
}

@test "no gate input uses required: true" {
  run grep -B1 'required: true' "${ACTION}"
  [ "${status}" -ne 0 ]
}

# ── Outputs ──────────────────────────────────────────────────────────────────

@test "declares workspace-artifact output" {
  grep 'workspace-artifact:' "${ACTION}"
}

@test "workspace-artifact output includes run_id" {
  grep -E 'workspace-artifact:.*\$\{\{\s*github\.run_id\s*\}\}' "${ACTION}" \
    || grep 'pr-agent-workspace-' "${ACTION}"
}

# ── Step names ───────────────────────────────────────────────────────────────

@test "has Build gate-results.json step" {
  grep 'Build gate-results.json' "${ACTION}"
}

@test "has Build pr-meta.json step" {
  grep 'Build pr-meta.json' "${ACTION}"
}

@test "has Collect diff step" {
  grep 'Collect diff' "${ACTION}"
}

@test "has Collect files changed step" {
  grep 'Collect files changed' "${ACTION}"
}

@test "has Collect existing reviews step" {
  grep 'Collect existing reviews' "${ACTION}"
}

@test "has Merge agent context and skills step" {
  grep 'Merge agent context and skills' "${ACTION}"
}

@test "has Write agent prompt step" {
  grep 'Write agent prompt' "${ACTION}"
}

# ── Artifact upload ──────────────────────────────────────────────────────────

@test "uses actions/upload-artifact with 40-char SHA" {
  sha="$(grep 'uses:.*actions/upload-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  [ -n "${sha}" ]
  [ "${#sha}" -eq 40 ]
}

@test "upload-artifact SHA matches manifest.yml" {
  action_sha="$(grep 'uses:.*actions/upload-artifact' "${ACTION}" | grep -oE '[0-9a-f]{40}')"
  manifest_sha="$(grep 'actions/upload-artifact:' "${MANIFEST}" | grep -oE '[0-9a-f]{40}')"
  [ "${action_sha}" = "${manifest_sha}" ]
}

@test "upload-artifact uses if-no-files-found: error" {
  grep 'if-no-files-found: error' "${ACTION}"
}

@test "upload-artifact retention-days is set to 1" {
  grep 'retention-days: 1' "${ACTION}"
}

@test "upload-artifact path is agent-workspace/" {
  grep "path: agent-workspace/" "${ACTION}"
}

@test "upload-artifact name includes run_id placeholder" {
  grep -E 'name:\s*pr-agent-workspace-\$\{\{' "${ACTION}"
}

# ── No unpinned references ───────────────────────────────────────────────────

@test "no @v* or @main or @master references" {
  run grep -E 'uses:.*@(v[0-9]|main|master)' "${ACTION}"
  [ "${status}" -ne 0 ]
}

# ── Gate results JSON construction ───────────────────────────────────────────

@test "result_to_bool converts success to true" {
  # Verify the helper function logic is present in the gate-results step.
  grep 'result_to_bool' "${ACTION}"
  grep '\[ "$1" = "success" \]' "${ACTION}"
}

@test "gate-results.json uses jq to build structured output" {
  grep 'jq -n' "${ACTION}"
  grep 'gate-results.json' "${ACTION}"
}

@test "gate-results.json includes all boolean pass fields" {
  for field in lint_passed test_passed coverage_passed secrets_clean; do
    grep "${field}" "${ACTION}"
  done
}

@test "gate-results.json includes raw result fields" {
  for field in lint_result test_result coverage_result secrets_result title_result deps_result; do
    grep "${field}" "${ACTION}"
  done
}

@test "gate-results.json results object contains all six gate keys" {
  for key in lint test coverage scan_secrets validate_pr_title scan_deps; do
    grep "${key}" "${ACTION}"
  done
}

@test "gate step passes input values via env vars" {
  for var in LINT TEST COVERAGE SECRETS TITLE DEPS; do
    grep -E "^\s+${var}:" "${ACTION}"
  done
}

@test "gate step sets set -euo pipefail" {
  grep 'set -euo pipefail' "${ACTION}"
}

# ── PR metadata collection ───────────────────────────────────────────────────

@test "pr-meta uses gh pr view with --json" {
  grep 'gh pr view' "${ACTION}"
  grep -- '--json' "${ACTION}"
}

@test "pr-meta requests all required fields" {
  for field in number title author baseRefName headRefName isDraft mergeable additions deletions changedFiles body; do
    grep "${field}" "${ACTION}"
  done
}

@test "pr-meta includes closingIssuesReferences" {
  grep 'closingIssuesReferences' "${ACTION}"
}

@test "pr-meta output goes to agent-workspace/pr-meta.json" {
  grep 'agent-workspace/pr-meta.json' "${ACTION}"
}

@test "pr-meta uses GH_TOKEN env var" {
  run grep -A5 'Build pr-meta.json' "${ACTION}"
  [[ "${output}" == *"GH_TOKEN"* ]]
}

# ── Diff collection ──────────────────────────────────────────────────────────

@test "diff uses gh pr diff" {
  grep 'gh pr diff' "${ACTION}"
}

@test "diff is capped at 40960 bytes (40 KB)" {
  grep 'head -c 40960' "${ACTION}"
}

@test "diff output goes to agent-workspace/diff.patch" {
  grep 'agent-workspace/diff.patch' "${ACTION}"
}

@test "diff step uses || true to tolerate empty diffs" {
  # The diff step pipes through head -c and uses || true to avoid failing on
  # PRs with no diff (e.g. draft-only changes).
  run grep -A3 'gh pr diff' "${ACTION}"
  [[ "${output}" == *"|| true"* ]]
}

# ── Files changed collection ────────────────────────────────────────────────

@test "files-changed uses gh pr view --json files" {
  grep 'gh pr view' "${ACTION}"
  grep -- '--json files' "${ACTION}"
}

@test "files-changed output goes to agent-workspace/files-changed.json" {
  grep 'agent-workspace/files-changed.json' "${ACTION}"
}

# ── Reviews collection ───────────────────────────────────────────────────────

@test "reviews uses gh pr view --json reviews,comments" {
  grep -- '--json reviews,comments' "${ACTION}"
}

@test "reviews output goes to agent-workspace/reviews.json" {
  grep 'agent-workspace/reviews.json' "${ACTION}"
}

# ── Context and skills merge ─────────────────────────────────────────────────

@test "merges shared and pr-specific AGENTS.md context" {
  grep 'AGENTS.md' "${ACTION}"
}

@test "context merge includes .openci defaults" {
  grep '.openci/.github/agent/shared/context/AGENTS.md' "${ACTION}"
  grep '.openci/.github/agent/pr/context/AGENTS.md' "${ACTION}"
}

@test "context merge includes caller overrides" {
  grep '.github/agent/shared/context/AGENTS.md' "${ACTION}"
  grep '.github/agent/pr/context/AGENTS.md' "${ACTION}"
}

@test "context merge tolerates missing files (2>/dev/null || true)" {
  local count
  count=$(grep -c '2>/dev/null || true' "${ACTION}")
  # At least 4 context cats + 4 skill copies = 8 tolerances minimum
  [ "${count}" -ge 8 ]
}

@test "merged context output goes to agent-workspace/context.md" {
  grep 'agent-workspace/context.md' "${ACTION}"
}

@test "copies shared then pr-specific skills" {
  # Use -F for fixed-string matching to avoid * being treated as regex quantifier.
  grep -F 'shared/skills/*.md' "${ACTION}"
  grep -F 'pr/skills/*.md' "${ACTION}"
}

@test "skills are copied to agent-workspace/skills/" {
  grep 'agent-workspace/skills/' "${ACTION}"
}

@test "skills merge allows pr-specific to override shared by filename" {
  # Verify order: shared first, then pr-specific (cp overwrites by filename).
  # Use -F for exact matching and include the cp command to disambiguate.
  local openci_shared openci_pr github_shared github_pr
  openci_shared=$(grep -Fn 'cp .openci/.github/agent/shared/skills/' "${ACTION}" | head -1 | cut -d: -f1)
  openci_pr=$(grep -Fn 'cp .openci/.github/agent/pr/skills/' "${ACTION}" | head -1 | cut -d: -f1)
  github_shared=$(grep -Fn 'cp .github/agent/shared/skills/' "${ACTION}" | head -1 | cut -d: -f1)
  github_pr=$(grep -Fn 'cp .github/agent/pr/skills/' "${ACTION}" | head -1 | cut -d: -f1)
  [ -n "${openci_shared}" ]
  [ -n "${openci_pr}" ]
  [ -n "${github_shared}" ]
  [ -n "${github_pr}" ]
  [ "${openci_shared}" -lt "${openci_pr}" ]
  [ "${openci_pr}" -lt "${github_shared}" ]
  [ "${github_shared}" -lt "${github_pr}" ]
}

@test "mkdir -p creates agent-workspace/skills directory" {
  grep 'mkdir -p agent-workspace/skills' "${ACTION}"
}

# ── Agent prompt ─────────────────────────────────────────────────────────────

@test "prompt references reading order with context.md first" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"1. agent-workspace/context.md"* ]]
}

@test "prompt references skills as second item" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"2. agent-workspace/skills/"* ]]
}

@test "prompt references gate-results.json" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"gate-results.json"* ]]
}

@test "prompt references pr-meta.json" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"pr-meta.json"* ]]
}

@test "prompt references diff.patch" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"diff.patch"* ]]
}

@test "prompt references files-changed.json" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"files-changed.json"* ]]
}

@test "prompt references reviews.json" {
  run grep -A20 'Read the workspace files' "${ACTION}"
  [[ "${output}" == *"reviews.json"* ]]
}

@test "prompt specifies pr-action-plan/v1 schema" {
  grep 'pr-action-plan/v1' "${ACTION}"
}

@test "prompt requests exactly one JSON object with no prose" {
  grep 'ONE JSON object' "${ACTION}"
  grep 'No surrounding prose' "${ACTION}"
}

@test "prompt output goes to agent-workspace/prompt.md" {
  grep 'agent-workspace/prompt.md' "${ACTION}"
}

# ── Workspace directory layout contract ──────────────────────────────────────

@test "workspace produces gate-results.json" {
  grep 'agent-workspace/gate-results.json' "${ACTION}"
}

@test "workspace produces pr-meta.json" {
  grep 'agent-workspace/pr-meta.json' "${ACTION}"
}

@test "workspace produces diff.patch" {
  grep 'agent-workspace/diff.patch' "${ACTION}"
}

@test "workspace produces files-changed.json" {
  grep 'agent-workspace/files-changed.json' "${ACTION}"
}

@test "workspace produces reviews.json" {
  grep 'agent-workspace/reviews.json' "${ACTION}"
}

@test "workspace produces context.md" {
  grep 'agent-workspace/context.md' "${ACTION}"
}

@test "workspace produces prompt.md" {
  grep 'agent-workspace/prompt.md' "${ACTION}"
}

@test "workspace produces skills directory" {
  grep 'agent-workspace/skills' "${ACTION}"
}

# ── Shell discipline ─────────────────────────────────────────────────────────

@test "all bash run-blocks use set -euo pipefail" {
  # Count shell: bash declarations and set -euo pipefail declarations.
  # The "Write agent prompt" step uses a heredoc (cat > file << 'PROMPT') that
  # doesn't need pipefail since it has no pipes or failing commands.
  # All other bash steps (6 of 7) must have it.
  local shells pipefails
  shells=$(grep -c 'shell: bash' "${ACTION}")
  pipefails=$(grep -c 'set -euo pipefail' "${ACTION}")
  [ "${shells}" -eq 7 ]
  [ "${pipefails}" -eq 6 ]
  # Verify the step that omits it is the heredoc prompt step.
  run grep -A5 'Write agent prompt' "${ACTION}"
  [[ "${output}" == *"cat > agent-workspace/prompt.md"* ]]
}

# ── GH API calls use consistent token ────────────────────────────────────────

@test "all gh commands use GH_TOKEN from github.token" {
  # Every gh pr view / gh pr diff block should have GH_TOKEN set.
  local gh_steps
  gh_steps=$(grep -c 'gh pr ' "${ACTION}")
  local token_blocks
  token_blocks=$(grep -c 'GH_TOKEN:' "${ACTION}")
  [ "${token_blocks}" -ge "${gh_steps}" ]
}

# ── Name and description ─────────────────────────────────────────────────────

@test "action name includes PR and Enrich" {
  run head -20 "${ACTION}"
  [[ "${output}" == *"PR"* ]]
  [[ "${output}" == *"Enrich"* ]]
}

@test "action description mentions agent workspace" {
  grep -i 'agent workspace' "${ACTION}"
}

@test "action description mentions Stage" {
  grep -i 'Stage' "${ACTION}"
}

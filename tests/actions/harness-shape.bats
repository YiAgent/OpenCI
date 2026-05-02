#!/usr/bin/env bats
# Tests the structural contract of the claude-harness composite + reusable
# workflow without invoking a GitHub runner. Catches drift between the two
# (e.g. composite gains an input but the workflow doesn't expose it) and
# guards against accidental return to bug-prone v1.x inputs like prompt_file.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPOSITE="${PROJECT_ROOT}/actions/_common/claude-harness/action.yml"
  WORKFLOW="${PROJECT_ROOT}/.github/workflows/claude-harness.yml"
}

# Helpers
have_yq() { command -v yq >/dev/null 2>&1; }

@test "composite action.yml is valid YAML" {
  if have_yq; then
    yq -e . "$COMPOSITE" >/dev/null
  else
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$COMPOSITE"
  fi
}

@test "reusable workflow is valid YAML" {
  if have_yq; then
    yq -e . "$WORKFLOW" >/dev/null
  else
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW"
  fi
}

@test "composite does NOT use the non-existent prompt_file input" {
  ! grep -E '^\s*prompt_file\s*:' "$COMPOSITE"
}

@test "composite does NOT use the non-existent prompt_inputs input" {
  ! grep -E '^\s*prompt_inputs\s*:' "$COMPOSITE"
}

@test "composite does NOT use the non-existent sticky_comment_marker input" {
  # Match only as a YAML key (i.e. ignore the explanatory comment).
  ! grep -E '^[[:space:]]+sticky_comment_marker[[:space:]]*:' "$COMPOSITE"
}

@test "composite passes prompt: from resolve step output" {
  grep -E "prompt:\s+\\\$\{\{ steps\.resolve\.outputs\.prompt \}\}" "$COMPOSITE"
}

@test "composite pins claude-code-action by SHA" {
  grep -E 'anthropics/claude-code-action@[0-9a-f]{40}' "$COMPOSITE"
}

@test "composite enables additional_permissions: actions: read" {
  grep -E '^\s+additional_permissions:' "$COMPOSITE"
  grep -E 'actions:\s*read' "$COMPOSITE"
}

@test "reusable workflow exposes new inputs" {
  for key in extra-allowed-tools extra-disallowed-tools mcp-config use-sticky-comment extra-env system-prompt; do
    grep -E "^\s+${key}:" "$WORKFLOW"
  done
}

@test "reusable workflow accepts oauth-token secret" {
  grep -E '^\s+oauth-token:' "$WORKFLOW"
}

@test "reusable workflow forwards new inputs to the composite" {
  for key in extra-allowed-tools extra-disallowed-tools mcp-config use-sticky-comment extra-env system-prompt oauth-token; do
    grep -E "^\s+${key}:" "$WORKFLOW"
  done
}

@test "reusable workflow no longer requires api-key (oauth/bedrock alternatives exist)" {
  # Confirm api-key is no longer marked as `required: true`
  awk '
    /^\s+api-key:/         { in_api=1; next }
    in_api && /^\s+\S+:/   { in_api=0 }
    in_api && /required:\s*true/ { print "FAIL: api-key required:true still present"; exit 1 }
    END { exit 0 }
  ' "$WORKFLOW"
}

@test "claude-code-action env passes ANTHROPIC_BASE_URL" {
  grep -E 'ANTHROPIC_BASE_URL:\s+\$\{\{ inputs\.api-base-url \}\}' "$COMPOSITE"
}

@test "composite carries provider switches: bedrock, vertex, foundry" {
  for k in use_bedrock use_vertex use_foundry; do
    grep -E "^\s+${k}:" "$COMPOSITE"
  done
}

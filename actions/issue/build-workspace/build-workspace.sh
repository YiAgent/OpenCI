#!/usr/bin/env bash
# Assembles the merged agent workspace from OpenCI defaults and caller overrides.
set -euo pipefail

mkdir -p agent-workspace/context/shared agent-workspace/context/issue
mkdir -p agent-workspace/skills/shared  agent-workspace/skills/issue
mkdir -p agent-workspace/runtime

copy_if_exists() {
  local src="$1" dest="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -R "$src" "$dest"
  fi
}

# OpenCI defaults first, then caller overrides (caller wins on conflict)
copy_if_exists ".openci/.github/agent/shared/context/AGENTS.md" "agent-workspace/context/shared/AGENTS.md"
copy_if_exists ".openci/.github/agent/issue/context/AGENTS.md"  "agent-workspace/context/issue/AGENTS.md"
[ -d ".openci/.github/agent/shared/skills" ] && cp .openci/.github/agent/shared/skills/*.md agent-workspace/skills/shared/ 2>/dev/null || true
[ -d ".openci/.github/agent/issue/skills"  ] && cp .openci/.github/agent/issue/skills/*.md  agent-workspace/skills/issue/  2>/dev/null || true

copy_if_exists ".github/agent/shared/context/AGENTS.md" "agent-workspace/context/shared/AGENTS.md"
copy_if_exists ".github/agent/issue/context/AGENTS.md"  "agent-workspace/context/issue/AGENTS.md"
[ -d ".github/agent/shared/skills" ] && cp .github/agent/shared/skills/*.md agent-workspace/skills/shared/ 2>/dev/null || true
[ -d ".github/agent/issue/skills"  ] && cp .github/agent/issue/skills/*.md  agent-workspace/skills/issue/  2>/dev/null || true

# Runtime files
cp .github/CODEOWNERS agent-workspace/runtime/CODEOWNERS 2>/dev/null || true
cp .mcp.json agent-workspace/runtime/mcp-config.json 2>/dev/null \
  || echo '{"mcpServers":{}}' > agent-workspace/runtime/mcp-config.json

# Merge MCP task registries (unique by name, caller wins)
jq -nc '{tasks: []}' > agent-workspace/runtime/mcp-tasks.json
merge_tasks() {
  local file="$1"
  [ -f "$file" ] || return 0
  jq -s '{tasks: ((.[0].tasks // []) + (.[1].tasks // []) | unique_by(.name))}' \
    agent-workspace/runtime/mcp-tasks.json "$file" > agent-workspace/runtime/mcp-tasks.tmp
  mv agent-workspace/runtime/mcp-tasks.tmp agent-workspace/runtime/mcp-tasks.json
}
merge_tasks ".openci/.github/agent/shared/mcp-tasks.json"
merge_tasks ".openci/.github/agent/issue/mcp-tasks.json"
merge_tasks ".github/agent/shared/mcp-tasks.json"
merge_tasks ".github/agent/issue/mcp-tasks.json"

# Live issue data
if [ -n "${ISSUE_NUMBER:-}" ]; then
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments,labels,assignees,state,url \
    > agent-workspace/runtime/issue-live.json 2>/dev/null || echo '{}' > agent-workspace/runtime/issue-live.json
  gh issue list --repo "$REPO" --state all --limit 10 --json number,title,state,labels,url \
    > agent-workspace/runtime/related-issues.json 2>/dev/null || echo '[]' > agent-workspace/runtime/related-issues.json
else
  echo '{}' > agent-workspace/runtime/issue-live.json
  echo '[]' > agent-workspace/runtime/related-issues.json
fi

# Environment capability metadata
jq -nc \
  --arg linear "${HAS_LINEAR_TOKEN:-false}" \
  --arg sentry "${HAS_SENTRY_TOKEN:-false}" \
  '{linear_token_available: ($linear == "true"), sentry_token_available: ($sentry == "true")}' \
  > agent-workspace/runtime/env-metadata.json

# Combined agent context file
jq -nc \
  --slurpfile ingest  agent-workspace/runtime/ingest.json \
  --slurpfile live    agent-workspace/runtime/issue-live.json \
  --slurpfile related agent-workspace/runtime/related-issues.json \
  --slurpfile env     agent-workspace/runtime/env-metadata.json \
  '{
    ingest: $ingest[0],
    live_issue: $live[0],
    related_issues: $related[0],
    env: $env[0],
    workspace_layout: {
      context: ["context/shared/AGENTS.md", "context/issue/AGENTS.md"],
      skills:  {shared: [], issue: []},
      mcp_tasks: "runtime/mcp-tasks.json"
    }
  }' > agent-workspace/agent-context.json

# Agent prompt
cat > agent-workspace/prompt.md <<'PROMPT'
You are the OpenCI issue agent. Read the prepared files in agent-workspace/.

Required reading:
- agent-workspace/context/shared/AGENTS.md
- agent-workspace/context/issue/AGENTS.md
- all files under agent-workspace/skills/
- agent-workspace/agent-context.json
- agent-workspace/runtime/ingest.json
- agent-workspace/runtime/mcp-tasks.json

Return exactly one JSON object and no surrounding prose:
{
  "version": "issue-action-plan/v1",
  "reasoning": "short audit explanation",
  "actions": [],
  "skip_reason": null
}

Only use skills present in agent-workspace/skills/. If no action is
needed, return an empty actions array with a skip_reason.
PROMPT

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# identify-pr-agent/identify.sh — figure out whether a PR was opened by an AI.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   PR_USER_LOGIN — github.event.pull_request.user.login
#   PR_HEAD_REF   — github.head_ref
#
# Output (stdout key=value + GITHUB_OUTPUT):
#   agent-type    — copilot | codex | openci | none
#
# This is the single source of truth for "is this PR from an AI agent?"
# Other workflows branch on `agent-type != none` to apply agent-only logic
# (e.g. P4-29 failure-feedback, P4-32 agent-review).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOGIN="${PR_USER_LOGIN:-}"
HEAD="${PR_HEAD_REF:-}"

agent="none"

case "$LOGIN" in
  copilot-swe-agent\[bot\]|copilot-swe-agent) agent="copilot" ;;
esac

if [ "$agent" = "none" ]; then
  case "$HEAD" in
    codex/*)      agent="codex"  ;;
    dev-agent/*)  agent="openci" ;;
  esac
fi

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit "agent-type" "$agent"
echo "::notice title=PR Agent::login=${LOGIN} head_ref=${HEAD} agent=${agent}"

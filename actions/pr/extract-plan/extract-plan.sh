#!/usr/bin/env bash
# Extracts a pr-action-plan/v1 JSON object from the claude-harness output.
set -euo pipefail

SKIP_PLAN='{"version":"pr-action-plan/v1","summary":"Agent skipped.","risk":"low","risk_reason":"ANTHROPIC_API_KEY not configured.","reviewer_focus":[],"actions":[],"skip_reason":"missing-anthropic-api-key"}'
FAIL_PLAN='{"version":"pr-action-plan/v1","summary":"Agent output was not parseable.","risk":"low","risk_reason":"Could not extract pr-action-plan/v1 from execution output.","reviewer_focus":[],"actions":[{"id":"escalate-unparseable","skill":"escalate","params":{"reason":"Agent output was not parseable.","labels":["needs-human"]},"confidence":"high"}],"skip_reason":null}'

if [ "${SKIPPED:-false}" = "true" ]; then
  plan="$SKIP_PLAN"
elif [ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ]; then
  raw="$(cat "$EXECUTION_FILE")"
  plan="$(printf '%s' "$raw" | jq -r '
    if type == "object" and .version == "pr-action-plan/v1" then .
    else
      [.. | strings | select(test("\"version\"[[:space:]]*:[[:space:]]*\"pr-action-plan/v1\""))] | last // empty
    end
  ' 2>/dev/null || true)"
  if [ -z "$plan" ]; then
    plan="$FAIL_PLAN"
  fi
else
  plan="$FAIL_PLAN"
fi

plan="$(jq -c . <<<"$plan")"
skip_reason="$(jq -r '.skip_reason // ""' <<<"$plan")"

{
  echo "plan<<EOF"
  echo "$plan"
  echo "EOF"
  echo "skip-reason=$skip_reason"
} >> "$GITHUB_OUTPUT"

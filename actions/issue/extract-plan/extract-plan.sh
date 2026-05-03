#!/usr/bin/env bash
# Extracts an issue-action-plan/v1 JSON object from the claude-harness output.
set -euo pipefail

SKIP_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent skipped because ANTHROPIC_API_KEY is not configured.","actions":[],"skip_reason":"missing-anthropic-api-key"}'
FAIL_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent output did not contain a parseable action plan.","actions":[{"id":"escalate-unparseable","skill":"escalate","params":{"reason":"Agent output was not parseable as issue-action-plan/v1.","labels":["needs-human"]},"risk":"low"}],"skip_reason":null}'
MISSING_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent execution file was not available.","actions":[{"id":"escalate-missing-output","skill":"escalate","params":{"reason":"Agent execution output was missing.","labels":["needs-human"]},"risk":"low"}],"skip_reason":null}'

if [ "${SKIPPED:-false}" = "true" ]; then
  plan="$SKIP_PLAN"
elif [ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ]; then
  raw="$(cat "$EXECUTION_FILE")"
  plan="$(printf '%s' "$raw" | jq -r '
    if type == "object" and .version == "issue-action-plan/v1" then .
    else
      [.. | strings | select(test("\"version\"[[:space:]]*:[[:space:]]*\"issue-action-plan/v1\""))] | last // empty
    end
  ' 2>/dev/null || true)"
  if [ -z "$plan" ]; then
    plan="$FAIL_PLAN"
  fi
else
  plan="$MISSING_PLAN"
fi

plan="$(jq -c . <<<"$plan")"
hash="$(printf '%s' "$plan" | sha256sum | awk '{print $1}')"
reasoning="$(jq -r '.reasoning // ""' <<<"$plan")"

{
  echo "action-plan<<EOF"
  echo "$plan"
  echo "EOF"
  echo "reasoning<<EOF"
  echo "$reasoning"
  echo "EOF"
  echo "plan-hash=$hash"
} >> "$GITHUB_OUTPUT"

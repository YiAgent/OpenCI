#!/usr/bin/env bash
# Usage: env -i REPO="..." ISSUE_NUM="..." ISSUE_TITLE="..." ISSUE_BODY="..." bash build-context.sh
# Builds the JSON context object passed to claude-harness for triage.
# Using jq --arg keeps all consumer fields out of shell injection paths.
set -euo pipefail

REPO="${REPO:-}"
ISSUE_NUM="${ISSUE_NUM:-}"
ISSUE_TITLE="${ISSUE_TITLE:-}"
ISSUE_BODY="${ISSUE_BODY:-}"

[ -n "$ISSUE_NUM" ] || { echo "::error::ISSUE_NUM is required and must be a positive integer" >&2; exit 1; }

jq -nc \
  --arg repo  "$REPO" \
  --arg num   "$ISSUE_NUM" \
  --arg title "$ISSUE_TITLE" \
  --arg body  "$ISSUE_BODY" \
  '{repo: $repo, issue: ($num | tonumber), title: $title, body: $body}'

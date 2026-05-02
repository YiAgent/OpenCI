#!/usr/bin/env bash
# Usage: env -i ISSUE_TITLE="..." bash extract-query.sh
# Strips conventional-commit prefix + stop-words and emits up to 6 search tokens.
set -euo pipefail

ISSUE_TITLE="${ISSUE_TITLE:-}"

query="$(printf '%s' "$ISSUE_TITLE" \
  | sed -E 's/^(bug|feat|feature|question|docs|chore|refactor|perf|ci|build|style):?[[:space:]]*//i' \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9 ' ' ' \
  | tr -s ' ' \
  | awk '{
      n=0
      for (i=1; i<=NF; i++) {
        w = $i
        if (length(w) <= 2) continue
        if (w ~ /^(the|and|for|are|but|not|you|all|can|her|was|one|our|out|how|why|with|when|from|this|that|have|been|does|need|want|some|like|just|than|then|will|into|over|also|much|most|here|them|than|onto|made|make)$/) continue
        printf("%s ", w); n++
        if (n >= 6) break
      }
    }')"

printf '%s' "$query"

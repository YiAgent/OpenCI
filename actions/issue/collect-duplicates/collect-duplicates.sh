#!/usr/bin/env bash
# Searches open issues for potential duplicates of the given title.
# Outputs a JSON array of candidates to GITHUB_OUTPUT.
set -euo pipefail

query="$(printf '%s' "$ISSUE_TITLE" \
  | sed -E 's/^(bug|feat|feature|question|docs|chore|refactor|perf|ci|build|style):?[[:space:]]*//i' \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9 ' ' ' \
  | tr -s ' ' \
  | awk '{
      n=0
      for (i=1; i<=NF; i++) {
        w=$i
        if (length(w) <= 2) continue
        if (w ~ /^(the|and|for|are|but|not|you|all|can|how|why|with|when|from|this|that|have|been|does|need|want|just|will|into|over|also|make)$/) continue
        printf("%s ", w); n++
        if (n >= 6) break
      }
    }')"
query="${query%% }"

if [ -z "$query" ]; then
  candidates='[]'
else
  candidates="$(gh search issues --repo "$REPO" --json number,title,state,url \
    --limit 5 "in:title $query" 2>/dev/null || echo '[]')"
  candidates="$(jq -c --argjson self "$ISSUE_NUM" \
    '[.[] | select(.number != $self)]' <<<"$candidates")"
fi

{
  echo "candidates<<EOF"
  echo "$candidates"
  echo "EOF"
} >> "$GITHUB_OUTPUT"

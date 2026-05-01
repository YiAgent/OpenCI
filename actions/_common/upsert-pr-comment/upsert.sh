#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# upsert.sh — single-comment-per-PR maintenance via marker.
# ─────────────────────────────────────────────────────────────────────────────
# Strategy:
#   1. List comments on the PR.
#   2. Find the one whose body contains MARKER (a hidden HTML comment).
#   3. If found → PATCH; otherwise → POST.
#
# Inputs (env):
#   GH_TOKEN  — GITHUB_TOKEN with `pull-requests: write`
#   REPO      — owner/repo (defaults to $GITHUB_REPOSITORY)
#   PR_NUMBER — PR number
#   MARKER    — HTML comment marker, e.g. "<!-- pr-summary-bot -->"
#   BODY      — full comment body (will be written verbatim)
#
# Outputs to GITHUB_OUTPUT:
#   comment-id  — id of the upserted comment
#   action      — created | updated
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
PR_NUMBER="${PR_NUMBER:-}"
MARKER="${MARKER:-}"
BODY="${BODY:-}"

for var in GH_TOKEN REPO PR_NUMBER MARKER BODY; do
  if [ -z "${!var:-}" ]; then
    echo "::error title=Upsert PR Comment::Missing required env var: $var" >&2
    exit 2
  fi
done

if ! command -v gh >/dev/null 2>&1; then
  echo "::error title=Upsert PR Comment::gh CLI is required" >&2
  exit 2
fi

# Find an existing comment containing the marker.
existing_id="$(
  gh api -X GET "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --paginate \
    --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" \
    | head -1
)"

emit_kv() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

if [ -n "$existing_id" ]; then
  result="$(gh api -X PATCH "repos/${REPO}/issues/comments/${existing_id}" \
    -f body="$BODY" --jq '.id')"
  emit_kv "comment-id" "$result"
  emit_kv "action"     "updated"
  echo "::notice title=PR Comment Updated::id=$result"
else
  result="$(gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="$BODY" --jq '.id')"
  emit_kv "comment-id" "$result"
  emit_kv "action"     "created"
  echo "::notice title=PR Comment Created::id=$result"
fi

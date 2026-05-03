#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect.sh — code-doc drift analysis for the docs agentic pipeline.
#
# Reads: DOCS_PATH, API_SPEC_PATH, API_SOURCE_PATH, GH_TOKEN, PR_NUMBER,
#        EVENT_NAME  (all set by the composite action via env:)
# Writes: GITHUB_OUTPUT  (drift-detected, api-stale, changelog-stale,
#                          needs-update)
#         docs-workspace/detect.json
#         docs-workspace/code-changes.txt   (optional, capped 30 KB)
#         docs-workspace/pr-diff.patch      (optional, PR trigger only)
#         docs-workspace/pr-files.json      (optional, PR trigger only)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

mkdir -p docs-workspace

DRIFT_DETECTED=false
API_STALE=false
CHANGELOG_STALE=false
CODE_CHANGES=""
DOC_CHANGES=""
UNRECORDED_PRS="[]"

# ── 1. Code-doc drift ────────────────────────────────────────────────────────
LAST_DOC_COMMIT=$(git log --oneline \
  -- "${DOCS_PATH}" "*.md" 2>/dev/null \
  | head -1 | awk '{print $1}' || echo "")

if [ -n "$LAST_DOC_COMMIT" ]; then
  CODE_CHANGES=$(git diff "${LAST_DOC_COMMIT}..HEAD" --name-only \
    -- "*.ts" "*.tsx" "*.js" "*.py" "*.go" "*.java" "*.rs" "*.rb" "*.php" \
    2>/dev/null \
    | grep -v -E '(test|spec|mock|fixture|__tests__)' \
    | head -50 || echo "")

  DOC_CHANGES=$(git diff "${LAST_DOC_COMMIT}..HEAD" --name-only \
    -- "*.md" "*.mdx" "${DOCS_PATH}/" \
    2>/dev/null || echo "")

  if [ -n "$CODE_CHANGES" ] && [ -z "$DOC_CHANGES" ]; then
    DRIFT_DETECTED=true
  fi
else
  # No doc history yet — flag if any code exists
  CODE_CHANGES=$(git ls-files "*.ts" "*.js" "*.py" "*.go" 2>/dev/null | head -20 || echo "")
  [ -n "$CODE_CHANGES" ] && DRIFT_DETECTED=true
fi

# Write code change contents for Agent context (capped 30 KB total)
if [ -n "$CODE_CHANGES" ]; then
  TMP_CONTENT=$(mktemp)
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ ! -f "$file" ]  && continue
    {
      echo "=== $file ==="
      head -c 2048 "$file"
      echo ""
    } >> "$TMP_CONTENT"
  done <<< "$CODE_CHANGES"
  head -c 30720 "$TMP_CONTENT" > docs-workspace/code-changes.txt
  rm -f "$TMP_CONTENT"
fi

# ── 2. API spec staleness ────────────────────────────────────────────────────
if [ -n "${API_SPEC_PATH:-}" ] && [ -f "${API_SPEC_PATH}" ]; then
  SPEC_COMMIT=$(git log -1 --format="%ct" -- "${API_SPEC_PATH}" 2>/dev/null || echo "0")
  SRC_COMMIT=$(git log -1 --format="%ct" -- "${API_SOURCE_PATH}" 2>/dev/null || echo "0")
  if [ -n "$SRC_COMMIT" ] && [ "$SRC_COMMIT" -gt "$SPEC_COMMIT" ]; then
    API_STALE=true
  fi
fi

# ── 3. Changelog staleness ───────────────────────────────────────────────────
if [ -f "CHANGELOG.md" ]; then
  LAST_CHANGELOG=$(git log -1 --format="%ct" -- CHANGELOG.md 2>/dev/null || echo "0")
  LAST_MERGE=$(git log -1 --merges --format="%ct" 2>/dev/null || echo "0")

  if [ -n "$LAST_MERGE" ] && [ "$LAST_MERGE" -gt "$LAST_CHANGELOG" ]; then
    CHANGELOG_STALE=true

    # Collect unrecorded PRs (last 20 merged) — best effort
    SINCE_ISO=$(date -d "@${LAST_CHANGELOG}" -Is 2>/dev/null \
      || date -r "${LAST_CHANGELOG}" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
      || echo "")
    if [ -n "$SINCE_ISO" ]; then
      UNRECORDED_PRS=$(gh pr list \
        --state merged \
        --limit 20 \
        --json number,title,mergedAt,labels \
        2>/dev/null \
        | jq --arg since "$SINCE_ISO" \
          '[.[] | select(.mergedAt > $since)]' \
        2>/dev/null || echo "[]")
    fi
  fi
fi

# ── 4. PR diff collection (pull_request trigger only) ───────────────────────
if [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${PR_NUMBER:-}" ]; then
  gh pr diff "$PR_NUMBER" --patch 2>/dev/null \
    | head -c 30720 > docs-workspace/pr-diff.patch || true

  gh pr view "$PR_NUMBER" --json files 2>/dev/null \
    | jq '{
        code_files: [.files[].path | select(test("\\.(ts|tsx|js|py|go|java|rs)$"))],
        doc_files:  [.files[].path | select(test("\\.(md|mdx)$"))]
      }' 2>/dev/null > docs-workspace/pr-files.json || true
fi

# ── 5. Emit outputs ──────────────────────────────────────────────────────────
if [ "$DRIFT_DETECTED" = "true" ] \
  || [ "$API_STALE" = "true" ] \
  || [ "$CHANGELOG_STALE" = "true" ]; then
  NEEDS_UPDATE=true
else
  NEEDS_UPDATE=false
fi

{
  echo "drift-detected=${DRIFT_DETECTED}"
  echo "api-stale=${API_STALE}"
  echo "changelog-stale=${CHANGELOG_STALE}"
  echo "needs-update=${NEEDS_UPDATE}"
} >> "$GITHUB_OUTPUT"

# ── 6. Write detect.json for Agent workspace ─────────────────────────────────
jq -n \
  --argjson drift     "${DRIFT_DETECTED}" \
  --argjson api       "${API_STALE}" \
  --argjson changelog "${CHANGELOG_STALE}" \
  --arg code          "${CODE_CHANGES}" \
  --arg docs          "${DOC_CHANGES}" \
  --argjson prs       "${UNRECORDED_PRS}" \
  '{
    drift_detected:   $drift,
    api_stale:        $api,
    changelog_stale:  $changelog,
    code_changes:     ($code | split("\n") | map(select(. != ""))),
    doc_changes:      ($docs | split("\n") | map(select(. != ""))),
    unrecorded_prs:   $prs
  }' > docs-workspace/detect.json

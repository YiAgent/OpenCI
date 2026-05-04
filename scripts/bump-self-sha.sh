#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bump-self-sha.sh — Update the YiAgent/OpenCI self-reference SHA.
# ─────────────────────────────────────────────────────────────────────────────
# Finds the latest commit on the main branch that contains
# .github/workflows/reusable/, then writes it to manifest.yml and all
# workflow files that reference YiAgent/OpenCI.
#
# Usage:
#   bash scripts/bump-self-sha.sh              # update in-place
#   bash scripts/bump-self-sha.sh --dry-run    # print new SHA, make no changes
#
# Requirements: git (fetch access to origin), yq, sed
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/manifest.yml"
REQUIRED_PATH=".github/workflows"
REMOTE="${REMOTE:-origin}"
BASE_BRANCH="${BASE_BRANCH:-main}"
DRY_RUN=false

for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

die() { echo "::error::$*" >&2; exit 1; }
info() { echo "  $*"; }

# ── 1. Resolve the latest remote SHA for BASE_BRANCH ─────────────────────────

info "Fetching $REMOTE/$BASE_BRANCH ..."
git fetch --quiet "$REMOTE" "$BASE_BRANCH" 2>/dev/null || \
  die "Cannot fetch $REMOTE/$BASE_BRANCH. Check your remote and network access."

remote_sha="$(git rev-parse "refs/remotes/$REMOTE/$BASE_BRANCH" 2>/dev/null)" || \
  die "Could not resolve $REMOTE/$BASE_BRANCH after fetch."

info "Remote HEAD: $remote_sha"

# ── 2. Walk back until we find a commit that has the required directory ───────

candidate="$remote_sha"
max_walk=20
walked=0

while true; do
  tree_output="$(git ls-tree "$candidate" "$REQUIRED_PATH/" 2>/dev/null || true)"
  if [ -n "$tree_output" ]; then
    break
  fi
  walked=$((walked + 1))
  if [ "$walked" -ge "$max_walk" ]; then
    die "Walked $max_walk commits back from $remote_sha without finding '$REQUIRED_PATH/'. Is the path correct?"
  fi
  # Step to parent.
  candidate="$(git rev-parse "${candidate}^" 2>/dev/null)" || \
    die "Ran out of history before finding '$REQUIRED_PATH/'."
done

if [ "$walked" -gt 0 ]; then
  echo "::warning::Remote HEAD ($remote_sha) is missing '$REQUIRED_PATH/'. Using ancestor $candidate instead (walked $walked commits back)."
fi

new_sha="$candidate"

# ── 3. Read current SHA from manifest.yml ────────────────────────────────────

if ! command -v yq >/dev/null 2>&1; then
  die "yq is required (brew install yq / apt install yq)"
fi

old_sha="$(yq -r '.deps["YiAgent/OpenCI"] // ""' "$MANIFEST")"

if [ "$old_sha" = "$new_sha" ]; then
  echo "manifest.yml already at $new_sha — nothing to do."
  exit 0
fi

echo ""
echo "  old SHA: ${old_sha:-<not set>}"
echo "  new SHA: $new_sha"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Would update manifest.yml and all workflow files."
  echo "[dry-run] Run without --dry-run to apply."
  exit 0
fi

# ── 4. Update manifest.yml ────────────────────────────────────────────────────

if [ -z "$old_sha" ]; then
  die "YiAgent/OpenCI not found in manifest.yml .deps — add it manually first."
fi

perl -pi -e "s|\Q${old_sha}\E|${new_sha}|g" "$MANIFEST"
info "Updated manifest.yml"

# ── 5. Update all workflow files that reference the old SHA ──────────────────

updated=0
while IFS= read -r -d '' f; do
  if grep -q "$old_sha" "$f" 2>/dev/null; then
    perl -pi -e "s|\Q${old_sha}\E|${new_sha}|g" "$f"
    info "Updated $f"
    updated=$((updated + 1))
  fi
done < <(find "$REPO_ROOT/.github/workflows" "$REPO_ROOT/actions" \
           -name "*.yml" -o -name "*.yaml" 2>/dev/null | tr '\n' '\0')

echo ""
echo "Done. Updated manifest.yml + $updated workflow file(s) to $new_sha"
echo "Stage and commit: git add manifest.yml .github/workflows actions/ && git commit -m 'chore(manifest): bump YiAgent/OpenCI SHA to $new_sha'"

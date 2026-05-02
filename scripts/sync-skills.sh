#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-skills.sh — validate skills/ directory structure and marketplace.json.
# ─────────────────────────────────────────────────────────────────────────────
# Checks:
#   1. Every skills/*/SKILL.md has required frontmatter (name, description)
#   2. Every skill directory is listed in marketplace.json
#   3. Every marketplace.json entry points to an existing directory
#   4. SKILL.md name field matches directory name
#
# Exit codes:
#   0 — all checks pass
#   1 — validation errors found
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/skills"
MARKETPLACE="$REPO_ROOT/marketplace.json"
errors=0

# ── Check marketplace.json exists ────────────────────────────────────────────
if [ ! -f "$MARKETPLACE" ]; then
  echo "::error title=sync-skills::marketplace.json not found at $MARKETPLACE"
  exit 1
fi

# ── Check 1: Every skills/*/SKILL.md has required frontmatter ────────────────
echo "::group::Checking SKILL.md frontmatter"
for skill_dir in "$SKILLS_DIR"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_file="$skill_dir/SKILL.md"
  dir_name="$(basename "$skill_dir")"

  if [ ! -f "$skill_file" ]; then
    echo "::error title=sync-skills::Missing SKILL.md in skills/$dir_name/"
    errors=$((errors + 1))
    continue
  fi

  # Extract frontmatter
  frontmatter="$(sed -n '/^---$/,/^---$/p' "$skill_file" | sed '1d;$d')"
  if [ -z "$frontmatter" ]; then
    echo "::error title=sync-skills::No YAML frontmatter in skills/$dir_name/SKILL.md"
    errors=$((errors + 1))
    continue
  fi

  # Check name field
  name="$(echo "$frontmatter" | grep -E '^name:' | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'")"
  if [ -z "$name" ]; then
    echo "::error title=sync-skills::Missing 'name' in frontmatter of skills/$dir_name/SKILL.md"
    errors=$((errors + 1))
  elif [ "$name" != "$dir_name" ]; then
    echo "::error title=sync-skills::Name mismatch: frontmatter says '$name' but directory is '$dir_name'"
    errors=$((errors + 1))
  fi

  # Check description field
  desc="$(echo "$frontmatter" | grep -E '^description:' | sed 's/^description:[[:space:]]*//' | tr -d '"' | tr -d "'")"
  if [ -z "$desc" ]; then
    echo "::error title=sync-skills::Missing 'description' in frontmatter of skills/$dir_name/SKILL.md"
    errors=$((errors + 1))
  fi

  echo "  OK: skills/$dir_name/SKILL.md"
done
echo "::endgroup::"

# ── Check 2: Every skill directory is listed in marketplace.json ─────────────
echo "::group::Checking marketplace coverage"
marketplace_names="$(jq -r '.plugins[].name' "$MARKETPLACE" 2>/dev/null || true)"
for skill_dir in "$SKILLS_DIR"/*/; do
  [ -d "$skill_dir" ] || continue
  dir_name="$(basename "$skill_dir")"

  if ! echo "$marketplace_names" | grep -qx "$dir_name"; then
    echo "::error title=sync-skills::skills/$dir_name/ is not listed in marketplace.json"
    errors=$((errors + 1))
  else
    echo "  OK: $dir_name in marketplace.json"
  fi
done
echo "::endgroup::"

# ── Check 3: Every marketplace entry points to existing directory ────────────
echo "::group::Checking marketplace entries"
jq -r '.plugins[] | "\(.name) \(.source)"' "$MARKETPLACE" 2>/dev/null | while IFS=' ' read -r name source; do
  # Resolve relative path
  target="$REPO_ROOT/${source#./}"
  if [ ! -d "$target" ]; then
    echo "::error title=sync-skills::marketplace entry '$name' points to '$source' which does not exist"
    errors=$((errors + 1))
  else
    echo "  OK: $name -> $source"
  fi
done
echo "::endgroup::"

# ── Summary ──────────────────────────────────────────────────────────────────
if [ "$errors" -gt 0 ]; then
  echo "::error title=sync-skills::$errors validation error(s) found"
  exit 1
fi

echo "::notice title=sync-skills::All checks passed"

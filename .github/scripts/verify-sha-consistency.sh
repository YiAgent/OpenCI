#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-sha-consistency.sh — Single-source-of-truth SHA enforcement.
# ─────────────────────────────────────────────────────────────────────────────
# Reads:
#   manifest.yml            — verified SHAs (source of truth)
#   manifest-pending.yml    — unverified entries, MUST NOT be referenced
#
# Scans:
#   .github/workflows/*.yml
#   .github/workflows/**/*.yml
#   actions/**/*.yml
#
# Enforces:
#   1. Every `uses: <action>@<ref>` for a third-party action uses a 40-char
#      lowercase hex SHA (no @v* / @main / @master / no truncated SHA).
#      Local references (`uses: ./...`) are allowed.
#   2. The SHA matches the value recorded for that action in manifest.yml.
#   3. The action is NOT listed in manifest-pending.yml (unverified).
#   4. The action is NOT in the deprecated list (SPEC Appendix B.2).
#
# Output uses GitHub Actions annotations (`::error`, `::notice`).
# Non-zero exit on any violation.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MANIFEST="${MANIFEST:-$REPO_ROOT/manifest.yml}"
PENDING="${PENDING:-$REPO_ROOT/manifest-pending.yml}"

# Self-referencing entries that need structural validation beyond SHA consistency.
# Each entry maps to the required path that must exist at the pinned SHA.
declare -A SELF_REFS
SELF_REFS["YiAgent/OpenCI"]=".github/workflows"

# SPEC Appendix B.2 — deprecated actions. Keep in sync with docs/SPEC.md.
DEPRECATED_ACTIONS=(
  "semgrep/semgrep-action"
  "amondnet/vercel-action"
)

errors=0
checked=0

emit_error() {
  local title="$1"
  local message="$2"
  echo "::error title=${title}::${message}" >&2
  errors=$((errors + 1))
}

emit_notice() {
  local title="$1"
  local message="$2"
  echo "::notice title=${title}::${message}"
}

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    emit_error "yq Missing" "Install yq (https://github.com/mikefarah/yq) to parse manifest.yml"
    exit 1
  fi
}

require_files() {
  if [ ! -f "$MANIFEST" ]; then
    emit_error "Manifest Missing" "Expected manifest.yml at $MANIFEST"
    exit 1
  fi
  if [ ! -f "$PENDING" ]; then
    emit_error "Manifest Missing" "Expected manifest-pending.yml at $PENDING"
    exit 1
  fi
}

# Build a "name<TAB>sha" lookup table from a manifest .deps map.
load_deps_map() {
  local file="$1"
  yq -r '.deps | to_entries | .[] | .key + "\t" + (.value // "")' "$file"
}

is_deprecated() {
  local action="$1"
  local entry
  for entry in "${DEPRECATED_ACTIONS[@]}"; do
    if [ "$action" = "$entry" ]; then
      return 0
    fi
  done
  return 1
}

# Collect all `uses:` lines from workflow / action yaml files.
# Output format: <relative-path>:<lineno>\t<normalized line starting with `uses:`>
# Skips local refs (./, ../).
collect_uses() {
  local search_dirs=(
    "$REPO_ROOT/.github/workflows"
    "$REPO_ROOT/actions"
  )
  local d
  for d in "${search_dirs[@]}"; do
    if [ -d "$d" ]; then
      # `-Rn` (no -h) so we keep file:line for diagnostics.
      # YAML allows step entries to begin with "- " (list item) before `uses:`.
      grep -RnE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[^[:space:]#]+@[^[:space:]#]+' "$d" 2>/dev/null \
        --include='*.yml' --include='*.yaml' \
      | awk -F':' '
          {
            file = $1
            line = $2
            # Reconstruct content (in case it contained colons).
            content = $0
            sub(/^[^:]*:[^:]*:/, "", content)
            # Strip leading whitespace and an optional "- " list-item marker.
            sub(/^[[:space:]]+/, "", content)
            sub(/^-[[:space:]]+/, "", content)
            # Skip local references (uses: ./foo or ../foo).
            if (content ~ /^uses:[[:space:]]+\.\.?\//) next
            printf "%s:%s\t%s\n", file, line, content
          }
        ' \
      || true
    fi
  done
}

main() {
  require_yq
  require_files

  local manifest_map pending_map
  manifest_map="$(load_deps_map "$MANIFEST")"
  pending_map="$(load_deps_map "$PENDING")"

  if [ -z "$manifest_map" ]; then
    emit_error "Empty Manifest" "manifest.yml has no .deps entries"
    return 1
  fi

  # Verify every entry in manifest.deps is a 40-char hex SHA.
  while IFS=$'\t' read -r name sha; do
    [ -z "$name" ] && continue
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      emit_error "Invalid Manifest SHA" "manifest.yml: $name has non-40-char-hex SHA: '$sha'"
    fi
  done <<<"$manifest_map"

  # Build pending name set (TAB-separated parses cleaner than awk-split).
  local pending_names=()
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] && pending_names+=("$name")
  done <<<"$pending_map"

  # Scan all uses: references.
  local where content action ref name
  while IFS=$'\t' read -r where content; do
    [ -z "$content" ] && continue
    checked=$((checked + 1))

    # Extract the `<action>@<ref>` portion. Strip trailing comment/whitespace.
    local raw
    raw="$(echo "$content" | sed -E 's/^uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//')"

    if ! [[ "$raw" == *"@"* ]]; then
      emit_error "Malformed uses" "$where: No @ref found in '$content'"
      continue
    fi

    action="${raw%@*}"
    ref="${raw##*@}"

    # Some actions reference subpaths: org/repo/subdir@SHA. Normalize the
    # registry name to org/repo (manifest keys never include subdir).
    name="$(echo "$action" | awk -F'/' '{ if (NF>=2) printf "%s/%s", $1, $2; else print $0 }')"

    # Reject deprecated actions outright.
    if is_deprecated "$name"; then
      emit_error "Deprecated Action" "$where: $name is in SPEC Appendix B.2 (deprecated); see docs/SPEC.md for replacement."
      continue
    fi

    # Reject @v* / @main / @master / @latest / non-40-char references.
    if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      emit_error "non-SHA uses" "$where: $name@$ref must be pinned to a 40-char commit SHA (manifest.yml)."
      continue
    fi

    # Reject references to actions in manifest-pending.yml.
    local pending_name
    for pending_name in "${pending_names[@]}"; do
      if [ "$pending_name" = "$name" ]; then
        emit_error "Pending Action Referenced" "$where: $name is in manifest-pending.yml; Migrate after verification before referencing it."
        continue 2
      fi
    done

    # Look up the manifest SHA for this action.
    # NB: previously used `echo "$manifest_map" | awk ... { print; exit }`,
    # but awk's early `exit` could trigger SIGPIPE on `echo` and kill the
    # pipeline under `set -o pipefail`. Use a here-string + shell loop so
    # there is no pipe and no SIGPIPE risk.
    local expected=""
    local m_key m_sha
    while IFS=$'\t' read -r m_key m_sha; do
      if [ "$m_key" = "$name" ]; then expected="$m_sha"; break; fi
    done <<<"$manifest_map"

    if [ -z "$expected" ]; then
      emit_error "Unknown Action" "$where: $name has no entry in manifest.yml (.deps). Add the verified SHA and rerun."
      continue
    fi

    if [ "$ref" != "$expected" ]; then
      emit_error "SHA mismatch" "$where: $name expected $expected but found $ref."
      continue
    fi
  done < <(collect_uses)

  # ── Structural validation for self-referencing entries ──────────────────────
  # Checks that the pinned SHA actually contains the required directory.
  # Catches the "SHA predates reusable/ reorganization" class of failures
  # before they reach CI (where they manifest as silent "workflow file issue").
  local self_name self_required_path self_sha tree_output m_key m_sha
  for self_name in "${!SELF_REFS[@]}"; do
    self_required_path="${SELF_REFS[$self_name]}"
    # Same SIGPIPE-avoidance pattern as the inner lookup above.
    self_sha=""
    while IFS=$'\t' read -r m_key m_sha; do
      if [ "$m_key" = "$self_name" ]; then self_sha="$m_sha"; break; fi
    done <<<"$manifest_map"
    [ -z "$self_sha" ] && continue

    # git ls-tree returns non-empty output when the path exists at that SHA.
    tree_output="$(git ls-tree "$self_sha" "$self_required_path/" 2>/dev/null || true)"
    if [ -z "$tree_output" ]; then
      emit_error "SHA Missing Structure" \
        "manifest.yml: $self_name SHA $self_sha has no '$self_required_path/' directory. Run scripts/bump-self-sha.sh to update to a valid commit."
    fi
  done

  emit_notice "verify-sha-consistency" "Checked $checked uses, $errors error(s)."

  if [ "$errors" -gt 0 ]; then
    return 1
  fi
  return 0
}

main "$@"

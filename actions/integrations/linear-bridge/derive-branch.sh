#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# linear-bridge/derive-branch.sh — derive a git branch name from Linear data.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   LINEAR_ID     — Linear issue id, e.g. AIC-123
#   LINEAR_TITLE  — Issue title
#   LINEAR_LABELS — comma-separated label names
#
# Output (stdout key=value lines + GITHUB_OUTPUT):
#   branch        — `<type>/<id-lower>-<slug>`
#                    where type ∈ {feat, fix, chore} based on labels
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ID="${LINEAR_ID:-}"
TITLE="${LINEAR_TITLE:-}"
LABELS="${LINEAR_LABELS:-}"

if [ -z "$ID" ] || [ -z "$TITLE" ]; then
  echo "::error title=Linear Bridge::LINEAR_ID and LINEAR_TITLE are required" >&2
  exit 2
fi

# type from labels.
type="chore"
labels_lower="$(printf '%s' "$LABELS" | tr '[:upper:]' '[:lower:]')"
case ",${labels_lower}," in
  *",bug,"*)         type="fix"  ;;
  *",feature,"*)     type="feat" ;;
  *",enhancement,"*) type="feat" ;;
esac

id_lower="$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')"

slug="$(printf '%s' "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:]' '-' \
  | tr -s '-' \
  | sed -E 's/^-+|-+$//g')"

# Cap slug length so the branch name stays sane.
if [ "${#slug}" -gt 50 ]; then
  slug="${slug:0:50}"
  slug="${slug%-*}"
fi

branch="${type}/${id_lower}-${slug}"
emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit "branch" "$branch"
emit "type"   "$type"
echo "::notice title=Linear Branch::id=$ID type=$type branch=$branch"

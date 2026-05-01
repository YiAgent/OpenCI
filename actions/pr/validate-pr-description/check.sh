#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-pr-description/check.sh — enforce "links to an issue" convention.
# ─────────────────────────────────────────────────────────────────────────────
# A PR passes if EITHER:
#   • the body contains `Closes #N`, `Fixes #N`, or `Resolves #N`
#     (case-insensitive, `#` may be `GH-`, repo refs accepted)
#   • the PR carries a `no-issue` label
#
# Inputs (env):
#   PR_BODY    — PR description body (may be empty)
#   PR_LABELS  — newline- or comma-separated list of label names
#
# Output: GitHub Actions annotations + exit code.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PR_BODY="${PR_BODY:-}"
PR_LABELS="${PR_LABELS:-}"

has_label() {
  local target="$1"
  printf '%s' "$PR_LABELS" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | grep -ixq "$target"
}

if has_label "no-issue"; then
  echo "::notice title=PR Description::no-issue label present — skipping issue-link check"
  exit 0
fi

# Match Closes/Fixes/Resolves followed by # or GH- and a number.
if printf '%s' "$PR_BODY" | grep -iqE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+(\[?[#]|GH-)[0-9]+'; then
  echo "::notice title=PR Description::Issue link found"
  exit 0
fi

# Also accept org/repo#N cross-repo references.
if printf '%s' "$PR_BODY" | grep -iqE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+'; then
  echo "::notice title=PR Description::Cross-repo issue link found"
  exit 0
fi

cat >&2 <<'EOF'
::error title=PR Description::Description must link an issue (Closes #N / Fixes #N / Resolves #N) or carry the `no-issue` label.
EOF
exit 1

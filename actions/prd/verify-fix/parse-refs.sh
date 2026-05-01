#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-fix/parse-refs.sh — extract Closes/Fixes/Resolves issue refs.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   PR_BODY  — PR description
# Output (stdout, GITHUB_OUTPUT):
#   refs     — comma-separated list of issue numbers (e.g. "42,17")
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BODY="${PR_BODY:-}"

refs="$(printf '%s' "$BODY" \
  | { grep -ioE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+' || true; } \
  | { grep -oE '#[0-9]+' || true; } \
  | sed 's/#//' \
  | sort -u \
  | { paste -sd, - || true; })"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit "refs" "${refs:-}"
echo "::notice title=Verify Fix Refs::${refs:-(none)}"

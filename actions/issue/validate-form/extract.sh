#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-form/extract.sh — pull form-field values from an issue body.
# ─────────────────────────────────────────────────────────────────────────────
# GitHub Issue Forms render as markdown headings + content blocks:
#
#   ### Area
#
#   frontend
#
#   ### Severity
#
#   high (cannot ship feature)
#
# This script extracts a named field's value (the lines under the heading
# until the next heading or end of body).
#
# Inputs (env):
#   ISSUE_BODY — raw issue body
#   FIELD      — field heading text (without the `###` prefix)
#
# Output: the value, trimmed of leading / trailing whitespace, on stdout.
# Empty when the field is absent.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BODY="${ISSUE_BODY:-}"
FIELD="${FIELD:-}"

if [ -z "$FIELD" ]; then
  echo "::error title=Validate Form::FIELD is required" >&2
  exit 2
fi

# awk reads the body, watches for `### <FIELD>` (case-sensitive), and
# captures lines until the next `###` heading.
value="$(printf '%s\n' "$BODY" | awk -v field="$FIELD" '
  BEGIN { capturing = 0 }
  /^###[[:space:]]+/ {
    if (capturing) { exit }
    # Strip "### " then trim trailing whitespace.
    sub(/^###[[:space:]]+/, "", $0)
    sub(/[[:space:]]+$/, "", $0)
    if ($0 == field) { capturing = 1 }
    next
  }
  capturing { print }
')"

# Trim leading + trailing blank lines.
value="$(printf '%s' "$value" | awk '
  { lines[NR] = $0 }
  END {
    start = 1
    end   = NR
    while (start <= end && lines[start] ~ /^[[:space:]]*$/) start++
    while (end   >= start && lines[end]   ~ /^[[:space:]]*$/) end--
    for (i = start; i <= end; i++) print lines[i]
  }
')"

printf '%s' "$value"

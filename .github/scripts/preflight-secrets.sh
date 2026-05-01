#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# preflight-secrets.sh — fast-fail when required secrets are missing.
# ─────────────────────────────────────────────────────────────────────────────
# Each reusable workflow in OpenCI runs this in its `preflight` job before any
# real work, so a missing secret aborts the run in <30s instead of wasting
# runner time downstream (see SPEC §5.1, §8.2).
#
# Usage:
#   preflight-secrets.sh --required "FOO,BAR" --optional "BAZ"
#
# Behaviour:
#   - Required missing  → ::error title=Missing Secret + exit 1
#   - Required present  → ::notice title=Secret Available
#   - Optional missing  → ::notice title=Optional Secret Skipped + continue
#   - Optional present  → ::notice title=Optional Secret Available
#
# Security:
#   - Never prints secret VALUES, only NAMES.
#   - Uses `set -u` so a missing `FOO` is an immediate empty-string failure
#     rather than silently expanding to nothing.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REQUIRED_CSV=""
OPTIONAL_CSV=""

usage() {
  cat >&2 <<EOF
Usage: $0 --required "CSV_LIST" [--optional "CSV_LIST"]

Examples:
  $0 --required "ANTHROPIC_API_KEY"
  $0 --required "REGISTRY_TOKEN" --optional "SONAR_TOKEN,SNYK_TOKEN"
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --required)
      REQUIRED_CSV="${2:-}"
      shift 2
      ;;
    --optional)
      OPTIONAL_CSV="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "::error title=Bad Argument::Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

emit_error() {
  echo "::error title=$1::$2" >&2
}

emit_notice() {
  echo "::notice title=$1::$2"
}

# Split a CSV string into NUL-separated names, trimming whitespace, dropping empties.
split_csv() {
  local csv="${1:-}"
  if [ -z "$csv" ]; then
    return 0
  fi
  # Use awk for portable split + trim. -v sep is a NUL char.
  printf '%s' "$csv" | awk -v RS=',' '{
    gsub(/^[ \t\n]+|[ \t\n]+$/, "", $0)
    if (length($0) > 0) printf "%s%c", $0, 0
  }'
}

errors=0

check_required() {
  local name
  while IFS= read -r -d '' name; do
    [ -z "$name" ] && continue
    # Indirect expansion with set -u — wrap in :- to avoid unbound-variable abort.
    local value="${!name:-}"
    if [ -z "$value" ]; then
      emit_error "Missing Secret" "$name"
      errors=$((errors + 1))
    else
      emit_notice "Secret Available" "$name"
    fi
  done < <(split_csv "${REQUIRED_CSV}")
}

check_optional() {
  local name
  while IFS= read -r -d '' name; do
    [ -z "$name" ] && continue
    local value="${!name:-}"
    if [ -z "$value" ]; then
      emit_notice "Optional Secret Skipped" "$name"
    else
      emit_notice "Optional Secret Available" "$name"
    fi
  done < <(split_csv "${OPTIONAL_CSV}")
}

check_required
check_optional

if [ "$errors" -gt 0 ]; then
  emit_error "Preflight Failed" "$errors required secret(s) missing"
  exit 1
fi

exit 0

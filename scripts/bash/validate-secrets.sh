#!/usr/bin/env bash
# Validate that required secrets are present.
# Usage: validate-secrets.sh SECRET1,SECRET2,SECRET3
set -euo pipefail

REQUIRED_SECRETS="${1:-}"
OPTIONAL_SECRETS="${2:-}"
MISSING=()
WARNINGS=()

if [ -z "$REQUIRED_SECRETS" ]; then
  echo "::error::No required secrets specified"
  exit 1
fi

IFS=',' read -ra SECRETS <<< "$REQUIRED_SECRETS"
for SECRET in "${SECRETS[@]}"; do
  SECRET=$(echo "$SECRET" | xargs)
  if [ -z "${!SECRET:-}" ]; then
    MISSING+=("$SECRET")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "::error::Missing required secrets: ${MISSING[*]}"
  exit 1
fi

if [ -n "$OPTIONAL_SECRETS" ]; then
  IFS=',' read -ra OPTS <<< "$OPTIONAL_SECRETS"
  for SECRET in "${OPTS[@]}"; do
    SECRET=$(echo "$SECRET" | xargs)
    if [ -z "${!SECRET:-}" ]; then
      WARNINGS+=("$SECRET")
      echo "::warning::Optional secret not set: $SECRET"
    fi
  done
fi

echo "secrets_ok=true"
echo "## Secret Validation" >> "$GITHUB_STEP_SUMMARY"
echo "- Required: ${#SECRETS[@]} checked, all present" >> "$GITHUB_STEP_SUMMARY"
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "- Optional: ${#WARNINGS[@]} missing (${WARNINGS[*]})" >> "$GITHUB_STEP_SUMMARY"
fi

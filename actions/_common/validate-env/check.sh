#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-env/check.sh — env-var presence guard from infra/ENV_MATRIX.md.
# ─────────────────────────────────────────────────────────────────────────────
# Why a markdown table? Two reasons:
#   1. The runtime owners (Doppler / SSM / 1Password) live outside the repo;
#      the table is the human-readable contract that pairs each env var to
#      its target environment(s) and source-of-truth.
#   2. .env.schema lives in node-land; ENV_MATRIX.md is language-agnostic.
#
# Expected table format (extra columns ignored):
#
#   | Var Name | Required In | Source |
#   | -------- | ----------- | ------ |
#   | DB_URL   | stg, prd    | aws-secrets |
#   | API_KEY  | dev,stg,prd | doppler |
#
# When `infra/ENV_MATRIX.md` does not exist, the gate is a no-op.
#
# Inputs (env):
#   ENV_MATRIX_PATH  — path to ENV_MATRIX.md (default: infra/ENV_MATRIX.md)
#   TARGET_ENV       — environment we are about to deploy to (dev|stg|prd|...)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV_MATRIX_PATH="${ENV_MATRIX_PATH:-infra/ENV_MATRIX.md}"
TARGET_ENV="${TARGET_ENV:-}"

if [ -z "$TARGET_ENV" ]; then
  echo "::error title=Validate Env::TARGET_ENV is required" >&2
  exit 2
fi

if [ ! -f "$ENV_MATRIX_PATH" ]; then
  echo "::notice title=Env Matrix Skipped::no ENV_MATRIX.md found at $ENV_MATRIX_PATH"
  exit 0
fi

# Parse table rows (ignore separator rows like "| --- | --- |").
# Match `| name | required-in | source |...`. Columns 4+ are tolerated.
declare -a missing=()

# shellcheck disable=SC2162
while IFS='' read -r line; do
  case "$line" in
    "|"*)
      # Skip separator rows (only `| ---` or `|:---|...`).
      if printf '%s' "$line" | grep -qE '^\|[[:space:]]*:?-+:?[[:space:]]*\|'; then continue; fi
      ;;
    *) continue ;;
  esac

  # Extract first three columns.
  name="$(printf '%s' "$line" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }')"
  scopes="$(printf '%s' "$line" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3 }')"

  # Skip empty / header rows.
  case "$name" in ""|"Var Name"|"Variable"|"var name"|"variable") continue ;; esac

  # Normalise scope list: lowercase, comma-or-space separated.
  scopes_norm="$(printf '%s' "$scopes" | tr '[:upper:],' '[:lower:] ' | tr -s '[:space:]' ' ')"

  # Does this row apply to our target env?
  applies="false"
  for s in $scopes_norm; do
    if [ "$s" = "$TARGET_ENV" ]; then applies="true"; break; fi
  done
  if [ "$applies" != "true" ]; then continue; fi

  # Indirect expansion (set -u tolerated via :- guard).
  value="${!name:-}"
  if [ -z "$value" ]; then
    missing+=("$name")
  fi
done < "$ENV_MATRIX_PATH"

if [ "${#missing[@]}" -gt 0 ]; then
  for v in "${missing[@]}"; do
    echo "::error title=Missing Env Var::$v (required in $TARGET_ENV per $ENV_MATRIX_PATH)" >&2
  done
  exit 1
fi

echo "::notice title=Env Matrix OK::all required vars present for env=$TARGET_ENV"

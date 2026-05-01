#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# observe-window/check.sh — verify enough time elapsed since stg deploy.
# ─────────────────────────────────────────────────────────────────────────────
# Pure verification; the actual waiting is owned by the dispatch chain
# (P1-12). If prd.yml is invoked too early (manual workflow_dispatch within
# the window) this script fails so the operator can either wait or
# explicitly bypass.
#
# Inputs (env):
#   STG_DEPLOY_TIME      — ISO 8601 timestamp from stg.yml output
#   OBSERVATION_MINUTES  — required minutes between stg and prd
#
# Output: success when (now - STG_DEPLOY_TIME) >= OBSERVATION_MINUTES.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STG_DEPLOY_TIME="${STG_DEPLOY_TIME:-}"
OBSERVATION_MINUTES="${OBSERVATION_MINUTES:-30}"

if [ -z "$STG_DEPLOY_TIME" ]; then
  echo "::error title=Observation Window::Missing STG_DEPLOY_TIME input" >&2
  exit 1
fi

# Convert ISO 8601 to epoch seconds (BSD `date` uses `-j -f`, GNU uses `-d`).
to_epoch() {
  local ts="$1"
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null; then
    return
  fi
  if date -u -d "$ts" +%s 2>/dev/null; then
    return
  fi
  echo "::error title=Observation Window::Cannot parse timestamp '$ts'" >&2
  exit 1
}

stg_epoch="$(to_epoch "$STG_DEPLOY_TIME")"
now_epoch="$(date -u +%s)"
elapsed_min=$(( (now_epoch - stg_epoch) / 60 ))

if [ "$elapsed_min" -lt "$OBSERVATION_MINUTES" ]; then
  cat >&2 <<EOF
::error title=Observation Window Too Early::elapsed=${elapsed_min}min required=${OBSERVATION_MINUTES}min stg=${STG_DEPLOY_TIME}
EOF
  exit 1
fi

echo "::notice title=Observation Window OK::elapsed=${elapsed_min}min required=${OBSERVATION_MINUTES}min"

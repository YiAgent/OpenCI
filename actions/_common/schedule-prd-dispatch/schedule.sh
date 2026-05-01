#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# schedule-prd-dispatch/schedule.sh — append a pending entry to the queue.
# ─────────────────────────────────────────────────────────────────────────────
# State-store: a GitHub Variable named PENDING_PRD_DISPATCHES holding a
# JSON array. Each entry:
#   {
#     "fire_at":          "<ISO 8601, UTC>",
#     "image_digest":     "<sha256:...>",
#     "stg_image_digest": "<sha256:...>",
#     "stg_deploy_time":  "<ISO 8601>",
#     "image_name":       "...",
#     "app_name":         "...",
#     "queued_at":        "<ISO 8601>"
#   }
#
# The companion poll.sh reads this var on a cron, fires the entries whose
# fire_at has passed, and rewrites the var without them.
#
# Inputs (env):
#   GH_TOKEN, REPO, IMAGE_DIGEST, STG_IMAGE_DIGEST, STG_DEPLOY_TIME,
#   OBSERVATION_MINUTES, IMAGE_NAME, APP_NAME
#
# QUEUE_OVERRIDE (test-only): when set to a JSON array string, the script
# uses it as the existing queue instead of reading the GitHub Variable;
# also writes the resulting queue to QUEUE_OUT_FILE if set, instead of
# calling `gh variable set`. This makes the script bats-testable without
# a live GitHub.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

require() {
  if [ -z "${!1:-}" ]; then
    echo "::error title=Schedule PRD Dispatch::missing required env $1" >&2
    exit 2
  fi
}
require IMAGE_DIGEST
require STG_IMAGE_DIGEST
require STG_DEPLOY_TIME
require IMAGE_NAME
require APP_NAME

: "${OBSERVATION_MINUTES:=30}"

# Compute fire_at = STG_DEPLOY_TIME + OBSERVATION_MINUTES.
to_epoch() {
  local ts="$1"
  if date -u -d "$ts" +%s 2>/dev/null; then return; fi
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null; then return; fi
  echo "::error title=Schedule PRD Dispatch::cannot parse STG_DEPLOY_TIME='$ts'" >&2
  exit 2
}
stg_epoch="$(to_epoch "$STG_DEPLOY_TIME")"
fire_epoch=$(( stg_epoch + OBSERVATION_MINUTES * 60 ))

format_ts() {
  local epoch="$1"
  if date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then return; fi
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}
fire_at="$(format_ts "$fire_epoch")"
queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Read existing queue.
if [ -n "${QUEUE_OVERRIDE:-}" ]; then
  current="$QUEUE_OVERRIDE"
elif [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  current="$(gh api "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" \
    --jq '.value' 2>/dev/null || echo '[]')"
  [ -z "$current" ] && current='[]'
else
  current='[]'
fi

# Validate it's a JSON array; reset on corruption.
if ! jq -e 'type == "array"' <<<"$current" >/dev/null 2>&1; then
  echo "::warning title=Schedule PRD Dispatch::existing queue not a JSON array; resetting"
  current='[]'
fi

# Build the new entry.
entry="$(jq -nc \
  --arg fire_at "$fire_at" \
  --arg digest "$IMAGE_DIGEST" \
  --arg stgd "$STG_IMAGE_DIGEST" \
  --arg stgt "$STG_DEPLOY_TIME" \
  --arg img "$IMAGE_NAME" \
  --arg app "$APP_NAME" \
  --arg q "$queued_at" \
  '{fire_at:$fire_at, image_digest:$digest, stg_image_digest:$stgd,
    stg_deploy_time:$stgt, image_name:$img, app_name:$app, queued_at:$q}')"

# Dedupe by image_digest — re-queueing the same digest replaces the
# earlier entry (newer fire_at wins).
new_queue="$(jq -c --argjson e "$entry" \
  'map(select(.image_digest != $e.image_digest)) + [$e]' <<<"$current")"

# Write back.
if [ -n "${QUEUE_OUT_FILE:-}" ]; then
  printf '%s\n' "$new_queue" > "$QUEUE_OUT_FILE"
elif [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  if gh api "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" >/dev/null 2>&1; then
    gh api -X PATCH "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" \
      -f name=PENDING_PRD_DISPATCHES -f value="$new_queue" >/dev/null
  else
    gh api -X POST "repos/${REPO}/actions/variables" \
      -f name=PENDING_PRD_DISPATCHES -f value="$new_queue" >/dev/null
  fi
else
  echo "::warning title=Schedule PRD Dispatch::no gh + no QUEUE_OUT_FILE; queue not persisted"
fi

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit "fire-at"     "$fire_at"
emit "queue-size"  "$(jq 'length' <<<"$new_queue")"
echo "::notice title=PRD Dispatch Scheduled::digest=$IMAGE_DIGEST fire_at=$fire_at"

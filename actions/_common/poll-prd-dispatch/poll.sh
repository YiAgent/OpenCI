#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# poll-prd-dispatch/poll.sh — fire pending dispatches whose fire_at passed.
# ─────────────────────────────────────────────────────────────────────────────
# Reads the PENDING_PRD_DISPATCHES GitHub Variable, splits into:
#   • due:      entries with fire_at <= now      → repository_dispatch
#   • pending:  entries with fire_at >  now      → write back to the variable
#
# Each due entry triggers a `repository_dispatch` of type
# `observe-window-complete` carrying the image / stg metadata.
#
# Test mode: set QUEUE_OVERRIDE to a JSON array to bypass GitHub. The
# script writes the kept (still-pending) queue to QUEUE_OUT_FILE and
# the fired entries to FIRED_OUT_FILE so bats can inspect both.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

now_epoch="$(date -u +%s)"

# Load the queue.
if [ -n "${QUEUE_OVERRIDE:-}" ]; then
  current="$QUEUE_OVERRIDE"
elif [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  current="$(gh api "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" \
    --jq '.value' 2>/dev/null || echo '[]')"
  [ -z "$current" ] && current='[]'
else
  current='[]'
fi

if ! jq -e 'type == "array"' <<<"$current" >/dev/null 2>&1; then
  echo "::warning title=Poll PRD Dispatch::queue not a JSON array; resetting"
  current='[]'
fi

# Helper: convert ISO 8601 to epoch.
to_epoch() {
  local ts="$1"
  if date -u -d "$ts" +%s 2>/dev/null; then return; fi
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null; then return; fi
  echo ""
}

# Split by fire_at.
fired='[]'
kept='[]'
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  fire_at="$(jq -r '.fire_at' <<<"$entry")"
  fire_epoch="$(to_epoch "$fire_at")"
  if [ -z "$fire_epoch" ] || [ "$fire_epoch" -le "$now_epoch" ]; then
    fired="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$fired")"
  else
    kept="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$kept")"
  fi
done < <(jq -c '.[]' <<<"$current")

# Persist kept queue.
if [ -n "${QUEUE_OUT_FILE:-}" ]; then
  printf '%s\n' "$kept" > "$QUEUE_OUT_FILE"
elif [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  if gh api "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" >/dev/null 2>&1; then
    gh api -X PATCH "repos/${REPO}/actions/variables/PENDING_PRD_DISPATCHES" \
      -f name=PENDING_PRD_DISPATCHES -f value="$kept" >/dev/null
  else
    gh api -X POST "repos/${REPO}/actions/variables" \
      -f name=PENDING_PRD_DISPATCHES -f value="$kept" >/dev/null
  fi
fi

# Stash fired entries for the workflow to dispatch.
if [ -n "${FIRED_OUT_FILE:-}" ]; then
  printf '%s\n' "$fired" > "$FIRED_OUT_FILE"
fi

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit "fired-count" "$(jq 'length' <<<"$fired")"
emit "kept-count"  "$(jq 'length' <<<"$kept")"
emit "fired"       "$fired"
echo "::notice title=Poll PRD Dispatch::fired=$(jq 'length' <<<"$fired") kept=$(jq 'length' <<<"$kept")"

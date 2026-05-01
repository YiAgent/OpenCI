#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# evaluate.sh — Sentry Stats v2 → error-rate threshold judgment.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   STATS_TOTAL_JSON     — JSON returned for `field=sum(quantity) groupBy=outcome`
#   STATS_ERROR_JSON     — same query but filtered to error-category outcomes
#                          (the action will fetch both; for tests we accept files
#                          on disk via STATS_TOTAL_FILE / STATS_ERROR_FILE).
#   BASELINE_ERROR_RATE  — e.g. "0.005"
#   THRESHOLD_MULTIPLIER — e.g. "2.0" → real threshold = baseline * multiplier
#   MIN_EVENTS           — below this, skip the gate (low-traffic envs)
#
# Outputs (stdout key=value lines + GITHUB_OUTPUT when present):
#   total-events         — accepted events in the window
#   error-events         — events with error-category outcome
#   error-rate           — error / total (4 decimals)
#   threshold            — the computed pass threshold
#   passed               — true | false  (true means deploy may proceed)
#
# Exit codes:
#   0 — passed (or skipped with passed=true)
#   1 — failed (rate > threshold)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASELINE="${BASELINE_ERROR_RATE:-0.005}"
MULTIPLIER="${THRESHOLD_MULTIPLIER:-2.0}"
MIN_EVENTS="${MIN_EVENTS:-100}"

if ! command -v jq >/dev/null 2>&1; then
  echo "::error title=Check Error Rate::jq is required" >&2
  exit 2
fi
if ! command -v bc >/dev/null 2>&1; then
  echo "::error title=Check Error Rate::bc is required" >&2
  exit 2
fi

# Allow tests to feed JSON via files instead of inline strings.
total_json="${STATS_TOTAL_JSON:-}"
if [ -z "$total_json" ] && [ -n "${STATS_TOTAL_FILE:-}" ] && [ -f "$STATS_TOTAL_FILE" ]; then
  total_json="$(cat "$STATS_TOTAL_FILE")"
fi
error_json="${STATS_ERROR_JSON:-}"
if [ -z "$error_json" ] && [ -n "${STATS_ERROR_FILE:-}" ] && [ -f "$STATS_ERROR_FILE" ]; then
  error_json="$(cat "$STATS_ERROR_FILE")"
fi

if [ -z "$total_json" ]; then
  echo "::error title=Check Error Rate::Missing STATS_TOTAL_JSON / STATS_TOTAL_FILE" >&2
  exit 2
fi
if [ -z "$error_json" ]; then
  echo "::error title=Check Error Rate::Missing STATS_ERROR_JSON / STATS_ERROR_FILE" >&2
  exit 2
fi

# Sum over outcome=accepted; tolerates missing fields.
sum_accepted() {
  local payload="$1"
  jq -r '
    .groups // []
    | map(select(.by.outcome == "accepted") | .totals["sum(quantity)"] // 0)
    | add // 0
  ' <<<"$payload"
}

total="$(sum_accepted "$total_json")"
errors="$(sum_accepted "$error_json")"

# Default to 0 when jq returns "null" or empty.
total="${total:-0}"
errors="${errors:-0}"

emit_kv() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit_kv "total-events" "$total"
emit_kv "error-events" "$errors"

# Low-traffic skip: don't fail deploys when the sample is too small.
if [ "$(echo "$total < $MIN_EVENTS" | bc -l)" = "1" ]; then
  emit_kv "error-rate" "0"
  emit_kv "threshold"  "$(echo "$BASELINE * $MULTIPLIER" | bc -l)"
  emit_kv "passed"     "true"
  echo "::notice title=Error Rate Check Skipped::events=$total < min=$MIN_EVENTS"
  exit 0
fi

rate="$(echo "scale=4; $errors / $total" | bc -l)"
threshold="$(echo "scale=4; $BASELINE * $MULTIPLIER" | bc -l)"

emit_kv "error-rate" "$rate"
emit_kv "threshold"  "$threshold"

# bc returns 1 for true, 0 for false.
if [ "$(echo "$rate > $threshold" | bc -l)" = "1" ]; then
  emit_kv "passed" "false"
  echo "::error title=Error Rate Exceeded::rate=$rate threshold=$threshold events=$total"
  exit 1
fi

emit_kv "passed" "true"
echo "::notice title=Error Rate OK::rate=$rate threshold=$threshold events=$total"

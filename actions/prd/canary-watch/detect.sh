#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# canary-watch/detect.sh — 3σ deviation detector.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env or files):
#   CURRENT_RATE     — current error rate (float, e.g. "0.012")
#   HISTORY_RATES    — newline-separated rates from the last 7 days at
#                      the same time-of-day window (used for baseline)
#                      OR HISTORY_FILE → file with one rate per line
#
# Logic:
#   mean = avg(history)
#   sd   = stddev(history)
#   threshold = mean + 3 * sd
#   regression = (current > threshold)
#
# Outputs:
#   mean / stddev / threshold / current / regression(true|false)
# Exit 1 only when REGRESSION_FAILS=true (default false → advisory mode).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CURRENT="${CURRENT_RATE:-}"
if [ -z "$CURRENT" ]; then
  echo "::error title=Canary Watch::CURRENT_RATE is required" >&2
  exit 2
fi

if [ -z "${HISTORY_RATES:-}" ] && [ -n "${HISTORY_FILE:-}" ] && [ -f "${HISTORY_FILE}" ]; then
  HISTORY_RATES="$(cat "$HISTORY_FILE")"
fi
if [ -z "${HISTORY_RATES:-}" ]; then
  echo "::notice title=Canary Watch::no history → cannot compute baseline; passing"
  echo "regression=false"
  exit 0
fi

# Compute mean + std dev with awk (no bc dependency for variance).
read -r mean sd <<< "$(printf '%s\n' "$HISTORY_RATES" \
  | awk '
    NF {
      x = $1 + 0
      n++
      sum   += x
      sumsq += x * x
    }
    END {
      if (n < 2) { print sum / (n ? n : 1), 0; exit }
      mean = sum / n
      var  = (sumsq - n * mean * mean) / (n - 1)
      if (var < 0) var = 0
      printf "%.6f %.6f", mean, sqrt(var)
    }')"

threshold="$(awk -v m="$mean" -v s="$sd" 'BEGIN { printf "%.6f", m + 3 * s }')"
regression="$(awk -v c="$CURRENT" -v t="$threshold" 'BEGIN { print (c+0 > t+0) ? "true" : "false" }')"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit "mean"       "$mean"
emit "stddev"     "$sd"
emit "threshold"  "$threshold"
emit "current"    "$CURRENT"
emit "regression" "$regression"

if [ "$regression" = "true" ]; then
  echo "::warning title=Canary 3σ Regression::current=$CURRENT mean=$mean sd=$sd threshold=$threshold"
  if [ "${REGRESSION_FAILS:-false}" = "true" ]; then exit 1; fi
else
  echo "::notice title=Canary OK::current=$CURRENT mean=$mean sd=$sd threshold=$threshold"
fi

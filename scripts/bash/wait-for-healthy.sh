#!/usr/bin/env bash
# Wait for a service to become healthy.
# Usage: wait-for-healthy.sh URL [timeout_seconds] [interval_seconds]
set -euo pipefail

URL="${1:?Usage: wait-for-healthy.sh URL [timeout] [interval]}"
TIMEOUT="${2:-120}"
INTERVAL="${3:-5}"

echo "Waiting for $URL to become healthy (timeout: ${TIMEOUT}s)..."

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    echo "Service healthy after ${ELAPSED}s (HTTP $HTTP_CODE)"
    echo "wait_time=$ELAPSED" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "  [${ELAPSED}s] HTTP $HTTP_CODE — retrying in ${INTERVAL}s..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "::error::Service at $URL not healthy after ${TIMEOUT}s"
echo "wait_time=$TIMEOUT" >> "$GITHUB_OUTPUT"
exit 1

#!/usr/bin/env bash
# Usage: env -i SONAR_TOKEN="..." bash check-token.sh
# Writes skip=true/false to GITHUB_OUTPUT (when set) and echoes skip= line.
set -euo pipefail

SONAR_TOKEN="${SONAR_TOKEN:-}"

if [ -z "${SONAR_TOKEN// }" ]; then
  skip="true"
  echo "::notice title=SonarCloud Skipped::SONAR_TOKEN not configured, graceful skip"
else
  skip="false"
fi

out="${GITHUB_OUTPUT:-}"
[ -n "$out" ] && echo "skip=$skip" >> "$out"
echo "skip=$skip"

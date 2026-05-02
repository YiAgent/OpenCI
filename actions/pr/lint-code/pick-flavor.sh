#!/usr/bin/env bash
# Usage: env -i LANGUAGE=node bash pick-flavor.sh
# Selects the MegaLinter flavor for the detected language.
# Writes flavor=<value> to GITHUB_OUTPUT (when set) and echoes it.
set -euo pipefail

LANGUAGE="${LANGUAGE:-}"

case "$LANGUAGE" in
  node|javascript|typescript) flavor="javascript" ;;
  python)                     flavor="python"     ;;
  go)                         flavor="go"         ;;
  java|kotlin)                flavor="java"       ;;
  *)                          flavor="ci_light"   ;;
esac

out="${GITHUB_OUTPUT:-}"
[ -n "$out" ] && echo "flavor=$flavor" >> "$out"
echo "::notice title=MegaLinter Flavor::language=$LANGUAGE flavor=$flavor"
echo "flavor=$flavor"

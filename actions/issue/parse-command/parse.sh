#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# parse-command/parse.sh — extract a slash command from an issue comment.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   COMMENT_BODY     — comment body (may be multi-line)
#   AUTHOR_ASSOC     — github.event.comment.author_association
#                       (OWNER / MEMBER / COLLABORATOR / CONTRIBUTOR / ...)
#
# Outputs (stdout key=value lines + GITHUB_OUTPUT when present):
#   command          — assign | unassign | label | unlabel | priority |
#                      close | reopen | duplicate | needs-info | triage |
#                      help | none
#   args             — remaining tokens (e.g. "@user", "p1", "#42")
#   authorized       — true | false  (false → execute step should refuse)
#
# Authorization model (matches SPEC §6.3):
#   • OWNER / MEMBER / COLLABORATOR can run any command.
#   • Anyone can run `/help`.
#   • Other associations get authorized=false.
#
# Exit code is always 0 — the WORKFLOW decides what to do based on
# `command` and `authorized`. We don't fail just because there's no command.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BODY="${COMMENT_BODY:-}"
ASSOC="${AUTHOR_ASSOC:-NONE}"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Extract the first line that starts with `/` (command).
line="$(printf '%s\n' "$BODY" | awk '/^[[:space:]]*\/[a-z-]+/ { print; exit }')"
if [ -z "$line" ]; then
  emit "command"    "none"
  emit "args"       ""
  emit "authorized" "false"
  exit 0
fi

# Strip leading whitespace then split on first space.
stripped="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
cmd_token="${stripped%% *}"
args_raw=""
if [ "$stripped" != "$cmd_token" ]; then
  args_raw="${stripped#"${cmd_token} "}"
fi

# Drop the leading `/`.
cmd="${cmd_token#/}"

# Allow-list. Anything else is treated as `none`.
case "$cmd" in
  assign|unassign|label|unlabel|priority|close|reopen|duplicate|needs-info|triage|help) ;;
  *)
    emit "command"    "none"
    emit "args"       ""
    emit "authorized" "false"
    exit 0
    ;;
esac

# Trim trailing whitespace from args.
args="$(printf '%s' "$args_raw" | sed -E 's/[[:space:]]+$//')"

# Authorization.
if [ "$cmd" = "help" ]; then
  authorized="true"
else
  case "$ASSOC" in
    OWNER|MEMBER|COLLABORATOR) authorized="true"  ;;
    *)                          authorized="false" ;;
  esac
fi

emit "command"    "$cmd"
emit "args"       "$args"
emit "authorized" "$authorized"

if [ "$authorized" = "false" ]; then
  echo "::notice title=Unauthorized Command::user=${ASSOC} cmd=/${cmd}"
fi

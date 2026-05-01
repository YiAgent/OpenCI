#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# resolve-prompt.sh — locate the prompt file for a claude-harness invocation.
# ─────────────────────────────────────────────────────────────────────────────
# Priority (SPEC §5.1):
#   1. CALLER_PROMPT_PATH (caller-supplied, relative to consumer repo) — if
#      the file exists, use it. Empty / missing means "fall through".
#   2. Built-in $ACTION_DIR/../../../prompts/$TASK.md.
#   3. Hard error if neither exists, so we never silently send Claude an
#      empty prompt.
#
# Usage:
#   resolve-prompt.sh <task> <caller-prompt-path> <action-dir>
#
# Outputs:
#   Prints the resolved absolute path to stdout. Sets RESOLVED_PROMPT in
#   GITHUB_OUTPUT when present.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TASK="${1:-}"
CALLER_PROMPT_PATH="${2:-}"
ACTION_DIR="${3:-}"

if [ -z "$TASK" ]; then
  echo "::error title=resolve-prompt::Missing required <task> argument" >&2
  exit 2
fi
if [ -z "$ACTION_DIR" ]; then
  echo "::error title=resolve-prompt::Missing required <action-dir> argument" >&2
  exit 2
fi

# Repository where the consumer's checkout lives. claude-code-action is normally
# run after `actions/checkout`, so $GITHUB_WORKSPACE points at the consumer code.
CONSUMER_ROOT="${GITHUB_WORKSPACE:-$PWD}"

resolve_caller_path() {
  local p="$1"
  # Absolute path: keep as-is.
  case "$p" in /*) printf '%s' "$p"; return ;; esac
  # Relative path: anchor at consumer repo root.
  printf '%s/%s' "$CONSUMER_ROOT" "$p"
}

resolved=""
source=""

if [ -n "$CALLER_PROMPT_PATH" ]; then
  candidate="$(resolve_caller_path "$CALLER_PROMPT_PATH")"
  if [ -f "$candidate" ]; then
    resolved="$candidate"
    source="caller"
  else
    echo "::error title=Prompt Not Found::Caller-supplied prompt-path '$CALLER_PROMPT_PATH' resolved to '$candidate' but the file does not exist." >&2
    exit 1
  fi
fi

if [ -z "$resolved" ]; then
  builtin="${ACTION_DIR%/}/../../../prompts/${TASK}.md"
  if [ -f "$builtin" ]; then
    # Normalise path (no .. segments).
    resolved="$(cd "$(dirname "$builtin")" && pwd)/$(basename "$builtin")"
    source="builtin"
  fi
fi

if [ -z "$resolved" ]; then
  echo "::error title=Prompt Not Found::No prompt for task '$TASK' (caller-path empty and no built-in prompts/${TASK}.md)" >&2
  exit 1
fi

echo "::notice title=AI Prompt Resolved::task=$TASK source=$source path=$resolved"
printf '%s\n' "$resolved"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'resolved-prompt=%s\n' "$resolved" >> "$GITHUB_OUTPUT"
  printf 'prompt-source=%s\n' "$source"     >> "$GITHUB_OUTPUT"
fi

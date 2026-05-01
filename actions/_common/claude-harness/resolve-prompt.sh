#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# resolve-prompt.sh — locate or resolve the prompt for a claude-harness invocation.
# ─────────────────────────────────────────────────────────────────────────────
# Signature (4 args): <task> <direct-prompt> <caller-prompt-path> <action-dir>
#
# Priority:
#   1. DIRECT_PROMPT — non-empty text or /slash-command.
#      /slash-command → resolve .claude/commands/<cmd>.md (from consumer repo)
#      plain text     → write to a temp file (always returns a file path)
#   2. CALLER_PROMPT_PATH — file path in consumer repo.
#   3. Built-in $ACTION_DIR/../../../prompts/$TASK.md.
#   4. Hard error if none found.
#
# Outputs (GITHUB_OUTPUT):
#   resolved-prompt-text  — set only when source=direct (the original text)
#   resolved-prompt-file  — absolute path to the resolved prompt file (always set)
#   prompt-source         — "direct" | "slash-command" | "caller" | "builtin"
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TASK="${1:-}"
DIRECT_PROMPT="${2:-}"
CALLER_PROMPT_PATH="${3:-}"
ACTION_DIR="${4:-}"

if [ -z "$TASK" ]; then
  echo "::error title=resolve-prompt::Missing required <task> argument" >&2
  exit 2
fi
if [ -z "$ACTION_DIR" ]; then
  echo "::error title=resolve-prompt::Missing required <action-dir> argument" >&2
  exit 2
fi

CONSUMER_ROOT="${GITHUB_WORKSPACE:-$PWD}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

resolved_text=""
resolved_file=""
source=""

# Priority 1: direct prompt text or slash command
if [ -n "$DIRECT_PROMPT" ]; then
  case "$DIRECT_PROMPT" in
    /*)
      # Slash command — resolve to .claude/commands/<cmd>.md in consumer repo
      cmd_name="${DIRECT_PROMPT#/}"
      cmd_file="$CONSUMER_ROOT/.claude/commands/${cmd_name}.md"
      if [ -f "$cmd_file" ]; then
        resolved_file="$cmd_file"
        source="slash-command"
        echo "::notice title=AI Prompt Resolved::task=$TASK source=slash-command path=$cmd_file"
      else
        echo "::error title=Prompt Not Found::Slash command '$DIRECT_PROMPT' has no file at '$cmd_file'" >&2
        exit 1
      fi
      ;;
    *)
      # Plain text — record original text, also write to temp file for claude-code-action
      resolved_text="$DIRECT_PROMPT"
      tmp_file="$RUNNER_TEMP/claude-prompt-${TASK##*/}-$$.md"
      printf '%s\n' "$DIRECT_PROMPT" > "$tmp_file"
      resolved_file="$tmp_file"
      source="direct"
      echo "::notice title=AI Prompt Resolved::task=$TASK source=direct"
      ;;
  esac
fi

# Priority 2: caller-supplied file path
if [ -z "$resolved_file" ] && [ -n "$CALLER_PROMPT_PATH" ]; then
  case "$CALLER_PROMPT_PATH" in
    /*) candidate="$CALLER_PROMPT_PATH" ;;
    *)  candidate="$CONSUMER_ROOT/$CALLER_PROMPT_PATH" ;;
  esac
  if [ -f "$candidate" ]; then
    resolved_file="$candidate"
    source="caller"
    echo "::notice title=AI Prompt Resolved::task=$TASK source=caller path=$candidate"
  else
    echo "::error title=Prompt Not Found::Caller-supplied prompt-path '$CALLER_PROMPT_PATH' resolved to '$candidate' but the file does not exist." >&2
    exit 1
  fi
fi

# Priority 3: built-in prompt
if [ -z "$resolved_file" ]; then
  builtin="${ACTION_DIR%/}/../../../prompts/${TASK}.md"
  if [ -f "$builtin" ]; then
    resolved_file="$(cd "$(dirname "$builtin")" && pwd)/$(basename "$builtin")"
    source="builtin"
    echo "::notice title=AI Prompt Resolved::task=$TASK source=builtin path=$resolved_file"
  fi
fi

if [ -z "$resolved_file" ]; then
  echo "::error title=Prompt Not Found::No prompt for task '$TASK' (checked: direct prompt, caller-path='$CALLER_PROMPT_PATH', built-in prompts/${TASK}.md)" >&2
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'resolved-prompt-text=%s\n' "$resolved_text" >> "$GITHUB_OUTPUT"
  printf 'resolved-prompt-file=%s\n' "$resolved_file"  >> "$GITHUB_OUTPUT"
  printf 'prompt-source=%s\n'        "$source"          >> "$GITHUB_OUTPUT"
fi

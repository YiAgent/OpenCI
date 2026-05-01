#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# resolve-prompt.sh — locate, load, and template the prompt for claude-harness.
# ─────────────────────────────────────────────────────────────────────────────
# Signature (5 args):
#   <task> <direct-prompt> <caller-prompt-path> <action-dir> <context-json>
#
# Why this script exists:
#   claude-code-action@v1.x exposes only `prompt:` (string) — there is no
#   `prompt_file` or `prompt_inputs`. We therefore: (1) resolve the source
#   file according to the priority chain below, (2) read it into memory,
#   (3) perform Mustache-style {{var}} substitution from the caller's JSON
#   context plus auto-injected GitHub vars, and (4) emit the rendered text
#   as a multi-line GITHUB_OUTPUT value the harness can pass straight to
#   `prompt:`.
#
# Priority:
#   1. DIRECT_PROMPT — non-empty text or /slash-command.
#      /slash-command → resolves to .claude/commands/<cmd>.md (consumer repo)
#      plain text     → used as-is
#   2. CALLER_PROMPT_PATH — file path in consumer repo.
#   3. Built-in $ACTION_DIR/../../../prompts/$TASK.md.
#   4. Hard error if none found.
#
# GITHUB_OUTPUT keys:
#   prompt-source   — direct | slash-command | caller | builtin
#   prompt-path     — absolute file path of the source (empty for direct text)
#   prompt          — multi-line, Mustache-rendered final prompt text
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TASK="${1:-}"
DIRECT_PROMPT="${2:-}"
CALLER_PROMPT_PATH="${3:-}"
ACTION_DIR="${4:-}"
CONTEXT_JSON="${5:-{\}}"

if [ -z "$TASK" ]; then
  echo "::error title=resolve-prompt::Missing required <task> argument" >&2
  exit 2
fi
if [ -z "$ACTION_DIR" ]; then
  echo "::error title=resolve-prompt::Missing required <action-dir> argument" >&2
  exit 2
fi

CONSUMER_ROOT="${GITHUB_WORKSPACE:-$PWD}"

resolved_path=""
raw_text=""
source=""

# ── Priority 1: direct prompt text or slash command ──────────────────────────
if [ -n "$DIRECT_PROMPT" ]; then
  case "$DIRECT_PROMPT" in
    /*)
      cmd_name="${DIRECT_PROMPT#/}"
      cmd_file="$CONSUMER_ROOT/.claude/commands/${cmd_name}.md"
      if [ -f "$cmd_file" ]; then
        resolved_path="$cmd_file"
        raw_text="$(cat "$cmd_file")"
        source="slash-command"
        echo "::notice title=AI Prompt Resolved::task=$TASK source=slash-command path=$cmd_file"
      else
        echo "::error title=Prompt Not Found::Slash command '$DIRECT_PROMPT' has no file at '$cmd_file'" >&2
        exit 1
      fi
      ;;
    *)
      raw_text="$DIRECT_PROMPT"
      source="direct"
      echo "::notice title=AI Prompt Resolved::task=$TASK source=direct"
      ;;
  esac
fi

# ── Priority 2: caller-supplied file path ────────────────────────────────────
if [ -z "$source" ] && [ -n "$CALLER_PROMPT_PATH" ]; then
  case "$CALLER_PROMPT_PATH" in
    /*) candidate="$CALLER_PROMPT_PATH" ;;
    *)  candidate="$CONSUMER_ROOT/$CALLER_PROMPT_PATH" ;;
  esac
  if [ -f "$candidate" ]; then
    resolved_path="$candidate"
    raw_text="$(cat "$candidate")"
    source="caller"
    echo "::notice title=AI Prompt Resolved::task=$TASK source=caller path=$candidate"
  else
    echo "::error title=Prompt Not Found::Caller-supplied prompt-path '$CALLER_PROMPT_PATH' resolved to '$candidate' but the file does not exist." >&2
    exit 1
  fi
fi

# ── Priority 3: built-in prompt ──────────────────────────────────────────────
if [ -z "$source" ]; then
  builtin="${ACTION_DIR%/}/../../../prompts/${TASK}.md"
  if [ -f "$builtin" ]; then
    resolved_path="$(cd "$(dirname "$builtin")" && pwd)/$(basename "$builtin")"
    raw_text="$(cat "$resolved_path")"
    source="builtin"
    echo "::notice title=AI Prompt Resolved::task=$TASK source=builtin path=$resolved_path"
  fi
fi

if [ -z "$source" ]; then
  echo "::error title=Prompt Not Found::No prompt for task '$TASK' (checked: direct prompt, caller-path='$CALLER_PROMPT_PATH', built-in prompts/${TASK}.md)" >&2
  exit 1
fi

# ── Mustache substitution ────────────────────────────────────────────────────
# Auto-injected vars (overridden if context provides the same key):
#   repo, run_id, run_url, event_name, ref, sha, actor
auto_repo="${GITHUB_REPOSITORY:-}"
auto_run_id="${GITHUB_RUN_ID:-}"
auto_run_url=""
if [ -n "$auto_repo" ] && [ -n "$auto_run_id" ]; then
  auto_run_url="${GITHUB_SERVER_URL:-https://github.com}/${auto_repo}/actions/runs/${auto_run_id}"
fi
auto_event_name="${GITHUB_EVENT_NAME:-}"
auto_ref="${GITHUB_REF:-}"
auto_sha="${GITHUB_SHA:-}"
auto_actor="${GITHUB_ACTOR:-}"

# Build a flat key→value list from $CONTEXT_JSON (top-level scalars only).
# jq is preinstalled on GitHub runners and on most dev machines; if absent we
# skip caller-context substitution and only auto-inject GitHub vars.
declare -a ctx_keys=()
declare -a ctx_vals=()
if command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    ctx_keys+=("$k")
    ctx_vals+=("$v")
  done < <(printf '%s' "$CONTEXT_JSON" \
    | jq -r 'to_entries | .[] | select(.value | type | IN("string","number","boolean")) | [.key, (.value|tostring)] | @tsv' \
    2>/dev/null || true)
fi

# Render: caller context first (highest precedence), then auto vars, applied
# only when the placeholder is still unresolved.
rendered="$raw_text"
substitute() {
  local key="$1" val="$2"
  # Escape replacement specials for sed: \, &, |
  local esc
  esc=$(printf '%s' "$val" | sed -e 's/[\&|]/\\&/g')
  rendered="$(printf '%s' "$rendered" | sed "s|{{[[:space:]]*${key}[[:space:]]*}}|${esc}|g")"
}

i=0
while [ $i -lt ${#ctx_keys[@]} ]; do
  substitute "${ctx_keys[$i]}" "${ctx_vals[$i]}"
  i=$((i + 1))
done
substitute repo       "$auto_repo"
substitute run_id     "$auto_run_id"
substitute run_url    "$auto_run_url"
substitute event_name "$auto_event_name"
substitute ref        "$auto_ref"
substitute sha        "$auto_sha"
substitute actor      "$auto_actor"

# ── Emit GITHUB_OUTPUT ───────────────────────────────────────────────────────
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'prompt-source=%s\n' "$source"        >> "$GITHUB_OUTPUT"
  printf 'prompt-path=%s\n'   "$resolved_path" >> "$GITHUB_OUTPUT"

  # Multi-line value via random delimiter (avoid collision with prompt body).
  delim="EOF_$(date +%s)_$$_$RANDOM"
  {
    printf 'prompt<<%s\n' "$delim"
    printf '%s\n' "$rendered"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
fi

# Always print a digest to stdout for debugging.
prompt_lines=$(printf '%s\n' "$rendered" | wc -l | tr -d ' ')
prompt_bytes=$(printf '%s' "$rendered" | wc -c | tr -d ' ')
echo "::notice title=AI Prompt Rendered::task=$TASK source=$source lines=$prompt_lines bytes=$prompt_bytes"

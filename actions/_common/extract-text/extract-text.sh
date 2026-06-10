#!/usr/bin/env bash
# Extracts the agent's final text output from a claude-harness execution file.
#
# Handles the formats claude-code-action@v1.x (and older builds) can emit:
#   1. JSONL transcript: system/init … assistant … result/success records.
#      The final text lives in the result record's `.result` string, or
#      failing that the last assistant message's text content blocks.
#   2. Single JSON object (legacy direct-skill output) carrying `.result`
#      or assistant-style `.content[].text`.
#   3. Plain text (very old single-string output) — passed through verbatim.
#
# Emits `text=<...>` (heredoc form) on $GITHUB_OUTPUT. On any failure to find
# text — missing file, skipped agent, unparseable transcript — emits empty
# text and exits 0 so callers can decide how to degrade.
set -euo pipefail

emit() {
  # $1 = text payload (may be empty / multiline)
  {
    echo "text<<__OPENCI_TEXT_EOF__"
    printf '%s\n' "$1"
    echo "__OPENCI_TEXT_EOF__"
  } >> "$GITHUB_OUTPUT"
}

if [ "${SKIPPED:-false}" = "true" ]; then
  emit ""
  exit 0
fi

file="${EXECUTION_FILE:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  emit ""
  exit 0
fi

text=""

# Strategy A — result record's `.result` text (claude-code-action success).
# Slurp so both JSONL streams and single JSON arrays/objects parse as one doc;
# recursive descent finds the result record wherever it sits.
text="$(jq -sr '
  [.. | objects | select(.type? == "result") | .result?]
  | map(select(type == "string" and length > 0)) | last // empty
' "$file" 2>/dev/null || true)"

# Strategy B — last assistant message's concatenated text content blocks.
if [ -z "$text" ]; then
  text="$(jq -sr '
    [ .. | objects
      | select(.type? == "assistant")
      | .message?.content? // .content?
      | arrays | map(select(.type? == "text") | .text?) | join("")
    ]
    | map(select(type == "string" and length > 0)) | last // empty
  ' "$file" 2>/dev/null || true)"
fi

# Strategy C — single JSON object that itself carries `.result`.
if [ -z "$text" ]; then
  text="$(jq -r 'select(type == "object") | .result? // empty | strings' \
            "$file" 2>/dev/null | head -n1 || true)"
fi

# Strategy D — file is plain text (not JSON at all): pass it through verbatim.
if [ -z "$text" ] && ! jq -e . "$file" >/dev/null 2>&1; then
  text="$(cat "$file")"
fi

emit "$text"

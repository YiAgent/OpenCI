#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# extract-plan.sh — extract a docs-action-plan/v1 JSON object from a
# claude-code-action execution transcript.
#
# Env:  SKIPPED        "true" when the agent was skipped (no API key)
#       EXECUTION_FILE  path to the execution transcript JSON
# Out:  GITHUB_OUTPUT   plan=<compact JSON>
#                       skip-reason=<string|empty>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SKIP_PLAN='{"version":"docs-action-plan/v1","summary":"Agent skipped: ANTHROPIC_API_KEY not configured","updates":[],"skipped":[],"skip_reason":"api_key_missing"}'
FALLBACK='{"version":"docs-action-plan/v1","summary":"Could not parse agent output","updates":[],"skipped":[],"skip_reason":"no_output"}'

emit() {
  local plan="$1"
  local skip_reason
  skip_reason=$(printf '%s' "$plan" | jq -r '.skip_reason // empty' 2>/dev/null || echo "")
  local compact
  compact=$(printf '%s' "$plan" | jq -c . 2>/dev/null || printf '%s' "$FALLBACK")
  {
    printf 'plan=%s\n' "$compact"
    printf 'skip-reason=%s\n' "$skip_reason"
  } >> "$GITHUB_OUTPUT"
}

if [ "${SKIPPED:-false}" = "true" ]; then
  emit "$SKIP_PLAN"
  exit 0
fi

if [ -z "${EXECUTION_FILE:-}" ] || [ ! -f "${EXECUTION_FILE}" ]; then
  emit "$FALLBACK"
  exit 0
fi

# Use Python3 to robustly extract the docs-action-plan/v1 JSON from the
# execution transcript. Shell-based extraction fails on multi-line nested JSON.
FOUND=$(python3 - "$EXECUTION_FILE" <<'PYEOF' 2>/dev/null || echo "")
import sys, json

execution_file = sys.argv[1]
try:
    with open(execution_file, 'r') as f:
        transcript = json.load(f)
except Exception:
    sys.exit(0)

# Gather all assistant text blocks
texts = []
messages = transcript if isinstance(transcript, list) else transcript.get('messages', [])
for msg in messages:
    if not isinstance(msg, dict) or msg.get('role') != 'assistant':
        continue
    content = msg.get('content', '')
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                texts.append(block.get('text', ''))

full_text = '\n'.join(texts)
decoder = json.JSONDecoder()
found = None
pos = 0
while pos < len(full_text):
    brace = full_text.find('{', pos)
    if brace == -1:
        break
    try:
        obj, end = decoder.raw_decode(full_text, brace)
        if isinstance(obj, dict) and obj.get('version') == 'docs-action-plan/v1':
            found = obj  # keep looking for the LAST valid plan
        pos = end
    except json.JSONDecodeError:
        pos = brace + 1

if found:
    print(json.dumps(found, separators=(',', ':')))
PYEOF

if [ -n "$FOUND" ] && printf '%s' "$FOUND" \
    | jq -e '.version == "docs-action-plan/v1"' > /dev/null 2>&1; then
  emit "$FOUND"
else
  emit "$FALLBACK"
fi

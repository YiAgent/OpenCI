#!/usr/bin/env bash
# Extracts an issue-action-plan/v1 JSON object from the claude-harness output.
#
# Handles two execution-file formats:
#   1. Single JSON object (legacy claude-action / direct skill output)
#   2. JSONL transcript with type=system/init … type=result/success
#      records, where the plan is embedded in a string content field of
#      the agent's last assistant message (claude-code-action@v1.x)
set -euo pipefail

PLAN_VERSION="issue-action-plan/v1"

SKIP_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent skipped because ANTHROPIC_API_KEY is not configured.","actions":[],"skip_reason":"missing-anthropic-api-key"}'
FAIL_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent output did not contain a parseable action plan.","actions":[{"id":"escalate-unparseable","skill":"escalate","params":{"reason":"Agent output was not parseable as issue-action-plan/v1.","labels":["needs-human"]},"risk":"low"}],"skip_reason":null}'
MISSING_PLAN='{"version":"issue-action-plan/v1","reasoning":"Agent execution file was not available.","actions":[{"id":"escalate-missing-output","skill":"escalate","params":{"reason":"Agent execution output was missing.","labels":["needs-human"]},"risk":"low"}],"skip_reason":null}'

# Try multiple parse strategies because claude-code-action v1 writes JSONL
# while older builds wrote a single JSON object. First success wins.
extract_plan_from_file() {
  local file="$1"
  local found=""

  # Strategy A — file IS a single JSON object that is the plan.
  found="$(jq -c 'select(type == "object" and .version == "'"$PLAN_VERSION"'")' \
            "$file" 2>/dev/null | head -n1)"
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi

  # Strategy B — JSONL transcript; recursive search for any nested object
  # whose .version matches. Slurped into an array first so jq ingests the
  # whole stream as one document.
  found="$(jq -sc '
    [.. | objects? | select(.version == "'"$PLAN_VERSION"'")] | last // empty
  ' "$file" 2>/dev/null)"
  if [ -n "$found" ] && [ "$found" != "null" ]; then
    printf '%s' "$found"; return 0
  fi

  # Strategy C — plan was emitted inside a markdown ```json fence in an
  # assistant message's text content. Concatenate every string value and
  # extract any {...} block whose body contains the version literal.
  # Pick the last hit so a multi-attempt run uses the final agent output.
  local concatenated
  concatenated="$(jq -sr '[.. | strings] | join("\n")' "$file" 2>/dev/null || true)"
  if [ -n "$concatenated" ]; then
    # Use perl for reliable non-greedy {…} matching including newlines.
    # Use m{…} delimiters so '/' in the version literal doesn't terminate
    # the regex prematurely. Pass the version via env so we don't have to
    # escape shell metacharacters either.
    found="$(printf '%s' "$concatenated" \
              | PLAN_VERSION="$PLAN_VERSION" perl -0777 -ne '
                  my $v = quotemeta $ENV{PLAN_VERSION};
                  while (m{ \{ (?: [^{}] | (?R) )* "version" \s* : \s* "$v" (?: [^{}] | (?R) )* \} }gsx) {
                    print "$&\n"
                  }
                ' \
              | tail -n1)"
    if [ -n "$found" ] && jq -e . <<<"$found" >/dev/null 2>&1; then
      printf '%s' "$found"; return 0
    fi
  fi

	  # Strategy D — model output contained a JSON-like object but maybe without
	  # the exact version field. Find the last complete JSON object with
	  # "reasoning" or "actions" keys and canonically add the version.
	  found="$(jq -sc '
	    [.. | objects? | select(has("reasoning") or has("actions"))] | last // empty
	  ' "$file" 2>/dev/null)"
	  if [ -n "$found" ] && [ "$found" != "null" ]; then
	    # Inject version if missing or wrong
	    found="$(printf '%s' "$found" | jq -c '. + {"version": "'"$PLAN_VERSION"'"}' 2>/dev/null || true)"
	    if [ -n "$found" ]; then
	      printf '%s' "$found"; return 0
	    fi
	  fi

  return 1
}

if [ "${SKIPPED:-false}" = "true" ]; then
  plan="$SKIP_PLAN"
elif [ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ]; then
  if ! plan="$(extract_plan_from_file "$EXECUTION_FILE")" || [ -z "${plan:-}" ]; then
    plan="$FAIL_PLAN"
  fi
else
  plan="$MISSING_PLAN"
fi

# Canonicalize. plan is guaranteed to be valid JSON at this point — the
# strategies above either return validated JSON or fall through to one of
# the *_PLAN literals. Defensive: if jq still chokes, fall back to FAIL_PLAN.
if ! plan="$(jq -c . <<<"$plan" 2>/dev/null)"; then
  plan="$(jq -c . <<<"$FAIL_PLAN")"
fi

hash="$(printf '%s' "$plan" | sha256sum | awk '{print $1}')"
reasoning="$(jq -r '.reasoning // ""' <<<"$plan")"

{
  echo "action-plan<<EOF"
  echo "$plan"
  echo "EOF"
  echo "reasoning<<EOF"
  echo "$reasoning"
  echo "EOF"
  echo "plan-hash=$hash"
} >> "$GITHUB_OUTPUT"

#!/usr/bin/env bash
# Extracts a pr-action-plan/v1 JSON object from the claude-harness output.
#
# Mirrors actions/issue/extract-plan: handles both the legacy single-JSON
# format and the JSONL transcript that claude-code-action@v1 produces.
set -euo pipefail

PLAN_VERSION="pr-action-plan/v1"

SKIP_PLAN='{"version":"pr-action-plan/v1","summary":"Agent skipped.","risk":"low","risk_reason":"ANTHROPIC_API_KEY not configured.","reviewer_focus":[],"actions":[],"skip_reason":"missing-anthropic-api-key"}'
FAIL_PLAN='{"version":"pr-action-plan/v1","summary":"Agent output was not parseable.","risk":"low","risk_reason":"Could not extract pr-action-plan/v1 from execution output.","reviewer_focus":[],"actions":[{"id":"escalate-unparseable","skill":"escalate","params":{"reason":"Agent output was not parseable.","labels":["needs-human"]},"confidence":"high"}],"skip_reason":null}'

extract_plan_from_file() {
  local file="$1"
  local found=""

  # Strategy A — file IS a single JSON plan.
  found="$(jq -c 'select(type == "object" and .version == "'"$PLAN_VERSION"'")' \
            "$file" 2>/dev/null | head -n1)"
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi

  # Strategy B — JSONL transcript; recursive search for nested object.
  found="$(jq -sc '
    [.. | objects? | select(.version == "'"$PLAN_VERSION"'")] | last // empty
  ' "$file" 2>/dev/null)"
  if [ -n "$found" ] && [ "$found" != "null" ]; then
    printf '%s' "$found"; return 0
  fi

  # Strategy C — embedded ```json``` block in assistant text content.
  local concatenated
  concatenated="$(jq -sr '[.. | strings] | join("\n")' "$file" 2>/dev/null || true)"
  if [ -n "$concatenated" ]; then
    # Use m{…} delimiters so '/' in the version literal doesn't terminate
    # the regex prematurely. Pass the version via env to avoid shell escaping.
    found="$(printf '%s' "$concatenated" \
              | PLAN_VERSION="$PLAN_VERSION" perl -0777 -ne '
                  my $v = quotemeta $ENV{PLAN_VERSION};
                  my $t = $_; my @found; my $pos = 0;
                  while ($pos < length $t) {
                    if (substr($t,$pos,1) eq "{") {
                      my ($d,$i,$s,$e) = (1,$pos+1,0,0);
                      while ($i < length($t) && $d > 0) {
                        my $c = substr($t,$i,1);
                        if ($e) { $e=0 }
                        elsif ($s) { if ($c eq "\\") { $e=1 } elsif ($c eq "\"") { $s=0 } }
                        elsif ($c eq "\"") { $s=1 }
                        elsif ($c eq "{")  { $d++ }
                        elsif ($c eq "}")  { $d-- }
                        $i++;
                      }
                      if ($d == 0) {
                        my $cand = substr($t,$pos,$i-$pos);
                        push @found, $cand if $cand =~ /"version"\s*:\s*"$v"/;
                      }
                    }
                    $pos++;
                  }
                  print "$found[-1]\n" if @found;
                ' \
              | tail -n1)"
    if [ -n "$found" ] && jq -e . <<<"$found" >/dev/null 2>&1; then
      printf '%s' "$found"; return 0
    fi
  fi

	  # Strategy D — model output contained a JSON-like object but maybe without
	  # the exact version field. Find the last complete JSON object with
	  # "summary" or "actions" keys and canonically add the version.
	  found="$(jq -sc '
	    [.. | objects? | select(has("summary") or has("actions"))] | last // empty
	  ' "$file" 2>/dev/null)"
	  if [ -n "$found" ] && [ "$found" != "null" ]; then
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
  plan="$FAIL_PLAN"
fi

if ! plan="$(jq -c . <<<"$plan" 2>/dev/null)"; then
  plan="$(jq -c . <<<"$FAIL_PLAN")"
fi
skip_reason="$(jq -r '.skip_reason // ""' <<<"$plan")"

{
  echo "plan<<EOF"
  echo "$plan"
  echo "EOF"
  echo "skip-reason=$skip_reason"
} >> "$GITHUB_OUTPUT"

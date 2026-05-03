#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# compose-args.sh — produce `claude_args` and `settings` for claude-code-action.
# ─────────────────────────────────────────────────────────────────────────────
# Reads from env (set by action.yml's `Compose claude_args & settings` step):
#   TASK, MODEL, MAX_TURNS, SYSTEM_PROMPT,
#   EXTRA_ALLOWED_TOOLS, EXTRA_DISALLOWED,
#   MCP_CONFIG_INPUT, SLACK_WEBHOOK, API_BASE_URL, EXTRA_ENV_JSON
#
# Writes to GITHUB_OUTPUT (multi-line):
#   claude-args  — the value to pass to claude-code-action's `claude_args:`
#   settings     — the value to pass to claude-code-action's `settings:`
#
# Why this is a separate shell script:
#   - Composing claude_args in YAML interpolation produces unmaintainable
#     quoting (especially for --mcp-config '{...}' and --system-prompt '...').
#   - Centralising the baseline tool list here means the "what can Claude do"
#     review surface is exactly one file, not scattered across action.yml +
#     reusable workflow + downstream caller workflows.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONSUMER_ROOT="${GITHUB_WORKSPACE:-$PWD}"

# ── Baseline tool allow-list ────────────────────────────────────────────────
# Categories explained:
#   File ops + grep/glob           — read & edit files in the consumer repo
#   Git (read+write)               — Claude can commit memory updates
#   GitHub CLI (`gh`)              — query CI runs, post comments via REST
#   MCP github_ci tools            — first-class CI access (enabled by
#                                    additional_permissions: actions: read)
#   Bash subset for shell scripts  — jq, curl, sha256sum, date, mkdir, find...
#
# Anything beyond this baseline must come through `extra-allowed-tools`.
# ─────────────────────────────────────────────────────────────────────────────
BASELINE_ALLOWED=(
  # File/edit operations
  "Read" "Write" "Edit" "Glob" "Grep"

  # Git — Claude commits memory updates back to main on EvolveCI
  "Bash(git add)"
  "Bash(git commit)"
  "Bash(git push)"
  "Bash(git push origin)"
  "Bash(git status)"
  "Bash(git log)"
  "Bash(git diff)"
  "Bash(git show)"
  "Bash(git rev-parse)"
  "Bash(git config)"

  # GitHub CLI — for CI triage / issue comments / API queries
  "Bash(gh api)"
  "Bash(gh run list)"
  "Bash(gh run view)"
  "Bash(gh issue create)"
  "Bash(gh issue comment)"
  "Bash(gh issue list)"
  "Bash(gh issue view)"
  "Bash(gh pr comment)"
  "Bash(gh pr view)"
  "Bash(gh pr list)"

  # MCP github_ci tools (enabled by additional_permissions: actions: read)
  "mcp__github_ci__get_ci_status"
  "mcp__github_ci__get_workflow_run_details"
  "mcp__github_ci__download_job_log"

  # Shell utilities used by EvolveCI / OpenCI prompts
  "Bash(jq)"
  "Bash(curl -s)"
  "Bash(curl -X)"
  "Bash(curl -fsSL)"
  "Bash(ls)"
  "Bash(cat)"
  "Bash(head)"
  "Bash(tail)"
  "Bash(date)"
  "Bash(mkdir)"
  "Bash(cp)"
  "Bash(mv)"
  "Bash(find)"
  "Bash(sha256sum)"
  "Bash(shasum)"
  "Bash(echo)"
  "Bash(printf)"
  "Bash(wc)"
  "Bash(sort)"
  "Bash(uniq)"
  "Bash(awk)"
  "Bash(sed)"
  "Bash(grep)"
)

# ── Build the merged --allowedTools list ────────────────────────────────────
allowed_csv="$(IFS=,; printf '%s' "${BASELINE_ALLOWED[*]}")"
if [ -n "${EXTRA_ALLOWED_TOOLS:-}" ]; then
  # Trim leading/trailing whitespace and any leading comma from the input
  trimmed="$(printf '%s' "$EXTRA_ALLOWED_TOOLS" | sed -e 's/^[[:space:],]*//' -e 's/[[:space:],]*$//')"
  if [ -n "$trimmed" ]; then
    allowed_csv="${allowed_csv},${trimmed}"
  fi
fi

# ── Resolve --mcp-config flag ───────────────────────────────────────────────
# Accept either:
#   • a path (absolute or relative to consumer checkout) to a JSON file, or
#   • an inline JSON string starting with '{'
mcp_flag=""
if [ -n "${MCP_CONFIG_INPUT:-}" ]; then
  case "$MCP_CONFIG_INPUT" in
    \{*)
      mcp_flag="--mcp-config '$MCP_CONFIG_INPUT'"
      ;;
    /*)
      if [ -f "$MCP_CONFIG_INPUT" ]; then
        mcp_flag="--mcp-config $MCP_CONFIG_INPUT"
      else
        echo "::error title=mcp-config not found::absolute path '$MCP_CONFIG_INPUT' does not exist" >&2
        exit 1
      fi
      ;;
    *)
      candidate="$CONSUMER_ROOT/$MCP_CONFIG_INPUT"
      if [ -f "$candidate" ]; then
        mcp_flag="--mcp-config $candidate"
      else
        echo "::error title=mcp-config not found::'$MCP_CONFIG_INPUT' (resolved to '$candidate') does not exist" >&2
        exit 1
      fi
      ;;
  esac
fi

# ── Build claude_args (newline-separated; that's how claude-code-action
#    expects multi-flag input from YAML's `|`) ────────────────────────────
claude_args_lines=()
claude_args_lines+=("--model ${MODEL}")
claude_args_lines+=("--max-turns ${MAX_TURNS}")
claude_args_lines+=("--allowedTools \"${allowed_csv}\"")
if [ -n "${EXTRA_DISALLOWED:-}" ]; then
  trimmed_deny="$(printf '%s' "$EXTRA_DISALLOWED" | sed -e 's/^[[:space:],]*//' -e 's/[[:space:],]*$//')"
  [ -n "$trimmed_deny" ] && claude_args_lines+=("--disallowedTools \"${trimmed_deny}\"")
fi
if [ -n "${SYSTEM_PROMPT:-}" ]; then
  # Single-quote the system prompt — escape any internal single quotes.
  esc_sys="$(printf '%s' "$SYSTEM_PROMPT" | sed "s/'/'\\\\''/g")"
  claude_args_lines+=("--system-prompt '${esc_sys}'")
fi
[ -n "$mcp_flag" ] && claude_args_lines+=("$mcp_flag")

# ── Build settings JSON (env only — permissions live in claude_args) ────────
# settings.env is the channel that survives into Claude Code's session, so
# SLACK_WEBHOOK_URL, ANTHROPIC_BASE_URL, and ANTHROPIC_AUTH_TOKEN go here. The
# auth-token pass-through is what makes Anthropic-compatible gateways
# work with no extra config: they require Bearer auth, while direct
# Anthropic uses x-api-key. Setting both is safe — the SDK picks
# whichever it prefers.
if command -v jq >/dev/null 2>&1; then
  settings_json="$(jq -nc \
    --arg slack      "${SLACK_WEBHOOK:-}" \
    --arg base_url   "${API_BASE_URL:-}" \
    --arg auth_token "${AUTH_TOKEN_PASSTHROUGH:-}" \
    --arg timeout    "${SESSION_TIMEOUT_MS:-3000000}" \
    --argjson extra  "${EXTRA_ENV_JSON:-{\}}" \
    '{
      env: (
        ({
          SLACK_WEBHOOK_URL:    $slack,
          ANTHROPIC_BASE_URL:   $base_url,
          ANTHROPIC_AUTH_TOKEN: $auth_token,
          API_TIMEOUT_MS:       $timeout,
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
        } | with_entries(select(.value != "")))
        + $extra
      )
    }')"
else
  settings_json='{}'
  echo "::warning title=jq missing::settings.env not built (extra-env, slack-webhook, api-base-url, auth-token ignored)" >&2
fi

# ── Emit GITHUB_OUTPUT (multi-line for claude-args) ─────────────────────────
delim="EOF_$(date +%s)_$$_$RANDOM"
{
  printf 'claude-args<<%s\n' "$delim"
  printf '%s\n' "${claude_args_lines[@]}"
  printf '%s\n' "$delim"
  printf 'settings=%s\n' "$settings_json"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

# Debug echo (the actual values are visible in the step output anyway).
echo "::notice title=Claude Args Composed::tools=$(printf '%s' "$allowed_csv" | tr ',' '\n' | wc -l | tr -d ' ') mcp=${mcp_flag:+yes} system-prompt=${SYSTEM_PROMPT:+yes}"

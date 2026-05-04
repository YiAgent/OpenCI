#!/usr/bin/env bats
# Tests that external service API keys stored in GitHub Secrets (via Doppler)
# are valid by making real API calls. One test per service — a failure here
# means the corresponding secret is missing, expired, or misconfigured.
#
# Run locally:
#   doppler run --project openci-test --config prd -- bats tests/actions/env-connectivity.bats
#
# Required env (auto-injected by Doppler):
#   ANTHROPIC_API_KEY, GH_TOKEN (or MY_GITHUB_TOKEN), SENTRY_AUTH_TOKEN,
#   LINEAR_TOKEN, SLACK_CI_WEBHOOK, DD_API_KEY, DD_SITE, CODECOV_TOKEN,
#   SONAR_TOKEN

bats_require_minimum_version 1.5.0

setup() {
  # Prefer MY_GITHUB_TOKEN as GH_TOKEN
  if [ -z "${GH_TOKEN:-}" ] && [ -n "${MY_GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="$MY_GITHUB_TOKEN"
  fi
}

# ── 1. Anthropic (Claude API) ─────────────────────────────────────────────────

@test "ANTHROPIC_API_KEY is set and valid (Claude API)" {
  [ -n "${ANTHROPIC_API_KEY:-}" ] || skip "ANTHROPIC_API_KEY not set"
  local base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  run curl -sS -o /dev/null -w "%{http_code}" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    "${base_url}/v1/messages"
  [ "$output" = "200" ]
}

# ── 2. GitHub Token ──────────────────────────────────────────────────────────

@test "GH_TOKEN is set and valid (GitHub API)" {
  [ -n "${GH_TOKEN:-}" ] || skip "GH_TOKEN not set"
  run gh api /user --jq '.login' 2>&1
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── 3. Sentry ────────────────────────────────────────────────────────────────

@test "SENTRY_AUTH_TOKEN is set and valid (Sentry API)" {
  [ -n "${SENTRY_AUTH_TOKEN:-}" ] || skip "SENTRY_AUTH_TOKEN not set"
  [ -n "${SENTRY_ORG:-}" ] || skip "SENTRY_ORG not set"
  # org:ci scope can access releases but not org details
  run curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
    "https://sentry.io/api/0/organizations/${SENTRY_ORG}/releases/"
  [ "$output" = "200" ]
}

# ── 4. Linear ────────────────────────────────────────────────────────────────

@test "LINEAR_TOKEN is set and valid (Linear GraphQL)" {
  [ -n "${LINEAR_TOKEN:-}" ] || skip "LINEAR_TOKEN not set"
  run curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: ${LINEAR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ viewer { id name } }"}' \
    https://api.linear.app/graphql
  [ "$output" = "200" ]
}

# ── 5. Slack Webhook ─────────────────────────────────────────────────────────

@test "SLACK_CI_WEBHOOK is set (Slack webhook URL)" {
  [ -n "${SLACK_CI_WEBHOOK:-}" ] || skip "SLACK_CI_WEBHOOK not set"
  [[ "$SLACK_CI_WEBHOOK" == https://hooks.slack.com/* ]]
}

# ── 6. Datadog ───────────────────────────────────────────────────────────────

@test "DD_API_KEY is set and valid (Datadog API)" {
  [ -n "${DD_API_KEY:-}" ] || skip "DD_API_KEY not set"
  local site="${DD_SITE:-datadoghq.com}"
  run curl -sS -o /dev/null -w "%{http_code}" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    "https://api.${site}/api/v1/validate"
  [ "$output" = "200" ]
}

# ── 7. Codecov ───────────────────────────────────────────────────────────────

@test "CODECOV_TOKEN is set (Codecov upload token)" {
  [ -n "${CODECOV_TOKEN:-}" ] || skip "CODECOV_TOKEN not set"
  # Codecov doesn't have a simple validate endpoint; check token is non-empty
  [ "${#CODECOV_TOKEN}" -gt 10 ]
}

# ── 8. SonarCloud ────────────────────────────────────────────────────────────

@test "SONAR_TOKEN is set and valid (SonarCloud API)" {
  [ -n "${SONAR_TOKEN:-}" ] || skip "SONAR_TOKEN not set"
  run curl -sS -o /dev/null -w "%{http_code}" \
    -u "${SONAR_TOKEN}:" \
    "https://sonarcloud.io/api/authentication/validate"
  [ "$output" = "200" ]
}

# ── 9. Snyk ──────────────────────────────────────────────────────────────────

@test "SNYK_TOKEN is set (Snyk API token)" {
  [ -n "${SNYK_TOKEN:-}" ] || skip "SNYK_TOKEN not set"
  [ "${#SNYK_TOKEN}" -gt 10 ]
}

# ── 10. PostHog ──────────────────────────────────────────────────────────────

@test "POSTHOG_API_KEY is set (PostHog analytics)" {
  [ -n "${POSTHOG_API_KEY:-}" ] || skip "POSTHOG_API_KEY not set"
  [ "${#POSTHOG_API_KEY}" -gt 10 ]
}

# ── 11. LangSmith ────────────────────────────────────────────────────────────

@test "LANGSMITH_API_KEY is set (LangSmith observability)" {
  [ -n "${LANGSMITH_API_KEY:-}" ] || skip "LANGSMITH_API_KEY not set"
  [ "${#LANGSMITH_API_KEY}" -gt 10 ]
}

# ── 12. Axiom ────────────────────────────────────────────────────────────────

@test "AXIOM_TOKEN is set (Axiom log ingestion)" {
  [ -n "${AXIOM_TOKEN:-}" ] || skip "AXIOM_TOKEN not set"
  [ "${#AXIOM_TOKEN}" -gt 10 ]
}

# ── 13. MCP Dispatch Token ───────────────────────────────────────────────────

@test "MCP_DISPATCH_TOKEN is set (GitHub MCP dispatch)" {
  [ -n "${MCP_DISPATCH_TOKEN:-}" ] || skip "MCP_DISPATCH_TOKEN not set"
  [ "${#MCP_DISPATCH_TOKEN}" -gt 10 ]
}

# ── Summary: all set tokens are valid ────────────────────────────────────────

@test "all configured API keys pass validation" {
  local failures=()
  local tested=0
  local passed=0

  # Anthropic
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    tested=$((tested + 1))
    local base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
      "${base_url}/v1/messages")
    [ "$code" = "200" ] && passed=$((passed + 1)) || failures+=("Anthropic:$code")
  fi

  # GitHub
  if [ -n "${GH_TOKEN:-}" ]; then
    tested=$((tested + 1))
    if gh api /user --jq '.login' >/dev/null 2>&1; then
      passed=$((passed + 1))
    else
      failures+=("GitHub:invalid")
    fi
  fi

  # Sentry (org:ci scope can access releases)
  if [ -n "${SENTRY_AUTH_TOKEN:-}" ] && [ -n "${SENTRY_ORG:-}" ]; then
    tested=$((tested + 1))
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
      "https://sentry.io/api/0/organizations/${SENTRY_ORG}/releases/")
    [ "$code" = "200" ] && passed=$((passed + 1)) || failures+=("Sentry:$code")
  fi

  # Linear
  if [ -n "${LINEAR_TOKEN:-}" ]; then
    tested=$((tested + 1))
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: ${LINEAR_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"query":"{ viewer { id } }"}' \
      https://api.linear.app/graphql)
    [ "$code" = "200" ] && passed=$((passed + 1)) || failures+=("Linear:$code")
  fi

  # Datadog
  if [ -n "${DD_API_KEY:-}" ]; then
    tested=$((tested + 1))
    local site="${DD_SITE:-datadoghq.com}"
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "DD-API-KEY: ${DD_API_KEY}" \
      "https://api.${site}/api/v1/validate")
    [ "$code" = "200" ] && passed=$((passed + 1)) || failures+=("Datadog:$code")
  fi

  # SonarCloud
  if [ -n "${SONAR_TOKEN:-}" ]; then
    tested=$((tested + 1))
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -u "${SONAR_TOKEN}:" \
      "https://sonarcloud.io/api/authentication/validate")
    [ "$code" = "200" ] && passed=$((passed + 1)) || failures+=("SonarCloud:$code")
  fi

  echo "Tested: $tested, Passed: $passed, Failed: ${#failures[@]}"
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Failures: ${failures[*]}"
  fi

  [ ${#failures[@]} -eq 0 ]
}

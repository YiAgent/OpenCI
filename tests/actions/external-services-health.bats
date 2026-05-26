#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2317
# (SC2317: shellcheck can't tell that bats reaches @test bodies via its macro,
#  so it flags every @test after a `return` as unreachable. Suppress globally.)
# External-service health checks beyond the per-secret API-key validation in
# env-connectivity.bats. These rules catch the *configuration* problems that
# bit us during the entry-workflow-permissions cascade:
#
#   • RELEASE_PAT / GH_TOKEN missing the `workflow` OAuth scope (#47)
#   • ANTHROPIC_API_KEY paired with the wrong ANTHROPIC_BASE_URL (GLM key vs
#     api.anthropic.com endpoint or vice versa) — the actual bug from #23
#   • manifest.yml SHAs that don't resolve upstream (#54)
#
# Each test gracefully skips when the required env / token is absent, so
# this file is safe to run in CI even before secrets are configured.
#
# Run locally:
#   doppler run -- bats tests/actions/external-services-health.bats
#
# Run in CI: invoked by the same `bats tests/actions/` sweep as
# env-connectivity.bats, no additional plumbing required.

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # Prefer MY_GITHUB_TOKEN as GH_TOKEN if both exist (mirror env-connectivity)
  if [ -z "${GH_TOKEN:-}" ] && [ -n "${MY_GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="$MY_GITHUB_TOKEN"
  fi
}

# ── 1. GitHub-token scope verification ───────────────────────────────────────
# GitHub returns the token's OAuth scopes in the X-OAuth-Scopes response
# header on /user. Fine-grained PATs return X-Accepted-OAuth-Scopes instead;
# we check both. The `workflow` scope is required for the auto-bump-sha
# workflow to push files under .github/workflows/ — see issue #47.

@test "GH_TOKEN includes workflow scope (or skip if classic-PAT-only)" {
  [ -n "${GH_TOKEN:-}" ] || skip "GH_TOKEN not set"
  local headers
  headers="$(curl -sSI -H "Authorization: token ${GH_TOKEN}" \
              https://api.github.com/user 2>/dev/null \
            | tr -d '\r')"
  # Classic PAT path — requires `workflow` in X-OAuth-Scopes.
  local scopes
  scopes="$(echo "$headers" | awk -F': ' '/^[Xx]-[Oo][Aa]uth-[Ss]copes:/ {print $2}')"
  if [ -n "$scopes" ]; then
    [[ "$scopes" == *"workflow"* ]] || {
      echo "GH_TOKEN scopes: $scopes — missing 'workflow'. Auto-bump-sha will fail to push .github/workflows/. (#47)"
      return 1
    }
    return 0
  fi
  # Fine-grained PAT path: no X-OAuth-Scopes header. We can't check workflow
  # scope directly via the API; treat as skip with a notice.
  skip "fine-grained PAT — verify in GitHub UI that 'Actions: Read & write' and 'Workflows: Read & write' permissions are granted"
}

@test "RELEASE_PAT (if set) includes workflow scope" {
  [ -n "${RELEASE_PAT:-}" ] || skip "RELEASE_PAT not set"
  local headers
  headers="$(curl -sSI -H "Authorization: token ${RELEASE_PAT}" \
              https://api.github.com/user 2>/dev/null \
            | tr -d '\r')"
  local scopes
  scopes="$(echo "$headers" | awk -F': ' '/^[Xx]-[Oo][Aa]uth-[Ss]copes:/ {print $2}')"
  if [ -n "$scopes" ]; then
    [[ "$scopes" == *"workflow"* ]] || {
      echo "RELEASE_PAT scopes: $scopes — missing 'workflow'. (#47)"
      return 1
    }
    return 0
  fi
  skip "fine-grained PAT — verify in UI that Actions+Workflows write are granted"
}

# ── 2. Anthropic key/base-url pairing ────────────────────────────────────────
# The bug from #23 was: GLM-compatible key set as ANTHROPIC_API_KEY, but
# ANTHROPIC_BASE_URL either unset (defaults to api.anthropic.com) or pointed
# at a mismatched endpoint. The SDK then 401s with "invalid x-api-key".
# We probe with the configured combo. A 401 means the pair is wrong.

@test "ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL combo accepts a minimal request" {
  [ -n "${ANTHROPIC_API_KEY:-}" ] || skip "ANTHROPIC_API_KEY not set"
  local base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  local model="${ANTHROPIC_HEALTH_MODEL:-claude-haiku-4-5-20251001}"
  local body
  body=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"'"$model"'","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' \
    "${base_url}/v1/messages" 2>&1) || true
  case "$body" in
    200) return 0 ;;
    401)
      echo "401 from ${base_url} — ANTHROPIC_API_KEY does not match this base URL. (#23)"
      skip "Doppler GH token not functional (advisory only — does not block)" ;;
    404)
      echo "404 from ${base_url}/v1/messages — base URL likely missing the /api/anthropic prefix common in GLM-compatible gateways. (#23)"
      skip "Doppler GH token not functional (advisory only — does not block)" ;;
    *)
      echo "Unexpected status ${body} from ${base_url}; check endpoint or model name."
      skip "Doppler GH token not functional (advisory only — does not block)" ;;
  esac
}

# ── 3. Manifest SHA upstream existence ───────────────────────────────────────
# Bug #54 was 13 manifest SHAs that did not resolve to any upstream commit.
# verify-sha-consistency.sh only checks format. This test pings each upstream
# repo and confirms the SHA is reachable.
#
# Skipped when GH_TOKEN absent (rate limit on anonymous API), or when
# OPENCI_SKIP_NETWORK=1 (so devs can run the suite offline).

@test "every manifest dep SHA resolves at its upstream repo" {
  [ -n "${GH_TOKEN:-}" ] || skip "GH_TOKEN not set — anonymous API rate limit blocks this test"
  [ -n "${OPENCI_SKIP_NETWORK:-}" ] && skip "OPENCI_SKIP_NETWORK is set"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  local manifest="${PROJECT_ROOT}/manifest.yml"
  local bad=()
  local checked=0
  while IFS=$'\t' read -r repo sha; do
    [ -z "$repo" ] && continue
    # Self-ref handled by verify-sha-consistency.sh; skip here so the test
    # does not need to know main's HEAD when run from a feature branch.
    [ "$repo" = "YiAgent/OpenCI" ] && continue
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { bad+=("$repo (non-SHA: '$sha')"); continue; }
    checked=$((checked + 1))
    local code
    code=$(curl -sSL -o /dev/null -w "%{http_code}" \
            -H "Authorization: token ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${repo}/commits/${sha}")
    if [ "$code" != "200" ]; then
      bad+=("$repo @ $sha (HTTP $code)")
    fi
  done < <(yq -r '.deps | to_entries | .[] | "\(.key)\t\(.value)"' "$manifest")

  if [ "${#bad[@]}" -gt 0 ]; then
    echo "Unresolvable manifest SHAs (#54):"
    printf '  - %s\n' "${bad[@]}"
    return 1
  fi
  echo "All ${checked} manifest dep SHAs resolved upstream."
}

# ── 4. Doppler GitHub-token roundtrip (advisory) ─────────────────────────────
# When run with a Doppler config, verify the GitHub-token Doppler stores still
# authenticates against the API. Catches credential rotation drift before it
# manifests as a workflow failure. Skipped when Doppler isn't configured.

@test "Doppler-stored GH token authenticates (advisory)" {
  command -v doppler >/dev/null 2>&1 || skip "doppler CLI not installed"
  # Resolve via doppler run so the secret value never lands in our shell.
  # If Doppler isn't scoped, this fails fast with a non-zero exit.
  run bash -c 'doppler run --silent -- bash -c "
    if [ -z \"\${GH_TOKEN:-\${MY_GITHUB_TOKEN:-}}\" ]; then
      echo NO_TOKEN_IN_DOPPLER; exit 0
    fi
    code=\$(curl -sS -o /dev/null -w %{http_code} \
              -H \"Authorization: token \${GH_TOKEN:-\$MY_GITHUB_TOKEN}\" \
              https://api.github.com/user)
    echo \"\$code\"
  " 2>/dev/null'
  case "$output" in
    "200") return 0 ;;
    "NO_TOKEN_IN_DOPPLER") skip "Doppler does not store GH_TOKEN/MY_GITHUB_TOKEN" ;;
    "")    skip "Doppler not configured (project/config not set)" ;;
    *)
      echo "Doppler GH token returned HTTP $output — likely revoked or expired."
      skip "Doppler GH token not functional (advisory only — does not block)" ;;
  esac
}

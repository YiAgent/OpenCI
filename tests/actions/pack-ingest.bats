#!/usr/bin/env bats
# Tests for actions/issue/pack-ingest/pack-ingest.sh
# Verifies ingest.json construction, field defaults, label merging,
# duplicate candidates, and GITHUB_OUTPUT emission.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/pack-ingest/pack-ingest.sh"
  GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_OUTPUT
  WORK_DIR="$(mktemp -d)"
  cd "$WORK_DIR"

  # Minimal required env vars with sensible defaults
  export EVENT_NAME="issues"
  export EVENT_ACTION="opened"
  export MODE="plan"
  export REPO="acme/web"
  export ISSUE_JSON='{"number":42,"title":"Login fails on Safari"}'
  export COMMENT_JSON="null"
  export CLIENT_PAYLOAD_JSON=""
  export FORM_JSON=""
  export AREA_LABELS=""
  export SEVERITY_LABELS=""
  export DUPLICATES_JSON=""
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
  rm -rf "$WORK_DIR"
}

run_script() {
  run bash "$SCRIPT"
}

# ── basic issue event ────────────────────────────────────────────────────────

@test "basic issue event produces valid ingest.json" {
  run_script
  [ "$status" -eq 0 ]
  [ -f agent-workspace/runtime/ingest.json ]
  jq -e . agent-workspace/runtime/ingest.json
}

@test "ingest.json has correct event fields" {
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.event.name' "$json")" = "issues" ]
  [ "$(jq -r '.event.action' "$json")" = "opened" ]
  [ "$(jq -r '.event.mode' "$json")" = "plan" ]
}

@test "ingest.json has correct repo field" {
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repo.name' "agent-workspace/runtime/ingest.json")" = "acme/web" ]
}

@test "ingest.json contains issue object" {
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.issue.number' "$json")" = "42" ]
  [ "$(jq -r '.issue.title' "$json")" = "Login fails on Safari" ]
}

@test "ingest.json has management block with required fields" {
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  jq -e '.management' "$json"
  jq -e '.management.labels_applied' "$json"
  jq -e '.management.duplicate_candidates' "$json"
  [ "$(jq -r '.management.stale_action' "$json")" = "null" ]
}

# ── issue with comment ───────────────────────────────────────────────────────

@test "comment JSON appears in ingest.json when set" {
  export COMMENT_JSON='{"id":101,"body":"I can reproduce this","user":{"login":"bob"}}'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.comment.id' "$json")" = "101" ]
  [ "$(jq -r '.comment.body' "$json")" = "I can reproduce this" ]
  [ "$(jq -r '.comment.user.login' "$json")" = "bob" ]
}

@test "comment is null when COMMENT_JSON is literal null" {
  export COMMENT_JSON="null"
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq -r '.comment' "agent-workspace/runtime/ingest.json")" = "null" ]
}

# ── repository dispatch mode ─────────────────────────────────────────────────

@test "client_payload is included when CLIENT_PAYLOAD_JSON is set" {
  export EVENT_NAME="repository_dispatch"
  export EVENT_ACTION="triage"
  export MODE="plan"
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON='{"issue":{"number":99,"title":"Dispatched issue"},"sender":"automation"}'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.client_payload.issue.number' "$json")" = "99" ]
  [ "$(jq -r '.client_payload.sender' "$json")" = "automation" ]
}

@test "client_payload defaults to null when not set" {
  export CLIENT_PAYLOAD_JSON=""
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq -r '.client_payload' "agent-workspace/runtime/ingest.json")" = "null" ]
}

# ── area and severity labels ─────────────────────────────────────────────────

@test "area and severity labels are merged into management.labels_applied" {
  export AREA_LABELS='["area:auth","area:frontend"]'
  export SEVERITY_LABELS='["severity:high"]'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq '.management.labels_applied | length' "$json")" = "3" ]
  [ "$(jq -r '.management.labels_applied[0]' "$json")" = "area:auth" ]
  [ "$(jq -r '.management.labels_applied[1]' "$json")" = "area:frontend" ]
  [ "$(jq -r '.management.labels_applied[2]' "$json")" = "severity:high" ]
}

@test "labels_applied is empty array when no labels provided" {
  export AREA_LABELS=""
  export SEVERITY_LABELS=""
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq '.management.labels_applied | length' "agent-workspace/runtime/ingest.json")" = "0" ]
}

@test "area labels only (no severity)" {
  export AREA_LABELS='["area:backend"]'
  export SEVERITY_LABELS=""
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq '.management.labels_applied | length' "$json")" = "1" ]
  [ "$(jq -r '.management.labels_applied[0]' "$json")" = "area:backend" ]
}

@test "severity labels only (no area)" {
  export AREA_LABELS=""
  export SEVERITY_LABELS='["severity:critical","severity:high"]'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq '.management.labels_applied | length' "$json")" = "2" ]
  [ "$(jq -r '.management.labels_applied[0]' "$json")" = "severity:critical" ]
  [ "$(jq -r '.management.labels_applied[1]' "$json")" = "severity:high" ]
}

# ── duplicate candidates ─────────────────────────────────────────────────────

@test "duplicate candidates appear in management.duplicate_candidates" {
  export DUPLICATES_JSON='[{"number":10,"title":"Old login bug","score":0.92},{"number":23,"title":"Safari auth issue","score":0.85}]'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq '.management.duplicate_candidates | length' "$json")" = "2" ]
  [ "$(jq -r '.management.duplicate_candidates[0].number' "$json")" = "10" ]
  [ "$(jq -r '.management.duplicate_candidates[0].score' "$json")" = "0.92" ]
  [ "$(jq -r '.management.duplicate_candidates[1].number' "$json")" = "23" ]
}

@test "duplicate_candidates defaults to empty array" {
  export DUPLICATES_JSON=""
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq '.management.duplicate_candidates | length' "agent-workspace/runtime/ingest.json")" = "0" ]
}

# ── optional var defaults ────────────────────────────────────────────────────

@test "FORM_JSON defaults to empty object when not set" {
  export FORM_JSON=""
  run_script
  [ "$status" -eq 0 ]
  [ "$(jq '.form | length' "agent-workspace/runtime/ingest.json")" = "0" ]
  [ "$(jq -r '.form | type' "agent-workspace/runtime/ingest.json")" = "object" ]
}

@test "FORM_JSON is included when set" {
  export FORM_JSON='{"component":"login","browser":"safari"}'
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.form.component' "$json")" = "login" ]
  [ "$(jq -r '.form.browser' "$json")" = "safari" ]
}

@test "all optional vars default gracefully when unset" {
  unset COMMENT_JSON CLIENT_PAYLOAD_JSON FORM_JSON AREA_LABELS SEVERITY_LABELS DUPLICATES_JSON 2>/dev/null || true
  export COMMENT_JSON=""
  export CLIENT_PAYLOAD_JSON=""
  export FORM_JSON=""
  export AREA_LABELS=""
  export SEVERITY_LABELS=""
  export DUPLICATES_JSON=""
  run_script
  [ "$status" -eq 0 ]
  local json="agent-workspace/runtime/ingest.json"
  [ "$(jq -r '.comment' "$json")" = "null" ]
  [ "$(jq -r '.client_payload' "$json")" = "null" ]
  [ "$(jq '.form | type' "$json")" = "\"object\"" ]
  [ "$(jq '.management.labels_applied | length' "$json")" = "0" ]
  [ "$(jq '.management.duplicate_candidates | length' "$json")" = "0" ]
}

# ── issue number extraction ──────────────────────────────────────────────────

@test "issue number extracted from .issue.number" {
  run_script
  [ "$status" -eq 0 ]
  grep -q '^issue-number=42$' "$GITHUB_OUTPUT"
}

@test "issue number extracted from .client_payload.issue.number when issue is null" {
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON='{"issue":{"number":77}}'
  run_script
  [ "$status" -eq 0 ]
  grep -q '^issue-number=77$' "$GITHUB_OUTPUT"
}

@test "issue number is empty when neither source provides it" {
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON="null"
  run_script
  [ "$status" -eq 0 ]
  # issue-number= should be present but with an empty value
  grep -q '^issue-number=$' "$GITHUB_OUTPUT"
}

@test ".issue.number takes precedence over .client_payload.issue.number" {
  export CLIENT_PAYLOAD_JSON='{"issue":{"number":99}}'
  # ISSUE_JSON still has number:42 from setup
  run_script
  [ "$status" -eq 0 ]
  grep -q '^issue-number=42$' "$GITHUB_OUTPUT"
}

# ── plan subject extraction ──────────────────────────────────────────────────

@test "plan subject extracted from issue title" {
  run_script
  [ "$status" -eq 0 ]
  grep -q '^plan-subject=Login fails on Safari$' "$GITHUB_OUTPUT"
}

@test "plan subject falls back to client_payload.title" {
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON='{"title":"External triage request"}'
  run_script
  [ "$status" -eq 0 ]
  grep -q '^plan-subject=External triage request$' "$GITHUB_OUTPUT"
}

@test "plan subject falls back to client_payload.issue.title" {
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON='{"issue":{"title":"Nested title fallback"}}'
  run_script
  [ "$status" -eq 0 ]
  grep -q '^plan-subject=Nested title fallback$' "$GITHUB_OUTPUT"
}

@test "plan subject defaults to 'external issue event' when no title available" {
  export ISSUE_JSON="null"
  export CLIENT_PAYLOAD_JSON="null"
  run_script
  [ "$status" -eq 0 ]
  grep -q '^plan-subject=external issue event$' "$GITHUB_OUTPUT"
}

# ── GITHUB_OUTPUT ────────────────────────────────────────────────────────────

@test "GITHUB_OUTPUT contains ingest-json multiline block" {
  run_script
  [ "$status" -eq 0 ]
  grep -q '^ingest-json<<EOF$' "$GITHUB_OUTPUT"
  # The closing EOF marker should be present
  grep -q '^EOF$' "$GITHUB_OUTPUT"
}

@test "GITHUB_OUTPUT contains issue-number" {
  run_script
  [ "$status" -eq 0 ]
  grep -q '^issue-number=' "$GITHUB_OUTPUT"
}

@test "GITHUB_OUTPUT contains plan-subject" {
  run_script
  [ "$status" -eq 0 ]
  grep -q '^plan-subject=' "$GITHUB_OUTPUT"
}

@test "GITHUB_OUTPUT contains all three outputs in correct order" {
  run_script
  [ "$status" -eq 0 ]
  # ingest-json must appear before issue-number, which must appear before plan-subject
  local ingest_line
  local issue_line
  local subject_line
  ingest_line="$(grep -n '^ingest-json<<EOF$' "$GITHUB_OUTPUT" | head -1 | cut -d: -f1)"
  issue_line="$(grep -n '^issue-number=' "$GITHUB_OUTPUT" | head -1 | cut -d: -f1)"
  subject_line="$(grep -n '^plan-subject=' "$GITHUB_OUTPUT" | head -1 | cut -d: -f1)"
  [ "$ingest_line" -lt "$issue_line" ]
  [ "$issue_line" -lt "$subject_line" ]
}

# ── ingest-json output is valid JSON ─────────────────────────────────────────

@test "ingest-json output between EOF markers is valid JSON" {
  run_script
  [ "$status" -eq 0 ]
  # Extract the content between the first ingest-json<<EOF and the closing EOF
  local json_content
  json_content="$(sed -n '/^ingest-json<<EOF$/,/^EOF$/{ /^ingest-json<<EOF$/d; /^EOF$/d; p; }' "$GITHUB_OUTPUT")"
  echo "$json_content" | jq -e . >/dev/null
}

@test "ingest-json output matches the written ingest.json" {
  run_script
  [ "$status" -eq 0 ]
  local json_content
  json_content="$(sed -n '/^ingest-json<<EOF$/,/^EOF$/{ /^ingest-json<<EOF$/d; /^EOF$/d; p; }' "$GITHUB_OUTPUT")"
  diff <(jq -S . agent-workspace/runtime/ingest.json) <(echo "$json_content" | jq -S .)
}

# ── agent-workspace/runtime directory ─────────────────────────────────────────

@test "agent-workspace/runtime directory is created" {
  run_script
  [ "$status" -eq 0 ]
  [ -d agent-workspace/runtime ]
}

@test "ingest.json is written to agent-workspace/runtime/" {
  run_script
  [ "$status" -eq 0 ]
  [ -f agent-workspace/runtime/ingest.json ]
}

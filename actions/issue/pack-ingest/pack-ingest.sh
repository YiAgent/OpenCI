#!/usr/bin/env bash
# Builds the normalised ingest.json payload and emits job outputs.
set -euo pipefail

mkdir -p agent-workspace/runtime

jq -nc \
  --arg event_name      "$EVENT_NAME" \
  --arg event_action    "$EVENT_ACTION" \
  --arg mode            "$MODE" \
  --arg repo            "$REPO" \
  --argjson issue       "${ISSUE_JSON:-null}" \
  --argjson comment     "${COMMENT_JSON:-null}" \
  --argjson client_payload "${CLIENT_PAYLOAD_JSON:-null}" \
  --argjson form        "${FORM_JSON:-{\}}" \
  --argjson area_labels "${AREA_LABELS:-[]}" \
  --argjson severity_labels "${SEVERITY_LABELS:-[]}" \
  --argjson duplicate_candidates "${DUPLICATES_JSON:-[]}" \
  '{
    event: {name: $event_name, action: $event_action, mode: $mode},
    repo: {name: $repo},
    issue: $issue,
    comment: $comment,
    client_payload: $client_payload,
    form: $form,
    management: {
      labels_applied: ($area_labels + $severity_labels),
      duplicate_candidates: $duplicate_candidates,
      stale_action: null
    }
  }' > agent-workspace/runtime/ingest.json

issue_number="$(jq -r '.issue.number // .client_payload.issue.number // empty' \
  agent-workspace/runtime/ingest.json)"
subject="$(jq -r \
  '.issue.title // .client_payload.title // .client_payload.issue.title // "external issue event"' \
  agent-workspace/runtime/ingest.json)"

{
  echo "ingest-json<<EOF"
  cat agent-workspace/runtime/ingest.json
  echo "EOF"
  echo "issue-number=$issue_number"
  echo "plan-subject=$subject"
} >> "$GITHUB_OUTPUT"

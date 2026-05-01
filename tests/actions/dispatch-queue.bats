#!/usr/bin/env bats
# Tests for schedule-prd-dispatch + poll-prd-dispatch shell logic.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCHEDULE="${PROJECT_ROOT}/actions/_common/schedule-prd-dispatch/schedule.sh"
  POLL="${PROJECT_ROOT}/actions/_common/poll-prd-dispatch/poll.sh"
  TMP="$(mktemp -d)"
  QUEUE_FILE="${TMP}/queue.json"
  FIRED_FILE="${TMP}/fired.json"
}

teardown() {
  rm -rf "${TMP}"
}

iso_now_minus_min() {
  local minus="$1"
  if date -u -v "-${minus}M" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then return; fi
  date -u -d "-${minus} minutes" +%Y-%m-%dT%H:%M:%SZ
}

# ── schedule.sh ─────────────────────────────────────────────────────────────

@test "schedule appends a new entry to an empty queue" {
  ts="$(iso_now_minus_min 0)"
  run env -i \
    QUEUE_OVERRIDE='[]' QUEUE_OUT_FILE="${QUEUE_FILE}" \
    IMAGE_DIGEST="sha256:aaa" \
    STG_IMAGE_DIGEST="sha256:aaa" \
    STG_DEPLOY_TIME="${ts}" \
    IMAGE_NAME="my-app" APP_NAME="my-app" \
    OBSERVATION_MINUTES="30" \
    bash "${SCHEDULE}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "1" ]
  [ "$(jq -r '.[0].image_digest' "${QUEUE_FILE}")" = "sha256:aaa" ]
}

@test "schedule replaces an entry with the same image_digest (re-queue)" {
  ts="$(iso_now_minus_min 0)"
  initial="$(jq -nc --arg ts "$ts" \
    '[{fire_at:"2099-01-01T00:00:00Z", image_digest:"sha256:aaa",
       stg_image_digest:"sha256:aaa", stg_deploy_time:$ts,
       image_name:"x", app_name:"x", queued_at:$ts}]')"

  run env -i \
    QUEUE_OVERRIDE="${initial}" QUEUE_OUT_FILE="${QUEUE_FILE}" \
    IMAGE_DIGEST="sha256:aaa" STG_IMAGE_DIGEST="sha256:aaa" \
    STG_DEPLOY_TIME="${ts}" IMAGE_NAME="x" APP_NAME="x" \
    OBSERVATION_MINUTES="5" \
    bash "${SCHEDULE}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "1" ]
  fire_at="$(jq -r '.[0].fire_at' "${QUEUE_FILE}")"
  [ "$fire_at" != "2099-01-01T00:00:00Z" ]
}

@test "schedule rejects missing required env" {
  run env -i bash "${SCHEDULE}"
  [ "${status}" -eq 2 ]
}

@test "schedule resets queue when stored value isn't an array" {
  ts="$(iso_now_minus_min 0)"
  run env -i \
    QUEUE_OVERRIDE='"corrupt"' QUEUE_OUT_FILE="${QUEUE_FILE}" \
    IMAGE_DIGEST="sha256:aaa" STG_IMAGE_DIGEST="sha256:aaa" \
    STG_DEPLOY_TIME="${ts}" IMAGE_NAME="x" APP_NAME="x" \
    OBSERVATION_MINUTES="30" \
    bash "${SCHEDULE}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "1" ]
}

# ── poll.sh ─────────────────────────────────────────────────────────────────

@test "poll fires due entries and keeps future ones" {
  past="$(iso_now_minus_min 5)"
  far_future="2099-01-01T00:00:00Z"
  queue="$(jq -nc --arg past "$past" --arg fut "$far_future" \
    '[{fire_at:$past, image_digest:"sha256:due",  stg_image_digest:"x", stg_deploy_time:"2026-01-01T00:00:00Z", image_name:"x", app_name:"x", queued_at:"2026-01-01T00:00:00Z"},
      {fire_at:$fut,  image_digest:"sha256:wait", stg_image_digest:"x", stg_deploy_time:"2026-01-01T00:00:00Z", image_name:"x", app_name:"x", queued_at:"2026-01-01T00:00:00Z"}]')"

  run env -i \
    QUEUE_OVERRIDE="${queue}" QUEUE_OUT_FILE="${QUEUE_FILE}" \
    FIRED_OUT_FILE="${FIRED_FILE}" \
    bash "${POLL}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${FIRED_FILE}")" = "1" ]
  [ "$(jq -r '.[0].image_digest' "${FIRED_FILE}")" = "sha256:due" ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "1" ]
  [ "$(jq -r '.[0].image_digest' "${QUEUE_FILE}")" = "sha256:wait" ]
}

@test "poll on an empty queue is a no-op" {
  run env -i \
    QUEUE_OVERRIDE='[]' QUEUE_OUT_FILE="${QUEUE_FILE}" \
    FIRED_OUT_FILE="${FIRED_FILE}" \
    bash "${POLL}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${FIRED_FILE}")" = "0" ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "0" ]
}

@test "poll fires entries with unparseable timestamps (fail-open)" {
  bad="$(jq -nc '[{fire_at:"NOT-A-DATE", image_digest:"sha256:bad",
                  stg_image_digest:"x", stg_deploy_time:"x",
                  image_name:"x", app_name:"x", queued_at:"x"}]')"
  run env -i \
    QUEUE_OVERRIDE="${bad}" QUEUE_OUT_FILE="${QUEUE_FILE}" \
    FIRED_OUT_FILE="${FIRED_FILE}" \
    bash "${POLL}"
  [ "${status}" -eq 0 ]
  # Unparseable → treat as overdue → fire (so queue can't grow forever).
  [ "$(jq 'length' "${FIRED_FILE}")" = "1" ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "0" ]
}

@test "poll handles corrupted queue value" {
  run env -i \
    QUEUE_OVERRIDE='"corrupt"' QUEUE_OUT_FILE="${QUEUE_FILE}" \
    FIRED_OUT_FILE="${FIRED_FILE}" \
    bash "${POLL}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "0" ]
}

# ── round-trip ─────────────────────────────────────────────────────────────

@test "round-trip: schedule then poll fires the entry once OBSERVATION_MINUTES has elapsed" {
  ts="$(iso_now_minus_min 60)"
  # First schedule with 30-min observation window → fire_at is 30 min ago.
  run env -i \
    QUEUE_OVERRIDE='[]' QUEUE_OUT_FILE="${QUEUE_FILE}" \
    IMAGE_DIGEST="sha256:rt" STG_IMAGE_DIGEST="sha256:rt" \
    STG_DEPLOY_TIME="${ts}" IMAGE_NAME="x" APP_NAME="x" \
    OBSERVATION_MINUTES="30" \
    bash "${SCHEDULE}"
  [ "${status}" -eq 0 ]
  q_after_schedule="$(cat "${QUEUE_FILE}")"
  [ "$(jq 'length' <<<"${q_after_schedule}")" = "1" ]

  # Poll picks it up.
  run env -i \
    QUEUE_OVERRIDE="${q_after_schedule}" \
    QUEUE_OUT_FILE="${QUEUE_FILE}" FIRED_OUT_FILE="${FIRED_FILE}" \
    bash "${POLL}"
  [ "${status}" -eq 0 ]
  [ "$(jq 'length' "${FIRED_FILE}")" = "1" ]
  [ "$(jq -r '.[0].image_digest' "${FIRED_FILE}")" = "sha256:rt" ]
  [ "$(jq 'length' "${QUEUE_FILE}")" = "0" ]
}

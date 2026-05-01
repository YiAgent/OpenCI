#!/usr/bin/env bats
# Tests for actions/_common/validate-env/check.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/_common/validate-env/check.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/env-matrix/standard.md"
  MISSING_FIX="${BATS_TEST_DIRNAME}/fixtures/env-matrix/does-not-exist.md"
}

@test "skipped (notice) when ENV_MATRIX.md is missing" {
  run env -i ENV_MATRIX_PATH="${MISSING_FIX}" TARGET_ENV="prd" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Env Matrix Skipped"* ]]
}

@test "missing TARGET_ENV → exit 2" {
  run env -i ENV_MATRIX_PATH="${FIX}" bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "stg with DB_URL+API_KEY set → ok, exit 0" {
  run env -i \
    DB_URL="x" API_KEY="y" \
    ENV_MATRIX_PATH="${FIX}" TARGET_ENV="stg" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Env Matrix OK"* ]]
}

@test "prd missing DB_URL → exit 1, error annotation" {
  run env -i \
    API_KEY="y" \
    ENV_MATRIX_PATH="${FIX}" TARGET_ENV="prd" \
    bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Missing Env Var::DB_URL"* ]]
}

@test "prd missing both → reports each separately" {
  run env -i \
    ENV_MATRIX_PATH="${FIX}" TARGET_ENV="prd" \
    bash "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Missing Env Var::DB_URL"* ]]
  [[ "${output}${stderr:-}" == *"Missing Env Var::API_KEY"* ]]
}

@test "dev requires only DEV_ONLY + API_KEY" {
  run env -i \
    DEV_ONLY="ok" API_KEY="ok" \
    ENV_MATRIX_PATH="${FIX}" TARGET_ENV="dev" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "dev does NOT require DB_URL" {
  run env -i \
    DEV_ONLY="ok" API_KEY="ok" \
    ENV_MATRIX_PATH="${FIX}" TARGET_ENV="dev" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  # DB_URL is unset but only required for stg/prd.
}

@test "scopes column with comma-only separator parses correctly" {
  TMP="$(mktemp)"
  cat >"$TMP" <<'EOF'
| Var Name | Required In | Source |
| -------- | ----------- | ------ |
| FOO | stg,prd | x |
EOF
  run env -i FOO="ok" ENV_MATRIX_PATH="$TMP" TARGET_ENV="prd" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  rm -f "$TMP"
}

@test "non-table lines are ignored" {
  TMP="$(mktemp)"
  cat >"$TMP" <<'EOF'
# Header

Some prose paragraph that should not be parsed as a row.

| Var Name | Required In | Source |
| -------- | ----------- | ------ |
| FOO | prd | x |
EOF
  run env -i FOO="ok" ENV_MATRIX_PATH="$TMP" TARGET_ENV="prd" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  rm -f "$TMP"
}

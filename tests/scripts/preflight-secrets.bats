#!/usr/bin/env bats
# Tests for .github/scripts/preflight-secrets.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/.github/scripts/preflight-secrets.sh"
}

@test "exit 0 when no required and no optional given" {
  run env -i bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "required FOO missing → exit 1, error annotation" {
  run env -i bash "${SCRIPT}" --required "FOO"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"::error title=Missing Secret::FOO"* ]]
  [[ "${output}${stderr:-}" == *"Preflight Failed"* ]]
}

@test "required FOO present → exit 0, notice annotation" {
  run env -i FOO=set bash "${SCRIPT}" --required "FOO"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice title=Secret Available::FOO"* ]]
}

@test "optional BAR missing → exit 0, skipped notice (NOT error)" {
  run env -i bash "${SCRIPT}" --required "" --optional "BAR"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice title=Optional Secret Skipped::BAR"* ]]
  [[ "${output}${stderr:-}" != *"::error"* ]]
}

@test "optional BAR present → notice Optional Secret Available" {
  run env -i BAR=hello bash "${SCRIPT}" --optional "BAR"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice title=Optional Secret Available::BAR"* ]]
}

@test "secret value is NOT printed (only name)" {
  run env -i SECRET=topsecret bash "${SCRIPT}" --required "SECRET"
  [ "${status}" -eq 0 ]
  [[ "${output}${stderr:-}" != *"topsecret"* ]]
  [[ "${output}" == *"SECRET"* ]]
}

@test "multiple required, mixed presence → reports all missing, exit 1" {
  run env -i A=1 bash "${SCRIPT}" --required "A,B,C"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Missing Secret::B"* ]]
  [[ "${output}${stderr:-}" == *"Missing Secret::C"* ]]
  [[ "${output}" == *"Secret Available::A"* ]]
}

@test "CSV trims whitespace around names" {
  run env -i FOO=1 BAR=2 bash "${SCRIPT}" --required " FOO ,  BAR "
  [ "${status}" -eq 0 ]
}

@test "empty optional CSV is allowed" {
  run env -i bash "${SCRIPT}" --required "" --optional ""
  [ "${status}" -eq 0 ]
}

@test "unknown flag → exit 2" {
  run env -i bash "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  [[ "${output}${stderr:-}" == *"Bad Argument"* ]]
}

@test "completes in under 1 second for 6 names" {
  start=$(date +%s)
  env -i bash "${SCRIPT}" --required "A,B,C" --optional "D,E,F" >/dev/null 2>&1 || true
  end=$(date +%s)
  diff=$(( end - start ))
  [ "${diff}" -lt 2 ]
}

@test "value of one missing required does not abort the loop (set -u tolerated)" {
  run env -i bash "${SCRIPT}" --required "MISSING_X"
  [ "${status}" -eq 1 ]
  [[ "${output}${stderr:-}" == *"Missing Secret::MISSING_X"* ]]
}

#!/usr/bin/env bats
# Tests for actions/issue/auto-label/label-from-form.sh + validate-form/extract.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  EXTRACT="${PROJECT_ROOT}/actions/issue/validate-form/extract.sh"
  LABEL_SH="${PROJECT_ROOT}/actions/issue/auto-label/label-from-form.sh"
  export EXTRACT_SH="${EXTRACT}"
}

bug_form_body() {
  cat <<'EOF'
### Area

frontend

### Severity

high (cannot ship feature)

### What's broken?

Login button doesn't redirect.

### Steps to reproduce

1. open /login
2. click button
EOF
}

@test "extract.sh pulls field value with surrounding blank lines stripped" {
  body="$(bug_form_body)"
  run env -i ISSUE_BODY="${body}" FIELD="Area" bash "${EXTRACT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "frontend" ]
}

@test "extract.sh returns empty when field missing" {
  body="$(bug_form_body)"
  run env -i ISSUE_BODY="${body}" FIELD="Nonexistent" bash "${EXTRACT}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "label-from-form (no gh) reports area + severity labels" {
  body="$(bug_form_body)"
  run env -i ISSUE_BODY="${body}" ISSUE_TITLE="bug: x" \
            EXTRACT_SH="${EXTRACT}" \
            bash "${LABEL_SH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"area:frontend"* ]]
  [[ "${output}" == *"severity:high"* ]]
}

@test "security keyword in title triggers security + private-discuss" {
  body="$(bug_form_body)"
  run env -i ISSUE_BODY="${body}" ISSUE_TITLE="possible API key leak in logs" \
            EXTRACT_SH="${EXTRACT}" \
            bash "${LABEL_SH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"security"* ]]
  [[ "${output}" == *"private-discuss"* ]]
}

@test "no derivable labels prints notice and exits 0" {
  body="### Other\n\nrandom"
  run env -i ISSUE_BODY="$(printf '%b' "$body")" ISSUE_TITLE="x" \
            EXTRACT_SH="${EXTRACT}" \
            bash "${LABEL_SH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no derivable labels from form"* ]]
}

@test "unknown area token is dropped (no label)" {
  body=$'### Area\n\nmars\n\n### Severity\n\nlow'
  run env -i ISSUE_BODY="${body}" ISSUE_TITLE="x" \
            EXTRACT_SH="${EXTRACT}" \
            bash "${LABEL_SH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"severity:low"* ]]
  [[ "${output}" != *"area:mars"* ]]
}

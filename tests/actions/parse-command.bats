#!/usr/bin/env bats
# Tests for actions/issue/parse-command/parse.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/parse-command/parse.sh"
}

@test "no slash command → command=none, authorized=false" {
  run env -i COMMENT_BODY="hello, just chatting" AUTHOR_ASSOC=OWNER bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=none"* ]]
  [[ "${output}" == *"authorized=false"* ]]
}

@test "/help is authorized for anyone" {
  run env -i COMMENT_BODY="/help" AUTHOR_ASSOC=NONE bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=help"* ]]
  [[ "${output}" == *"authorized=true"* ]]
}

@test "/assign @bob authorized for OWNER" {
  run env -i COMMENT_BODY="/assign @bob" AUTHOR_ASSOC=OWNER bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=assign"* ]]
  [[ "${output}" == *"args=@bob"* ]]
  [[ "${output}" == *"authorized=true"* ]]
}

@test "/close NOT authorized for CONTRIBUTOR" {
  run env -i COMMENT_BODY="/close" AUTHOR_ASSOC=CONTRIBUTOR bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=close"* ]]
  [[ "${output}" == *"authorized=false"* ]]
  [[ "${output}" == *"::notice title=Unauthorized Command"* ]]
}

@test "MEMBER and COLLABORATOR are authorized" {
  for assoc in MEMBER COLLABORATOR; do
    run env -i COMMENT_BODY="/priority p1" AUTHOR_ASSOC="$assoc" bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"authorized=true"* ]]
  done
}

@test "unknown command → command=none" {
  run env -i COMMENT_BODY="/foobar nope" AUTHOR_ASSOC=OWNER bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=none"* ]]
  [[ "${output}" == *"authorized=false"* ]]
}

@test "command on a non-first line still parses" {
  run env -i COMMENT_BODY=$'thanks!\n/label foo' AUTHOR_ASSOC=OWNER bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=label"* ]]
  [[ "${output}" == *"args=foo"* ]]
}

@test "leading whitespace before slash is tolerated" {
  run env -i COMMENT_BODY="   /needs-info" AUTHOR_ASSOC=OWNER bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"command=needs-info"* ]]
  [[ "${output}" == *"authorized=true"* ]]
}

@test "writes to GITHUB_OUTPUT" {
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" env -i \
    GITHUB_OUTPUT="$out" COMMENT_BODY="/triage" AUTHOR_ASSOC=OWNER \
    bash "${SCRIPT}" >/dev/null
  grep -q '^command=triage$'  "$out"
  grep -q '^authorized=true$' "$out"
  rm -f "$out"
}

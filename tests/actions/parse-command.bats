#!/usr/bin/env bats
# Tests for actions/issue/parse-command/parse.sh
#
# Reads env:  COMMENT_BODY, AUTHOR_ASSOC
# Writes:     command, args, authorized  (stdout + GITHUB_OUTPUT)

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/parse-command/parse.sh"
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

# ── helpers ──────────────────────────────────────────────────────────────────

# Run the parser with given body and association.
run_parse() {
  local body="$1" assoc="${2:-NONE}"
  run env -i COMMENT_BODY="$body" AUTHOR_ASSOC="$assoc" \
      GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
  [ "${status}" -eq 0 ]
}

# Extract a key=value from stdout.
stdout_kv() {
  local key="$1"
  printf '%s\n' "${lines[@]}" | grep -m1 "^${key}=" | sed "s/^${key}=//"
}

# Extract a key=value from GITHUB_OUTPUT file.
ghout_kv() {
  local key="$1"
  grep -m1 "^${key}=" "$GITHUB_OUTPUT" | sed "s/^${key}=//"
}

# ── 1. No command in body ────────────────────────────────────────────────────

@test "no command → command=none, args empty, authorized=false" {
  run_parse "just a regular comment"
  [ "$(stdout_kv command)" = "none" ]
  [ "$(stdout_kv args)" = "" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "empty body → command=none" {
  run_parse ""
  [ "$(stdout_kv command)" = "none" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

# ── 2. Valid command as OWNER ────────────────────────────────────────────────

@test "/assign @user as OWNER → authorized=true" {
  run_parse "/assign @user" "OWNER"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv args)" = "@user" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

# ── 3. Valid command as MEMBER ───────────────────────────────────────────────

@test "/label bug as MEMBER → authorized=true" {
  run_parse "/label bug" "MEMBER"
  [ "$(stdout_kv command)" = "label" ]
  [ "$(stdout_kv args)" = "bug" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

# ── 4. Valid command as COLLABORATOR ─────────────────────────────────────────

@test "/close as COLLABORATOR → authorized=true" {
  run_parse "/close" "COLLABORATOR"
  [ "$(stdout_kv command)" = "close" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

# ── 5. /help is public ──────────────────────────────────────────────────────

@test "/help as CONTRIBUTOR → authorized=true" {
  run_parse "/help" "CONTRIBUTOR"
  [ "$(stdout_kv command)" = "help" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

@test "/help as NONE → authorized=true" {
  run_parse "/help" "NONE"
  [ "$(stdout_kv command)" = "help" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

# ── 6. Unauthorized for CONTRIBUTOR / NONE ───────────────────────────────────

@test "/assign @user as CONTRIBUTOR → authorized=false" {
  run_parse "/assign @user" "CONTRIBUTOR"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv args)" = "@user" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "/assign @user as NONE → authorized=false" {
  run_parse "/assign @user" "NONE"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv args)" = "@user" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "/label bug as CONTRIBUTOR → authorized=false" {
  run_parse "/label bug" "CONTRIBUTOR"
  [ "$(stdout_kv command)" = "label" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

# ── 7. Unknown command ──────────────────────────────────────────────────────

@test "/foo (unknown) → command=none, authorized=false" {
  run_parse "/foo"
  [ "$(stdout_kv command)" = "none" ]
  [ "$(stdout_kv args)" = "" ]
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "/deploy (unknown) → command=none" {
  run_parse "/deploy prod"
  [ "$(stdout_kv command)" = "none" ]
}

# ── 8. Multi-line body ──────────────────────────────────────────────────────

@test "command on second line of multi-line body" {
  run_parse $'some preamble text\n/assign @alice' "OWNER"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv args)" = "@alice" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

@test "command on third line, first lines are noise" {
  run_parse $'line one\nline two\n/close' "MEMBER"
  [ "$(stdout_kv command)" = "close" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

# ── 9. Leading whitespace ───────────────────────────────────────────────────

@test "command with leading spaces" {
  run_parse "   /close" "OWNER"
  [ "$(stdout_kv command)" = "close" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

@test "command with leading tab" {
  run_parse $'\t/label enhancement' "MEMBER"
  [ "$(stdout_kv command)" = "label" ]
  [ "$(stdout_kv args)" = "enhancement" ]
}

# ── 10. No args ─────────────────────────────────────────────────────────────

@test "/close with no args → args is empty" {
  run_parse "/close" "OWNER"
  [ "$(stdout_kv command)" = "close" ]
  [ "$(stdout_kv args)" = "" ]
}

@test "/reopen with no args → args is empty" {
  run_parse "/reopen" "COLLABORATOR"
  [ "$(stdout_kv command)" = "reopen" ]
  [ "$(stdout_kv args)" = "" ]
}

@test "/help with no args → args is empty" {
  run_parse "/help"
  [ "$(stdout_kv command)" = "help" ]
  [ "$(stdout_kv args)" = "" ]
}

# ── 11. All 11 supported commands are recognized ────────────────────────────

@test "all commands recognized: assign" {
  run_parse "/assign @x" "OWNER"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv authorized)" = "true" ]
}

@test "all commands recognized: unassign" {
  run_parse "/unassign @x" "OWNER"
  [ "$(stdout_kv command)" = "unassign" ]
}

@test "all commands recognized: label" {
  run_parse "/label bug" "OWNER"
  [ "$(stdout_kv command)" = "label" ]
}

@test "all commands recognized: unlabel" {
  run_parse "/unlabel wontfix" "OWNER"
  [ "$(stdout_kv command)" = "unlabel" ]
}

@test "all commands recognized: priority" {
  run_parse "/priority p1" "OWNER"
  [ "$(stdout_kv command)" = "priority" ]
}

@test "all commands recognized: close" {
  run_parse "/close" "OWNER"
  [ "$(stdout_kv command)" = "close" ]
}

@test "all commands recognized: reopen" {
  run_parse "/reopen" "OWNER"
  [ "$(stdout_kv command)" = "reopen" ]
}

@test "all commands recognized: duplicate" {
  run_parse "/duplicate #42" "OWNER"
  [ "$(stdout_kv command)" = "duplicate" ]
}

@test "all commands recognized: needs-info" {
  run_parse "/needs-info please clarify" "OWNER"
  [ "$(stdout_kv command)" = "needs-info" ]
}

@test "all commands recognized: triage" {
  run_parse "/triage" "OWNER"
  [ "$(stdout_kv command)" = "triage" ]
}

@test "all commands recognized: help" {
  run_parse "/help"
  [ "$(stdout_kv command)" = "help" ]
}

# ── 12. Command extraction ignores non-command lines ────────────────────────

@test "non-command lines before slash command are ignored" {
  run_parse $'please fix this bug\n/assign @bob' "MEMBER"
  [ "$(stdout_kv command)" = "assign" ]
  [ "$(stdout_kv args)" = "@bob" ]
}

@test "lines starting with / but uppercase are not commands" {
  run_parse $'/Assign @user' "OWNER"
  [ "$(stdout_kv command)" = "none" ]
}

@test "lines starting with / but containing digits are not commands" {
  run_parse $'/123invalid' "OWNER"
  [ "$(stdout_kv command)" = "none" ]
}

# ── 13. GITHUB_OUTPUT file is written correctly ─────────────────────────────

@test "GITHUB_OUTPUT receives command, args, authorized" {
  run_parse "/assign @user" "OWNER"
  [ "$(ghout_kv command)" = "assign" ]
  [ "$(ghout_kv args)" = "@user" ]
  [ "$(ghout_kv authorized)" = "true" ]
}

@test "GITHUB_OUTPUT receives none values for empty body" {
  run_parse ""
  [ "$(ghout_kv command)" = "none" ]
  [ "$(ghout_kv args)" = "" ]
  [ "$(ghout_kv authorized)" = "false" ]
}

@test "GITHUB_OUTPUT receives unauthorized for restricted command" {
  run_parse "/close" "NONE"
  [ "$(ghout_kv command)" = "close" ]
  [ "$(ghout_kv authorized)" = "false" ]
}

# ── 14. Authorization for all privileged associations ───────────────────────

@test "OWNER can run any command" {
  for cmd in assign unassign label unlabel priority close reopen duplicate needs-info triage; do
    run_parse "/${cmd} arg" "OWNER"
    [ "$(stdout_kv authorized)" = "true" ]
  done
}

@test "MEMBER can run any command" {
  for cmd in assign unassign label unlabel priority close reopen duplicate needs-info triage; do
    run_parse "/${cmd} arg" "MEMBER"
    [ "$(stdout_kv authorized)" = "true" ]
  done
}

@test "COLLABORATOR can run any command" {
  for cmd in assign unassign label unlabel priority close reopen duplicate needs-info triage; do
    run_parse "/${cmd} arg" "COLLABORATOR"
    [ "$(stdout_kv authorized)" = "true" ]
  done
}

# ── 15. Authorization for unprivileged associations ─────────────────────────

@test "CONTRIBUTOR cannot run /assign" {
  run_parse "/assign @x" "CONTRIBUTOR"
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "NONE cannot run /close" {
  run_parse "/close" "NONE"
  [ "$(stdout_kv authorized)" = "false" ]
}

@test "FIRST_TIME_CONTRIBUTOR cannot run /label" {
  run_parse "/label bug" "FIRST_TIME_CONTRIBUTOR"
  [ "$(stdout_kv authorized)" = "false" ]
}

# ── 16. Args trimming ───────────────────────────────────────────────────────

@test "trailing whitespace is trimmed from args" {
  run_parse "/label bug   " "OWNER"
  [ "$(stdout_kv args)" = "bug" ]
}

@test "args with multiple tokens preserved" {
  run_parse "/assign @user to area/backend" "OWNER"
  [ "$(stdout_kv args)" = "@user to area/backend" ]
}

# ── 17. Default AUTHOR_ASSOC when unset ─────────────────────────────────────

@test "missing AUTHOR_ASSOC defaults to NONE → unauthorized" {
  run env -i COMMENT_BODY="/close" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPT"
  [ "${status}" -eq 0 ]
  local cmd
  cmd="$(printf '%s\n' "${lines[@]}" | grep -m1 '^command=' | sed 's/^command=//')"
  [ "$cmd" = "close" ]
  local auth
  auth="$(printf '%s\n' "${lines[@]}" | grep -m1 '^authorized=' | sed 's/^authorized=//')"
  [ "$auth" = "false" ]
}

# ── 18. Exit code always 0 ──────────────────────────────────────────────────

@test "always exits 0 even with no command" {
  run_parse "no command here"
  [ "${status}" -eq 0 ]
}

@test "always exits 0 with unknown command" {
  run_parse "/nonexistent"
  [ "${status}" -eq 0 ]
}

@test "always exits 0 with empty body" {
  run_parse ""
  [ "${status}" -eq 0 ]
}

@test "always exits 0 for authorized command" {
  run_parse "/close" "OWNER"
  [ "${status}" -eq 0 ]
}

@test "always exits 0 for unauthorized command" {
  run_parse "/close" "NONE"
  [ "${status}" -eq 0 ]
}

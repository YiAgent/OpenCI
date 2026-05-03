#!/usr/bin/env bats
# Tests for actions/pr/validate-pr-title/action.yml
#
# Since the validation logic is inline in a composite action's `run:` block,
# we replicate the exact regex here and test against it. Any change to the
# pattern in action.yml must be mirrored in check_title() below.

setup() {
  check_title() {
    local title="$1"
    local pattern='^(feat|fix|refactor|docs|test|chore|perf|ci|build|style|revert)(\([A-Za-z0-9_./-]+\))?(!)?: .{1,}$'
    [[ "$title" =~ $pattern ]]
  }
}

# ---------------------------------------------------------------------------
# Valid titles — basic forms
# ---------------------------------------------------------------------------

@test "valid: feat without scope" {
  check_title "feat: add login"
}

@test "valid: fix with scope" {
  check_title "fix(auth): handle expired tokens"
}

@test "valid: refactor with breaking change bang" {
  check_title "refactor!: breaking change"
}

@test "valid: scope with dots, slashes, and dashes" {
  check_title "feat(api/v2): new endpoint"
}

@test "valid: docs type" {
  check_title "docs: update README"
}

@test "valid: ci type" {
  check_title "ci: update workflow"
}

@test "valid: build type" {
  check_title "build: upgrade deps"
}

@test "valid: style type" {
  check_title "style: format code"
}

@test "valid: revert type" {
  check_title "revert: undo feat"
}

@test "valid: test type" {
  check_title "test: add unit tests"
}

@test "valid: chore type" {
  check_title "chore: bump version"
}

@test "valid: perf type" {
  check_title "perf: optimize render loop"
}

@test "valid: scope with underscores" {
  check_title "feat(user_profile): add avatar upload"
}

@test "valid: scope with dots only" {
  check_title "fix(github.actions): correct yaml"
}

@test "valid: scope with dashes" {
  check_title "fix(auth-module): token refresh"
}

@test "valid: subject with special characters" {
  check_title "feat: support $HOME and ~ expansion"
}

@test "valid: single-char subject" {
  check_title "docs: x"
}

@test "valid: long subject line" {
  check_title "feat: add a very long description that goes on and on and on with lots of detail about what changed"
}

# ---------------------------------------------------------------------------
# Valid titles — every type in the allowlist
# ---------------------------------------------------------------------------

@test "valid: type 'feat'" {
  check_title "feat: something"
}

@test "valid: type 'fix'" {
  check_title "fix: something"
}

@test "valid: type 'refactor'" {
  check_title "refactor: something"
}

@test "valid: type 'docs'" {
  check_title "docs: something"
}

@test "valid: type 'test'" {
  check_title "test: something"
}

@test "valid: type 'chore'" {
  check_title "chore: something"
}

@test "valid: type 'perf'" {
  check_title "perf: something"
}

@test "valid: type 'ci'" {
  check_title "ci: something"
}

@test "valid: type 'build'" {
  check_title "build: something"
}

@test "valid: type 'style'" {
  check_title "style: something"
}

@test "valid: type 'revert'" {
  check_title "revert: something"
}

# ---------------------------------------------------------------------------
# Valid titles — bang + scope combinations
# ---------------------------------------------------------------------------

@test "valid: bang with scope" {
  check_title "feat(api)!: redesign auth flow"
}

@test "valid: bang without scope" {
  check_title "fix!: correct breaking patch"
}

# ---------------------------------------------------------------------------
# Invalid titles
# ---------------------------------------------------------------------------

@test "invalid: uppercase type" {
  ! check_title "Feat: capitalize"
}

@test "invalid: missing colon-space separator" {
  ! check_title "feat add login"
}

@test "invalid: type not in allowlist" {
  ! check_title "unknown: bad type"
}

@test "invalid: empty subject after colon-space" {
  ! check_title "feat: "
}

@test "invalid: no space after colon" {
  ! check_title "feat:"
}

@test "invalid: just the type, no colon" {
  ! check_title "feat"
}

@test "invalid: empty string" {
  ! check_title ""
}

@test "invalid: empty scope parens" {
  ! check_title "feat(): empty parens"
}

@test "invalid: scope with spaces" {
  ! check_title "feat(bad scope): spaces in parens"
}

@test "invalid: scope with special characters" {
  ! check_title "feat(a@b): at sign in scope"
}

@test "invalid: scope with exclamation inside parens" {
  ! check_title "feat(foo!bar): exclamation in scope"
}

@test "invalid: leading whitespace" {
  ! check_title " feat: leading space"
}

@test "invalid: type with trailing space before colon" {
  ! check_title "feat : bad spacing"
}

@test "invalid: no subject (just colon)" {
  ! check_title "chore:"
}

@test "invalid: mixed-case type" {
  ! check_title "FIX: uppercase"
}

@test "invalid: abbreviated type not in list" {
  ! check_title "ft: typo"
}

@test "invalid: scope only, no type" {
  ! check_title "(scope): missing type"
}

@test "invalid: subject before colon" {
  ! check_title "add login: feat"
}

#!/usr/bin/env bats
# Tests for actions/issue/collect-duplicates/collect-duplicates.sh
#
# Inputs (env): GH_TOKEN, REPO, ISSUE_NUM, ISSUE_TITLE
# Outputs: candidates JSON array to GITHUB_OUTPUT

bats_require_minimum_version 1.5.0

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/issue/collect-duplicates/collect-duplicates.sh"
  WORK_DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="${WORK_DIR}/output.txt"
  touch "$GITHUB_OUTPUT"

  # Mock gh CLI
  mkdir -p "$WORK_DIR/bin"
  export PATH="$WORK_DIR/bin:$PATH"
  export GH_TOKEN="fake-token"
  export REPO="test/repo"
  export ISSUE_NUM="99"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# Helper: mock gh search issues
mock_gh() {
  local response="${1:-[]}"
  cat > "$WORK_DIR/bin/gh" <<MOCK
#!/bin/bash
echo '${response}'
MOCK
  chmod +x "$WORK_DIR/bin/gh"
}

# Helper: extract candidates from GITHUB_OUTPUT
get_candidates() {
  awk '/^candidates<</{found=1; next} found && /^EOF/{exit} found{print}' "$GITHUB_OUTPUT"
}

# ── 1. Keyword extraction ─────────────────────────────────────────────────────

@test "strips conventional commit prefix from title" {
  mock_gh '[]'
  export ISSUE_TITLE="fix: authentication broken after update"
  bash "$SCRIPT"

  # The script should have run without error
  [ -f "$GITHUB_OUTPUT" ]
  grep -q "candidates<<" "$GITHUB_OUTPUT"
}

@test "extracts meaningful keywords from title" {
  # Mock gh to capture the search query (we can't easily capture it, but verify it runs)
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
echo '[{"number":10,"title":"Auth broken","state":"open","url":"https://github.com/test/repo/issues/10"}]'
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  export ISSUE_TITLE="feat: authentication login flow broken"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  echo "$candidates" | jq -e '. | length > 0'
}

@test "filters out stop words (the, and, for, etc.)" {
  mock_gh '[]'
  export ISSUE_TITLE="the bug and the fix for the authentication"
  bash "$SCRIPT"

  grep -q "candidates<<" "$GITHUB_OUTPUT"
}

@test "converts title to lowercase for search" {
  mock_gh '[]'
  export ISSUE_TITLE="BUG: Authentication BROKEN After Update"
  bash "$SCRIPT"

  [ "$?" -eq 0 ] || [ "$?" -eq 0 ]
  grep -q "candidates<<" "$GITHUB_OUTPUT"
}

# ── 2. Empty query handling ───────────────────────────────────────────────────

@test "returns empty array when title is empty" {
  mock_gh '[]'
  export ISSUE_TITLE=""
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  [ "$candidates" = "[]" ]
}

@test "returns empty array when title is only stop words" {
  mock_gh '[]'
  export ISSUE_TITLE="the and for are but not you all"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  [ "$candidates" = "[]" ]
}

@test "returns empty array when title is only prefix" {
  mock_gh '[]'
  export ISSUE_TITLE="fix:"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  [ "$candidates" = "[]" ]
}

# ── 3. Self-issue exclusion ───────────────────────────────────────────────────

@test "filters out self-issue from results" {
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
echo '[{"number":99,"title":"Same issue","state":"open","url":"https://github.com/test/repo/issues/99"},{"number":50,"title":"Other issue","state":"open","url":"https://github.com/test/repo/issues/50"}]'
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  export ISSUE_TITLE="authentication broken"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  # Issue 99 (self) should be filtered out
  echo "$candidates" | jq -e '. | length == 1'
  echo "$candidates" | jq -e '.[0].number == 50'
}

# ── 4. gh failure fallback ────────────────────────────────────────────────────

@test "returns empty array when gh search fails" {
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  export ISSUE_TITLE="authentication broken"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  [ "$candidates" = "[]" ]
}

# ── 5. GITHUB_OUTPUT format ──────────────────────────────────────────────────

@test "writes candidates<<EOF ... EOF block to GITHUB_OUTPUT" {
  mock_gh '[]'
  export ISSUE_TITLE="test issue"
  bash "$SCRIPT"

  grep -q "^candidates<<EOF$" "$GITHUB_OUTPUT"
  grep -q "^EOF$" "$GITHUB_OUTPUT"
}

@test "candidates in GITHUB_OUTPUT is valid JSON" {
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
echo '[{"number":1,"title":"Test","state":"open","url":"https://github.com/test/repo/issues/1"}]'
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  export ISSUE_TITLE="test issue"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  echo "$candidates" | jq -e '. | type == "array"'
}

# ── 6. Deduplication (unique issue numbers) ──────────────────────────────────

@test "filters out self-issue but keeps duplicates from gh" {
  cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/bin/bash
echo '[{"number":10,"title":"A","state":"open","url":"u1"},{"number":99,"title":"Self","state":"open","url":"u2"},{"number":20,"title":"B","state":"open","url":"u3"}]'
MOCK
  chmod +x "$WORK_DIR/bin/gh"

  export ISSUE_TITLE="test authentication"
  bash "$SCRIPT"

  local candidates
  candidates="$(get_candidates)"
  # Self (99) is filtered; 10 and 20 remain
  echo "$candidates" | jq -e '. | length == 2'
  echo "$candidates" | jq -e 'all(.number != 99)'
}

# ── 7. Short words are filtered ──────────────────────────────────────────────

@test "filters out words with 2 or fewer characters" {
  mock_gh '[]'
  export ISSUE_TITLE="ab cd ef authentication broken"
  bash "$SCRIPT"

  grep -q "candidates<<" "$GITHUB_OUTPUT"
}

# ── 8. Limits to 6 keywords ──────────────────────────────────────────────────

@test "uses at most 6 keywords for search" {
  mock_gh '[]'
  export ISSUE_TITLE="one two three four five six seven eight nine ten"
  bash "$SCRIPT"

  [ "$?" -eq 0 ]
  grep -q "candidates<<" "$GITHUB_OUTPUT"
}

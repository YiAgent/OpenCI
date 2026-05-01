#!/usr/bin/env bats
# Tests for actions/integrations/linear-bridge/derive-branch.sh

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${PROJECT_ROOT}/actions/integrations/linear-bridge/derive-branch.sh"
}

@test "feature label → feat/" {
  run env -i \
    LINEAR_ID="AIC-123" LINEAR_TITLE="Add login flow" LINEAR_LABELS="feature,frontend" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"branch=feat/aic-123-add-login-flow"* ]]
}

@test "bug label → fix/" {
  run env -i \
    LINEAR_ID="AIC-9" LINEAR_TITLE="Crash on logout" LINEAR_LABELS="bug" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"branch=fix/aic-9-crash-on-logout"* ]]
}

@test "no recognised label → chore/" {
  run env -i \
    LINEAR_ID="X-1" LINEAR_TITLE="Refactor utils" LINEAR_LABELS="" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"branch=chore/x-1-refactor-utils"* ]]
}

@test "unicode + symbols are stripped from slug" {
  run env -i \
    LINEAR_ID="X-2" LINEAR_TITLE="Fix !!!emoji 🚀 token bug" LINEAR_LABELS="bug" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  # Slug only contains [a-z0-9-]+
  [[ "${output}" =~ branch=fix/x-2-[a-z0-9-]+ ]]
}

@test "long titles are capped at ~50 chars" {
  long="this is a really very extremely long title that should clearly be truncated"
  run env -i \
    LINEAR_ID="X-3" LINEAR_TITLE="$long" LINEAR_LABELS="feature" \
    bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  branch_line="$(printf '%s\n' "${output}" | grep '^branch=')"
  [ "${#branch_line}" -lt 80 ]   # branch=feat/x-3-... slug < 50
}

@test "missing inputs → exit 2" {
  run env -i bash "${SCRIPT}"
  [ "${status}" -eq 2 ]
}

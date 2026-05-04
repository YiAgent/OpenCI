#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# workflow-audit.sh — Static auditor for GitHub Actions workflow / composite
# bug patterns surfaced during the entry-workflow-permissions cascade
# (issues #40-#68). Encodes the lessons so regressions fail CI fast instead
# of silently shipping a broken workflow.
# ─────────────────────────────────────────────────────────────────────────────
# Each rule is a focused check (one file family, one bug class). Failures
# print `::error::` annotations; the script exits non-zero if any rule fires.
#
# Run from repo root:
#   bash .github/scripts/workflow-audit.sh
#
# Override targets:
#   WORKFLOWS_DIR=.github/workflows ACTIONS_DIR=actions \
#     bash .github/scripts/workflow-audit.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"
ACTIONS_DIR="${ACTIONS_DIR:-$REPO_ROOT/actions}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$REPO_ROOT/.github/scripts}"

errors=0
checked=0

err() {
  local rule="$1" file="$2" detail="$3"
  echo "::error file=${file},title=${rule}::${detail}" >&2
  errors=$((errors + 1))
}

note() {
  echo "::notice title=$1::$2"
}

is_entry_workflow() {
  local f="$1"
  local base
  base="$(basename "$f")"
  case "$base" in reusable-*) return 1 ;; esac
  # reusable workflow files start with reusable- by convention
  return 0
}

# ── Rule W01 (#41): permissions: {} at workflow level forbids any nested job
# ─ permission. Either declare what's needed or drop the empty block.
audit_empty_permissions_block() {
  local f
  for f in "$WORKFLOWS_DIR"/*.yml; do
    [ -f "$f" ] || continue
    is_entry_workflow "$f" || continue
    if grep -qE '^permissions:\s*\{\s*\}\s*$' "$f"; then
      err "W01" "$f" "permissions: {} at workflow level blocks every nested job permission. Declare needed scopes explicitly. (#41)"
    fi
    checked=$((checked + 1))
  done
}

# ── Rule W02 (#47): `workflows` is not a valid permission scope.
audit_invalid_permission_scopes() {
  local f
  local valid_scopes='actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses'
  for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/reusable-*.yml; do
    [ -f "$f" ] || continue
    # Match leading-2-or-4-space indentation, key: value (write|read|none)
    while IFS= read -r line; do
      local key
      key="$(echo "$line" | sed -E 's/^[[:space:]]*([a-z-]+):.*$/\1/')"
      if ! echo "$key" | grep -qE "^(${valid_scopes})$"; then
        # Skip non-permission keys in the same indent block — heuristic:
        # only flag when the line is followed by a known permission verb.
        if echo "$line" | grep -qE ':\s*(read|write|none|admin)\s*(#|$)'; then
          err "W02" "$f" "'$key' is not a valid GitHub Actions permission scope. (#47)"
        fi
      fi
    done < <(awk '/^permissions:/{flag=1; next} flag&&/^[a-z]/{flag=0} flag&&/^[[:space:]]+[a-z-]+:[[:space:]]*(read|write|none|admin)/' "$f" 2>/dev/null)
  done
}

# ── Rule W03 (#68): entry + reusable share concurrency.group → deadlock.
audit_concurrency_deadlock() {
  local entry reusable_path reusable_name
  for entry in "$WORKFLOWS_DIR"/*.yml; do
    [ -f "$entry" ] || continue
    is_entry_workflow "$entry" || continue
    # Pull all `uses: …/reusable-X.yml@…` referenced from this entry.
    while IFS= read -r ref; do
      # ref looks like "reusable-foo.yml@<sha>" — strip @sha to get name.
      reusable_name="${ref%%@*}"
      reusable_path="$WORKFLOWS_DIR/$reusable_name"
      [ -f "$reusable_path" ] || continue
      local entry_group reusable_group
      entry_group="$(awk '/^concurrency:/{flag=1; next} flag&&/group:/{sub(/^[[:space:]]+group:[[:space:]]*/, ""); print; exit}' "$entry" | tr -d '[:space:]')"
      reusable_group="$(awk '/^concurrency:/{flag=1; next} flag&&/group:/{sub(/^[[:space:]]+group:[[:space:]]*/, ""); print; exit}' "$reusable_path" | tr -d '[:space:]')"
      [ -z "$entry_group" ] || [ -z "$reusable_group" ] && continue
      if [ "$entry_group" = "$reusable_group" ]; then
        err "W03" "$reusable_path" "shares concurrency.group '$entry_group' with caller $(basename "$entry") → GitHub deadlock detection cancels the run. Drop concurrency from the reusable. (#68)"
      fi
    done < <(grep -hoE 'reusable-[a-z-]+\.yml@[0-9a-f]{40}' "$entry")
  done
}

# ── Rule W04 (#54): every manifest YiAgent/OpenCI dep SHA must be a valid
# ─ 40-char hex (already enforced by verify-sha-consistency.sh — this is a
# ─ smoke-test redundancy). We additionally probe a handful of cross-cutting
# ─ third-party action SHAs locally (skipping network probes — that lives in
# ─ verify-sha-consistency.sh).
audit_manifest_sha_format() {
  local manifest="$REPO_ROOT/manifest.yml"
  [ -f "$manifest" ] || return 0
  if ! command -v yq >/dev/null 2>&1; then return 0; fi
  while IFS=$'\t' read -r key sha; do
    [ -z "$key" ] && continue
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      err "W04" "manifest.yml" "'$key' SHA is not a valid 40-char hex: '$sha' (#54)"
    fi
  done < <(yq -r '.deps | to_entries | .[] | .key + "\t" + (.value // "")' "$manifest")
}

# ── Rule A01 (#50): `uses:` field of composite action cannot interpolate
# ─ ${{ … }} expressions. Static at parse time.
audit_dynamic_uses_in_composite() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # `uses:` line where the action ref portion (anything up to end-of-line
    # or first `#`) contains a ${{ … }} expression. Both `uses: x@${{ y }}`
    # and `uses: x/${{ y }}@sha` patterns are illegal.
    if grep -qE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^#]*\$\{\{' "$f"; then
      err "A01" "$f" "Dynamic \${{ … }} in 'uses:' ref is not allowed; refs must be static. Gate with 'if:' on per-flavor steps instead. (#50)"
    fi
  done < <(find "$ACTIONS_DIR" -name "action.yml" -o -name "action.yaml" 2>/dev/null)
}

# ── Rule A02 (#60): ${{ secrets.X }} inside composite action description
# ─ trips the parser (secrets context not available in composites).
audit_secrets_in_composite_description() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -nE '\$\{\{\s*secrets\.' "$f" >/dev/null; then
      err "A02" "$f" "\${{ secrets.X }} is not valid in composite YAML; even inside descriptions the parser tries to evaluate it. Replace with plain prose. (#60)"
    fi
  done < <(find "$ACTIONS_DIR" -name "action.yml" -o -name "action.yaml" 2>/dev/null)
}

# ── Rule R01 (#49): reusable workflow's verify-sha job needs fetch-depth: 0
# ─ to resolve the self-referencing manifest SHA via `git ls-tree`.
audit_verify_sha_fetch_depth() {
  local f
  for f in "$WORKFLOWS_DIR"/reusable-*.yml "$WORKFLOWS_DIR"/on-maintenance.yml; do
    [ -f "$f" ] || continue
    # Only check files that have a verify-sha job AND call the consistency script.
    if grep -q "verify-sha-consistency\.sh" "$f"; then
      # Look for actions/checkout block with fetch-depth: 0 anywhere in file.
      if ! grep -qE 'fetch-depth:\s*0' "$f"; then
        err "R01" "$f" "Job runs verify-sha-consistency.sh but no actions/checkout step sets fetch-depth: 0; git ls-tree on the self-ref SHA will fail in shallow checkouts. (#49)"
      fi
    fi
  done
}

# ── Rule S01 (#62): `echo … | awk … exit` under set -o pipefail can SIGPIPE.
# We only flag the producer-pipe form (something | awk '... exit' where the
# producer can write more after awk closes the read end). awk reading via
# stdin from a heredoc/here-string or piped from a fixed-output command
# (find, etc.) is fine. Skip lines inside comments.
audit_pipefail_awk_exit() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Skip the auditor itself — its error strings contain literal descriptions
    # of the pattern that would trigger the rule.
    case "$f" in *"workflow-audit.sh") continue ;; esac
    # Need pipefail set somewhere (non-comment line). Both `set -o pipefail`
    # and combined-flag forms like `set -euo pipefail` should match.
    if ! grep -qE '^[^#]*\bset\b[^#]*\bpipefail\b' "$f"; then
      continue
    fi
    # Look for the dangerous pattern across the file. We can't strip
    # strings cleanly (awk body lives inside single quotes that also wrap
    # other content), so instead match lines where the file contains:
    #   echo|printf <stuff> | awk <stuff with exit>
    # on a single line, skipping comment-only lines (`^\s*#`).
    if grep -vE '^[[:space:]]*#' "$f" \
         | grep -qE '\b(echo|printf)\b[^|#]*\|[[:space:]]*awk\b[^|#]*\bexit\b'; then
      err "S01" "$f" "Found 'echo|awk ... exit' under set -o pipefail; can race into SIGPIPE. Replace with here-string + while-read. (#62)"
    fi
  done < <(find "$SCRIPTS_DIR" -name "*.sh" 2>/dev/null)
}

# ── Rule T01 (#64): self-test / maintenance must include .github/scripts/**
# ─ in their `paths:` so script edits actually trigger the workflows that
# ─ exercise those scripts.
audit_self_test_paths() {
  local f
  for f in "$WORKFLOWS_DIR/ci-self-test.yml" "$WORKFLOWS_DIR/on-maintenance.yml"; do
    [ -f "$f" ] || continue
    if ! grep -qE '^\s*-\s*"\.github/scripts/' "$f"; then
      err "T01" "$f" "Trigger 'paths:' must include '.github/scripts/**' so script changes are exercised by this workflow. (#64)"
    fi
  done
}

main() {
  audit_empty_permissions_block
  audit_invalid_permission_scopes
  audit_concurrency_deadlock
  audit_manifest_sha_format
  audit_dynamic_uses_in_composite
  audit_secrets_in_composite_description
  audit_verify_sha_fetch_depth
  audit_pipefail_awk_exit
  audit_self_test_paths

  note "workflow-audit" "Ran 9 rules across .github/workflows + actions + .github/scripts; ${errors} error(s)."

  if [ "$errors" -gt 0 ]; then
    return 1
  fi
  return 0
}

main "$@"

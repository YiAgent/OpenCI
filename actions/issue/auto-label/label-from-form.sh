#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auto-label/label-from-form.sh — derive labels from issue-form fields.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   ISSUE_BODY  — raw issue body
#   ISSUE_TITLE — issue title (used to detect security keywords)
#   GH_TOKEN    — token with issues:write
#   REPO        — owner/repo
#   ISSUE_NUM   — issue number
#
# Behaviour:
#   • Extracts the "Area" field, lowercases the first token, and applies
#     `area:<token>` label if the token is in the supported set.
#   • Extracts the "Severity" field, looks for blocker/high/medium/low,
#     applies `severity:<level>` label.
#   • If title or body match common security keywords, applies `security`
#     and `private-discuss` labels.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

EXTRACT="${EXTRACT_SH:-$(dirname "$0")/../validate-form/extract.sh}"

extract_field() {
  ISSUE_BODY="$ISSUE_BODY" FIELD="$1" bash "$EXTRACT"
}

# --- Area ---
area_raw="$(extract_field "Area")"
area_first_token="$(printf '%s' "$area_raw" | head -1 | awk '{print tolower($1)}')"
case "$area_first_token" in
  frontend|backend|ai|ci|docs|infra|other)
    area_label="area:$area_first_token"
    ;;
  *) area_label="" ;;
esac

# --- Severity ---
sev_raw="$(extract_field "Severity")"
sev_first_token="$(printf '%s' "$sev_raw" | head -1 | awk '{print tolower($1)}')"
case "$sev_first_token" in
  blocker)        sev_label="severity:blocker" ;;
  high)           sev_label="severity:high"    ;;
  medium)         sev_label="severity:medium"  ;;
  low)            sev_label="severity:low"     ;;
  *)              sev_label="" ;;
esac

# --- Security keywords ---
sec_label=""
priv_label=""
combined="$(printf '%s\n%s' "$ISSUE_TITLE" "$ISSUE_BODY")"
if printf '%s' "$combined" \
   | grep -iqE '\b(api[ _-]?key|secret|password|token|credential|leak|0day|cve|exploit|vulnerab)'
then
  sec_label="security"
  priv_label="private-discuss"
fi

# --- Apply ---
labels=()
[ -n "$area_label" ]  && labels+=("$area_label")
[ -n "$sev_label" ]   && labels+=("$sev_label")
[ -n "$sec_label" ]   && labels+=("$sec_label")
[ -n "$priv_label" ]  && labels+=("$priv_label")

if [ "${#labels[@]}" -eq 0 ]; then
  echo "::notice title=Auto Label::no derivable labels from form"
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ] || [ -z "${REPO:-}" ] || [ -z "${ISSUE_NUM:-}" ]; then
  # Library mode (used by bats): just print what we WOULD apply.
  printf 'WOULD-LABEL: %s\n' "${labels[@]}"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::warning title=Auto Label::gh CLI not available; skipping apply"
  exit 0
fi

# Apply labels (one call so partial failure is rare).
joined="$(IFS=','; echo "${labels[*]}")"
gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "$joined"
echo "::notice title=Auto Label::applied=${joined}"

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-coverage/compute.sh — compute %, gate by mode.
# ─────────────────────────────────────────────────────────────────────────────
# Inputs (env):
#   COVERAGE_FILE  — path to lcov.info | coverage.xml (cobertura/jacoco) |
#                    coverage.out (Go) | coverage.json (istanbul-summary)
#   THRESHOLD      — required percentage (0–100)
#   MODE           — pr | stg | prd
#                    pr  → below threshold ⇒ ::warning, exit 0
#                    stg → below threshold ⇒ ::error, exit 1
#                    prd → same as stg
#
# Outputs (stdout key=value lines + GITHUB_OUTPUT when present):
#   coverage-percent
#   passed (true|false)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

FILE="${COVERAGE_FILE:-}"
THRESHOLD="${THRESHOLD:-80}"
MODE="${MODE:-pr}"

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "::error title=Coverage Artifact Missing::COVERAGE_FILE=$FILE not found. Run tests first to produce a coverage report." >&2
  exit 2
fi

emit_kv() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Returns coverage percentage (float, 2 decimals) on stdout.
parse_lcov() {
  awk '
    /^LH:/ { hit  += substr($0, 4) + 0 }
    /^LF:/ { tot  += substr($0, 4) + 0 }
    END   { if (tot == 0) print 0; else printf "%.2f", (hit / tot) * 100 }
  ' "$1"
}

parse_cobertura() {
  # Cobertura XML root has line-rate="0.83" attribute.
  rate="$(grep -oE 'line-rate="[0-9.]+"' "$1" | head -1 | sed -E 's/^line-rate="([^"]*)"$/\1/')"
  if [ -z "$rate" ]; then echo 0; return; fi
  awk -v r="$rate" 'BEGIN { printf "%.2f", r * 100 }'
}

parse_jacoco() {
  # Jacoco XML uses <counter type="LINE" missed="X" covered="Y"/>; sum across.
  awk '
    /<counter type="LINE"/ {
      missed = covered = 0
      if (match($0, /missed="[0-9]+"/))  { missed  = substr($0, RSTART+8, RLENGTH-9) + 0 }
      if (match($0, /covered="[0-9]+"/)) { covered = substr($0, RSTART+9, RLENGTH-10) + 0 }
      m += missed; c += covered
    }
    END { tot = m + c; if (tot == 0) print 0; else printf "%.2f", (c / tot) * 100 }
  ' "$1"
}

parse_go() {
  # Go coverage.out:
  #   first line: `mode: ...`
  #   each line:  `pkg/file.go:start.col,end.col stmts hits`
  awk '
    NR == 1 { next }                     # skip mode header
    NF >= 3 {
      stmts = $(NF-1) + 0
      hits  = $NF + 0
      tot += stmts
      if (hits > 0) cov += stmts
    }
    END { if (tot == 0) print 0; else printf "%.2f", (cov / tot) * 100 }
  ' "$1"
}

parse_istanbul_summary() {
  # JSON like { "total": { "lines": { "pct": 87.5 } } }
  jq -r '.total.lines.pct // 0' "$1"
}

detect_format() {
  case "$1" in
    *.info|*.lcov)            echo lcov ;;
    *.out)                    echo go   ;;
    *.json)                   echo istanbul ;;
    *.xml)
      if grep -q '<counter type="LINE"' "$1" 2>/dev/null; then echo jacoco
      else echo cobertura
      fi
      ;;
    *)
      # Fall back to content sniffing.
      if grep -q '^LF:' "$1" 2>/dev/null; then echo lcov
      elif head -1 "$1" 2>/dev/null | grep -q '^mode:'; then echo go
      elif grep -q 'line-rate=' "$1" 2>/dev/null; then echo cobertura
      elif grep -q '<counter type="LINE"' "$1" 2>/dev/null; then echo jacoco
      else echo unknown
      fi
      ;;
  esac
}

format="$(detect_format "$FILE")"
case "$format" in
  lcov)      pct="$(parse_lcov      "$FILE")" ;;
  cobertura) pct="$(parse_cobertura "$FILE")" ;;
  jacoco)    pct="$(parse_jacoco    "$FILE")" ;;
  go)        pct="$(parse_go        "$FILE")" ;;
  istanbul)  pct="$(parse_istanbul_summary "$FILE")" ;;
  *)
    echo "::error title=Coverage Format Unknown::Cannot parse $FILE" >&2
    exit 2
    ;;
esac

emit_kv "coverage-percent" "$pct"

# Gate.
below="$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN { print (p+0 < t+0) ? 1 : 0 }')"
if [ "$below" = "1" ]; then
  case "$MODE" in
    pr)
      emit_kv "passed" "false"
      echo "::warning title=Coverage Below Threshold::pct=${pct}% threshold=${THRESHOLD}% mode=pr (advisory)"
      exit 0
      ;;
    stg|prd)
      emit_kv "passed" "false"
      echo "::error title=Coverage Below Threshold::pct=${pct}% threshold=${THRESHOLD}% mode=${MODE} (blocking)" >&2
      exit 1
      ;;
    *)
      echo "::error title=Coverage Mode Unknown::mode=${MODE}" >&2
      exit 2
      ;;
  esac
fi

emit_kv "passed" "true"
echo "::notice title=Coverage OK::pct=${pct}% threshold=${THRESHOLD}% mode=${MODE}"

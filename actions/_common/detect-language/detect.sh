#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect.sh — detect language stack from filesystem markers.
# ─────────────────────────────────────────────────────────────────────────────
# Detection priority (first match wins):
#   1. node    — package.json   ( pkg-mgr: pnpm | yarn | npm )
#   2. python  — pyproject.toml | requirements.txt   ( uv | pip )
#   3. go      — go.mod
#   4. JVM     — pom.xml | build.gradle.kts | build.gradle
#                Kotlin/Java disambiguated by .kt vs .java source files.
#   5. unknown
#
# Inputs:
#   $1 (optional) — directory to inspect; defaults to $DETECT_DIR or $PWD.
#
# Side effects (in CI):
#   Writes language=, package-manager=, version-file=, runtime-version= to
#   $GITHUB_OUTPUT when set; always echoes the same key=value pairs to stdout
#   for shell-level testing.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Allow caller to bypass detection with an explicit language override.
if [ -n "${OVERRIDE:-}" ]; then
  emit "language"        "$OVERRIDE"
  emit "package-manager" "unknown"
  emit "version-file"    ""
  emit "runtime-version" ""
  echo "::notice title=Language Detected::language=${OVERRIDE} package-manager=unknown (override)"
  exit 0
fi

ROOT="${1:-${DETECT_DIR:-$PWD}}"
cd "$ROOT"

language="unknown"
pkg_mgr="unknown"
version_file=""
runtime_version=""

# Returns 0 if at least one file matching the pattern exists below the
# current directory (excluding common build / dependency directories).
has_files_with_extension() {
  local ext="$1"
  find . -type f -name "*.${ext}" \
    -not -path '*/node_modules/*' \
    -not -path '*/build/*' \
    -not -path '*/target/*' \
    -not -path '*/.git/*' \
    -not -path '*/.gradle/*' \
    -print -quit 2>/dev/null | grep -q .
}

if [ -f package.json ]; then
  language="node"
  if   [ -f pnpm-lock.yaml ]; then pkg_mgr="pnpm"
  elif [ -f yarn.lock ];      then pkg_mgr="yarn"
  else                              pkg_mgr="npm"
  fi
  if   [ -f .nvmrc ];        then version_file=".nvmrc"
  elif [ -f .node-version ]; then version_file=".node-version"
  fi
  if [ -n "$version_file" ]; then
    runtime_version="$(tr -d '[:space:]' <"$version_file")"
  fi

elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  language="python"
  if [ -f uv.lock ]; then pkg_mgr="uv"; else pkg_mgr="pip"; fi
  if [ -f .python-version ]; then
    version_file=".python-version"
    runtime_version="$(tr -d '[:space:]' <"$version_file")"
  fi

elif [ -f go.mod ]; then
  language="go"
  pkg_mgr="go-mod"
  version_file="go.mod"
  runtime_version="$(grep -E '^go[[:space:]]+[0-9]' go.mod | head -1 | awk '{print $2}' || true)"

elif [ -f pom.xml ]; then
  language="java"
  pkg_mgr="maven"
  version_file="pom.xml"

elif [ -f build.gradle.kts ]; then
  language="kotlin"
  pkg_mgr="gradle-kts"
  version_file="build.gradle.kts"
  # Java-only project that happens to use Kotlin DSL: demote to java.
  if has_files_with_extension "java" && ! has_files_with_extension "kt"; then
    language="java"
  fi

elif [ -f build.gradle ]; then
  language="java"
  pkg_mgr="gradle"
  version_file="build.gradle"
  if has_files_with_extension "kt"; then
    language="kotlin"
  fi
fi

emit "language"        "$language"
emit "package-manager" "$pkg_mgr"
emit "version-file"    "$version_file"
emit "runtime-version" "$runtime_version"

echo "::notice title=Language Detected::language=${language} package-manager=${pkg_mgr}"

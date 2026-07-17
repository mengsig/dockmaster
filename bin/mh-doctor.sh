#!/usr/bin/env bash
# mh-doctor.sh - verify the manhandler is ready to run, and scaffold MH_HOME.
#
# Two jobs, one place:
#   1. Bootstrap: ensure the MH_HOME layout exists (state/, data/, repos/,
#      config/, tasks/, worktrees/, the registry file). Idempotent — safe to
#      run repeatedly; it only creates what is missing.
#   2. Diagnose: check every tool the toolbelt depends on, GitHub auth, and the
#      committed config defaults, with an actionable hint for anything missing.
#
# This is the single owner of the dependency contract: mh-session-start delegates
# its tooling check here so "what the toolbelt needs" lives in exactly one place.
#
# Usage:
#   mh-doctor.sh          full report + scaffold; exit 1 if a REQUIRED tool is missing
#   mh-doctor.sh check    compact tooling + GitHub-auth check only (no scaffold)
#
# Exit 0 = required tools present. Exit 1 = a required tool is missing (a missing
# recommended tool degrades a feature but never fails the check).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"

# Dependency contract, as (name, purpose) pairs. Required tools are called
# directly by the toolbelt; without them scripts cannot run. Recommended tools
# gate specific features (the PR path, per-repo memory, review surfaces).
REQUIRED_TOOLS=(
  "git" "clone, worktree, and all git operations"
  "jq"  "registry and backlog JSON (single-owner parsers)"
)
RECOMMENDED_TOOLS=(
  "gh"           "GitHub auth + API for the PR delivery path"
  "gh-axi"       "ergonomic GitHub wrapper used on the PR path"
  "contextgraph" "per-repo memory (recall/remember) inside managed repos"
  "lavish-axi"   "review surfaces and structured reports"
)

tool_hint() {
  case "$1" in
    git|jq)            printf 'install with your package manager (e.g. apt install %s / brew install %s)' "$1" "$1" ;;
    gh)                printf 'https://cli.github.com' ;;
    gh-axi|lavish-axi) printf 'part of the axi toolset — install it and ensure it is on PATH' ;;
    contextgraph)      printf 'install the contextgraph CLI and ensure it is on PATH' ;;
    *)                 printf 'install %s and ensure it is on PATH' "$1" ;;
  esac
}

# report_tools <compact> -> prints one line per tool; returns the count of
# missing REQUIRED tools (so a caller can gate on readiness).
report_tools() {
  local compact="$1" name purpose miss=0 i
  for ((i = 0; i < ${#REQUIRED_TOOLS[@]}; i += 2)); do
    name="${REQUIRED_TOOLS[i]}"; purpose="${REQUIRED_TOOLS[i + 1]}"
    if command -v "$name" >/dev/null 2>&1; then
      printf '  ok       %-13s %s\n' "$name" "$purpose"
    else
      printf '  MISSING  %-13s %s\n' "$name" "$purpose"
      printf '           ^ required — %s\n' "$(tool_hint "$name")"
      miss=$((miss + 1))
    fi
  done
  for ((i = 0; i < ${#RECOMMENDED_TOOLS[@]}; i += 2)); do
    name="${RECOMMENDED_TOOLS[i]}"; purpose="${RECOMMENDED_TOOLS[i + 1]}"
    if command -v "$name" >/dev/null 2>&1; then
      printf '  ok       %-13s %s\n' "$name" "$purpose"
    else
      printf '  warn     %-13s %s\n' "$name" "$purpose"
      [ "$compact" = 1 ] || printf '           ^ recommended — %s\n' "$(tool_hint "$name")"
    fi
  done
  # GitHub auth only matters when gh is present.
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      printf '  ok       %-13s %s\n' "gh-auth" "authenticated"
    else
      printf '  warn     %-13s %s\n' "gh-auth" "run: gh auth login"
    fi
  fi
  return "$miss"
}

section() { printf '\n=== %s ===\n' "$1"; }

mode="${1:-full}"
case "$mode" in
  check)
    # Compact readiness probe for mh-session-start; no scaffold, no headings.
    report_tools 1 || exit $?
    ;;

  full|"")
    section "TOOLING"
    miss=0; report_tools 0 || miss=$?

    section "HOME (scaffolded if missing)"
    mh_ensure_dirs
    mkdir -p "$MH_STATE/worktrees"
    for p in state state/tasks state/worktrees data repos config; do
      if [ -d "$MH_HOME/$p" ]; then printf '  ok   %s/\n' "$p"; else printf '  MISSING %s/\n' "$p"; fi
    done
    if [ -f "$MH_REGISTRY" ]; then printf '  ok   state/repos.json\n'; else printf '  MISSING state/repos.json\n'; fi
    if [ -f "$MH_CONFIG/pr-pipeline.default.json" ]; then
      printf '  ok   config/pr-pipeline.default.json\n'
    else
      printf '  warn config/pr-pipeline.default.json absent (tracked default missing?)\n'
    fi
    if [ -f "$MH_HOME/.env" ]; then printf '  ok   .env present\n'; else printf '  note .env absent (optional; operator-private secrets)\n'; fi

    section "VERDICT"
    if [ "$miss" -gt 0 ]; then
      printf '  NOT READY: %d required tool(s) missing (see above).\n' "$miss"
      exit 1
    fi
    printf '  READY: required tools present; home scaffolded.\n'
    ;;

  *)
    mh_die "usage: mh-doctor.sh [check]"
    ;;
esac

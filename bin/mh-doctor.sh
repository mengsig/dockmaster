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
# Exit 0 = required tools present. Exit 1 = a required tool is missing. A missing
# PR-flow or optional tool warns and degrades a feature, but never fails the
# check — so a green verdict means exactly what the README promises.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"

# Dependency contract, as (name, purpose) pairs, in three tiers:
#   REQUIRED  — called directly by the toolbelt; without them nothing runs.
#   PR-FLOW   — needed only for the PR delivery path; local-only mode works
#               without them. gh (or the gh-axi wrapper) is the one tool here.
#   OPTIONAL  — the operator's own axi tooling, NOT bundled with this distro.
#               Absent, the manhandler degrades to a real, plainer mode (plain
#               gh for GitHub, operator-run review with no lavish artifact).
# Only REQUIRED tools gate the verdict; the other two tiers only warn.
REQUIRED_TOOLS=(
  "git" "clone, worktree, and all git operations"
  "jq"  "registry and backlog JSON (single-owner parsers)"
)
PRFLOW_TOOLS=(
  "gh"  "GitHub auth + API for the PR flow (or gh-axi); local-only mode needs neither"
)
OPTIONAL_TOOLS=(
  "gh-axi"              "ergonomic GitHub wrapper (operator tooling, not bundled)"
  "lavish-axi"          "reviewable approval artifact (operator tooling, not bundled)"
  "chrome-devtools-axi" "browser automation for web tasks (operator tooling, not bundled)"
)

tool_hint() {
  case "$1" in
    git|jq)  printf 'install with your package manager (e.g. apt install %s / brew install %s)' "$1" "$1" ;;
    gh)      printf 'https://cli.github.com' ;;
    gh-axi|lavish-axi|chrome-devtools-axi)
             printf 'operator tooling, not bundled — without it manhandler uses plain gh and operator-run review' ;;
    *)       printf 'install %s and ensure it is on PATH' "$1" ;;
  esac
}

# report_warn_tier <compact> <label> <name> <purpose> [<name> <purpose> ...] ->
# prints an ok/warn line per tool. A missing tool warns with <label> but never
# counts against readiness (only REQUIRED tools gate the verdict).
report_warn_tier() {
  local compact="$1" label="$2"; shift 2
  local name purpose
  while [ "$#" -gt 0 ]; do
    name="$1"; purpose="$2"; shift 2
    if command -v "$name" >/dev/null 2>&1; then
      printf '  ok       %-13s %s\n' "$name" "$purpose"
    else
      printf '  warn     %-13s %s\n' "$name" "$purpose"
      [ "$compact" = 1 ] || printf '           ^ %s — %s\n' "$label" "$(tool_hint "$name")"
    fi
  done
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
  report_warn_tier "$compact" "needed for the PR flow" "${PRFLOW_TOOLS[@]}"
  report_warn_tier "$compact" "optional" "${OPTIONAL_TOOLS[@]}"
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

# probe_state_json -> for each state file that exists but does not parse as JSON,
# print a FAIL line with an actionable recovery hint; return the count of invalid
# files. A corrupt registry or backlog silently breaks every jq-driven command,
# so this must run early (session-start reaches it through `check`) — before any
# repo/backlog section spews raw jq parse errors with no explanation. jq is a
# required tool, so its absence is already a readiness failure reported above.
probe_state_json() {
  local bad=0 backlog
  command -v jq >/dev/null 2>&1 || return 0
  if [ -f "$MH_REGISTRY" ] && ! jq . "$MH_REGISTRY" >/dev/null 2>&1; then
    printf '  FAIL state/repos.json is not valid JSON\n'
    printf '       ^ restore from git or a backup, or reset to {"repos":{}}\n'
    bad=$((bad + 1))
  fi
  backlog="$MH_STATE/backlog.json"
  if [ -f "$backlog" ] && ! jq . "$backlog" >/dev/null 2>&1; then
    printf '  FAIL state/backlog.json is not valid JSON\n'
    printf '       ^ restore from git or a backup, or reset to {"items":[],"decisions":[]}\n'
    bad=$((bad + 1))
  fi
  return "$bad"
}

mode="${1:-full}"
case "$mode" in
  check)
    # Compact readiness probe for mh-session-start; no scaffold, no headings.
    # Tooling first, then state-JSON integrity so a corrupt registry surfaces its
    # recovery hint here (session-start runs `check` before its repo/backlog
    # sections) instead of as raw jq errors later.
    miss=0; report_tools 1 || miss=$?
    badjson=0; probe_state_json || badjson=$?
    if [ "$miss" -gt 0 ]; then exit "$miss"; fi
    if [ "$badjson" -gt 0 ]; then exit 1; fi
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

    # State JSON must PARSE, not just exist (same probe session-start runs via
    # `check`): a corrupt registry or backlog silently breaks every jq-driven
    # command, so a parse failure is a readiness failure with a recovery hint.
    badjson=0; probe_state_json || badjson=$?
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
    if [ "$badjson" -gt 0 ]; then
      printf '  NOT READY: %d state file(s) are not valid JSON (see above).\n' "$badjson"
      exit 1
    fi
    printf '  READY: required tools present; state valid; home scaffolded.\n'
    ;;

  *)
    mh_die "usage: mh-doctor.sh [check]"
    ;;
esac

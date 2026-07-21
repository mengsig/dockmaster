#!/usr/bin/env bash
# dm-doctor.sh - verify the dockmaster is ready to run, and scaffold DM_HOME.
#
# Two jobs, one place:
#   1. Bootstrap: ensure the DM_HOME layout exists (state/, data/, repos/,
#      config/, tasks/, worktrees/, the registry file). Idempotent — safe to
#      run repeatedly; it only creates what is missing.
#   2. Diagnose: check every tool the toolbelt depends on, GitHub auth, and the
#      committed config defaults, with an actionable hint for anything missing.
#
# This is the single owner of the dependency contract: dm-session-start delegates
# its tooling check here so "what the toolbelt needs" lives in exactly one place.
#
# Usage:
#   dm-doctor.sh [check] [--runtime auto|claude|codex|both]
#
# Exit 0 = required tools present. Exit 1 = a required tool is missing. A missing
# PR-flow or optional tool warns but never fails the check: a green verdict means
# local-only mode works, NOT that the PR flow is available (see the PR-FLOW tier).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"

# Dependency contract, as (name, purpose) pairs, in three tiers:
#   REQUIRED  — called directly by the toolbelt; without them nothing runs.
#   PR-FLOW   — needed only for the PR delivery path; local-only mode works
#               without them. BOTH gh and gh-axi belong here: reads go through
#               `gh api`, but every GitHub mutation calls gh-axi and there is
#               no plain-gh fallback (#104).
#   OPTIONAL  — genuinely degrade cleanly when absent.
# Only REQUIRED tools gate the verdict; the other two tiers only warn.
REQUIRED_TOOLS=(
  "git" "clone, worktree, and all git operations"
  "jq"  "registry and backlog JSON (single-owner parsers)"
)
PRFLOW_TOOLS=(
  "gh"     "GitHub auth + API reads for the PR flow; local-only mode needs neither"
  "gh-axi" "GitHub mutations: pr create, merge, repo create (no plain-gh fallback)"
)
OPTIONAL_TOOLS=(
  "lavish-axi"          "reviewable approval artifact; without it, review the change directly"
  "chrome-devtools-axi" "browser automation for web tasks"
)

tool_hint() {
  case "$1" in
    git|jq)  printf 'install with your package manager (e.g. apt install %s / brew install %s)' "$1" "$1" ;;
    gh)      printf 'https://cli.github.com' ;;
    gh-axi)  printf 'maintainer tooling with no public install path — without it the PR flow is unavailable; use local-only mode (#104)' ;;
    lavish-axi|chrome-devtools-axi)
             printf 'operator tooling, not bundled — the feature it gates is skipped, nothing else changes' ;;
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

runtime_probe() {
  local runtime="$1"
  command -v "$runtime" >/dev/null 2>&1 || return 2
  case "$runtime" in
    claude) claude auth status --json >/dev/null 2>&1 ;;
    codex) codex login status >/dev/null 2>&1 ;;
  esac
}

runtime_status() {
  local runtime="$1" status=0
  runtime_probe "$runtime" || status=$?
  case "$status" in 0) printf 'ready\n' ;; 2) printf 'absent\n' ;; *) printf 'unauthenticated\n' ;; esac
}

snapshot_runtimes() {
  CLAUDE_RUNTIME_STATUS="$(runtime_status claude)"
  CODEX_RUNTIME_STATUS="$(runtime_status codex)"
  case "$CLAUDE_RUNTIME_STATUS" in ready|absent|unauthenticated) ;; *) dm_die "invalid Claude probe result" ;; esac
  case "$CODEX_RUNTIME_STATUS" in ready|absent|unauthenticated) ;; *) dm_die "invalid Codex probe result" ;; esac
}

report_one_runtime() {
  local runtime="$1" required="$2" status
  case "$runtime" in claude) status="$CLAUDE_RUNTIME_STATUS" ;; codex) status="$CODEX_RUNTIME_STATUS" ;; esac
  case "$status" in
    ready) printf '  ok       %-13s %s\n' "$runtime-runtime" "installed and authenticated"; return 0 ;;
    absent) printf '  %-8s %-13s %s\n' "$required" "$runtime-runtime" "CLI absent" ;;
    unauthenticated) printf '  %-8s %-13s %s\n' "$required" "$runtime-runtime" "authentication unavailable" ;;
  esac
  [ "$required" = "MISSING" ] && return 1
  return 0
}

report_runtime() {
  local selected="$1" claude_ok=0 codex_ok=0 miss=0
  snapshot_runtimes
  if [ "$CLAUDE_RUNTIME_STATUS" = ready ]; then claude_ok=1; fi
  if [ "$CODEX_RUNTIME_STATUS" = ready ]; then codex_ok=1; fi
  case "$selected" in
    claude|codex) report_one_runtime "$selected" MISSING || miss=1 ;;
    both)
      report_one_runtime claude MISSING || miss=$((miss + 1))
      report_one_runtime codex MISSING || miss=$((miss + 1))
      ;;
    auto)
      if [ "$claude_ok" -eq 1 ]; then report_one_runtime claude MISSING
      elif [ "$codex_ok" -eq 1 ]; then report_one_runtime codex MISSING
      else
        printf '  MISSING  %-13s %s\n' "agent-runtime" "no authenticated Claude or Codex runtime"
        miss=1
      fi
      [ "$claude_ok" -eq 1 ] || report_one_runtime claude warn
      [ "$codex_ok" -eq 1 ] || report_one_runtime codex warn
      ;;
  esac
  return "$miss"
}

report_node() {
  local version major
  if ! command -v node >/dev/null 2>&1; then
    printf '  warn     %-13s %s\n' node 'development/runtime validation unavailable (requires Node >=14)'
    return 0
  fi
  version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  major="${version%%.*}"
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  if [ "$major" -ge 14 ]; then
    printf '  ok       %-13s %s\n' node "development/runtime validation (${version})"
  else
    printf '  warn     %-13s %s\n' node "${version:-unknown}; development checks require >=14"
  fi
}

# report_tools <compact> -> prints one line per tool; returns the count of
# missing REQUIRED tools (so a caller can gate on readiness).
report_tools() {
  local compact="$1" selected_runtime="$2" name purpose miss=0 runtime_miss=0 i
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
  report_node
  report_runtime "$selected_runtime" || runtime_miss=$?
  miss=$((miss + runtime_miss))
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
  if [ -f "$DM_REGISTRY" ] && ! jq . "$DM_REGISTRY" >/dev/null 2>&1; then
    printf '  FAIL state/repos.json is not valid JSON\n'
    printf '       ^ restore from git or a backup, or reset to {"repos":{}}\n'
    bad=$((bad + 1))
  fi
  backlog="$DM_STATE/backlog.json"
  if [ -f "$backlog" ] && ! jq . "$backlog" >/dev/null 2>&1; then
    printf '  FAIL state/backlog.json is not valid JSON\n'
    printf '       ^ restore from git or a backup, or reset to {"items":[],"decisions":[]}\n'
    bad=$((bad + 1))
  fi
  if [ -f "$DM_STATE/secondmates.json" ] && ! jq -e '
      (.secondmates | type) == "object" and
      all(.secondmates[];
        (.status | IN("launching","active","dormant","retired")) and
        (.thread_name | type == "string" and test("^[a-z0-9_]{1,64}$")) and
        (.agent_id | type == "string") and
        (.repos | type == "array")) and
      ([.secondmates | to_entries[] | select(.value.status != "retired") | .value.thread_name] as $threads |
        ($threads | length) == ($threads | unique | length)) and
      ([.secondmates[].agent_id | select(length > 0)] as $agents |
        ($agents | length) == ($agents | unique | length))
    ' "$DM_STATE/secondmates.json" >/dev/null 2>&1; then
    printf '  FAIL state/secondmates.json has invalid supervisor state\n'
    printf '       ^ restore a valid {"secondmates":{}} document; do not hand-edit live identity records\n'
    bad=$((bad + 1))
  fi
  return "$bad"
}

mode="full"; selected_runtime="auto"
while [ "$#" -gt 0 ]; do
  case "$1" in
    check|full) mode="$1"; shift ;;
    --runtime) selected_runtime="${2:-}"; shift 2 ;;
    *) dm_die "usage: dm-doctor.sh [check] [--runtime auto|claude|codex|both]" ;;
  esac
done
case "$selected_runtime" in auto|claude|codex|both) ;; *) dm_die "runtime must be auto|claude|codex|both" ;; esac
case "$mode" in
  check)
    # Compact readiness probe for dm-session-start; no scaffold, no headings.
    # Tooling first, then state-JSON integrity so a corrupt registry surfaces its
    # recovery hint here (session-start runs `check` before its repo/backlog
    # sections) instead of as raw jq errors later.
    miss=0; report_tools 1 "$selected_runtime" || miss=$?
    badjson=0; probe_state_json || badjson=$?
    if [ "$miss" -gt 0 ]; then exit "$miss"; fi
    if [ "$badjson" -gt 0 ]; then exit 1; fi
    ;;

  full|"")
    section "TOOLING"
    miss=0; report_tools 0 "$selected_runtime" || miss=$?

    section "HOME (scaffolded if missing)"
    dm_ensure_dirs
    mkdir -p "$DM_STATE/worktrees"
    for p in state state/tasks state/worktrees data repos config; do
      if [ -d "$DM_HOME/$p" ]; then printf '  ok   %s/\n' "$p"; else printf '  MISSING %s/\n' "$p"; fi
    done
    if [ -f "$DM_REGISTRY" ]; then printf '  ok   state/repos.json\n'; else printf '  MISSING state/repos.json\n'; fi

    # State JSON must PARSE, not just exist (same probe session-start runs via
    # `check`): a corrupt registry or backlog silently breaks every jq-driven
    # command, so a parse failure is a readiness failure with a recovery hint.
    badjson=0; probe_state_json || badjson=$?
    if [ -f "$DM_CONFIG/pr-pipeline.default.json" ]; then
      printf '  ok   config/pr-pipeline.default.json\n'
    else
      printf '  warn config/pr-pipeline.default.json absent (tracked default missing?)\n'
    fi
    if [ -f "$DM_HOME/.env" ]; then printf '  ok   .env present\n'; else printf '  note .env absent (optional; operator-private secrets)\n'; fi

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
    dm_die "usage: dm-doctor.sh [check] [--runtime auto|claude|codex|both]"
    ;;
esac

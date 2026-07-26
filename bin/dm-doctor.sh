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
#   dm-doctor.sh [check] [--json]
#
# --json (check only) emits the same readiness in one compact document —
# {verdict, pr_delivery, checks:[{name,tier,status,note}]} — with the SAME exit
# code the human check returns for the same fleet.
#
# Exit 0 = required tools present. Exit 1 = a required tool is missing. A missing
# PR-flow or optional tool warns but never fails the check: local-only delivery
# is a real mode, not a readiness failure. The VERDICT still has to be true about
# it — a plain "READY" is printed ONLY when the PR flow is actually available;
# otherwise it reads "READY (LOCAL-ONLY)" and names what is missing, so an
# adopter learns it here and not at their first PR.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"

# Dependency contract, as (name, purpose) pairs, in three tiers:
#   REQUIRED  — called directly by the toolbelt; without them nothing runs.
#   PR-FLOW   — needed only for the PR delivery path; local-only mode works
#               without them. Plain `gh` is the ONLY tool in this tier and the
#               whole PR path: reads go through `gh api` and every mutation
#               through `gh pr create` / `gh api --method PUT` / `gh repo create`
#               (#104). No wrapper substitutes for it, and none is needed.
#   OPTIONAL  — genuinely degrade cleanly when absent; each purpose line names
#               exactly what degrades.
# Only REQUIRED tools gate the verdict; the other two tiers only warn — but a
# missing/unauthenticated gh does qualify the VERDICT (see report_pr_delivery).
REQUIRED_TOOLS=(
  "git" "cloning, branching, and every git operation"
  "jq"  "registry and backlog JSON (single-owner parsers)"
)
PRFLOW_TOOLS=(
  "gh"  "GitHub auth + API for the whole PR flow, reads and mutations alike"
)
OPTIONAL_TOOLS=(
  "gh-axi"              "preferred for the three GitHub mutations; plain gh does the same work without it"
  "lavish-axi"          "reviewable approval artifact; without it, review the change directly in a browser"
  "chrome-devtools-axi" "browser automation; without it browser-driving tasks are unavailable"
)

tool_hint() {
  case "$1" in
    git|jq)  printf 'install with your package manager (e.g. apt install %s / brew install %s)' "$1" "$1" ;;
    gh)      printf 'https://cli.github.com' ;;
    gh-axi)  printf 'maintainer tooling with no public install path — not needed: plain gh opens, merges, and creates without it (#104)' ;;
    lavish-axi)
             printf 'operator tooling, not bundled — review the artifact HTML in a browser and give feedback in chat' ;;
    chrome-devtools-axi)
             printf 'operator tooling, not bundled — browser-driving tasks cannot run without it' ;;
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

claude_runtime_status() {
  local status=0
  command -v claude >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
  claude auth status --json >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then printf 'ready\n'; else printf 'unauthenticated\n'; fi
}

# runtime_note <probe-status> - the text describing that probe. Pure, and shared
# by the printed line and the --json row so the two cannot describe one probe
# differently. An unrecognized status is rejected by the CALLER (a die here
# would be swallowed by the command substitution that reads this).
runtime_note() {
  case "$1" in
    ready) printf 'installed and authenticated' ;;
    absent) printf 'CLI absent' ;;
    unauthenticated) printf 'authentication unavailable' ;;
    *) printf 'unrecognized probe result' ;;
  esac
}

# One probe per run: the printed line and the readiness verdict must come from
# the same snapshot, or a second probe could disagree with what was reported.
report_runtime() {
  local status
  status="$(claude_runtime_status)"
  case "$status" in
    ready) printf '  ok       %-13s %s\n' "claude-runtime" "$(runtime_note "$status")"; return 0 ;;
    absent|unauthenticated) printf '  MISSING  %-13s %s\n' "claude-runtime" "$(runtime_note "$status")" ;;
    *) dm_die "invalid Claude probe result: '$status'" ;;
  esac
  return 1
}

# node_probe -> "<ok|missing><TAB><note>". Single owner of the >=14 rule and its
# wording, read by both the printed line and the --json row.
node_probe() {
  local version major
  if ! command -v node >/dev/null 2>&1; then
    printf 'missing\tdevelopment/runtime validation unavailable (requires Node >=14)\n'
    return 0
  fi
  version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  major="${version%%.*}"
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  if [ "$major" -ge 14 ]; then
    printf 'ok\tdevelopment/runtime validation (%s)\n' "$version"
  else
    printf 'missing\t%s; development checks require >=14\n' "${version:-unknown}"
  fi
}

report_node() {
  local probe
  probe="$(node_probe)"
  if [ "${probe%%$'\t'*}" = ok ]; then
    printf '  ok       %-13s %s\n' node "${probe#*$'\t'}"
  else
    printf '  warn     %-13s %s\n' node "${probe#*$'\t'}"
  fi
}

# Probe whether the PR delivery path can actually work and print its line. Only
# plain gh decides: it is the baseline for both the parsed reads and the
# mutations, so no axi wrapper can enable or block the path. Sets PR_DELIVERY,
# which the verdict reads — the reason doctor's first signal is true.
PR_DELIVERY="unknown"
probe_pr_delivery() {
  local present=0 authed=0
  if command -v gh >/dev/null 2>&1; then
    present=1
    if gh auth status >/dev/null 2>&1; then authed=1; fi
  fi
  PR_DELIVERY="$(dm_pr_delivery_gate "$present" "$authed")"
}
pr_delivery_note() {
  case "$1" in
    ready)   printf 'gh authenticated; PRs can be opened and merged' ;;
    no-cli)  printf 'UNAVAILABLE: gh is not installed; only local-only landing works' ;;
    no-auth) printf 'UNAVAILABLE: gh is not authenticated (gh auth login); only local-only landing works' ;;
    *)       printf 'UNAVAILABLE: status could not be resolved' ;;
  esac
}
report_pr_delivery() {
  probe_pr_delivery
  case "$PR_DELIVERY" in
    ready) printf '  ok       %-13s %s\n' "pr-delivery" "$(pr_delivery_note "$PR_DELIVERY")" ;;
    *)     printf '  warn     %-13s %s\n' "pr-delivery" "$(pr_delivery_note "$PR_DELIVERY")" ;;
  esac
}

# report_tools <compact> -> prints one line per tool; returns the count of
# missing REQUIRED tools (so a caller can gate on readiness).
report_tools() {
  local compact="$1" name purpose miss=0 runtime_miss=0 i
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
  report_runtime || runtime_miss=$?
  miss=$((miss + runtime_miss))
  report_pr_delivery
  return "$miss"
}

# --- machine-readable readiness (check --json) -------------------------------
# One row per line the human check prints, from the SAME arrays and probes, so
# the two views cannot disagree about what is installed. Rows accumulate in a
# global rather than through a command substitution: a probe's dm_die has to
# abort the run, and it cannot escape `$( )`.
JSON_ROWS=""; JSON_MISS=0
json_row() {
  JSON_ROWS="$JSON_ROWS$(jq -c -n --arg name "$1" --arg tier "$2" --arg status "$3" --arg note "$4" \
    '{name:$name,tier:$tier,status:$status,note:$note}')"$'\n'
}

# json_tool_tier <tier> <name> <purpose> [...] - one row per tool in a tier.
# Only the `required` tier feeds JSON_MISS, exactly as report_tools gates.
json_tool_tier() {
  local tier="$1"; shift
  local name purpose
  while [ "$#" -gt 0 ]; do
    name="$1"; purpose="$2"; shift 2
    if command -v "$name" >/dev/null 2>&1; then
      json_row "$name" "$tier" ok "$purpose"
    else
      json_row "$name" "$tier" missing "$purpose"
      [ "$tier" != required ] || JSON_MISS=$((JSON_MISS + 1))
    fi
  done
}

collect_json_rows() {
  local probe status
  JSON_ROWS=""; JSON_MISS=0
  json_tool_tier required "${REQUIRED_TOOLS[@]}"
  json_tool_tier pr-flow "${PRFLOW_TOOLS[@]}"
  json_tool_tier optional "${OPTIONAL_TOOLS[@]}"
  probe="$(node_probe)"
  json_row node optional "${probe%%$'\t'*}" "${probe#*$'\t'}"
  # claude-runtime counts toward readiness like a required tool (report_tools
  # folds report_runtime's failure into the same miss count).
  status="$(claude_runtime_status)"
  case "$status" in
    ready) json_row claude-runtime required ok "$(runtime_note "$status")" ;;
    absent|unauthenticated)
      json_row claude-runtime required missing "$(runtime_note "$status")"
      JSON_MISS=$((JSON_MISS + 1)) ;;
    *) dm_die "invalid Claude probe result: '$status'" ;;
  esac
  probe_pr_delivery
  if [ "$PR_DELIVERY" = ready ]; then
    json_row pr-delivery pr-flow ok "$(pr_delivery_note "$PR_DELIVERY")"
  else
    json_row pr-delivery pr-flow missing "$(pr_delivery_note "$PR_DELIVERY")"
  fi
}

# The same verdict wording the full report prints, from the same three inputs.
json_verdict() {
  if [ "$1" -gt 0 ] || [ "$2" -gt 0 ]; then printf 'NOT READY\n'; return 0; fi
  case "$PR_DELIVERY" in
    ready)          printf 'READY\n' ;;
    no-cli|no-auth) printf 'READY (LOCAL-ONLY)\n' ;;
    *)              printf 'NOT READY\n' ;;
  esac
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
    printf '       ^ restore with dm-state.sh import <archive>, or reset to {"repos":{}}\n'
    bad=$((bad + 1))
  fi
  # A registry entry under the distro's reserved name is shadowed by the alias:
  # dm_repo_dir_or_none short-circuits before the registry read, so such a repo
  # silently resolves to $DM_HOME with authority `never`. dm-repo.sh blocks new
  # ones; a PRE-EXISTING entry can only be surfaced, so say so rather than let it
  # redirect quietly.
  if [ -f "$DM_REGISTRY" ] && jq -e --arg n "$DM_DISTRO_REPO" '.repos[$n]' "$DM_REGISTRY" >/dev/null 2>&1; then
    printf '  FAIL registry has an entry named %s, the reserved distro name\n' "$DM_DISTRO_REPO"
    printf '       ^ it is shadowed: the name resolves to the distro root, not its clone.\n'
    printf '         Rename it (dm-repo.sh remove %s, then re-add under another name).\n' "$DM_DISTRO_REPO"
    bad=$((bad + 1))
  fi
  backlog="$DM_STATE/backlog.json"
  if [ -f "$backlog" ] && ! jq . "$backlog" >/dev/null 2>&1; then
    printf '  FAIL state/backlog.json is not valid JSON\n'
    printf '       ^ restore with dm-state.sh import <archive>, or reset to {"items":[],"decisions":[]}\n'
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

mode="full"; json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    check|full) mode="$1"; shift ;;
    --json) json=1; shift ;;
    *) dm_die "usage: dm-doctor.sh [check] [--json]" ;;
  esac
done
# `full` scaffolds and prints sections; there is no document to emit for it.
[ "$json" -eq 0 ] || [ "$mode" = check ] || dm_die "--json applies to 'check' only: dm-doctor.sh check --json"
case "$mode" in
  check)
    if [ "$json" -eq 1 ]; then
      dm_need jq
      collect_json_rows
      # The FAIL hints go to the human path only; here the corrupt state shows up
      # as the verdict and the exit code, which must both match `check` exactly.
      badjson=0; probe_state_json >/dev/null || badjson=$?
      printf '%s' "$JSON_ROWS" | jq -c -s \
        --arg verdict "$(json_verdict "$JSON_MISS" "$badjson")" \
        --argjson pr_delivery "$([ "$PR_DELIVERY" = ready ] && echo true || echo false)" \
        '{verdict:$verdict, pr_delivery:$pr_delivery, checks:.}'
      if [ "$JSON_MISS" -gt 0 ]; then exit "$JSON_MISS"; fi
      if [ "$badjson" -gt 0 ]; then exit 1; fi
      exit 0
    fi
    # Compact readiness probe for dm-session-start; no scaffold, no headings.
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
    # The verdict must not overstate what works. A bare READY is reserved for a
    # home where BOTH delivery paths run; otherwise it is qualified and names
    # the missing piece, so the PR path never fails first at delivery time.
    case "$PR_DELIVERY" in
      ready)
        printf '  READY: required tools present; state valid; home scaffolded.\n' ;;
      no-cli)
        printf '  READY (LOCAL-ONLY): required tools present; state valid; home scaffolded.\n'
        printf '  PR DELIVERY UNAVAILABLE: gh is not installed (%s). Approved fast-forward landing works; opening or merging a PR does not.\n' "$(tool_hint gh)" ;;
      no-auth)
        printf '  READY (LOCAL-ONLY): required tools present; state valid; home scaffolded.\n'
        printf '  PR DELIVERY UNAVAILABLE: gh is not authenticated (run: gh auth login). Approved fast-forward landing works; opening or merging a PR does not.\n' ;;
      *)
        printf '  NOT READY: PR delivery status could not be resolved.\n'
        exit 1 ;;
    esac
    ;;

  *)
    dm_die "usage: dm-doctor.sh [check]"
    ;;
esac

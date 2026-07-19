#!/usr/bin/env bash
# dm-secondmate.sh - locked owner of persistent domain-supervisor identity state.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need jq
dm_ensure_dirs

STATE="$DM_STATE/secondmates.json"

init_state() {
  local tmp
  [ -f "$STATE" ] && return 0
  dm_lock "$STATE"
  if [ ! -f "$STATE" ]; then
    tmp="$(mktemp "$DM_STATE/.secondmates.json.XXXXXX")" || {
      dm_unlock "$STATE"; dm_die "mktemp failed for secondmates.json"
    }
    printf '{"secondmates":{}}\n' > "$tmp" || {
      rm -f "$tmp"; dm_unlock "$STATE"; dm_die "failed initializing secondmates.json"
    }
    mv -f "$tmp" "$STATE" || {
      rm -f "$tmp"; dm_unlock "$STATE"; dm_die "failed committing secondmates.json"
    }
  fi
  dm_unlock "$STATE"
}

require_single_line() {
  local label="$1" value="$2"
  [ -n "$value" ] || dm_die "$label must not be empty"
  case "$value" in *$'\n'*|*$'\r'*) dm_die "$label must be single-line" ;; esac
}

validate_thread_name() {
  case "$1" in ''|*[!a-z0-9_]*) dm_die "invalid Codex thread name: '$1'" ;; esac
  [ "${#1}" -le 64 ] || dm_die "Codex thread name exceeds 64 characters"
}

validate_repos() {
  local remaining="$1" repo
  [ -n "$remaining" ] || dm_die "repo list must not be empty"
  while :; do
    repo="${remaining%%,*}"
    dm_require_id "$repo"
    [ "$remaining" = "$repo" ] && break
    remaining="${remaining#*,}"
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  prepare|attach|abandon|clear|retire|init) init_state ;;
  get|list|reconcile) [ -f "$STATE" ] || {
    [ "$cmd" = "get" ] && dm_die "no secondmate state: $STATE"
    exit 0
  } ;;
esac
case "$cmd" in
  prepare)
    id="${1:-}"; shift || true
    dm_require_id "$id"
    scope=""; repos=""; thread_name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --scope) scope="${2:-}"; shift 2 ;;
        --repos) repos="${2:-}"; shift 2 ;;
        --thread-name) thread_name="${2:-}"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    require_single_line "scope" "$scope"
    validate_repos "$repos"
    validate_thread_name "$thread_name"
    dm_json_update "$STATE" --arg id "$id" --arg scope "$scope" --arg repos "$repos" \
      --arg thread "$thread_name" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      if (.secondmates[$id] == null or .secondmates[$id].status == "dormant") then
        .secondmates[$id] = ((.secondmates[$id] // {}) + {
          scope:$scope, repos:($repos | split(",")), thread_name:$thread,
          agent_id:"", status:"launching", updated:$now
        })
      else error("secondmate already launching, active, or retired") end'
    ;;
  attach)
    id="${1:-}"; agent_id="${2:-}"
    dm_require_id "$id"; require_single_line "agent id" "$agent_id"
    [ "${#agent_id}" -le 256 ] || dm_die "agent id exceeds 256 characters"
    dm_json_update "$STATE" --arg id "$id" --arg agent "$agent_id" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      if (.secondmates[$id].status == "launching" and
          (.secondmates[$id].thread_name | length > 0) and
          ((.secondmates[$id].agent_id // "") == "")) then
        .secondmates[$id].agent_id=$agent |
        .secondmates[$id].status="active" |
        .secondmates[$id].updated=$now
      else error("secondmate is not an unowned prepared launch") end'
    ;;
  abandon)
    id="${1:-}"; confirmation="${2:-}"
    dm_require_id "$id"
    [ "$confirmation" = "--confirmed-no-live" ] || dm_die "usage: dm-secondmate.sh abandon <id> --confirmed-no-live"
    dm_json_update "$STATE" --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      if (.secondmates[$id].status == "launching" and ((.secondmates[$id].agent_id // "") == "")) then
        .secondmates[$id].status="dormant" |
        .secondmates[$id].last_clear_reason="launch failed; no live owner confirmed" |
        .secondmates[$id].updated=$now
      else error("only an unowned launching record can be abandoned") end'
    ;;
  clear)
    id="${1:-}"; expected="${2:-}"; reason="${3:-}"
    dm_require_id "$id"; require_single_line "expected agent id" "$expected"
    require_single_line "clear reason" "$reason"
    dm_json_update "$STATE" --arg id "$id" --arg agent "$expected" --arg reason "$reason" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      if (.secondmates[$id].agent_id == $agent and $agent != "") then
        .secondmates[$id].agent_id="" |
        .secondmates[$id].status="dormant" |
        .secondmates[$id].last_clear_reason=$reason |
        .secondmates[$id].updated=$now
      else error("runtime owner does not match") end'
    ;;
  retire)
    id="${1:-}"; confirmation="${2:-}"
    dm_require_id "$id"
    [ "$confirmation" = "--confirmed-idle" ] || dm_die "usage: dm-secondmate.sh retire <id> --confirmed-idle"
    dm_json_update "$STATE" --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      if (.secondmates[$id].status == "dormant" and ((.secondmates[$id].agent_id // "") == "")) then
        .secondmates[$id].status="retired" | .secondmates[$id].updated=$now
      else error("secondmate must be dormant and unowned before retirement") end'
    ;;
  get)
    id="${1:-}"; dm_require_id "$id"
    jq -e --arg id "$id" '.secondmates[$id]' "$STATE"
    ;;
  list)
    jq -r '.secondmates | to_entries[] |
      [.key,.value.status,.value.thread_name,(.value.agent_id // ""),(.value.repos | join(",")),.value.scope] | @tsv' "$STATE"
    ;;
  reconcile)
    jq -r '.secondmates | to_entries[] |
      if .value.status == "active" and ((.value.agent_id // "") != "") then
        "VERIFY-LIVE\t\(.key)\t\(.value.thread_name)\t\(.value.agent_id)"
      elif .value.status == "launching" then
        "AMBIGUOUS-LAUNCH\t\(.key)\t\(.value.thread_name)\tlist by exact name before any spawn"
      elif .value.status == "dormant" then
        "DORMANT\t\(.key)\t\(.value.thread_name)\teligible only after no-live-owner proof"
      elif .value.status == "retired" then empty
      else "INVALID\t\(.key)\t\(.value.status // "missing")\tfail closed" end' "$STATE"
    ;;
  init) ;;
  *)
    dm_die "usage: dm-secondmate.sh {prepare|attach|abandon|clear|retire|get|list|reconcile} ..."
    ;;
esac

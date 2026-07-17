#!/usr/bin/env bash
# mh-backlog.sh - the durable, cross-session work queue and operator-decision log.
#
# Source of truth is state/backlog.json (one jq-owned parser, no format drift);
# a human-readable state/backlog.md is re-rendered on every change. The native
# Claude Code task list is an in-session convenience; this file survives restarts.
#
# Work items:
#   add <id> "<title>" [--repo R] [--status queued|inflight] [--blocked-by a,b] [--note "..."]
#   move <id> <queued|inflight|done>
#   done <id> [--note "..."]
#   ready                 queued items whose blockers are all done/absent
#   decisions             open operator decisions (key + question), one per line
#   list                  print the rendered backlog
#
# Operator decisions (used by the decision-hold skill):
#   hold <key> "<question>" [--options "A | B"] [--origin <path>]
#   resolve <key> "<answer>"
#
# A decision hold stays open until resolved; completing/tearing down the task
# that surfaced it never closes it.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need jq
mh_ensure_dirs

BJSON="$MH_STATE/backlog.json"
BMD="$MH_STATE/backlog.md"
[ -f "$BJSON" ] || printf '{"items":[],"decisions":[]}\n' > "$BJSON"

bwrite() { local tmp; tmp="$(mktemp "$MH_STATE/.backlog.XXXXXX")"; jq "$@" "$BJSON" > "$tmp" && mv -f "$tmp" "$BJSON"; }

render() {
  {
    echo "# Backlog"
    echo
    for sec in inflight queued done; do
      case "$sec" in inflight) h="In flight";; queued) h="Queued";; done) h="Done";; esac
      echo "## $h"
      jq -r --arg s "$sec" '
        .items[] | select(.status==$s) |
        "- [\(if .status=="done" then "x" else " " end)] \(.id) \(.title)" +
        (if (.repo//"")!="" then "  (\(.repo))" else "" end) +
        (if (.blocked_by|length)>0 then "\n    blocked-by: \(.blocked_by|join(", "))" else "" end) +
        (if (.note//"")!="" then "\n    note: \(.note)" else "" end)
      ' "$BJSON"
      echo
    done
    echo "## Decisions (operator)"
    jq -r '
      .decisions[] |
      "- [\(if .status=="resolved" then "x" else " " end)] \(.key): \(.question)" +
      (if (.options//"")!="" then "\n    options: \(.options)" else "" end) +
      (if (.origin//"")!="" then "\n    origin: \(.origin)" else "" end) +
      (if (.answer//"")!="" then "\n    answer: \(.answer)" else "" end)
    ' "$BJSON"
  } > "$BMD"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    id="${1:-}"; title="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$id" ] && [ -n "$title" ] || mh_die "usage: mh-backlog.sh add <id> \"<title>\" [--repo R] [--status queued|inflight] [--blocked-by a,b] [--note ...]"
    mh_require_id "$id"
    repo=""; status="queued"; blocked=""; note=""
    while [ "$#" -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2;; --status) status="${2:-}"; shift 2;;
      --blocked-by) blocked="${2:-}"; shift 2;; --note) note="${2:-}"; shift 2;;
      *) mh_die "unknown flag: $1";; esac; done
    case "$status" in queued|inflight|done) ;; *) mh_die "status must be queued|inflight|done";; esac
    bj="$(printf '%s' "$blocked" | jq -R 'split(",") | map(select(length>0))')"
    bwrite --arg id "$id" --arg t "$title" --arg r "$repo" --arg s "$status" --arg n "$note" --argjson b "${bj:-[]}" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.items |= (map(select(.id!=$id)) + [{id:$id,title:$t,repo:$r,status:$s,blocked_by:$b,note:$n,ts:$ts}])'
    render; mh_info "backlog: added $id ($status)"
    ;;
  move)
    id="${1:-}"; status="${2:-}"
    [ -n "$id" ] && [ -n "$status" ] || mh_die "usage: mh-backlog.sh move <id> <queued|inflight|done>"
    case "$status" in queued|inflight|done) ;; *) mh_die "status must be queued|inflight|done";; esac
    jq -e --arg id "$id" 'any(.items[]; .id==$id)' "$BJSON" >/dev/null || mh_die "no backlog item: $id"
    bwrite --arg id "$id" --arg s "$status" '.items |= map(if .id==$id then .status=$s else . end)'
    render; mh_info "backlog: $id -> $status"
    ;;
  done)
    id="${1:-}"; shift || true; note=""
    [ "${1:-}" = "--note" ] && note="${2:-}"
    [ -n "$id" ] || mh_die "usage: mh-backlog.sh done <id> [--note ...]"
    jq -e --arg id "$id" 'any(.items[]; .id==$id)' "$BJSON" >/dev/null || mh_die "no backlog item: $id"
    bwrite --arg id "$id" --arg n "$note" '.items |= map(if .id==$id then (.status="done" | (if $n!="" then .note=$n else . end)) else . end)'
    render; mh_info "backlog: $id done"
    ;;
  ready)
    # queued items whose blockers are all done or absent
    jq -r '
      (.items | map(select(.status=="done").id)) as $done |
      .items[] | select(.status=="queued") |
      select(all(.blocked_by[]; . as $b | ($done|index($b))!=null)) |
      "\(.id)\t\(.title)"' "$BJSON" | column -t -s$'\t' 2>/dev/null || true
    ;;
  decisions)
    # open operator decisions, machine-readable (key<TAB>question); consumed by
    # status views. Resolved holds are omitted.
    jq -r '.decisions[] | select(.status=="open") | "\(.key)\t\(.question)"' "$BJSON" \
      | column -t -s$'\t' 2>/dev/null || true
    ;;
  hold)
    key="${1:-}"; question="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$key" ] && [ -n "$question" ] || mh_die "usage: mh-backlog.sh hold <key> \"<question>\" [--options \"A | B\"] [--origin <path>]"
    options=""; origin=""
    while [ "$#" -gt 0 ]; do case "$1" in --options) options="${2:-}"; shift 2;; --origin) origin="${2:-}"; shift 2;; *) mh_die "unknown flag: $1";; esac; done
    # idempotent on key: upsert, preserving status/answer if the hold already exists
    bwrite --arg k "$key" --arg q "$question" --arg o "$options" --arg og "$origin" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (.decisions | map(select(.key==$k)) | .[0]) as $existing
      | (($existing // {key:$k, status:"open", answer:"", ts:$ts}) | .question=$q | .options=$o | .origin=$og) as $upd
      | .decisions = ((.decisions | map(select(.key!=$k))) + [$upd])'
    render; mh_info "backlog: decision hold '$key' open"
    ;;
  resolve)
    key="${1:-}"; answer="${2:-}"
    [ -n "$key" ] && [ -n "$answer" ] || mh_die "usage: mh-backlog.sh resolve <key> \"<answer>\""
    jq -e --arg k "$key" 'any(.decisions[]; .key==$k)' "$BJSON" >/dev/null || mh_die "no decision hold: $key"
    bwrite --arg k "$key" --arg a "$answer" '.decisions |= map(if .key==$k then (.status="resolved"|.answer=$a) else . end)'
    render; mh_info "backlog: decision '$key' resolved"
    ;;
  list|show|"")
    render; cat "$BMD"
    ;;
  *) echo "usage: mh-backlog.sh {add|move|done|ready|decisions|hold|resolve|list} ..." >&2; exit 2 ;;
esac

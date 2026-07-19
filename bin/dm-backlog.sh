#!/usr/bin/env bash
# dm-backlog.sh - the durable, cross-session work queue and operator-decision log.
#
# Source of truth is state/backlog.json (one jq-owned parser, no format drift);
# a human-readable state/backlog.md is re-rendered on every change. Runtime
# task/thread lists are in-session conveniences; this file survives restarts.
#
# Work items:
#   add <id> "<title>" [--repo R] [--status queued|inflight] [--blocked-by a,b] [--note "..."] [--campaign C]
#   move <id> <queued|inflight|done>
#   done <id> [--note "..."]
#   ready                 queued items whose blockers are all done/absent
#   campaign <id>         items grouped under a campaign, with their status
#   decisions             open operator decisions (key + question), one per line
#   list                  print the rendered backlog
#
# A campaign groups the child items of one multi-repo intent (one child task per
# repo) so it can be tracked and reported as a unit; see the fleet-change skill.
#
# Operator decisions (used by the decision-hold skill):
#   hold <key> "<question>" [--options "A | B"] [--origin <path>]
#   resolve <key> "<answer>"
#
# A decision hold stays open until resolved; completing/tearing down the task
# that surfaced it never closes it.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need jq
dm_ensure_dirs

BJSON="$DM_STATE/backlog.json"
BMD="$DM_STATE/backlog.md"
[ -f "$BJSON" ] || printf '{"items":[],"decisions":[]}\n' > "$BJSON"

# Locked, atomic update of backlog.json. Delegates to the shared dm_json_update
# (dm-lib.sh) — the single owner of the locked read-modify-write of a JSON file —
# so the backlog and the registry share one audited path (no format drift).
bwrite() { dm_json_update "$BJSON" "$@"; }

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
        (if (.campaign//"")!="" then "\n    campaign: \(.campaign)" else "" end) +
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
    [ -n "$id" ] && [ -n "$title" ] || dm_die "usage: dm-backlog.sh add <id> \"<title>\" [--repo R] [--status queued|inflight] [--blocked-by a,b] [--note ...] [--campaign C]"
    dm_require_id "$id"
    repo=""; status="queued"; blocked=""; note=""; campaign=""
    while [ "$#" -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2;; --status) status="${2:-}"; shift 2;;
      --blocked-by) blocked="${2:-}"; shift 2;; --note) note="${2:-}"; shift 2;;
      --campaign) campaign="${2:-}"; shift 2;;
      *) dm_die "unknown flag: $1";; esac; done
    case "$status" in queued|inflight|done) ;; *) dm_die "status must be queued|inflight|done";; esac
    [ -n "$campaign" ] && dm_require_id "$campaign"
    bj="$(printf '%s' "$blocked" | jq -R 'split(",") | map(select(length>0))')"
    bwrite --arg id "$id" --arg t "$title" --arg r "$repo" --arg s "$status" --arg n "$note" --arg cp "$campaign" --argjson b "${bj:-[]}" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.items |= (map(select(.id!=$id)) + [{id:$id,title:$t,repo:$r,status:$s,blocked_by:$b,note:$n,campaign:$cp,ts:$ts}])'
    render; dm_info "backlog: added $id ($status)"
    ;;
  move)
    id="${1:-}"; status="${2:-}"
    [ -n "$id" ] && [ -n "$status" ] || dm_die "usage: dm-backlog.sh move <id> <queued|inflight|done>"
    case "$status" in queued|inflight|done) ;; *) dm_die "status must be queued|inflight|done";; esac
    jq -e --arg id "$id" 'any(.items[]; .id==$id)' "$BJSON" >/dev/null || dm_die "no backlog item: $id"
    bwrite --arg id "$id" --arg s "$status" '.items |= map(if .id==$id then .status=$s else . end)'
    render; dm_info "backlog: $id -> $status"
    ;;
  done)
    id="${1:-}"; shift || true; note=""
    [ "${1:-}" = "--note" ] && note="${2:-}"
    [ -n "$id" ] || dm_die "usage: dm-backlog.sh done <id> [--note ...]"
    jq -e --arg id "$id" 'any(.items[]; .id==$id)' "$BJSON" >/dev/null || dm_die "no backlog item: $id"
    bwrite --arg id "$id" --arg n "$note" '.items |= map(if .id==$id then (.status="done" | (if $n!="" then .note=$n else . end)) else . end)'
    render; dm_info "backlog: $id done"
    ;;
  ready)
    # Queued items whose blockers are all COMPLETE (or absent). A blocker's true
    # completion comes from `dm-task.sh state` (reconciled from real signals —
    # merged PR, merge event, report), NOT the hand-set backlog status, which can
    # lie both ways: a blocker that actually landed but was never marked `done`,
    # or one marked `done` that never landed. Fall back to the backlog status
    # only when the blocker id has no task record at all.
    task_bin="$(dirname "${BASH_SOURCE[0]}")/dm-task.sh"
    blockers="$(jq -r '[.items[] | select(.status=="queued") | .blocked_by[]] | unique | .[]' "$BJSON")"
    complete_ids=""
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if [ -f "$(dm_meta_path "$b")" ]; then
        # Capture once and match with case (no `grep -q` in a pipe: it would
        # SIGPIPE the producer, which pipefail reports as failure).
        st="$("$task_bin" state "$b" 2>/dev/null || true)"
        case "$st" in "state: done"*) complete_ids="${complete_ids}${b}"$'\n' ;; esac
      elif jq -e --arg b "$b" 'any(.items[]; .id==$b and .status=="done")' "$BJSON" >/dev/null 2>&1; then
        complete_ids="${complete_ids}${b}"$'\n'
      fi
    done <<EOF
$blockers
EOF
    complete="$(printf '%s' "$complete_ids" | jq -R -s 'split("\n") | map(select(length>0))')"
    jq -r --argjson complete "$complete" '
      .items[] | select(.status=="queued") |
      select(all(.blocked_by[]; . as $b | ($complete|index($b))!=null)) |
      "\(.id)\t\(.title)"' "$BJSON" | column -t -s$'\t' 2>/dev/null || true
    ;;
  campaign)
    # Rollup view: every item tagged with this campaign id and its current
    # backlog status (id<TAB>status<TAB>title(repo)). Grouping only — each child
    # is an ordinary gated task; the fleet-change skill drives the fan-out.
    cid="${1:-}"
    [ -n "$cid" ] || dm_die "usage: dm-backlog.sh campaign <id>"
    dm_require_id "$cid"
    jq -r --arg c "$cid" '
      .items[] | select((.campaign//"")==$c) |
      "\(.id)\t\(.status)\t\(.title)" +
      (if (.repo//"")!="" then "  (\(.repo))" else "" end)' "$BJSON" \
      | column -t -s$'\t' 2>/dev/null || true
    ;;
  decisions)
    # open operator decisions, machine-readable (key<TAB>question); consumed by
    # status views. Resolved holds are omitted.
    jq -r '.decisions[] | select(.status=="open") | "\(.key)\t\(.question)"' "$BJSON" \
      | column -t -s$'\t' 2>/dev/null || true
    ;;
  hold)
    key="${1:-}"; question="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$key" ] && [ -n "$question" ] || dm_die "usage: dm-backlog.sh hold <key> \"<question>\" [--options \"A | B\"] [--origin <path>]"
    options=""; origin=""
    while [ "$#" -gt 0 ]; do case "$1" in --options) options="${2:-}"; shift 2;; --origin) origin="${2:-}"; shift 2;; *) dm_die "unknown flag: $1";; esac; done
    # idempotent on key: upsert, preserving status/answer if the hold already exists
    bwrite --arg k "$key" --arg q "$question" --arg o "$options" --arg og "$origin" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (.decisions | map(select(.key==$k)) | .[0]) as $existing
      | (($existing // {key:$k, status:"open", answer:"", ts:$ts}) | .question=$q | .options=$o | .origin=$og) as $upd
      | .decisions = ((.decisions | map(select(.key!=$k))) + [$upd])'
    render; dm_info "backlog: decision hold '$key' open"
    ;;
  resolve)
    key="${1:-}"; answer="${2:-}"
    [ -n "$key" ] && [ -n "$answer" ] || dm_die "usage: dm-backlog.sh resolve <key> \"<answer>\""
    jq -e --arg k "$key" 'any(.decisions[]; .key==$k)' "$BJSON" >/dev/null || dm_die "no decision hold: $key"
    bwrite --arg k "$key" --arg a "$answer" '.decisions |= map(if .key==$k then (.status="resolved"|.answer=$a) else . end)'
    render; dm_info "backlog: decision '$key' resolved"
    ;;
  list|show|"")
    render; cat "$BMD"
    ;;
  *) echo "usage: dm-backlog.sh {add|move|done|ready|campaign|decisions|hold|resolve|list} ..." >&2; exit 2 ;;
esac

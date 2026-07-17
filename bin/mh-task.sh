#!/usr/bin/env bash
# mh-task.sh - durable per-task records and on-demand current-state reconciliation.
#
# Design split (inherited from firstmate, the part worth keeping):
#   - state/tasks/<id>.meta   durable record: kind, repo, worktree, branch,
#                             mode, agent_id, pr, pr_state, ... Written only
#                             through mh-lib's single owner path.
#   - state/tasks/<id>.status APPEND-ONLY event log. A line is a wake EVENT, not
#                             current-state truth.
#   - `state <id>`            reconciles authoritative current state on demand
#                             from real signals (worktree landed? PR merged?
#                             agent alive?), never from the last status line.
#
# The native Claude Code task list is the in-session working mirror; these files
# are the cross-session source of truth.
#
# Commands:
#   new <id> --kind ship|scout --repo R [--mode M] [--title T]
#   set <id> <key> <value>
#   get <id> [<key>]
#   event <id> <state> [<note>]
#   state <id>            reconcile and print current state
#   archive <id>          move a terminal-done task's records + artifacts to
#                         state/archive/ (fails closed on a non-done or live task)
#   list

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_ensure_dirs

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    id="${1:-}"; shift || true
    [ -n "$id" ] || mh_die "usage: mh-task.sh new <id> --kind ship|scout --repo R [--mode M] [--title T]"
    mh_require_id "$id"
    [ -f "$(mh_meta_path "$id")" ] && mh_die "task '$id' already exists"
    kind=""; repo=""; mode=""; title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) kind="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --mode) mode="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    case "$kind" in ship|scout) ;; *) mh_die "--kind must be ship|scout" ;; esac
    [ -n "$repo" ] || mh_die "--repo is required"
    # inherit mode from the repo registry unless overridden
    [ -n "$mode" ] || mode="$(mh_registry_get "$repo" mode)"
    [ -n "$mode" ] || mode="pipeline"
    mh_meta_set "$id" kind "$kind"
    mh_meta_set "$id" repo "$repo"
    mh_meta_set "$id" mode "$mode"
    [ -n "$title" ] && mh_meta_set "$id" title "$title"
    mh_meta_set "$id" created "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mh_status_append "$id" created "$title"
    mh_info "created task $id (kind=$kind repo=$repo mode=$mode)"
    ;;

  set)
    id="${1:-}"; key="${2:-}"; value="${3:-}"
    [ -n "$id" ] && [ -n "$key" ] || mh_die "usage: mh-task.sh set <id> <key> <value>"
    mh_meta_set "$id" "$key" "$value"
    ;;

  get)
    id="${1:-}"; key="${2:-}"
    [ -n "$id" ] || mh_die "usage: mh-task.sh get <id> [<key>]"
    if [ -n "$key" ]; then mh_meta_get "$id" "$key"
    else cat "$(mh_meta_path "$id")" 2>/dev/null || mh_die "no such task: $id"; fi
    ;;

  event)
    id="${1:-}"; st="${2:-}"; note="${3:-}"
    [ -n "$id" ] && [ -n "$st" ] || mh_die "usage: mh-task.sh event <id> <state> [<note>]"
    mh_status_append "$id" "$st" "$note"
    ;;

  state)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-task.sh state <id>"
    [ -f "$(mh_meta_path "$id")" ] || { echo "state: unknown · source: none · no such task"; exit 0; }
    kind="$(mh_meta_get "$id" kind)"
    wt="$(mh_meta_get "$id" worktree)"
    pr="$(mh_meta_get "$id" pr)"
    # 1) PR merged is terminal-done for a ship task.
    if [ -n "$pr" ]; then
      st="$(mh_meta_get "$id" pr_state)"
      [ "$st" = "MERGED" ] && { echo "state: done · source: pr · $pr merged"; exit 0; }
    fi
    # 2) Scout: done once its report exists.
    if [ "$kind" = "scout" ] && [ -f "$MH_DATA/$id/report.md" ]; then
      echo "state: done · source: report · data/$id/report.md"; exit 0
    fi
    # 3) Ship: done only on POSITIVE landing evidence (a merge event), never on
    #    the mere absence of unlanded commits (that also matches an unstarted task).
    #    Anchor to the VERB field: a status line is "TIMESTAMP verb: note" and the
    #    timestamp has no spaces, so `^[^ ]+ merged: ` matches only a real `merged`
    #    event — not a note whose text happens to contain "merged: " (e.g. a
    #    crewmate note about an upstream PR), which would falsely flip a live,
    #    unlanded task to done.
    if [ "$kind" = "ship" ] && grep -qE '^[^ ]+ merged: ' "$(mh_status_path "$id")" 2>/dev/null; then
      echo "state: done · source: status-log · landed"; exit 0
    fi
    # 3b) Ship with committed work not yet landed is at least "working", even if
    #     the crewmate never emitted an event.
    has_work=0
    if [ "$kind" = "ship" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
      "$(dirname "${BASH_SOURCE[0]}")/mh-worktree.sh" landed "$id" >/dev/null 2>&1 || has_work=1
    fi
    # 4) Otherwise fall back to the last event verb that maps to a real state.
    last="$(tail -n1 "$(mh_status_path "$id")" 2>/dev/null | sed -n 's/^[0-9TZ:-]* //p')"
    verb="${last%%:*}"
    case "$verb" in
      blocked|needs-decision) echo "state: blocked · source: status-log · $last" ;;
      paused)                 echo "state: paused · source: status-log · $last" ;;
      failed)                 echo "state: failed · source: status-log · $last" ;;
      review-ready)           echo "state: awaiting-review · source: status-log · lavish artifact ready for the operator: $last" ;;
      ready|done)             echo "state: working · source: status-log · reported ready but not yet landed: $last" ;;
      ''|created)
        if [ "$has_work" -eq 1 ]; then echo "state: working · source: worktree · committed work not yet landed"
        else echo "state: pending · source: status-log · not yet dispatched"; fi ;;
      *)                      echo "state: working · source: status-log · $last" ;;
    esac
    ;;

  archive)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-task.sh archive <id>"
    mh_require_id "$id"
    meta="$(mh_meta_path "$id")"
    [ -f "$meta" ] || mh_die "no such task: $id"
    # Fail closed: only a task that reconciles to terminal 'done' may be archived.
    # `state` derives 'done' solely from positive landing/report evidence, so a
    # ship task with unlanded work reconciles to 'working' and is refused here —
    # archival must never bury unfinished work.
    st="$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    [ "$st" = "done" ] || mh_die "refusing to archive '$id': current state is '$st', not done"
    # A worktree still on disk is a live local copy that teardown never removed.
    # Its (possibly unlanded) work must not be swept away behind the operator's
    # back — require teardown first.
    wt="$(mh_meta_get "$id" worktree)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      mh_die "refusing to archive '$id': local copy still present at $wt (tear it down first)"
    fi
    archdir="$MH_STATE/archive"
    mkdir -p "$archdir"
    status="$(mh_status_path "$id")"
    # Lock the meta path so the move cannot race a concurrent meta writer.
    mh_lock "$meta"
    mv -f "$meta" "$archdir/$id.meta" || { mh_unlock "$meta"; mh_die "failed archiving meta for '$id'"; }
    if [ -f "$status" ]; then
      mv -f "$status" "$archdir/$id.status" || { mh_unlock "$meta"; mh_die "failed archiving status log for '$id'"; }
    fi
    mh_unlock "$meta"
    if [ -d "$MH_DATA/$id" ]; then
      rm -rf "$archdir/$id"   # replace any stale archive of a reused id
      mv -f "$MH_DATA/$id" "$archdir/$id" || mh_die "failed archiving data dir for '$id'"
    fi
    mh_info "archived task $id -> state/archive/"
    ;;

  list)
    printf 'ID\tKIND\tREPO\tSTATE\n'
    for m in "$MH_TASKS"/*.meta; do
      [ -f "$m" ] || continue
      id="$(basename "$m" .meta)"
      printf '%s\t%s\t%s\t%s\n' "$id" "$(mh_meta_get "$id" kind)" "$(mh_meta_get "$id" repo)" "$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    done | column -t -s$'\t' 2>/dev/null || cat
    ;;

  *)
    echo "usage: mh-task.sh {new|set|get|event|state|archive|list} ..." >&2; exit 2 ;;
esac

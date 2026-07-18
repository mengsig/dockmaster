#!/usr/bin/env bash
# dm-task.sh - durable per-task records and on-demand current-state reconciliation.
#
# Design split (the part worth keeping):
#   - state/tasks/<id>.meta   durable record: kind, repo, worktree, branch,
#                             mode, agent_id, pr, pr_state, ... Written only
#                             through dm-lib's single owner path.
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
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-task.sh new <id> --kind ship|scout --repo R [--mode M] [--title T]"
    dm_require_id "$id"
    [ -f "$(dm_meta_path "$id")" ] && dm_die "task '$id' already exists"
    kind=""; repo=""; mode=""; title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) kind="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --mode) mode="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    case "$kind" in ship|scout) ;; *) dm_die "--kind must be ship|scout" ;; esac
    [ -n "$repo" ] || dm_die "--repo is required"
    # inherit mode from the repo registry unless overridden
    [ -n "$mode" ] || mode="$(dm_registry_get "$repo" mode)"
    [ -n "$mode" ] || mode="pipeline"
    dm_meta_set "$id" kind "$kind"
    dm_meta_set "$id" repo "$repo"
    dm_meta_set "$id" mode "$mode"
    [ -n "$title" ] && dm_meta_set "$id" title "$title"
    dm_meta_set "$id" created "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dm_status_append "$id" created "$title"
    dm_info "created task $id (kind=$kind repo=$repo mode=$mode)"
    ;;

  set)
    id="${1:-}"; key="${2:-}"; value="${3:-}"
    [ -n "$id" ] && [ -n "$key" ] || dm_die "usage: dm-task.sh set <id> <key> <value>"
    # The PR-tracking fields are DERIVED from GitHub by dm-pr.sh (check/open/
    # merge) and are the trusted landing signal `dm-task.sh state` reads. Refuse
    # to hand-set them here: `set pr_state MERGED` would otherwise forge a
    # terminal landing over unlanded work (the same forge the `event merged`
    # reservation blocks). The sanctioned writer uses dm_meta_set directly.
    # `base` gets the same protection: it feeds `gh pr create --base` (via
    # dm_pr_base_for), so a hand-forged value would silently retarget a sub-PR.
    # It is recorded only by `dm-worktree.sh create --base`, which also writes
    # directly via dm_meta_set and so is unaffected by this CLI-only guard.
    case "$key" in
      pr|pr_state|merge_state) dm_die "'$key' is a PR-tracking field maintained by dm-pr.sh (check/open/merge); it must not be set by hand" ;;
      base) dm_die "'base' is recorded by dm-worktree.sh create --base; it must not be set by hand" ;;
    esac
    dm_meta_set "$id" "$key" "$value"
    ;;

  get)
    id="${1:-}"; key="${2:-}"
    [ -n "$id" ] || dm_die "usage: dm-task.sh get <id> [<key>]"
    dm_require_id "$id"
    if [ -n "$key" ]; then dm_meta_get "$id" "$key"
    else cat "$(dm_meta_path "$id")" 2>/dev/null || dm_die "no such task: $id"; fi
    ;;

  event)
    id="${1:-}"; st="${2:-}"; note="${3:-}"
    [ -n "$id" ] && [ -n "$st" ] || dm_die "usage: dm-task.sh event <id> <state> [<note>]"
    # 'merged' is a LANDING signal: `state` treats a `merged` status line as
    # terminal-done. It is appended ONLY by the sanctioned landing paths
    # (dm-merge.sh local / dm-pr.sh merge), which write it directly via
    # dm_status_append. Reject it here so a crewmate cannot forge a done/landed
    # signal over unlanded work (which would mis-report done and let a repo be
    # unregistered over a live worktree).
    case "$st" in
      merged) dm_die "'merged' is a landing signal appended only by dm-merge/dm-pr; dm-task.sh event must not forge it" ;;
    esac
    dm_status_append "$id" "$st" "$note"
    ;;

  state)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh state <id>"
    dm_require_id "$id"
    [ -f "$(dm_meta_path "$id")" ] || { echo "state: unknown · source: none · no such task"; exit 0; }
    kind="$(dm_meta_get "$id" kind)"
    wt="$(dm_meta_get "$id" worktree)"
    # Refresh pr_state from GitHub first so an out-of-band merge (operator merged
    # in the web UI) is seen, not reported as `working` forever. Best-effort: a
    # failed check must not abort this decision. No-op offline or when there is
    # no PR / it is already MERGED (dm_should_refresh_pr_state).
    if dm_should_refresh_pr_state "$id"; then
      "$(dirname "${BASH_SOURCE[0]}")/dm-pr.sh" check "$id" >/dev/null 2>&1 || true
    fi
    pr="$(dm_meta_get "$id" pr)"
    # 1) PR merged is terminal-done for a ship task.
    if [ -n "$pr" ]; then
      st="$(dm_meta_get "$id" pr_state)"
      [ "$st" = "MERGED" ] && { echo "state: done · source: pr · $pr merged"; exit 0; }
    fi
    # 2) Scout: done once its report exists.
    if [ "$kind" = "scout" ] && [ -f "$DM_DATA/$id/report.md" ]; then
      echo "state: done · source: report · data/$id/report.md"; exit 0
    fi
    # 3) Ship: done only on POSITIVE landing evidence (a merge event), never on
    #    the mere absence of unlanded commits (that also matches an unstarted task).
    #    Anchor to the VERB field: a status line is "TIMESTAMP verb: note" and the
    #    timestamp has no spaces, so `^[^ ]+ merged: ` matches only a real `merged`
    #    event — not a note whose text happens to contain "merged: " (e.g. a
    #    crewmate note about an upstream PR), which would falsely flip a live,
    #    unlanded task to done.
    if [ "$kind" = "ship" ] && grep -qE '^[^ ]+ merged: ' "$(dm_status_path "$id")" 2>/dev/null; then
      echo "state: done · source: status-log · landed"; exit 0
    fi
    # 3b) Ship with committed work not yet landed is at least "working", even if
    #     the crewmate never emitted an event.
    has_work=0
    if [ "$kind" = "ship" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
      "$(dirname "${BASH_SOURCE[0]}")/dm-worktree.sh" landed "$id" >/dev/null 2>&1 || has_work=1
    fi
    # 4) Otherwise fall back to the last event verb that maps to a real state.
    last="$(tail -n1 "$(dm_status_path "$id")" 2>/dev/null | sed -n 's/^[0-9TZ:-]* //p')"
    verb="${last%%:*}"
    case "$verb" in
      blocked)                echo "state: blocked · source: status-log · $last" ;;
      # A distinct token from 'blocked': an operator CHOICE is required, not just
      # unblocking action. decision-hold/supervision key off this exact string to
      # open a durable backlog hold before the task can be torn down.
      needs-decision)         echo "state: needs-decision · source: status-log · $last" ;;
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
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh archive <id>"
    dm_require_id "$id"
    meta="$(dm_meta_path "$id")"
    [ -f "$meta" ] || dm_die "no such task: $id"
    # Fail closed: only a task that reconciles to terminal 'done' may be archived.
    # `state` derives 'done' solely from positive landing/report evidence, so a
    # ship task with unlanded work reconciles to 'working' and is refused here —
    # archival must never bury unfinished work.
    st="$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    [ "$st" = "done" ] || dm_die "refusing to archive '$id': current state is '$st', not done"
    # A worktree still on disk is a live local copy that teardown never removed.
    # Its (possibly unlanded) work must not be swept away behind the operator's
    # back — require teardown first.
    wt="$(dm_meta_get "$id" worktree)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      dm_die "refusing to archive '$id': local copy still present at $wt (tear it down first)"
    fi
    archdir="$DM_STATE/archive"
    mkdir -p "$archdir"
    status="$(dm_status_path "$id")"
    # Lock the meta path so the move cannot race a concurrent meta writer.
    dm_lock "$meta"
    mv -f "$meta" "$archdir/$id.meta" || { dm_unlock "$meta"; dm_die "failed archiving meta for '$id'"; }
    if [ -f "$status" ]; then
      mv -f "$status" "$archdir/$id.status" || { dm_unlock "$meta"; dm_die "failed archiving status log for '$id'"; }
    fi
    dm_unlock "$meta"
    if [ -d "$DM_DATA/$id" ]; then
      rm -rf "$archdir/$id"   # replace any stale archive of a reused id
      mv -f "$DM_DATA/$id" "$archdir/$id" || dm_die "failed archiving data dir for '$id'"
    fi
    dm_info "archived task $id -> state/archive/"
    ;;

  list)
    printf 'ID\tKIND\tREPO\tSTATE\n'
    while IFS= read -r id; do
      # Bulk overview: reconcile each row OFFLINE (DM_NO_FETCH=1). A per-task live
      # PR refresh here would turn `list` (and the session-start digest that calls
      # it) into N sequential GitHub round-trips on the hottest command. A single
      # `state <id>` still refreshes live; `list` favors a fast local snapshot.
      printf '%s\t%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" kind)" "$(dm_meta_get "$id" repo)" "$(DM_NO_FETCH=1 "$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    done < <(dm_all_task_ids) | column -t -s$'\t' 2>/dev/null || cat
    ;;

  *)
    echo "usage: dm-task.sh {new|set|get|event|state|archive|list} ..." >&2; exit 2 ;;
esac

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
# The active runtime's task/thread list is the in-session working mirror; these
# files are the cross-session source of truth.
#
# Commands:
#   new <id> --kind ship|scout --repo R [--mode M] [--title T]
#   set <id> <key> <value>
#   approve <id> <fast|default|rigorous> [<first-gate>]
#   gate <id> <ready|start|block|complete> <gate> [...]
#   ready-gates            list approved gates waiting for a runtime owner
#   waiter <id> <prepare|active|idle|terminal> [...]
#   get <id> [<key>]
#   event <id> <state> [<note>]
#   state <id>            reconcile and print current state
#   archive <id>          move a terminal (done/discarded) task's records +
#                         artifacts to state/archive/ (fails closed otherwise)
#   list

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# `new` inherits a task's mode from the repo registry; a corrupt registry must
# not silently record an empty mode.
dm_registry_require_valid

valid_pipeline_tier() { case "${1:-}" in fast|default|rigorous) return 0 ;; *) return 1 ;; esac; }
valid_pipeline_gate() {
  case "${1:-}" in
    ''|[!a-z]*|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}
valid_integration_gate() {
  case "${1:-}" in
    rebase|merge-gate-review|final-tests|verify|security|pr|land) return 0 ;;
    *) return 1 ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-task.sh new <id> --kind ship|scout --repo R [--mode M] [--title T]"
    dm_require_id "$id"
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
    # Name the flag the operator actually typed; dm_task_create re-checks both as
    # the library-side boundary. Also keeps an empty repo out of the registry read.
    dm_valid_task_kind "$kind" || dm_die "--kind must be ship|scout"
    [ -n "$repo" ] || dm_die "--repo is required"
    # inherit mode from the repo registry unless overridden
    [ -n "$mode" ] || mode="$(dm_registry_get "$repo" mode)"
    [ -n "$mode" ] || mode="pipeline"
    dm_task_create "$id" "$kind" "$repo" "$mode" "$title"
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
    # `pr_head` too: dm-worktree.sh landed compares HEAD against it, so a
    # hand-set value would make post-merge commits look landed and removable.
    # `base` gets the same protection: it feeds `gh pr create --base` (via
    # dm_pr_base_for), so a hand-forged value would silently retarget a sub-PR.
    # It is recorded only by `dm-worktree.sh create --base`, which also writes
    # directly via dm_meta_set and so is unaffected by this CLI-only guard.
    case "$key" in
      pr|pr_state|merge_state|pr_check_snapshot|pr_head) dm_die "'$key' is a PR-tracking field maintained by dm-pr.sh (check/open/merge); it must not be set by hand" ;;
      base) dm_die "'base' is recorded by dm-worktree.sh create --base; it must not be set by hand" ;;
      worktree) dm_die "'worktree' is maintained by dm-worktree.sh create/remove; it must not be set by hand" ;;
      approved_at|pipeline_tier|pipeline_gate|pipeline_state|gate_started_at|pipeline_blocked_by|pipeline_blocked_reason)
        dm_die "'$key' is pipeline state maintained by dm-task.sh approve/gate; it must not be set by hand" ;;
      waiter_thread_name|waiter_agent_id|waiter_state)
        dm_die "'$key' is review-waiter state maintained by dm-task.sh waiter; it must not be set by hand" ;;
      review_session_state|review_session_started_at)
        dm_die "'$key' is review-session state maintained by dm-lavish.sh; it must not be set by hand" ;;
    esac
    dm_meta_set "$id" "$key" "$value"
    ;;

  approve)
    id="${1:-}"; tier="${2:-}"; gate="${3:-coldstart-review}"
    [ -n "$id" ] && [ -n "$tier" ] \
      || dm_die "usage: dm-task.sh approve <id> <fast|default|rigorous> [<first-gate>]"
    dm_require_id "$id"
    valid_pipeline_tier "$tier" || dm_die "pipeline tier must be fast|default|rigorous"
    valid_pipeline_gate "$gate" || dm_die "invalid pipeline gate: '$gate'"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    [ "$(dm_meta_get "$id" kind)" = "ship" ] || dm_die "only ship tasks enter a delivery pipeline"
    [ "$(dm_meta_get "$id" mode)" != "local-only" ] || dm_die "local-only tasks do not enter a PR pipeline"
    approved_at="$(dm_meta_get "$id" approved_at)"
    [ -z "$approved_at" ] || dm_die "task '$id' is already approved at $approved_at"
    approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dm_meta_set_fields_locked "$id" \
      approved_at "$approved_at" pipeline_tier "$tier" pipeline_gate "$gate" \
      pipeline_state ready gate_started_at "" pipeline_blocked_by "" pipeline_blocked_reason ""
    dm_unlock "$meta"
    dm_status_append "$id" working "approved; $tier pipeline gate '$gate' ready to schedule"
    ;;

  gate)
    id="${1:-}"; action="${2:-}"; gate="${3:-}"; shift 3 2>/dev/null || true
    [ -n "$id" ] && [ -n "$action" ] && [ -n "$gate" ] \
      || dm_die "usage: dm-task.sh gate <id> <ready|start|block|complete> <gate> [<blocker-id> <reason>]"
    dm_require_id "$id"
    valid_pipeline_gate "$gate" || dm_die "invalid pipeline gate: '$gate'"
    status_state=working
    status_note=""
    case "$action" in
      ready)
        [ "$#" -eq 0 ] || dm_die "usage: dm-task.sh gate <id> ready <gate>"
        ;;
      start)
        [ "$#" -eq 0 ] || dm_die "usage: dm-task.sh gate <id> start <gate>"
        ;;
      block)
        blocker="${1:-}"; reason="${2:-}"
        [ "$#" -eq 2 ] && [ -n "$blocker" ] && [ -n "$reason" ] \
          || dm_die "usage: dm-task.sh gate <id> block <integration-gate> <blocker-id> <reason>"
        valid_integration_gate "$gate" \
          || dm_die "overlap may block only integration/finalization gates: rebase|merge-gate-review|final-tests|verify|security|pr|land"
        dm_require_id "$blocker"
        [ "$blocker" != "$id" ] || dm_die "a task cannot block its own pipeline"
        [ -f "$(dm_meta_path "$blocker")" ] || dm_die "no active blocker task: $blocker"
        dm_require_single_line "pipeline blocker reason" "$reason"
        ;;
      complete)
        [ "$#" -le 1 ] || dm_die "usage: dm-task.sh gate <id> complete <gate> [<next-gate>]"
        next_gate="${1:-}"
        [ -z "$next_gate" ] || valid_pipeline_gate "$next_gate" \
          || dm_die "invalid next pipeline gate: '$next_gate'"
        ;;
      *) dm_die "gate action must be ready|start|block|complete" ;;
    esac
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    [ -n "$(dm_meta_get "$id" approved_at)" ] \
      || dm_die "task '$id' has no recorded approval; run dm-task.sh approve first"
    current_gate="$(dm_meta_get "$id" pipeline_gate)"
    current_state="$(dm_meta_get "$id" pipeline_state)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$action" in
      ready)
        [ "$current_state" = "blocked" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot ready '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        blocker="$(dm_meta_get "$id" pipeline_blocked_by)"
        if [ -f "$(dm_meta_path "$blocker")" ]; then
          blocker_state="$(DM_NO_FETCH=1 "$0" state "$blocker" | sed 's/ · .*//; s/^state: //')"
          [ "$blocker_state" = "done" ] \
            || dm_die "integration blocker '$blocker' is still '$blocker_state'; gate remains blocked"
        elif [ ! -f "$DM_STATE/archive/$blocker.meta" ]; then
          dm_die "integration blocker '$blocker' has no active or archived task record"
        fi
        dm_meta_set_fields_locked "$id" \
          pipeline_state ready gate_started_at "" pipeline_blocked_by "" pipeline_blocked_reason ""
        status_note="pipeline gate '$gate' ready to schedule"
        ;;
      start)
        [ "$current_state" = "ready" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot start '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        dm_meta_set_fields_locked "$id" pipeline_state running gate_started_at "$now"
        status_note="pipeline gate '$gate' started"
        ;;
      block)
        [ "$current_state" = "ready" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot block '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        dm_meta_set_fields_locked "$id" \
          pipeline_state blocked gate_started_at "" \
          pipeline_blocked_by "$blocker" pipeline_blocked_reason "$reason"
        status_state=paused
        status_note="integration gate '$gate' waits for '$blocker': $reason"
        ;;
      complete)
        [ "$current_state" = "running" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot complete '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        if [ -n "$next_gate" ]; then
          dm_meta_set_fields_locked "$id" \
            pipeline_gate "$next_gate" pipeline_state ready gate_started_at "" \
            pipeline_blocked_by "" pipeline_blocked_reason ""
          status_note="pipeline gate '$gate' complete; '$next_gate' ready to schedule"
        else
          dm_meta_set_fields_locked "$id" pipeline_state complete
          status_note="pipeline gate '$gate' complete"
        fi
        ;;
    esac
    dm_unlock "$meta"
    dm_status_append "$id" "$status_state" "$status_note"
    ;;

  ready-gates)
    printf 'ID\tTIER\tGATE\tAPPROVED\n'
    while IFS= read -r id; do
      [ "$(dm_meta_get "$id" pipeline_state)" = "ready" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" pipeline_tier)" \
        "$(dm_meta_get "$id" pipeline_gate)" "$(dm_meta_get "$id" approved_at)"
    done < <(dm_all_task_ids) | sort -t$'\t' -k4,4 | column -t -s$'\t' 2>/dev/null || cat
    ;;

  waiter)
    id="${1:-}"; action="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$id" ] && [ -n "$action" ] \
      || dm_die "usage: dm-task.sh waiter <id> <prepare|active|idle|terminal> [...]"
    dm_require_id "$id"
    case "$action" in
      prepare)
        thread="${1:-}"
        [ "$#" -eq 1 ] && [ -n "$thread" ] \
          || dm_die "usage: dm-task.sh waiter <id> prepare <thread-name>"
        case "$thread" in ''|*[!a-z0-9_]*) dm_die "waiter thread name must match [a-z0-9_]+" ;; esac
        [ "${#thread}" -le 64 ] || dm_die "waiter thread name must be <= 64 characters"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        old_thread="$(dm_meta_get "$id" waiter_thread_name)"
        old_agent="$(dm_meta_get "$id" waiter_agent_id)"
        case "$old_state" in
          prepared)
            [ "$old_thread" = "$thread" ] && [ -z "$old_agent" ] \
              || dm_die "task '$id' has malformed or ambiguous prepared waiter state; reconcile it before launch"
            ;;
          ''|terminal)
            [ -z "$old_thread" ] && [ -z "$old_agent" ] \
              || dm_die "task '$id' has legacy waiter identity without a live state; reconcile it before launch"
            ;;
          idle)
            dm_die "task '$id' has idle waiter '$old_agent'; reuse that exact identity instead of preparing another"
            ;;
          active)
            dm_die "task '$id' already has an active waiter; reconcile it before preparing another"
            ;;
          *)
            dm_die "task '$id' has unknown waiter state '$old_state'; reconcile it before launch"
            ;;
        esac
        dm_meta_set_fields_locked "$id" waiter_thread_name "$thread" waiter_agent_id "" waiter_state prepared
        dm_unlock "$meta"
        ;;
      active)
        thread="${1:-}"; agent="${2:-}"
        [ "$#" -eq 2 ] && [ -n "$thread" ] && [ -n "$agent" ] \
          || dm_die "usage: dm-task.sh waiter <id> active <thread-name> <agent-id>"
        case "$thread" in ''|*[!a-z0-9_]*) dm_die "waiter thread name must match [a-z0-9_]+" ;; esac
        [ "${#thread}" -le 64 ] || dm_die "waiter thread name must be <= 64 characters"
        dm_require_single_line "waiter agent id" "$agent"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        old_thread="$(dm_meta_get "$id" waiter_thread_name)"
        old_agent="$(dm_meta_get "$id" waiter_agent_id)"
        case "$old_state" in
          prepared)
            [ "$old_thread" = "$thread" ] && [ -z "$old_agent" ] \
              || dm_die "task '$id' prepared waiter '$old_thread'; refusing mismatched or malformed activation"
            ;;
          idle|active)
            [ "$old_thread" = "$thread" ] && [ "$old_agent" = "$agent" ] \
              || dm_die "task '$id' already records waiter '${old_agent:-missing}'; refusing ambiguous replacement"
            ;;
          *)
            dm_die "task '$id' has no prepared or reusable waiter; prepare its identity before activation"
            ;;
        esac
        dm_meta_set_fields_locked "$id" waiter_thread_name "$thread" waiter_agent_id "$agent" waiter_state active
        dm_unlock "$meta"
        ;;
      idle)
        [ "$#" -eq 0 ] || dm_die "usage: dm-task.sh waiter <id> idle"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        [ "$old_state" = "active" ] || [ "$old_state" = "idle" ] \
          || dm_die "task '$id' has no active waiter to keep idle"
        [ -n "$(dm_meta_get "$id" waiter_thread_name)" ] \
          && [ -n "$(dm_meta_get "$id" waiter_agent_id)" ] \
          || dm_die "task '$id' has no waiter identity to keep idle"
        dm_meta_set_fields_locked "$id" waiter_state idle
        dm_unlock "$meta"
        ;;
      terminal)
        [ "$#" -eq 0 ] || dm_die "usage: dm-task.sh waiter <id> terminal"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        dm_meta_set_fields_locked "$id" waiter_thread_name "" waiter_agent_id "" waiter_state terminal
        dm_unlock "$meta"
        ;;
      *) dm_die "waiter state must be prepare|active|idle|terminal" ;;
    esac
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
      # Appended only by dm-worktree.sh remove --force, so a crewmate cannot
      # flip its own live task terminal.
      discarded) dm_die "'discarded' is appended only by dm-worktree.sh remove --force (operator discard); dm-task.sh event must not forge it" ;;
      working|review-ready|ready|done|blocked|needs-decision|failed|paused) ;;
      *) dm_die "state must be working|review-ready|ready|done|blocked|needs-decision|failed|paused" ;;
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
    # `landed` distinguishes 1 (not landed) from 2 (could not determine). Collapsing
    # them would assert "committed work not yet landed" about a task whose repo did
    # not even resolve — a statement we cannot make (#119).
    has_work=0; work_unknown=0
    if [ "$kind" = "ship" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
      landed_rc=0
      "$(dirname "${BASH_SOURCE[0]}")/dm-worktree.sh" landed "$id" >/dev/null 2>&1 || landed_rc=$?
      case "$landed_rc" in
        0) : ;;
        1) has_work=1 ;;
        *) work_unknown=1 ;;
      esac
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
      # Terminal only once the worktree is gone; a lingering local copy keeps
      # the task live so archive/remove stay refused.
      discarded)
        if [ -n "$wt" ] && [ -d "$wt" ]; then
          echo "state: working · source: worktree · discard recorded but local copy still present"
        else
          echo "state: discarded · source: status-log · $last"
        fi ;;
      review-ready)           echo "state: awaiting-review · source: status-log · lavish artifact ready for the operator: $last" ;;
      ready|done)             echo "state: working · source: status-log · reported ready but not yet landed: $last" ;;
      ''|created)
        if [ "$has_work" -eq 1 ]; then echo "state: working · source: worktree · committed work not yet landed"
        elif [ "$work_unknown" -eq 1 ]; then echo "state: working · source: worktree · could not determine whether its work landed (repo unresolvable)"
        else echo "state: pending · source: status-log · not yet dispatched"; fi ;;
      *)                      echo "state: working · source: status-log · $last" ;;
    esac
    ;;

  archive)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh archive <id>"
    dm_require_id "$id"
    meta="$(dm_meta_path "$id")"
    [ -f "$meta" ] || dm_die "no such task: $id"
    dm_review_active "$id" \
      && dm_die "refusing to archive '$id': Lavish review session or notification waiter is active"
    # Fail closed: only a task that reconciles to terminal 'done' may be archived.
    # `state` derives 'done' solely from positive landing/report evidence, so a
    # ship task with unlanded work reconciles to 'working' and is refused here —
    # archival must never bury unfinished work.
    st="$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    case "$st" in
      done|discarded) ;;
      *) dm_die "refusing to archive '$id': current state is '$st', not done/discarded" ;;
    esac
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
    dm_require_complete_task_locked "$id"
    if dm_review_active "$id"; then
      dm_unlock "$meta"
      dm_die "refusing to archive '$id': Lavish review became active during archive validation"
    fi
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
    echo "usage: dm-task.sh {new|set|approve|gate|ready-gates|waiter|get|event|state|archive|list} ..." >&2; exit 2 ;;
esac

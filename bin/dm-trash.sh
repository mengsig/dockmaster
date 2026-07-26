#!/usr/bin/env bash
# dm-trash.sh - throw an in-flight task away on the operator's word, cleaning up
# the backend instead of hiding it.
#
#   dm-trash.sh <id> --reason "<why>" [--close-pr]
#
# The operator abandons a task whose intent is deprecated or whose plan was
# superseded. Two neighbouring paths already exist and neither fits: teardown
# (`dm-worktree.sh remove`) is for work that LANDED, and `dm-task.sh close` is for
# a task where nothing was ever BUILT — it refuses on any recorded local copy.
# This is the third case: built, not landed, and deliberately discarded. It is
# the PACKAGING of AGENTS.md directive 4's "--force requires explicit operator
# discard authority", never a relaxation of it: the authority is recorded before
# anything is destroyed, and the forced removal happens inside this flow so no
# caller is ever taught to reach for --force by hand.
#
# Order is chosen so no step can strand state. Everything reversible or
# recording happens first, the irreversible deletion last, and every step that
# fails stops the flow rather than continuing past it — so an interrupted trash
# always leaves a task `dm-task.sh state` still reports truthfully (live while
# its local copy is there, terminal once it is gone).
#
#   1. refuse without a reason, on an unknown id, or on an already-terminal task
#   2. refuse an unclosed PR unless --close-pr (never merges, never deletes a
#      remote branch)
#   3. snapshot branch / head / dirty summary into the task record, with who,
#      when and why
#   4. close the PR (reversible: a closed PR can be reopened)
#   5. remove the local copy under the recorded authority — dm-worktree.sh parks
#      the discarded head at refs/dm-discarded/<id>/<sha> in the clone, and this
#      flow VERIFIES that ref resolves before reporting the work recoverable
#   6. resolve the backlog row, archive the records
#
# What survives: every commit that was made (the parked ref, plus the pushed
# branch when a PR existed — it is left alone on purpose). What does NOT:
# uncommitted and untracked files. `git stash create` cannot capture untracked
# files, so a partial snapshot would advertise recoverability it does not
# deliver; instead the counts go on the record and the summary says plainly that
# they are gone.
#
# Output is one `key=value` per line on stdout so a session can relay it; the
# removal's own log and every warning go to stderr.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git; dm_need jq
dm_ensure_dirs
# The recovery-ref verification resolves the task's clone; a corrupt registry
# must stop this before anything is destroyed, not while reporting the outcome.
dm_registry_require_valid

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# The state token out of a `dm-task.sh state` line ("state: X · source: … · …").
# Never dies: callers use it to DECIDE, including after the point of no return.
reconciled_state() {
  local line token
  line="$(DM_NO_FETCH=1 "$BIN_DIR/dm-task.sh" state "$1")" || { printf 'unreadable\n'; return 0; }
  token="${line%% · *}"
  printf '%s\n' "${token#state: }"
}

# 0 = the backlog has a row for <id>, 1 = it does not, 2 = the backlog could not
# be read. The third answer is the point: a corrupt backlog must never read as
# "no such row" and let this flow report a resolved queue it never touched.
backlog_has_row() {
  local doc
  doc="$("$BIN_DIR/dm-backlog.sh" list --json)" || return 2
  printf '%s' "$doc" | jq -e --arg id "$1" 'any(.items[]; .id==$id)' >/dev/null
}

# snapshot_value <id> <meta-key> <fresh> -> what to record for one snapshot
# field. A failed forced removal can leave the worktree unreadable, so a RETRY
# reads "none"/"unknown" where the first attempt read a real value — and
# `trashed_head` is the recovery key. So a non-answer never overwrites an answer
# an earlier attempt already recorded; it only fills a field that has none.
snapshot_value() {
  local fresh="$3" prev
  case "$fresh" in
    none|unknown|undetermined) ;;
    *) printf '%s\n' "$fresh"; return 0 ;;
  esac
  prev="$(dm_meta_get "$1" "$2")"
  case "$prev" in
    ''|none|unknown|undetermined) printf '%s\n' "$fresh" ;;
    *) printf '%s\n' "$prev" ;;
  esac
}

# A step failed AFTER the local copy was deleted. The task is already terminal,
# so re-running this command is refused by design — name the two commands that
# finish the job instead of leaving the operator to guess them.
die_after_removal() {
  local id="$1" reason="$2" what="$3" detail="$4"
  [ -z "$detail" ] || what="$what
$detail"
  dm_die "$what
$id's local copy is gone and the task is recorded discarded — that part is done and reconciles correctly. Finish the bookkeeping by hand:
  dm-backlog.sh done $id --note \"trashed: $reason\"
  dm-task.sh archive $id"
}

id=""; reason=""; close_pr=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) [ "$#" -ge 2 ] || dm_die "--reason requires a value"; reason="$2"; shift 2 ;;
    --close-pr) close_pr=1; shift ;;
    -*) dm_die "unknown flag: $1 (usage: dm-trash.sh <id> --reason \"<why>\" [--close-pr])" ;;
    *) [ -z "$id" ] || dm_die "unexpected extra argument: $1"; id="$1"; shift ;;
  esac
done
[ -n "$id" ] || dm_die "usage: dm-trash.sh <id> --reason \"<why this work is being discarded>\" [--close-pr]"
dm_require_id "$id"
# The reason is the authority's content, not decoration: it is the only thing on
# the record that says why work nobody landed was allowed to be destroyed.
[ -n "$reason" ] || dm_die "--reason is required: trashing destroys work nobody landed, so the record must say why the operator discarded it"
dm_require_single_line "trash reason" "$reason"

meta_file="$(dm_meta_path "$id")"
[ -f "$meta_file" ] || dm_die "no such task: $id (check the id with dm-task.sh list; an archived task is already gone)"
repo="$(dm_meta_get "$id" repo)"
[ -n "$repo" ] || dm_die "task '$id' records no repo, so neither its clone nor its recovery ref can be resolved; the record is incomplete — inspect $meta_file"

# Reconciled, PR state refreshed live (dm-task.sh state refreshes an unmerged PR
# from GitHub), so the guards below judge what is true now rather than what was
# last written down.
state_line="$("$BIN_DIR/dm-task.sh" state "$id")"
state="${state_line%% · *}"; state="${state#state: }"
case "$state" in
  done|discarded)
    dm_die "REFUSED: '$id' is already terminal ('$state'), so there is nothing in flight to discard. A landed task is teardown + archive (dm-worktree.sh remove / dm-task.sh archive); undoing work that landed is a revert (rollback skill)." ;;
esac

# --- the open-PR guard -------------------------------------------------------
# Fail closed: only a PR provably CLOSED needs no --close-pr. Anything else —
# OPEN, or a state we could not refresh — is treated as open, because leaving an
# open PR behind a discarded task invites someone to merge abandoned work.
pr="$(dm_meta_get "$id" pr)"
pr_action=none
if [ -n "$pr" ]; then
  pr_state="$(dm_meta_get "$id" pr_state)"
  case "$pr_state" in
    # A belt: `dm-task.sh state` already reads a merged PR as terminal-done, so
    # the guard above normally fires first. Kept so the refusal stays correct if
    # that reconcile rule ever changes.
    MERGED)
      dm_die "REFUSED: $id's PR is MERGED ($pr) — its work LANDED. Trash discards unlanded work; undoing a landed change is a revert (rollback skill)." ;;
    CLOSED) pr_action=already-closed ;;
    *)
      [ "$close_pr" -eq 1 ] \
        || dm_die "REFUSED: $id has a PR that is not closed ($pr, state '${pr_state:-unknown}'). Trashing it would leave an open PR inviting a merge of discarded work. Re-run with --close-pr to close it unmerged with the reason on it, or close it on GitHub first."
      pr_action=close ;;
  esac
fi

# --- the running worker ------------------------------------------------------
# This script cannot stop an agent — only the session that spawned it can — so
# it says so loudly and continues. `failed` is the one state where the worker
# itself reported that it stopped; every other state may still have a live agent
# writing into the directory about to be deleted.
agent="$(dm_meta_get "$id" agent_id)"
if [ -n "$agent" ] && [ "$state" != failed ]; then
  dm_warn "STOP THE WORKER FIRST: $id records worker $agent and reconciles to '$state'. This command cannot stop an agent; the session that spawned it must. A worker still running will keep writing into the local copy this is about to delete."
fi

# --- snapshot what is about to be destroyed ----------------------------------
# The clone, resolved TOLERANTLY and once: it is where a discarded head is
# parked, so both the snapshot and the recovery check below need it — but an
# unresolvable repo must not stop a trash (dm-worktree.sh remove --force can
# still clean up, and pinning the task instead is the #119 mistake).
clone_dir=""; clone_rc=0
clone_out="$(dm_repo_dir_or_none "$repo" 2>&1)" || clone_rc=$?
if [ "$clone_rc" -eq 0 ] && [ -d "$clone_out/.git" ]; then clone_dir="$clone_out"; fi

wt="$(dm_meta_get "$id" worktree)"
branch=none; head=none; tracked=none; untracked_count=none; landed=no-local-copy
if [ -n "$wt" ] && [ -d "$wt" ]; then
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  branch="$(dm_first_line "$branch")"
  [ -n "$branch" ] || branch=unknown
  # A crew worktree starts detached; "HEAD" is git's name for that, not a branch.
  [ "$branch" != HEAD ] || branch=detached
  head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  [ -n "$head" ] || head=none
  if ! tracked="$(dm_tracked_state "$wt")"; then
    dm_warn "cannot tell whether $id has uncommitted changes ($(dm_first_line "$tracked")); the summary reports it as undetermined"
    tracked=undetermined
  fi
  untracked_out=""
  if untracked_out="$(dm_untracked "$wt")"; then
    untracked_count="$(printf '%s\n' "$untracked_out" | grep -c . || true)"
  else
    untracked_count=undetermined
    dm_warn "cannot inspect $id's untracked files ($(dm_first_line "$untracked_out")); the summary cannot say how many are being discarded"
  fi
  # Whether the commits are already in the base decides what "recoverable" means
  # below: work that landed needs no parked ref, work that did not must have one.
  landed_json=""; landed_rc=0
  landed_json="$("$BIN_DIR/dm-worktree.sh" landed "$id" --json 2>/dev/null)" || landed_rc=$?
  landed=undetermined
  if [ "$landed_rc" -ne 0 ]; then
    # --json answers `undetermined` for every question it CAN answer, so a
    # nonzero here is the command itself failing. Say so; do not read the
    # silence as "not landed".
    dm_warn "could not ask whether $id's work landed; the summary reports it as undetermined"
  elif [ -n "$landed_json" ]; then
    landed="$(printf '%s' "$landed_json" | jq -r '.state // "undetermined"')"
  fi
elif [ -n "$wt" ]; then
  # Recorded but already absent: the interrupted-cleanup shape. The directory is
  # gone, but git's admin record still names its head — and the removal parks
  # that head, so reading it here is what lets the summary report the work as
  # recoverable instead of silently under-claiming. Same lookup ORDER as
  # dm-worktree.sh's own: the derived managed path first (canonical by
  # construction), the stored path only as a fallback (a record written before
  # DM_HOME was canonicalized holds a symlinked path git never string-matches).
  branch=unknown; landed=undetermined
  if [ -n "$clone_dir" ]; then
    head="$(dm_admin_worktree_head "$clone_dir" "$DM_WT/$id")"
    [ -n "$head" ] || head="$(dm_admin_worktree_head "$clone_dir" "$wt")"
    [ -n "$head" ] || head=none
  fi
fi

# --- record the authority BEFORE destroying anything -------------------------
# Every field is new; nothing existing is renamed or overwritten. They travel
# with the records into state/archive/, so the snapshot outlives the task.
# `trashed_by` is the account that RAN the command — the operator's word is
# relayed by the session and cannot be verified here, so the field claims only
# what it knows.
trashed_by="$(id -un 2>/dev/null || true)"
[ -n "$trashed_by" ] || trashed_by="${USER:-unknown}"
branch="$(snapshot_value "$id" trashed_branch "$branch")"
head="$(snapshot_value "$id" trashed_head "$head")"
tracked="$(snapshot_value "$id" trashed_tracked "$tracked")"
untracked_count="$(snapshot_value "$id" trashed_untracked "$untracked_count")"
landed="$(snapshot_value "$id" trashed_landed "$landed")"
dm_meta_set "$id" trashed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
dm_meta_set "$id" trashed_by "$trashed_by"
dm_meta_set "$id" trashed_reason "$reason"
dm_meta_set "$id" trashed_branch "$branch"
dm_meta_set "$id" trashed_head "$head"
dm_meta_set "$id" trashed_tracked "$tracked"
dm_meta_set "$id" trashed_untracked "$untracked_count"
dm_meta_set "$id" trashed_landed "$landed"
# A non-terminal verb, appended before the destruction. `dm-task.sh state` reads
# an unknown verb through its fallback as `working`, which is exactly right if
# this flow dies next: the local copy is still there and its work still has not
# landed. The terminal `discarded` line comes after, from the removal itself.
dm_status_append "$id" trashed "operator discard authority, by $trashed_by: $reason"

# --- close the PR: reversible, so it goes before the deletion ----------------
if [ "$pr_action" = close ]; then
  "$BIN_DIR/dm-pr.sh" close "$id" --reason "trashed: $reason" \
    || dm_die "REFUSED: could not close $id's PR ($pr). Nothing has been deleted and the task is still live. Close it (or fix the cause above) and re-run: dm-trash.sh $id --reason \"$reason\""
  pr_action=closed
fi

# --- remove the local copy under the recorded authority ----------------------
worktree_result=absent
if [ -n "$wt" ]; then
  remove_out=""
  remove_out="$("$BIN_DIR/dm-worktree.sh" remove "$id" --force 2>&1)" \
    || dm_die "REFUSED: could not remove $id's local copy at $wt under discard authority; nothing was deleted.
${remove_out:-No detail from the removal.}
The task is still live and reconciles as such; the trash intent is on its record. Fix the cause above, then re-run: dm-trash.sh $id --reason \"$reason\""
  # The removal's own log and warnings ("head could NOT be preserved") are the
  # evidence for the recovery claim below — never swallowed.
  [ -z "$remove_out" ] || printf '%s\n' "$remove_out" >&2
  worktree_result=removed
fi

# --- verify the recovery claim instead of asserting it -----------------------
# dm-worktree.sh parks the discarded head, warning rather than failing when it
# cannot. So the ref is CHECKED here: this flow tells the operator work survived
# only when the object is actually reachable by name.
recoverable=nothing-committed; recover_cmd=""
if [ "$landed" = landed ]; then
  recoverable=already-in-base
elif [ "$head" != none ]; then
  recoverable=NOT-PRESERVED
  if [ -n "$clone_dir" ]; then
    recover_ref="$(dm_discard_ref "$id" "$head")"
    parked="$(git -C "$clone_dir" rev-parse --verify --quiet "$recover_ref" 2>/dev/null || true)"
    if [ "$parked" = "$head" ]; then
      recoverable="$recover_ref"
      recover_cmd="git -C $clone_dir branch recovered-$id $head"
    fi
  fi
  if [ "$recoverable" = NOT-PRESERVED ]; then
    # The object itself almost certainly still exists — parking is what failed —
    # so name the one command that saves it while that is still true.
    if [ -n "$clone_dir" ]; then
      dm_warn "$id's discarded head $head is NOT on a recovery ref. The commit is still in the clone until it is garbage-collected — preserve it NOW with: git -C $clone_dir branch recovered-$id $head"
    else
      dm_warn "$id's discarded head $head is NOT on a recovery ref, and repo '$repo' does not resolve to a clone to look for it in; the commit may already be unreachable"
    fi
  fi
fi

# Uncommitted and untracked files are the one thing this flow never keeps, so the
# summary must not imply loss where there was nothing to lose — nor hide it where
# there was. DISCARDED means gone for good; undetermined means git could not be
# read and something MAY have been lost with it.
case "$tracked/$untracked_count" in
  undetermined/*|*/undetermined) uncommitted=undetermined ;;
  clean/0|none/none)             uncommitted=none ;;
  *)                             uncommitted=DISCARDED ;;
esac

# --- the task must end terminal ----------------------------------------------
# The forced removal appends `discarded` on every path it takes from here, so
# this is a belt, not the mechanism: if it somehow did not, reach the same
# terminal state through the other sanctioned writer rather than leaving a task
# that reads live with no local copy behind it.
state="$(reconciled_state "$id")"
case "$state" in
  done|discarded) : ;;
  *)
    "$BIN_DIR/dm-task.sh" close "$id" --reason "trashed: $reason" >/dev/null \
      || die_after_removal "$id" "$reason" "REFUSED: $id's local copy is gone but the task did not reach a terminal state ('$state') and could not be closed." ""
    state="$(reconciled_state "$id")" ;;
esac
case "$state" in
  done|discarded) : ;;
  *) die_after_removal "$id" "$reason" "REFUSED: $id still reconciles to '$state' after its local copy was removed; the records are NOT archived because archiving a live-looking task would bury it." "" ;;
esac

# --- bookkeeping -------------------------------------------------------------
backlog_result=no-row
row_rc=0
backlog_has_row "$id" || row_rc=$?
case "$row_rc" in
  0)
    "$BIN_DIR/dm-backlog.sh" done "$id" --note "trashed: $reason" >/dev/null \
      || die_after_removal "$id" "$reason" "REFUSED: could not resolve $id's backlog row." ""
    backlog_result=resolved ;;
  1) : ;;
  *) die_after_removal "$id" "$reason" "REFUSED: the backlog could not be read, so $id's row was not resolved and its records were not archived." "" ;;
esac

archive_out=""
archive_out="$("$BIN_DIR/dm-task.sh" archive "$id" 2>&1)" \
  || die_after_removal "$id" "$reason" "REFUSED: could not archive $id's records." "$archive_out"

printf 'task=%s\n' "$id"
printf 'repo=%s\n' "$repo"
printf 'state=%s\n' "$state"
printf 'reason=%s\n' "$reason"
printf 'authority=operator-discard by %s\n' "$trashed_by"
printf 'local_copy=%s\n' "$worktree_result"
printf 'pr=%s\n' "$pr_action"
printf 'branch=%s\n' "$branch"
printf 'head=%s\n' "$head"
printf 'committed_work=%s\n' "$recoverable"
[ -z "$recover_cmd" ] || printf 'recover_cmd=%s\n' "$recover_cmd"
printf 'uncommitted_tracked=%s\n' "$tracked"
printf 'untracked_paths=%s\n' "$untracked_count"
printf 'uncommitted=%s\n' "$uncommitted"
printf 'backlog=%s\n' "$backlog_result"
printf 'records=archived\n'

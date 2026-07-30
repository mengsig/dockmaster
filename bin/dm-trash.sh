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
#   2. refuse a PR not CONFIRMED closed against GitHub unless --close-pr (never
#      merges, never deletes a remote branch)
#   3. snapshot branch / head / dirty summary into the task record, with who,
#      when and why
#   4. close the PR (reversible: a closed PR can be reopened)
#   5. remove the local copy under the recorded authority — dm-worktree.sh parks
#      the discarded head at refs/dm-discarded/<id>/<sha> in the clone, where
#      <id> is the SANITIZED id component (dm_ref_component: an id may legally
#      hold characters git refuses in a ref name)
#   6. read the recovery verdict out of that ref NAMESPACE, never out of the
#      pre-removal snapshot: the namespace is what a recovery would actually use
#   7. resolve the backlog row, resolve the task's OPEN decision holds (a hold
#      that fails to resolve WARNS and continues rather than stopping here —
#      the destructive part already happened, and a silent half-done cleanup
#      is worse than a loud one), archive the records
#
# A task already recorded discarded BY THIS FLOW (it is the only writer of
# `trashed_reason`) is RESUMABLE: a re-run skips every destructive step and
# finishes only the bookkeeping tail, because a crash between the discard and the
# archive would otherwise leave a task no command would touch again.
#
# What survives: every commit that was made (the parked ref, plus the pushed
# branch when a PR existed — it is left alone on purpose). What does NOT:
# uncommitted and untracked files. `git stash create` cannot capture untracked
# files, so a partial snapshot would advertise recoverability it does not
# deliver; instead the counts go on the record and the summary says plainly that
# they are gone. An unreadable HEAD is never reported as "nothing committed" —
# it is UNDETERMINED, and every recovery claim is verified before it is printed.
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

# admin_head <clone-dir> <id> <recorded-path> -> the head git's admin record still
# holds for this task's worktree, or empty. Derived managed path first (canonical
# by construction), the stored path only as a fallback — a record written before
# DM_HOME was canonicalized holds a symlinked path git never string-matches.
# Porcelain reports an unborn or corrupt HEAD as all-zeros, which names no commit;
# park_discarded_head filters exactly that, and this second copy of the lookup
# must not diverge from it.
admin_head() {
  local h
  h="$(dm_admin_worktree_head "$1" "$DM_WT/$2")"
  [ -n "$h" ] || h="$(dm_admin_worktree_head "$1" "$3")"
  case "$h" in
    ''|*[!0]*) printf '%s' "$h" ;;
    *) dm_warn "git reports an unborn or unresolvable HEAD ($h) for $2's local copy; there is no commit behind it" ;;
  esac
}

# parked_refs <clone-dir> <id> -> "<sha> <refname>", one line per recovery ref
# this id has in the clone. The ref NAMESPACE is the ground truth for the
# recovery verdict, not the pre-removal snapshot: a worker can commit in the
# window between them, landedness can flip, and git's admin record may already
# have been pruned — and the namespace is what a recovery would actually use.
# The bare parent path matches every ref beneath it (a git prefix match), so a
# legacy FLAT ref sitting at that path is reported too.
parked_refs() {
  git -C "$1" for-each-ref --format='%(objectname) %(refname)' "$(dm_discard_ref "$2")" 2>/dev/null || true
}

# snapshot_value <id> <meta-key> <fresh> -> what to record for one snapshot
# field. A failed forced removal can leave the worktree unreadable, so a RETRY
# reads a non-answer where the first attempt read a real value — and
# `trashed_head` is the recovery key. So a recorded answer always wins over a
# fresh non-answer, and one non-answer never replaces another (a recorded
# `undetermined` must not decay into `none`, which the summary reads as a
# definite "there was nothing").
snapshot_value() {
  local fresh="$3" prev
  case "$fresh" in
    none|unknown|undetermined|no-local-copy) ;;
    *) printf '%s\n' "$fresh"; return 0 ;;
  esac
  prev="$(dm_meta_get "$1" "$2")"
  if [ -n "$prev" ]; then printf '%s\n' "$prev"; else printf '%s\n' "$fresh"; fi
}

# A step failed AFTER the local copy was deleted. The task is terminal, so the
# tail is what is left — name it. A re-run also finishes it (this flow resumes
# its own discard), so both routes are given.
die_after_removal() {
  local id="$1" reason="$2" what="$3" detail="$4"
  [ -z "$detail" ] || what="$what
$detail"
  dm_die "$what
$id's local copy is gone and the task is recorded discarded — that part is done and reconciles correctly. Finish the bookkeeping by re-running this command, or by hand:
  dm-backlog.sh done $id --note $(dm_squote "trashed: $reason")
  dm-task.sh archive $id"
}

# resolve_decision_holds <id> <reason> -> one "resolved:<key>" or
# "unresolved:<key>" line per line on stdout (the caller turns each into the
# matching key=value record; this function's own stdout is captured whole by
# the caller, so it cannot emit key=value records directly).
#
# A hold belongs to this id if its key is <id>-decision-* (decision-hold
# skill's convention) or its recorded origin references data/<id>/ (the
# report-path convention) — both exist in the backlog today. This is
# DELIBERATELY stricter than a bare substring match: it does not catch a hold
# filed without --origin and not key-prefixed with this id, and that gap is
# not closed here (widening the matcher risks resolving someone else's hold on
# a coincidental substring, which is worse than leaving an unrelated one open).
# Filtering on status=="open" is what makes a resumed trash idempotent: a hold
# this flow already resolved on an earlier run no longer matches, so it is
# silently skipped rather than re-resolved or reported twice.
# A hold that fails to resolve must not abort bookkeeping that already
# committed the destructive part — warn loudly and keep going.
resolve_decision_holds() {
  local id="$1" reason="$2" holds_json rc=0 keys hkey errf err resolve_out resolve_rc
  # stderr captured separately from stdout: stdout must stay pure JSON for the
  # jq read below, so a diagnostic cannot be merged onto it the way archive_out
  # merges 2>&1 elsewhere in this file (nothing here re-parses archive_out).
  errf="$(mktemp "${TMPDIR:-/tmp}/dm-trash-decisions.XXXXXX")" \
    || { dm_warn "could not read $id's decision holds (mktemp failed); none were resolved as part of this trash"; return 0; }
  holds_json="$("$BIN_DIR/dm-backlog.sh" decisions --json 2>"$errf")" || rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"; rm -f "$errf"
  if [ "$rc" -ne 0 ]; then
    dm_warn "could not read $id's decision holds; none were resolved as part of this trash ($(dm_first_line "${err:-no detail}"))"
    return 0
  fi
  keys="$(printf '%s' "$holds_json" | jq -r --arg pfx "$id-decision-" --arg path "data/$id/" '
    .[] | select(.status=="open") |
    select((.key|contains("\n"))|not) |
    select((.key|startswith($pfx)) or ((.origin//"")|contains($path))) |
    .key')" \
    || { dm_warn "could not parse $id's decision holds; none were resolved as part of this trash"; return 0; }
  if [ -n "$keys" ]; then
    while IFS= read -r hkey; do
      [ -n "$hkey" ] || continue
      resolve_out=""; resolve_rc=0
      resolve_out="$("$BIN_DIR/dm-backlog.sh" resolve "$hkey" "trashed: $reason" 2>&1)" || resolve_rc=$?
      if [ "$resolve_rc" -eq 0 ]; then
        printf 'resolved:%s\n' "$hkey"
      else
        printf 'unresolved:%s\n' "$hkey"
        dm_warn "could not resolve $id's decision hold '$hkey'; it is still open and must be closed by hand: dm-backlog.sh resolve $hkey $(dm_squote "trashed: $reason") ($(dm_first_line "${resolve_out:-no detail}"))"
      fi
    done <<EOF
$keys
EOF
  fi
  return 0
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

# --- terminal, resumable, or live? -------------------------------------------
# `trashed_reason` is written by nothing else, so a discarded task carrying one is
# THIS flow's own unfinished work: a crash (or a kill) between the discard and the
# archive must not leave a task that every command refuses. Resuming runs only the
# bookkeeping tail — it can no longer destroy anything, because there is nothing
# left to destroy, so it also needs no GitHub round-trip.
pr="$(dm_meta_get "$id" pr)"
recorded_reason="$(dm_meta_get "$id" trashed_reason)"
state="$(reconciled_state "$id")"
resume=0
if [ "$state" = discarded ] && [ -n "$recorded_reason" ]; then resume=1; fi

# The PR refresh happens HERE, and whether it SUCCEEDED is remembered: the guards
# below may only trust a recorded CLOSED if GitHub confirmed it in this run. State
# is then re-read offline, because the refresh itself can reveal a merge that
# makes the task terminal.
pr_confirmed=0
if [ "$resume" -eq 0 ] && dm_should_refresh_pr_state "$id"; then
  if "$BIN_DIR/dm-pr.sh" check "$id" >/dev/null 2>&1; then pr_confirmed=1; fi
  state="$(reconciled_state "$id")"
fi

case "$state" in
  discarded)
    [ "$resume" -eq 1 ] \
      || dm_die "REFUSED: '$id' is already terminal ('$state') and was not discarded by this flow, so there is nothing here to finish. Its records are archived with dm-task.sh archive $id."
    if [ "$reason" != "$recorded_reason" ]; then
      dm_warn "$id was already discarded on the recorded authority ($recorded_reason); finishing THAT trash rather than re-recording a new reason"
    fi
    reason="$recorded_reason" ;;
  done)
    dm_die "REFUSED: '$id' is already terminal ('$state') — its work LANDED. Teardown + archive end a landed task (dm-worktree.sh remove / dm-task.sh archive); undoing work that landed is a revert (rollback skill)." ;;
esac

# --- the running worker ------------------------------------------------------
# This script cannot stop an agent — only the session that spawned it can — so it
# says so loudly, on stderr AND in the summary, and continues. A settled state is
# the only one where the worker is known not to be writing any more.
agent="$(dm_meta_get "$id" agent_id)"
worker=none
case "$state" in
  failed|discarded|done) ;;
  *) [ -z "$agent" ] || worker=RUNNING ;;
esac
if [ "$worker" = RUNNING ]; then
  dm_warn "STOP THE WORKER FIRST: $id records worker $agent and reconciles to '$state'. This command cannot stop an agent; the session that spawned it must. A worker still running will keep writing into the local copy this is about to delete."
fi

# The clone, resolved TOLERANTLY and once: it holds the recovery refs, so both
# the snapshot and the verdict need it — but an unresolvable repo must not stop a
# trash (dm-worktree.sh remove --force can still clean up, and pinning the task
# instead is the #119 mistake).
clone_dir=""; clone_rc=0
clone_out="$(dm_repo_dir_or_none "$repo" 2>&1)" || clone_rc=$?
if [ "$clone_rc" -eq 0 ] && [ -d "$clone_out/.git" ]; then clone_dir="$clone_out"; fi

wt="$(dm_meta_get "$id" worktree)"
branch=none; head=none; tracked=none; untracked_count=none; landed=no-local-copy
pr_action=none
worktree_result=absent
trashed_by=""

if [ "$resume" -eq 1 ]; then
  # Nothing to destroy and nothing to re-record: report what the record already
  # says, then fall through to the tail.
  branch="$(dm_meta_get "$id" trashed_branch)"; [ -n "$branch" ] || branch=unknown
  head="$(dm_meta_get "$id" trashed_head)"; [ -n "$head" ] || head=none
  tracked="$(dm_meta_get "$id" trashed_tracked)"; [ -n "$tracked" ] || tracked=undetermined
  untracked_count="$(dm_meta_get "$id" trashed_untracked)"; [ -n "$untracked_count" ] || untracked_count=undetermined
  landed="$(dm_meta_get "$id" trashed_landed)"; [ -n "$landed" ] || landed=undetermined
  trashed_by="$(dm_meta_get "$id" trashed_by)"; [ -n "$trashed_by" ] || trashed_by=unknown
  # `worktree` was cleared by the removal, so this recorded fact is what says
  # whether there ever was a local copy. A record from before this field existed
  # falls back to the branch name, which is `none` only for a task that had none.
  had_worktree="$(dm_meta_get "$id" trashed_had_worktree)"
  if [ -z "$had_worktree" ]; then
    if [ "$branch" = none ]; then had_worktree=0; else had_worktree=1; fi
  fi
  [ "$had_worktree" -eq 0 ] || worktree_result=removed-earlier
  # One live re-check before reporting. Between the discard and this resume the PR
  # can have been reopened or even merged, and archiving the task as
  # `already-closed` on a stale record would file a state that is no longer true.
  # This never CLOSES anything: the authority to do that belonged to the run that
  # discarded the work, so a PR found open is reported, loudly, with the command
  # that closes it.
  if [ -n "$pr" ]; then
    pr_live=0
    if dm_should_refresh_pr_state "$id"; then
      if "$BIN_DIR/dm-pr.sh" check "$id" >/dev/null 2>&1; then pr_live=1; fi
    fi
    case "$(dm_meta_get "$id" pr_state)" in
      MERGED)
        pr_action=MERGED
        dm_warn "$id's PR ($pr) is MERGED — its work landed AFTER the discard was recorded. This resume only finishes the bookkeeping; if the landed change must go, that is a revert (rollback skill)." ;;
      CLOSED)
        if [ "$pr_live" -eq 1 ]; then pr_action=already-closed; else pr_action=closed-unconfirmed; fi ;;
      *)
        pr_action=STILL-OPEN
        dm_warn "$id was discarded but its PR ($pr) is not closed, so abandoned work is still open for merge. This resume does not close PRs — close it with: dm-pr.sh close $id --reason $(dm_squote "trashed: $reason")" ;;
    esac
  fi
  printf 'resuming %s: its local copy is already gone, only the backlog row and the records are left\n' "$id" >&2
else
  # --- the open-PR guard ------------------------------------------------------
  # Fail closed. A recorded CLOSED counts only if the refresh above CONFIRMED it
  # against GitHub in this run: the refresh is best-effort, so a PR reopened
  # since the last check would otherwise be trusted as closed and left open
  # behind a discarded task, inviting a merge of abandoned work.
  if [ -n "$pr" ]; then
    pr_state="$(dm_meta_get "$id" pr_state)"
    case "$pr_state" in
      # Refused whether or not the refresh confirmed it: a cached MERGED is
      # already enough to stop. `dm-task.sh state` normally catches it first.
      MERGED)
        dm_die "REFUSED: $id's PR is MERGED ($pr) — its work LANDED. Trash discards unlanded work; undoing a landed change is a revert (rollback skill)." ;;
      CLOSED)
        if [ "$pr_confirmed" -eq 1 ]; then
          pr_action=already-closed
        else
          [ "$close_pr" -eq 1 ] \
            || dm_die "REFUSED: $id records its PR as CLOSED ($pr) but that could not be confirmed against GitHub just now, so it may have been reopened. Re-run with --close-pr (a PR already closed is left alone), or confirm it on GitHub first."
          pr_action=close
        fi ;;
      *)
        [ "$close_pr" -eq 1 ] \
          || dm_die "REFUSED: $id has a PR that is not closed ($pr, state '${pr_state:-unknown}'). Trashing it would leave an open PR inviting a merge of discarded work. Re-run with --close-pr to close it unmerged with the reason on it, or close it on GitHub first."
        pr_action=close ;;
    esac
  elif [ "$close_pr" -eq 1 ]; then
    printf 'note: --close-pr had nothing to do — %s records no PR\n' "$id" >&2
  fi

  # --- snapshot what is about to be destroyed --------------------------------
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    # `-d "$wt"` proves the DIRECTORY survived, never that its `.git` record
    # is still intact — a partially-failed removal leaves exactly that shape
    # (#210/#181). A broken record makes `git -C "$wt"` walk UP into whatever
    # enclosing repo it finds and answer with ITS branch/head, plausible and
    # wrong, as this task's own. Prove containment first; a failure is treated
    # the same as an unreadable branch/head, never trusted from the wrong repo.
    if dm_worktree_contained "$wt" >/dev/null 2>&1; then
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      branch="$(dm_first_line "$branch")"
      [ -n "$branch" ] || branch=unknown
      # A crew worktree starts detached; "HEAD" is git's name for that, not a branch.
      [ "$branch" != HEAD ] || branch=detached
      head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
    else
      branch=unknown; head=""
      dm_warn "$id's local copy at $wt is broken (missing or invalid git record); refusing to read its branch/head — it would answer from the wrong repository"
    fi
    # An unreadable in-worktree HEAD (deleted or corrupt `.git` file) is NOT "no
    # commit": the clone's admin record still names the head and the object is
    # still there. dm-worktree.sh parks from the same fallback.
    if [ -z "$head" ] && [ -n "$clone_dir" ]; then
      head="$(admin_head "$clone_dir" "$id" "$wt")"
      [ -z "$head" ] \
        || dm_warn "cannot read HEAD inside $id's local copy; using the head git's own admin record still holds ($head)"
    fi
    [ -n "$head" ] || head=none
    # Whether the commits are already in the base decides what "recoverable"
    # means below: work that landed needs no parked ref.
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
    # recoverable instead of silently under-claiming.
    #
    # Nothing about the TREE can be read, though. Leaving the dirty counters at
    # their `none` initializers would print a definite "nothing uncommitted was
    # lost" about a directory this run never saw — the exact all-clear the
    # undetermined value exists for.
    branch=unknown; landed=undetermined
    tracked=undetermined; untracked_count=undetermined
    if [ -n "$clone_dir" ]; then
      head="$(admin_head "$clone_dir" "$id" "$wt")"
      [ -n "$head" ] || head=none
    fi
  fi

  # --- record the authority BEFORE destroying anything -----------------------
  # Every field is new; nothing existing is renamed or overwritten. They travel
  # with the records into state/archive/, so the snapshot outlives the task.
  # `trashed_by` is the account that RAN the command — the operator's word is
  # relayed by the session and cannot be verified here, so the field claims only
  # what it knows.
  trashed_by="$(id -un 2>/dev/null || true)"
  [ -n "$trashed_by" ] || trashed_by="${USER:-unknown}"
  branch="$(snapshot_value "$id" trashed_branch "$branch")"
  head="$(snapshot_value "$id" trashed_head "$head")"
  landed="$(snapshot_value "$id" trashed_landed "$landed")"
  dm_meta_set "$id" trashed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dm_meta_set "$id" trashed_by "$trashed_by"
  dm_meta_set "$id" trashed_reason "$reason"
  dm_meta_set "$id" trashed_branch "$branch"
  dm_meta_set "$id" trashed_head "$head"
  dm_meta_set "$id" trashed_landed "$landed"
  # Recorded as a FACT rather than inferred later from the branch name: the
  # removal clears `worktree`, so after it there is nothing else left that
  # distinguishes "its local copy was removed" from "it never had one" — and
  # that distinction decides whether an empty recovery namespace is an all-clear.
  if [ -n "$wt" ]; then had_worktree=1; else had_worktree=0; fi
  dm_meta_set "$id" trashed_had_worktree "$had_worktree"
  # A non-terminal verb, appended before the destruction. `dm-task.sh state` reads
  # an unknown verb through its fallback as `working`, which is exactly right if
  # this flow dies next: the local copy is still there and its work still has not
  # landed. The terminal `discarded` line comes after, from the removal itself.
  dm_status_append "$id" trashed "operator discard authority, by $trashed_by: $reason"

  # --- close the PR: reversible, so it goes before the deletion --------------
  if [ "$pr_action" = close ]; then
    "$BIN_DIR/dm-pr.sh" close "$id" --reason "trashed: $reason" \
      || dm_die "REFUSED: could not close $id's PR ($pr). Nothing has been deleted and the task is still live. Close it (or fix the cause above) and re-run: dm-trash.sh $id --reason $(dm_squote "$reason")"
    pr_action=closed
  fi

  # --- the dirty summary, read as late as possible ---------------------------
  # Immediately before the removal, not back at the snapshot: the PR close is a
  # GitHub round-trip, and a count read before it would describe a tree that had
  # time to change. Still recorded BEFORE anything is destroyed.
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    # Re-checked here, not reused from the snapshot: the worktree could have
    # been broken between the two reads, and `dm_tracked_state`/`dm_untracked`
    # would otherwise silently answer clean/empty from an enclosing repo.
    if dm_worktree_contained "$wt" >/dev/null 2>&1; then
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
    else
      tracked=undetermined; untracked_count=undetermined
      dm_warn "$id's local copy at $wt is broken (missing or invalid git record); cannot tell whether it has uncommitted or untracked changes"
    fi
  fi
  tracked="$(snapshot_value "$id" trashed_tracked "$tracked")"
  untracked_count="$(snapshot_value "$id" trashed_untracked "$untracked_count")"
  dm_meta_set "$id" trashed_tracked "$tracked"
  dm_meta_set "$id" trashed_untracked "$untracked_count"

  # --- remove the local copy under the recorded authority --------------------
  if [ -n "$wt" ]; then
    remove_out=""; remove_rc=0
    remove_out="$("$BIN_DIR/dm-worktree.sh" remove "$id" --force 2>&1)" || remove_rc=$?
    if [ "$remove_rc" -ne 0 ]; then
      # Do not ASSERT that nothing was deleted — look. A removal can fail after
      # the directory is already gone, and claiming otherwise sends the operator
      # looking for work that is not there.
      if [ -d "$wt" ]; then left="the local copy is still at $wt"
      else left="the local copy at $wt is ALREADY GONE — inspect the record and the parked refs before retrying"; fi
      dm_die "REFUSED: could not remove $id's local copy under discard authority; $left.
${remove_out:-No detail from the removal.}
The task still reconciles as live and the trash intent is on its record. Fix the cause above, then re-run: dm-trash.sh $id --reason $(dm_squote "$reason")"
    fi
    # The removal's own log and warnings ("head could NOT be preserved") are the
    # evidence for the verdict below — never swallowed.
    [ -z "$remove_out" ] || printf '%s\n' "$remove_out" >&2
    worktree_result=removed
  fi
fi

# --- the recovery verdict, read out of the ref namespace ---------------------
# dm-worktree.sh parks the discarded head, WARNING rather than failing when it
# cannot, so what actually exists is the only trustworthy source. Every ref found
# is reported, whatever the verdict.
parked_list=""
[ -z "$clone_dir" ] || parked_list="$(parked_refs "$clone_dir" "$id")"
parked_count=0
[ -z "$parked_list" ] || parked_count="$(printf '%s\n' "$parked_list" | grep -c .)"
head_ref=""
if [ "$head" != none ] && [ -n "$parked_list" ]; then
  head_ref="$(printf '%s\n' "$parked_list" | awk -v h="$head" '$1 == h && !f { print $2; f = 1 }')"
fi

# A ref under this id's namespace is only THIS task's work if a head ties it
# there. Task ids are REUSABLE and refs/dm-discarded/* is keyed by sha precisely
# so an earlier discard survives the reuse — so with no head to match against,
# an inherited ref says nothing about this run, and naming it would resurrect
# someone else's commit while the one actually at risk goes unmentioned.
recoverable=""; recover_cmd=""
if [ -n "$head_ref" ]; then
  recoverable="$head_ref"
  recover_cmd="git -C $(dm_squote "$clone_dir") branch recovered-$(dm_ref_component "$id") $head"
elif [ "$landed" = landed ]; then
  recoverable=already-in-base
elif [ "$head" != none ] && [ "$parked_count" -eq 1 ]; then
  # A ref exists but not for the head we snapshotted: the admin record was
  # already pruned, or the removal parked a commit made after the snapshot.
  # Report the ref that EXISTS, and say it is not the head we recorded.
  parked_sha="${parked_list%% *}"
  recoverable="${parked_list#* }"
  recover_cmd="git -C $(dm_squote "$clone_dir") branch recovered-$(dm_ref_component "$id") $parked_sha"
  dm_warn "$id's recovery ref holds $parked_sha, not the head this run recorded ($head); the work was preserved, but as a different commit"
elif [ "$head" != none ] && [ "$parked_count" -gt 1 ]; then
  recoverable=parked-refs
  dm_warn "$id has $parked_count recovery refs and none matches the head this run recorded ($head); ids are reusable, so inspect the parked_ref lines before recovering"
elif [ "$had_worktree" -eq 0 ]; then
  recoverable=nothing-committed
elif [ -z "$clone_dir" ]; then
  recoverable=UNDETERMINED
  dm_warn "cannot say whether $id's work survived: repo '$repo' does not resolve to a clone, so its recovery refs cannot be read"
elif [ "$head" != none ]; then
  recoverable=NOT-PRESERVED
  # The object itself almost certainly still exists — parking is what failed — so
  # name the one command that saves it while that is still true. The branch name
  # is SANITIZED: a task id may legally contain characters git refuses in a ref,
  # and this instruction is sometimes the operator's only route back.
  dm_warn "$id's discarded head $head is NOT on a recovery ref. The commit is still in the clone until it is garbage-collected — preserve it NOW with: git -C $(dm_squote "$clone_dir") branch recovered-$(dm_ref_component "$id") $head"
else
  # A local copy existed but its head could never be determined. Never an
  # all-clear: `nothing-committed` is reserved for a task that never had one.
  recoverable=UNDETERMINED
  undet_note="$id had a local copy whose head could not be determined, so nothing here can name what it held; if it held commits, they are reachable only until the clone is garbage-collected"
  [ "$parked_count" -eq 0 ] \
    || undet_note="$undet_note. The $parked_count parked_ref line(s) below belong to an EARLIER discard of this reusable id, not to this one — do not read them as this task's work"
  dm_warn "$undet_note"
fi

# Uncommitted and untracked files are the one thing this flow never keeps, so the
# summary must not imply loss where there was nothing to lose — nor hide it where
# there was. DISCARDED means gone for good; undetermined means git could not be
# read and something MAY have been lost with it.
# The `none/none` pair is the never-had-a-local-copy shape, so it is gated on
# that fact rather than trusted on its own: an initializer that survived a branch
# which could not read the tree must not print as a clean bill of health.
case "$tracked/$untracked_count" in
  undetermined/*|*/undetermined) uncommitted=undetermined ;;
  clean/0)                       uncommitted=none ;;
  none/none)
    if [ "$had_worktree" -eq 0 ]; then uncommitted=none; else uncommitted=undetermined; fi ;;
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

# --- resolve the task's open decision holds ---------------------------------
# Trashed work must not leave a decision hold pointing at discarded intent
# still showing up in "needs you". This never touches an already-resolved
# hold (see resolve_decision_holds above), so a resume finds nothing left to do.
hold_resolutions="$(resolve_decision_holds "$id" "$reason")"

# A concurrent run of this same flow may already have archived it. That is the
# tail finishing, not a failure — but only when the records really are there.
if [ ! -f "$meta_file" ] && [ -f "$DM_STATE/archive/$id.meta" ]; then
  dm_warn "$id's records were archived by another run of this flow while this one was finishing"
else
  archive_out=""
  archive_out="$("$BIN_DIR/dm-task.sh" archive "$id" 2>&1)" \
    || die_after_removal "$id" "$reason" "REFUSED: could not archive $id's records." "$archive_out"
fi

printf 'task=%s\n' "$id"
printf 'repo=%s\n' "$repo"
printf 'state=%s\n' "$state"
printf 'reason=%s\n' "$reason"
printf 'authority=operator-discard by %s\n' "$trashed_by"
printf 'local_copy=%s\n' "$worktree_result"
printf 'pr=%s\n' "$pr_action"
[ "$worker" = none ] || printf 'worker=%s\n' "$worker"
printf 'branch=%s\n' "$branch"
printf 'head=%s\n' "$head"
printf 'committed_work=%s\n' "$recoverable"
[ -z "$recover_cmd" ] || printf 'recover_cmd=%s\n' "$recover_cmd"
# Every ref that exists for this id, whatever the verdict said — ids are
# reusable, so an older discard's ref is visible rather than silently conflated.
if [ -n "$parked_list" ]; then
  printf '%s\n' "$parked_list" | while IFS= read -r pref; do
    [ -z "$pref" ] || printf 'parked_ref=%s\n' "$pref"
  done
fi
printf 'uncommitted_tracked=%s\n' "$tracked"
printf 'untracked_paths=%s\n' "$untracked_count"
printf 'uncommitted=%s\n' "$uncommitted"
printf 'backlog=%s\n' "$backlog_result"
if [ -n "$hold_resolutions" ]; then
  printf '%s\n' "$hold_resolutions" | while IFS= read -r hline; do
    case "$hline" in
      resolved:*)   printf 'resolved_hold=%s\n' "${hline#resolved:}" ;;
      unresolved:*) printf 'unresolved_hold=%s\n' "${hline#unresolved:}" ;;
      '') ;;
    esac
  done
fi
printf 'records=archived\n'

#!/usr/bin/env bash
# dm-status.sh - a read-only, glanceable snapshot of the fleet, safe to run any
# time during a session.
#
# Unlike dm-session-start (a once-per-session startup + recovery digest that
# fast-forward-syncs clones), this mutates nothing and performs no network sync.
# It reconciles current state and surfaces what needs the operator's attention.
#
# Sections: managed repos (flagging any clone left tangled on a feature branch),
# in-flight tasks (with an attention summary), active worktrees (with disk use,
# plus orphaned directories, dangling records, and orphaned data artifacts),
# three-source state drift (task meta vs backlog vs reconciled state), untracked
# operator decisions (blocked/needs-decision/awaiting-review tasks with no open
# hold), and the ready backlog with open operator decisions.
#
# Usage: dm-status.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# This snapshot must perform NO network sync. Its reconcile path transitively
# reaches dm-worktree.sh landed, which otherwise fetches; DM_NO_FETCH=1 makes it
# reconcile from local refs only. (Session-start does not set this and still syncs.)
export DM_NO_FETCH=1
here="$(dirname "${BASH_SOURCE[0]}")"
shopt -s nullglob
snapshot_failed=0

# Long-runner threshold: an in-flight task older than this is flagged as
# possibly stuck. One knob, overridable via env for a deliberately slow fleet.
# A non-integer or non-positive value (e.g. "4.5") would make the `* 3600`
# arithmetic below throw or produce a nonsensical threshold, so validate it at
# the boundary and fall back to the default rather than crash the snapshot.
DM_STUCK_AGE_HOURS="${DM_STUCK_AGE_HOURS:-4}"
case "$DM_STUCK_AGE_HOURS" in
  ''|*[!0-9]*) stuck_age_ok=0 ;;
  *) if [ "$DM_STUCK_AGE_HOURS" -gt 0 ] 2>/dev/null; then stuck_age_ok=1; else stuck_age_ok=0; fi ;;
esac
if [ "$stuck_age_ok" -ne 1 ]; then
  dm_warn "DM_STUCK_AGE_HOURS='$DM_STUCK_AGE_HOURS' is not a positive integer; defaulting to 4"
  DM_STUCK_AGE_HOURS=4
fi

section() { printf '\n=== %s ===\n' "$1"; }

# iso_to_epoch <iso>  -> epoch seconds for an ISO-8601 UTC stamp
# (YYYY-MM-DDTHH:MM:SSZ, the format dm-lib stamps), or empty if unparseable.
# Tries GNU `date -d` then BSD `date -j -f`; never fails the caller — an
# unparseable stamp degrades to "show the raw value" rather than crashing.
iso_to_epoch() {
  local iso="$1" e
  [ -n "$iso" ] || return 0
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  return 0
}

# human_age <seconds>  -> compact duration like "6h 12m", "3d 4h", "8m".
human_age() {
  local s="$1" d h m
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

section "MANAGED REPOS"
"$here/dm-repo.sh" list 2>/dev/null || echo "  (none registered)"
# A primary clone left on a non-default branch means crew work tangled it; that
# is a health signal worth surfacing (tangle_check prints only when tangled).
while IFS= read -r name; do
  [ -n "$name" ] || continue
  "$here/dm-worktree.sh" tangle "$name" 2>/dev/null || true
done < <(jq -r '.repos | keys[]' "$DM_REGISTRY" 2>/dev/null || true)

section "IN-FLIGHT WORK (reconciled; no sync)"
tasks="$("$here/dm-task.sh" list 2>/dev/null || true)"
if [ -n "$tasks" ]; then
  printf '%s\n' "$tasks"
  attention="$(printf '%s\n' "$tasks" | grep -Ec 'blocked|needs-decision|failed|awaiting-review|paused' || true)"
  [ "${attention:-0}" -gt 0 ] && \
    printf '  ATTENTION: %d task(s) need you (blocked/needs-decision/failed/awaiting-review/paused).\n' "$attention"

  # Age of each non-terminal task, from its `created` stamp, so a silently-stuck
  # task is visible. Tasks past DM_STUCK_AGE_HOURS are flagged; landed (done)
  # tasks are skipped. Read-only and offline (DM_NO_FETCH is already exported).
  now="$(date -u +%s)"
  stuck_secs=$((DM_STUCK_AGE_HOURS * 3600))
  agerows=""
  while IFS= read -r tid; do
    # `state` exits non-zero on a worktree-only or malformed record (no kind);
    # tolerate that here (|| true) — such a record has no start time to age and
    # is skipped by the empty-state guard below. Without the guard, set -e +
    # pipefail would abort the whole snapshot on one odd record.
    short="$("$here/dm-task.sh" state "$tid" 2>/dev/null | sed 's/ · .*//; s/^state: //' || true)"
    case "$short" in done|'') continue ;; esac
    created="$(dm_meta_get "$tid" created)"
    epoch="$(iso_to_epoch "$created")"
    if [ -n "$epoch" ]; then
      secs=$((now - epoch))
      col="$(human_age "$secs")"
      if [ "$secs" -ge "$stuck_secs" ]; then
        col="$col  <- possibly stuck (>${DM_STUCK_AGE_HOURS}h); load stuck-worker"
      fi
    else
      # Portable epoch conversion failed — degrade to the raw stamp, never crash.
      col="since ${created:-unknown}"
    fi
    agerows+="  age"$'\t'"$tid"$'\t'"$short"$'\t'"$col"$'\n'
  done < <(dm_all_task_ids)
  if [ -n "$agerows" ]; then
    printf '%s' "$agerows" | column -t -s$'\t' 2>/dev/null || printf '%s' "$agerows"
  fi
else
  echo "  (no tasks)"
fi

section "DOMAIN SUPERVISORS (durable identities)"
if secondmates="$("$here/dm-secondmate.sh" reconcile 2>&1)"; then
  if [ -n "$secondmates" ]; then printf '%s\n' "$secondmates"; else echo "  (none registered)"; fi
else
  printf '  FAIL supervisor state unreadable or malformed: %s\n' "$DM_STATE/secondmates.json"
  [ -z "$secondmates" ] || printf '       %s\n' "$(printf '%s' "$secondmates" | head -n1)"
  snapshot_failed=1
fi

section "OPEN PRs (needing attention)"
# The fleet PR/health sweep, run through dm-pr.sh so the CI rollup has one owner.
# DM_NO_FETCH is exported above, so the sweep performs NO network and reports the
# cached pr_state/checks (live review state needs a fetch this snapshot must not
# do). Best-effort: a sweep failure must not abort the snapshot.
"$here/dm-pr.sh" sweep 2>/dev/null || echo "  (sweep unavailable)"

section "WORKTREES (active local copies)"
# Parallel indexed arrays record, for every worktree a task claims, its path
# (rec_wt) and owning task id (rec_id) at the same index. bash 3.2 (macOS) has no
# associative arrays; the fleet is small, so the linear membership scan below is
# fine. Used to cross-check the on-disk state/worktrees/ directory for orphans
# and dangling records.
rec_wt=(); rec_id=()
rows=""
while IFS=$'\t' read -r id repo wt; do
  [ -n "$wt" ] || continue
  rec_wt+=("$wt"); rec_id+=("$id")
  if [ -d "$wt" ]; then
    size="$(du -sh "$wt" 2>/dev/null | cut -f1)"
    rows+="$id"$'\t'"$repo"$'\t'"${size:-?}"$'\t'"$wt"$'\n'
  fi
done < <("$here/dm-worktree.sh" list 2>/dev/null || true)
if [ -n "$rows" ]; then printf '%s' "$rows" | column -t -s$'\t' 2>/dev/null || printf '%s' "$rows"; else echo "  (none)"; fi
# recorded_id <path> -> echo the owning task id if <path> is recorded, else empty.
recorded_id() {
  local target="$1" i
  for ((i = 0; i < ${#rec_wt[@]}; i++)); do
    [ "${rec_wt[i]}" = "$target" ] && { printf '%s' "${rec_id[i]}"; return 0; }
  done
  return 1
}
# A directory under state/worktrees/ that no task claims (leftover from a crash
# or a manual removal) — teardown never created it through the normal path.
for d in "$DM_STATE"/worktrees/*/; do
  d="${d%/}"
  recorded_id "$d" >/dev/null || printf '  ORPHAN (on disk, no task record): %s\n' "$d"
done
# A task that records a worktree which no longer exists on disk.
for ((i = 0; i < ${#rec_wt[@]}; i++)); do
  [ -d "${rec_wt[i]}" ] || printf '  DANGLING (recorded by %s, missing on disk): %s\n' "${rec_id[i]}" "${rec_wt[i]}"
done
# A data/<id>/ artifact dir whose task record is gone (torn down without archival,
# or a crash) — dead weight every scan re-walks. Parallel to the ORPHAN/DANGLING
# worktree checks above; a live or archivable task always keeps its .meta.
for d in "$DM_DATA"/*/; do
  d="${d%/}"
  [ -f "$DM_TASKS/$(basename "$d").meta" ] || printf '  ORPHAN-DATA (artifacts, no task record): %s\n' "$d"
done

section "STATE DRIFT (task meta vs backlog vs reconciled state)"
# Three sources describe the same work: the durable task metas, the backlog
# items, and the reconciled current state. When they disagree, one of them is
# lying. This lint surfaces the disagreements read-only and offline (DM_NO_FETCH
# is exported above, so the transitive `dm-worktree.sh landed` uses local refs).
backlog="$DM_STATE/backlog.json"
drift=0
if [ -f "$backlog" ] && command -v jq >/dev/null 2>&1; then
  # (a) a task meta with no matching backlog item — dispatch always records a
  #     backlog item, so a meta without one is untracked work.
  while IFS= read -r tid; do
    if ! jq -e --arg id "$tid" 'any(.items[]; .id==$id)' "$backlog" >/dev/null 2>&1; then
      printf '  DRIFT: task %s has no backlog item\n' "$tid"; drift=$((drift + 1))
    fi
  done < <(dm_all_task_ids)
  # (b) a backlog item whose stored status disagrees with the reconciled state,
  #     and (c) a done backlog item whose worktree still holds unlanded work.
  while IFS=$'\t' read -r bid bstatus; do
    [ -n "$bid" ] || continue
    [ -f "$DM_TASKS/$bid.meta" ] || continue   # only a task record can be reconciled
    bstate="$("$here/dm-task.sh" state "$bid" 2>/dev/null | sed 's/ · .*//; s/^state: //' || true)"
    if [ "$bstatus" = "done" ] && [ "$bstate" != "done" ]; then
      printf '  DRIFT: backlog %s is done but task reconciles to %s\n' "$bid" "${bstate:-unknown}"
      drift=$((drift + 1))
    elif [ "$bstatus" != "done" ] && [ "$bstate" = "done" ]; then
      printf '  DRIFT: task %s has landed but backlog still marks it %s\n' "$bid" "$bstatus"
      drift=$((drift + 1))
    fi
    if [ "$bstatus" = "done" ]; then
      bwt="$(dm_meta_get "$bid" worktree)"
      if [ -n "$bwt" ] && [ -d "$bwt" ] && ! "$here/dm-worktree.sh" landed "$bid" >/dev/null 2>&1; then
        printf '  DRIFT: backlog %s is done but its local copy holds unlanded work: %s\n' "$bid" "$bwt"
        drift=$((drift + 1))
      fi
    fi
  done < <(jq -r '.items[] | "\(.id)\t\(.status)"' "$backlog" 2>/dev/null || true)
fi
if [ "$drift" -eq 0 ]; then echo "  (no drift)"; fi

section "UNTRACKED DECISIONS (blocked/needs-decision/awaiting-review with no open hold)"
# A task waiting on the operator (blocked/needs-decision/awaiting-review) whose
# decision lives only in the append-only status log evaporates at teardown. A
# durable backlog hold must reference it; flag the ones that have none so the
# operator sees the gap. (Detect + flag only — the decision text is not parsed.)
nohold=0
if [ -f "$backlog" ] && command -v jq >/dev/null 2>&1; then
  holds="$(jq -r '.decisions[] | select(.status=="open") | "\(.key) \(.origin // "")"' "$backlog" 2>/dev/null || true)"
  while IFS= read -r tid; do
    tstate="$("$here/dm-task.sh" state "$tid" 2>/dev/null | sed 's/ · .*//; s/^state: //' || true)"
    case "$tstate" in blocked|needs-decision|awaiting-review) ;; *) continue ;; esac
    if [ -n "$holds" ] && grep -qF "$tid" <<<"$holds"; then continue; fi
    printf '  NO-HOLD: task %s is %s but no open decision hold references it\n' "$tid" "$tstate"
    nohold=$((nohold + 1))
  done < <(dm_all_task_ids)
fi
if [ "$nohold" -eq 0 ]; then echo "  (none)"; fi

section "BACKLOG (ready to start)"
ready="$("$here/dm-backlog.sh" ready 2>/dev/null || true)"
if [ -n "$ready" ]; then printf '%s\n' "$ready"; else echo "  (nothing ready)"; fi

section "OPEN DECISIONS (operator-owned)"
dec="$("$here/dm-backlog.sh" decisions 2>/dev/null || true)"
if [ -n "$dec" ]; then printf '%s\n' "$dec"; else echo "  (none open)"; fi

[ "$snapshot_failed" -eq 0 ]

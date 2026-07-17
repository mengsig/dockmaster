#!/usr/bin/env bash
# mh-status.sh - a read-only, glanceable snapshot of the fleet, safe to run any
# time during a session.
#
# Unlike mh-session-start (a once-per-session startup + recovery digest that
# fast-forward-syncs clones), this mutates nothing and performs no network sync.
# It reconciles current state and surfaces what needs the operator's attention.
#
# Sections: managed repos (flagging any clone left tangled on a feature branch),
# in-flight tasks (with an attention summary), active worktrees (with disk use,
# plus orphaned directories and dangling records), and the ready backlog with
# open operator decisions.
#
# Usage: mh-status.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_ensure_dirs
# This snapshot must perform NO network sync. Its reconcile path transitively
# reaches mh-worktree.sh landed, which otherwise fetches; MH_NO_FETCH=1 makes it
# reconcile from local refs only. (Session-start does not set this and still syncs.)
export MH_NO_FETCH=1
here="$(dirname "${BASH_SOURCE[0]}")"
shopt -s nullglob

# Long-runner threshold: an in-flight task older than this is flagged as
# possibly stuck. One knob, overridable via env for a deliberately slow fleet.
MH_STUCK_AGE_HOURS="${MH_STUCK_AGE_HOURS:-4}"

section() { printf '\n=== %s ===\n' "$1"; }

# iso_to_epoch <iso>  -> epoch seconds for an ISO-8601 UTC stamp
# (YYYY-MM-DDTHH:MM:SSZ, the format mh-lib stamps), or empty if unparseable.
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
"$here/mh-repo.sh" list 2>/dev/null || echo "  (none registered)"
# A primary clone left on a non-default branch means crew work tangled it; that
# is a health signal worth surfacing (tangle_check prints only when tangled).
while IFS= read -r name; do
  [ -n "$name" ] || continue
  "$here/mh-worktree.sh" tangle "$name" 2>/dev/null || true
done < <(jq -r '.repos | keys[]' "$MH_REGISTRY" 2>/dev/null || true)

section "IN-FLIGHT WORK (reconciled; no sync)"
tasks="$("$here/mh-task.sh" list 2>/dev/null || true)"
if [ -n "$tasks" ]; then
  printf '%s\n' "$tasks"
  attention="$(printf '%s\n' "$tasks" | grep -Ec 'blocked|failed|awaiting-review|paused' || true)"
  [ "${attention:-0}" -gt 0 ] && \
    printf '  ATTENTION: %d task(s) need you (blocked/failed/awaiting-review/paused).\n' "$attention"

  # Age of each non-terminal task, from its `created` stamp, so a silently-stuck
  # task is visible. Tasks past MH_STUCK_AGE_HOURS are flagged; landed (done)
  # tasks are skipped. Read-only and offline (MH_NO_FETCH is already exported).
  now="$(date -u +%s)"
  stuck_secs=$((MH_STUCK_AGE_HOURS * 3600))
  agerows=""
  for m in "$MH_TASKS"/*.meta; do
    [ -f "$m" ] || continue
    tid="$(basename "$m" .meta)"
    # `state` exits non-zero on a worktree-only or malformed record (no kind);
    # tolerate that here (|| true) — such a record has no start time to age and
    # is skipped by the empty-state guard below. Without the guard, set -e +
    # pipefail would abort the whole snapshot on one odd record.
    short="$("$here/mh-task.sh" state "$tid" 2>/dev/null | sed 's/ · .*//; s/^state: //' || true)"
    case "$short" in done|'') continue ;; esac
    created="$(mh_meta_get "$tid" created)"
    epoch="$(iso_to_epoch "$created")"
    if [ -n "$epoch" ]; then
      secs=$((now - epoch))
      col="$(human_age "$secs")"
      if [ "$secs" -ge "$stuck_secs" ]; then
        col="$col  <- possibly stuck (>${MH_STUCK_AGE_HOURS}h); load stuck-worker"
      fi
    else
      # Portable epoch conversion failed — degrade to the raw stamp, never crash.
      col="since ${created:-unknown}"
    fi
    agerows+="  age"$'\t'"$tid"$'\t'"$short"$'\t'"$col"$'\n'
  done
  if [ -n "$agerows" ]; then
    printf '%s' "$agerows" | column -t -s$'\t' 2>/dev/null || printf '%s' "$agerows"
  fi
else
  echo "  (no tasks)"
fi

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
done < <("$here/mh-worktree.sh" list 2>/dev/null || true)
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
for d in "$MH_STATE"/worktrees/*/; do
  d="${d%/}"
  recorded_id "$d" >/dev/null || printf '  ORPHAN (on disk, no task record): %s\n' "$d"
done
# A task that records a worktree which no longer exists on disk.
for ((i = 0; i < ${#rec_wt[@]}; i++)); do
  [ -d "${rec_wt[i]}" ] || printf '  DANGLING (recorded by %s, missing on disk): %s\n' "${rec_id[i]}" "${rec_wt[i]}"
done

section "BACKLOG (ready to start)"
ready="$("$here/mh-backlog.sh" ready 2>/dev/null || true)"
if [ -n "$ready" ]; then printf '%s\n' "$ready"; else echo "  (nothing ready)"; fi

section "OPEN DECISIONS (operator-owned)"
dec="$("$here/mh-backlog.sh" decisions 2>/dev/null || true)"
if [ -n "$dec" ]; then printf '%s\n' "$dec"; else echo "  (none open)"; fi

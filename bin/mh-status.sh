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

section() { printf '\n=== %s ===\n' "$1"; }

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
else
  echo "  (no tasks)"
fi

section "WORKTREES (active local copies)"
# recorded[path]=task-id for every worktree a task claims; used to cross-check
# the on-disk state/worktrees/ directory for orphans and dangling records.
declare -A recorded
rows=""
while IFS=$'\t' read -r id repo wt; do
  [ -n "$wt" ] || continue
  recorded["$wt"]="$id"
  if [ -d "$wt" ]; then
    size="$(du -sh "$wt" 2>/dev/null | cut -f1)"
    rows+="$id"$'\t'"$repo"$'\t'"${size:-?}"$'\t'"$wt"$'\n'
  fi
done < <("$here/mh-worktree.sh" list 2>/dev/null || true)
if [ -n "$rows" ]; then printf '%s' "$rows" | column -t -s$'\t' 2>/dev/null || printf '%s' "$rows"; else echo "  (none)"; fi
# A directory under state/worktrees/ that no task claims (leftover from a crash
# or a manual removal) — teardown never created it through the normal path.
for d in "$MH_STATE"/worktrees/*/; do
  d="${d%/}"
  [ -n "${recorded[$d]:-}" ] || printf '  ORPHAN (on disk, no task record): %s\n' "$d"
done
# A task that records a worktree which no longer exists on disk.
for wt in "${!recorded[@]}"; do
  [ -d "$wt" ] || printf '  DANGLING (recorded by %s, missing on disk): %s\n' "${recorded[$wt]}" "$wt"
done

section "BACKLOG (ready to start)"
ready="$("$here/mh-backlog.sh" ready 2>/dev/null || true)"
if [ -n "$ready" ]; then printf '%s\n' "$ready"; else echo "  (nothing ready)"; fi

section "OPEN DECISIONS (operator-owned)"
dec="$("$here/mh-backlog.sh" decisions 2>/dev/null || true)"
if [ -n "$dec" ]; then printf '%s\n' "$dec"; else echo "  (none open)"; fi

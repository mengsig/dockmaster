#!/usr/bin/env bash
# dm-merge.sh - guarded local landing and conflict-aware rebase.
#
# Two operations, both fail closed:
#   local <id>    land a local-only task branch into its clone's default branch
#                 by FAST-FORWARD ONLY. A diverged branch is refused with a
#                 rebase instruction, never force-merged.
#   rebase <id>   update a task's worktree branch onto the latest default. On a
#                 clean rebase it reports success; on conflicts it stops and
#                 reports the conflicted files, then aborts to leave the worktree
#                 exactly as it was (the merge-conflict skill dispatches a
#                 crewmate to resolve with full context).
#
# This is one of the few paths allowed to change a managed clone, and only the
# local, FF-only landing does so.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git
dm_ensure_dirs

cmd="${1:-}"; shift || true
case "$cmd" in
  local)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-merge.sh local <id>"
    mode="$(dm_meta_get "$id" mode)"
    [ "$mode" = "local-only" ] || dm_die "task $id is mode '$mode', not local-only; use dm-pr.sh for PR-based landing"
    repo="$(dm_meta_get "$id" repo)"; wt="$(dm_require_worktree "$id")"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
    [ "$branch" != "HEAD" ] || dm_die "worktree on detached HEAD; nothing to land"
    ! dm_tracked_dirty "$wt" || dm_die "worktree has uncommitted changes to tracked files; commit before landing"
    dir="$(dm_repo_dir "$repo")"; def="$(dm_default_branch "$dir")"
    cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    [ "$cur" = "$def" ] || dm_die "clone is on '$cur', not default '$def'; return it before landing"
    [ -z "$(git -C "$dir" status --porcelain)" ] || dm_die "clone working tree is dirty; refusing to land"
    head="$(git -C "$wt" rev-parse HEAD)"
    before="$(git -C "$dir" rev-parse --short "$def")"
    # FF only: default must be an ancestor of the task head.
    if ! git -C "$dir" merge-base --is-ancestor "$def" "$head"; then
      dm_die "REFUSED: '$def' is not an ancestor of '$branch' (diverged). Rebase the branch onto '$def' first: dm-merge.sh rebase $id"
    fi
    git -C "$dir" merge --ff-only "$head" >/dev/null || dm_die "fast-forward merge failed"
    after="$(git -C "$dir" rev-parse --short "$def")"
    dm_status_append "$id" merged "local $def $before -> $after"
    dm_info "landed $id into $def ($before -> $after)"
    ;;

  rebase)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-merge.sh rebase <id>"
    repo="$(dm_meta_get "$id" repo)"; wt="$(dm_require_worktree "$id")"
    ! dm_tracked_dirty "$wt" || dm_die "worktree has uncommitted changes to tracked files; commit or stash before rebasing"
    dir="$(dm_repo_dir "$repo")"; def="$(dm_default_branch "$dir")"
    git -C "$dir" fetch --quiet origin "$def" 2>/dev/null || dm_warn "$repo: fetch failed; base may be stale"
    # Pick the rebase base to MATCH the base a worktree is created from, or the
    # branch will loop between "clean rebase" and "diverged, rebase first". For a
    # local-only repo the LOCAL <def> holds local landings and origin lags, so
    # prefer local <def>; other modes prefer origin/<def>.
    mode="$(dm_meta_get "$id" mode)"
    if [ "$mode" = "local-only" ]; then
      base="$(git -C "$dir" rev-parse --verify --quiet "$def" 2>/dev/null || git -C "$dir" rev-parse "origin/$def")"
    else
      base="$(git -C "$dir" rev-parse --verify --quiet "origin/$def" 2>/dev/null || git -C "$dir" rev-parse "$def")"
    fi
    if git -C "$wt" rebase "$base" >/dev/null 2>&1; then
      dm_info "rebased $id onto $def cleanly"
      exit 0
    fi
    # conflicts: report and abort so the worktree is left untouched for a crewmate
    conflicts="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
    git -C "$wt" rebase --abort >/dev/null 2>&1 \
      || dm_die "rebase of $id hit conflicts and 'git rebase --abort' failed; worktree is half-rebased and could not be restored — resolve manually in $wt"
    echo "CONFLICT: rebasing $id onto $def hit conflicts in:" >&2
    printf '%s\n' "$conflicts" >&2
    echo "worktree left unchanged; dispatch a crewmate via the merge-conflict skill to resolve with full context" >&2
    exit 3
    ;;

  *)
    echo "usage: dm-merge.sh {local|rebase} ..." >&2; exit 2 ;;
esac

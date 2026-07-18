#!/usr/bin/env bash
# mh-worktree.sh - disposable git worktrees for isolated, parallel crew work.
#
# Every ship/scout task runs in its OWN worktree off the repo's clone, so
# concurrent work on one repo never collides. Worktrees live under
# state/worktrees/<id> and are removed only after their work has landed (ship)
# or their report exists (scout).
#
# Commands:
#   create <id> <repo> [<branch>]   create worktree for task <id> off <repo>'s clone
#                                    (branch defaults to a detached checkout of the
#                                    default branch; crewmate creates its own branch)
#   assert <path> <repo>            verify <path> is a real worktree root distinct
#                                    from the primary clone (isolation invariant)
#   landed <id>                     is the worktree's committed work landed? (exit 0/1)
#   remove <id> [--force]           remove worktree; refuses on unlanded/dirty work
#   list                            list task worktrees
#   tangle <repo>                   is the primary clone tangled onto a feature branch?

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need git
mh_ensure_dirs

MH_WT="$MH_STATE/worktrees"
mkdir -p "$MH_WT"

# --- isolation assertion: the load-bearing safety invariant ------------------
assert_isolated() {
  local path="$1" repo="$2" primary top
  path="$(cd "$path" 2>/dev/null && pwd -P)" || mh_die "worktree path does not exist: $1"
  primary="$(cd "$(mh_repo_dir "$repo")" && pwd -P)"
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  top="$(cd "$top" 2>/dev/null && pwd -P || true)"
  [ -n "$top" ] || mh_die "not inside a git worktree: $path"
  [ "$top" = "$path" ] || mh_die "path is not a worktree root: $path (root is $top)"
  [ "$top" != "$primary" ] || mh_die "REFUSED: task path equals the primary clone ($primary); crew work must be isolated"
  printf '%s\n' "$top"
}

# --- tangle detection: named non-default branch checked out in primary -------
tangle_check() {
  local repo="$1" dir def cur
  dir="$(mh_repo_dir "$repo")"
  def="$(mh_default_branch "$dir")"
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [ "$cur" != "$def" ] && [ "$cur" != "HEAD" ]; then
    echo "TANGLE: primary clone of '$repo' is on '$cur', expected '$def'. Return it with: git -C $dir checkout $def"
    return 1
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create)
    id="${1:-}"; repo="${2:-}"; branch="${3:-}"
    [ -n "$id" ] && [ -n "$repo" ] || mh_die "usage: mh-worktree.sh create <id> <repo> [<branch>]"
    mh_require_id "$id"
    # Require an existing task record with a kind. Without it, create would write
    # a kind-less meta that `mh-task.sh state` cannot classify (it reconciles by
    # kind). Fail closed and point at the record-creating command.
    [ -n "$(mh_meta_get "$id" kind)" ] || mh_die "no task record for '$id' (or it has no kind); create it first: mh-task.sh new $id --kind ship|scout --repo $repo"
    dir="$(mh_repo_dir "$repo")"
    wt="$MH_WT/$id"
    [ -e "$wt" ] && mh_die "worktree already exists: $wt"
    if [ "${MH_NO_FETCH:-0}" != "1" ]; then
      # Bring the clone's default branch current BEFORE cutting a worktree base
      # off it (we hit a 9-behind base once). Reuse mh-sync's FF-only logic
      # rather than reimplementing it here. A STUCK result (diverged or dirty
      # clone) fails closed instead of cutting a worktree off a stale base.
      # MH_NO_FETCH=1 (offline / smoke) skips this entirely: no sync, no block.
      sync_out="$("$(dirname "${BASH_SOURCE[0]}")/mh-sync.sh" one "$repo")"
      case "$sync_out" in
        STUCK:*) mh_die "clone $repo is not fast-forwardable to origin — resolve it, then retry ($sync_out)" ;;
      esac
    fi
    def="$(mh_default_branch "$dir")"
    # Branch from the LOCAL default: it holds local-only landings and is kept
    # fast-forwarded to origin for PR repos by mh-sync. Fall back to origin.
    base="$(git -C "$dir" rev-parse --verify --quiet "$def" 2>/dev/null || git -C "$dir" rev-parse "origin/$def")"
    if [ -n "$branch" ]; then
      git -C "$dir" worktree add -b "$branch" "$wt" "$base" >/dev/null
    else
      # detached checkout of the base; the crewmate creates its own branch
      git -C "$dir" worktree add --detach "$wt" "$base" >/dev/null
    fi
    assert_isolated "$wt" "$repo" >/dev/null
    mh_meta_set "$id" worktree "$wt"
    mh_meta_set "$id" repo "$repo"
    mh_info "$wt"
    ;;

  assert)
    path="${1:-}"; repo="${2:-}"
    [ -n "$path" ] && [ -n "$repo" ] || mh_die "usage: mh-worktree.sh assert <path> <repo>"
    assert_isolated "$path" "$repo"
    ;;

  tangle)
    repo="${1:-}"; [ -n "$repo" ] || mh_die "usage: mh-worktree.sh tangle <repo>"
    tangle_check "$repo"
    ;;

  landed)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-worktree.sh landed <id>"
    wt="$(mh_meta_get "$id" worktree)"; repo="$(mh_meta_get "$id" repo)"
    [ -n "$wt" ] && [ -d "$wt" ] || mh_die "no worktree recorded for $id"
    # Refresh pr_state so an out-of-band merge is reflected in the pr_state
    # fallback below. No-op offline (MH_NO_FETCH) or with no/already-merged PR.
    mh_refresh_pr_state "$id"
    # Uncommitted changes to tracked files mean work is not committed => not landed.
    # (Untracked files are handled separately at teardown, not here.)
    ! mh_tracked_dirty "$wt" || { echo "unlanded: uncommitted changes to tracked files"; exit 1; }
    dir="$(mh_repo_dir "$repo")"
    def="$(mh_default_branch "$dir")"
    # MH_NO_FETCH=1 reconciles from local refs only (mh-status.sh sets it so its
    # read-only snapshot performs no network). Session-start leaves it unset and
    # still syncs. On a failed fetch, warn rather than hide a stale base.
    if [ "${MH_NO_FETCH:-0}" != "1" ]; then
      git -C "$dir" fetch --quiet origin "$def" 2>/dev/null || mh_warn "$repo: fetch failed; base may be stale"
    fi
    head="$(git -C "$wt" rev-parse HEAD)"
    # Landed if HEAD is an ancestor of origin/<default> (merged) or there are no
    # commits ahead of the base at all (nothing to land).
    if git -C "$dir" merge-base --is-ancestor "$head" "origin/$def" 2>/dev/null \
       || git -C "$dir" merge-base --is-ancestor "$head" "$def" 2>/dev/null; then
      echo "landed"; exit 0
    fi
    # A recorded, merged PR also counts as landed (squash-merge rewrites SHAs).
    pr_state="$(mh_meta_get "$id" pr_state)"
    [ "$pr_state" = "MERGED" ] && { echo "landed: PR merged"; exit 0; }
    echo "unlanded: commits not in $def and no merged PR recorded"; exit 1
    ;;

  remove)
    # Parse flags in a loop so order does not matter: both `remove <id> --force`
    # and `remove --force <id>` are accepted.
    id=""; force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force) force=1; shift ;;
        -*) mh_die "unknown flag: $1" ;;
        *) [ -z "$id" ] || mh_die "unexpected extra argument: $1"; id="$1"; shift ;;
      esac
    done
    [ -n "$id" ] || mh_die "usage: mh-worktree.sh remove <id> [--force]"
    wt="$(mh_meta_get "$id" worktree)"; repo="$(mh_meta_get "$id" repo)"
    [ -n "$wt" ] || mh_die "no worktree recorded for $id"
    kind="$(mh_meta_get "$id" kind)"
    if [ "$force" -eq 0 ]; then
      # Committed work must be landed (ship only; a scout worktree is scratch).
      if [ "$kind" != "scout" ] && ! "$0" landed "$id" >/dev/null 2>&1; then
        mh_die "REFUSED: $id has unlanded work. Confirm it landed, or pass --force only with explicit discard authority."
      fi
      # Untracked non-ignored files could be forgotten work; fail closed.
      untracked="$(mh_untracked "$wt")"
      if [ -n "$untracked" ]; then
        mh_die "REFUSED: $id worktree has untracked files (forgotten work, or build cruft the repo should ignore). Review/clean them, or pass --force. Files:
$untracked"
      fi
    fi
    dir="$(mh_repo_dir "$repo")"
    git -C "$dir" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git -C "$dir" worktree prune 2>/dev/null || true
    mh_meta_set "$id" worktree ""
    mh_info "removed worktree for $id"
    ;;

  list)
    for m in "$MH_TASKS"/*.meta; do
      [ -f "$m" ] || continue
      id="$(basename "$m" .meta)"
      wt="$(mh_meta_get "$id" worktree)"
      [ -n "$wt" ] && printf '%s\t%s\t%s\n' "$id" "$(mh_meta_get "$id" repo)" "$wt"
    done
    ;;

  *)
    echo "usage: mh-worktree.sh {create|assert|tangle|landed|remove|list} ..." >&2; exit 2 ;;
esac

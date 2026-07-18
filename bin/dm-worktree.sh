#!/usr/bin/env bash
# dm-worktree.sh - disposable git worktrees for isolated, parallel crew work.
#
# Every ship/scout task runs in its OWN worktree off the repo's clone, so
# concurrent work on one repo never collides. Worktrees live under
# state/worktrees/<id> and are removed only after their work has landed (ship)
# or their report exists (scout).
#
# Commands:
#   create <id> <repo> [<branch>] [--base <ref>]
#                                    create worktree for task <id> off <repo>'s clone
#                                    (branch defaults to a detached checkout of the
#                                    default branch; crewmate creates its own branch).
#                                    --base <ref> branches off a PARENT ref instead
#                                    (a stacked sub-PR child): the parent ref itself
#                                    is fetched fresh and recorded as the task's
#                                    `base` meta, in place of the default-branch
#                                    freshness guard used when --base is omitted.
#   assert <path> <repo>            verify <path> is a real worktree root distinct
#                                    from the primary clone (isolation invariant)
#   landed <id>                     is the worktree's committed work landed? (exit 0/1)
#   remove <id> [--force]           remove worktree; refuses on unlanded/dirty work
#   list                            list task worktrees
#   tangle <repo>                   is the primary clone tangled onto a feature branch?

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git
dm_ensure_dirs

DM_WT="$DM_STATE/worktrees"
mkdir -p "$DM_WT"

# --- isolation assertion: the load-bearing safety invariant ------------------
assert_isolated() {
  local path="$1" repo="$2" primary top
  path="$(cd "$path" 2>/dev/null && pwd -P)" || dm_die "worktree path does not exist: $1"
  primary="$(cd "$(dm_repo_dir "$repo")" && pwd -P)"
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  top="$(cd "$top" 2>/dev/null && pwd -P || true)"
  [ -n "$top" ] || dm_die "not inside a git worktree: $path"
  [ "$top" = "$path" ] || dm_die "path is not a worktree root: $path (root is $top)"
  [ "$top" != "$primary" ] || dm_die "REFUSED: task path equals the primary clone ($primary); crew work must be isolated"
  printf '%s\n' "$top"
}

# --- tangle detection: named non-default branch checked out in primary -------
tangle_check() {
  local repo="$1" dir def cur
  dir="$(dm_repo_dir "$repo")"
  def="$(dm_default_branch "$dir")"
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
    # Flags parsed in a loop (mirrors `remove`) so `--base` can appear anywhere
    # relative to the positional <id> <repo> [<branch>].
    id=""; repo=""; branch=""; base_ref=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base) [ "$#" -ge 2 ] || dm_die "--base requires a <ref>"; base_ref="$2"; shift 2 ;;
        -*) dm_die "unknown flag: $1" ;;
        *)
          if [ -z "$id" ]; then id="$1"
          elif [ -z "$repo" ]; then repo="$1"
          elif [ -z "$branch" ]; then branch="$1"
          else dm_die "unexpected extra argument: $1"
          fi
          shift ;;
      esac
    done
    [ -n "$id" ] && [ -n "$repo" ] || dm_die "usage: dm-worktree.sh create <id> <repo> [<branch>] [--base <ref>]"
    dm_require_id "$id"
    # Require an existing task record with a kind. Without it, create would write
    # a kind-less meta that `dm-task.sh state` cannot classify (it reconciles by
    # kind). Fail closed and point at the record-creating command.
    [ -n "$(dm_meta_get "$id" kind)" ] || dm_die "no task record for '$id' (or it has no kind); create it first: dm-task.sh new $id --kind ship|scout --repo $repo"
    dir="$(dm_repo_dir "$repo")"
    wt="$DM_WT/$id"
    [ -e "$wt" ] && dm_die "worktree already exists: $wt"
    if [ -n "$base_ref" ]; then
      # PARENT-AWARE freshness: a sub-PR child branches off a PARENT branch, not
      # the clone's default branch, so the base that must be current is the
      # parent ref itself -- fetch it directly instead of running the (unrelated)
      # default-branch FF-sync guard below. DM_NO_FETCH=1 skips the fetch, same
      # convention as the default path.
      if [ "${DM_NO_FETCH:-0}" != "1" ]; then
        git -C "$dir" fetch --quiet origin "$base_ref" 2>/dev/null || dm_warn "$repo: fetch of parent ref '$base_ref' failed; base may be stale"
      fi
      # Prefer the freshly-fetched remote-tracking ref; fall back to a local-only
      # branch (a parent not yet pushed).
      base="$(git -C "$dir" rev-parse --verify --quiet "origin/$base_ref" 2>/dev/null || git -C "$dir" rev-parse --verify --quiet "$base_ref" 2>/dev/null)" \
        || dm_die "parent ref not found (checked origin/$base_ref and $base_ref): $base_ref"
    else
      if [ "${DM_NO_FETCH:-0}" != "1" ]; then
        # Bring the clone's default branch current BEFORE cutting a worktree base
        # off it (we hit a 9-behind base once). Reuse dm-sync's FF-only logic
        # rather than reimplementing it here. A STUCK result (diverged or dirty
        # clone) fails closed instead of cutting a worktree off a stale base.
        # DM_NO_FETCH=1 (offline / smoke) skips this entirely: no sync, no block.
        # The `|| sync_out=...` guards against dm-sync itself exiting non-zero
        # unexpectedly (under set -e that would otherwise crash this command with
        # a raw git failure instead of failing closed through the STUCK path below).
        # dm_sync_reaction (dm-lib.sh) turns STUCK into dm_die here and SKIP into
        # "base may be stale" (a warn, not fail-closed — no divergence was found).
        sync_out="$("$(dirname "${BASH_SOURCE[0]}")/dm-sync.sh" one "$repo")" || sync_out="STUCK: sync failed unexpectedly"
        dm_sync_reaction "$repo" "$sync_out" die
      fi
      def="$(dm_default_branch "$dir")"
      # Branch from the LOCAL default: it holds local-only landings and is kept
      # fast-forwarded to origin for PR repos by dm-sync. Fall back to origin.
      base="$(git -C "$dir" rev-parse --verify --quiet "$def" 2>/dev/null || git -C "$dir" rev-parse "origin/$def")"
    fi
    if [ -n "$branch" ]; then
      git -C "$dir" worktree add -b "$branch" "$wt" "$base" >/dev/null
    else
      # detached checkout of the base; the crewmate creates its own branch
      git -C "$dir" worktree add --detach "$wt" "$base" >/dev/null
    fi
    assert_isolated "$wt" "$repo" >/dev/null
    dm_meta_set "$id" worktree "$wt"
    dm_meta_set "$id" repo "$repo"
    # Record the parent ref so dm-pr.sh open can default the sub-PR's --base to
    # it (the "main PR" this child stacks on). Not a landing field: it carries
    # no forge risk analogous to pr/pr_state/merge_state.
    [ -n "$base_ref" ] && dm_meta_set "$id" base "$base_ref"
    dm_info "$wt"
    ;;

  assert)
    path="${1:-}"; repo="${2:-}"
    [ -n "$path" ] && [ -n "$repo" ] || dm_die "usage: dm-worktree.sh assert <path> <repo>"
    assert_isolated "$path" "$repo"
    ;;

  tangle)
    repo="${1:-}"; [ -n "$repo" ] || dm_die "usage: dm-worktree.sh tangle <repo>"
    tangle_check "$repo"
    ;;

  landed)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-worktree.sh landed <id>"
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    # Refresh pr_state so an out-of-band merge is reflected in the pr_state
    # fallback below. Best-effort. No-op offline (DM_NO_FETCH) or with no/
    # already-merged PR (dm_should_refresh_pr_state).
    if dm_should_refresh_pr_state "$id"; then
      "$(dirname "${BASH_SOURCE[0]}")/dm-pr.sh" check "$id" >/dev/null 2>&1 || true
    fi
    # Uncommitted changes to tracked files mean work is not committed => not landed.
    # (Untracked files are handled separately at teardown, not here.)
    ! dm_tracked_dirty "$wt" || { echo "unlanded: uncommitted changes to tracked files"; exit 1; }
    dir="$(dm_repo_dir "$repo")"
    def="$(dm_default_branch "$dir")"
    # DM_NO_FETCH=1 reconciles from local refs only (dm-status.sh sets it so its
    # read-only snapshot performs no network). Session-start leaves it unset and
    # still syncs. On a failed fetch, warn rather than hide a stale base.
    if [ "${DM_NO_FETCH:-0}" != "1" ]; then
      git -C "$dir" fetch --quiet origin "$def" 2>/dev/null || dm_warn "$repo: fetch failed; base may be stale"
    fi
    head="$(git -C "$wt" rev-parse HEAD)"
    # Landed if HEAD is an ancestor of origin/<default> (merged) or there are no
    # commits ahead of the base at all (nothing to land).
    if git -C "$dir" merge-base --is-ancestor "$head" "origin/$def" 2>/dev/null \
       || git -C "$dir" merge-base --is-ancestor "$head" "$def" 2>/dev/null; then
      echo "landed"; exit 0
    fi
    # A recorded, merged PR also counts as landed (squash-merge rewrites SHAs).
    pr_state="$(dm_meta_get "$id" pr_state)"
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
        -*) dm_die "unknown flag: $1" ;;
        *) [ -z "$id" ] || dm_die "unexpected extra argument: $1"; id="$1"; shift ;;
      esac
    done
    [ -n "$id" ] || dm_die "usage: dm-worktree.sh remove <id> [--force]"
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    kind="$(dm_meta_get "$id" kind)"
    if [ "$force" -eq 0 ]; then
      # Committed work must be landed (ship only; a scout worktree is scratch).
      if [ "$kind" != "scout" ] && ! "$0" landed "$id" >/dev/null 2>&1; then
        dm_die "REFUSED: $id has unlanded work. Confirm it landed, or pass --force only with explicit discard authority."
      fi
      # Untracked non-ignored files could be forgotten work; fail closed.
      untracked="$(dm_untracked "$wt")"
      if [ -n "$untracked" ]; then
        dm_die "REFUSED: $id worktree has untracked files (forgotten work, or build cruft the repo should ignore). Review/clean them, or pass --force. Files:
$untracked"
      fi
    fi
    dir="$(dm_repo_dir "$repo")"
    git -C "$dir" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git -C "$dir" worktree prune 2>/dev/null || true
    dm_meta_set "$id" worktree ""
    dm_info "removed worktree for $id"
    ;;

  list)
    while IFS= read -r id; do
      wt="$(dm_meta_get "$id" worktree)"
      [ -n "$wt" ] && printf '%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" repo)" "$wt"
    done < <(dm_all_task_ids)
    ;;

  *)
    echo "usage: dm-worktree.sh {create|assert|tangle|landed|remove|list} ..." >&2; exit 2 ;;
esac

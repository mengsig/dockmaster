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
#                                    Refuses a <repo> resolving to the distro root;
#                                    the reserved name `dockmaster` is the one
#                                    exemption, for its own PR path (#119).
#                                    Prints exactly two stdout lines: `base: <ref>
#                                    @<sha>` then the worktree path. Every caller
#                                    consumes only the LAST line -- treat that as
#                                    the contract, not just today's convention.
#   assert <path> <repo>            verify <path> is a real worktree root distinct
#                                    from the primary clone (isolation invariant)
#   landed <id> [--json]            is the worktree's committed work landed?
#                                    (exit 0 landed, 1 unlanded, 2 undeterminable)
#                                    --json ALWAYS exits 0 when the question was
#                                    answered and carries `state` in the object:
#                                    landed|unlanded|undetermined.
#   remove <id> [--force]           remove worktree; refuses on a missing scout
#                                    report, unlanded work, an undeterminable
#                                    git state, or untracked files. --force
#                                    discards (explicit operator authority) and
#                                    unsticks a task whose git worktree record is
#                                    broken or whose directory is already gone.
#                                    A discarded head that was not proven landed
#                                    is parked at refs/dm-discarded/<id>/<sha> in
#                                    the clone, so the commit survives gc — on
#                                    both force paths, including the one that
#                                    prunes a vanished worktree's admin record.
#   list [--json]                   list task worktrees
#   tangle <repo> [--json]          is the primary clone tangled onto a feature branch?
#                                    Human form: prints a TANGLE: line and exits 1
#                                    when it is. --json ALWAYS exits 0 when the
#                                    clone could be read, and answers in the
#                                    object - a reader cannot otherwise tell
#                                    "on a side branch" from "the script failed".

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git
dm_ensure_dirs
# Validate in the MAIN shell: dm_repo_dir resolves the clone through a nested
# command substitution, where a dm_die exits only the inner subshell — the
# refusal would be printed, swallowed, and `dir` would fall back to DM_HOME
# (itself a git repo), attaching a worker's copy to the distro root.
dm_registry_require_valid

# DM_WT (the managed worktree root) is a dm-lib layout constant: the same path
# is how git's admin record is keyed, and dm-trash.sh reads that record too.
mkdir -p "$DM_WT"

# --- isolation assertion: the load-bearing safety invariant ------------------
assert_isolated() {
  local path="$1" repo="$2" primary primary_dir top
  path="$(cd "$path" 2>/dev/null && pwd -P)" || dm_die "worktree path does not exist: $1"
  # Resolve in its own step: nested in the `cd` substitution, a resolver dm_die
  # does not propagate — it yielded an empty primary, and an empty primary can
  # never equal $top, so the isolation assertion would PASS on a lookup failure.
  primary_dir="$(dm_repo_dir "$repo")" \
    || dm_die "cannot verify isolation: repo '$repo' did not resolve"
  primary="$(cd "$primary_dir" && pwd -P)" || dm_die "primary clone path does not exist: $primary_dir"
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  top="$(cd "$top" 2>/dev/null && pwd -P || true)"
  [ -n "$top" ] || dm_die "not inside a git worktree: $path"
  [ "$top" = "$path" ] || dm_die "path is not a worktree root: $path (root is $top)"
  [ "$top" != "$primary" ] || dm_die "REFUSED: task path equals the primary clone ($primary); crew work must be isolated"
  printf '%s\n' "$top"
}

require_managed_worktree() {
  local id="$1" recorded expected recorded_real expected_real
  recorded="$(dm_require_worktree "$id")"
  expected="$DM_WT/$id"
  [ -d "$expected" ] || dm_die "REFUSED: managed worktree path does not exist for $id: $expected"
  recorded_real="$(cd "$recorded" 2>/dev/null && pwd -P)" \
    || dm_die "REFUSED: cannot canonicalize recorded worktree path for $id: $recorded"
  expected_real="$(cd "$expected" 2>/dev/null && pwd -P)" \
    || dm_die "REFUSED: cannot canonicalize managed worktree path for $id: $expected"
  [ "$recorded_real" = "$expected_real" ] \
    || dm_die "REFUSED: recorded worktree path for $id does not match managed path $expected_real: $recorded_real"
  printf '%s\n' "$expected_real"
}

# Normal removal: assert isolation, then let git drop its own admin record.
# Both steps die on failure; the caller catches that via command substitution.
git_remove_worktree() {
  local wt="$1" repo="$2" dir="$3"
  assert_isolated "$wt" "$repo" >/dev/null
  git -C "$dir" worktree remove --force "$wt"
}

# The parked-head ref layout is owned by dm-lib (dm_discard_ref /
# dm_ref_component): dm-trash.sh verifies the same path before it reports the
# work recoverable, so the composition must have exactly one owner.

# Discards were once parked FLAT at refs/dm-discarded/<id>. A ref living at that
# path is a git D/F conflict: nothing can be created beneath it, so upgrading to
# the nested refs/dm-discarded/<id>/<sha> layout left parking permanently broken
# for that id (#145). Move the old head into the nested layout, once.
# Returns 0 when the parent path is clear to park under, 1 when it is not.
migrate_flat_discard_ref() {
  local id="$1" dir="$2" flat old out
  flat="$(dm_discard_ref "$id")"
  old="$(git -C "$dir" rev-parse --verify --quiet "$flat" 2>/dev/null)" || return 0
  [ -n "$old" ] || return 0
  # Delete before create: the nested path cannot exist while the flat ref does.
  # The old head is unreferenced only between these two calls, and a failed
  # re-park restores the flat ref rather than leaving the commit unnamed.
  if ! out="$(git -C "$dir" update-ref -d "$flat" "$old" 2>&1)"; then
    dm_warn "cannot clear $id's legacy discard ref $flat ($(dm_first_line "${out:-no error detail from git}")); parking under it stays blocked"
    return 1
  fi
  # STDERR only: the caller's stdout is its parked-sha return value.
  if out="$(git -C "$dir" update-ref "$flat/$old" "$old" 2>&1)"; then
    dm_warn "$id: legacy discard ref $flat moved to $flat/$old (the old flat layout blocked parking)"
    return 0
  fi
  dm_warn "could not re-park $id's legacy discarded head $old under $flat ($(dm_first_line "${out:-no error detail from git}")); restoring the legacy ref"
  git -C "$dir" update-ref "$flat" "$old" 2>/dev/null \
    || dm_warn "could not restore $flat either; recover $old with: git -C $dir branch recovered-$id $old"
  return 1
}

# Park <sha> on a ref in the CLONE (shared object store) so a discarded commit
# stays reachable and survives gc. Keyed by sha, not id alone: ids are reusable
# and refs/dm-discarded/* gets no reflog, so a per-id ref would clobber an
# earlier discard into unreachability. Prints the sha when parked, nothing
# otherwise — every failure warns.
park_discarded_head() {
  local id="$1" dir="$2" head="$3" ref out
  [ -n "$head" ] || return 0
  # All-zeros is git's "no object" oid (unborn/corrupt HEAD). update-ref reads it
  # as DELETE and exits 0, so parking would create nothing while the note claimed
  # a ref. Length-agnostic so it holds for sha256 too.
  case "$head" in
    *[!0]*) ;;
    *) dm_warn "cannot park $id's discarded head: git reports an unborn or unresolvable HEAD ($head); there is no commit to preserve"; return 0 ;;
  esac
  ref="$(dm_discard_ref "$id" "$head")"
  if ! git check-ref-format "$ref" 2>/dev/null; then
    dm_warn "cannot park $id's discarded head $head: '$ref' is not a valid ref name; the commit may be unreachable after gc"
    return 0
  fi
  # A legacy FLAT ref at the parent path is a git directory/file conflict that
  # blocks every nested create beneath it. Migrate it first, or this park fails.
  migrate_flat_discard_ref "$id" "$dir" || true
  if ! out="$(git -C "$dir" update-ref "$ref" "$head" 2>&1)"; then
    dm_warn "could not park $id's discarded head $head on $ref ($(dm_first_line "${out:-no error detail from git}")); the commit may be unreachable after gc"
    return 0
  fi
  printf '%s\n' "$head"
}

# Work not proven landed is about to be deleted. A detached worktree's reflog
# dies with its directory, so park HEAD before anything is removed.
#
# An unreadable in-worktree HEAD (deleted/corrupt `.git` file) is NOT "no
# commit": the clone's admin record still names the head, and the object is
# still in the clone. Falling back to it is what stops a real commit from being
# discarded with no recovery ref at all. Same lookup ORDER as
# clear_missing_worktree: derived managed path first, stored path second.
preserve_discarded_head() {
  local id="$1" wt="$2" dir="$3" head
  head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" || head=""
  if [ -z "$head" ]; then
    head="$(dm_admin_worktree_head "$dir" "$DM_WT/$id")"
    [ -n "$head" ] || head="$(dm_admin_worktree_head "$dir" "$wt")"
    [ -z "$head" ] \
      || dm_warn "cannot read HEAD inside $id's worktree; using the head git's own admin record still holds ($head)"
  fi
  [ -n "$head" ] \
    || { dm_warn "cannot read HEAD of $id's worktree, and git's admin record names none; discarding with no recovery ref"; return 0; }
  park_discarded_head "$id" "$dir" "$head"
}

# --force recovery for an interrupted cleanup: the recorded directory is ALREADY
# gone (crash between the rm and the meta clear), so there is nothing to inspect
# or delete. Clears the stale record and prunes git's admin entry — the two
# things that otherwise pin the task at `working` and its whole clone with it.
# Deletes nothing, so it needs no path-confinement check. The prune DOES drop
# the admin record's reference to the commit, so park it first.
clear_missing_worktree() {
  local id="$1" repo="$2" recorded="$3" dir head parked note prune_out
  dir="$(dm_repo_dir "$repo")"
  # Derived key first: $DM_WT/$id is canonical by construction, while a record
  # written before DM_HOME was canonicalized holds a symlinked path that never
  # string-matches git's physical entry. The directory is gone, so the stored
  # path cannot be canonicalized at read time — only used as a fallback.
  head="$(dm_admin_worktree_head "$dir" "$DM_WT/$id")"
  [ -n "$head" ] || head="$(dm_admin_worktree_head "$dir" "$recorded")"
  parked=""
  [ -z "$head" ] || parked="$(park_discarded_head "$id" "$dir" "$head")"
  if ! prune_out="$(git -C "$dir" worktree prune 2>&1)"; then
    dm_warn "clearing $id's stale worktree record, but git worktree prune failed: $(dm_first_line "${prune_out:-no error detail from git}")"
  fi
  note="stale worktree record cleared with operator discard authority; directory was already absent: $recorded"
  if [ -n "$parked" ]; then
    note="$note; head $parked kept at $(dm_discard_ref "$id" "$parked") in the clone"
  elif [ -n "$head" ]; then
    note="$note; head $head could NOT be preserved"
  else
    note="$note; no git record held a head"
  fi
  dm_meta_set "$id" worktree ""
  dm_status_append "$id" discarded "$note"
  dm_info "cleared stale worktree record for $id (directory was already absent: $recorded)"
}

# --force-only fallback when git can no longer remove the worktree (admin record
# destroyed); without it the task pins at `working` forever. Managed path only.
discard_managed_dir() {
  local wt="$1" id="$2" repo="$3" wt_root primary primary_dir
  wt_root="$(cd "$DM_WT" 2>/dev/null && pwd -P)" \
    || dm_die "REFUSED: managed worktree root does not exist: $DM_WT"
  # Resolve then cd, never nested: a dm_repo_dir die inside the cd substitution
  # would not propagate, leaving primary=CWD and defeating the collision check.
  primary_dir="$(dm_repo_dir "$repo")" \
    || dm_die "REFUSED: cannot resolve primary clone for '$repo'; refusing to delete $wt"
  primary="$(cd "$primary_dir" 2>/dev/null && pwd -P)" \
    || dm_die "REFUSED: primary clone for '$repo' does not exist; refusing to delete $wt"
  [ "$wt" = "$wt_root/$id" ] \
    || dm_die "REFUSED: $wt is not the managed worktree path $wt_root/$id; refusing to delete it"
  [ "$wt" != "$primary" ] \
    || dm_die "REFUSED: $wt resolves to the primary clone of '$repo'; refusing to delete it"
  rm -rf "$wt"
}

# --force-only removal of a worktree whose repo no longer resolves (#119): there
# is NO clone, so discard_managed_dir's primary-collision check is inapplicable
# and would die at dm_repo_dir. The confined managed-path check is the essential
# guard and needs no clone — keep it, drop only the clone comparison.
discard_orphan_worktree() {
  local wt="$1" id="$2" wt_root
  wt_root="$(cd "$DM_WT" 2>/dev/null && pwd -P)" \
    || dm_die "REFUSED: managed worktree root does not exist: $DM_WT"
  [ "$wt" = "$wt_root/$id" ] \
    || dm_die "REFUSED: $wt is not the managed worktree path $wt_root/$id; refusing to delete it"
  rm -rf "$wt"
}

# --- tangle detection: named non-default branch checked out in primary -------
tangle_check() {
  local repo="$1" dir def cur
  dir="$(dm_repo_dir "$repo")"
  def="$(dm_default_branch "$dir")"
  # On an unborn HEAD git prints "HEAD" to STDOUT and exits 128, so the old
  # `|| echo HEAD` fallback captured BOTH and reported the branch as "HEAD\nHEAD"
  # — a corrupt diagnostic in exactly the case that needs a clear one (#123).
  # dm-sync.sh already guards the identical call this way.
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  cur="$(dm_first_line "$cur")"
  if [ -z "$cur" ]; then
    echo "TANGLE: cannot read the current branch of '$repo' at $dir; the clone is unreadable as a git repository"
    return 1
  fi
  if [ "$cur" != "$def" ] && [ "$cur" != "HEAD" ]; then
    echo "TANGLE: primary clone of '$repo' is on '$cur', expected '$def'. Return it with: git -C $dir checkout $def"
    return 1
  fi
  return 0
}

# tangle_json <repo> - the same question, as one object, exiting 0 whenever the
# clone COULD be read. The human form's "exit 1 = tangled" is a fine shell
# contract and a trap for a machine reader, which cannot distinguish it from the
# script failing; and the prose it prints names a path and a git command, which
# is not for an operator-facing surface. Only a genuine read failure exits
# nonzero here.
tangle_json() {
  local repo="$1" dir def cur
  dm_need jq
  dir="$(dm_repo_dir "$repo")"
  def="$(dm_default_branch "$dir")"
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  cur="$(dm_first_line "$cur")"
  [ -n "$cur" ] \
    || dm_die "tangle: cannot read the current branch of '$repo' at $dir; the clone is unreadable as a git repository"
  jq -nc --arg repo "$repo" --arg on "$cur" --arg expected "$def" \
    '{repo:$repo, on:$on, expected:$expected, tangled: ($on != $expected and $on != "HEAD")}'
}

# landed_answer <want_json> <id> <state> [<detail>] -- emit the `landed` answer in
# the requested form and exit. The bare form keeps its exit code (0 landed /
# 1 unlanded / 2 undeterminable); --json always exits 0, because those codes are
# ANSWERS and a machine reader cannot tell them from the script having failed.
# The object carries `state` and no derived boolean: a `landed:false` field would
# let "undetermined" be read as "not landed", the very confusion exit 2 exists to
# prevent. Call it from the MAIN shell only — inside $( ) its exit is swallowed.
landed_answer() {
  local want_json="$1" id="$2" state="$3" detail="${4:-}" rc
  case "$state" in
    landed) rc=0 ;;
    unlanded) rc=1 ;;
    undetermined) rc=2 ;;
    *) dm_die "internal: landed_answer got an unknown state '$state'" ;;
  esac
  if [ "$want_json" -eq 1 ]; then
    jq -nc --arg id "$id" --arg state "$state" --arg detail "$detail" \
      '{id:$id, state:$state, detail:$detail}'
    exit 0
  fi
  if [ -n "$detail" ]; then echo "$state: $detail"; else echo "$state"; fi
  exit "$rc"
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
    # The record's repo decides which clone the work lands in and whose merge
    # authority gates it, so `dm-task.sh set` reserves the field — but create
    # WROTE it unconditionally below, which made this the one-command way around
    # that reservation: point a task recorded against a `never` repo at a
    # permissive one, and the land succeeds. The argument may only ever confirm
    # what the record already says.
    recorded_repo="$(dm_meta_get "$id" repo)"
    if [ -n "$recorded_repo" ] && [ "$recorded_repo" != "$repo" ]; then
      dm_die "REFUSED: task '$id' is recorded against repo '$recorded_repo', not '$repo'. A task's repo is fixed when it is created; re-pointing it would land its work in the wrong clone, under the wrong merge authority. Create the worktree for '$recorded_repo', or create a separate task for '$repo'."
    fi
    dir="$(dm_repo_dir "$repo")"
    # THE ONE EXEMPTION to "never operate on the distro" (#119). Cutting a
    # worktree off DM_HOME is exactly how dockmaster ships changes to itself
    # (branch + worktree + its own PR), so the RESERVED distro name is allowed
    # here — and only here. Anything else resolving to the distro root (a
    # hand-edited registry path) is refused. It buys a worktree and nothing more:
    # dm-sync's fast-forward and dm-merge's local land refuse the distro outright.
    if [ "$repo" != "$DM_DISTRO_REPO" ]; then
      dm_assert_not_distro "$dir" "creating a worktree for repo '$repo'"
    fi
    wt="$DM_WT/$id"
    [ -e "$wt" ] && dm_die "worktree already exists: $wt"
    base_label=""
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
      base_label="$base_ref"
    elif [ "$repo" = "$DM_DISTRO_REPO" ]; then
      # The distro's own clone is the one case dm-sync.sh REFUSES to touch (the
      # control plane is the operator's checkout; moving it unattended is the
      # exact thing that must never happen) -- so its local default branch only
      # advances when the operator pulls by hand, and the FF-sync guard below is
      # a permanent no-op here. `fetch` only writes refs; it never touches the
      # checked-out branch, index, or working tree, so fetching origin's <def>
      # and cutting a NEW worktree off that commit gets a current base WITHOUT
      # working around the refusal -- the refusal still holds, in full.
      def="$(dm_default_branch "$dir")"
      if [ "${DM_NO_FETCH:-0}" != "1" ]; then
        # A failed fetch must not silently fall back to local main: that
        # silence (a `dm_warn "base may be stale"` nobody read) is exactly what
        # let three tasks branch off a base several commits stale in one day.
        # Fail closed instead of warning and continuing.
        #
        # Fetch into a PRIVATE ref and read the base back from THAT ref, so the
        # ref read is the ref this fetch wrote. Both alternatives can lie:
        # origin/<def> is left stale by a hand-narrowed remote.origin.fetch even
        # when the explicit fetch succeeds, and FETCH_HEAD is one scratch file
        # per clone that ANY fetch rewrites -- `create --base`, dm-merge's
        # stacked-child rebase and the operator's own `git fetch origin
        # some-branch` all target this same clone, and one landing between the
        # fetch and the read hands back an unrelated branch tip labelled
        # origin/<def> (reproduced, not theorised). refs/dm/ is not a branch, a
        # tag or a remote-tracking ref, so nothing in the checkout moves.
        git -C "$dir" fetch --quiet origin "+refs/heads/$def:refs/dm/base/$def" \
          || dm_die "could not fetch origin/$def for the distro's own worktree (offline, no remote, or auth failure). Refusing to cut a worktree off a base that cannot be verified current -- retry once network/auth is restored."
        base="$(git -C "$dir" rev-parse --verify --quiet "refs/dm/base/$def")" \
          || dm_die "fetch of origin/$def succeeded but refs/dm/base/$def did not resolve; cannot verify a fetched commit for the distro's own worktree"
        base_label="origin/$def"
        # A successful, current fetch only proves origin/<def> is known --
        # it says nothing about whether the operator's LOCAL <def> already
        # carries commits origin doesn't have (a hand commit, a local merge).
        # Basing the worktree on the fetched commit would then silently drop
        # them: the same loss class this fix exists to prevent, running the
        # other way. Refuse rather than warn -- a warning nobody reads is
        # exactly the failure mode this task replaced.
        #
        # Name the branch by its full refs/heads/ path, the same way dm-sync.sh
        # does: `rev-parse main` searches refs/tags/ BEFORE refs/heads/, so a tag
        # named after the default branch answers this question about the tag and
        # lets the operator's unpushed commits through unprotected.
        if git -C "$dir" show-ref --verify --quiet "refs/heads/$def" \
          && ! git -C "$dir" merge-base --is-ancestor "refs/heads/$def" "$base" 2>/dev/null; then
          dm_die "$repo: local '$def' carries commits not on origin/$def (diverged or ahead of origin) -- cutting a worktree off origin/$def would silently drop them. Reconcile '$def' with origin by hand (push, rebase, or fast-forward), then retry."
        fi
      else
        # DM_NO_FETCH=1 (offline/smoke): no network is permitted here either, so
        # neither the freshness fetch nor the divergence check above can run --
        # same escape hatch as the non-distro path below. Prefer a
        # previously-fetched origin/<def>; fall back to the local branch only
        # if nothing was ever fetched. Both are addressed by full ref path for
        # the same reason as the divergence guard above -- a tag named after the
        # default branch must not decide where a worktree gets cut.
        if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$def"; then
          base_label="origin/$def"
          base_ref_path="refs/remotes/origin/$def"
        else
          base_label="$def"
          base_ref_path="refs/heads/$def"
        fi
        base="$(git -C "$dir" rev-parse --verify --quiet "$base_ref_path")" \
          || dm_die "$base_label does not resolve in $dir; cannot determine a base for the distro's own worktree"
      fi
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
        # "base may be stale" (a warn, not fail-closed — no divergence was found;
        # the repo isn't the distro, so a SKIP here means no origin remote, an
        # unborn branch, etc., not the control-plane refusal above).
        sync_out="$("$(dirname "${BASH_SOURCE[0]}")/dm-sync.sh" one "$repo")" || sync_out="STUCK: sync failed unexpectedly"
        dm_sync_reaction "$repo" "$sync_out" die
      fi
      def="$(dm_default_branch "$dir")"
      # Branch from the LOCAL default: it holds local-only landings and is kept
      # fast-forwarded to origin for PR repos by dm-sync. Fall back to origin.
      base="$(git -C "$dir" rev-parse --verify --quiet "$def" 2>/dev/null || git -C "$dir" rev-parse "origin/$def")"
      base_label="$def"
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
    # State the actual base PLAINLY. A warning read past ("base may be stale")
    # is exactly how several tasks silently branched off a stale base in one
    # day -- this line, not a softened warning, is the fix for that half of
    # the bug.
    dm_info "base: $base_label @$(git -C "$dir" rev-parse --short "$base")"
    dm_info "$wt"
    ;;

  assert)
    path="${1:-}"; repo="${2:-}"
    [ -n "$path" ] && [ -n "$repo" ] || dm_die "usage: dm-worktree.sh assert <path> <repo>"
    assert_isolated "$path" "$repo"
    ;;

  tangle)
    repo="${1:-}"; shift 2>/dev/null || true
    [ -n "$repo" ] || dm_die "usage: dm-worktree.sh tangle <repo> [--json]"
    want_json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) want_json=1; shift ;;
        *) dm_die "usage: dm-worktree.sh tangle <repo> [--json]" ;;
      esac
    done
    if [ "$want_json" -eq 1 ]; then tangle_json "$repo"; else tangle_check "$repo"; fi
    ;;

  landed)
    id="${1:-}"; shift 2>/dev/null || true
    [ -n "$id" ] || dm_die "usage: dm-worktree.sh landed <id> [--json]"
    want_json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) want_json=1; shift ;;
        *) dm_die "usage: dm-worktree.sh landed <id> [--json]" ;;
      esac
    done
    [ "$want_json" -eq 0 ] || dm_need jq
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    # Refresh pr_state so an out-of-band merge is reflected in the pr_state
    # fallback below. Best-effort. No-op offline (DM_NO_FETCH) or with no/
    # already-merged PR (dm_should_refresh_pr_state).
    if dm_should_refresh_pr_state "$id"; then
      "$(dirname "${BASH_SOURCE[0]}")/dm-pr.sh" check "$id" >/dev/null 2>&1 || true
    fi
    # Uncommitted tracked changes => not committed => not landed. (Untracked
    # files are handled at teardown.) Exit 2 keeps a git failure out of that.
    if ! tracked_state="$(dm_tracked_state "$wt")"; then
      landed_answer "$want_json" "$id" undetermined "cannot inspect tracked files: $tracked_state"
    fi
    [ "$tracked_state" = clean ] \
      || landed_answer "$want_json" "$id" unlanded "uncommitted changes to tracked files"
    # Exit 2 = COULD NOT DETERMINE, distinct from exit 1 = not landed. `remove`,
    # `dm-task.sh state`, and `dm-status.sh` drift rely on the difference:
    # reporting a failed lookup as "unlanded work" misstates the reason (#84/#119).
    dir="$(dm_repo_dir_or_none "$repo")" \
      || landed_answer "$want_json" "$id" undetermined "cannot resolve repo '$repo' (unregistered, or the registry is unreadable)"
    [ -d "$dir/.git" ] \
      || landed_answer "$want_json" "$id" undetermined "no clone for repo '$repo' (expected $dir)"
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
      landed_answer "$want_json" "$id" landed
    fi
    # Squash-merge rewrites SHAs, so ancestry above cannot see a merged PR. But
    # "a PR merged" is not "THIS head merged": compare against pr_head (#120).
    pr_state="$(dm_meta_get "$id" pr_state)"
    if [ "$pr_state" = "MERGED" ]; then
      merged_head="$(dm_meta_get "$id" pr_head)"
      [ -n "$merged_head" ] \
        || landed_answer "$want_json" "$id" undetermined "PR recorded MERGED but no pr_head recorded; cannot prove HEAD is in the merged result"
      git -C "$wt" rev-parse --verify --quiet "$merged_head^{commit}" >/dev/null 2>&1 \
        || landed_answer "$want_json" "$id" undetermined "merged PR head $merged_head is not present in this worktree; cannot compare"
      if [ "$head" = "$merged_head" ] || git -C "$wt" merge-base --is-ancestor "$head" "$merged_head" 2>/dev/null; then
        landed_answer "$want_json" "$id" landed "PR merged"
      fi
      landed_answer "$want_json" "$id" unlanded "HEAD $head is not contained in the merged PR head $merged_head (commits added after the merge)"
    fi
    landed_answer "$want_json" "$id" unlanded "commits not in $def and no merged PR recorded"
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
    repo="$(dm_meta_get "$id" repo)"
    # An interrupted cleanup leaves a recorded path whose directory is already
    # gone. require_managed_worktree dies on that before --force is ever
    # consulted, which pins the task and its clone forever — handle it first.
    recorded="$(dm_meta_get "$id" worktree)"
    if [ -n "$recorded" ] && [ ! -d "$recorded" ]; then
      [ "$force" -eq 1 ] || dm_die "REFUSED: $id's recorded worktree directory is already absent: $recorded
Nothing remains to inspect, so the work cannot be proven landed — an interrupted cleanup leaves exactly this.
If the path is merely unavailable (unmounted volume), restore it and retry. Otherwise re-run with --force (explicit discard authority) to clear the stale record."
      clear_missing_worktree "$id" "$repo" "$recorded"
      exit 0
    fi
    wt="$(require_managed_worktree "$id")"
    kind="$(dm_meta_get "$id" kind)"
    # Runs for EVERY kind so a mutable `kind` cannot switch the gate off (#127),
    # and under --force it decides whether a discard destroyed work (#120).
    landed_rc=0; landed_out="$("$0" landed "$id" 2>&1)" || landed_rc=$?
    if [ "$force" -eq 0 ]; then
      if [ "$kind" = "scout" ] && [ ! -f "$DM_DATA/$id/report.md" ]; then
        dm_die "REFUSED: scout $id has no report at data/$id/report.md. Produce the report, or pass --force only with explicit discard authority."
      fi
      # Three outcomes reported apart: a scout's tracked edits ARE the
      # reproduction, and a git failure is never dirtiness (#84).
      if [ "$landed_rc" -eq 1 ] && [ "$kind" = "scout" ]; then
        dm_die "REFUSED: scout $id has investigation scratch that is not in git history; worktree preserved.
${landed_out:-No detail from the landed check.}
Scratch is expected for a reproduction — confirm data/$id/report.md captures the findings, then pass --force to discard it."
      elif [ "$landed_rc" -eq 1 ]; then
        dm_die "REFUSED: $id has unlanded work; worktree preserved.
${landed_out:-No detail from the landed check.}
Confirm it landed, or pass --force only with explicit discard authority."
      elif [ "$landed_rc" -ne 0 ]; then
        dm_die "REFUSED: cannot determine whether $id's work landed; worktree preserved.
${landed_out:-No detail from the landed check.}
Fix the git error above, or pass --force only with explicit discard authority."
      fi
      # Untracked non-ignored files could be forgotten work; fail closed UNLESS
      # every one is provably-disposable tool cruft (dm_is_disposable_cruft) —
      # then teardown discards only regenerable artifacts and needs no --force.
      if ! untracked="$(dm_untracked "$wt")"; then
        dm_die "REFUSED: cannot inspect untracked files for $id; worktree preserved.
${untracked:-No detail from git.}
Fix the git error above, or pass --force only with explicit discard authority."
      fi
      undisposable=""
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        dm_is_disposable_cruft "$u" && continue
        if [ -z "$undisposable" ]; then undisposable="$u"; else undisposable="$undisposable
$u"; fi
      done <<<"$untracked"
      if [ -n "$undisposable" ]; then
        dm_die "REFUSED: $id worktree has untracked files (forgotten work, or build cruft the repo should ignore). Review/clean them, or pass --force. Files:
$undisposable"
      fi
    fi
    # Stop anything the verify gate left running BEFORE the directory goes: the
    # stop command lives in the worktree, so after removal a leaked app/container
    # (and its browser and browser lease) can no longer be stopped at all. Every
    # refusal above has already passed, so this only runs on a real teardown, and
    # it warns rather than blocks — a task must never pin on a stuck app.
    if [ "$(dm_meta_get "$id" verify_app_state)" != "" ]; then
      "$(dirname "$0")/dm-verify.sh" down "$id" >/dev/null \
        || dm_warn "could not stop the verification app for $id; check for a leftover process or container before removing the worktree"
    fi
    # Resolve the clone tolerantly: removal must not be held hostage by an
    # unregistered/renamed repo, or by a clone that escapes repos/ (#141), or the
    # worktree is uncleanable even with --force and its task pins at `working`
    # (#119). dm_repo_dir would die here.
    #
    # CAPTURE the resolver's reason rather than let it surface: it states its
    # refusal on stderr, and a bare "REFUSED: …" printed by a command that then
    # succeeds reads as a failed teardown. On success it prints only the path, so
    # the merged capture is exactly that. The reason is reported below either way,
    # so nothing is hidden.
    discarded_head=""; resolve_why=""; rd_rc=0
    rd_out="$(dm_repo_dir_or_none "$repo" 2>&1)" || rd_rc=$?
    if [ "$rd_rc" -eq 0 ]; then
      dir="$rd_out"
    else
      dir=""; resolve_why="$(dm_first_line "${rd_out:-repo '$repo' does not resolve}")"
      # Quote the reason, not its framing: this command is reporting why it could
      # not reach a clone, and re-emitting "error:"/"REFUSED:" inside its own line
      # would restate someone else's verdict as this command's.
      resolve_why="${resolve_why#error: }"; resolve_why="${resolve_why#REFUSED: }"
    fi
    if [ -n "$dir" ] && [ -d "$dir/.git" ]; then
      # Park the head BEFORE anything is deleted: after the directory is gone the
      # sha is unrecoverable (detached worktree, its reflog goes with it).
      if [ "$force" -eq 1 ] && [ "$landed_rc" -ne 0 ]; then
        discarded_head="$(preserve_discarded_head "$id" "$wt" "$dir")"
      fi
      if ! remove_out="$(git_remove_worktree "$wt" "$repo" "$dir" 2>&1)"; then
        if [ "$force" -eq 0 ]; then
          dm_die "REFUSED: git could not remove $id's worktree; directory and metadata preserved.
${remove_out:-No error detail from git.}
Inspect $wt. If its git record is broken or the work is expendable, re-run with --force (explicit discard authority) to delete the managed directory."
        fi
        dm_warn "git could not remove $id's worktree (${remove_out:-no error detail from git}); discarding $wt under operator discard authority"
        discard_managed_dir "$wt" "$id" "$repo"
      fi
      if ! prune_out="$(git -C "$dir" worktree prune 2>&1)"; then
        dm_warn "worktree removed for $id, but git worktree prune failed: ${prune_out:-no error detail from git}"
      fi
    else
      # No clone to park into, remove through, or prune. The commit lived only in
      # that clone's object store, so it CANNOT be preserved — refuse without
      # --force (the landed_rc=2 refusal above already covers the unforced path),
      # then delete only after re-confirming the confined managed path (#119).
      [ "$force" -eq 1 ] || dm_die "REFUSED: cannot resolve repo '$repo' to remove $id's worktree: ${resolve_why:-no clone resolved}
Its commit cannot be preserved without the clone. Re-run with --force (explicit discard authority) to discard the managed directory."
      discard_orphan_worktree "$wt" "$id"
      dm_warn "removed $id's worktree directly: ${resolve_why:-repo '$repo' does not resolve}; no clone to park its head into or prune its admin entry, so any discarded commit could not be preserved"
    fi
    dm_meta_set "$id" worktree ""
    # Written here, not via dm-task.sh event, to bar forgery. Skipped only when
    # merge-signalled AND proven landed: else task pins (#69) or loss is silent (#120).
    if [ "$force" -eq 1 ]; then
      merge_signal=0
      if [ "$(dm_meta_get "$id" pr_state)" = "MERGED" ] \
         || grep -qE '^[^ ]+ merged: ' "$(dm_status_path "$id")" 2>/dev/null; then merge_signal=1; fi
      discard_note="worktree force-removed with operator discard authority"
      if [ "$landed_rc" -ne 0 ]; then
        discard_note="$discard_note; work not proven landed: ${landed_out##*$'\n'}"
        if [ -n "$discarded_head" ]; then
          discard_note="$discard_note; head $discarded_head kept at $(dm_discard_ref "$id" "$discarded_head") in the clone"
        else
          discard_note="$discard_note; head could NOT be preserved"
        fi
      fi
      if [ "$merge_signal" -eq 0 ] || [ "$landed_rc" -ne 0 ]; then
        dm_status_append "$id" discarded "$discard_note"
      fi
    fi
    dm_info "removed worktree for $id"
    ;;

  list)
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        *) dm_die "unknown flag: $1 (usage: dm-worktree.sh list [--json])" ;;
      esac
    done
    if [ "$json" -eq 1 ]; then
      dm_need jq
      # Same selection as the human list (a recorded worktree), plus whether the
      # directory is still there — a record whose directory vanished is the
      # interrupted-cleanup shape `remove` reports on.
      rows="$(while IFS= read -r id; do
        wt="$(dm_meta_get "$id" worktree)"
        [ -n "$wt" ] || continue
        if [ -d "$wt" ]; then exists=true; else exists=false; fi
        jq -c -n --arg id "$id" --arg repo "$(dm_meta_get "$id" repo)" \
          --arg path "$wt" --argjson exists "$exists" \
          '{id:$id,repo:$repo,path:$path,exists:$exists}'
      done < <(dm_all_task_ids))"
      printf '%s' "$rows" | jq -c -s '.'
      exit 0
    fi
    while IFS= read -r id; do
      wt="$(dm_meta_get "$id" worktree)"
      [ -n "$wt" ] && printf '%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" repo)" "$wt"
    done < <(dm_all_task_ids)
    ;;

  *)
    echo "usage: dm-worktree.sh {create|assert|tangle|landed|remove|list} ..." >&2; exit 2 ;;
esac

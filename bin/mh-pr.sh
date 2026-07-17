#!/usr/bin/env bash
# mh-pr.sh - open, check, and merge pull requests. The ONLY sanctioned PR path.
#
# Guards (fail closed, before any side effect):
#   - task id and PR url/number are validated before any network or state write.
#   - merge REFUSES a red or pending PR ("never merge red") and REFUSES an
#     already-merged/closed PR.
#   - PR data is recorded into task meta; it is never interpolated into shell.
#   - repository is derived from the clone's origin, never from caller input.
#
# Explicit merge AUTHORITY (captain approval / standing yolo) is enforced by the
# manhandler one layer up, per AGENTS.md. This script enforces mechanics only.
#
# Commands:
#   open  <id> --title T (--body-file F | --body B) [--base B] [--draft]
#   check <id>                    refresh pr_state + checks into meta; print summary
#   merge <id> [--method squash|merge|rebase] [--delete-branch]
#   url   <id>                    print recorded PR url

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need git; mh_need gh-axi; mh_need jq
mh_ensure_dirs

repo_dir() { local d; d="$MH_HOME/$(mh_registry_get "$1" path)"; [ -d "$d/.git" ] || mh_die "no clone for repo '$1'"; printf '%s\n' "$d"; }

owner_repo() {
  # derive owner/repo from a git remote url (ssh or https), strictly
  local url="$1" slug
  slug="$(printf '%s' "$url" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
  case "$slug" in
    */*) : ;; *) mh_die "cannot parse owner/repo from remote: $url" ;;
  esac
  # reject anything that is not owner/repo of safe chars
  case "$slug" in *[!A-Za-z0-9._/-]*) mh_die "unsafe characters in owner/repo: $slug" ;; esac
  printf '%s\n' "$slug"
}

pr_number_from_url() {
  # strict canonical parse: https://github.com/<owner>/<repo>/pull/<n>
  local url="$1"
  printf '%s' "$url" | grep -qE '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*$' \
    || mh_die "not a canonical PR url: $url"
  printf '%s' "$url" | sed -E 's#.*/pull/##'
}

# Combine two CI rollups, worst-wins, in precedence:
#   failing > unknown > pending > passing > none
# `unknown` ranks above `pending` so an API error is never silently treated as
# mergeable; `none` (no signal at all) ranks lowest.
rollup_rank() {
  case "$1" in
    failing) echo 4 ;; unknown) echo 3 ;; pending) echo 2 ;;
    passing) echo 1 ;; none) echo 0 ;; *) echo 3 ;;
  esac
}
worst_rollup() {
  if [ "$(rollup_rank "$1")" -ge "$(rollup_rank "$2")" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  open)
    id="${1:-}"; shift || true
    [ -n "$id" ] || mh_die "usage: mh-pr.sh open <id> --title T (--body-file F | --body B) [--base B] [--draft]"
    mh_require_id "$id"
    title=""; body_file=""; body=""; base=""; draft=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --body) body="${2:-}"; shift 2 ;;
        --base) base="${2:-}"; shift 2 ;;
        --draft) draft=1; shift ;;
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    [ -n "$title" ] || mh_die "--title is required"
    wt="$(mh_meta_get "$id" worktree)"; repo="$(mh_meta_get "$id" repo)"
    [ -n "$wt" ] && [ -d "$wt" ] || mh_die "no worktree for $id"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
    [ "$branch" != "HEAD" ] || mh_die "worktree is on a detached HEAD; crewmate must create a branch first"
    ! mh_tracked_dirty "$wt" || mh_die "worktree has uncommitted changes to tracked files; commit before opening a PR"
    dir="$(repo_dir "$repo")"; slug="$(owner_repo "$(git -C "$dir" remote get-url origin)")"
    [ -n "$base" ] || base="$(mh_default_branch "$dir")"
    mh_info "pushing $branch -> origin"
    git -C "$wt" push -u origin "$branch" >/dev/null 2>&1 || git -C "$wt" push origin "$branch"
    args=(pr create -R "$slug" --title "$title" --base "$base" --head "$branch")
    if [ -n "$body_file" ]; then args+=(--body-file "$body_file")
    elif [ -n "$body" ]; then args+=(--body "$body")
    else args+=(--body ""); fi
    [ "$draft" -eq 1 ] && args+=(--draft)
    out="$(gh-axi "${args[@]}")" || mh_die "pr create failed"
    url="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' | head -n1)"
    [ -n "$url" ] || mh_die "could not determine PR url from output"
    mh_meta_set "$id" branch "$branch"
    mh_meta_set "$id" pr "$url"
    mh_status_append "$id" done "PR $url"
    mh_info "$url"
    ;;

  check)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-pr.sh check <id>"
    url="$(mh_meta_get "$id" pr)"; [ -n "$url" ] || mh_die "no PR recorded for $id"
    n="$(pr_number_from_url "$url")"; repo="$(mh_meta_get "$id" repo)"
    slug="$(owner_repo "$(git -C "$(repo_dir "$repo")" remote get-url origin)")"
    json="$(gh-axi api "repos/$slug/pulls/$n" 2>/dev/null)" || mh_die "could not read PR $url"
    state="$(printf '%s' "$json" | jq -r '.state // "unknown" | ascii_upcase')"
    merged="$(printf '%s' "$json" | jq -r '.merged // false')"
    sha="$(printf '%s' "$json" | jq -r '.head.sha // empty')"
    [ "$merged" = "true" ] && state="MERGED"
    # Roll up CI for the head sha from BOTH the check-runs API and the legacy
    # combined commit-status API, worst-wins. A repo whose CI reports only via
    # commit statuses returns an empty check-runs array; taking that alone as
    # "none" would let a red PR merge (violating "never merge red").
    runs_rollup="none"; status_rollup="none"
    if [ -n "$sha" ]; then
      runs_rollup="$(gh-axi api "repos/$slug/commits/$sha/check-runs" 2>/dev/null \
        | jq -r 'if (.check_runs|length)==0 then "none"
                 elif any(.check_runs[]; .conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out") then "failing"
                 elif any(.check_runs[]; .status!="completed") then "pending"
                 else "passing" end' 2>/dev/null || echo unknown)"
      # GitHub returns .state=="pending" even with ZERO statuses, so treat
      # total_count==0 as "none" (no signal), not pending.
      status_rollup="$(gh-axi api "repos/$slug/commits/$sha/status" 2>/dev/null \
        | jq -r 'if ((.total_count // 0) == 0) then "none"
                 elif (.state=="failure" or .state=="error") then "failing"
                 elif (.state=="success") then "passing"
                 else "pending" end' 2>/dev/null || echo unknown)"
    fi
    rollup="$(worst_rollup "$runs_rollup" "$status_rollup")"
    # mergeable_state (clean/blocked/unstable/dirty/behind/draft/unknown) gates
    # the merge alongside CI; GitHub often reports "unknown" on first fetch.
    merge_state="$(printf '%s' "$json" | jq -r '.mergeable_state // "unknown"')"
    mh_meta_set "$id" pr_state "$state"
    mh_meta_set "$id" checks "$rollup"
    mh_meta_set "$id" merge_state "$merge_state"
    [ -n "$sha" ] && mh_meta_set "$id" pr_head "$sha"
    echo "pr: $url · state: $state · checks: $rollup · merge_state: $merge_state"
    ;;

  merge)
    id="${1:-}"; shift || true
    [ -n "$id" ] || mh_die "usage: mh-pr.sh merge <id> [--method squash|merge|rebase] [--delete-branch]"
    method="squash"; delete=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --method) method="${2:-}"; shift 2 ;;
        --delete-branch) delete=1; shift ;;
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    case "$method" in squash|merge|rebase) ;; *) mh_die "method must be squash|merge|rebase" ;; esac
    url="$(mh_meta_get "$id" pr)"; [ -n "$url" ] || mh_die "no PR recorded for $id"
    # refresh state, then guard
    "$0" check "$id" >/dev/null
    state="$(mh_meta_get "$id" pr_state)"; checks="$(mh_meta_get "$id" checks)"
    merge_state="$(mh_meta_get "$id" merge_state)"
    [ "$state" = "MERGED" ] && mh_die "PR already merged: $url"
    [ "$state" = "CLOSED" ] && mh_die "PR is closed, refusing to merge: $url"
    case "$checks" in
      failing) mh_die "REFUSED: PR has failing checks (never merge red): $url" ;;
      pending) mh_die "REFUSED: PR checks still running: $url" ;;
      passing|none) : ;;
      *) mh_die "REFUSED: could not confirm check status ($checks): $url" ;;
    esac
    # mergeable_state gate. Refuse a conflicted, draft, or branch-protection-
    # blocked PR. Do NOT refuse solely on "unknown" (GitHub often hasn't computed
    # it on first fetch); the gh pr merge failure path is the remaining backstop.
    case "$merge_state" in
      dirty)   mh_die "REFUSED: PR has merge conflicts (mergeable_state=dirty): $url" ;;
      draft)   mh_die "REFUSED: PR is a draft (mergeable_state=draft): $url" ;;
      blocked) mh_die "REFUSED: required checks/reviews not satisfied (mergeable_state=blocked): $url" ;;
      *) : ;;
    esac
    n="$(pr_number_from_url "$url")"; repo="$(mh_meta_get "$id" repo)"
    slug="$(owner_repo "$(git -C "$(repo_dir "$repo")" remote get-url origin)")"
    args=(pr merge "$n" -R "$slug" "--$method")
    [ "$delete" -eq 1 ] && args+=(--delete-branch)
    gh-axi "${args[@]}" || mh_die "merge failed"
    mh_meta_set "$id" pr_state MERGED
    mh_status_append "$id" merged "$url"
    mh_info "merged: $url"
    ;;

  url)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-pr.sh url <id>"
    mh_meta_get "$id" pr ;;

  *)
    echo "usage: mh-pr.sh {open|check|merge|url} ..." >&2; exit 2 ;;
esac

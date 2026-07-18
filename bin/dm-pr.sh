#!/usr/bin/env bash
# dm-pr.sh - open, check, and merge pull requests. The ONLY sanctioned PR path.
#
# Guards (fail closed, before any side effect):
#   - task id and PR url/number are validated before any network or state write.
#   - merge REFUSES a red or pending PR ("never merge red") and REFUSES an
#     already-merged/closed PR.
#   - PR data is recorded into task meta; it is never interpolated into shell.
#   - repository is derived from the clone's origin, never from caller input.
#
# Explicit merge AUTHORITY (captain approval / standing yolo) is enforced by the
# dockmaster one layer up, per AGENTS.md. This script enforces mechanics only.
#
# GitHub access splits by need: reads that are parsed by jq use `gh api` (it
# returns real JSON), while mutations use `gh-axi` (`gh-axi api` emits a
# YAML-like format that jq cannot parse).
#
# Commands:
#   open  <id> --title T (--body-file F | --body B) [--base B] [--draft]
#   adopt <id> <url>              record a PR opened out of band (e.g. direct-pr
#                                 mode, a revert PR): validates the url is a
#                                 canonical GitHub PR url for the task's own
#                                 repo, then records it and queries real state
#   check <id>                    refresh pr_state + checks into meta; print summary
#   await-checks <id> [--timeout-secs N] [--interval-secs N]
#                                 poll check until the CI rollup is terminal
#                                 (a `none` rollup keeps polling, not terminal,
#                                 when the repo has CI configured)
#   merge <id> [--method squash|merge|rebase] [--delete-branch]
#   sweep                         read-only fleet sweep: every task with an open
#                                 PR, its CI rollup + whether a review requests
#                                 changes (offline under DM_NO_FETCH: cached only)
#   security-scan <id>            grep the diff for security-surface signals
#   url   <id>                    print recorded PR url

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
# git+jq are needed by every command (registry, worktree, diffs). The GitHub
# tools (gh-axi/gh) are checked per-command below, so the local-only commands
# (security-scan, url) run without them.
dm_need git; dm_need jq
dm_ensure_dirs

# await-checks polling defaults (named once): wait up to ~10 minutes, re-checking
# every ~15s. GitHub Actions runs are minutes long, so a short interval mostly
# sleeps; both are overridable per call.
AWAIT_TIMEOUT_SECS=600
AWAIT_INTERVAL_SECS=15

owner_repo() {
  # derive owner/repo from a git remote url (ssh or https), strictly
  local url="$1" slug
  slug="$(printf '%s' "$url" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
  case "$slug" in
    */*) : ;; *) dm_die "cannot parse owner/repo from remote: $url" ;;
  esac
  # reject anything that is not owner/repo of safe chars
  case "$slug" in *[!A-Za-z0-9._/-]*) dm_die "unsafe characters in owner/repo: $slug" ;; esac
  printf '%s\n' "$slug"
}

repo_slug() {
  # repo_slug <repo>  -> owner/repo derived from the managed clone's origin
  # remote. Single owner (file-local) of a pattern repeated at every call site
  # that needs GitHub's owner/repo slug for a task's repo.
  owner_repo "$(git -C "$(dm_repo_dir "$1")" remote get-url origin)"
}

pr_number_from_url() {
  # strict canonical parse: https://github.com/<owner>/<repo>/pull/<n>
  local url="$1"
  grep -qE '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*$' <<<"$url" \
    || dm_die "not a canonical PR url: $url"
  printf '%s' "$url" | sed -E 's#.*/pull/##'
}

pr_repo_slug_from_url() {
  # owner/repo a (already-canonical) PR url belongs to, reusing owner_repo by
  # stripping the "/pull/<n>" suffix down to a plain repo url first.
  owner_repo "$(printf '%s' "$1" | sed -E 's#/pull/[0-9]+$##')"
}

task_has_ci() {
  # task_has_ci <id>  -> exit 0 if the task's repo has CI configured
  # (.github/workflows present), checked in the worktree first so a workflow
  # file added on the crewmate's branch but not yet in the managed clone still
  # counts, else the clone. Single owner of this detection so merge and
  # await-checks cannot drift apart on what "has CI" means.
  local id="$1" repo wt
  repo="$(dm_meta_get "$id" repo)"
  wt="$(dm_meta_get "$id" worktree)"
  # `if`, not a bare `[ ... ] && [ ... ] && return 0`: under set -e a false
  # first test would abort this function's CALLER outright (a standalone list
  # whose exit status is nonzero), not just fall through to the next line.
  if [ -n "$wt" ] && [ -d "$wt/.github/workflows" ]; then
    return 0
  fi
  [ -d "$(dm_repo_dir "$repo")/.github/workflows" ]
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
    [ -n "$id" ] || dm_die "usage: dm-pr.sh open <id> --title T (--body-file F | --body B) [--base B] [--draft]"
    dm_require_id "$id"
    # A local-only task never opens a PR — that path lands by fast-forward via
    # dm-merge.sh local. Refuse here (before any GitHub tool or push) so the
    # wrong delivery path fails fast with the right instruction.
    mode="$(dm_meta_get "$id" mode)"
    [ "$mode" = "local-only" ] && dm_die "task $id is mode 'local-only'; a PR is not its delivery path — land it with: dm-merge.sh local $id"
    title=""; body_file=""; body=""; base=""; draft=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --body) body="${2:-}"; shift 2 ;;
        --base) base="${2:-}"; shift 2 ;;
        --draft) draft=1; shift ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    [ -n "$title" ] || dm_die "--title is required"
    dm_need gh-axi
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
    [ "$branch" != "HEAD" ] || dm_die "worktree is on a detached HEAD; crewmate must create a branch first"
    ! dm_tracked_dirty "$wt" || dm_die "worktree has uncommitted changes to tracked files; commit before opening a PR"
    dir="$(dm_repo_dir "$repo")"; slug="$(repo_slug "$repo")"
    # No explicit --base: default to the recorded parent (a stacked sub-PR
    # created via `dm-worktree.sh create --base`), else the default branch.
    base="$(dm_pr_base_for "$id" "$base" "$dir")"
    dm_info "pushing $branch -> origin"
    # The first push (-u) can fail for benign reasons (upstream already set), so
    # retry a plain push. If THAT is rejected — typically a non-fast-forward
    # because the branch was rebased locally and diverged from origin — surface a
    # domain message instead of raw git text. No force is performed: a diverged
    # branch is a signal to reconcile, never to overwrite origin.
    if ! git -C "$wt" push -u origin "$branch" >/dev/null 2>&1; then
      git -C "$wt" push origin "$branch" \
        || dm_die "push rejected — branch '$branch' diverged on origin; was it rebased? no force performed. Reconcile with origin, then retry."
    fi
    args=(pr create -R "$slug" --title "$title" --base "$base" --head "$branch")
    if [ -n "$body_file" ]; then args+=(--body-file "$body_file")
    elif [ -n "$body" ]; then args+=(--body "$body")
    else args+=(--body ""); fi
    [ "$draft" -eq 1 ] && args+=(--draft)
    out="$(gh-axi "${args[@]}")" || dm_die "pr create failed"
    url="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' | head -n1)"
    [ -n "$url" ] || dm_die "could not determine PR url from output"
    dm_meta_set "$id" branch "$branch"
    dm_meta_set "$id" pr "$url"
    dm_status_append "$id" done "PR $url"
    dm_info "$url"
    ;;

  adopt)
    # Record a PR that was opened OUTSIDE dm-pr.sh open (a direct-pr-mode task,
    # or a revert PR per the rollback skill) so the merge gate has something
    # real to check. `pr`/`pr_state`/`merge_state` are write-protected on
    # dm-task.sh set (they're the trusted landing signal); this is the
    # sanctioned writer — validate first, then record via dm_meta_set directly,
    # matching how `open` records `pr` after a real push+create.
    id="${1:-}"; url="${2:-}"
    [ -n "$id" ] && [ -n "$url" ] || dm_die "usage: dm-pr.sh adopt <id> <url>"
    dm_require_id "$id"
    n="$(pr_number_from_url "$url")"
    repo="$(dm_meta_get "$id" repo)"
    [ -n "$repo" ] || dm_die "no such task: $id"
    slug="$(repo_slug "$repo")"
    url_slug="$(pr_repo_slug_from_url "$url")"
    # Refuse a PR that belongs to a different repo than the task's — comparing
    # case-insensitively since GitHub owner/repo names are case-insensitive.
    if [ "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$url_slug" | tr 'A-Z' 'a-z')" ]; then
      dm_die "PR $url belongs to $url_slug, not this task's repo ($slug) — refusing to adopt a PR from a different repo"
    fi
    existing="$(dm_meta_get "$id" pr)"
    if [ -n "$existing" ] && [ "$existing" != "$url" ]; then
      dm_die "task $id already has a different PR recorded ($existing); adopt onto a fresh task id instead"
    fi
    dm_need gh
    dm_meta_set "$id" pr "$url"
    "$0" check "$id"
    dm_status_append "$id" done "adopted PR $url"
    dm_info "adopted $url for task $id"
    ;;

  check)
    dm_need gh
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-pr.sh check <id>"
    url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
    n="$(pr_number_from_url "$url")"; repo="$(dm_meta_get "$id" repo)"
    slug="$(repo_slug "$repo")"
    json="$(gh api "repos/$slug/pulls/$n" 2>/dev/null)" || dm_die "could not read PR $url"
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
      # action_required (needs manual action) counts as failing, not green;
      # stale (result is for an older commit) is inconclusive, so pending.
      runs_rollup="$(gh api "repos/$slug/commits/$sha/check-runs" 2>/dev/null \
        | jq -r 'if (.check_runs|length)==0 then "none"
                 elif any(.check_runs[]; .conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out" or .conclusion=="action_required") then "failing"
                 elif any(.check_runs[]; .status!="completed" or .conclusion=="stale") then "pending"
                 else "passing" end' 2>/dev/null || echo unknown)"
      # GitHub returns .state=="pending" even with ZERO statuses, so treat
      # total_count==0 as "none" (no signal), not pending.
      status_rollup="$(gh api "repos/$slug/commits/$sha/status" 2>/dev/null \
        | jq -r 'if ((.total_count // 0) == 0) then "none"
                 elif (.state=="failure" or .state=="error") then "failing"
                 elif (.state=="success") then "passing"
                 else "pending" end' 2>/dev/null || echo unknown)"
    fi
    rollup="$(worst_rollup "$runs_rollup" "$status_rollup")"
    # mergeable_state (clean/blocked/unstable/dirty/behind/draft/unknown) gates
    # the merge alongside CI; GitHub often reports "unknown" on first fetch.
    merge_state="$(printf '%s' "$json" | jq -r '.mergeable_state // "unknown"')"
    dm_meta_set "$id" pr_state "$state"
    dm_meta_set "$id" checks "$rollup"
    dm_meta_set "$id" merge_state "$merge_state"
    [ -n "$sha" ] && dm_meta_set "$id" pr_head "$sha"
    echo "pr: $url · state: $state · checks: $rollup · merge_state: $merge_state"
    ;;

  await-checks)
    # Poll `check` until the CI rollup is terminal (passing/failing, or none on
    # a confirmed CI-less repo) or the timeout elapses, so a caller (the merge
    # gate, a supervision Monitor) can WAIT for GitHub Actions rather than
    # treating a still-pending PR as a refusal. This does NOT merge and does
    # NOT relax "never merge red": it is a pre-step, and the outcome maps to an
    # exit code the caller acts on.
    dm_need gh
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh await-checks <id> [--timeout-secs N] [--interval-secs N]"
    timeout_secs="$AWAIT_TIMEOUT_SECS"; interval_secs="$AWAIT_INTERVAL_SECS"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout-secs) timeout_secs="${2:-}"; shift 2 ;;
        --interval-secs) interval_secs="${2:-}"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    case "$timeout_secs" in ''|*[!0-9]*) dm_die "--timeout-secs must be a non-negative integer" ;; esac
    case "$interval_secs" in ''|*[!0-9]*) dm_die "--interval-secs must be a non-negative integer" ;; esac
    [ "$interval_secs" -ge 1 ] || dm_die "--interval-secs must be >= 1"
    url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
    # has_ci decides what "none" means below: on a CI-configured repo, `none`
    # right after a PR opens is the race window before Actions has registered
    # any check — not terminal, keep polling. Only a confirmed CI-less repo
    # treats `none` as the (immediate) terminal answer, matching the merge gate's
    # own has_ci-gated treatment of `none` (never used to relax "never merge red").
    if task_has_ci "$id"; then has_ci=1; else has_ci=0; fi
    waited=0
    # Loop checks first, then tests the timeout, so timeout=0 still does exactly
    # one check (a single-shot probe) rather than none.
    while : ; do
      # A transient check failure (a network blip) is non-terminal: keep polling
      # within the timeout rather than aborting the wait. A persistent failure
      # still surfaces — it never reaches a terminal rollup, so it times out
      # (non-zero) with the last-seen rollup reported.
      if "$0" check "$id" >/dev/null 2>&1; then
        checks="$(dm_meta_get "$id" checks)"
      else
        checks="unknown"
      fi
      case "$checks" in
        passing) dm_info "await-checks: passing after ${waited}s: $url"; exit 0 ;;
        none)
          if [ "$has_ci" -eq 0 ]; then
            dm_info "await-checks: none after ${waited}s (repo has no CI configured): $url"; exit 0
          fi
          ;;   # CI configured but no check has registered yet: not terminal, keep waiting
        failing) dm_info "await-checks: FAILING after ${waited}s: $url"; exit 1 ;;
        *) : ;;   # pending / unknown / empty: not terminal, keep waiting
      esac
      if [ "$waited" -ge "$timeout_secs" ]; then
        dm_info "await-checks: TIMED OUT after ${waited}s (last rollup: ${checks:-unknown}): $url"
        exit 1
      fi
      sleep "$interval_secs"
      waited=$((waited + interval_secs))
    done
    ;;

  merge)
    dm_need gh-axi; dm_need gh
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh merge <id> [--method squash|merge|rebase] [--delete-branch] [--allow-no-checks]"
    method="squash"; delete=0; allow_no_checks=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --method) method="${2:-}"; shift 2 ;;
        --delete-branch) delete=1; shift ;;
        --allow-no-checks) allow_no_checks=1; shift ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    case "$method" in squash|merge|rebase) ;; *) dm_die "method must be squash|merge|rebase" ;; esac
    url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
    # refresh state, then guard
    "$0" check "$id" >/dev/null
    state="$(dm_meta_get "$id" pr_state)"; checks="$(dm_meta_get "$id" checks)"
    merge_state="$(dm_meta_get "$id" merge_state)"
    [ "$state" = "MERGED" ] && dm_die "PR already merged: $url"
    [ "$state" = "CLOSED" ] && dm_die "PR is closed, refusing to merge: $url"
    # Never merge red. A `none` rollup (no checks reported) does NOT auto-pass:
    # it is the race window after a PR opens but before CI registers. It passes
    # only on an explicit --allow-no-checks AND a confirmed CI-less repo
    # (has_ci=0): once .github/workflows exists, --allow-no-checks can no
    # longer bypass `none` (closes #49) — a repo that gained CI must wait for
    # it, never merge on a rollup that just hasn't registered yet.
    repo="$(dm_meta_get "$id" repo)"
    # `if` (not a bare `task_has_ci "$id" && has_ci=1`): under set -e, a false
    # exit here is the last statement of this line, so a bare `&&` would abort
    # the merge command itself when the repo simply has no CI.
    if task_has_ci "$id"; then has_ci=1; else has_ci=0; fi
    case "$(dm_merge_gate "$checks" "$allow_no_checks" "$has_ci")" in
      allow) : ;;
      refuse-failing) dm_die "REFUSED: PR has failing checks (never merge red): $url" ;;
      refuse-pending) dm_die "REFUSED: PR checks still running: $url — wait for them with: dm-pr.sh await-checks $id" ;;
      refuse-none)
        if [ "$has_ci" -eq 1 ]; then
          dm_die "REFUSED: no checks reported yet for $url — this repo has CI configured. Wait with: dm-pr.sh await-checks $id"
        else
          dm_die "REFUSED: no checks reported yet for $url — pass --allow-no-checks if this repo has no CI, or wait with: dm-pr.sh await-checks $id"
        fi
        ;;
      *)              dm_die "REFUSED: could not confirm check status ($checks): $url" ;;
    esac
    # mergeable_state gate. Refuse a conflicted, draft, or branch-protection-
    # blocked PR. Do NOT refuse solely on "unknown" (GitHub often hasn't computed
    # it on first fetch); the gh pr merge failure path is the remaining backstop.
    case "$merge_state" in
      dirty)   dm_die "REFUSED: PR has merge conflicts (mergeable_state=dirty): $url" ;;
      draft)   dm_die "REFUSED: PR is a draft (mergeable_state=draft): $url" ;;
      blocked) dm_die "REFUSED: required checks/reviews not satisfied (mergeable_state=blocked): $url" ;;
      *) : ;;
    esac
    n="$(pr_number_from_url "$url")"
    slug="$(repo_slug "$repo")"
    args=(pr merge "$n" -R "$slug" "--$method")
    [ "$delete" -eq 1 ] && args+=(--delete-branch)
    gh-axi "${args[@]}" || dm_die "merge failed"
    dm_meta_set "$id" pr_state MERGED
    dm_status_append "$id" merged "$url"
    dm_info "merged: $url"
    # Best-effort: FF-sync the clone's default branch so it is never left behind
    # by the PR it just merged (reuses dm-sync's FF-only logic). The merge above
    # already completed and is recorded; a can't-FF sync must not fail it - just
    # name the manual fallback. The `|| sync_out=...` guards against dm-sync
    # itself exiting non-zero unexpectedly (under set -e that would otherwise
    # abort this command AFTER the merge was already recorded, misreporting a
    # completed merge as a failed one).
    sync_out="$("$(dirname "${BASH_SOURCE[0]}")/dm-sync.sh" one "$repo")" || sync_out="STUCK: sync failed unexpectedly"
    dm_sync_reaction "$repo" "$sync_out" warn
    ;;

  security-scan)
    # Advisory only: grep the task's diff for security-surface signals and print
    # whether `security-review` should run, so the optional security gate is a
    # deliberate skip rather than a silent one. It NEVER blocks and NEVER decides.
    # Exit code follows grep's sense: 0 = signals found (review recommended),
    # 1 = none found (skip is defensible); a real error (no worktree) dies via
    # dm_die. Local-only: no GitHub tools required.
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-pr.sh security-scan <id>"
    dm_require_id "$id"
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    base="$(dm_default_branch "$(dm_repo_dir "$repo")")"
    # Diff the branch against the default branch when that ref is reachable from
    # the worktree; otherwise fall back to the working diff against HEAD.
    if git -C "$wt" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      diff="$(git -C "$wt" diff "$base"...HEAD 2>/dev/null || true)"
    else
      diff="$(git -C "$wt" diff HEAD 2>/dev/null || true)"
    fi
    # Match on a here-string, not a pipe: `grep -q` on a pipe would SIGPIPE the
    # producer (exit 141), which pipefail reports as failure.
    hits=""
    grep -iEq -- 'auth|login|session|token|secret|password|passwd|credential|api[_-]?key' <<<"$diff" && hits="$hits auth/secrets" || true
    grep -iEq -- 'crypt|encrypt|decrypt|cipher|hmac|\bhash\b|\brsa\b|\baes\b|sha[0-9]|jwt' <<<"$diff" && hits="$hits crypto" || true
    grep -iEq -- 'parse|deserial|unmarshal|unpickle|yaml\.load|json\.load|eval\(|exec\(|subprocess|os\.system|shell=true|system\(' <<<"$diff" && hits="$hits input-parsing" || true
    grep -iEq -- 'https?://|fetch\(|socket|urlopen|requests\.|\bcurl\b|\bsql\b|execute\(|redirect|open\(' <<<"$diff" && hits="$hits external-io" || true
    hits="${hits# }"
    if [ -n "$hits" ]; then
      dm_info "security-scan: signals present ($hits) — run security-review on this diff before merge"
      exit 0
    fi
    dm_info "security-scan: no security-surface signals — a security-review skip is defensible (record it)"
    exit 1
    ;;

  sweep)
    # Fleet PR/health sweep (#26): walk every task that records an OPEN PR and
    # report, one line each, its CI rollup and whether a review is requesting
    # changes, plus a summary. Purely READ-ONLY over GitHub and repos — it opens
    # no PR, pushes nothing, merges nothing. It DOES refresh the cached
    # pr_state/checks meta via `check` (the same cache dm-status trusts), reusing
    # that rollup logic rather than recomputing it.
    #
    # Offline (DM_NO_FETCH=1 — how dm-status invokes it): perform NO network. Show
    # the cached pr_state/checks and skip the review query, matching how
    # dm_should_refresh_pr_state degrades offline.
    offline=0
    [ "${DM_NO_FETCH:-0}" = "1" ] && offline=1
    [ "$offline" -eq 1 ] || dm_need gh
    total=0; red=0; changes=0; missing=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      url="$(dm_meta_get "$id" pr)"
      repo="$(dm_meta_get "$id" repo)"
      # A missing clone skips this PR (its slug/rollup are underivable) but must
      # not abort the whole sweep; surface it per-line, never a silent skip.
      dir="$DM_HOME/$(dm_registry_get "$repo" path)"
      if [ ! -d "$dir/.git" ]; then
        missing=$((missing + 1))
        printf '  %s  (repo clone missing: %s — skipped)  %s\n' "$id" "${repo:-?}" "$url"
        continue
      fi
      if [ "$offline" -eq 1 ]; then
        checks="$(dm_meta_get "$id" checks)"; [ -n "$checks" ] || checks="?"
        state="$(dm_meta_get "$id" pr_state)"; [ -n "$state" ] || state="?"
        printf '  %s  state: %s  checks: %s (cached)  reviews: (no fetch)  %s\n' "$id" "$state" "$checks" "$url"
        case "$checks" in failing) red=$((red + 1)) ;; esac
        continue
      fi
      # Online: refresh the rollup through `check` (single owner of the rollup
      # computation), then read the review state. A failed check is surfaced
      # per-line, never swallowed.
      if ! "$0" check "$id" >/dev/null 2>&1; then
        printf '  %s  (could not read PR — check failed)  %s\n' "$id" "$url"
        continue
      fi
      checks="$(dm_meta_get "$id" checks)"; [ -n "$checks" ] || checks="?"
      state="$(dm_meta_get "$id" pr_state)"; [ -n "$state" ] || state="?"
      n="$(pr_number_from_url "$url")"
      slug="$(repo_slug "$repo")"
      # Unaddressed review = a reviewer whose LATEST actionable review (the last
      # APPROVED/CHANGES_REQUESTED per author) is CHANGES_REQUESTED. jq returns
      # true/false; a null/API error becomes "error" so it reads as unknown, never
      # a false "clean".
      cr="$(gh api "repos/$slug/pulls/$n/reviews" 2>/dev/null \
        | jq -r '[.[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED")]
                 | group_by(.user.login)
                 | map(max_by(.submitted_at).state)
                 | any(. == "CHANGES_REQUESTED")' 2>/dev/null || echo error)"
      case "$cr" in
        true)  review="changes-requested"; changes=$((changes + 1)) ;;
        false) review="clean" ;;
        *)     review="unknown" ;;
      esac
      case "$checks" in failing) red=$((red + 1)) ;; esac
      printf '  %s  state: %s  checks: %s  reviews: %s  %s\n' "$id" "$state" "$checks" "$review" "$url"
    done < <(dm_open_pr_tasks)
    if [ "$total" -eq 0 ]; then
      dm_info "  (no open PRs)"
    else
      note=""
      [ "$red" -gt 0 ] && note="$note, $red with red CI"
      [ "$changes" -gt 0 ] && note="$note, $changes with changes requested"
      [ "$missing" -gt 0 ] && note="$note, $missing with a missing clone"
      note="${note#, }"
      [ -n "$note" ] && note=" ($note)"
      dm_info "  sweep: $total open PR(s)$note"
    fi
    ;;

  url)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-pr.sh url <id>"
    dm_meta_get "$id" pr ;;

  *)
    echo "usage: dm-pr.sh {open|adopt|check|await-checks|merge|sweep|security-scan|url} ..." >&2; exit 2 ;;
esac

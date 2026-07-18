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
# GitHub access splits by need: reads that are parsed by jq use `gh api` (it
# returns real JSON), while mutations use `gh-axi` (`gh-axi api` emits a
# YAML-like format that jq cannot parse).
#
# Commands:
#   open  <id> --title T (--body-file F | --body B) [--base B] [--draft]
#   check <id>                    refresh pr_state + checks into meta; print summary
#   await-checks <id> [--timeout-secs N] [--interval-secs N]
#                                 poll check until the CI rollup is terminal
#   merge <id> [--method squash|merge|rebase] [--delete-branch]
#   sweep                         read-only fleet sweep: every task with an open
#                                 PR, its CI rollup + whether a review requests
#                                 changes (offline under MH_NO_FETCH: cached only)
#   security-scan <id>            grep the diff for security-surface signals
#   url   <id>                    print recorded PR url

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
# git+jq are needed by every command (registry, worktree, diffs). The GitHub
# tools (gh-axi/gh) are checked per-command below, so the local-only commands
# (security-scan, url) run without them.
mh_need git; mh_need jq
mh_ensure_dirs

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
    */*) : ;; *) mh_die "cannot parse owner/repo from remote: $url" ;;
  esac
  # reject anything that is not owner/repo of safe chars
  case "$slug" in *[!A-Za-z0-9._/-]*) mh_die "unsafe characters in owner/repo: $slug" ;; esac
  printf '%s\n' "$slug"
}

repo_slug() {
  # repo_slug <repo>  -> owner/repo derived from the managed clone's origin
  # remote. Single owner (file-local) of a pattern repeated at every call site
  # that needs GitHub's owner/repo slug for a task's repo.
  owner_repo "$(git -C "$(mh_repo_dir "$1")" remote get-url origin)"
}

pr_number_from_url() {
  # strict canonical parse: https://github.com/<owner>/<repo>/pull/<n>
  local url="$1"
  grep -qE '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*$' <<<"$url" \
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
    # A local-only task never opens a PR — that path lands by fast-forward via
    # mh-merge.sh local. Refuse here (before any GitHub tool or push) so the
    # wrong delivery path fails fast with the right instruction.
    mode="$(mh_meta_get "$id" mode)"
    [ "$mode" = "local-only" ] && mh_die "task $id is mode 'local-only'; a PR is not its delivery path — land it with: mh-merge.sh local $id"
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
    mh_need gh-axi
    wt="$(mh_require_worktree "$id")"; repo="$(mh_meta_get "$id" repo)"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
    [ "$branch" != "HEAD" ] || mh_die "worktree is on a detached HEAD; crewmate must create a branch first"
    ! mh_tracked_dirty "$wt" || mh_die "worktree has uncommitted changes to tracked files; commit before opening a PR"
    dir="$(mh_repo_dir "$repo")"; slug="$(repo_slug "$repo")"
    # No explicit --base: default to the recorded parent (a stacked sub-PR
    # created via `mh-worktree.sh create --base`), else the default branch.
    base="$(mh_pr_base_for "$id" "$base" "$dir")"
    mh_info "pushing $branch -> origin"
    # The first push (-u) can fail for benign reasons (upstream already set), so
    # retry a plain push. If THAT is rejected — typically a non-fast-forward
    # because the branch was rebased locally and diverged from origin — surface a
    # domain message instead of raw git text. No force is performed: a diverged
    # branch is a signal to reconcile, never to overwrite origin.
    if ! git -C "$wt" push -u origin "$branch" >/dev/null 2>&1; then
      git -C "$wt" push origin "$branch" \
        || mh_die "push rejected — branch '$branch' diverged on origin; was it rebased? no force performed. Reconcile with origin, then retry."
    fi
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
    mh_need gh
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-pr.sh check <id>"
    url="$(mh_meta_get "$id" pr)"; [ -n "$url" ] || mh_die "no PR recorded for $id"
    n="$(pr_number_from_url "$url")"; repo="$(mh_meta_get "$id" repo)"
    slug="$(repo_slug "$repo")"
    json="$(gh api "repos/$slug/pulls/$n" 2>/dev/null)" || mh_die "could not read PR $url"
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
    mh_meta_set "$id" pr_state "$state"
    mh_meta_set "$id" checks "$rollup"
    mh_meta_set "$id" merge_state "$merge_state"
    [ -n "$sha" ] && mh_meta_set "$id" pr_head "$sha"
    echo "pr: $url · state: $state · checks: $rollup · merge_state: $merge_state"
    ;;

  await-checks)
    # Poll `check` until the CI rollup is terminal (passing/failing/none) or the
    # timeout elapses, so a caller (the merge gate, a supervision Monitor) can
    # WAIT for GitHub Actions rather than treating a still-pending PR as a
    # refusal. This does NOT merge and does NOT relax "never merge red": it is a
    # pre-step, and the outcome maps to an exit code the caller acts on.
    mh_need gh
    id="${1:-}"; shift || true
    [ -n "$id" ] || mh_die "usage: mh-pr.sh await-checks <id> [--timeout-secs N] [--interval-secs N]"
    timeout_secs="$AWAIT_TIMEOUT_SECS"; interval_secs="$AWAIT_INTERVAL_SECS"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout-secs) timeout_secs="${2:-}"; shift 2 ;;
        --interval-secs) interval_secs="${2:-}"; shift 2 ;;
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    case "$timeout_secs" in ''|*[!0-9]*) mh_die "--timeout-secs must be a non-negative integer" ;; esac
    case "$interval_secs" in ''|*[!0-9]*) mh_die "--interval-secs must be a non-negative integer" ;; esac
    [ "$interval_secs" -ge 1 ] || mh_die "--interval-secs must be >= 1"
    url="$(mh_meta_get "$id" pr)"; [ -n "$url" ] || mh_die "no PR recorded for $id"
    waited=0
    # Loop checks first, then tests the timeout, so timeout=0 still does exactly
    # one check (a single-shot probe) rather than none.
    while : ; do
      # A transient check failure (a network blip) is non-terminal: keep polling
      # within the timeout rather than aborting the wait. A persistent failure
      # still surfaces — it never reaches a terminal rollup, so it times out
      # (non-zero) with the last-seen rollup reported.
      if "$0" check "$id" >/dev/null 2>&1; then
        checks="$(mh_meta_get "$id" checks)"
      else
        checks="unknown"
      fi
      case "$checks" in
        passing|none) mh_info "await-checks: $checks after ${waited}s: $url"; exit 0 ;;
        failing)      mh_info "await-checks: FAILING after ${waited}s: $url"; exit 1 ;;
        *) : ;;   # pending / unknown / empty: not terminal, keep waiting
      esac
      if [ "$waited" -ge "$timeout_secs" ]; then
        mh_info "await-checks: TIMED OUT after ${waited}s (last rollup: ${checks:-unknown}): $url"
        exit 1
      fi
      sleep "$interval_secs"
      waited=$((waited + interval_secs))
    done
    ;;

  merge)
    mh_need gh-axi; mh_need gh
    id="${1:-}"; shift || true
    [ -n "$id" ] || mh_die "usage: mh-pr.sh merge <id> [--method squash|merge|rebase] [--delete-branch] [--allow-no-checks]"
    method="squash"; delete=0; allow_no_checks=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --method) method="${2:-}"; shift 2 ;;
        --delete-branch) delete=1; shift ;;
        --allow-no-checks) allow_no_checks=1; shift ;;
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
    # Never merge red. A `none` rollup (no checks reported) does NOT auto-pass:
    # it is the race window after a PR opens but before CI registers. It passes
    # only on an explicit --allow-no-checks AND a confirmed CI-less repo
    # (has_ci=0): once .github/workflows exists, --allow-no-checks can no
    # longer bypass `none` (closes #49) — a repo that gained CI must wait for
    # it, never merge on a rollup that just hasn't registered yet.
    repo="$(mh_meta_get "$id" repo)"
    ci_dir="$(mh_repo_dir "$repo")"
    # has_ci is checked in the worktree first (if still recorded), so a
    # workflow file added on the crewmate's branch but not yet in the managed
    # clone still counts; falls back to the clone otherwise.
    wt="$(mh_meta_get "$id" worktree)"
    has_ci=0
    if [ -n "$wt" ] && [ -d "$wt/.github/workflows" ]; then
      has_ci=1
    elif [ -d "$ci_dir/.github/workflows" ]; then
      has_ci=1
    fi
    case "$(mh_merge_gate "$checks" "$allow_no_checks" "$has_ci")" in
      allow) : ;;
      refuse-failing) mh_die "REFUSED: PR has failing checks (never merge red): $url" ;;
      refuse-pending) mh_die "REFUSED: PR checks still running: $url — wait for them with: mh-pr.sh await-checks $id" ;;
      refuse-none)
        if [ "$has_ci" -eq 1 ]; then
          mh_die "REFUSED: no checks reported yet for $url — this repo has CI configured. Wait with: mh-pr.sh await-checks $id"
        else
          mh_die "REFUSED: no checks reported yet for $url — pass --allow-no-checks if this repo has no CI, or wait with: mh-pr.sh await-checks $id"
        fi
        ;;
      *)              mh_die "REFUSED: could not confirm check status ($checks): $url" ;;
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
    n="$(pr_number_from_url "$url")"
    slug="$(repo_slug "$repo")"
    args=(pr merge "$n" -R "$slug" "--$method")
    [ "$delete" -eq 1 ] && args+=(--delete-branch)
    gh-axi "${args[@]}" || mh_die "merge failed"
    mh_meta_set "$id" pr_state MERGED
    mh_status_append "$id" merged "$url"
    mh_info "merged: $url"
    # Best-effort: FF-sync the clone's default branch so it is never left behind
    # by the PR it just merged (reuses mh-sync's FF-only logic). The merge above
    # already completed and is recorded; a can't-FF sync must not fail it - just
    # name the manual fallback. The `|| sync_out=...` guards against mh-sync
    # itself exiting non-zero unexpectedly (under set -e that would otherwise
    # abort this command AFTER the merge was already recorded, misreporting a
    # completed merge as a failed one).
    sync_out="$("$(dirname "${BASH_SOURCE[0]}")/mh-sync.sh" one "$repo")" || sync_out="STUCK: sync failed unexpectedly"
    mh_sync_reaction "$repo" "$sync_out" warn
    ;;

  security-scan)
    # Advisory only: grep the task's diff for security-surface signals and print
    # whether `security-review` should run, so the optional security gate is a
    # deliberate skip rather than a silent one. It NEVER blocks and NEVER decides.
    # Exit code follows grep's sense: 0 = signals found (review recommended),
    # 1 = none found (skip is defensible); a real error (no worktree) dies via
    # mh_die. Local-only: no GitHub tools required.
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-pr.sh security-scan <id>"
    mh_require_id "$id"
    wt="$(mh_require_worktree "$id")"; repo="$(mh_meta_get "$id" repo)"
    base="$(mh_default_branch "$(mh_repo_dir "$repo")")"
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
      mh_info "security-scan: signals present ($hits) — run security-review on this diff before merge"
      exit 0
    fi
    mh_info "security-scan: no security-surface signals — a security-review skip is defensible (record it)"
    exit 1
    ;;

  sweep)
    # Fleet PR/health sweep (#26): walk every task that records an OPEN PR and
    # report, one line each, its CI rollup and whether a review is requesting
    # changes, plus a summary. Purely READ-ONLY over GitHub and repos — it opens
    # no PR, pushes nothing, merges nothing. It DOES refresh the cached
    # pr_state/checks meta via `check` (the same cache mh-status trusts), reusing
    # that rollup logic rather than recomputing it.
    #
    # Offline (MH_NO_FETCH=1 — how mh-status invokes it): perform NO network. Show
    # the cached pr_state/checks and skip the review query, matching how
    # mh_should_refresh_pr_state degrades offline.
    offline=0
    [ "${MH_NO_FETCH:-0}" = "1" ] && offline=1
    [ "$offline" -eq 1 ] || mh_need gh
    total=0; red=0; changes=0; missing=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      url="$(mh_meta_get "$id" pr)"
      repo="$(mh_meta_get "$id" repo)"
      # A missing clone skips this PR (its slug/rollup are underivable) but must
      # not abort the whole sweep; surface it per-line, never a silent skip.
      dir="$MH_HOME/$(mh_registry_get "$repo" path)"
      if [ ! -d "$dir/.git" ]; then
        missing=$((missing + 1))
        printf '  %s  (repo clone missing: %s — skipped)  %s\n' "$id" "${repo:-?}" "$url"
        continue
      fi
      if [ "$offline" -eq 1 ]; then
        checks="$(mh_meta_get "$id" checks)"; [ -n "$checks" ] || checks="?"
        state="$(mh_meta_get "$id" pr_state)"; [ -n "$state" ] || state="?"
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
      checks="$(mh_meta_get "$id" checks)"; [ -n "$checks" ] || checks="?"
      state="$(mh_meta_get "$id" pr_state)"; [ -n "$state" ] || state="?"
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
    done < <(mh_open_pr_tasks)
    if [ "$total" -eq 0 ]; then
      mh_info "  (no open PRs)"
    else
      note=""
      [ "$red" -gt 0 ] && note="$note, $red with red CI"
      [ "$changes" -gt 0 ] && note="$note, $changes with changes requested"
      [ "$missing" -gt 0 ] && note="$note, $missing with a missing clone"
      note="${note#, }"
      [ -n "$note" ] && note=" ($note)"
      mh_info "  sweep: $total open PR(s)$note"
    fi
    ;;

  url)
    id="${1:-}"; [ -n "$id" ] || mh_die "usage: mh-pr.sh url <id>"
    mh_meta_get "$id" pr ;;

  *)
    echo "usage: mh-pr.sh {open|check|await-checks|merge|sweep|security-scan|url} ..." >&2; exit 2 ;;
esac

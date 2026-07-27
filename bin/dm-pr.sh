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
# Merge AUTHORITY is enforced here in two layers. The repo's merge_authority
# (yolo|ask|never) is a HARD stop: `merge` refuses outright, before any GitHub
# call, for a `never` repo (dm_merge_authority_gate) — no flag bypasses it. The
# only carve-out is the operator-granted merge_allowed_bases list: a `never`
# repo's PR proceeds iff its LIVE GitHub base branch exactly matches a listed
# branch that is neither the LIVE default branch nor the registry default
# (dm_merge_base_exception, fail closed on anything unverifiable), re-verified
# immediately before the merge mutation (TOCTOU guard against a retarget);
# a default-branch PR stays impossible to merge. The
# operator-approval part of `ask` (vs. standing `yolo`) stays the dockmaster's
# duty one layer up, per AGENTS.md; this script enforces the never-stop and the
# CI mechanics.
#
# GitHub access splits by need. Parsed reads always use plain `gh api` (real
# JSON). Mutations — `pr create` and the SHA-checked merge PUT — go through
# dm_require_github_cli: the operator's `gh-axi` wrapper when installed, else
# plain `gh`, whose argv shape differs and is built per binary. Same-repo branch
# cleanup uses Git's server-enforced force-with-lease so an advanced ref cannot
# be deleted.
#
# Commands:
#   open  <id> --title T (--body-file F | --body B) [--base B] [--draft]
#                                 the caller's body stays first and intact;
#                                 whatever the gates recorded is appended below
#                                 it (dm-evidence.sh), replacing a section an
#                                 earlier compose left, never stacking one
#   adopt <id> <url>              record a PR opened out of band (e.g. direct-pr
#                                 mode, a revert PR): validates the url is a
#                                 canonical GitHub PR url for the task's own
#                                 repo, then records it and queries real state
#   check <id> [--snapshot]       refresh PR state; print summary or snapshot JSON
#   await-checks <id> [--timeout-secs N] [--interval-secs N]
#                                 poll check until the CI rollup is terminal
#                                 (a `none` rollup keeps polling, not terminal,
#                                 when the repo has CI configured)
#   merge <id> [--method squash|merge|rebase] [--delete-branch]
#   close <id> --reason R         close a PR WITHOUT merging, commenting the
#                                 reason on it first. Refuses an already-merged
#                                 PR and never deletes the remote branch; the
#                                 trash flow (dm-trash.sh) is its caller
#   sweep [--json]                read-only fleet sweep: every task with an open
#                                 PR, its CI rollup + whether a review requests
#                                 changes (offline under DM_NO_FETCH: cached only)
#   pipeline <repo> [--json]      the gate track a PR in <repo> must clear, from
#                                 config/pr-pipeline.<repo>.json or the default
#   security-scan <id> [--json]   grep the diff for security-surface signals.
#                                 Bare: exit 0 = signals, 1 = none. --json ALWAYS
#                                 exits 0 and answers in `surface`.
#   url   <id>                    print recorded PR url

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
# git+jq are needed by every command (registry, worktree, diffs). The GitHub CLI
# is checked per-command below, so the local-only commands (security-scan, url)
# run without one.
dm_need git; dm_need jq
dm_ensure_dirs
# Merge/landing decisions read the registry (authority, allowed bases, clone
# path); a corrupt one must stop them before any gate is consulted.
dm_registry_require_valid

# Sibling toolbelt scripts, resolved from this script's own location so they are
# reachable from any cwd (mirrors dm-lib's BASH_SOURCE-based resolution).
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# gate_evidence_section <id> -- the section to append below the caller's body:
# whatever dm-evidence.sh collected, or a stated UNAVAILABLE section when the
# collector itself cannot be run. Empty ONLY when the collector ran and no gate
# contributed anything, which is the one case that legitimately means "no gate
# applied" (#175). A warning on stderr is not a substitute: it reaches a log the
# reviewer never opens, and a PR carrying nothing reads exactly like a PR whose
# gates all stayed out — the false green this whole section exists to prevent.
gate_evidence_section() {
  local id="$1" collector="$BIN_DIR/dm-evidence.sh" out rc=0 why=""
  if [ ! -x "$collector" ]; then
    why="\`dm-evidence.sh\` is missing or not executable"
  else
    out="$("$collector" block "$id" 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || why="\`dm-evidence.sh block\` exited $rc"
  fi
  if [ -n "$why" ]; then
    dm_warn "gate evidence could not be collected for $id ($why); the PR will say so"
    dm_evidence_wrap "**gate evidence** — UNAVAILABLE · $why, so what this task's gates saw is NOT reported here. Treat every gate as unreported until it is."
    return 0
  fi
  printf '%s' "$out"
}

# await-checks polling defaults (named once): wait up to ~10 minutes, re-checking
# every ~15s. GitHub Actions runs are minutes long, so a short interval mostly
# sleeps; both are overridable per call.
AWAIT_TIMEOUT_SECS=600
AWAIT_INTERVAL_SECS=15

# gh_api_retry bounds (#107): up to 4 attempts, doubling delay from a 2s base
# (2s, 4s, 6s...). Overridable so tests can run near-instantly.
GH_RETRY_MAX="${DM_GH_RETRY_MAX:-4}"
GH_RETRY_BASE_SECS="${DM_GH_RETRY_BASE_SECS:-2}"

# sweep's circuit breaker (#107): abort the whole sweep after this many
# CONSECUTIVE PRs each exhaust their full gh_api_retry budget, rather than
# grinding through the rest of a large fleet at the same degraded rate under
# sustained rate limiting (worst case ~(2+4+6+...)s of sleeping per exhausted
# PR with the defaults above).
GH_CIRCUIT_BREAKER_MAX="${DM_GH_CIRCUIT_BREAKER_MAX:-5}"

# is_transient_gh_error <stderr-text>  -> true if a `gh api` failure looks like
# a rate limit or a transient transport error worth retrying, false for a
# permanent error (404, bad request, auth) that retrying cannot fix.
is_transient_gh_error() {
  grep -qiE 'rate limit|secondary rate|HTTP 429|HTTP 5[0-9][0-9]|time(d)? ?out|could not resolve host|connection reset|temporary failure|unexpected EOF' <<<"$1"
}

# Distinct exit code gh_api_retry returns when it stopped specifically because
# it exhausted the retry budget on a TRANSIENT error, as opposed to any other
# failure — sweep's circuit breaker watches for exactly this code. Every
# caller of gh_api_retry is invoked through a `$(...)` command substitution,
# which bash runs in a subshell, so a global variable set inside gh_api_retry
# can never be observed by the caller once it returns; the exit code is the
# only channel that survives that boundary. Chosen far from any real `gh`
# exit code (which is 1 for essentially every API failure).
GH_RETRY_EXHAUSTED_RC=99

# gh_api_retry <args to `gh api`...>  -> stdout of the call. Retries a
# transient/rate-limit failure with bounded exponential backoff; a permanent
# failure returns the real underlying `gh` exit code, exactly like a single
# failed `gh api` call would — every existing degrade-to-unknown/dm_die caller
# is unchanged, only the path to that same failure gets slower and sturdier.
# Exhausting the attempts on a still-transient error returns
# GH_RETRY_EXHAUSTED_RC instead, still non-zero so every `||` fallback still
# fires the same way, just distinguishably so the circuit breaker can tell
# "rate-limited" apart from "ordinary failure".
# Reads only: mutations (`pr create`, the merge PUT) are never retried here —
# retrying a mutation without an idempotency guarantee risks a double side
# effect, so those keep their own single-attempt handling.
gh_api_retry() {
  local attempt=1 out err rc errtext transient
  while :; do
    err="$(mktemp "$DM_STATE/.gh-retry.XXXXXX")" || dm_die "mktemp failed for gh api retry buffer"
    rc=0; out="$(gh api "$@" 2>"$err")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"; printf '%s' "$out"; return 0
    fi
    errtext="$(cat "$err" 2>/dev/null || true)"; rm -f "$err"
    if is_transient_gh_error "$errtext"; then transient=1; else transient=0; fi
    if [ "$attempt" -ge "$GH_RETRY_MAX" ] || [ "$transient" -eq 0 ]; then
      printf '%s' "$errtext" >&2
      if [ "$transient" -eq 1 ] && [ "$attempt" -ge "$GH_RETRY_MAX" ]; then
        return "$GH_RETRY_EXHAUSTED_RC"
      fi
      return "$rc"
    fi
    sleep "$((GH_RETRY_BASE_SECS * attempt))"
    attempt=$((attempt + 1))
  done
}

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
  #
  # Resolve into a variable first. Nested in the `git -C` substitution, a resolver
  # dm_die does not propagate, and `git -C ""` is a documented no-op that reads
  # the CWD repo — in production the distro. `check` then wrote real landing
  # fields (pr_state, checks, pr_check_snapshot) sourced from the WRONG repo, and
  # `adopt`'s cross-repo guard compared against that same wrong slug.
  local dir
  dir="$(dm_repo_dir "$1")" \
    || dm_die "cannot resolve repo '$1' to derive its GitHub slug; refusing to fall back to the current directory"
  owner_repo "$(git -C "$dir" remote get-url origin)"
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
  local id="$1" repo wt dir
  repo="$(dm_meta_get "$id" repo)"
  wt="$(dm_meta_get "$id" worktree)"
  # `if`, not a bare `[ ... ] && [ ... ] && return 0`: under set -e a false
  # first test would abort this function's CALLER outright (a standalone list
  # whose exit status is nonzero), not just fall through to the next line.
  if [ -n "$wt" ] && [ -d "$wt/.github/workflows" ]; then
    return 0
  fi
  # Resolve into a VARIABLE first, then test it. Nested inside the `[ ]`
  # argument, a dm_die from the resolver does not propagate (set -e ignores a
  # failed substitution there) — the test just saw an empty path and answered
  # "no CI", which with --allow-no-checks makes dm_merge_gate ALLOW. An
  # unresolvable repo must refuse, never silently unlock the bypass.
  dir="$(dm_repo_dir "$repo")" \
    || dm_die "cannot determine CI configuration for repo '$repo'; refusing to guess (a wrong answer here can unlock --allow-no-checks)"
  [ -d "$dir/.github/workflows" ]
}

# verify_never_exception <repo> <slug> <n> <url> — decide the never-repo
# base-branch carve-out against the PR's LIVE state. Fetches the PR's current
# base branch AND its repository's current default branch in ONE GitHub call —
# a self-consistent snapshot: both values come from the same response, so a
# concurrent retarget/rename cannot split them. The pure gate must then allow
# against BOTH default-branch anchors:
#   - the LIVE default (GitHub's truth — catches a registry default_branch that
#     drifted after a rename or misconfiguration), and
#   - the registry default (belt-and-braces — catches a stale/wrong GitHub
#     response, and an empty/unset registry default refuses via the gate rather
#     than comparing trivially).
# Either anchor matching the base — or ANY value being unverifiable — refuses
# (fail closed): the default branch must NEVER be mergeable under `never`.
# Registry read ordering is load-bearing: the caller resolved authority first,
# then this reads the allowed list, then the default — the registry advances
# atomically (locked temp+mv in dm-repo.sh), so each read sees a complete
# snapshot, and reading the default LAST means a concurrent default_branch
# change is judged by the freshest value. Prints the verified base branch on
# allow; dies on everything else.
verify_never_exception() {
  local repo="$1" slug="$2" n="$3" url="$4" json base_ref live_default reg_default allowed
  allowed="$(dm_merge_allowed_bases "$repo")"
  reg_default="$(dm_registry_get "$repo" default_branch)"
  json="$(gh_api_retry "repos/$slug/pulls/$n" 2>/dev/null)" \
    || dm_die "REFUSED: repo $repo is merge_authority=never and the PR's base branch could not be verified on GitHub — refusing (fail closed): $url"
  base_ref="$(printf '%s' "$json" | jq -r '.base.ref // empty' 2>/dev/null)" || base_ref=""
  live_default="$(printf '%s' "$json" | jq -r '.base.repo.default_branch // empty' 2>/dev/null)" || live_default=""
  [ -n "$base_ref" ] || dm_die "REFUSED: repo $repo is merge_authority=never and the PR's base branch could not be verified on GitHub — refusing (fail closed): $url"
  [ -n "$live_default" ] || dm_die "REFUSED: repo $repo is merge_authority=never and the base repository's LIVE default branch could not be verified on GitHub — refusing (fail closed): $url"
  case "$(dm_merge_base_exception never "$base_ref" "$live_default" "$allowed")" in
    allow) : ;;
    *) dm_die "REFUSED: repo $repo is merge_authority=never and PR base '$base_ref' is not an operator-granted merge base (merge_allowed_bases covers: $(printf '%s' "$allowed" | tr '\n' ' '); live default branch: $live_default); the operator merges it on GitHub" ;;
  esac
  case "$(dm_merge_base_exception never "$base_ref" "$reg_default" "$allowed")" in
    allow) : ;;
    *) dm_die "REFUSED: repo $repo is merge_authority=never and PR base '$base_ref' matches the registry default_branch ('$reg_default') or the registry default is unset — the default branch is never mergeable under never; the operator merges it on GitHub" ;;
  esac
  printf '%s\n' "$base_ref"
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

is_git_oid() {
  [ -n "$1" ] && [ -z "${1//[0-9A-Fa-f]/}" ]
}

load_check_snapshot_json() {
  local snapshot="$1" values owner name
  values="$(printf '%s' "$snapshot" | jq -er '
    select(type == "object")
    | [.head, .head_repo, .head_ref, .checks, .merge_state, .state]
    | if all(.[]; type == "string") then .[] else error("invalid snapshot") end' 2>/dev/null)" || return 1
  {
    IFS= read -r PR_SNAPSHOT_HEAD
    IFS= read -r PR_SNAPSHOT_HEAD_REPO
    IFS= read -r PR_SNAPSHOT_HEAD_REF
    IFS= read -r PR_SNAPSHOT_CHECKS
    IFS= read -r PR_SNAPSHOT_MERGE_STATE
    IFS= read -r PR_SNAPSHOT_STATE
  } <<<"$values"
  [ -z "$PR_SNAPSHOT_HEAD" ] || is_git_oid "$PR_SNAPSHOT_HEAD" || return 1
  case "$PR_SNAPSHOT_CHECKS" in passing|failing|pending|none|unknown) ;; *) return 1 ;; esac
  case "$PR_SNAPSHOT_MERGE_STATE" in clean|blocked|unstable|dirty|behind|draft|has_hooks|unknown) ;; *) return 1 ;; esac
  case "$PR_SNAPSHOT_STATE" in OPEN|CLOSED|MERGED|UNKNOWN) ;; *) return 1 ;; esac
  if [ -z "$PR_SNAPSHOT_HEAD_REPO" ] && [ -z "$PR_SNAPSHOT_HEAD_REF" ]; then
    return 0
  fi
  owner="${PR_SNAPSHOT_HEAD_REPO%%/*}"; name="${PR_SNAPSHOT_HEAD_REPO#*/}"
  [ -n "$owner" ] && [ -n "$name" ] && [ "$name" != "$PR_SNAPSHOT_HEAD_REPO" ] || return 1
  case "$PR_SNAPSHOT_HEAD_REPO" in *[!A-Za-z0-9._/-]*|*/*/*) return 1 ;; esac
  git check-ref-format "refs/heads/$PR_SNAPSHOT_HEAD_REF" >/dev/null 2>&1
}

# --- sweep-only GraphQL snapshot (#107) ---------------------------------------
# `sweep`'s online path needs state + CI rollup + review verdict for every open
# PR; fetching that via REST costs 4 calls (PR details, check-runs, commit
# status, reviews) per PR, unpaced. ONE GraphQL query returns all three in one
# round trip, cutting sweep's call count ~4x. Scoped to sweep's read-only
# display only: `check`/`merge`/`await-checks` keep their own REST path
# unchanged, so this never itself feeds a merge decision.
SWEEP_REVIEWS_PAGE=100

sweep_graphql_query() {
  cat <<'GQL'
query($owner: String!, $name: String!, $number: Int!, $reviewsFirst: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state
      merged
      headRefOid
      title
      createdAt
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
      reviews(first: $reviewsFirst) {
        pageInfo { hasNextPage }
        nodes { state submittedAt author { login } }
      }
    }
  }
}
GQL
}

# sweep_pr_snapshot <owner> <name> <number>  -> compact JSON
# {state, checks, review, head, title, created_at} on stdout, or nonzero with
# nothing printed. Only the first four are destructured by read_sweep_snapshot;
# title/created_at are display-only for `--json` and are read straight off the
# snapshot with jq, never through that line-based read (a title is free text).
# Every field is validated at this API boundary before being trusted: an
# unexpected shape, a GraphQL `errors` entry, or more than SWEEP_REVIEWS_PAGE
# reviews (pageInfo.hasNextPage) all fail CLOSED to "unknown", never a false
# "clean" (the #107 false-green: the old unpaginated reviews call silently
# truncated at GitHub's default page size of 30). Propagates gh_api_retry's
# exact exit code (rather than flattening to 1) so a caller can see
# GH_RETRY_EXHAUSTED_RC specifically — sweep's circuit breaker needs it.
sweep_pr_snapshot() {
  local owner="$1" name="$2" number="$3" json rc
  rc=0
  json="$(gh_api_retry graphql -f query="$(sweep_graphql_query)" \
      -F owner="$owner" -F name="$name" -F number="$number" \
      -F reviewsFirst="$SWEEP_REVIEWS_PAGE" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$json" | jq -ce '
    if (.errors | length) > 0 then error("graphql error") else . end
    | .data.repository.pullRequest as $pr
    | if $pr == null then error("no such PR") else . end
    | if ($pr.reviews.nodes | type) != "array" then error("invalid reviews") else . end
    | if ($pr.commits.nodes | type) != "array" then error("invalid commits") else . end
    | ($pr.commits.nodes[0].commit.statusCheckRollup.state // null) as $rollup
    | (if $pr.merged == true then "MERGED"
       elif $pr.state == "OPEN" then "OPEN"
       elif $pr.state == "CLOSED" then "CLOSED"
       else "UNKNOWN" end) as $state
    | (if $rollup == null then "none"
       elif $rollup == "SUCCESS" then "passing"
       elif $rollup == "FAILURE" or $rollup == "ERROR" then "failing"
       elif $rollup == "PENDING" or $rollup == "EXPECTED" then "pending"
       else "unknown" end) as $checks
    | (if ($pr.reviews.pageInfo.hasNextPage | type) == "boolean"
       then $pr.reviews.pageInfo.hasNextPage else true end) as $truncated
    | ( [$pr.reviews.nodes[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
        | group_by(.author.login)
        | map(max_by(.submittedAt).state)
        | any(. == "CHANGES_REQUESTED") ) as $cr
    | { state: $state, checks: $checks,
        review: (if $truncated then "unknown" elif $cr then "changes-requested" else "clean" end),
        head: ($pr.headRefOid // ""),
        title: ($pr.title // ""), created_at: ($pr.createdAt // "") }
  ' 2>/dev/null
}

# read_sweep_snapshot <json>  -> validates and destructures into
# SWEEP_STATE/SWEEP_CHECKS/SWEEP_REVIEW/SWEEP_HEAD, or returns 1. Mirrors
# load_check_snapshot_json's boundary validation for the sweep-only shape.
# SWEEP_HEAD is validated but deliberately never persisted: `check` already
# owns pr_head as part of its own atomic pr_check_snapshot write, and writing
# it again from here would give the same field two independent, driftable
# sources. Validating it anyway is still worth doing — a malformed head is a
# signal the rest of the response may be untrustworthy too.
read_sweep_snapshot() {
  local json="$1" values
  values="$(printf '%s' "$json" | jq -er '
    select(type == "object")
    | [.state, .checks, .review, .head]
    | if all(.[]; type == "string") then .[] else error("invalid sweep snapshot") end' 2>/dev/null)" || return 1
  {
    IFS= read -r SWEEP_STATE
    IFS= read -r SWEEP_CHECKS
    IFS= read -r SWEEP_REVIEW
    IFS= read -r SWEEP_HEAD
  } <<<"$values"
  case "$SWEEP_STATE" in OPEN|CLOSED|MERGED|UNKNOWN) ;; *) return 1 ;; esac
  case "$SWEEP_CHECKS" in passing|failing|pending|none|unknown) ;; *) return 1 ;; esac
  case "$SWEEP_REVIEW" in clean|changes-requested|unknown) ;; *) return 1 ;; esac
  [ -z "$SWEEP_HEAD" ] || is_git_oid "$SWEEP_HEAD" || return 1
}

# sweep_row <id> <repo> <url> <state> <checks> <review> <title> <created_at>
#           <offline> <unreadable>  -> one JSON object for `sweep --json`.
# jq --arg, never string assembly: a PR title is free text. EVERY swept PR gets
# a row, unreadable ones included with `unreadable` set — a PR that drops out of
# the list reads as a fleet with fewer problems than it has.
#
# `unreadable` is a TOKEN (repo_missing | github_unreadable), not a sentence: the
# console words it for the operator, and this script's own phrasing —
# "clone missing", "check failed" — is the crew's vocabulary, not theirs.
sweep_row() {
  jq -nc --arg id "$1" --arg repo "$2" --arg url "$3" --arg state "$4" \
    --arg checks "$5" --arg review "$6" --arg title "$7" --arg created_at "$8" \
    --arg offline "$9" --arg unreadable "${10}" \
    --arg authority "$(dm_merge_authority "$2")" '
    { id: $id, repo: $repo, url: $url, state: $state, checks: $checks,
      review: $review, title: $title, created_at: $created_at,
      authority: $authority, offline: ($offline == "1"),
      unreadable: (if $unreadable == "" then null else $unreadable end) }'
}

check_runs_rollup() {
  local slug="$1" sha="$2" json rollup
  json="$(gh_api_retry "repos/$slug/commits/$sha/check-runs?per_page=100" 2>/dev/null)" \
    || { printf 'unknown\n'; return; }
  rollup="$(printf '%s' "$json" | jq -er '
    if type != "object" or (.check_runs | type) != "array"
      or (.total_count | type) != "number" or .total_count < 0
      or (.total_count | floor) != .total_count then error("invalid check-runs response")
    elif .total_count != (.check_runs | length) then "unknown"
    elif (.check_runs | length) == 0 then "none"
    elif any(.check_runs[]; .status == "completed" and
      (.conclusion == "failure" or .conclusion == "cancelled"
        or .conclusion == "timed_out" or .conclusion == "action_required"
        or .conclusion == "startup_failure")) then "failing"
    elif any(.check_runs[]; .status == "completed" and
      (.conclusion == null or
        (.conclusion != "success" and .conclusion != "neutral"
          and .conclusion != "skipped" and .conclusion != "stale"
          and .conclusion != "failure" and .conclusion != "cancelled"
          and .conclusion != "timed_out" and .conclusion != "action_required"
          and .conclusion != "startup_failure"))) then "unknown"
    elif any(.check_runs[]; .status != "completed" or .conclusion == "stale") then "pending"
    elif all(.check_runs[]; .status == "completed" and
      (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped")) then "passing"
    else "unknown" end' 2>/dev/null)" || rollup="unknown"
  printf '%s\n' "$rollup"
}

commit_status_rollup() {
  local slug="$1" sha="$2" json rollup
  json="$(gh_api_retry "repos/$slug/commits/$sha/status" 2>/dev/null)" \
    || { printf 'unknown\n'; return; }
  rollup="$(printf '%s' "$json" | jq -er '
    if type != "object" or (.total_count | type) != "number"
      or .total_count < 0 or (.total_count | floor) != .total_count then error("invalid status response")
    elif .total_count == 0 then "none"
    elif .state == "failure" or .state == "error" then "failing"
    elif .state == "success" then "passing"
    else "pending" end' 2>/dev/null)" || rollup="unknown"
  printf '%s\n' "$rollup"
}

local_task_head() {
  local id="$1" wt head
  wt="$(dm_meta_get "$id" worktree)"
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  head="$(git -C "$wt" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  is_git_oid "$head" || return 1
  printf '%s\n' "$head"
}

remote_ref_head() {
  local head_repo="$1" head_ref="$2" encoded json head
  [ -n "$head_repo" ] && [ -n "$head_ref" ] || return 1
  encoded="$(jq -nr --arg ref "$head_ref" '$ref | @uri')" || return 1
  json="$(gh_api_retry "repos/$head_repo/git/ref/heads/$encoded" 2>/dev/null)" || return 1
  head="$(printf '%s' "$json" | jq -er '.object.sha | select(type == "string" and length > 0)' 2>/dev/null)" || return 1
  is_git_oid "$head" || return 1
  printf '%s\n' "$head"
}

expected_pr_head() {
  local id="$1" head_repo="$2" head_ref="$3" wt local_head remote_head
  remote_head="$(remote_ref_head "$head_repo" "$head_ref")" || return 1
  wt="$(dm_meta_get "$id" worktree)"
  if [ -n "$wt" ]; then
    local_head="$(local_task_head "$id")" || return 1
    [ "$local_head" = "$remote_head" ] || return 2
  fi
  printf '%s\n' "$remote_head"
}

same_repo() {
  [ "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" ]
}

atomic_merge_pull() {
  local slug="$1" n="$2" head="$3" method="$4" cli path out
  local args=()
  path="/repos/$slug/pulls/$n/merge"
  cli="$(dm_require_github_cli)"
  # One argv cannot serve both. gh-axi puts the HTTP method positionally and
  # does NOT support --raw-field — it silently sends an EMPTY body, which would
  # merge without the sha condition. gh needs --method, and --raw-field so the
  # sha is unambiguously a string. Neither response is parsed (only echoed in
  # the failure message), so the YAML/JSON split does not matter here.
  if [ "$cli" = "gh-axi" ]; then
    args=(api PUT "$path" --field "sha=$head" --field "merge_method=$method")
  else
    args=(api --method PUT "$path" --raw-field "sha=$head" --raw-field "merge_method=$method")
  fi
  out="$("$cli" "${args[@]}" 2>&1)" \
    || dm_die "REFUSED: atomic merge failed; PR head changed or GitHub rejected the merge: ${out:-no response}"
}

# The two mutations `close` needs. Split by CLI exactly as atomic_merge_pull is:
# gh-axi takes the HTTP method positionally and has no --raw-field, gh needs
# --method and --raw-field so the value is unambiguously a string. Both die on
# failure — a comment that did not post must not be followed by a silent close.
# The body is passed as `--field body=<text>`, and gh reads a value starting with
# `@` as a FILE to read (`@-` is stdin) — the wrapper CLI has no --raw-field to
# turn that off. Every caller here prefixes fixed text, which makes a leading `@`
# impossible; that prefix is load-bearing, not decoration, and `close` also
# refuses a reason that starts with one.
comment_pr() {
  local slug="$1" n="$2" body="$3" cli path out
  local args=()
  path="/repos/$slug/issues/$n/comments"
  cli="$(dm_require_github_cli)"
  if [ "$cli" = "gh-axi" ]; then
    args=(api POST "$path" --field "body=$body")
  else
    args=(api --method POST "$path" --raw-field "body=$body")
  fi
  out="$("$cli" "${args[@]}" 2>&1)" \
    || dm_die "REFUSED: could not comment the reason on PR #$n; leaving it OPEN: ${out:-no response}"
}

close_pull() {
  local slug="$1" n="$2" cli path out
  local args=()
  path="/repos/$slug/pulls/$n"
  cli="$(dm_require_github_cli)"
  if [ "$cli" = "gh-axi" ]; then
    args=(api PATCH "$path" --field "state=closed")
  else
    args=(api --method PATCH "$path" --raw-field "state=closed")
  fi
  out="$("$cli" "${args[@]}" 2>&1)" \
    || dm_die "could not close PR #$n: ${out:-no response}"
}

delete_merged_head() {
  local repo="$1" slug="$2" head_repo="$3" head_ref="$4" merged_head="$5" dir lease out
  if ! same_repo "$slug" "$head_repo"; then
    dm_info "branch cleanup skipped: PR head belongs to fork $head_repo"
    return 0
  fi
  dir="$(dm_repo_dir "$repo")"
  lease="refs/heads/$head_ref:$merged_head"
  out="$(git -C "$dir" push origin "--force-with-lease=$lease" \
    ":refs/heads/$head_ref" 2>&1)" || {
    dm_warn "branch cleanup failed after merge: ${out:-no response}"
    return 0
  }
  dm_info "deleted merged branch: $head_ref"
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
    # `pr create` is a mutation with no jq-parsed response, so either binary
    # serves. Resolve BEFORE the push so a missing GitHub CLI fails with nothing
    # yet pushed.
    gh_cli="$(dm_require_github_cli)"
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
    [ "$branch" != "HEAD" ] || dm_die "worktree is on a detached HEAD; crewmate must create a branch first"
    ! dm_tracked_dirty "$wt" || dm_die "worktree has uncommitted changes to tracked files; commit before opening a PR"
    if ! untracked="$(dm_untracked "$wt")"; then
      dm_die "cannot inspect untracked files before opening a PR; nothing pushed. ${untracked:-No detail from git.}"
    fi
    [ -z "$untracked" ] || dm_die "worktree has untracked files; clean or commit them before opening a PR: $(dm_first_line "$untracked")"
    dir="$(dm_repo_dir "$repo")"; slug="$(repo_slug "$repo")"
    # No explicit --base: default to the recorded parent (a stacked sub-PR
    # created via `dm-worktree.sh create --base`), else the default branch.
    base="$(dm_pr_base_for "$id" "$base" "$dir")"
    # Gate evidence (#175). Composed BEFORE the push so a body problem fails with
    # nothing pushed. Read-only and never fatal on its own: an unreachable
    # collector still opens the PR, saying so on it. Only a collector that RAN
    # and found nothing yields an empty block, leaving the body as passed.
    body_tmp=""
    evidence="$(gate_evidence_section "$id")"
    if [ -n "$evidence" ]; then
      body_tmp="$(mktemp "$DM_STATE/.pr-body.XXXXXX")" || dm_die "mktemp failed composing the PR body for $id"
      # The composed body holds the PR text, so it is cleaned up on EVERY exit
      # from here on — a `dm_die` further down, or a kill mid-`gh`. Cleared
      # again before the first dm_meta_set: dm_lock installs its own EXIT/INT/
      # TERM traps and would drop this one.
      trap 'rm -f "$body_tmp"' EXIT
      trap 'rm -f "$body_tmp"; exit 130' INT
      trap 'rm -f "$body_tmp"; exit 143' TERM
      # Stripping first drops a section an earlier compose appended, so
      # re-running never stacks blocks; the caller's own text passes through
      # untouched. dm_evidence_strip is a lib function, not a call back into
      # dm-evidence.sh: the collector may be exactly what is unavailable.
      { if [ -n "$body_file" ]; then cat -- "$body_file"
        elif [ -n "$body" ]; then printf '%s\n' "$body"; fi
      } | dm_evidence_strip > "$body_tmp" \
        || dm_die "could not compose the PR body for $id (is --body-file readable?); nothing pushed"
      printf '\n%s\n' "$evidence" >> "$body_tmp" \
        || dm_die "failed writing the composed PR body for $id; nothing pushed"
    fi
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
    if [ -n "$body_tmp" ]; then args+=(--body-file "$body_tmp")
    elif [ -n "$body_file" ]; then args+=(--body-file "$body_file")
    elif [ -n "$body" ]; then args+=(--body "$body")
    else args+=(--body ""); fi
    [ "$draft" -eq 1 ] && args+=(--draft)
    # stderr captured separately (not 2>&1) so the URL parse below only ever
    # sees the CLI's stdout, never a stray url from a warning line.
    errf="$(mktemp "$DM_STATE/.pr-open.XXXXXX")" || dm_die "mktemp failed opening PR for $id"
    if out="$("$gh_cli" "${args[@]}" 2>"$errf")"; then
      rm -f "$errf"
    else
      err="$(cat "$errf" 2>/dev/null || true)"; rm -f "$errf"
      dm_die "pr create failed: ${err:-${out:-no output from $gh_cli}}"
    fi
    # The body has been handed to GitHub; drop it and the traps guarding it
    # before dm_meta_set, whose lock installs traps of its own.
    if [ -n "$body_tmp" ]; then trap - EXIT INT TERM; rm -f "$body_tmp"; body_tmp=""; fi
    # `|| true` is load-bearing: a no-match grep exits 1, which under set -e
    # aborted the whole command HERE — silently, before the guard below could
    # say anything. -m1 replaces the `| head -n1` pipe (no SIGPIPE to trip
    # pipefail).
    url="$(grep -m1 -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' <<<"$out" || true)"
    # Both irreversible steps (push, create) already succeeded here, so a failed
    # parse leaves a real PR the task record does not know about. Name the
    # recovery instead of leaving the operator to discover `adopt`.
    [ -n "$url" ] || dm_die "$gh_cli reported success but printed no PR url: branch '$branch' IS pushed and the PR probably exists. Find it on GitHub, then record it with: dm-pr.sh adopt $id <url>"
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
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh check <id> [--snapshot]"
    dm_require_id "$id"
    snapshot_only=0
    if [ "${1:-}" = "--snapshot" ]; then snapshot_only=1; shift; fi
    [ "$#" -eq 0 ] || dm_die "usage: dm-pr.sh check <id> [--snapshot]"
    repo="$(dm_meta_get "$id" repo)"; [ -n "$repo" ] || dm_die "no such task: $id"
    url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
    n="$(pr_number_from_url "$url")"
    slug="$(repo_slug "$repo")"
    json="$(gh_api_retry "repos/$slug/pulls/$n" 2>/dev/null)" || dm_die "could not read PR $url"
    state="$(printf '%s' "$json" | jq -er '(.state // "unknown") | select(type == "string") | ascii_upcase' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    merged="$(printf '%s' "$json" | jq -er '(.merged // false) | if type == "boolean" then tostring else error("invalid merged flag") end' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    sha="$(printf '%s' "$json" | jq -er '(.head.sha // "") | select(type == "string")' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    head_repo="$(printf '%s' "$json" | jq -er '(.head.repo.full_name // "") | select(type == "string")' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    head_ref="$(printf '%s' "$json" | jq -er '(.head.ref // "") | select(type == "string")' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    [ -z "$sha" ] || is_git_oid "$sha" || dm_die "PR returned an invalid head SHA: $url"
    [ "$merged" = "true" ] && state="MERGED"
    # Roll up CI for the head sha from BOTH the check-runs API and the legacy
    # combined commit-status API, worst-wins. A repo whose CI reports only via
    # commit statuses returns an empty check-runs array; taking that alone as
    # "none" would let a red PR merge (violating "never merge red").
    runs_rollup="none"; status_rollup="none"
    if [ -n "$sha" ]; then
      # One maximal page keeps API work bounded. A response that says more runs
      # exist than were returned is unknown, never an incomplete green result.
      runs_rollup="$(check_runs_rollup "$slug" "$sha")"
      status_rollup="$(commit_status_rollup "$slug" "$sha")"
    fi
    rollup="$(worst_rollup "$runs_rollup" "$status_rollup")"
    # mergeable_state (clean/blocked/unstable/dirty/behind/draft/has_hooks/unknown) gates
    # the merge alongside CI; GitHub often reports "unknown" on first fetch.
    merge_state="$(printf '%s' "$json" | jq -er '(.mergeable_state // "unknown") | select(type == "string")' 2>/dev/null)" \
      || dm_die "invalid PR response for $url"
    snapshot="$(jq -cn --arg state "$state" --arg checks "$rollup" \
      --arg merge_state "$merge_state" --arg head "$sha" \
      --arg head_repo "$head_repo" --arg head_ref "$head_ref" \
      '{state:$state, checks:$checks, merge_state:$merge_state, head:$head, head_repo:$head_repo, head_ref:$head_ref}')"
    load_check_snapshot_json "$snapshot" || dm_die "invalid PR/check state returned for $url"
    dm_meta_set "$id" pr_state "$state"
    dm_meta_set "$id" checks "$rollup"
    dm_meta_set "$id" merge_state "$merge_state"
    dm_meta_set "$id" pr_head "$sha"
    dm_meta_set "$id" pr_check_snapshot "$snapshot"
    if [ "$snapshot_only" -eq 1 ]; then
      printf '%s\n' "$snapshot"
    else
      echo "pr: $url · state: $state · checks: $rollup · merge_state: $merge_state"
    fi
    ;;

  await-checks)
    # Poll `check` until the CI rollup is terminal (passing/failing, or none on
    # a confirmed CI-less repo) or the timeout elapses, so a caller (the merge
    # gate, a runtime supervision wait) can WAIT for GitHub Actions rather than
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
      check_out=""
      if check_out="$("$0" check "$id" --snapshot 2>&1)"; then
        if load_check_snapshot_json "$check_out"; then
          checks="$PR_SNAPSHOT_CHECKS"; merge_state="$PR_SNAPSHOT_MERGE_STATE"
          checked_head="$PR_SNAPSHOT_HEAD"
        else
          checks="unknown"; merge_state="unknown"; checked_head=""
          dm_info "await-checks: refresh returned an invalid check snapshot after ${waited}s: $url"
        fi
      else
        checks="unknown"; merge_state="unknown"; checked_head=""
        dm_info "await-checks: refresh failed after ${waited}s: ${check_out:-unknown error}"
      fi
      # Bind terminality to the PR's CURRENT head. Only a candidate-terminal
      # observation (dm_await_needs_head) needs the extra head fetch; when its
      # rolled-up head is stale, empty, or unverifiable, downgrade to a
      # non-terminal rollup so a previous run — or a stale dirty state — can
      # never end the wait early. dm_await_gate then decides the action.
      if dm_await_needs_head "$checks" "$merge_state" "$has_ci"; then
        if expected_head="$(expected_pr_head "$id" "$PR_SNAPSHOT_HEAD_REPO" "$PR_SNAPSHOT_HEAD_REF")"; then
          if [ -z "$checked_head" ]; then
            checks="unknown"; merge_state="unknown"
            dm_info "await-checks: refresh returned no PR head after ${waited}s: $url"
          elif [ "$checked_head" != "$expected_head" ]; then
            checks="pending"; merge_state="unknown"
            dm_info "await-checks: PR head $checked_head has not reached expected head $expected_head after ${waited}s: $url"
          fi
        else
          checks="unknown"; merge_state="unknown"
          dm_info "await-checks: could not reconcile the local and remote expected PR head after ${waited}s: $url"
        fi
      fi
      case "$(dm_await_gate "$checks" "$merge_state" "$has_ci")" in
        dirty)
          dm_info "await-checks: DIRTY after ${waited}s (merge conflict — GitHub runs no checks on an unmergeable PR; rebase first): $url"
          exit 1 ;;
        pass)
          if [ "$checks" = "none" ]; then
            dm_info "await-checks: none after ${waited}s (repo has no CI configured): $url"
          else
            dm_info "await-checks: passing after ${waited}s: $url"
          fi
          exit 0 ;;
        fail)
          dm_info "await-checks: FAILING after ${waited}s: $url"; exit 1 ;;
        wait) : ;;   # pending / unknown / none-with-CI / stale head: keep polling
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
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh merge <id> [--method squash|merge|rebase] [--delete-branch] [--allow-no-checks]"
    dm_require_id "$id"
    # Merge authority is the OUTERMOST gate, checked before GitHub tools are even
    # required and before any GitHub call: a `never` repo can never be merged by
    # the dockmaster — no flag, no --allow-no-checks, no CI state bypasses it.
    # Enforcing it here makes the refusal deterministic offline and independent of
    # the never-merge-red gate that follows. The single carve-out is the
    # operator-granted merge_allowed_bases list (the integration-branch
    # workflow): a `never` repo's PR may proceed ONLY when its live GitHub base
    # branch exactly matches a listed non-default branch — a repo with no list
    # keeps today's unconditional, offline refusal.
    repo="$(dm_meta_get "$id" repo)"
    [ -n "$repo" ] || dm_die "no such task: $id"
    never_exception=0; exception_base=""
    authority="$(dm_merge_authority "$repo")"
    case "$(dm_merge_authority_gate "$authority")" in
      allow) : ;;
      refuse-never)
        allowed_bases="$(dm_merge_allowed_bases "$repo")"
        [ -n "$allowed_bases" ] || dm_die "REFUSED: repo $repo is merge_authority=never: the dockmaster may not merge; the PR is merge-ready — the operator merges it on GitHub"
        # An exception is configured: verify the PR's ACTUAL current base branch
        # live from GitHub — never from task meta, since a PR base can be
        # retargeted on GitHub after `open`. verify_never_exception fails closed
        # on anything unverifiable and enforces both default-branch anchors.
        dm_need gh
        url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
        n="$(pr_number_from_url "$url")"
        slug="$(repo_slug "$repo")"
        exception_base="$(verify_never_exception "$repo" "$slug" "$n" "$url")"
        dm_info "merge-authority exception: repo $repo is merge_authority=never, but PR base '$exception_base' is an operator-granted merge base (merge_allowed_bases); proceeding to the normal merge gates"
        never_exception=1
        ;;
      refuse-invalid) dm_die "REFUSED: cannot resolve merge authority for repo '$repo': it is unregistered, or has an invalid merge_authority ('$(dm_registry_get "$repo" merge_authority)'); refusing to merge. Register it (dm-repo.sh add) or set a valid authority: dm-repo.sh set $repo merge_authority yolo|ask|never" ;;
      *) dm_die "REFUSED: repo $repo merge authority could not be resolved; refusing to merge" ;;
    esac
    # `gh` alone: merge's gates are jq-parsed reads, which only plain gh can
    # serve. That also guarantees the mutation resolver below finds a CLI.
    dm_need gh
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
    check_out=""
    check_out="$("$0" check "$id" --snapshot 2>&1)" \
      || dm_die "REFUSED: check refresh failed for $url: ${check_out:-unknown error}"
    load_check_snapshot_json "$check_out" \
      || dm_die "REFUSED: check returned an invalid state snapshot: $url"
    state="$PR_SNAPSHOT_STATE"; checks="$PR_SNAPSHOT_CHECKS"
    merge_state="$PR_SNAPSHOT_MERGE_STATE"
    checked_head="$PR_SNAPSHOT_HEAD"
    head_repo="$PR_SNAPSHOT_HEAD_REPO"; head_ref="$PR_SNAPSHOT_HEAD_REF"
    case "$state" in
      OPEN) : ;;
      MERGED) dm_die "PR already merged: $url" ;;
      CLOSED) dm_die "PR is closed, refusing to merge: $url" ;;
      *) dm_die "REFUSED: PR state is not confirmed OPEN ($state): $url" ;;
    esac
    # Never merge red. A `none` rollup (no checks reported) does NOT auto-pass:
    # it is the race window after a PR opens but before CI registers. It passes
    # only on an explicit --allow-no-checks AND a confirmed CI-less repo
    # (has_ci=0): once .github/workflows exists, --allow-no-checks can no
    # longer bypass `none` (closes #49) — a repo that gained CI must wait for
    # it, never merge on a rollup that just hasn't registered yet.
    # (repo was resolved above for the merge-authority gate.)
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
    expected_head="$(expected_pr_head "$id" "$head_repo" "$head_ref")" \
      || dm_die "REFUSED: could not reconcile the expected local and remote head for $url"
    [ -n "$checked_head" ] \
      || dm_die "REFUSED: GitHub did not report a PR head for $url"
    [ "$checked_head" = "$expected_head" ] \
      || dm_die "REFUSED: checked PR head $checked_head does not match expected task/remote head $expected_head: $url"
    # mergeable_state gate. Refuse a conflicted, draft, or branch-protection-
    # blocked PR. Do NOT refuse solely on "unknown" (GitHub often hasn't computed
    # it on first fetch); the atomic merge API remains the final backstop.
    case "$merge_state" in
      dirty)   dm_die "REFUSED: PR has merge conflicts (mergeable_state=dirty): $url" ;;
      draft)   dm_die "REFUSED: PR is a draft (mergeable_state=draft): $url" ;;
      blocked) dm_die "REFUSED: required checks/reviews not satisfied (mergeable_state=blocked): $url" ;;
      *) : ;;
    esac
    n="$(pr_number_from_url "$url")"
    slug="$(repo_slug "$repo")"
    if [ "$never_exception" -eq 1 ]; then
      # TOCTOU guard: the base was verified before the CI/mergeable gates above,
      # but GitHub merges into whatever the base is AT MERGE TIME and
      # GitHub has no base-pinned merge — a retarget in that window would land
      # into the new base. Minimize the window: re-run the FULL exception
      # decision (fresh list, fresh live base + defaults, fail closed on any
      # fetch failure) immediately before the mutation, and refuse if the base
      # changed at all since the first check, even to another allowed branch.
      # The residual base-retarget instant is inherent to GitHub's API; the head
      # race is closed separately by the SHA-conditioned merge mutation.
      recheck_base="$(verify_never_exception "$repo" "$slug" "$n" "$url")"
      [ "$recheck_base" = "$exception_base" ] || dm_die "REFUSED: PR base changed from '$exception_base' to '$recheck_base' between verification and merge (retargeted on GitHub); refusing: $url"
    fi
    expected_head="$(expected_pr_head "$id" "$head_repo" "$head_ref")" \
      || dm_die "REFUSED: could not re-verify matching local and remote heads immediately before merge: $url"
    [ "$expected_head" = "$checked_head" ] \
      || dm_die "REFUSED: expected task/remote head changed from $checked_head to $expected_head before merge: $url"
    # GitHub compares sha and merges atomically; a push in the final instant
    # returns conflict instead of merging unchecked code.
    atomic_merge_pull "$slug" "$n" "$checked_head" "$method"
    dm_meta_set "$id" pr_state MERGED
    dm_status_append "$id" merged "$url"
    dm_info "merged: $url"
    [ "$delete" -eq 1 ] && delete_merged_head "$repo" "$slug" "$head_repo" "$head_ref" "$checked_head"
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

  close)
    # Close a PR WITHOUT merging, saying why on the PR itself. Its caller is the
    # trash flow (dm-trash.sh): a discarded task must not leave an open PR
    # inviting someone to merge work the operator abandoned. It never merges and
    # never deletes the remote branch — that branch is the copy of the work that
    # lives outside the clone, so deleting it would narrow recovery to the
    # parked ref alone.
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh close <id> --reason \"<why it is not being merged>\""
    dm_require_id "$id"
    reason=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) [ "$#" -ge 2 ] || dm_die "--reason requires a value"; reason="$2"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    [ -n "$reason" ] || dm_die "--reason is required: a PR closed unmerged must say why"
    dm_require_single_line "close reason" "$reason"
    # Belt for the comment body's `@` hazard above: the fixed prefix already makes
    # a leading `@` unreachable, so this refuses only a value that would rely on
    # that prefix to be safe.
    case "$reason" in
      @*) dm_die "--reason must not start with '@': the GitHub CLI reads a field value beginning with @ as a file to read, and the wrapper CLI has no --raw-field to disable it" ;;
    esac
    repo="$(dm_meta_get "$id" repo)"; [ -n "$repo" ] || dm_die "no such task: $id"
    url="$(dm_meta_get "$id" pr)"; [ -n "$url" ] || dm_die "no PR recorded for $id"
    dm_need gh
    # Refresh before deciding: the recorded state may predate an out-of-band
    # merge, and GitHub accepts `state=closed` on a merged PR without complaint —
    # the merge stays, the PR reads closed, and the record now says the change was
    # abandoned. Only a confirmed-OPEN PR is closed here.
    close_check=""
    close_check="$("$0" check "$id" --snapshot 2>&1)" \
      || dm_die "REFUSED: check refresh failed for $url: ${close_check:-unknown error}"
    load_check_snapshot_json "$close_check" \
      || dm_die "REFUSED: check returned an invalid state snapshot: $url"
    case "$PR_SNAPSHOT_STATE" in
      OPEN) : ;;
      MERGED) dm_die "REFUSED: $url is already MERGED; closing it would record abandoned work over a change that landed. Undoing a landed change is a revert (rollback skill), not a close." ;;
      CLOSED) dm_info "pr already closed: $url"; exit 0 ;;
      *) dm_die "REFUSED: PR state is not confirmed OPEN ($PR_SNAPSHOT_STATE): $url" ;;
    esac
    n="$(pr_number_from_url "$url")"
    slug="$(repo_slug "$repo")"
    # Comment first, and refuse if it fails: a PR closed with no stated reason is
    # exactly the artifact this command exists to avoid.
    comment_pr "$slug" "$n" "Closed without merging: $reason"
    close_pull "$slug" "$n"
    dm_meta_set "$id" pr_state CLOSED
    dm_info "closed without merging: $url"
    ;;

  security-scan)
    # Advisory only: grep the task's diff for security-surface signals and print
    # whether `security-review` should run, so the optional security gate is a
    # deliberate skip rather than a silent one. It NEVER blocks and NEVER decides.
    # Exit code follows grep's sense: 0 = signals found (review recommended),
    # 1 = none found (skip is defensible); a real error (no worktree) dies via
    # dm_die. Local-only: no GitHub tools required.
    #
    # --json ALWAYS exits 0 once the diff was read, answering in `surface`: "no
    # signals" is good news, and a consumer that reads the bare form's exit 1 as
    # a failure loses it and falls back to whatever its default happens to be.
    id="${1:-}"; shift 2>/dev/null || true
    [ -n "$id" ] || dm_die "usage: dm-pr.sh security-scan <id> [--json]"
    want_json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) want_json=1; shift ;;
        *) dm_die "usage: dm-pr.sh security-scan <id> [--json]" ;;
      esac
    done
    dm_require_id "$id"
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    # Same nesting hazard: an unresolvable repo left $base empty, and the scan
    # silently fell back to `git diff HEAD` — the wrong range, reported as a
    # clean advisory result.
    repo_dir="$(dm_repo_dir "$repo")" \
      || dm_die "cannot resolve repo '$repo' to determine the diff base for the scan"
    base="$(dm_default_branch "$repo_dir")"
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
    if [ "$want_json" -eq 1 ]; then
      jq -nc --arg id "$id" --arg hits "$hits" \
        '{id:$id, surface: ($hits != ""), signals: ($hits | split(" ") | map(select(length > 0)))}'
      exit 0
    fi
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
    # no PR, pushes nothing, merges nothing.
    #
    # Online (#107): ONE GraphQL call per PR (sweep_pr_snapshot) replaces the 4
    # sequential REST calls (`check`'s 3 plus a separate reviews fetch) this
    # used to cost, retried with bounded backoff on a transient/rate-limit
    # failure (gh_api_retry), plus a circuit breaker that aborts the sweep
    # early on sustained rate limiting rather than grinding through the whole
    # fleet at the same degraded rate (GH_CIRCUIT_BREAKER_MAX below). An OPEN
    # PR only gets pr_state/checks refreshed in the cache; merge_state/
    # pr_head/pr_check_snapshot are left as they were (this GraphQL query
    # does not populate them, and `merge`/`await-checks` always re-derive
    # them fresh anyway — this path never itself feeds a merge decision). A
    # PR just observed MERGED is the one case that IS safety-relevant
    # (dm-worktree.sh landed trusts pr_head), so it falls back to the full
    # REST `check` there, which writes all five fields exactly as before.
    #
    # Offline (DM_NO_FETCH=1 — how dm-status invokes it): perform NO network. Show
    # the cached pr_state/checks and skip the review query, matching how
    # dm_should_refresh_pr_state degrades offline.
    # --json emits the same walk as one array instead of one line per PR, for
    # the console. Same loop, same semantics: a second walk would drift.
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        *) dm_die "usage: dm-pr.sh sweep [--json]" ;;
      esac
    done
    rows=""
    offline=0
    [ "${DM_NO_FETCH:-0}" = "1" ] && offline=1
    [ "$offline" -eq 1 ] || dm_need gh
    total=0; red=0; changes=0; missing=0; unknown_review=0; unknown_checks=0
    consecutive_exhausted=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      url="$(dm_meta_get "$id" pr)"
      repo="$(dm_meta_get "$id" repo)"
      # A missing clone skips this PR (its slug/rollup are underivable) but must
      # not abort the whole sweep; surface it per-line, never a silent skip.
      # Only exit 2 (no such repo) may degrade to a skipped line; a failed
      # registry read must not be laundered into "clone missing" (see dm-sync).
      rdrc=0; dir="$(dm_repo_dir_or_none "$repo")" || rdrc=$?
      [ "$rdrc" -eq 0 ] || [ "$rdrc" -eq 2 ] || dm_die "sweep: could not resolve repo '$repo' — the registry could not be read"
      if [ "$rdrc" -ne 0 ] || [ ! -d "$dir/.git" ]; then
        missing=$((missing + 1))
        if [ "$json" -eq 1 ]; then
          rows="$rows$(sweep_row "$id" "$repo" "$url" "" "" "" "" "" 0 repo_missing)"$'\n'
        else
          printf '  %s  (repo unregistered or clone missing: %s — skipped)  %s\n' "$id" "${repo:-?}" "$url"
        fi
        continue
      fi
      if [ "$offline" -eq 1 ]; then
        # `?` is a HUMAN placeholder for "never checked"; JSON keeps it empty.
        checks="$(dm_meta_get "$id" checks)"
        state="$(dm_meta_get "$id" pr_state)"
        if [ "$json" -eq 1 ]; then
          rows="$rows$(sweep_row "$id" "$repo" "$url" "$state" "$checks" "" "" "" 1 "")"$'\n'
        else
          printf '  %s  state: %s  checks: %s (cached)  reviews: (no fetch)  %s\n' "$id" "${state:-?}" "${checks:-?}" "$url"
        fi
        case "$checks" in
          failing) red=$((red + 1)) ;;
          unknown) unknown_checks=$((unknown_checks + 1)) ;;
        esac
        continue
      fi
      # Online: one GraphQL call gets state + CI rollup + review verdict
      # together (#107). A read/parse failure is surfaced per-line, never
      # swallowed into a false "clean".
      n="$(pr_number_from_url "$url")"
      slug="$(repo_slug "$repo")"
      owner="${slug%%/*}"; name="${slug#*/}"
      snap=""; snap_rc=0
      snap="$(sweep_pr_snapshot "$owner" "$name" "$n")" || snap_rc=$?
      if [ -z "$snap" ] || ! read_sweep_snapshot "$snap"; then
        # A failure whose exit code is specifically GH_RETRY_EXHAUSTED_RC (as
        # opposed to an ordinary one-shot failure, e.g. a malformed response)
        # is the rate-limit signal the circuit breaker watches:
        # GH_CIRCUIT_BREAKER_MAX of these IN A ROW aborts the sweep rather
        # than grinding through the rest of a large fleet at the same
        # degraded rate.
        if [ "$snap_rc" -eq "$GH_RETRY_EXHAUSTED_RC" ]; then
          consecutive_exhausted=$((consecutive_exhausted + 1))
          if [ "$consecutive_exhausted" -ge "$GH_CIRCUIT_BREAKER_MAX" ]; then
            dm_die "REFUSED: $consecutive_exhausted consecutive PRs exhausted gh's retry budget (sustained rate limiting?) — aborting the sweep early rather than grinding through the rest of the fleet at the same degraded rate. Wait for the rate limit to reset, then retry."
          fi
        else
          consecutive_exhausted=0
        fi
        if [ "$json" -eq 1 ]; then
          rows="$rows$(sweep_row "$id" "$repo" "$url" "" "" "" "" "" 0 github_unreadable)"$'\n'
        else
          printf '  %s  (could not read PR — check failed)  %s\n' "$id" "$url"
        fi
        continue
      fi
      consecutive_exhausted=0
      state="$SWEEP_STATE"; checks="$SWEEP_CHECKS"; review="$SWEEP_REVIEW"
      title="$(printf '%s' "$snap" | jq -r '.title // ""')"
      created="$(printf '%s' "$snap" | jq -r '.created_at // ""')"
      if [ "$state" = "MERGED" ]; then
        if ! "$0" check "$id" >/dev/null 2>&1; then
          if [ "$json" -eq 1 ]; then
            rows="$rows$(sweep_row "$id" "$repo" "$url" "" "" "" "" "" 0 github_unreadable)"$'\n'
          else
            printf '  %s  (could not read PR — check failed)  %s\n' "$id" "$url"
          fi
          continue
        fi
        checks="$(dm_meta_get "$id" checks)"
        state="$(dm_meta_get "$id" pr_state)"
      else
        # Caching what GitHub just said is best-effort, in BOTH directions.
        # (1) Between the enumeration above and this line the task can be archived
        #     by teardown or trash; dm_meta_set refuses a task with no active
        #     record and that refusal is an exit, so it runs where it cannot take
        #     the whole sweep down with it.
        # (2) It must never DOWNGRADE a terminal state someone else established
        #     while this snapshot was in flight: `close` and `merge` write
        #     CLOSED/MERGED, and writing a pre-close OPEN back over that would
        #     resurrect a PR the record had already finished with.
        cached_state="$(dm_meta_get "$id" pr_state)"
        case "$cached_state" in
          MERGED|CLOSED) : ;;
          *)
            write_out=""
            if ! write_out="$( { dm_meta_set "$id" pr_state "$state"; dm_meta_set "$id" checks "$checks"; } 2>&1 )"; then
              dm_warn "sweep: could not cache $id's PR state ($(dm_first_line "${write_out:-no detail}")); the row below is still what GitHub reported"
            fi ;;
        esac
      fi
      case "$checks" in
        failing) red=$((red + 1)) ;;
        unknown) unknown_checks=$((unknown_checks + 1)) ;;
      esac
      case "$review" in
        changes-requested) changes=$((changes + 1)) ;;
        unknown) unknown_review=$((unknown_review + 1)) ;;
      esac
      if [ "$json" -eq 1 ]; then
        rows="$rows$(sweep_row "$id" "$repo" "$url" "$state" "$checks" "$review" "$title" "$created" 0 "")"$'\n'
      else
        printf '  %s  state: %s  checks: %s  reviews: %s  %s\n' "$id" "${state:-?}" "${checks:-?}" "$review" "$url"
      fi
    done < <(dm_open_pr_tasks)
    if [ "$json" -eq 1 ]; then
      printf '%s' "$rows" | jq -s -c '.'
    elif [ "$total" -eq 0 ]; then
      dm_info "  (no open PRs)"
    else
      note=""
      [ "$red" -gt 0 ] && note="$note, $red with red CI"
      [ "$changes" -gt 0 ] && note="$note, $changes with changes requested"
      # unknown is distinct from clean/red: a review truncated past its
      # bounded page, or a CI rollup gh could not confirm, must never read
      # the same as an all-clear fleet — surface it so it gets a look, not
      # a skim-past.
      [ "$unknown_review" -gt 0 ] && note="$note, $unknown_review with an unverified review"
      [ "$unknown_checks" -gt 0 ] && note="$note, $unknown_checks with unknown CI"
      [ "$missing" -gt 0 ] && note="$note, $missing with a missing clone"
      note="${note#, }"
      [ -n "$note" ] && note=" ($note)"
      dm_info "  sweep: $total open PR(s)$note"
    fi
    ;;

  pipeline)
    # The gate track a PR in this repo must CLEAR - the declared list, offline,
    # never a progress claim: nothing here records which gates have run.
    repo="${1:-}"; shift 2>/dev/null || true
    [ -n "$repo" ] || dm_die "usage: dm-pr.sh pipeline <repo> [--json]"
    # Validated before it composes a filename, so a name cannot walk out of config/.
    dm_require_id "$repo"
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        *) dm_die "usage: dm-pr.sh pipeline <repo> [--json]" ;;
      esac
    done
    # A per-repo override is OPERATOR content and lives in DM_HOME; the default
    # is TRACKED DISTRO content, so fall back to the one shipped beside bin/ when
    # DM_HOME is not the distro root.
    file="$DM_CONFIG/pr-pipeline.$repo.json"
    [ -f "$file" ] || file="$DM_CONFIG/pr-pipeline.default.json"
    [ -f "$file" ] || file="$BIN_DIR/../config/pr-pipeline.default.json"
    [ -f "$file" ] \
      || dm_die "no pipeline config for '$repo': neither config/pr-pipeline.$repo.json nor a config/pr-pipeline.default.json (in DM_HOME or beside bin/) exists"
    jq -e '(.gates | type) == "array" and (.gates | length) > 0' "$file" >/dev/null 2>&1 \
      || dm_die "$file declares no gates array; refusing to report an empty gate track"
    if [ "$json" -eq 1 ]; then
      jq -c --arg repo "$repo" --arg config "$(basename "$file")" '
        { repo: $repo, config: $config,
          gates: [ .gates[] | { gate: .gate, pass: (.pass // ""),
                                optional: (.optional == true), note: (.note // "") } ] }' "$file"
    else
      jq -r '.gates[] | .gate
             + (if .pass then " (" + .pass + ")" else "" end)
             + (if .optional == true then " [optional]" else "" end)' "$file"
    fi
    ;;

  url)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-pr.sh url <id>"
    dm_meta_get "$id" pr ;;

  *)
    echo "usage: dm-pr.sh {open|adopt|check|await-checks|merge|close|sweep|pipeline|security-scan|url} ..." >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# dm-lib.sh - shared helpers for the dockmaster toolbelt.
# Source this from other dm-*.sh scripts: . "$(dirname "$0")/dm-lib.sh"
#
# Conventions every dm-* script follows:
#   - Fail closed. Validate inputs before any side effect. A refusal is a
#     signal, never an obstacle to force past.
#   - One owner per format. Task meta and the repo registry each have exactly
#     one reader/writer path (this lib), so the on-disk shape cannot drift.
#   - Never write to a managed repo except through the narrow guarded paths
#     (clone, sync, approved local merge). Those live in their own scripts.

set -euo pipefail

# DM_HOME is the dockmaster distro root (this repo). Resolve from this file's
# location so scripts work regardless of the caller's cwd.
DM_HOME="${DM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export DM_HOME

DM_STATE="$DM_HOME/state"
DM_DATA="$DM_HOME/data"
DM_REPOS="$DM_HOME/repos"
DM_CONFIG="$DM_HOME/config"
DM_REGISTRY="$DM_STATE/repos.json"
DM_TASKS="$DM_STATE/tasks"

dm_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
dm_warn() { printf 'warning: %s\n' "$*" >&2; }
dm_info() { printf '%s\n' "$*"; }

dm_need() { command -v "$1" >/dev/null 2>&1 || dm_die "required tool not found: $1"; }

# --- portable advisory lock: mkdir-based mutex -------------------------------
# Serializes the read-modify-write of a shared-state file across concurrent
# dm-* invocations (parallel crew is the design premise, so unlocked RMW loses
# updates). We use an atomic `mkdir` as the primitive, NOT flock — macOS has no
# flock. THIS HELPER OWNS THE EXIT TRAP: dm_lock arms a trap that removes the
# lock dir so an dm_die/exit inside the critical section cannot leak it, and
# dm_unlock clears it. It is not reentrant: do not nest dm_lock calls in one
# process, and do not set your own EXIT/INT/TERM trap between dm_lock/dm_unlock.
#
# Crash-safety: a holder killed with SIGKILL cannot run its trap, so the lock
# dir survives and would otherwise wedge every future write (~30s spin, then
# hard death). To self-heal, the holder records its PID and an epoch timestamp
# inside the lock dir; a waiter reclaims the lock only on POSITIVE evidence of
# abandonment — the recorded PID is not alive, or the lock is older than
# DM_LOCK_STALE_SECS. Genuine LIVE contention still blocks, then fails visibly.
dm_lock() {
  # dm_lock <file>  -- acquire the advisory lock guarding <file>
  local target="$1" lockdir reclaim waited=0 pid rpid
  lockdir="$target.lock"; reclaim="$lockdir.reclaim"
  while ! mkdir "$lockdir" 2>/dev/null; do
    # The lock is held. Self-heal ONLY a lock abandoned by a crashed holder,
    # identified by concrete evidence: a recorded numeric PID that is not alive.
    # This is unambiguous — owning the lock requires a successful `mkdir`, after
    # which the holder writes its OWN (live) PID, so a dead PID in an existing
    # lock dir can only belong to a crashed holder, never a live owner. An empty
    # or partial PID (a live holder in the microsecond gap between its mkdir and
    # its write) is NOT evidence and is never reclaimed; such a metadata-less
    # crash (astronomically rare) falls through to the visible ~30s timeout.
    # A stuck-but-alive holder is likewise never reclaimed — it fails visibly
    # rather than risk tearing the lock from a process that may still resume.
    pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) : ;;
      *)
        if ! kill -0 "$pid" 2>/dev/null; then
          # Serialize reclaimers with a second lock so exactly one acts, and
          # re-verify the dead PID still owns the dir immediately before removing
          # it. While the lock dir exists holding a dead PID no live holder can
          # own it (owning requires a fresh mkdir, which needs the dir absent),
          # so removing it here cannot tear a live holder away. If another waiter
          # already reclaimed and a live holder took over, the re-read PID is now
          # live (or the dir is gone) and we leave it be.
          if mkdir "$reclaim" 2>/dev/null; then
            rpid="$(cat "$lockdir/pid" 2>/dev/null || true)"
            if [ -d "$lockdir" ] && [ "$rpid" = "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
              dm_warn "reclaiming stale lock on $(basename "$target") (holder pid=$pid not alive; previous holder likely crashed)"
              rm -rf "$lockdir" 2>/dev/null || true
            fi
            rmdir "$reclaim" 2>/dev/null || true
            continue
          fi
        fi
        ;;
    esac
    waited=$((waited + 1))
    if [ "$waited" -ge 300 ]; then
      dm_die "could not acquire lock on $(basename "$target") after ~30s; if no dm-* process is running, remove the stale lock: rm -rf '$lockdir'"
    fi
    sleep 0.1
  done
  # We hold the lock: record our PID so a future waiter can detect our crash.
  printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
  # Clean up on normal exit / dm_die (EXIT), and on signal death. A trapped
  # INT/TERM handler must ALSO terminate: without the explicit exit, bash runs
  # the handler and then RESUMES the (now unlocked) critical section — which
  # would let a waiter acquire and write concurrently. So each signal handler
  # cleans up and exits with the conventional 128+signo code.
  trap "rm -rf '$lockdir' 2>/dev/null || true" EXIT
  trap "rm -rf '$lockdir' 2>/dev/null || true; exit 130" INT
  trap "rm -rf '$lockdir' 2>/dev/null || true; exit 143" TERM
}

dm_unlock() {
  # dm_unlock <file>  -- release the lock and clear the traps
  local lockdir="$1.lock"
  rm -rf "$lockdir" 2>/dev/null || true
  trap - EXIT INT TERM
}

dm_ensure_dirs() {
  mkdir -p "$DM_STATE" "$DM_DATA" "$DM_REPOS" "$DM_CONFIG" "$DM_TASKS"
  [ -f "$DM_REGISTRY" ] || printf '{"repos":{}}\n' > "$DM_REGISTRY"
}

# --- task id validation ------------------------------------------------------
# Path-safe slug, no leading dot, <= 64 chars. Rejected ids never touch disk.
dm_valid_id() {
  case "$1" in
    ''|.*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

dm_require_id() {
  dm_valid_id "$1" || dm_die "invalid task/repo id: '$1' (use [A-Za-z0-9._-], no leading dot, <= 64 chars)"
}

# --- task meta: single owner of state/tasks/<id>.meta ------------------------
# Format is one key=value per line. Values are single-line only.
dm_meta_path() { printf '%s/%s.meta\n' "$DM_TASKS" "$1"; }
dm_status_path() { printf '%s/%s.status\n' "$DM_TASKS" "$1"; }

dm_meta_get() {
  # dm_meta_get <id> <key>  -> prints value or empty. The key is matched as a
  # FIXED string (not a regex); value may itself contain '='; last line wins.
  local f; f="$(dm_meta_path "$1")"
  [ -f "$f" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$f"
}

dm_meta_set() {
  # dm_meta_set <id> <key> <value>  (value must be single-line). The key is
  # matched as a FIXED string (not a regex) when dropping the old line.
  dm_require_id "$1"
  dm_ensure_dirs
  local f tmp; f="$(dm_meta_path "$1")"
  case "$3" in *$'\n'*) dm_die "meta value for '$2' must be single-line" ;; esac
  dm_lock "$f"
  tmp="$(mktemp "$DM_TASKS/.meta.XXXXXX")" || { dm_unlock "$f"; dm_die "mktemp failed for meta '$1'"; }
  # Build into $tmp; on any write failure remove the temp (no orphan) and fail
  # loudly. `|| true` on the read keeps a missing file from tripping set -e.
  {
    [ -f "$f" ] && awk -v k="$2" 'index($0, k "=") != 1' "$f" || true
    printf '%s=%s\n' "$2" "$3"
  } > "$tmp" || { rm -f "$tmp"; dm_unlock "$f"; dm_die "failed writing meta for '$1'"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; dm_unlock "$f"; dm_die "failed committing meta for '$1'"; }
  dm_unlock "$f"
}

# --- status event log: append-only, best effort ------------------------------
# A status line is a WAKE EVENT, not current-state truth. Current state is
# reconciled on demand (dm-task.sh state), never stored as a mutable field.
dm_status_append() {
  # dm_status_append <id> <state> <note>
  dm_require_id "$1"
  dm_ensure_dirs
  printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "${3:-}" >> "$(dm_status_path "$1")"
}

# --- git cleanliness ---------------------------------------------------------
# Uncommitted changes to TRACKED files (staged or unstaged). This is what blocks
# operations that act on the committed head (land, PR push): untracked files do
# not participate in those and must not block them.
dm_tracked_dirty() {
  ! git -C "$1" diff --quiet 2>/dev/null || ! git -C "$1" diff --cached --quiet 2>/dev/null
}

# Untracked, non-ignored files. These are ambiguous (forgotten source vs build
# cruft), so operations that DISCARD a worktree (teardown) fail closed on them.
dm_untracked() { git -C "$1" ls-files --others --exclude-standard 2>/dev/null; }

# --- git helpers -------------------------------------------------------------
# Resolve a repo's default branch: origin/HEAD -> main/master (local or remote)
# -> current branch -> "main". Always prints exactly one line.
dm_default_branch() {
  local dir="$1" ref b
  ref="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  ref="${ref#origin/}"
  if [ -n "$ref" ]; then printf '%s\n' "$ref"; return 0; fi
  for b in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$b" \
       || git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"; return 0
    fi
  done
  b="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$b" ] && [ "$b" != "HEAD" ]; then printf '%s\n' "$b"; return 0; fi
  printf 'main\n'
}

# Resolve the PR base for `dm-pr.sh open`: an explicit --base always wins; else
# the parent ref recorded by `dm-worktree.sh create --base` (a stacked sub-PR
# targets its parent, not the default branch); else the repo's default branch.
dm_pr_base_for() {
  local id="$1" explicit="$2" dir="$3" recorded
  if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
  recorded="$(dm_meta_get "$id" base)"
  if [ -n "$recorded" ]; then printf '%s\n' "$recorded"; return 0; fi
  dm_default_branch "$dir"
}

# --- per-repo memory: the dm-memory hybrid model -----------------------------
# Repo knowledge lives in plain markdown, not a bespoke store (see dm-memory.sh):
# SHARED facts in the repo's own committed AGENTS.md dm:knowledge section (travels
# with every clone/worktree, authored by a crewmate in a worktree), and PRIVATE
# dockmaster notes in git-excluded repos/<repo>/.dm/. The dockmaster never
# force-commits shared knowledge onto a clone's default branch; it lands through
# the normal PR/local flow like any other change.

# --- locked, atomic JSON update ----------------------------------------------
# dm_json_update <file> <jq-args...>  -- apply a jq filter to a JSON file in
# place, serialized by the advisory lock and committed atomically. The temp is
# created in the target's own directory so the final `mv` is a same-filesystem
# rename (atomic); on any failure the temp is removed (no orphan) and we fail
# loudly. Single owner of the "locked read-modify-write of a JSON file" pattern.
dm_json_update() {
  local file="$1"; shift
  local tmp dir base
  dir="$(dirname "$file")"; base="$(basename "$file")"
  dm_lock "$file"
  tmp="$(mktemp "$dir/.$base.XXXXXX")" || { dm_unlock "$file"; dm_die "mktemp failed for $base"; }
  if jq "$@" "$file" > "$tmp"; then
    mv -f "$tmp" "$file" || { rm -f "$tmp"; dm_unlock "$file"; dm_die "failed committing $base"; }
  else
    rm -f "$tmp"; dm_unlock "$file"; dm_die "update (jq) of $base failed"
  fi
  dm_unlock "$file"
}

# --- registry (repos.json): single owner path via jq ------------------------
dm_registry_get() {
  # dm_registry_get <name> [<field>]  -> prints repo object or a field
  dm_ensure_dirs
  if [ -n "${2:-}" ]; then
    jq -r --arg n "$1" --arg f "$2" '.repos[$n][$f] // empty' "$DM_REGISTRY"
  else
    jq -e --arg n "$1" '.repos[$n]' "$DM_REGISTRY" 2>/dev/null
  fi
}

# dm_merge_authority <name>  -> the repo's effective merge authority, one of
# yolo|ask|never|invalid. Single owner of the value AND its legacy migration.
#   - A stored `merge_authority` of yolo|ask|never is returned verbatim.
#   - A stored `merge_authority` that is present but NOT one of those three is a
#     corrupt/hand-broken value: it returns `invalid` so the merge/land gate can
#     FAIL CLOSED (a typo like "nevr" must never be silently downgraded to a
#     permissive posture). It is NOT re-derived from the legacy boolean.
#   - Only an ABSENT/empty `merge_authority` falls back to the retired boolean
#     `yolo` (true -> yolo, false/absent -> ask) — the legacy-registry migration.
# The repo object is snapshotted with ONE file read (`jq -c` of `.repos[$n]`) so a
# concurrent `dm-repo.sh set` cannot interleave between reads of the two fields;
# `merge_authority` and `yolo` are then extracted from that in-memory snapshot,
# not the file. The extraction pulls the WHOLE stored `merge_authority` string
# (any embedded tab/newline included) and validates it EXACTLY against
# yolo|ask|never — a hand-corrupted value like "yolo\tx" must not be truncated to
# a valid-looking prefix and pass. Every merge/landing path and the `list` display
# read authority through here.
dm_merge_authority() {
  dm_ensure_dirs
  local name="$1" obj ma yolo
  # Snapshot the repo object (compact, single line) with the sole file read. A
  # missing repo yields "{}", which reads as the legacy default (ask) below.
  obj="$(jq -c --arg n "$name" '.repos[$n] // {}' "$DM_REGISTRY" 2>/dev/null)"
  # Extract each field from the snapshot string, not the file — the exact decoded
  # value, validated whole. `$(...)` strips only a trailing newline, so an
  # embedded tab or newline survives into $ma and fails the exact match below.
  ma="$(printf '%s' "$obj" | jq -r '.merge_authority // "" | tostring')"
  yolo="$(printf '%s' "$obj" | jq -r 'if .yolo == true then "true" else "false" end')"
  case "$ma" in
    yolo|ask|never) printf '%s\n' "$ma"; return 0 ;;
    "")             : ;;                       # absent -> legacy derivation below
    *)              printf 'invalid\n'; return 0 ;;   # corrupt -> fail closed
  esac
  case "$yolo" in
    true) printf 'yolo\n' ;;
    *)    printf 'ask\n' ;;
  esac
}

# dm_merge_allowed_bases <name>  -> the repo's operator-granted merge-exception
# base branches (registry field `merge_allowed_bases`, a JSON array of strings),
# one per line; prints nothing when the field is absent/empty. Same snapshot
# discipline as dm_merge_authority: ONE file read of the repo object, so a
# concurrent `dm-repo.sh set` cannot interleave between reads. Non-string
# entries in a hand-corrupted array are dropped (fail closed: a corrupt entry
# grants nothing); a whitespace-containing entry survives here but can never
# match in dm_merge_base_exception, which refuses whitespace bases.
dm_merge_allowed_bases() {
  dm_ensure_dirs
  local obj
  obj="$(jq -c --arg n "$1" '.repos[$n] // {}' "$DM_REGISTRY" 2>/dev/null)" || return 0
  printf '%s' "$obj" | jq -r '.merge_allowed_bases // [] | if type == "array" then .[] else empty end | select(type == "string")' 2>/dev/null || true
}

# dm_repo_dir <name>  -> print the managed clone's directory, or die if absent.
# Single owner of "resolve a registered repo's clone path"; every script that
# needs a repo's working tree goes through here so the error is identical.
dm_repo_dir() {
  local name="$1" dir
  dir="$DM_HOME/$(dm_registry_get "$name" path)"
  [ -d "$dir/.git" ] || dm_die "no clone for repo '$name' (expected $dir); add it with dm-repo.sh add"
  printf '%s\n' "$dir"
}

# dm_require_worktree <id>  -> print the task's recorded worktree path, or die
# if none is recorded or the path no longer exists on disk (a stale/torn-down
# record). Single owner of "resolve a task's worktree or refuse" so every
# caller reports the same thing on a missing worktree, and so the `-d` check
# cannot silently drop out of one call site (dm-worktree.sh remove used to
# check only non-empty before this consolidation).
dm_require_worktree() {
  local wt; wt="$(dm_meta_get "$1" worktree)"
  [ -n "$wt" ] && [ -d "$wt" ] || dm_die "no worktree for $1"
  printf '%s\n' "$wt"
}

# --- FF-sync-with-fallback reaction: shared by callers that best-effort sync a
# clone around a landing action -----------------------------------------------
# dm_sync_reaction <repo> <sync_out> <die|warn>  -- given the STUCK/SKIP/OK line
# `dm-sync.sh one <repo>` printed (or the synthetic "STUCK: sync failed
# unexpectedly" line a caller substitutes when the sync command itself errors
# under set -e), report it the way each current caller does:
#   worktree create (die):  STUCK -> dm_die (refuses to cut a worktree off a
#                            base that isn't fast-forwardable); SKIP -> dm_warn
#                            "...; base may be stale"; OK -> silent.
#   pr merge (warn):        STUCK -> dm_warn (the merge already landed and is
#                            recorded; a can't-FF sync must not fail it, only
#                            name the manual fallback); SKIP/OK -> dm_info the
#                            raw line.
# This function does NOT run the sync itself: dm-sync.sh also sources dm-lib.sh,
# so dm-lib.sh invoking it would reintroduce the same upward dependency #56
# removed for dm-pr.sh (dm-lib.sh has no outbound dm-*.sh call). Each caller
# still runs `dm-sync.sh one <repo>` (with the STUCK fallback on an unexpected
# failure) itself and passes the resulting line in here to interpret.
dm_sync_reaction() {
  local repo="$1" sync_out="$2" reaction="$3"
  case "$sync_out" in
    STUCK:*)
      if [ "$reaction" = die ]; then
        dm_die "clone $repo is not fast-forwardable to origin — resolve it, then retry ($sync_out)"
      else
        dm_warn "post-merge sync: $sync_out — sync $repo manually"
      fi
      ;;
    SKIP:*)
      if [ "$reaction" = die ]; then dm_warn "$sync_out; base may be stale"
      else dm_info "$sync_out"; fi
      ;;
    *)
      # A bare `[ ... ] && cmd` here would trip `set -e` when the test is false
      # (this is the last statement of the arm, not part of a larger `&&`/`||`
      # chain or an if-condition) — use `if` so a "die"-reaction no-op never
      # aborts the caller.
      if [ "$reaction" = warn ]; then dm_info "$sync_out"; fi
      ;;
  esac
}

# --- live PR-state refresh: the out-of-band-merge drift guard -----------------
# The cached pr_state meta field goes stale when a PR is merged out of band
# (the operator merges in the GitHub web UI — common), so state/landed decisions
# that trust it report `working` forever. `state` and `landed` refresh it live,
# before their decision, by running `dm-pr.sh check` themselves — but only when
# there is a PR to check and the task is not already MERGED. Offline mode
# (DM_NO_FETCH=1, used by dm-status and the smoke tests) skips the network and
# trusts the cached value.
#
# This predicate decides WHETHER to refresh; it does not shell out to dm-pr.sh
# itself. dm-pr.sh sources dm-lib.sh, so dm-lib.sh invoking dm-pr.sh would be a
# module cycle (the foundation depending on one of its own consumers) —
# dm-lib.sh has no outbound dm-*.sh call. Each caller (dm-task.sh state,
# dm-worktree.sh landed) runs the check itself, best-effort, when this returns
# true: a failed check must not abort the caller's decision, it just falls back
# to the cached pr_state. Single owner of the predicate so `state` and `landed`
# refresh under identical conditions.
dm_should_refresh_pr_state() {
  # dm_should_refresh_pr_state <id>  -- exit 0 (should refresh) / 1 (skip)
  [ "${DM_NO_FETCH:-0}" = "1" ] && return 1
  [ -n "$(dm_meta_get "$1" pr)" ] || return 1
  [ "$(dm_meta_get "$1" pr_state)" = "MERGED" ] && return 1
  return 0
}

# --- merge check-gate decision (never merge red) -----------------------------
# Decide whether a CI rollup permits a merge, as a pure function so it is
# testable offline. `none` (no checks reported) does NOT auto-pass: it is the
# window after a PR opens but before CI registers — and we cannot reliably tell
# "no CI configured" from "CI not yet reported" from the rollup alone. So `none`
# passes ONLY when the operator has explicitly acknowledged a CI-less repo
# (--allow-no-checks) AND the caller confirms no CI is configured (has_ci=0);
# merging a genuinely CI-less repo is thus a conscious, logged choice rather
# than an inference that could silently merge red. `has_ci` (derived from
# `.github/workflows` presence) is used ONLY in this safe direction — to FORBID
# the --allow-no-checks bypass once CI exists — NEVER to auto-pass `none`: a
# repo can run external CI (commit statuses) with no .github/workflows, so a
# missing directory never implies "safe to skip checks" on its own, only
# `has_ci=0` narrows what --allow-no-checks may bypass. Prints one of:
#   allow | refuse-failing | refuse-pending | refuse-none | refuse-unknown
dm_merge_gate() {
  # dm_merge_gate <rollup> <allow_no_checks:0|1> <has_ci:0|1>
  case "$1" in
    passing) printf 'allow\n' ;;
    failing) printf 'refuse-failing\n' ;;
    pending) printf 'refuse-pending\n' ;;
    none)    if [ "$2" = "1" ] && [ "$3" = "0" ]; then printf 'allow\n'; else printf 'refuse-none\n'; fi ;;
    *)       printf 'refuse-unknown\n' ;;
  esac
}

# --- merge authority gate: the "never merge in this repo" hard stop -----------
# Decide whether the dockmaster may merge/land in a repo with this authority, as
# a pure function so it is testable offline (like dm_merge_gate). This is a
# SEPARATE, earlier gate than the never-merge-red check: it fires before any CI
# rollup is even consulted. `never` is an absolute refusal no flag can bypass;
# `ask`/`yolo` both permit the merge MECHANICS here (the operator-approval part
# of `ask` stays a skill-layer duty). A `never` repo refuses; a corrupt/`invalid`
# authority (or any unrecognized token) also FAILS CLOSED to a distinct
# `refuse-invalid` so the caller can name the bad value and the fix — the safe
# direction for a merge gate. Prints: allow | refuse-never | refuse-invalid.
dm_merge_authority_gate() {
  # dm_merge_authority_gate <authority>
  case "$1" in
    yolo|ask) printf 'allow\n' ;;
    never)    printf 'refuse-never\n' ;;
    *)        printf 'refuse-invalid\n' ;;
  esac
}

# --- merge-base exception: the branch-scoped carve-out for a `never` repo -----
# Decide whether an operator-granted base-branch exception lets a PR merge
# proceed past a `never` authority, as a pure function (offline, no side
# effects, testable like dm_merge_gate). The exception exists for the
# integration-branch workflow: sub-PRs targeting a long-lived feature branch may
# be merged, while any PR targeting the default branch stays hard-refused.
# Fail closed on every edge:
#   - applies ONLY to authority `never` (ask/yolo/invalid/anything else print
#     `refuse` — callers must not consult it for those; ask/yolo never reach it);
#   - `allow` iff <base> is non-empty, whitespace-free, differs from
#     <default_branch>, and EXACTLY (full-string) matches one allowed base;
#   - an empty/unknown <default_branch> refuses (the default branch must NEVER
#     be mergeable under `never`, so an unverifiable one cannot be ruled out).
# Prints: allow | refuse.
dm_merge_base_exception() {
  # dm_merge_base_exception <authority> <base> <default_branch> <allowed_bases_newline_separated>
  local authority="$1" base="$2" default_branch="$3" allowed="$4" line
  [ "$authority" = "never" ] || { printf 'refuse\n'; return 0; }
  [ -n "$base" ] || { printf 'refuse\n'; return 0; }
  case "$base" in *[[:space:]]*) printf 'refuse\n'; return 0 ;; esac
  [ -n "$default_branch" ] || { printf 'refuse\n'; return 0; }
  [ "$base" != "$default_branch" ] || { printf 'refuse\n'; return 0; }
  while IFS= read -r line; do
    if [ "$line" = "$base" ]; then printf 'allow\n'; return 0; fi
  done <<EOF
$allowed
EOF
  printf 'refuse\n'
}

# --- all task ids: the "$DM_TASKS/*.meta glob -> id" idiom -------------------
# Prints, one per line, every task id that has a meta file. Single owner of the
# glob + existence-guard (protects against a literal no-match glob when
# nullglob is unset, the case for every caller except dm-status.sh) so the
# iteration idiom cannot drift between call sites. Ordering follows the shell
# glob (task-id order).
dm_all_task_ids() {
  local m
  for m in "$DM_TASKS"/*.meta; do
    [ -f "$m" ] || continue
    basename "$m" .meta
  done
}

# --- open-PR task selector: which tasks the fleet PR sweep visits ------------
# Prints, one id per line, every task meta that records an OPEN pull request: a
# non-empty `pr` whose cached `pr_state` is neither MERGED nor CLOSED. Pure and
# offline (reads only task meta, no network), so the sweep's SELECTION is
# testable without GitHub. pr_state may be empty (a PR opened but never checked);
# that still counts as open.
dm_open_pr_tasks() {
  local id pr st
  while IFS= read -r id; do
    pr="$(dm_meta_get "$id" pr)"
    [ -n "$pr" ] || continue
    st="$(dm_meta_get "$id" pr_state)"
    case "$st" in MERGED|CLOSED) continue ;; esac
    printf '%s\n' "$id"
  done < <(dm_all_task_ids)
}

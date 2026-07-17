#!/usr/bin/env bash
# mh-lib.sh - shared helpers for the manhandler toolbelt.
# Source this from other mh-*.sh scripts: . "$(dirname "$0")/mh-lib.sh"
#
# Conventions every mh-* script follows:
#   - Fail closed. Validate inputs before any side effect. A refusal is a
#     signal, never an obstacle to force past.
#   - One owner per format. Task meta and the repo registry each have exactly
#     one reader/writer path (this lib), so the on-disk shape cannot drift.
#   - Never write to a managed repo except through the narrow guarded paths
#     (clone, sync, approved local merge). Those live in their own scripts.

set -euo pipefail

# MH_HOME is the manhandler distro root (this repo). Resolve from this file's
# location so scripts work regardless of the caller's cwd.
MH_HOME="${MH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export MH_HOME

MH_STATE="$MH_HOME/state"
MH_DATA="$MH_HOME/data"
MH_REPOS="$MH_HOME/repos"
MH_CONFIG="$MH_HOME/config"
MH_REGISTRY="$MH_STATE/repos.json"
MH_TASKS="$MH_STATE/tasks"

mh_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
mh_warn() { printf 'warning: %s\n' "$*" >&2; }
mh_info() { printf '%s\n' "$*"; }

mh_need() { command -v "$1" >/dev/null 2>&1 || mh_die "required tool not found: $1"; }

# --- portable advisory lock: mkdir-based mutex -------------------------------
# Serializes the read-modify-write of a shared-state file across concurrent
# mh-* invocations (parallel crew is the design premise, so unlocked RMW loses
# updates). We use an atomic `mkdir` as the primitive, NOT flock — macOS has no
# flock. THIS HELPER OWNS THE EXIT TRAP: mh_lock arms a trap that removes the
# lock dir so an mh_die/exit inside the critical section cannot leak it, and
# mh_unlock clears it. It is not reentrant: do not nest mh_lock calls in one
# process, and do not set your own EXIT/INT/TERM trap between mh_lock/mh_unlock.
#
# Crash-safety: a holder killed with SIGKILL cannot run its trap, so the lock
# dir survives and would otherwise wedge every future write (~30s spin, then
# hard death). To self-heal, the holder records its PID and an epoch timestamp
# inside the lock dir; a waiter reclaims the lock only on POSITIVE evidence of
# abandonment — the recorded PID is not alive, or the lock is older than
# MH_LOCK_STALE_SECS. Genuine LIVE contention still blocks, then fails visibly.
MH_LOCK_STALE_SECS="${MH_LOCK_STALE_SECS:-300}"

mh_lock() {
  # mh_lock <file>  -- acquire the advisory lock guarding <file>
  local target="$1" lockdir stage waited=0 pid epoch now age stale sig prev_sig="" cur_pid
  lockdir="$target.lock"
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Read the current holder's metadata. A partial/unreadable value is treated
    # as "unknown" (empty), never trusted as evidence of a live holder.
    pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    epoch="$(cat "$lockdir/epoch" 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || echo 0)"
    stale=0; age=""
    # Abandonment is judged ONLY from CONCRETE evidence: (a) a recorded numeric
    # PID that is not alive, or (b) a recorded numeric epoch older than the stale
    # bound (also covers PID reuse). Empty/partial metadata is NEVER treated as
    # stale: an empty signature aliases across distinct holders (each is briefly
    # metadata-less in the microsecond gap between its mkdir and its writes), so
    # reclaiming on it could tear a live holder's lock away. A lock that stays
    # metadata-less (a crash in that gap — astronomically rare) instead falls
    # through to the visible ~30s acquisition timeout below.
    case "$pid" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "$pid" 2>/dev/null || stale=1 ;;
    esac
    case "$epoch" in
      ''|*[!0-9]*) : ;;
      *) age=$((now - epoch)); [ "$age" -ge "$MH_LOCK_STALE_SECS" ] && stale=1 ;;
    esac
    # Reclaim ONLY a lock whose (concrete) identity was observed UNCHANGED across
    # a poll interval AND looked abandoned both times. A live lock under genuine
    # contention recycles fast — its (pid,epoch) changes on every acquisition — so
    # a repeated-identical stale observation cannot be a live holder; it is a
    # frozen (crashed) one. This is the load-bearing guard against reclaiming a
    # lock out from under a live holder during normal parallel writes.
    sig="$pid|$epoch"
    if [ "$stale" -eq 1 ] && [ "$sig" = "$prev_sig" ]; then
      # Claim the stale dir by an ATOMIC rename so two waiters cannot both reclaim
      # and race a fresh holder in between: exactly one `mv` of a given directory
      # instance wins. Re-verify the moved dir's FULL signature (pid AND epoch)
      # still matches the instance we judged; if it does not, we moved a recycled
      # (live) holder — restore it. Comparing the epoch too, not just the pid,
      # closes a PID-reuse race: a recycled live holder always writes a fresh
      # epoch, so it can never alias the frozen (pid,epoch) of the crashed one.
      stage="$lockdir.stale.$$"
      if mv "$lockdir" "$stage" 2>/dev/null; then
        cur_pid="$(cat "$stage/pid" 2>/dev/null || true)"
        cur_epoch="$(cat "$stage/epoch" 2>/dev/null || true)"
        if [ "$cur_pid" = "$pid" ] && [ "$cur_epoch" = "$epoch" ]; then
          mh_warn "reclaiming stale lock on $(basename "$target") (holder pid=${pid:-?}${age:+ age=${age}s}); previous holder likely crashed"
          rm -rf "$stage" 2>/dev/null || true
        else
          mv "$stage" "$lockdir" 2>/dev/null || rm -rf "$stage" 2>/dev/null || true
        fi
      fi
      prev_sig=""   # require a fresh two-observation cycle after any attempt
      continue
    fi
    prev_sig="$sig"
    waited=$((waited + 1))
    if [ "$waited" -ge 300 ]; then
      mh_die "could not acquire lock on $(basename "$target") after ~30s; if no mh-* process is running, remove the stale lock: rm -rf '$lockdir'"
    fi
    sleep 0.1
  done
  # We hold the lock: record ownership so a future waiter can detect our crash.
  # PID first (a single small write, effectively atomic) so liveness is knowable
  # as early as possible; the epoch bounds a stuck-but-live holder.
  printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
  date +%s > "$lockdir/epoch" 2>/dev/null || true
  # Expand the lock path into the trap string NOW so cleanup survives mh_die/exit,
  # and cover signal deaths (INT/TERM) as well as a normal EXIT.
  trap "rm -rf '$lockdir' 2>/dev/null || true" EXIT INT TERM
}

mh_unlock() {
  # mh_unlock <file>  -- release the lock and clear the traps
  local lockdir="$1.lock"
  rm -rf "$lockdir" 2>/dev/null || true
  trap - EXIT INT TERM
}

mh_ensure_dirs() {
  mkdir -p "$MH_STATE" "$MH_DATA" "$MH_REPOS" "$MH_CONFIG" "$MH_TASKS"
  [ -f "$MH_REGISTRY" ] || printf '{"repos":{}}\n' > "$MH_REGISTRY"
}

# --- task id validation ------------------------------------------------------
# Path-safe slug, no leading dot, <= 64 chars. Rejected ids never touch disk.
mh_valid_id() {
  case "$1" in
    ''|.*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

mh_require_id() {
  mh_valid_id "$1" || mh_die "invalid task/repo id: '$1' (use [A-Za-z0-9._-], no leading dot, <= 64 chars)"
}

# --- task meta: single owner of state/tasks/<id>.meta ------------------------
# Format is one key=value per line. Values are single-line only.
mh_meta_path() { printf '%s/%s.meta\n' "$MH_TASKS" "$1"; }
mh_status_path() { printf '%s/%s.status\n' "$MH_TASKS" "$1"; }

mh_meta_get() {
  # mh_meta_get <id> <key>  -> prints value or empty. The key is matched as a
  # FIXED string (not a regex); value may itself contain '='; last line wins.
  local f; f="$(mh_meta_path "$1")"
  [ -f "$f" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$f"
}

mh_meta_set() {
  # mh_meta_set <id> <key> <value>  (value must be single-line). The key is
  # matched as a FIXED string (not a regex) when dropping the old line.
  mh_require_id "$1"
  mh_ensure_dirs
  local f tmp; f="$(mh_meta_path "$1")"
  case "$3" in *$'\n'*) mh_die "meta value for '$2' must be single-line" ;; esac
  mh_lock "$f"
  tmp="$(mktemp "$MH_TASKS/.meta.XXXXXX")" || { mh_unlock "$f"; mh_die "mktemp failed for meta '$1'"; }
  # Build into $tmp; on any write failure remove the temp (no orphan) and fail
  # loudly. `|| true` on the read keeps a missing file from tripping set -e.
  {
    [ -f "$f" ] && awk -v k="$2" 'index($0, k "=") != 1' "$f" || true
    printf '%s=%s\n' "$2" "$3"
  } > "$tmp" || { rm -f "$tmp"; mh_unlock "$f"; mh_die "failed writing meta for '$1'"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; mh_unlock "$f"; mh_die "failed committing meta for '$1'"; }
  mh_unlock "$f"
}

# --- status event log: append-only, best effort ------------------------------
# A status line is a WAKE EVENT, not current-state truth. Current state is
# reconciled on demand (mh-task.sh state), never stored as a mutable field.
mh_status_append() {
  # mh_status_append <id> <state> <note>
  mh_require_id "$1"
  mh_ensure_dirs
  printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "${3:-}" >> "$(mh_status_path "$1")"
}

# --- git cleanliness ---------------------------------------------------------
# Uncommitted changes to TRACKED files (staged or unstaged). This is what blocks
# operations that act on the committed head (land, PR push): untracked files do
# not participate in those and must not block them.
mh_tracked_dirty() {
  ! git -C "$1" diff --quiet 2>/dev/null || ! git -C "$1" diff --cached --quiet 2>/dev/null
}

# Untracked, non-ignored files. These are ambiguous (forgotten source vs build
# cruft), so operations that DISCARD a worktree (teardown) fail closed on them.
mh_untracked() { git -C "$1" ls-files --others --exclude-standard 2>/dev/null; }

# --- git helpers -------------------------------------------------------------
# Resolve a repo's default branch: origin/HEAD -> main/master (local or remote)
# -> current branch -> "main". Always prints exactly one line.
mh_default_branch() {
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

# --- per-repo memory: the mh-memory hybrid model -----------------------------
# Repo knowledge lives in plain markdown, not a bespoke store (see mh-memory.sh):
# SHARED facts in the repo's own committed AGENTS.md mh:knowledge section (travels
# with every clone/worktree, authored by a crewmate in a worktree), and PRIVATE
# manhandler notes in git-excluded repos/<repo>/.mh/. The manhandler never
# force-commits shared knowledge onto a clone's default branch; it lands through
# the normal PR/local flow like any other change.

# --- locked, atomic JSON update ----------------------------------------------
# mh_json_update <file> <jq-args...>  -- apply a jq filter to a JSON file in
# place, serialized by the advisory lock and committed atomically. The temp is
# created in the target's own directory so the final `mv` is a same-filesystem
# rename (atomic); on any failure the temp is removed (no orphan) and we fail
# loudly. Single owner of the "locked read-modify-write of a JSON file" pattern.
mh_json_update() {
  local file="$1"; shift
  local tmp dir base
  dir="$(dirname "$file")"; base="$(basename "$file")"
  mh_lock "$file"
  tmp="$(mktemp "$dir/.$base.XXXXXX")" || { mh_unlock "$file"; mh_die "mktemp failed for $base"; }
  if jq "$@" "$file" > "$tmp"; then
    mv -f "$tmp" "$file" || { rm -f "$tmp"; mh_unlock "$file"; mh_die "failed committing $base"; }
  else
    rm -f "$tmp"; mh_unlock "$file"; mh_die "update (jq) of $base failed"
  fi
  mh_unlock "$file"
}

# --- registry (repos.json): single owner path via jq ------------------------
mh_registry_get() {
  # mh_registry_get <name> [<field>]  -> prints repo object or a field
  mh_ensure_dirs
  if [ -n "${2:-}" ]; then
    jq -r --arg n "$1" --arg f "$2" '.repos[$n][$f] // empty' "$MH_REGISTRY"
  else
    jq -e --arg n "$1" '.repos[$n]' "$MH_REGISTRY" 2>/dev/null
  fi
}

# mh_repo_dir <name>  -> print the managed clone's directory, or die if absent.
# Single owner of "resolve a registered repo's clone path"; every script that
# needs a repo's working tree goes through here so the error is identical.
mh_repo_dir() {
  local name="$1" dir
  dir="$MH_HOME/$(mh_registry_get "$name" path)"
  [ -d "$dir/.git" ] || mh_die "no clone for repo '$name' (expected $dir); add it with mh-repo.sh add"
  printf '%s\n' "$dir"
}

# --- live PR-state refresh: the out-of-band-merge drift guard -----------------
# The cached pr_state meta field goes stale when a PR is merged out of band
# (the operator merges in the GitHub web UI — common), so state/landed decisions
# that trust it report `working` forever. Refresh pr_state from GitHub via
# `mh-pr.sh check` (which updates the meta) before such a decision, but only
# when there is a PR to check and the task is not already MERGED. Offline mode
# (MH_NO_FETCH=1, used by mh-status and the smoke tests) skips the network and
# trusts the cached value. Best effort: a failed check must not abort the
# caller's decision — it falls back to the cached pr_state. Single owner so
# `state` and `landed` refresh identically.
mh_refresh_pr_state() {
  # mh_refresh_pr_state <id>
  [ "${MH_NO_FETCH:-0}" = "1" ] && return 0
  [ -n "$(mh_meta_get "$1" pr)" ] || return 0
  [ "$(mh_meta_get "$1" pr_state)" = "MERGED" ] && return 0
  "$(dirname "${BASH_SOURCE[0]}")/mh-pr.sh" check "$1" >/dev/null 2>&1 || true
}

# --- merge check-gate decision (never merge red) -----------------------------
# Decide whether a CI rollup permits a merge, as a pure function so it is
# testable offline. `none` (no checks reported) does NOT auto-pass: it is the
# window after a PR opens but before CI registers, and treating it as green
# would merge red. It passes only when the caller proved there is nothing to
# wait for — an explicit --allow-no-checks (has_no_checks=1) or a repo with no
# CI configured (has_ci=0). Prints one of:
#   allow | refuse-failing | refuse-pending | refuse-none | refuse-unknown
mh_merge_gate() {
  # mh_merge_gate <rollup> <allow_no_checks:0|1> <has_ci:0|1>
  case "$1" in
    passing) printf 'allow\n' ;;
    failing) printf 'refuse-failing\n' ;;
    pending) printf 'refuse-pending\n' ;;
    none)    if [ "$2" = "1" ] || [ "$3" = "0" ]; then printf 'allow\n'; else printf 'refuse-none\n'; fi ;;
    *)       printf 'refuse-unknown\n' ;;
  esac
}

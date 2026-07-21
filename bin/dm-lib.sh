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
DM_HOME="${DM_HOME:-$(dirname "${BASH_SOURCE[0]}")/..}"
# Canonicalized whenever it already exists: git records worktree paths
# PHYSICALLY, so a symlinked DM_HOME (macOS /var -> /private/var, any symlinked
# TMPDIR) makes every recorded-path-vs-git comparison miss. A first run creates
# DM_HOME later via dm_ensure_dirs; by the time any path is recorded it exists,
# so it is canonical from then on.
if _dm_real_home="$(cd "$DM_HOME" 2>/dev/null && pwd -P)"; then DM_HOME="$_dm_real_home"; fi
unset _dm_real_home
export DM_HOME

# The distro's own reserved repo name. It is NOT in the registry and must never
# be added: dm_repo_dir_or_none resolves it to $DM_HOME explicitly, by name, so
# dockmaster's self-ship lifecycle (worktree/assert/landed/remove) works while a
# typo still dies at the resolver. Mutating the distro stays refused regardless
# (dm_assert_not_distro), and its merge authority is `never`.
DM_DISTRO_REPO="dockmaster"

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

# --- GitHub CLI resolution ---------------------------------------------------
# Plain `gh` is the SUPPORTED BASELINE for every GitHub call; `gh-axi` is the
# operator's private wrapper (no public install path) and only ever a preferred
# enhancement. Two rules keep the two apart:
#   - MUTATIONS (pr create, repo create, the merge PUT) go through the resolver
#     below and must handle both binaries' argv shapes at the call site.
#   - READS PARSED BY jq always call `gh api` directly, never the resolver:
#     `gh-axi api` emits YAML, so routing a parsed read through it would parse
#     the wrong shape.
dm_github_cli() {
  # dm_github_cli -> print the mutation CLI (gh-axi preferred, else gh); exit 1
  # when neither is installed.
  if command -v gh-axi >/dev/null 2>&1; then printf 'gh-axi\n'; return 0; fi
  command -v gh >/dev/null 2>&1 || return 1
  printf 'gh\n'
}

dm_require_github_cli() {
  # Same, but dies naming `gh` — the tool an adopter can actually install.
  dm_github_cli && return 0
  dm_die "required tool not found: gh (the GitHub CLI) — install it from https://cli.github.com, then run: gh auth login"
}

# dm_pr_delivery_gate <gh_present:0|1> <gh_authenticated:0|1> -> ready | no-cli |
# no-auth. Pure so dm-doctor's verdict is testable offline (like dm_merge_gate):
# doctor probes, this decides. gh-axi is deliberately NOT an input — it can
# neither enable nor block the PR path.
dm_pr_delivery_gate() {
  case "$1" in 1) ;; *) printf 'no-cli\n'; return 0 ;; esac
  case "$2" in 1) printf 'ready\n' ;; *) printf 'no-auth\n' ;; esac
}

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
# hard death). To self-heal, the holder records its PID inside the lock dir; a
# waiter reclaims it only on POSITIVE evidence of abandonment — the recorded PID
# is not alive. There is no age-based reclaim: elapsed time is not evidence that
# a holder is gone. Genuine LIVE contention still blocks, then fails visibly.

# Spins (at 0.1s) a blocking reclaim marker must survive before it counts as
# abandoned. A real reclaim is a few filesystem calls, so 5s is a vast margin.
DM_LOCK_RECLAIM_STALL_SPINS=50

# Acquire the reclaim mutex that serializes reclaimers, self-healing one leaked
# by a reclaimer that died mid-reclaim. Before #122 this marker was unstamped
# and untrapped, so ONE killed reclaimer disabled dead-lock recovery forever.
# Two independent heals, because the marker must never be the permanent wedge:
#   - a recorded PID that is not alive (positive evidence, as for the lock);
#   - no usable PID, but the marker has blocked us for <stalled> spins. Age is
#     valid evidence HERE and not for the lock itself: this critical section is
#     bounded and tiny, so a marker outliving it by 5s cannot have a live owner.
# Returns 0 holding the mutex; 1 otherwise (caller retries on the next spin).
dm_lock_acquire_reclaim() {
  local reclaim="$1" stalled="$2" rcpid
  if mkdir "$reclaim" 2>/dev/null; then
    printf '%s\n' "$$" > "$reclaim/pid" 2>/dev/null || true
    return 0
  fi
  rcpid="$(cat "$reclaim/pid" 2>/dev/null || true)"
  case "$rcpid" in
    ''|*[!0-9]*)
      [ "$stalled" -ge "$DM_LOCK_RECLAIM_STALL_SPINS" ] || return 1
      dm_warn "clearing abandoned reclaim marker $(basename "$reclaim") (no live owner recorded)"
      ;;
    *)
      if kill -0 "$rcpid" 2>/dev/null; then return 1; fi
      dm_warn "clearing abandoned reclaim marker $(basename "$reclaim") (pid=$rcpid not alive)"
      ;;
  esac
  rm -rf "$reclaim" 2>/dev/null || true
  return 1
}

dm_lock() {
  # dm_lock <file>  -- acquire the advisory lock guarding <file>
  local target="$1" lockdir reclaim waited=0 stalled=0 pid rpid
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
          if dm_lock_acquire_reclaim "$reclaim" "$stalled"; then
            stalled=0
            rpid="$(cat "$lockdir/pid" 2>/dev/null || true)"
            if [ -d "$lockdir" ] && [ "$rpid" = "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
              dm_warn "reclaiming stale lock on $(basename "$target") (holder pid=$pid not alive; previous holder likely crashed)"
              rm -rf "$lockdir" 2>/dev/null || true
            fi
            rm -rf "$reclaim" 2>/dev/null || true
            continue
          fi
          # Blocked by the reclaim marker, not by the lock: count it so an
          # unstamped leak eventually heals instead of wedging recovery forever.
          stalled=$((stalled + 1))
        fi
        ;;
    esac
    waited=$((waited + 1))
    if [ "$waited" -ge 300 ]; then
      dm_die "could not acquire lock on $(basename "$target") after ~30s; if no dm-* process is running, remove the stale lock AND its reclaim marker: rm -rf '$lockdir' '$reclaim'"
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
  # Absent or zero-length both mean "first run" — seed the empty registry. A
  # non-empty file is NEVER rewritten here; if it does not parse that is
  # corruption, caught by dm_registry_require_valid, not silently reset.
  [ -s "$DM_REGISTRY" ] || printf '{"repos":{}}\n' > "$DM_REGISTRY"
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

dm_valid_meta_key() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

dm_require_meta_key() {
  dm_valid_meta_key "$1" || dm_die "invalid meta key: '$1' (use [A-Za-z0-9._-], <= 64 chars)"
}

dm_valid_task_kind() { case "${1:-}" in ship|scout) return 0 ;; *) return 1 ;; esac; }
dm_valid_task_mode() { case "${1:-}" in pipeline|direct-pr|local-only) return 0 ;; *) return 1 ;; esac; }

dm_require_task_kind() {
  dm_valid_task_kind "${1:-}" || dm_die "task kind must be ship|scout"
}

dm_require_task_mode() {
  dm_valid_task_mode "${1:-}" || dm_die "task mode must be pipeline|direct-pr|local-only"
}

dm_require_single_line() {
  # dm_require_single_line <label> <value>; arity checked so a one-arg call is a
  # domain error, not an `unbound variable` abort under set -u.
  [ "$#" -eq 2 ] || dm_die "dm_require_single_line requires <label> <value>"
  case "$2" in *$'\n'*|*$'\r'*) dm_die "$1 must be single-line" ;; esac
}

dm_meta_get() {
  # dm_meta_get <id> <key>  -> prints value or empty. The key is matched as a
  # FIXED string (not a regex); value may itself contain '='; last line wins.
  dm_require_id "$1"
  dm_require_meta_key "$2"
  local f; f="$(dm_meta_path "$1")"
  [ -f "$f" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$f"
}

# Caller holds the task meta lock, so validation and the following mutation are
# one transaction with respect to creation, archival, and other writers.
dm_require_complete_task_locked() {
  local id="$1" f kind repo mode created status
  f="$(dm_meta_path "$id")"; status="$(dm_status_path "$id")"
  [ -f "$f" ] || dm_die "no such active task: $id"
  kind="$(dm_meta_get "$id" kind)"; repo="$(dm_meta_get "$id" repo)"
  mode="$(dm_meta_get "$id" mode)"; created="$(dm_meta_get "$id" created)"
  dm_valid_task_kind "$kind" || dm_die "incomplete or corrupt active task '$id': invalid kind"
  [ -n "$repo" ] || dm_die "incomplete or corrupt active task '$id': missing repo"
  dm_valid_task_mode "$mode" || dm_die "incomplete or corrupt active task '$id': invalid mode"
  [ -n "$created" ] || dm_die "incomplete or corrupt active task '$id': missing created timestamp"
  [ -f "$status" ] || dm_die "incomplete or corrupt active task '$id': missing status log"
}

# A .status with no .meta: an interrupted create (status commits first) or an
# interrupted archive (meta moves first). Never suggest deleting it — it may be
# an archived task's only history.
dm_die_orphan_status() {
  local id="$1" status="$2" arch_meta arch_status
  arch_meta="$DM_STATE/archive/$id.meta"; arch_status="$DM_STATE/archive/$id.status"
  if [ -e "$arch_meta" ] && [ ! -e "$arch_status" ]; then
    dm_die "task '$id' is archived at $arch_meta but an interrupted archive left its status log behind; finish the archive to free the id: mv '$status' '$arch_status'"
  fi
  if [ -e "$arch_meta" ]; then
    dm_die "task '$id' is already archived at $arch_meta and an unexpected status log remains active; inspect it, then move it aside to free the id: mv '$status' '$status.orphan'"
  fi
  dm_die "task '$id' has a status log with no meta, left by an interrupted create or archive; inspect it, then move it aside to free the id: mv '$status' '$status.orphan'"
}

dm_task_create() {
  # dm_task_create <id> <kind> <repo> <mode> <title>
  [ "$#" -eq 5 ] || dm_die "dm_task_create requires <id> <kind> <repo> <mode> <title>"
  local id="$1" kind="$2" repo="$3" mode="$4" title="$5"
  local meta status meta_tmp status_tmp created
  dm_require_id "$id"; dm_require_task_kind "$kind"; dm_require_task_mode "$mode"
  [ -n "$repo" ] || dm_die "task repo is required"
  dm_require_single_line "task repo" "$repo"; dm_require_single_line "task title" "$title"
  dm_ensure_dirs
  meta="$(dm_meta_path "$id")"; status="$(dm_status_path "$id")"
  dm_lock "$meta"
  if [ -e "$meta" ]; then
    dm_unlock "$meta"; dm_die "task '$id' already exists"
  fi
  if [ -e "$status" ]; then
    dm_unlock "$meta"; dm_die_orphan_status "$id" "$status"
  fi
  meta_tmp="$(mktemp "$DM_TASKS/.meta.XXXXXX")" \
    || { dm_unlock "$meta"; dm_die "mktemp failed for task '$id' meta"; }
  status_tmp="$(mktemp "$DM_TASKS/.status.XXXXXX")" \
    || { rm -f "$meta_tmp"; dm_unlock "$meta"; dm_die "mktemp failed for task '$id' status"; }
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf 'kind=%s\nrepo=%s\nmode=%s\n' "$kind" "$repo" "$mode"
    [ -z "$title" ] || printf 'title=%s\n' "$title"
    printf 'created=%s\n' "$created"
  } > "$meta_tmp" \
    || { rm -f "$meta_tmp" "$status_tmp"; dm_unlock "$meta"; dm_die "failed writing task '$id' meta"; }
  printf '%s created: %s\n' "$created" "$title" > "$status_tmp" \
    || { rm -f "$meta_tmp" "$status_tmp"; dm_unlock "$meta"; dm_die "failed writing task '$id' status"; }
  mv -f "$status_tmp" "$status" \
    || { rm -f "$meta_tmp" "$status_tmp"; dm_unlock "$meta"; dm_die "failed committing task '$id' status"; }
  mv -f "$meta_tmp" "$meta" \
    || { rm -f "$meta_tmp" "$status"; dm_unlock "$meta"; dm_die "failed committing task '$id' meta"; }
  dm_unlock "$meta"
}

dm_meta_set() {
  # dm_meta_set <id> <key> <value>  (value must be single-line). The key is
  # matched as a FIXED string (not a regex) when dropping the old line.
  dm_require_id "$1"
  dm_require_meta_key "$2"
  dm_require_single_line "meta value for '$2'" "$3"
  case "$2" in
    kind) dm_require_task_kind "$3" ;;
    mode) dm_require_task_mode "$3" ;;
  esac
  dm_ensure_dirs
  local f tmp; f="$(dm_meta_path "$1")"
  dm_lock "$f"
  dm_require_complete_task_locked "$1"
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

# --- status event log: append-only -------------------------------------------
# A status line is a WAKE EVENT, not current-state truth. Current state is
# reconciled on demand (dm-task.sh state), never stored as a mutable field.
dm_status_append() {
  # dm_status_append <id> <state> <note>
  dm_require_id "$1"
  [ -n "$2" ] || dm_die "status state is required"
  dm_require_single_line "status state" "$2"
  dm_require_single_line "status note" "${3:-}"
  dm_ensure_dirs
  local meta status; meta="$(dm_meta_path "$1")"; status="$(dm_status_path "$1")"
  dm_lock "$meta"
  dm_require_complete_task_locked "$1"
  printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "${3:-}" >> "$status" \
    || { dm_unlock "$meta"; dm_die "failed appending status for '$1'"; }
  dm_unlock "$meta"
}

# --- git cleanliness ---------------------------------------------------------
# First line only. Git's failure modes are verbose — `git diff` on a non-repo
# path exits 129 after ~130 lines of usage text — and a refusal that buries the
# one useful line under a manual page does not name the thing at risk.
dm_first_line() { printf '%s' "${1%%$'\n'*}"; }

# Uncommitted changes to TRACKED files (staged or unstaged). This is what blocks
# operations that act on the committed head (land, PR push): untracked files do
# not participate in those and must not block them.
# Prints clean|dirty (exit 0) or a single-line `error: <detail>` (exit 2) — a
# broken repo must not read as merely dirty. git diff --quiet: 1 = differences,
# >1 = real error.
dm_tracked_state() {
  local dir="$1" out rc
  rc=0; out="$(git -C "$dir" diff --quiet 2>&1)" || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'error: git diff failed (exit %s) in %s: %s\n' "$rc" "$dir" "$(dm_first_line "${out:-no detail from git}")"; return 2
  fi
  if [ "$rc" -eq 1 ]; then printf 'dirty\n'; return 0; fi
  rc=0; out="$(git -C "$dir" diff --cached --quiet 2>&1)" || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'error: git diff --cached failed (exit %s) in %s: %s\n' "$rc" "$dir" "$(dm_first_line "${out:-no detail from git}")"; return 2
  fi
  if [ "$rc" -eq 1 ]; then printf 'dirty\n'; return 0; fi
  printf 'clean\n'
}

# Fail-closed boolean: undeterminable counts as dirty, so a broken repo blocks
# the action. Callers that must report the two apart use dm_tracked_state.
dm_tracked_dirty() {
  local state
  state="$(dm_tracked_state "$1")" || return 0
  [ "$state" = dirty ]
}

# Untracked, non-ignored files, one per line. These are ambiguous (forgotten
# source vs build cruft), so operations that DISCARD a worktree (teardown) fail
# closed on them. On git failure prints a single-line `error: <detail>` and
# returns 1, so the caller's refusal can name the cause instead of guessing.
dm_untracked() {
  local out rc=0 err
  # stderr stays OFF stdout on success: a git warning with exit 0 would
  # otherwise read as an untracked filename and be cited as forgotten work.
  out="$(git -C "$1" ls-files --others --exclude-standard 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err="$(git -C "$1" ls-files --others --exclude-standard 2>&1 >/dev/null)" || true
    printf 'error: git ls-files failed (exit %s) in %s: %s\n' "$rc" "$1" "$(dm_first_line "${err:-no detail from git}")"
    return 1
  fi
  printf '%s\n' "$out"
}

# Is <relpath> provably-disposable build/tool cruft that teardown may discard
# without --force? Deliberately TIGHT: only well-known regenerable artifacts.
# Never node_modules/dist/build/.env/venv — those can hide real work. Matches
# both git's expanded-file form and its trailing-slash directory form; a
# directory-family name counts only as a real path SEGMENT (slash after it),
# never a bare file of the same name. Exit 0 = disposable, 1 = keep (fail closed).
dm_is_disposable_cruft() {
  local rel="$1" base
  [ -n "$rel" ] || return 1
  base="${rel%/}"; base="${base##*/}"
  case "$base" in
    uv.lock|.coverage|coverage.xml|*.pyc) return 0 ;;
  esac
  case "/$rel" in
    */__pycache__/*|*/.pytest_cache/*|*/.ruff_cache/*|*/.mypy_cache/*|*/htmlcov/*) return 0 ;;
  esac
  return 1
}

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

# --- registry integrity: corrupt must never read as empty --------------------
# A corrupt repos.json used to disable every registry guard at once. The guards
# were written as `jq -e ... && dm_die`; a jq parse error makes the `&&`
# short-circuit, so "cannot read the registry" silently became "nothing is
# registered" — and `add` then offered to rm -rf a live managed clone as an
# "orphan" (#112), while `dm-status` printed an empty fleet and exited 0 (#114).
# Three states, deliberately distinguished:
#   missing / zero-length -> legitimate first run; dm_ensure_dirs seeds it
#   parses, right shape   -> usable (possibly legitimately empty)
#   anything else         -> corruption; stop the operation, everywhere
# Every registry read goes through the accessors below, so no consumer can opt
# out. Validated once per process: an invocation reads this lock-protected file
# many times, and dm_json_update writes only jq's own (valid) output.
#
# Scripts whose clone path flows through dm_repo_dir must ALSO call
# dm_registry_require_valid in their MAIN shell. dm_repo_dir builds its path in
# a nested command substitution, and bash does not propagate set -e out of one:
# the refusal is printed but swallowed, and the path degrades to DM_HOME — which
# is itself a git repo, so the `.git` probe passes and the caller silently
# operates on the distro root.
DM_REGISTRY_VALID=0

dm_registry_require_valid() {
  if [ "$DM_REGISTRY_VALID" = "1" ]; then return 0; fi
  # Name a missing jq as itself; otherwise its "command not found" would be
  # captured below and reported as a parse error.
  dm_need jq
  dm_ensure_dirs
  local detail
  # Capture jq's stderr only (2>&1 before >/dev/null redirects the diagnostic
  # into the capture, then discards the boolean on stdout).
  # `-s` slurps the whole file into an array so `length == 1` rejects CONCATENATED
  # documents; without it `-e` judges only the last value in the stream, and a
  # healthy-looking tail would mask a corrupt head.
  detail="$(jq -e -s 'length == 1
      and (.[0] | type == "object" and has("repos") and (.repos | type == "object"))' \
    "$DM_REGISTRY" 2>&1 >/dev/null)" \
    || dm_die "the repo registry does not parse: $DM_REGISTRY
  ${detail:-not a single JSON object with a .repos object (expected {\"repos\":{…}})}
This is CORRUPTION, not an empty registry. Every repo you enrolled is still enrolled and every clone under repos/ is untouched; nothing has been changed. Restore the file from a backup or from your last known-good copy, or inspect it with: jq . '$DM_REGISTRY'
Do NOT delete anything under repos/ to recover from this — a clone may hold work that exists nowhere else. dm-doctor.sh check reports the same fault."
  DM_REGISTRY_VALID=1
}

# dm_registry_has <name>  -> exit 0 if registered, 1 if not. Single owner of the
# "is this repo registered?" question. Never conflates a failed READ with a
# negative ANSWER: the registry is validated first, and any jq exit above 1
# (i.e. not merely "key absent") is a hard failure rather than a silent "no".
dm_registry_has() {
  dm_registry_require_valid
  local rc=0
  jq -e --arg n "$1" '.repos | has($n)' "$DM_REGISTRY" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) dm_die "could not read repo '$1' from the registry (jq exit $rc): $DM_REGISTRY
This is a read failure, not an answer — refusing to treat it as 'not registered'. Inspect it with: jq . '$DM_REGISTRY'" ;;
  esac
}

# dm_registry_keys  -> every registered repo name, one per line (none = no
# output). Single owner of the enumeration: the `jq ... 2>/dev/null || true`
# idiom this replaces turned a corrupt registry into an empty fleet at three
# call sites. Callers that enumerate must ALSO call dm_registry_require_valid in
# their main shell — a dm_die in here exits only the process-substitution
# subshell, which would leave the caller looping over nothing.
dm_registry_keys() {
  dm_registry_require_valid
  jq -r '.repos | keys[]' "$DM_REGISTRY" \
    || dm_die "could not enumerate the registry: $DM_REGISTRY"
}

# --- registry (repos.json): single owner path via jq ------------------------
dm_registry_get() {
  # dm_registry_get <name> [<field>]  -> prints repo object or a field
  dm_registry_require_valid
  if [ -n "${2:-}" ]; then
    jq -r --arg n "$1" --arg f "$2" '.repos[$n][$f] // empty' "$DM_REGISTRY"
  else
    jq -e --arg n "$1" '.repos[$n]' "$DM_REGISTRY" 2>/dev/null
  fi
}

# dm_merge_authority <name>  -> the repo's effective merge authority, one of
# yolo|ask|never|invalid. Single owner of the value AND its legacy migration.
#   - The reserved distro name returns `never`: the dockmaster may never merge or
#     land the distro itself — its PRs are merged by the operator on GitHub.
#     Stated explicitly so the refusal names the real posture, not a lookup miss.
#   - Any OTHER unregistered repo (no registry entry, or a null one) returns
#     `invalid`, never the permissive legacy default: an unknown repo must fail
#     the merge gate closed, not inherit the most permissive posture (#119).
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
  [ "$name" != "$DM_DISTRO_REPO" ] || { printf 'never\n'; return 0; }
  # Snapshot the repo object (compact, single line) with the sole file read. An
  # absent key and a null entry both yield "null" — distinct from a registered
  # entry that merely omits the field, so an unknown repo cannot fall through to
  # the legacy `ask` default. An unreadable/corrupt registry yields "" and is
  # treated the same way: fail closed to `invalid` (#119). Every real merge path
  # validates the registry in its main shell first (dm_registry_require_valid),
  # so this is the belt-and-suspenders backstop, not the only guard.
  obj="$(jq -c --arg n "$name" 'if (.repos // {}) | has($n) then .repos[$n] else null end' "$DM_REGISTRY" 2>/dev/null)" || obj=""
  case "$obj" in
    ''|null) printf 'invalid\n'; return 0 ;;
  esac
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
  # Fail closed like dm_merge_authority: a read failure yields no bases, so the
  # never-repo merge exception grants nothing. The main shell validates the
  # registry loudly (dm_registry_require_valid) before any real merge path.
  obj="$(jq -c --arg n "$1" '.repos[$n] // {}' "$DM_REGISTRY" 2>/dev/null)" || return 0
  printf '%s' "$obj" | jq -r '.merge_allowed_bases // [] | if type == "array" then .[] else empty end | select(type == "string")' 2>/dev/null || true
}

# dm_repo_dir_or_none <name>  -> print the repo's working-tree directory, or exit
# nonzero with NO output. Single owner of the "$DM_HOME/<registry path>"
# composition AND of the reserved distro-name alias.
#
# The empty path component is the whole point (#119): `"$DM_HOME/$(...)"` with an
# unregistered name composed to $DM_HOME itself — the distro root — and the
# `.git` probe that was meant to catch it always passes there, because the distro
# IS a git repo. So a mistyped repo name resolved to the operator's control
# plane and the toolbelt happily synced/merged it. Refuse the empty path BEFORE
# building any directory; an absent path can never compose into a valid one.
#
# EXIT CODES ARE PART OF THE CONTRACT, so a caller can distinguish "no such repo"
# from "the lookup itself failed" and never swallow the latter:
#   0  resolved (path printed)
#   2  no such repo — benign; a caller MAY continue (dm-sync's SKIP line)
#   1 or other  the lookup FAILED (unreadable/corrupt registry, a dm_die raised
#      inside this call). Callers must propagate it, never report it as "unknown
#      repo": that would turn registry corruption into a benign skip.
dm_repo_dir_or_none() {
  local name="${1:-}" path
  [ -n "$name" ] || return 2
  # The distro resolves BY ITS RESERVED NAME, never by an empty path (see
  # DM_DISTRO_REPO). It has no registry entry and must never gain one.
  if [ "$name" = "$DM_DISTRO_REPO" ]; then printf '%s\n' "$DM_HOME"; return 0; fi
  path="$(dm_registry_get "$name" path)" || return 1
  [ -n "$path" ] || return 2
  printf '%s/%s\n' "$DM_HOME" "$path"
}

# dm_repo_dir <name>  -> print the repo's working-tree directory, or die. Every
# script that needs a repo's working tree goes through here so the error is
# identical — and so an unknown repo and a broken registry read differently.
dm_repo_dir() {
  local name="${1:-}" dir rc=0
  dir="$(dm_repo_dir_or_none "$name")" || rc=$?
  case "$rc" in
    0) : ;;
    2) dm_die "repo '$name' is not registered (no registry entry, or no path recorded); check the name with dm-repo.sh list, or register it with dm-repo.sh add" ;;
    *) dm_die "repo '$name': could not resolve its directory — the registry could not be read. Fix state/repos.json before retrying." ;;
  esac
  [ -d "$dir/.git" ] || dm_die "no clone for repo '$name' (expected $dir); add it with dm-repo.sh add"
  printf '%s\n' "$dir"
}

# --- the distro is never a managed repo --------------------------------------
# DM_HOME holds the operating contract, the toolbelt, the skills every crewmate
# runs from, and the live orchestration state. #119 showed sanctioned commands
# (dm-sync fast-forward, dm-merge local land) acting on it because a bad repo
# name resolved there. dm_repo_dir_or_none closes that ROUTE; this closes the
# CLASS for any other way a repo path could resolve to the DISTRO ROOT (a
# hand-edited registry path of "." or "repos/..", or a clone symlinked AT the
# distro). SCOPE, precisely: this protects $DM_HOME only. A registry path
# pointing OUTSIDE DM_HOME — e.g. repos/<name> symlinked to an unrelated git
# repo elsewhere — still resolves and is still operated on; containment of
# repos/ as a whole is a separate, unclosed gap, tracked in #141.
#
# This guards MUTATION, not resolution. The distro legitimately resolves (by its
# reserved name) so its own worktree lifecycle works; what it may never do is
# fast-forward its clone (dm-sync) or land onto its default branch (dm-merge
# local) — the tracked surface ships through this repo's own PR path.
#
# dm_is_distro_dir is the pure comparison (both sides resolved physically, so a
# symlink or a non-canonical DM_HOME cannot sneak past); dm_assert_not_distro is
# the refusing wrapper for mutating call sites. A nonexistent directory is not
# the distro (DM_HOME exists), so it is reported as "not the distro" and the
# caller's own existence checks handle it.
dm_is_distro_dir() {
  # dm_is_distro_dir <dir>  -- exit 0 if <dir> IS the distro root
  local resolved home
  resolved="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
  home="$(cd "$DM_HOME" 2>/dev/null && pwd -P)" || return 1
  [ "$resolved" = "$home" ]
}

dm_assert_not_distro() {
  # dm_assert_not_distro <dir> <action-description>
  # Empty input is a CALLER BUG, not a pass: an empty dir is exactly what a
  # swallowed resolver failure produces, and defaulting a guard to "allow" there
  # points it the wrong way. Refuse independently of what the callers happen to do.
  [ -n "${1:-}" ] || dm_die "internal: dm_assert_not_distro called with an empty directory (${2:-unknown action}); the caller's repo resolution failed silently"
  ! dm_is_distro_dir "$1" || dm_die "REFUSED: ${2:-this operation} would act on the dockmaster distro itself ($DM_HOME), not a managed repo. Check the repo name (dm-repo.sh list). The distro ships changes to itself through its own branch and PR, never through this path."
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

# --- await-checks decision: bind terminality to the PR's CURRENT head --------
# dm-pr.sh await-checks polls a PR's CI rollup and must never end the wait on a
# rollup that belongs to an OLDER head: right after a push GitHub can still
# report the previous head's finished run (a stale green/red), and a
# merge-conflicted (dirty) PR never gets workflow runs at all. Both decisions
# are pure so they are testable offline, like dm_merge_gate.
#
# dm_await_needs_head answers the brief's question "is this rollup terminal for
# THIS head SHA?" — i.e. is the current observation a candidate-terminal one
# whose trust hinges on the rolled-up head matching the PR's live head, so the
# caller must verify the head before acting. It is the single source of truth
# for that relevance (the caller's I/O guard and the terminal mapping both read
# it), so they cannot drift. Exit 0 = must verify the head; 1 = keep polling.
dm_await_needs_head() {
  # dm_await_needs_head <rollup> <merge_state> <has_ci:0|1>
  local rollup="$1" merge_state="$2" has_ci="$3"
  if [ "$merge_state" = "dirty" ]; then return 0; fi
  case "$rollup" in
    passing|failing) return 0 ;;
    none) if [ "$has_ci" = "0" ]; then return 0; fi ;;
  esac
  return 1
}

# dm_await_gate maps a head-RECONCILED observation to a poll action. The caller
# resolves the head first and, on a stale/unverifiable head, downgrades the
# rollup/merge_state to a non-terminal value (pending/unknown) BEFORE calling
# this — so a mismatched head can never reach a terminal verdict here. `dirty`
# outranks the rollup (a conflict cannot produce merge checks); `none` is
# terminal only on a confirmed CI-less repo (has_ci=0), matching dm_merge_gate.
# Prints: pass | fail | dirty | wait.
dm_await_gate() {
  # dm_await_gate <rollup> <merge_state> <has_ci:0|1>
  local rollup="$1" merge_state="$2" has_ci="$3"
  if [ "$merge_state" = "dirty" ]; then printf 'dirty\n'; return 0; fi
  case "$rollup" in
    passing) printf 'pass\n' ;;
    failing) printf 'fail\n' ;;
    none)    if [ "$has_ci" = "0" ]; then printf 'pass\n'; else printf 'wait\n'; fi ;;
    *)       printf 'wait\n' ;;
  esac
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

# --- dispatch right-sizing: advisory model-tier recommendation ----------------
# Recommend the least model tier that still fits the work, as a pure function
# (offline, no side effects) so dm-brief can surface it and smoke can test it.
# ADVISORY, not a gate: the Codex adapter exposes no per-spawn model field, so
# this can only be surfaced, never enforced. Risk signals dominate (size UP when
# unsure); a scout or mechanical change sizes down. Matching is case-insensitive
# and substring, so `auth` also fires on author/authority — a deliberate
# over-size bias, the safe direction for an advisory hint. Prints: haiku|sonnet|opus.
dm_recommended_model() {
  # dm_recommended_model <kind> <title-plus-brief-text>
  local kind="$1" text="$2"
  if grep -qiE 'authz|permission|auth|migration|alembic|concurren|lock|mutex|security|secret|crypto|merge.gate|memory governance' <<<"$text"; then
    printf 'opus\n'; return 0
  fi
  if [ "$kind" = "scout" ] || grep -qiE 'test|docs?|chore|nit|typo|format|comment|rename' <<<"$text"; then
    printf 'haiku\n'; return 0
  fi
  printf 'sonnet\n'
}

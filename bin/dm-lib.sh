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
# The managed worktree root. Here rather than in dm-worktree.sh because a task's
# managed path is the FIRST key git's admin record is looked up by (see
# dm_admin_worktree_head), and two scripts now need that lookup.
DM_WT="$DM_STATE/worktrees"

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
  local out rc=0 errf err
  # The temp lives OUTSIDE the inspected directory: a scratch file written into
  # the worktree would itself show up as untracked work.
  errf="$(mktemp "${TMPDIR:-/tmp}/dm-untracked.XXXXXX")" \
    || { printf 'error: mktemp failed while inspecting untracked files in %s\n' "$1"; return 1; }
  # stderr stays OFF stdout on success: a git warning with exit 0 would
  # otherwise read as an untracked filename and be cited as forgotten work. It
  # is captured from THIS run, never re-read by a second one (#146): the tree
  # can change between the two, and a second run that succeeds loses the cause.
  out="$(git -C "$1" ls-files --others --exclude-standard 2>"$errf")" || rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  if [ "$rc" -ne 0 ]; then
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

# --- code-state fingerprint: binds a verdict to code content, not just HEAD --
# A verdict recorded against a commit is not a verdict: a green run can be
# carried across the very edit that breaks it. HEAD alone is not enough either
# — crew work is uncommitted for most of its life — so the fingerprint also
# covers the dirty state. Single owner: dm-verify.sh's `up`/`flow`/`report` pin
# an app boot to it, and dm-test.sh (#185) binds a recorded test pass to it too,
# so a verdict cannot outlive the code it was produced against on either gate.

# One content-digest tool, resolved once: sha256sum (Linux), shasum (macOS), and
# cksum as the last resort. All three print "<digest...> <path>" for file
# arguments, which is what binds a path to its own bytes.
if command -v sha256sum >/dev/null 2>&1; then DM_DIGEST_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then DM_DIGEST_CMD=(shasum -a 256)
else DM_DIGEST_CMD=(cksum); fi

# dm_untracked_digests <worktree> -- "<digest>  <path>" per untracked file,
# sorted. Each path is bound to ITS OWN content. Concatenating all the bytes
# into one stream did not: moving a line from one untracked file to another
# left the path list and the byte total identical, so the pin sat still while
# the routes moved. Same root as `aa.js` containing the text `zz.js` hashing
# like an empty pair.
dm_untracked_digests() {
  local wt="$1" paths
  # Emptiness is checked FIRST: GNU xargs runs its command once on empty input,
  # and a digest tool with no arguments reads stdin and hangs.
  paths="$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)" || return 1
  [ -n "$paths" ] || return 0
  # `--` is load-bearing: paths arrive as bare arguments, so an untracked file
  # named `--help` or `-c` is read as an OPTION. sha256sum then prints usage,
  # hashes NOTHING and exits 0 — the untracked digest set collapses to a
  # constant and the pin stops moving on new uncommitted source entirely.
  # No `|| true` either: a digest tool that fails must fail the pin, not empty it.
  git -C "$wt" ls-files --others --exclude-standard -z 2>/dev/null \
    | ( cd "$wt" && xargs -0 -n 50 "${DM_DIGEST_CMD[@]}" -- ) \
    | LC_ALL=C sort
}

# dm_code_state <worktree> -- "<head>/<content-checksum>", or empty when the
# worktree cannot be read.
#
# The checksum must cover file CONTENT, not the porcelain listing. `git status
# --porcelain` emits status letters and paths and never CONTENT, so once a file
# was dirty every further edit produced the identical line and checksum — and
# crew work is dirty for most of its life, the exact case this pin exists for.
#
# Hash BOTH derivatives, never one instead of the other. Hashing content alone
# was blind in the mirror direction: an untracked file RENAMED, or two untracked
# files merged into one with the same bytes, left the checksum identical while
# the app's routes moved. So the material is:
#   - `git diff HEAD`  — tracked content AND tracked paths (renames included)
#   - the untracked PATH list — structure
#   - the untracked file CONTENTS — bytes
# `git diff HEAD` also carries binary changes, via its `index <blob>..<blob>` line.
dm_code_state() {
  local wt="$1" head content udigests
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  # Prove both reads work BEFORE hashing: a `return` inside the group below runs
  # in a subshell, so a failed git would otherwise hash to a stable checksum of
  # nothing — a pin that never moves, which is the failure this guards.
  git -C "$wt" diff HEAD >/dev/null 2>&1 || return 1
  git -C "$wt" ls-files --others --exclude-standard >/dev/null 2>&1 || return 1
  udigests="$(dm_untracked_digests "$wt")" || return 1
  # cksum's byte count is kept, not discarded: this is the security-critical pin
  # and CRC-32 is linear, so length is a cheap independent term.
  content="$( { git -C "$wt" diff HEAD 2>/dev/null
                printf '%s\n' "$udigests"
              } | cksum | awk '{print $1"-"$2}' )"
  [ -n "$content" ] || return 1
  printf '%s/%s\n' "$head" "$content"
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
  dm_registry_require_unique_keys
  DM_REGISTRY_VALID=1
}

# JSON permits an object to repeat a key and every parser keeps just one of them
# (jq: the last). So `{"repos":{…},"repos":{}}` PARSES, passes the shape check
# above, and reads as an EMPTY fleet while the real entries sit in the same file
# (#151) — the same "corruption must never read as empty" class as #112/#114.
#
# Detection counts leaves twice. `--stream` reports every leaf the FILE holds,
# duplicates included; the parsed document holds only the survivors. Every JSON
# value contributes at least one leaf event (an empty object/array is itself a
# leaf event), so a repeated key ALWAYS costs at least one leaf and the two
# counts differ IFF some key is repeated somewhere in the file — at any depth,
# whether the duplicate is `repos` itself or a repo name inside it.
#
# Both counts come from ONE read of the bytes. Re-reading the file for the second
# count could straddle a concurrent atomic registry write and report a perfectly
# healthy registry as corrupt, which is the same lie in the other direction.
dm_registry_require_unique_keys() {
  local bytes raw_leaves kept_leaves
  bytes="$(cat "$DM_REGISTRY")" || dm_die "could not read the repo registry: $DM_REGISTRY"
  raw_leaves="$(printf '%s' "$bytes" | jq -n --stream '[inputs | select(length == 2)] | length')" \
    || dm_die "could not scan the repo registry for duplicate keys: $DM_REGISTRY"
  kept_leaves="$(printf '%s' "$bytes" | jq '[paths((type != "object" and type != "array") or length == 0)] | length')" \
    || dm_die "could not count the repo registry's entries: $DM_REGISTRY"
  [ "$raw_leaves" = "$kept_leaves" ] || dm_die "the repo registry has DUPLICATE KEYS: $DM_REGISTRY
  it holds $raw_leaves values but a parser keeps only $kept_leaves — a repeated key (\"repos\" itself, or a repo name inside it) silently discards everything the earlier copy held.
This is CORRUPTION, not an empty registry. Every repo you enrolled is still enrolled and every clone under repos/ is untouched; nothing has been changed. Find the repeated key and keep one copy of it — inspect the file with: jq . '$DM_REGISTRY' (jq prints only the surviving copy, so compare against the raw text).
Do NOT delete anything under repos/ to recover from this — a clone may hold work that exists nowhere else."
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

# --- containment: a managed clone lives under repos/ -------------------------
# dm_repo_dir_or_none COMPOSES "$DM_HOME/<registry path>" but never RESOLVED it,
# so `repos/<name>` symlinked at a git repo anywhere else on disk resolved fine:
# the toolbelt cut a worktree in that foreign repo and a crewmate committed to
# its default branch (#141). Containment is checked PHYSICALLY (cd/pwd -P;
# `realpath` is not on a stock macOS), and $DM_REPOS is resolved the same way —
# so an operator who symlinks the WHOLE repos/ tree onto another volume stays
# supported, and only a per-repo escape is refused.
#
# Two narrow exemptions, both deliberate:
#   - the distro root: it lives AT $DM_HOME, not under repos/, and resolves by
#     its reserved name so its own PR path works. A hand-edited registry path
#     that resolves there stays the DISTRO guards' business (dm_assert_not_distro,
#     dm-sync's control-plane SKIP), which state the real posture; this guard
#     would only mislabel it.
#   - a path that does not resolve: there is nothing to escape INTO, and every
#     caller already refuses a directory with no clone in it.
dm_within_repos() {
  # dm_within_repos <dir>  -- exit 0 if <dir> is contained, 1 if it escapes. Pure.
  local dir="${1:-}" real root
  [ -n "$dir" ] || return 1
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 0
  if dm_is_distro_dir "$real"; then return 0; fi
  root="$(cd "$DM_REPOS" 2>/dev/null && pwd -P)" || return 1
  case "$real" in
    "$root"|"$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

dm_assert_within_repos() {
  # dm_assert_within_repos <dir> <subject-description>
  # Empty input is a CALLER BUG, not a pass — same reasoning as
  # dm_assert_not_distro: empty is what a swallowed resolver failure produces.
  local real
  [ -n "${1:-}" ] || dm_die "internal: dm_assert_within_repos called with an empty directory (${2:-unknown subject}); the caller's repo resolution failed silently"
  if dm_within_repos "$1"; then return 0; fi
  # Name where it actually LANDS, not just the path that was composed: with a
  # symlinked repos/<name> the two differ, and the target is the thing at risk.
  real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
  # First line is the whole refusal, standalone: a caller on a tolerant path
  # (dm-worktree teardown) quotes only that line into its own message.
  dm_die "REFUSED: ${2:-this directory} lands on $real, OUTSIDE the managed clone root $DM_REPOS
A managed clone must live under repos/; a symlink or hand-edited registry path pointing at a repository elsewhere is never operated on (composed path: $1).
Check the entry with dm-repo.sh list, then replace the symlink with a real clone: dm-repo.sh add <name> <remote>."
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
#   1 or other  the lookup FAILED (unreadable/corrupt registry, a clone that
#      escapes repos/, any other dm_die raised inside this call). Callers must
#      propagate it, never report it as "unknown repo": that would turn registry
#      corruption — or a containment breach — into a benign skip.
dm_repo_dir_or_none() {
  local name="${1:-}" path dir
  [ -n "$name" ] || return 2
  # The distro resolves BY ITS RESERVED NAME, never by an empty path (see
  # DM_DISTRO_REPO). It has no registry entry and must never gain one.
  if [ "$name" = "$DM_DISTRO_REPO" ]; then printf '%s\n' "$DM_HOME"; return 0; fi
  path="$(dm_registry_get "$name" path)" || return 1
  [ -n "$path" ] || return 2
  dir="$DM_HOME/$path"
  # Containment is asserted at the single composition owner, so NO consumer can
  # obtain an escaped path — including the ones that tolerate a failed lookup
  # (dm-sync's SKIP line, dm-worktree's teardown). Like the corrupt-registry
  # death raised inside dm_registry_get, this dm_die exits the caller's command
  # substitution: the caller sees a FAILED lookup (never exit 2, "no such repo")
  # and the real reason is already on stderr.
  dm_assert_within_repos "$dir" "the clone registered for repo '$name'"
  printf '%s\n' "$dir"
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
    *) dm_die "repo '$name': could not resolve its directory — see the refusal above (the registry could not be read, or its clone is not contained under repos/). Fix state/repos.json or the clone before retrying." ;;
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
# repo elsewhere — is the neighbouring question, and it is answered by
# dm_within_repos / dm_assert_within_repos below (#141).
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

# --- worktree containment: never answer from the enclosing repo -------------
# `git -C <path>` WALKS UP the filesystem when <path> has no working `.git`
# (removed, or the directory survives but the link inside it is gone) and
# silently answers from whatever repository it finds instead — and every
# managed worktree lives under DM_WT, itself inside DM_HOME's own working
# tree, so that walk lands on a REAL repo (the distro, or a sibling clone) and
# never errors. #210/#181/#209 are one bug: a cleanup path trusted `git -C
# "$wt"` on a broken worktree and recorded the wrong repo's answer as this
# task's own. dm_worktree_contained is the single check every such call site
# must pass first.
#
# Prints the physical toplevel of <path> and exits 0 ONLY when git resolves it
# to <path> itself. Exits 1, printing nothing, when <path> does not exist, is
# not inside a git worktree at all, or git walked up past it. Never dies: a
# caller mid-diagnosis (dm-worktree.sh's `landed`, dm-trash.sh's snapshot)
# needs to turn a failure into its OWN undetermined/refused answer, not have
# the whole command die out from under it.
dm_worktree_contained() {
  local path="${1:-}" real top
  [ -n "$path" ] || return 1
  real="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  top="$(git -C "$real" rev-parse --show-toplevel 2>/dev/null || true)"
  top="$(cd "$top" 2>/dev/null && pwd -P || true)"
  [ -n "$top" ] || return 1
  [ "$top" = "$real" ] || return 1
  printf '%s\n' "$real"
}

# dm_assert_worktree_contained <path> -> the same check, for a call site where
# "not contained" is always a hard refusal rather than a soft undetermined
# branch: dies with a reason instead of returning quietly.
dm_assert_worktree_contained() {
  local out
  out="$(dm_worktree_contained "${1:-}")" \
    || dm_die "REFUSED: '${1:-}' is not a real worktree root — it is missing, or git walked UP past it into an enclosing repository (a missing or broken .git record). Refusing rather than answering from the wrong repo."
  printf '%s\n' "$out"
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

# --- where a discarded head is parked ----------------------------------------
# Single owner of the recovery-ref LAYOUT, because two scripts depend on it:
# dm-worktree.sh remove --force creates the ref, and dm-trash.sh verifies it
# resolves before telling the operator the work is recoverable. A second,
# hand-composed copy of this path is how a recovery claim drifts from the ref
# that actually exists.

# Task ids allow `.`, so a legal id can still be an illegal ref component
# (`a..b`, `x.lock`, `trail.`). Map everything outside [A-Za-z0-9_-] to `_` so
# the work is preserved anyway; the sha keeps distinct ids from colliding.
dm_ref_component() { printf '%s' "${1//[!A-Za-z0-9_-]/_}"; }

# dm_admin_worktree_head <clone-dir> <worktree-path> -> the HEAD git's admin
# record still holds for a worktree at that path, or empty. A vanished DIRECTORY
# does not take the commit with it — the object lives in the clone and the admin
# record is its last reference, so this is the only way to name the head of a
# worktree whose directory is already gone (and it must be read before a prune).
#
# awk reads to EOF and keeps only the FIRST match instead of `exit`-ing on it:
# exiting early closes the pipe, git dies of SIGPIPE, and `pipefail` turns the
# whole function into exit 141 — which, in a plain `head="$(...)"` assignment
# under `set -e`, kills the caller. It only surfaces once git's output exceeds
# the pipe buffer (many worktrees), so it is invisible in small fixtures.
dm_admin_worktree_head() {
  local dir="$1" path="$2"
  git -C "$dir" worktree list --porcelain 2>/dev/null | awk -v p="$path" '
    $1 == "worktree" { in_entry = (substr($0, 10) == p) }
    in_entry && $1 == "HEAD" && !found { print $2; found = 1 }
  '
}

# dm_squote <string> -> the string as a single-quoted shell word, safe to paste
# into a command line. Used for paths in the recovery instructions this toolbelt
# PRINTS for an operator to run: an unquoted path breaks on the first space, and
# that instruction is sometimes the only route back to a discarded commit.
dm_squote() {
  local s="$1"
  # Close the quote, emit an escaped quote, reopen — the only way to carry a
  # single quote inside single quotes.
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

# dm_discard_ref <id> [<sha>] -> the ref a discarded head is parked on. With no
# sha, the PARENT path (the legacy flat layout's own ref; nothing can be created
# beneath it while a ref lives there — see migrate_flat_discard_ref).
dm_discard_ref() {
  local base
  base="refs/dm-discarded/$(dm_ref_component "$1")"
  if [ -n "${2:-}" ]; then printf '%s/%s\n' "$base" "$2"; else printf '%s\n' "$base"; fi
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

# --- PR body: the appended gate-evidence section (#175) ----------------------
# Single owner of the section's SHAPE, because two scripts depend on it:
# dm-evidence.sh renders one, and dm-pr.sh both renders the "collector could not
# be run" variant and strips a previous section before appending. Keeping the
# markers here also means stripping never depends on dm-evidence.sh existing —
# the very failure the fallback exists for.
#
# The region is delimited at BOTH ends. A single opening marker was ambiguous:
# any body that merely QUOTED it (a PR description about this machinery is the
# obvious case) got truncated from that line to the end, silently discarding the
# operator's own text.
DM_EVIDENCE_BEGIN='<!-- dm:gate-evidence -->'
DM_EVIDENCE_END='<!-- /dm:gate-evidence -->'

dm_evidence_wrap() {
  # dm_evidence_wrap <content> -- the whole appended section, separator and
  # markers included. Content is markdown already rendered by its producer.
  [ "$#" -eq 1 ] || dm_die "dm_evidence_wrap requires <content>"
  [ -n "$1" ] || dm_die "dm_evidence_wrap refuses an empty section: an evidence block with nothing in it is indistinguishable from no gate at all"
  printf -- '---\n%s\n\n### Gate evidence\n\n%s\n\n%s\n' \
    "$DM_EVIDENCE_BEGIN" "$1" "$DM_EVIDENCE_END"
}

dm_evidence_strip() {
  # dm_evidence_strip -- body on stdin, body without a previously appended
  # section on stdout. Removes ONLY a complete begin..end region that ends the
  # body, plus the blank lines and `---` separator introducing it. Anything else
  # — a quoted marker, an unterminated one, one inside a fenced block — is
  # passed through byte for byte: appending a duplicate section is a visible
  # annoyance, whereas eating the description is silent data loss.
  # \r is ignored when matching so a body round-tripped through GitHub (which
  # serves CRLF) still strips instead of stacking a second section.
  awk -v b="$DM_EVIDENCE_BEGIN" -v e="$DM_EVIDENCE_END" '
    function bare(s) { sub(/\r$/, "", s); return s }
    { raw[++n] = $0; flat[n] = bare($0) }
    END {
      last = n
      while (last > 0 && flat[last] == "") last--
      start = 0
      if (last > 0 && flat[last] == e)
        for (i = last - 1; i >= 1; i--) if (flat[i] == b) { start = i; break }
      if (start > 0) {
        n = start - 1
        while (n > 0 && (flat[n] == "" || flat[n] == "---")) n--
      }
      for (i = 1; i <= n; i++) print raw[i]
    }'
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

# --- brief readiness: one owner for "can this brief be dispatched?" -----------
# Prints WHY a brief must not be dispatched and returns 0; prints nothing and
# returns 1 when it is ready. Three reasons, because they need three different
# recoveries and a single boolean made every caller give the wrong advice:
#   missing     -> generate it (dm-brief.sh <id>), then fill it
#   empty       -> regenerate; there is nothing to preserve
#   placeholder -> EDIT IN PLACE; regenerating would destroy a partial fill
# All three end the same way — a crewmate with no task — so all three callers
# refuse on all three. Single owner: three sites drifting on this predicate is
# what produced the false refusal this replaced.
#
# `placeholder` is LINE-anchored, never a whole-file match: a correctly filled
# brief whose task text merely MENTIONS {TASK} is filled — issue #115's own text
# does — and refusing it would strand an already-spawned crewmate. \r is in
# [[:space:]], so a CRLF scaffold still matches.
# `empty` catches an EXACTLY zero-byte file, which is what a death during the
# truncate-then-write leaves. A partial write that got as far as one byte is not
# caught here; it is caught by the placeholder arm whenever the bare {TASK} line
# survived, and not at all when it did not.
dm_brief_unready_reason() {
  local brief="$1"
  [ -f "$brief" ] || { printf 'missing\n'; return 0; }
  [ -s "$brief" ] || { printf 'empty\n'; return 0; }
  grep -qx '[[:space:]]*{TASK}[[:space:]]*' "$brief" || return 1
  printf 'placeholder\n'
}

# --- dispatch right-sizing: two independent dials, chosen by judgment --------
# Model tier and reasoning effort are SEPARATE axes and both bind at spawn:
# `model` is an Agent-tool parameter, and effort comes from the `crew-<level>`
# subagent definitions under `.claude/agents/`, selected with `subagent_type`.
# Each crew-*.md PINS a default model (#177), so an OMITTED `model` parameter
# lands on a considered tier instead of inheriting the session's — the parameter
# still wins, so every model x effort pair stays a one-liner.
#
# There is deliberately no computed recommendation here: the dockmaster reads
# the brief and the diff and picks a rung on the model x effort ladder itself
# (task-lifecycle has the ladder). A table trying to do that from a role/kind/
# diff-size signal (#166-#187) under- and over-fired in practice and was
# removed rather than recalibrated again.
#
# The levels a dispatch may record. `max` exists in the runtime but is
# deliberately excluded: a cost ceiling, not a missing case. Do not add it back.
DM_EFFORT_LEVELS='low medium high xhigh'

# dm_transcript_model <file>  -> the model id a subagent ACTUALLY ran as, read
# from the first `"model":"..."` in its transcript; non-zero when the file is
# absent or carries none. Task meta and the transcript are independent sources,
# and only the transcript proves what ran — the dispatch gate records a CHOICE,
# it cannot verify the spawn. Unreadable must stay unproven, never a pass.
dm_transcript_model() {
  local file="${1:-}" value
  [ -n "$file" ] && [ -f "$file" ] || return 2
  # `"model":"` is 9 chars, plus the closing quote: awk exits at the first hit,
  # so a large transcript is not fully scanned.
  value="$(awk 'match($0, /"model":"[a-zA-Z0-9._-]+"/) {
    print substr($0, RSTART + 9, RLENGTH - 10); exit }' "$file")" || return 2
  [ -n "$value" ] || return 2
  printf '%s\n' "$value"
}

# True when the transcript's model id is the tier the dispatch recorded. The
# record holds a tier alias (`opus`) and the runtime reports a full id
# (`claude-opus-5`), so containment — not equality — is the test. No alias is a
# substring of another, so this cannot cross-match two tiers.
dm_dispatch_model_matches() {
  local recorded="${1:-}" actual="${2:-}"
  [ -n "$recorded" ] && [ -n "$actual" ] || return 1
  case "$actual" in *"$recorded"*) return 0 ;; esac
  return 1
}

# True when <value> is EXACTLY one effort level. Whole-word equality, never a
# substring test against the joined list: `case " $LEVELS " in *" $v "*)` also
# accepted any adjacent run ("low medium", "high xhigh"), storing a level with no
# crew-*.md behind it. Equality makes empty and multi-word refusals structural.
dm_effort_is_valid() {
  local value="${1:-}" level
  for level in $DM_EFFORT_LEVELS; do
    [ "$value" = "$level" ] && return 0
  done
  return 1
}

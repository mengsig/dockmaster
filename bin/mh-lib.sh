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
  # mh_meta_get <id> <key>  -> prints value or empty
  local f; f="$(mh_meta_path "$1")"
  [ -f "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | tail -n1
}

mh_meta_set() {
  # mh_meta_set <id> <key> <value>  (value must be single-line)
  mh_require_id "$1"
  mh_ensure_dirs
  local f tmp; f="$(mh_meta_path "$1")"
  case "$3" in *$'\n'*) mh_die "meta value for '$2' must be single-line" ;; esac
  tmp="$(mktemp "$MH_TASKS/.meta.XXXXXX")"
  { [ -f "$f" ] && grep -v "^$2=" "$f" || true; printf '%s=%s\n' "$2" "$3"; } > "$tmp"
  mv -f "$tmp" "$f"
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

# --- contextgraph: memory is TRACKED in each managed repo -------------------
# Per-repo memory lives in the repo's own committed .contextgraph/ (plus file
# sidecars), so git materializes it in every worktree and clone and recall works
# for crewmates. It is delivered through the normal PR/land flow (mh-repo.sh
# init-memory for onboarding; crewmates commit memory changes with their work).
# The manhandler never force-commits it onto a clone's default branch, which
# would diverge from origin and break fast-forward sync.

# Stage whatever contextgraph init created/modified in a worktree, ready to
# commit: the .contextgraph/ store and, when init created them, AGENTS.md /
# CLAUDE.md. Only stages paths that exist.
mh_cg_stage() {
  local dir="$1" p
  for p in .contextgraph AGENTS.md CLAUDE.md; do
    [ -e "$dir/$p" ] && git -C "$dir" add "$p" 2>/dev/null || true
  done
  # also stage any file-level sidecars contextgraph wrote next to source files
  git -C "$dir" add -A ':(glob)**/.*.md' 2>/dev/null || true
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

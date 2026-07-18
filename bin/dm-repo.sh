#!/usr/bin/env bash
# dm-repo.sh - manage the registry of repositories the dockmaster operates on.
#
# The registry (state/repos.json) is the single source of truth for what is
# managed. Each repo is cloned once under repos/<name> (read-only to the
# dockmaster; crewmates work in worktrees off that clone) and gets its per-repo
# memory scaffolded via dm-memory.sh seed (see that script for the model).
#
# Commands:
#   add <name> <remote> [--mode M] [--test-cmd C] [--branch B] [--no-memory]
#   create <name> [<remote>] [--mode M] [--test-cmd C] [--branch B]
#          [--public|--private] [--https] [--description D] [--no-memory]
#                            stand up a BRAND-NEW repo: create the GitHub repo
#                            (when no remote is given) or use an empty remote you
#                            supply, initialize repos/<name> with a first commit,
#                            set upstream, publish, and register it. (add clones
#                            an EXISTING populated remote; create makes a new one.)
#   list
#   get <name> [<field>]
#   set <name> <field> <value>
#   remove <name>            (registry entry only; never deletes a clone with
#                             uncommitted or unpushed work)
#   seed <name>              (idempotent private memory store in the clone)
#
# Modes: pipeline (default, full PR gate pipeline) | direct-pr | local-only.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git; dm_need jq
dm_ensure_dirs

cmd="${1:-}"; shift || true

# registry_write <jq-filter> [args...] - locked, atomic update of repos.json.
# Thin wrapper over the shared dm_json_update so the registry and any other JSON
# state use one audited read-modify-write path (lock, atomic temp->mv, cleanup).
registry_write() { dm_json_update "$DM_REGISTRY" "$@"; }

# require_valid_mode <mode> - single owner of the mode enum, checked by add,
# create, and set so the three cannot drift on what a valid mode is.
require_valid_mode() {
  case "$1" in
    pipeline|direct-pr|local-only) ;;
    *) dm_die "mode must be pipeline|direct-pr|local-only" ;;
  esac
}

# guard_new_repo_slot <name> <orphan-hint> -> print the clone directory this
# name would use, or die if <name> is already registered or its clone
# directory exists unregistered (an orphan left by a partial add/create).
# <orphan-hint> names what the caller does before registering (clone vs.
# local init) so the recovery message matches what actually happened.
guard_new_repo_slot() {
  local name="$1" hint="$2" dir
  jq -e --arg n "$name" '.repos[$n]' "$DM_REGISTRY" >/dev/null 2>&1 && dm_die "repo '$name' already registered"
  dir="$DM_REPOS/$name"
  [ -e "$dir" ] && dm_die "path already exists but '$name' is not registered: $dir
This is an orphaned clone from a partial add/create ($hint). Recover, then re-run: remove it (rm -rf '$dir') or move it aside."
  printf '%s\n' "$dir"
}

# register_repo <name> <remote> <branch> <mode> <test_cmd> - write the canonical
# registry entry for a managed repo. Single owner of the entry shape, shared by
# `add` (clone existing) and `create` (make new) so the two cannot drift.
register_repo() {
  registry_write \
    --arg n "$1" --arg r "$2" --arg p "repos/$1" \
    --arg b "$3" --arg m "$4" --arg t "$5" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.repos[$n] = {remote:$r, path:$p, default_branch:$b, mode:$m, yolo:false, test_cmd:$t, pipeline:"default", memory:false, added:$ts}'
}

# Scaffold the repo's private memory store in the clone: git-excluded
# repos/<name>/.dm/ (see dm-memory.sh for the model). SHARED knowledge is authored
# later by a crewmate in a worktree (the repo's AGENTS.md dm:knowledge section),
# never seeded into the clone — so the clone stays pristine and landable. Fail
# OPEN: memory is optional, so a scaffold failure warns and leaves the repo
# registered without it (retry with `dm-repo.sh seed <name>`), never blocking
# onboarding.
seed_memory() {
  local name="$1" dir="$DM_REPOS/$1" out
  [ -d "$dir/.git" ] || dm_die "no clone at $dir"
  if out="$("$(dirname "$0")/dm-memory.sh" seed "$name" 2>&1)"; then
    registry_write --arg n "$name" '.repos[$n].memory = true'
    dm_info "$out"
  else
    dm_warn "memory scaffold failed for $name; repo registered without it. Retry: dm-repo.sh seed $name
$out"
    registry_write --arg n "$name" '.repos[$n].memory = false'
  fi
}

case "$cmd" in
  add)
    name="${1:-}"; remote="${2:-}"; shift 2 || true
    [ -n "$name" ] && [ -n "$remote" ] || dm_die "usage: dm-repo.sh add <name> <remote> [--mode M] [--test-cmd C] [--branch B] [--no-memory]"
    dm_require_id "$name"
    mode="pipeline"; test_cmd=""; branch=""; want_memory=1
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --test-cmd) test_cmd="${2:-}"; shift 2 ;;
        --branch) branch="${2:-}"; shift 2 ;;
        --no-memory) want_memory=0; shift ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    require_valid_mode "$mode"
    dir="$(guard_new_repo_slot "$name" "the clone succeeded but registration did not")"
    dm_info "cloning $remote -> $dir"
    git clone "$remote" "$dir" || dm_die "clone failed"
    [ -n "$branch" ] || branch="$(dm_default_branch "$dir")"
    register_repo "$name" "$remote" "$branch" "$mode" "$test_cmd"
    [ "$want_memory" -eq 1 ] && seed_memory "$name" || true
    dm_info "registered '$name' (mode=$mode, default_branch=$branch)"
    # A fresh clone with no test_cmd leaves the tests gate a permanent soft-skip
    # and an empty dm:knowledge section. Point at the onboarding scout that seeds
    # both (project-management skill); a scout would find nothing in a repo the
    # operator supplied a command for, so only hint when one is missing.
    [ -n "$test_cmd" ] || dm_info "hint: no test command set, so the tests gate will soft-skip and repository knowledge starts empty. Dispatch an onboarding scout to propose a test_cmd and initial knowledge (see the project-management skill), or set one now: dm-repo.sh set $name test_cmd '<cmd>'"
    ;;

  create)
    name="${1:-}"; shift || true
    [ -n "$name" ] || dm_die "usage: dm-repo.sh create <name> [<remote>] [--mode M] [--test-cmd C] [--branch B] [--public|--private] [--https] [--description D] [--no-memory]"
    dm_require_id "$name"
    # optional positional remote: the first arg that is not a flag
    remote=""
    case "${1:-}" in ""|-*) ;; *) remote="$1"; shift ;; esac
    mode="pipeline"; test_cmd=""; branch="main"; visibility="private"; scheme="ssh"; description=""; want_memory=1
    created_remote=0   # set when WE create the GitHub repo, so a later failure can warn it now exists empty
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --test-cmd) test_cmd="${2:-}"; shift 2 ;;
        --branch) branch="${2:-}"; shift 2 ;;
        --public) visibility="public"; shift ;;
        --private) visibility="private"; shift ;;
        --https) scheme="https"; shift ;;
        --description) description="${2:-}"; shift 2 ;;
        --no-memory) want_memory=0; shift ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    require_valid_mode "$mode"
    dir="$(guard_new_repo_slot "$name" "the local repo was initialized but registration did not complete")"

    # Resolve the remote. Either the operator supplies an EMPTY remote they made,
    # or (no remote given) we create the GitHub repo ourselves.
    if [ -n "$remote" ]; then
      refs="$(git ls-remote --heads "$remote" 2>/dev/null)" || dm_die "cannot reach remote '$remote' (bad url or auth?)"
      [ -z "$refs" ] || dm_die "remote '$remote' already has branches; use 'dm-repo.sh add' to clone an existing repo"
    else
      dm_need gh-axi
      dm_info "creating GitHub repository '$name' ($visibility)"
      create_args=(repo create "$name" "--$visibility")
      [ -n "$description" ] && create_args+=(--description "$description")
      out="$(gh-axi "${create_args[@]}" 2>&1)" || dm_die "gh repo create failed:
$out"
      html="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[A-Za-z0-9._/-]+' | head -n1)"
      [ -n "$html" ] || dm_die "could not parse the new repo url from gh output:
$out"
      slug="$(printf '%s' "$html" | sed -E 's#^https://github\.com/##; s#\.git$##')"
      case "$scheme" in
        https) remote="https://github.com/$slug.git" ;;
        *)     remote="git@github.com:$slug.git" ;;
      esac
      created_remote=1
    fi

    # If WE just created the GitHub repo, every step below can fail with a real
    # (but empty) remote already live. Surface that in each failure so the
    # operator knows to clean it up manually — this tool never auto-deletes it.
    remote_note=""
    [ "$created_remote" -eq 1 ] && remote_note="
NOTE: the GitHub repository '$html' was just created and now exists (empty) on GitHub. If you do not re-run a successful create, delete it manually (e.g. gh repo delete). This tool never auto-deletes it."

    # Initialize a local repo with ONE commit so it has a default branch and a
    # base for worktrees, then publish and set upstream. This is the repo-init
    # write sanctioned for dm-repo.sh; it never forces and never touches an
    # existing clone (the path is guaranteed absent above).
    # Portable initial-branch selection: `git init -b` needs git >= 2.28. Init,
    # then point HEAD at the desired branch ref (materialized by the first commit
    # below) — works on all supported git versions.
    git init -q "$dir" || dm_die "git init failed$remote_note"
    git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || dm_die "failed to set initial branch to '$branch'$remote_note"
    git -C "$dir" remote add origin "$remote" || dm_die "failed to set origin remote. Local repo left at $dir$remote_note"
    printf '# %s\n' "$name" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" -c commit.gpgsign=false commit -q -m "chore: initialize repository" \
      || dm_die "initial commit failed (set git user.name and user.email)$remote_note"
    dm_info "publishing initial commit to origin and setting upstream"
    git -C "$dir" push -u origin "$branch" >/dev/null 2>&1 \
      || dm_die "push to origin failed (check auth; the remote must be empty). Local repo left at $dir$remote_note"
    register_repo "$name" "$remote" "$branch" "$mode" "$test_cmd"
    [ "$want_memory" -eq 1 ] && seed_memory "$name" || true
    dm_info "created and registered '$name' (mode=$mode, default_branch=$branch, origin=$remote)"
    ;;

  list)
    jq -r '.repos | to_entries[] | "\(.key)\t\(.value.mode)\t\(.value.default_branch)\t\(.value.remote)"' "$DM_REGISTRY" \
      | { printf 'NAME\tMODE\tBRANCH\tREMOTE\n'; cat; } | column -t -s$'\t' 2>/dev/null || cat
    ;;

  get)
    name="${1:-}"; field="${2:-}"
    [ -n "$name" ] || dm_die "usage: dm-repo.sh get <name> [<field>]"
    if [ -n "$field" ]; then dm_registry_get "$name" "$field"
    else jq -e --arg n "$name" '.repos[$n]' "$DM_REGISTRY" || dm_die "no such repo: $name"; fi
    ;;

  set)
    name="${1:-}"; field="${2:-}"; value="${3:-}"
    [ -n "$name" ] && [ -n "$field" ] || dm_die "usage: dm-repo.sh set <name> <field> <value>"
    jq -e --arg n "$name" '.repos[$n]' "$DM_REGISTRY" >/dev/null 2>&1 || dm_die "no such repo: $name"
    # Whitelist the settable fields. A free-form setter let a bad default_branch or
    # path silently misroute sync/merge; only known fields, validated, may change.
    case "$field" in
      yolo) case "$value" in true|false) ;; *) dm_die "yolo must be true|false" ;; esac
            registry_write --arg n "$name" --argjson v "$value" '.repos[$n].yolo = $v' ;;
      mode) require_valid_mode "$value"
            registry_write --arg n "$name" --arg v "$value" '.repos[$n].mode = $v' ;;
      default_branch)
            dir="$DM_REPOS/$name"
            [ -d "$dir/.git" ] || dm_die "cannot set default_branch: no clone at $dir"
            # It must actually resolve as a branch in the clone (local or on origin);
            # a bogus value would break worktree base selection and ff sync.
            git -C "$dir" rev-parse --verify --quiet "refs/heads/$value" >/dev/null 2>&1 \
              || git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$value" >/dev/null 2>&1 \
              || dm_die "default_branch '$value' is not a branch in the clone '$name'; fetch or create it first"
            registry_write --arg n "$name" --arg v "$value" '.repos[$n].default_branch = $v' ;;
      test_cmd|pipeline|remote)
            registry_write --arg n "$name" --arg f "$field" --arg v "$value" '.repos[$n][$f] = $v' ;;
      *)    dm_die "unknown field '$field'; settable fields: mode, yolo, test_cmd, pipeline, default_branch, remote" ;;
    esac
    dm_info "set $name.$field = $value"
    ;;

  remove)
    name="${1:-}"
    [ -n "$name" ] || dm_die "usage: dm-repo.sh remove <name>"
    dir="$DM_REPOS/$name"
    if [ -d "$dir/.git" ]; then
      # Fail closed: never drop a clone that still holds unlanded work.
      if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        dm_die "clone $name has uncommitted changes; resolve them before removing"
      fi
      # Refuse if any worktree beyond the primary is checked out. Count in one
      # shot: an early-closing `grep -q` in an `&&` guard can SIGPIPE git under
      # `set -o pipefail`, short-circuit the `&&`, and silently SKIP this refusal.
      # `grep -c` prints 0 (exit 1) when there are none, so `|| true` keeps set -e
      # from firing; the primary worktree itself counts as 1.
      n="$(git -C "$dir" worktree list --porcelain 2>/dev/null | grep -c '^worktree' || true)"
      [ "${n:-0}" -gt 1 ] && dm_die "clone $name has active worktrees; tear them down first"
    fi
    # Fail closed on live tasks: a non-terminal task pointing at this repo would be
    # orphaned by removal — its later dm-worktree/dm-sync calls die "no clone".
    # Terminal (done) tasks are safe to leave behind. The registry entry is still
    # present here, so `dm-task.sh state` can resolve each referencing task.
    live=""
    task_sh="$(dirname "$0")/dm-task.sh"
    while IFS= read -r tid; do
      [ "$(dm_meta_get "$tid" repo)" = "$name" ] || continue
      st="$("$task_sh" state "$tid" 2>/dev/null | sed -n 's/^state: \([^ ]*\).*/\1/p')"
      [ "$st" = "done" ] && continue
      live="$live $tid($st)"
    done < <(dm_all_task_ids)
    [ -z "$live" ] || dm_die "repo $name is referenced by live task(s):$live — finish or tear them down before unregistering the repo"
    registry_write --arg n "$name" 'del(.repos[$n])'
    dm_info "unregistered '$name' (clone left on disk at $dir; delete manually if intended)"
    ;;

  seed)
    name="${1:-}"; [ -n "$name" ] || dm_die "usage: dm-repo.sh seed <name>"
    seed_memory "$name"
    ;;

  *)
    echo "usage: dm-repo.sh {add|create|list|get|set|remove|seed} ..." >&2; exit 2 ;;
esac

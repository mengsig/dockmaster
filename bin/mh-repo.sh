#!/usr/bin/env bash
# mh-repo.sh - manage the registry of repositories the manhandler operates on.
#
# The registry (state/repos.json) is the single source of truth for what is
# managed. Each repo is cloned once under repos/<name> (read-only to the
# manhandler; crewmates work in worktrees off that clone) and gets its own
# per-repo memory via contextgraph init.
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
#   init-memory <name>       (idempotent contextgraph init in the clone)
#
# Modes: pipeline (default, full PR gate pipeline) | direct-pr | local-only.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need git; mh_need jq
mh_ensure_dirs

cmd="${1:-}"; shift || true

registry_write() {
  # registry_write <jq-filter> [args...] - atomic update of repos.json
  local tmp; tmp="$(mktemp "$MH_STATE/.repos.XXXXXX")"
  jq "$@" "$MH_REGISTRY" > "$tmp" && mv -f "$tmp" "$MH_REGISTRY"
}

# register_repo <name> <remote> <branch> <mode> <test_cmd> - write the canonical
# registry entry for a managed repo. Single owner of the entry shape, shared by
# `add` (clone existing) and `create` (make new) so the two cannot drift.
register_repo() {
  registry_write \
    --arg n "$1" --arg r "$2" --arg p "repos/$1" \
    --arg b "$3" --arg m "$4" --arg t "$5" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.repos[$n] = {remote:$r, path:$p, default_branch:$b, mode:$m, yolo:false, test_cmd:$t, pipeline:"default", contextgraph:false, added:$ts}'
}

# Deliver contextgraph memory INTO the repo as tracked content, through the
# repo's normal delivery path, so it travels with the repo and every worktree.
# For local-only repos it fast-forward-lands; otherwise it opens a PR to approve.
init_memory() {
  local name="$1" dir="$MH_REPOS/$1"
  [ -d "$dir/.git" ] || mh_die "no clone at $dir"
  command -v contextgraph >/dev/null 2>&1 || { mh_warn "contextgraph not on PATH; skipping memory init for $name"; registry_write --arg n "$name" '.repos[$n].contextgraph = false'; return 0; }
  if git -C "$dir" ls-files --error-unmatch .contextgraph/repo.md >/dev/null 2>&1; then
    mh_info "contextgraph memory already tracked in $name"
    registry_write --arg n "$name" '.repos[$n].contextgraph = true'
    return 0
  fi
  local mode id wt br
  mode="$(mh_registry_get "$name" mode)"; [ -n "$mode" ] || mode="pipeline"
  id="$name-init-memory"
  "$(dirname "$0")/mh-task.sh" new "$id" --kind ship --repo "$name" --mode "$mode" --title "initialize contextgraph memory" >/dev/null 2>&1 || true
  wt="$("$(dirname "$0")/mh-worktree.sh" create "$id" "$name" 2>/dev/null | tail -n1)"
  [ -d "$wt" ] || { mh_warn "could not create worktree to initialize memory for $name; skipping"; registry_write --arg n "$name" '.repos[$n].contextgraph = false'; return 0; }
  br="chore/x/init-contextgraph-memory"
  git -C "$wt" checkout -q -b "$br"
  # Fail OPEN: memory is optional. If contextgraph is unavailable or broken,
  # clean up and leave the repo registered without memory (retry later).
  if ! ( cd "$wt" && contextgraph init >/dev/null 2>&1 ); then
    mh_warn "contextgraph init failed for $name (contextgraph unavailable?); repo registered without memory. Retry later: mh-repo.sh init-memory $name"
    "$(dirname "$0")/mh-worktree.sh" remove "$id" --force >/dev/null 2>&1 || true
    "$(dirname "$0")/mh-task.sh" set "$id" kind scout >/dev/null 2>&1 || true
    registry_write --arg n "$name" '.repos[$n].contextgraph = false'
    return 0
  fi
  mh_cg_stage "$wt"
  if git -C "$wt" diff --cached --quiet; then
    mh_warn "contextgraph init produced no changes for $name"
  else
    git -C "$wt" -c commit.gpgsign=false commit -q -m "chore: initialize contextgraph memory" || mh_die "commit failed"
  fi
  registry_write --arg n "$name" '.repos[$n].contextgraph = true'
  if [ "$mode" = "local-only" ]; then
    "$(dirname "$0")/mh-merge.sh" local "$id" && "$(dirname "$0")/mh-worktree.sh" remove "$id"
    mh_info "contextgraph memory landed locally in $name"
  else
    mh_info "contextgraph memory committed on branch '$br' for $name."
    mh_info "Open a PR to track it: bin/mh-pr.sh open $id --title \"initialize contextgraph memory\" --body \"Adds contextgraph memory so per-repo context travels with the repo.\""
  fi
}

case "$cmd" in
  add)
    name="${1:-}"; remote="${2:-}"; shift 2 || true
    [ -n "$name" ] && [ -n "$remote" ] || mh_die "usage: mh-repo.sh add <name> <remote> [--mode M] [--test-cmd C] [--branch B] [--no-memory]"
    mh_require_id "$name"
    mode="pipeline"; test_cmd=""; branch=""; want_memory=1
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --test-cmd) test_cmd="${2:-}"; shift 2 ;;
        --branch) branch="${2:-}"; shift 2 ;;
        --no-memory) want_memory=0; shift ;;
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    case "$mode" in pipeline|direct-pr|local-only) ;; *) mh_die "mode must be pipeline|direct-pr|local-only" ;; esac
    jq -e --arg n "$name" '.repos[$n]' "$MH_REGISTRY" >/dev/null 2>&1 && mh_die "repo '$name' already registered"
    dir="$MH_REPOS/$name"
    [ -e "$dir" ] && mh_die "path already exists: $dir"
    mh_info "cloning $remote -> $dir"
    git clone "$remote" "$dir" || mh_die "clone failed"
    [ -n "$branch" ] || branch="$(mh_default_branch "$dir")"
    register_repo "$name" "$remote" "$branch" "$mode" "$test_cmd"
    [ "$want_memory" -eq 1 ] && init_memory "$name" || true
    mh_info "registered '$name' (mode=$mode, default_branch=$branch)"
    ;;

  create)
    name="${1:-}"; shift || true
    [ -n "$name" ] || mh_die "usage: mh-repo.sh create <name> [<remote>] [--mode M] [--test-cmd C] [--branch B] [--public|--private] [--https] [--description D] [--no-memory]"
    mh_require_id "$name"
    # optional positional remote: the first arg that is not a flag
    remote=""
    case "${1:-}" in ""|-*) ;; *) remote="$1"; shift ;; esac
    mode="pipeline"; test_cmd=""; branch="main"; visibility="private"; scheme="ssh"; description=""; want_memory=1
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
        *) mh_die "unknown flag: $1" ;;
      esac
    done
    case "$mode" in pipeline|direct-pr|local-only) ;; *) mh_die "mode must be pipeline|direct-pr|local-only" ;; esac
    jq -e --arg n "$name" '.repos[$n]' "$MH_REGISTRY" >/dev/null 2>&1 && mh_die "repo '$name' already registered"
    dir="$MH_REPOS/$name"
    [ -e "$dir" ] && mh_die "path already exists: $dir"

    # Resolve the remote. Either the operator supplies an EMPTY remote they made,
    # or (no remote given) we create the GitHub repo ourselves.
    if [ -n "$remote" ]; then
      refs="$(git ls-remote --heads "$remote" 2>/dev/null)" || mh_die "cannot reach remote '$remote' (bad url or auth?)"
      [ -z "$refs" ] || mh_die "remote '$remote' already has branches; use 'mh-repo.sh add' to clone an existing repo"
    else
      mh_need gh-axi
      mh_info "creating GitHub repository '$name' ($visibility)"
      create_args=(repo create "$name" "--$visibility")
      [ -n "$description" ] && create_args+=(--description "$description")
      out="$(gh-axi "${create_args[@]}" 2>&1)" || mh_die "gh repo create failed:
$out"
      html="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[A-Za-z0-9._/-]+' | head -n1)"
      [ -n "$html" ] || mh_die "could not parse the new repo url from gh output:
$out"
      slug="$(printf '%s' "$html" | sed -E 's#^https://github\.com/##; s#\.git$##')"
      case "$scheme" in
        https) remote="https://github.com/$slug.git" ;;
        *)     remote="git@github.com:$slug.git" ;;
      esac
    fi

    # Initialize a local repo with ONE commit so it has a default branch and a
    # base for worktrees, then publish and set upstream. This is the repo-init
    # write sanctioned for mh-repo.sh; it never forces and never touches an
    # existing clone (the path is guaranteed absent above).
    git init -q -b "$branch" "$dir" || mh_die "git init failed"
    git -C "$dir" remote add origin "$remote"
    printf '# %s\n' "$name" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" -c commit.gpgsign=false commit -q -m "chore: initialize repository" \
      || mh_die "initial commit failed (set git user.name and user.email)"
    mh_info "publishing initial commit to origin and setting upstream"
    git -C "$dir" push -u origin "$branch" >/dev/null 2>&1 \
      || mh_die "push to origin failed (check auth; the remote must be empty). Local repo left at $dir"
    register_repo "$name" "$remote" "$branch" "$mode" "$test_cmd"
    [ "$want_memory" -eq 1 ] && init_memory "$name" || true
    mh_info "created and registered '$name' (mode=$mode, default_branch=$branch, origin=$remote)"
    ;;

  list)
    jq -r '.repos | to_entries[] | "\(.key)\t\(.value.mode)\t\(.value.default_branch)\t\(.value.remote)"' "$MH_REGISTRY" \
      | { printf 'NAME\tMODE\tBRANCH\tREMOTE\n'; cat; } | column -t -s$'\t' 2>/dev/null || cat
    ;;

  get)
    name="${1:-}"; field="${2:-}"
    [ -n "$name" ] || mh_die "usage: mh-repo.sh get <name> [<field>]"
    if [ -n "$field" ]; then mh_registry_get "$name" "$field"
    else jq -e --arg n "$name" '.repos[$n]' "$MH_REGISTRY" || mh_die "no such repo: $name"; fi
    ;;

  set)
    name="${1:-}"; field="${2:-}"; value="${3:-}"
    [ -n "$name" ] && [ -n "$field" ] || mh_die "usage: mh-repo.sh set <name> <field> <value>"
    jq -e --arg n "$name" '.repos[$n]' "$MH_REGISTRY" >/dev/null 2>&1 || mh_die "no such repo: $name"
    case "$field" in
      yolo) case "$value" in true|false) ;; *) mh_die "yolo must be true|false" ;; esac
            registry_write --arg n "$name" --argjson v "$value" '.repos[$n].yolo = $v' ;;
      mode) case "$value" in pipeline|direct-pr|local-only) ;; *) mh_die "mode must be pipeline|direct-pr|local-only" ;; esac
            registry_write --arg n "$name" --arg v "$value" '.repos[$n].mode = $v' ;;
      *)    registry_write --arg n "$name" --arg f "$field" --arg v "$value" '.repos[$n][$f] = $v' ;;
    esac
    mh_info "set $name.$field = $value"
    ;;

  remove)
    name="${1:-}"
    [ -n "$name" ] || mh_die "usage: mh-repo.sh remove <name>"
    dir="$MH_REPOS/$name"
    if [ -d "$dir/.git" ]; then
      # Fail closed: never drop a clone that still holds unlanded work.
      if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        mh_die "clone $name has uncommitted changes; resolve them before removing"
      fi
      if git -C "$dir" worktree list --porcelain 2>/dev/null | grep -q '^worktree' \
         && [ "$(git -C "$dir" worktree list --porcelain | grep -c '^worktree')" -gt 1 ]; then
        mh_die "clone $name has active worktrees; tear them down first"
      fi
    fi
    registry_write --arg n "$name" 'del(.repos[$n])'
    mh_info "unregistered '$name' (clone left on disk at $dir; delete manually if intended)"
    ;;

  init-memory)
    name="${1:-}"; [ -n "$name" ] || mh_die "usage: mh-repo.sh init-memory <name>"
    init_memory "$name"
    ;;

  *)
    echo "usage: mh-repo.sh {add|create|list|get|set|remove|init-memory} ..." >&2; exit 2 ;;
esac

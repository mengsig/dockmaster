#!/usr/bin/env bash
# mh-memory.sh - the manhandler's native, plain-markdown context system.
#
# No bespoke database, no query engine: memory is markdown you can read, diff,
# and edit by hand. Three stores, each with exactly one owner:
#
#   1. SHARED (committed, travels)  - the `mh:knowledge` section inside a managed
#      repo's own AGENTS.md. Contributor-relevant facts (build/test commands,
#      conventions, invariants, pitfalls, routing). It is committed and so reaches
#      every clone and worktree for free. The manhandler NEVER hand-writes a
#      managed repo's tracked AGENTS.md (prime directive): a crewmate edits this
#      section IN ITS WORKTREE and commits it with its work. `seed` only guarantees
#      the scaffold exists, and only where doing so cannot dirty a tracked file.
#
#   2. PRIVATE (git-excluded, manhandler-only)  - repos/<repo>/.mh/notes.md. Fleet
#      strategy, per-repo operator preferences, sensitive routing: things that must
#      NOT enter the user's project history. Excluded via the clone's
#      .git/info/exclude so it never shows as untracked or gets committed.
#
#   3. GLOBAL (orchestrator)  - state/learnings.md (fleet-wide facts + gotchas) and
#      state/operator.md (operator preferences), in the manhandler home.
#
# A secret value must NEVER be written into any store (mirror the credential-
# handoff rule): pass a reference, never the value. This tool does not persist
# secrets, transient failures, task status, plans, or code excerpts.
#
# Usage:
#   mh-memory.sh recall <repo> [query]
#   mh-memory.sh recall --global [query]
#   mh-memory.sh remember <repo> --private --kind <kind> "<fact>"
#   mh-memory.sh remember --global --kind <kind> "<fact>"
#   mh-memory.sh seed <repo>
#   mh-memory.sh --help
#
# kinds: command convention invariant pitfall routing decision

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need git; mh_need jq
mh_ensure_dirs

MH_KNOWLEDGE_START='<!-- mh:knowledge:start -->'
MH_KNOWLEDGE_END='<!-- mh:knowledge:end -->'

usage() {
  cat <<'EOF'
mh-memory.sh - native plain-markdown context for the manhandler

  recall <repo> [query]            print a repo's SHARED knowledge (its AGENTS.md
                                   mh:knowledge section) + PRIVATE notes; [query]
                                   filters matching lines (grep -i).
  recall --global [query]          print state/learnings.md + state/operator.md.
  remember <repo> --private --kind <kind> "<fact>"
                                   append one dated bullet to repos/<repo>/.mh/notes.md.
  remember --global --kind <kind> "<fact>"
                                   append one dated bullet to state/learnings.md.
  seed <repo>                      ensure the private store (git-excluded) and the
                                   AGENTS.md mh:knowledge markers exist. Idempotent.

  kinds: command convention invariant pitfall routing decision

SHARED knowledge is authored by a crewmate editing the AGENTS.md mh:knowledge
section in its worktree and committing it - never appended through this tool.
Never record a secret value in any store.
EOF
}

# --- validation --------------------------------------------------------------
validate_kind() {
  case "$1" in
    command|convention|invariant|pitfall|routing|decision) ;;
    *) mh_die "invalid kind '$1'; use one of: command convention invariant pitfall routing decision" ;;
  esac
}

validate_fact() {
  [ -n "$1" ] || mh_die "fact must not be empty"
  case "$1" in *$'\n'*) mh_die "fact must be a single line (no newlines)" ;; esac
}

require_registered() {
  mh_require_id "$1"
  mh_registry_get "$1" >/dev/null 2>&1 || mh_die "repo '$1' is not registered; add it with mh-repo.sh add"
}

clone_dir() {
  local p; p="$(mh_registry_get "$1" path)"
  [ -n "$p" ] || mh_die "repo '$1' has no path in the registry"
  printf '%s/%s\n' "$MH_HOME" "$p"
}

# --- shared-knowledge extraction ---------------------------------------------
# Print the lines strictly between the mh:knowledge markers of file $1.
extract_knowledge() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -v s="$MH_KNOWLEDGE_START" -v e="$MH_KNOWLEDGE_END" '
    index($0, s) { inside = 1; next }
    index($0, e) { inside = 0 }
    inside
  ' "$f"
}

# print_section <label> <content> <query> - render one store, filtered if a query
# is given. Keeps the store label visible even when nothing matches.
print_section() {
  local label="$1" content="$2" query="$3" shown
  printf '== %s ==\n' "$label"
  if [ -z "$content" ]; then
    printf '  (empty)\n\n'; return 0
  fi
  if [ -n "$query" ]; then
    shown="$(printf '%s\n' "$content" | grep -i -e "$query" || true)"
    if [ -z "$shown" ]; then printf '  (no lines match "%s")\n\n' "$query"; return 0; fi
    printf '%s\n\n' "$shown"
  else
    printf '%s\n\n' "$content"
  fi
}

# --- private store scaffolding -----------------------------------------------
# Ensure repos/<repo>/.mh/notes.md exists and .mh/ is git-excluded in the clone,
# so the private store never shows as untracked and can never be committed.
ensure_private_store() {
  local repo="$1" dir mhdir notes excl
  dir="$(clone_dir "$repo")"
  [ -d "$dir/.git" ] || mh_die "no clone at $dir for repo '$repo'"
  mhdir="$dir/.mh"; notes="$mhdir/notes.md"
  mkdir -p "$mhdir"
  if [ ! -f "$notes" ]; then
    printf '<!-- manhandler private notes for %s - git-excluded, never committed -->\n' "$repo" > "$notes"
  fi
  excl="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$excl" ] || return 0
  case "$excl" in /*) ;; *) excl="$dir/$excl" ;; esac
  mkdir -p "$(dirname "$excl")"
  if [ ! -f "$excl" ] || ! grep -qxF '.mh/' "$excl" 2>/dev/null; then
    printf '.mh/\n' >> "$excl"
  fi
}

# --- shared-knowledge scaffolding --------------------------------------------
# Ensure the AGENTS.md mh:knowledge markers exist. Honors the prime directive:
# a managed repo's TRACKED AGENTS.md is never hand-written here (the section is
# authored by a crewmate in a worktree). Only an absent or untracked AGENTS.md,
# which cannot dirty tracked content or break fast-forward sync, is scaffolded.
ensure_shared_markers() {
  local repo="$1" dir agents existed=0
  dir="$(clone_dir "$repo")"
  agents="$dir/AGENTS.md"
  if [ -f "$agents" ] && grep -q 'mh:knowledge:start' "$agents" 2>/dev/null; then
    return 0
  fi
  if [ -f "$agents" ] && git -C "$dir" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then
    mh_warn "repo '$repo' has a tracked AGENTS.md without an mh:knowledge section; a crewmate must add it in a worktree (not seeded here)."
    return 0
  fi
  [ -f "$agents" ] && existed=1
  {
    if [ "$existed" = 1 ]; then printf '\n'; else printf '# %s\n\n' "$repo"; fi
    printf '%s\n' "$MH_KNOWLEDGE_START"
    printf '## Repository knowledge (manhandler-maintained)\n'
    printf '_Durable, non-obvious facts about this repo: build/test commands, conventions,\n'
    printf 'invariants, pitfalls, routing. Curated - not append-forever._\n\n'
    printf '%s\n' "$MH_KNOWLEDGE_END"
  } >> "$agents"
}

# --- verbs -------------------------------------------------------------------
recall_repo() {
  local repo="$1" query="${2:-}" dir shared_content priv_content priv_file
  require_registered "$repo"
  dir="$(clone_dir "$repo")"
  shared_content="$(extract_knowledge "$dir/AGENTS.md")"
  priv_file="$dir/.mh/notes.md"; priv_content=""
  [ -f "$priv_file" ] && priv_content="$(cat "$priv_file")"
  print_section "shared knowledge: $repo ($dir/AGENTS.md)" "$shared_content" "$query"
  print_section "private notes: $repo ($priv_file)" "$priv_content" "$query"
}

recall_global() {
  local query="${1:-}" learn operator lc oc
  learn="$MH_STATE/learnings.md"; operator="$MH_STATE/operator.md"
  lc=""; [ -f "$learn" ] && lc="$(cat "$learn")"
  oc=""; [ -f "$operator" ] && oc="$(cat "$operator")"
  print_section "fleet learnings ($learn)" "$lc" "$query"
  print_section "operator preferences ($operator)" "$oc" "$query"
}

remember_private() {
  local repo="$1" kind="$2" fact="$3" dir notes bullet
  require_registered "$repo"
  validate_kind "$kind"; validate_fact "$fact"
  ensure_private_store "$repo"
  dir="$(clone_dir "$repo")"; notes="$dir/.mh/notes.md"
  bullet="- **[$kind]** $fact  _($(date -u +%Y-%m-%dT%H:%M:%SZ))_"
  mh_lock "$notes"
  printf '%s\n' "$bullet" >> "$notes" || { mh_unlock "$notes"; mh_die "failed appending private note for '$repo'"; }
  mh_unlock "$notes"
  mh_info "recorded private note for '$repo'"
}

remember_global() {
  local kind="$1" fact="$2" f bullet
  validate_kind "$kind"; validate_fact "$fact"
  f="$MH_STATE/learnings.md"
  bullet="- **[$kind]** $fact  _($(date -u +%Y-%m-%dT%H:%M:%SZ))_"
  mh_lock "$f"
  if [ ! -f "$f" ]; then
    printf '# Fleet learnings (manhandler global memory)\n\n_Fleet-wide operational facts and gotchas - dated, evidence-backed, pruned._\n\n' > "$f" \
      || { mh_unlock "$f"; mh_die "failed creating $f"; }
  fi
  printf '%s\n' "$bullet" >> "$f" || { mh_unlock "$f"; mh_die "failed appending fleet learning"; }
  mh_unlock "$f"
  mh_info "recorded fleet learning"
}

seed_repo() {
  local repo="$1"
  require_registered "$repo"
  ensure_private_store "$repo"
  ensure_shared_markers "$repo"
  mh_info "seeded memory scaffold for '$repo' (.mh/ private store + AGENTS.md mh:knowledge markers)"
}

# --- dispatch ----------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  recall)
    if [ "${1:-}" = "--global" ]; then
      shift
      recall_global "${1:-}"
    else
      repo="${1:-}"; [ -n "$repo" ] || mh_die "usage: mh-memory.sh recall <repo> [query] | recall --global [query]"
      shift || true
      recall_repo "$repo" "${1:-}"
    fi
    ;;

  remember)
    target="${1:-}"; shift || true
    [ -n "$target" ] || mh_die "usage: mh-memory.sh remember <repo> --private --kind <kind> \"<fact>\" | remember --global --kind <kind> \"<fact>\""
    if [ "$target" = "--global" ]; then
      kind=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --kind) kind="${2:-}"; shift 2 ;;
          --) shift; break ;;
          -*) mh_die "unknown flag: $1" ;;
          *) break ;;
        esac
      done
      [ -n "$kind" ] || mh_die "remember --global requires --kind <kind>"
      fact="${1:-}"; [ -n "$fact" ] || mh_die "remember --global requires a \"<fact>\""
      remember_global "$kind" "$fact"
    else
      repo="$target"; private=0; kind=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --private) private=1; shift ;;
          --kind) kind="${2:-}"; shift 2 ;;
          --) shift; break ;;
          -*) mh_die "unknown flag: $1" ;;
          *) break ;;
        esac
      done
      [ "$private" = 1 ] || mh_die "repo-scoped remember must use --private; SHARED knowledge is authored by a crewmate in the repo's AGENTS.md mh:knowledge section, not appended here"
      [ -n "$kind" ] || mh_die "remember <repo> --private requires --kind <kind>"
      fact="${1:-}"; [ -n "$fact" ] || mh_die "remember <repo> --private requires a \"<fact>\""
      remember_private "$repo" "$kind" "$fact"
    fi
    ;;

  seed)
    repo="${1:-}"; [ -n "$repo" ] || mh_die "usage: mh-memory.sh seed <repo>"
    seed_repo "$repo"
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    mh_die "unknown command '$cmd'; run mh-memory.sh --help"
    ;;
esac

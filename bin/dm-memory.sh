#!/usr/bin/env bash
# dm-memory.sh - the dockmaster's native, plain-markdown context system.
#
# No bespoke database, no query engine: memory is markdown you can read, diff,
# and edit by hand. Three stores, each with exactly one owner:
#
#   1. SHARED (committed, travels)  - the `dm:knowledge` section inside a managed
#      repo's own AGENTS.md, delimited by the markers below. Contributor-relevant
#      facts (build/test commands, conventions, invariants, pitfalls, routing). It
#      is committed and so reaches every clone and worktree for free. The dockmaster
#      NEVER writes it here: a crewmate adds/edits this section IN ITS WORKTREE and
#      commits it with its work, so the clone stays pristine (landable and
#      fast-forward-syncable). `seed` therefore never touches the clone's AGENTS.md;
#      `recall` reads whatever committed section the clone has.
#
#   2. PRIVATE (git-excluded, RELAYED to crewmates)  - repos/<repo>/.dm/notes.md.
#      Per-repo orchestration context: routing, per-repo operator preferences,
#      strategy. Excluded via the clone's .git/info/exclude so it never enters the
#      user's project history, but `recall` DOES inject it into every crewmate
#      brief for the crewmate's awareness (not to be copied into commits or the
#      repo's AGENTS.md). Do NOT put anything a crewmate must never see here; use
#      the dockmaster-only store below for that.
#
#   2b. DOCKMASTER-ONLY (git-excluded, NEVER relayed)  - repos/<repo>/.dm/private.md.
#      The truly orchestrator-private store: `recall` shows it to the dockmaster,
#      but `dm-brief.sh` recalls with --crew and EXCLUDES it, so it never reaches a
#      crewmate brief. Sensitive routing the crew must not see lives here.
#
#   3. GLOBAL (orchestrator)  - state/learnings.md (fleet-wide facts + gotchas) and
#      state/operator.md (operator preferences), in the dockmaster home.
#
# A secret value must NEVER be written into any store (mirror the credential-
# handoff rule): pass a reference, never the value. This tool does not persist
# secrets, transient failures, task status, plans, or code excerpts.
#
# Usage:
#   dm-memory.sh recall <repo> [query] [--crew]
#   dm-memory.sh recall --global [query]
#   dm-memory.sh remember <repo> --private --kind <kind> "<fact>"
#   dm-memory.sh remember <repo> --dockmaster-only --kind <kind> "<fact>"
#   dm-memory.sh remember --global --kind <kind> "<fact>"
#   dm-memory.sh forget <repo> --private <substring>
#   dm-memory.sh forget <repo> --dockmaster-only <substring>
#   dm-memory.sh forget --global <substring>
#   dm-memory.sh seed <repo>
#   dm-memory.sh --help
#
# kinds: command convention invariant pitfall routing decision

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git; dm_need jq
dm_ensure_dirs

DM_KNOWLEDGE_START='<!-- dm:knowledge:start -->'
DM_KNOWLEDGE_END='<!-- dm:knowledge:end -->'

# Soft per-store line cap for recall output. Keeps an unbounded store from
# flooding a brief (dm-brief injects recall verbatim); a tail pointer tells the
# reader how to see the rest with a query. Full content is always reachable via
# an explicit query, which is filtered before the cap applies.
DM_RECALL_MAX_LINES="${DM_RECALL_MAX_LINES:-40}"
case "$DM_RECALL_MAX_LINES" in
  ''|*[!0-9]*|0) dm_warn "DM_RECALL_MAX_LINES='$DM_RECALL_MAX_LINES' is not a positive integer; using 40"; DM_RECALL_MAX_LINES=40 ;;
esac

usage() {
  cat <<'EOF'
dm-memory.sh - native plain-markdown context for the dockmaster

  recall <repo> [query] [--crew]   print a repo's SHARED knowledge (its AGENTS.md
                                   dm:knowledge section) + PRIVATE notes + the
                                   DOCKMASTER-ONLY store; [query] filters to lines
                                   matching any whitespace-separated term as a
                                   literal, case-insensitive substring (grep -i -F,
                                   OR of terms). Output is soft-capped per store
                                   (DM_RECALL_MAX_LINES, default 40) with a tail
                                   pointer; narrow with a query to see the rest.
                                   --crew omits the dockmaster-only store (what
                                   dm-brief injects into a crewmate brief).
  recall --global [query]          print state/learnings.md + state/operator.md.
  remember <repo> --private --kind <kind> [--] "<fact>"
                                   append one dated bullet to repos/<repo>/.dm/notes.md
                                   (relayed to crewmate briefs).
  remember <repo> --dockmaster-only --kind <kind> [--] "<fact>"
                                   append one dated bullet to repos/<repo>/.dm/private.md
                                   (never relayed to a crewmate).
  remember --global --kind <kind> [--] "<fact>"
                                   append one dated bullet to state/learnings.md.

  Use -- to end flag parsing when the fact itself begins with - or -- (e.g.
  remember demo --private --kind command -- "-Wall enables all warnings").
  forget <repo> --private <substring>
  forget <repo> --dockmaster-only <substring>
  forget --global <substring>      remove every bullet line matching <substring>
                                   (literal) from the store, printing what it
                                   removed. Fails if nothing matched.
  seed <repo>                      ensure the git-excluded private store exists.
                                   Idempotent. Never touches the clone's AGENTS.md.

  kinds: command convention invariant pitfall routing decision

SHARED knowledge is authored by a crewmate adding an dm:knowledge section to the
repo's AGENTS.md in its worktree and committing it - never written through this
tool (that would dirty the clone). Never record a secret value in any store.
EOF
}

# --- validation --------------------------------------------------------------
validate_kind() {
  case "$1" in
    command|convention|invariant|pitfall|routing|decision) ;;
    *) dm_die "invalid kind '$1'; use one of: command convention invariant pitfall routing decision" ;;
  esac
}

validate_fact() {
  [ -n "$1" ] || dm_die "fact must not be empty"
  case "$1" in *$'\n'*) dm_die "fact must be a single line (no newlines)" ;; esac
  # The "never store a secret value" rule is advisory here: this validation does
  # not (and cannot reliably) detect secrets. credential-handoff owns that
  # control — pass a reference, never the value.
}

require_registered() {
  dm_require_id "$1"
  dm_registry_get "$1" >/dev/null 2>&1 || dm_die "repo '$1' is not registered; add it with dm-repo.sh add"
}

clone_dir() {
  local p; p="$(dm_registry_get "$1" path)"
  [ -n "$p" ] || dm_die "repo '$1' has no path in the registry"
  printf '%s/%s\n' "$DM_HOME" "$p"
}

# --- shared-knowledge extraction ---------------------------------------------
# Print the lines strictly between the dm:knowledge markers of file $1. Only a
# block closed by a matching end marker is emitted: lines are buffered between
# markers and flushed on `end`. A start marker with no end (a truncated or
# mis-edited AGENTS.md) emits NOTHING and warns to stderr, so the file's whole
# tail — including the coding-guidelines mirror — can never leak into recall and
# every crewmate brief.
#
# A marker is recognized only when it is the WHOLE trimmed line, so a repo that
# documents the literal marker in prose or a code fence does not mis-trigger
# extraction. The buffered content uses the original ($0) lines, unmodified.
extract_knowledge() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -v s="$DM_KNOWLEDGE_START" -v e="$DM_KNOWLEDGE_END" -v file="$f" '
    { trimmed = $0; sub(/^[ \t]+/, "", trimmed); sub(/[ \t]+$/, "", trimmed) }
    trimmed == s { inside = 1; buf = ""; next }
    inside && trimmed == e { printf "%s", buf; inside = 0; buf = ""; next }
    inside { buf = buf $0 "\n" }
    END {
      if (inside)
        print "dm-memory: dm:knowledge start marker without a matching end in " file "; recall omits it (file may be truncated)" > "/dev/stderr"
    }
  ' "$f"
}

# filter_query <content> <query> - keep the lines of <content> that match ANY
# whitespace-separated term of <query> as a literal, case-insensitive substring
# (grep -i -F, OR of terms). Terms are built into a `-e` args array in a loop so
# it stays bash-3.2-safe (no process substitution, no arrays expanded empty under
# set -u). An all-whitespace query degrades to "no filter" (returns content).
filter_query() {
  local content="$1" query="$2" term
  set -f  # $query is split on whitespace intentionally; -f stops pathname
          # globbing (a term like "*.md" must stay literal, not match CWD files)
  set -- # reuse the positional args as the term list
  for term in $query; do set -- "$@" -e "$term"; done
  set +f
  if [ "$#" -eq 0 ]; then printf '%s\n' "$content"; return 0; fi
  grep -i -F "$@" <<<"$content" || true
}

# emit_capped <content> <hint> - print at most DM_RECALL_MAX_LINES lines of
# <content>; if more remain, print a tail pointer naming how many were omitted
# and the recall invocation (<hint>) that narrows the view. Reads via here-string
# (never a pipe into head) so an early-closing head cannot SIGPIPE the producer.
emit_capped() {
  local content="$1" hint="$2" total omitted
  total="$(grep -c '' <<<"$content")"
  if [ "$total" -le "$DM_RECALL_MAX_LINES" ]; then
    printf '%s\n\n' "$content"; return 0
  fi
  head -n "$DM_RECALL_MAX_LINES" <<<"$content"
  omitted=$((total - DM_RECALL_MAX_LINES))
  printf '  … %s older line(s) omitted — run `%s`\n\n' "$omitted" "$hint"
}

# print_section <label> <content> <query> <hint> - render one store, filtered if
# a query is given, then soft-capped. Keeps the store label visible even when
# empty or nothing matches. <hint> is the recall invocation the cap tail suggests.
print_section() {
  local label="$1" content="$2" query="$3" hint="${4:-dm-memory.sh recall <repo> <query>}" shown
  printf '== %s ==\n' "$label"
  if [ -z "$content" ]; then
    printf '  (empty)\n\n'; return 0
  fi
  if [ -n "$query" ]; then
    shown="$(filter_query "$content" "$query")"
    if [ -z "$shown" ]; then printf '  (no lines match "%s")\n\n' "$query"; return 0; fi
    emit_capped "$shown" "$hint"
  else
    emit_capped "$content" "$hint"
  fi
}

# --- private store scaffolding -----------------------------------------------
# Ensure repos/<repo>/.dm/<fname> exists (with a header) and .dm/ is git-excluded
# in the clone, so the store never shows as untracked and can never be committed.
# <header> is the leading text of the `<!-- ... for <repo> ... -->` comment.
ensure_store() {
  local repo="$1" fname="$2" header="$3" dir dmdir file excl
  dir="$(clone_dir "$repo")"
  [ -d "$dir/.git" ] || dm_die "no clone at $dir for repo '$repo'"
  dmdir="$dir/.dm"; file="$dmdir/$fname"
  mkdir -p "$dmdir"
  # Create the header under the lock so concurrent first writes cannot truncate
  # each other's store; `-s` guards against re-truncating an already-populated
  # file (mirrors remember_global's create-under-lock).
  dm_lock "$file"
  if [ ! -s "$file" ]; then
    printf '<!-- %s for %s - git-excluded, never committed -->\n' "$header" "$repo" > "$file" \
      || { dm_unlock "$file"; dm_die "failed creating $fname store for '$repo'"; }
  fi
  dm_unlock "$file"
  excl="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$excl" ] || return 0
  case "$excl" in /*) ;; *) excl="$dir/$excl" ;; esac
  mkdir -p "$(dirname "$excl")"
  if [ ! -f "$excl" ] || ! grep -qxF '.dm/' "$excl" 2>/dev/null; then
    printf '.dm/\n' >> "$excl"
  fi
}

ensure_private_store()    { ensure_store "$1" notes.md   "dockmaster private notes"; }
ensure_dockmaster_store() { ensure_store "$1" private.md "dockmaster-only notes"; }

# --- verbs -------------------------------------------------------------------
# recall_repo <repo> [query] [crew] - print the repo's stores. When crew=1 the
# dockmaster-only store is OMITTED (dm-brief passes --crew so a crewmate never
# sees it); the dockmaster's own recall (crew=0) includes it.
recall_repo() {
  local repo="$1" query="${2:-}" crew="${3:-0}" dir hint
  local shared_content priv_content priv_file dm_content dm_file
  require_registered "$repo"
  dir="$(clone_dir "$repo")"
  hint="dm-memory.sh recall $repo <query>"
  shared_content="$(extract_knowledge "$dir/AGENTS.md")"
  priv_file="$dir/.dm/notes.md"; priv_content=""
  [ -f "$priv_file" ] && priv_content="$(cat "$priv_file")"
  print_section "shared knowledge: $repo ($dir/AGENTS.md)" "$shared_content" "$query" "$hint"
  print_section "private notes: $repo ($priv_file)" "$priv_content" "$query" "$hint"
  if [ "$crew" != "1" ]; then
    dm_file="$dir/.dm/private.md"; dm_content=""
    [ -f "$dm_file" ] && dm_content="$(cat "$dm_file")"
    print_section "dockmaster-only notes: $repo ($dm_file)" "$dm_content" "$query" "$hint"
  fi
}

recall_global() {
  local query="${1:-}" learn operator lc oc
  learn="$DM_STATE/learnings.md"; operator="$DM_STATE/operator.md"
  lc=""; [ -f "$learn" ] && lc="$(cat "$learn")"
  oc=""; [ -f "$operator" ] && oc="$(cat "$operator")"
  print_section "fleet learnings ($learn)" "$lc" "$query" "dm-memory.sh recall --global <query>"
  print_section "operator preferences ($operator)" "$oc" "$query" "dm-memory.sh recall --global <query>"
}

# warn_if_duplicate <file> <fact> - non-fatal stderr warning when a bullet with
# the same fact BODY already exists, matched literally and ignoring the kind and
# the trailing date (the framing around the fact is `]** <fact>  _(`). Advisory
# only; the append still proceeds so no knowledge is silently dropped.
warn_if_duplicate() {
  local f="$1" fact="$2"
  [ -f "$f" ] || return 0
  if grep -qF -- "]** $fact  _(" "$f" 2>/dev/null; then
    dm_warn "a note with this exact fact body already exists in $f; appending anyway (use 'forget' to curate)"
  fi
}

# append_repo_note <repo> <kind> <fact> <file> <label> - append one dated bullet
# to a repo store, serialized by the lock. Shared by the private and
# dockmaster-only paths, which differ only in target file and label.
append_repo_note() {
  local repo="$1" kind="$2" fact="$3" file="$4" label="$5" bullet
  bullet="- **[$kind]** $fact  _($(date -u +%Y-%m-%dT%H:%M:%SZ))_"
  warn_if_duplicate "$file" "$fact"
  dm_lock "$file"
  printf '%s\n' "$bullet" >> "$file" || { dm_unlock "$file"; dm_die "failed appending $label for '$repo'"; }
  dm_unlock "$file"
  dm_info "recorded $label for '$repo'"
}

remember_private() {
  local repo="$1" kind="$2" fact="$3" dir
  require_registered "$repo"
  validate_kind "$kind"; validate_fact "$fact"
  ensure_private_store "$repo"
  dir="$(clone_dir "$repo")"
  append_repo_note "$repo" "$kind" "$fact" "$dir/.dm/notes.md" "private note"
}

remember_dockmaster() {
  local repo="$1" kind="$2" fact="$3" dir
  require_registered "$repo"
  validate_kind "$kind"; validate_fact "$fact"
  ensure_dockmaster_store "$repo"
  dir="$(clone_dir "$repo")"
  append_repo_note "$repo" "$kind" "$fact" "$dir/.dm/private.md" "dockmaster-only note"
}

remember_global() {
  local kind="$1" fact="$2" f bullet
  validate_kind "$kind"; validate_fact "$fact"
  f="$DM_STATE/learnings.md"
  bullet="- **[$kind]** $fact  _($(date -u +%Y-%m-%dT%H:%M:%SZ))_"
  warn_if_duplicate "$f" "$fact"
  dm_lock "$f"
  if [ ! -f "$f" ]; then
    printf '# Fleet learnings (dockmaster global memory)\n\n_Fleet-wide operational facts and gotchas - dated, evidence-backed, pruned._\n\n' > "$f" \
      || { dm_unlock "$f"; dm_die "failed creating $f"; }
  fi
  printf '%s\n' "$bullet" >> "$f" || { dm_unlock "$f"; dm_die "failed appending fleet learning"; }
  dm_unlock "$f"
  dm_info "recorded fleet learning"
}

# --- forget: locked removal of matching bullet lines -------------------------
# Remove every BULLET line (starts with "- ") of <file> that contains <substr>
# as a literal substring, rewriting the file atomically under the lock. Prints
# the removed lines. Fails (removes nothing) if no bullet matched, so a typo'd
# substring is a visible error, not a silent no-op. Non-bullet lines (the header)
# are never touched, even if they contain the substring.
forget_from_file() {
  local f="$1" substr="$2" desc="$3" bullets removed tmp
  bullets="$(grep -e '^- ' "$f" || true)"
  removed="$(grep -F -e "$substr" <<<"$bullets" || true)"
  if [ -z "$removed" ]; then
    dm_die "no $desc match \"$substr\"; nothing removed"
  fi
  dm_lock "$f"
  tmp="$(mktemp "$(dirname "$f")/.forget.XXXXXX")" || { dm_unlock "$f"; dm_die "mktemp failed for $(basename "$f")"; }
  awk -v s="$substr" '/^- / && index($0, s) { next } { print }' "$f" > "$tmp" \
    || { rm -f "$tmp"; dm_unlock "$f"; dm_die "failed rewriting $f"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; dm_unlock "$f"; dm_die "failed committing $f"; }
  dm_unlock "$f"
  dm_info "removed $desc matching \"$substr\":"
  printf '%s\n' "$removed"
}

forget_repo() {
  local repo="$1" fname="$2" substr="$3" desc="$4" dir f
  require_registered "$repo"
  dir="$(clone_dir "$repo")"; f="$dir/.dm/$fname"
  [ -f "$f" ] || dm_die "no $desc store for '$repo'; nothing to forget"
  forget_from_file "$f" "$substr" "$desc for '$repo'"
}

forget_global() {
  local substr="$1" f
  f="$DM_STATE/learnings.md"
  [ -f "$f" ] || dm_die "no fleet learnings store; nothing to forget"
  forget_from_file "$f" "$substr" "fleet learning(s)"
}

seed_repo() {
  local repo="$1"
  require_registered "$repo"
  ensure_private_store "$repo"
  dm_info "seeded private memory store for '$repo' (git-excluded repos/$repo/.dm/). Shared knowledge is added to the repo's AGENTS.md dm:knowledge section by a crewmate in a worktree."
}

# --- dispatch ----------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  recall)
    if [ "${1:-}" = "--global" ]; then
      shift
      recall_global "${1:-}"
    else
      repo=""; query=""; crew=0; endflags=0
      while [ "$#" -gt 0 ]; do
        if [ "$endflags" -eq 0 ]; then
          case "$1" in
            --crew) crew=1; shift; continue ;;
            --) endflags=1; shift; continue ;;
            -*) dm_die "unknown flag for recall: $1" ;;
          esac
        fi
        if [ -z "$repo" ]; then repo="$1"; else query="$query${query:+ }$1"; fi
        shift
      done
      [ -n "$repo" ] || dm_die "usage: dm-memory.sh recall <repo> [query] [--crew] | recall --global [query]"
      recall_repo "$repo" "$query" "$crew"
    fi
    ;;

  remember)
    target="${1:-}"; shift || true
    [ -n "$target" ] || dm_die "usage: dm-memory.sh remember <repo> --private --kind <kind> \"<fact>\" | remember --global --kind <kind> \"<fact>\""
    if [ "$target" = "--global" ]; then
      kind=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --kind) kind="${2:-}"; shift 2 ;;
          --) shift; break ;;
          -*) dm_die "unknown flag: $1" ;;
          *) break ;;
        esac
      done
      [ -n "$kind" ] || dm_die "remember --global requires --kind <kind>"
      fact="${1:-}"; [ -n "$fact" ] || dm_die "remember --global requires a \"<fact>\""
      remember_global "$kind" "$fact"
    else
      repo="$target"; private=0; mhonly=0; kind=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --private) private=1; shift ;;
          --dockmaster-only) mhonly=1; shift ;;
          --kind) kind="${2:-}"; shift 2 ;;
          --) shift; break ;;
          -*) dm_die "unknown flag: $1" ;;
          *) break ;;
        esac
      done
      [ "$private" = 1 ] || [ "$mhonly" = 1 ] || dm_die "repo-scoped remember must use --private or --dockmaster-only; SHARED knowledge is authored by a crewmate in the repo's AGENTS.md dm:knowledge section, not appended here"
      if [ "$private" = 1 ] && [ "$mhonly" = 1 ]; then dm_die "use only one of --private / --dockmaster-only"; fi
      [ -n "$kind" ] || dm_die "remember <repo> requires --kind <kind>"
      fact="${1:-}"; [ -n "$fact" ] || dm_die "remember <repo> requires a \"<fact>\""
      if [ "$mhonly" = 1 ]; then
        remember_dockmaster "$repo" "$kind" "$fact"
      else
        remember_private "$repo" "$kind" "$fact"
      fi
    fi
    ;;

  forget)
    target="${1:-}"; shift || true
    [ -n "$target" ] || dm_die "usage: dm-memory.sh forget <repo> --private <substring> | forget <repo> --dockmaster-only <substring> | forget --global <substring>"
    if [ "$target" = "--global" ]; then
      substr="${1:-}"; [ -n "$substr" ] || dm_die "forget --global requires a <substring>"
      forget_global "$substr"
    else
      repo="$target"; private=0; mhonly=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --private) private=1; shift ;;
          --dockmaster-only) mhonly=1; shift ;;
          --) shift; break ;;
          -*) dm_die "unknown flag: $1" ;;
          *) break ;;
        esac
      done
      [ "$private" = 1 ] || [ "$mhonly" = 1 ] || dm_die "repo-scoped forget must use --private or --dockmaster-only"
      if [ "$private" = 1 ] && [ "$mhonly" = 1 ]; then dm_die "use only one of --private / --dockmaster-only"; fi
      substr="${1:-}"; [ -n "$substr" ] || dm_die "forget <repo> requires a <substring>"
      if [ "$mhonly" = 1 ]; then
        forget_repo "$repo" private.md "$substr" "dockmaster-only note(s)"
      else
        forget_repo "$repo" notes.md "$substr" "private note(s)"
      fi
    fi
    ;;

  seed)
    repo="${1:-}"; [ -n "$repo" ] || dm_die "usage: dm-memory.sh seed <repo>"
    seed_repo "$repo"
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    dm_die "unknown command '$cmd'; run dm-memory.sh --help"
    ;;
esac

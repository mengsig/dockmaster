#!/usr/bin/env bash
# dm-state.sh - export and import the dockmaster's orchestration state.
#
# state/ is the system of record - the registry, every task record, the backlog,
# and the memory that makes the fleet improve - and it is single-copy, gitignored
# local files. Without an export path, machine loss destroys all of it. This
# script produces one portable checksummed archive and restores it into another
# checkout.
#
# Commands:
#   export [--out FILE] [--with-artifacts]   write a .tar.gz of the record set
#   verify FILE                              check an archive without installing
#   import FILE [--force]                    restore into THIS checkout ($DM_HOME)
#
# Import has no target flag: it installs into $DM_HOME, the root the OPERATOR
# chose (the checkout it runs from, or an explicit DM_HOME). The security
# property is narrower than "cannot be aimed anywhere" - it is that nothing
# INSIDE the archive can redirect where its contents land.
#
# WHAT TRAVELS - the record set: state/repos.json, state/tasks/*.meta|.status,
# state/backlog.json, state/backlog.md, state/operator.md, state/learnings.md,
# state/secondmates.json, state/archive/*.meta|.status, and the git-excluded
# per-repo memory sidecars repos/<repo>/.dm/*.md. With --with-artifacts, also
# data/** and state/archive/<id>/** (briefs, scout reports, review pages).
#
# WHAT NEVER TRAVELS, and why:
#   repos/<name>/            managed clones - re-clonable from the registry remote
#   state/worktrees/         live local copies - git checkouts off those clones;
#                            work committed there but NOT landed is single-copy
#                            and is NOT in the archive (the import report says so)
#   .env, *.lock             credentials; transient mutex dirs
#   native runtime memory/   lives outside $DM_HOME (the runtime owns it); back
#                            it up with the rest of your runtime config
#   anything unrecognized    entries under state/, state/tasks/, state/archive/,
#                            and repos/<repo>/.dm/ that the record set does not
#                            name are listed in the manifest and skipped, so a
#                            restore never looks more complete than it is
# Per-repo SHARED knowledge (.dm-knowledge/) is committed to each managed repo,
# so it already travels with git and is deliberately not duplicated here.
#
# NO ROLLBACK on import: files are installed one at a time. A mid-way failure
# leaves the state root partially restored; the error names how many landed.
#
# CONSISTENCY - per-file, not point-in-time. Every record file is copied while
# holding the same advisory lock its writers take (dm-lib's mkdir mutex), so no
# file in the archive is a torn mid-write copy. The archive is NOT an atomic
# snapshot: files are copied one at a time, so a write that lands between two
# copies appears in one and not the other. Append-only status logs and
# write-once artifacts are copied without a lock.
#
# SECRETS - the archive is exactly as sensitive as state/ itself: it carries the
# dockmaster-only memory store (repos/<repo>/.dm/private.md, which exists
# precisely so it is never relayed), operator preferences, and, with
# --with-artifacts, briefs and scout reports. Exporting moves that content past
# the machine boundary it was written under - treat the archive as a secret,
# store it encrypted, and see docs/architecture.md. It is written mode 0600.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need tar; dm_need jq

DM_STATE_FORMAT='dockmaster-state/1'
SHA_CMD=''
TAB="$(printf '\t')"

# Single owner of the scratch dir every command stages through. Script-scoped
# (not `local`) so the EXIT trap can still see it after the command returns, and
# armed once here so a dm_lock subshell's own trap can never displace it.
STAGE=''
cleanup_stage() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; }
trap cleanup_stage EXIT

make_stage() {
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dm-state-$1.XXXXXX")" || dm_die "mktemp failed"
}

resolve_sha_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then SHA_CMD=sha256sum
  elif command -v shasum >/dev/null 2>&1; then SHA_CMD=shasum
  else dm_die "no sha256 tool found (need sha256sum or shasum)"; fi
}

sha_of() {
  case "$SHA_CMD" in
    sha256sum) sha256sum "$1" | awk '{print $1}' ;;
    shasum)    shasum -a 256 "$1" | awk '{print $1}' ;;
    *) dm_die "sha tool not resolved (internal)" ;;
  esac
}

file_bytes() { wc -c < "$1" | tr -d ' '; }

# --- the record set ----------------------------------------------------------
# Explicit allowlist, not a sweep: a file only enters the archive if it is named
# here, so a future file dropped into state/ is reported as unrecognized rather
# than silently exported. Prints "<lock|plain>\t<path relative to DM_HOME>".
# 'lock' files have concurrent toolbelt writers; 'plain' files are append-only
# event logs, archived (write-once) records, or narrative files with no writer.
list_records() {
  local f d name
  for f in repos.json backlog.json secondmates.json operator.md learnings.md; do
    if [ -f "$DM_STATE/$f" ]; then printf 'lock\tstate/%s\n' "$f"; fi
  done
  if [ -f "$DM_STATE/backlog.md" ]; then printf 'plain\tstate/backlog.md\n'; fi
  for f in "$DM_TASKS"/*.meta; do
    if [ -f "$f" ]; then printf 'lock\tstate/tasks/%s\n' "$(basename "$f")"; fi
  done
  for f in "$DM_TASKS"/*.status; do
    if [ -f "$f" ]; then printf 'plain\tstate/tasks/%s\n' "$(basename "$f")"; fi
  done
  for f in "$DM_STATE"/archive/*.meta "$DM_STATE"/archive/*.status; do
    if [ -f "$f" ]; then printf 'plain\tstate/archive/%s\n' "$(basename "$f")"; fi
  done
  # Glob, not a two-name list: a memory store added later must be carried, not
  # silently dropped from every backup.
  for d in "$DM_REPOS"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    for f in "$d.dm"/*.md; do
      if [ -f "$f" ]; then printf 'lock\trepos/%s/.dm/%s\n' "$name" "$(basename "$f")"; fi
    done
  done
}

# Entries the record set does not carry and that are not deliberately excluded.
# Scans one level INTO the dirs that hold records, so the first future record
# type added under state/tasks/ shows up as unrecognized instead of going
# silently missing from every backup. Dot-entries are skipped: no record is a
# dotfile (ids forbid a leading dot) and the only dot-entries there are the
# toolbelt's transient mktemp temps.
list_unrecognized() {
  local e n d name
  for e in "$DM_STATE"/*; do
    [ -e "$e" ] || continue
    n="$(basename "$e")"
    case "$n" in
      repos.json|backlog.json|backlog.md|secondmates.json|operator.md|learnings.md) continue ;;
      tasks|archive|worktrees) continue ;;
      *.lock|*.lock.reclaim) continue ;;
    esac
    printf 'state/%s\n' "$n"
  done
  for e in "$DM_TASKS"/*; do
    [ -e "$e" ] || continue
    n="$(basename "$e")"
    case "$n" in *.meta|*.status|*.lock|*.lock.reclaim) continue ;; esac
    printf 'state/tasks/%s\n' "$n"
  done
  for e in "$DM_STATE"/archive/*; do
    [ -e "$e" ] || continue
    n="$(basename "$e")"
    case "$n" in *.meta|*.status|*.lock|*.lock.reclaim) continue ;; esac
    # A per-task dir is the archived artifact dir: known, carried only with
    # --with-artifacts, never "unrecognized".
    if [ -d "$e" ]; then continue; fi
    printf 'state/archive/%s\n' "$n"
  done
  for d in "$DM_REPOS"/*/; do
    [ -d "$d.dm" ] || continue
    name="$(basename "$d")"
    for e in "$d.dm"/*; do
      [ -e "$e" ] || continue
      n="$(basename "$e")"
      case "$n" in *.md|*.lock|*.lock.reclaim) continue ;; esac
      printf 'repos/%s/.dm/%s\n' "$name" "$n"
    done
  done
}

# --- export ------------------------------------------------------------------
# Copy one record file into the staging payload. A 'lock' copy runs in a
# SUBSHELL: dm_lock owns the EXIT trap, and dm_unlock clears it, which would
# otherwise destroy this script's own staging-cleanup trap.
stage_record() {
  local cls="$1" rel="$2" stage="$3" src dst
  src="$DM_HOME/$rel"; dst="$stage/payload/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ "$cls" = lock ]; then
    ( dm_lock "$src"; cp -p "$src" "$dst" || { dm_unlock "$src"; exit 1; }; dm_unlock "$src" ) \
      || dm_die "failed copying $rel"
    return 0
  fi
  cp -p "$src" "$dst" || dm_die "failed copying $rel"
}

stage_artifacts() {
  local stage="$1" d name
  if [ -d "$DM_DATA" ]; then
    mkdir -p "$stage/payload/data"
    cp -R "$DM_DATA/." "$stage/payload/data/" || dm_die "failed copying data/"
  fi
  for d in "$DM_STATE"/archive/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    mkdir -p "$stage/payload/state/archive/$name"
    cp -R "$d." "$stage/payload/state/archive/$name/" || dm_die "failed copying state/archive/$name"
  done
}

# "<sha256>\t<bytes>\t<relpath>" for every staged file. A tab or newline in a
# path would corrupt this stream, so both fail the export loudly.
payload_index() {
  local payload="$1" f rel sha bytes
  find "$payload" -type f | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$payload"/}"
    case "$rel" in *"$TAB"*) dm_die "unsupported tab in path: $rel" ;; esac
    sha="$(sha_of "$f")"
    [ -n "$sha" ] || dm_die "checksum failed for $rel"
    bytes="$(file_bytes "$f")"
    printf '%s\t%s\t%s\n' "$sha" "$bytes" "$rel"
  done
}

write_manifest() {
  local stage="$1" artifacts="$2" index omitted
  index="$(payload_index "$stage/payload")"
  omitted="$(list_unrecognized)"
  jq -n --arg format "$DM_STATE_FORMAT" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg source_home "$DM_HOME" \
        --arg artifacts "$artifacts" \
        --arg index "$index" \
        --arg omitted "$omitted" '
    def lines: split("\n") | map(select(length > 0));
    { format: $format, created: $created, source_home: $source_home,
      with_artifacts: ($artifacts == "1"),
      omitted_unrecognized: ($omitted | lines),
      files: ($index | lines | map(split("\t") | {sha256: .[0], bytes: (.[1] | tonumber), path: .[2]})) }
  ' > "$stage/manifest.json" || dm_die "failed writing manifest"
}

# Only the default archive name is gitignored, so an --out inside the checkout
# can be committed by accident - and the archive holds private memory.
warn_if_output_inside_home() {
  local dir
  dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" \
    || dm_die "output directory does not exist: $(dirname "$1")"
  case "$dir/" in
    "$DM_HOME"/*) dm_warn "writing the archive inside the dockmaster checkout ($DM_HOME). It holds private and dockmaster-only memory - move it out, or confirm it is gitignored, before committing anything." ;;
  esac
}

cmd_export() {
  local out='' artifacts=0 stage count bytes
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; [ -n "$out" ] || dm_die "--out needs a path"; shift 2 ;;
      --with-artifacts) artifacts=1; shift ;;
      *) dm_die "usage: dm-state.sh export [--out FILE] [--with-artifacts]" ;;
    esac
  done
  [ -d "$DM_STATE" ] || dm_die "no state directory at $DM_STATE; nothing to export"
  [ -n "$out" ] || out="./dockmaster-state-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  if [ -e "$out" ]; then dm_die "refusing to overwrite existing file: $out"; fi
  warn_if_output_inside_home "$out"
  resolve_sha_cmd
  make_stage export; stage="$STAGE"
  mkdir -p "$stage/payload"
  export_payload "$stage" "$artifacts"
  write_manifest "$stage" "$artifacts"
  ( umask 077; tar -czf "$out" -C "$stage" . ) || dm_die "failed writing archive $out"
  chmod 600 "$out" || dm_die "failed restricting mode on $out"
  count="$(jq -r '.files | length' "$stage/manifest.json")"
  bytes="$(jq -r '[.files[].bytes] | add // 0' "$stage/manifest.json")"
  dm_info "exported $count files ($bytes bytes of state) -> $out"
  export_summary "$stage" "$artifacts"
}

export_payload() {
  local stage="$1" artifacts="$2" cls rel
  while IFS="$TAB" read -r cls rel; do
    [ -n "$rel" ] || continue
    stage_record "$cls" "$rel" "$stage"
  done <<EOF
$(list_records)
EOF
  if [ "$artifacts" -eq 1 ]; then stage_artifacts "$stage"; fi
}

export_summary() {
  local stage="$1" artifacts="$2" d wt=0 clones=0
  for d in "$DM_STATE"/worktrees/*/; do
    if [ -d "$d" ]; then wt=$((wt + 1)); fi
  done
  for d in "$DM_REPOS"/*/.git; do
    if [ -e "$d" ]; then clones=$((clones + 1)); fi
  done
  if [ "$artifacts" -eq 1 ]; then
    dm_info "  artifacts: included (data/ and archived task dirs)"
  else
    dm_info "  artifacts: NOT included - re-run with --with-artifacts for briefs, scout reports, review pages"
  fi
  dm_info "  not carried: $clones managed clone(s) under repos/ (re-clonable), $wt local copy/copies under state/worktrees/ (unlanded work in one is NOT in this archive)"
  jq -r '.omitted_unrecognized[]? | "  unrecognized, NOT carried: " + .' "$stage/manifest.json"
  dm_info "  the archive contains private and dockmaster-only memory - treat it as a secret"
}

# --- verify ------------------------------------------------------------------
# An archive path is untrusted input. Reject anything that could escape the
# payload or land inside a managed clone's tracked tree: only state/, data/, and
# the per-repo .dm/ sidecars are installable.
require_safe_relpath() {
  case "$1" in
    ''|/*|*..*) dm_die "refusing unsafe archive path: '$1'" ;;
  esac
  case "$1" in
    state/*|data/*|repos/*/.dm/*) return 0 ;;
    *) dm_die "refusing archive path outside state/, data/, repos/<repo>/.dm/: '$1'" ;;
  esac
}

# The manifest must describe the payload EXACTLY: same SET of paths, no
# duplicates. Comparing counts instead would let one duplicated entry inflate the
# total and smuggle exactly one unlisted, never-checksummed file past verify.
require_manifest_matches_payload() {
  local stage="$1" listed actual rel extra missing
  listed="$(jq -r '.files[].path' "$stage/manifest.json" | LC_ALL=C sort)"
  [ -n "$listed" ] || dm_die "archive contains no files"
  [ "$listed" = "$(printf '%s\n' "$listed" | LC_ALL=C uniq)" ] \
    || dm_die "manifest lists a duplicate path (corrupt or tampered)"
  while IFS= read -r rel; do require_safe_relpath "$rel"; done <<EOF
$listed
EOF
  actual="$(cd "$stage/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  [ "$listed" = "$actual" ] || {
    extra="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual") | tr '\n' ' ')"
    missing="$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual") | tr '\n' ' ')"
    dm_die "archive payload does not match its manifest (corrupt or tampered); unlisted: ${extra:-none}| missing: ${missing:-none}"
  }
}

# Extract into <stage> and prove the payload matches the manifest exactly:
# known format, safe paths, regular files only, matching checksums, and no
# unlisted payload file.
verify_archive() {
  local stage="$1" archive="$2" fmt sha rel got
  # Extraction precedes validation, so it leans on tar refusing absolute and
  # `..` member paths (GNU tar and bsdtar both do); everything installed later
  # comes from the verified manifest list, never from whatever tar wrote.
  tar -xzf "$archive" -C "$stage" || dm_die "failed extracting $archive"
  [ -f "$stage/manifest.json" ] || dm_die "not a dockmaster state archive (no manifest.json)"
  jq -e . "$stage/manifest.json" >/dev/null 2>&1 || dm_die "manifest.json is not valid JSON"
  fmt="$(jq -r '.format // empty' "$stage/manifest.json")"
  [ "$fmt" = "$DM_STATE_FORMAT" ] || dm_die "unsupported archive format '$fmt' (expected $DM_STATE_FORMAT)"
  [ -d "$stage/payload" ] || dm_die "archive has a manifest but no payload directory"
  # A symlink member is invisible to the path-set comparison (`find -type f`
  # skips it) and must never be installed, so refuse any non-regular member.
  [ -z "$(find "$stage/payload" ! -type f ! -type d)" ] \
    || dm_die "archive payload holds a symlink or other non-regular file; refusing"
  require_manifest_matches_payload "$stage"
  while IFS="$TAB" read -r sha rel; do
    [ -n "$rel" ] || continue
    got="$(sha_of "$stage/payload/$rel")"
    [ "$got" = "$sha" ] || dm_die "checksum mismatch for $rel (archive is corrupt or tampered)"
  done <<EOF
$(jq -r '.files[] | "\(.sha256)\t\(.path)"' "$stage/manifest.json")
EOF
}

cmd_verify() {
  local archive="${1:-}" stage
  [ -n "$archive" ] || dm_die "usage: dm-state.sh verify <archive.tar.gz>"
  [ -f "$archive" ] || dm_die "no such archive: $archive"
  resolve_sha_cmd
  make_stage verify; stage="$STAGE"
  verify_archive "$stage" "$archive"
  jq -r '"ok: \(.files|length) files, format \(.format), taken \(.created) from \(.source_home)"
         + (if .with_artifacts then "\n  artifacts: included" else "\n  artifacts: not included" end)
         + (if (.omitted_unrecognized|length) > 0
            then "\n  unrecognized, not carried: " + (.omitted_unrecognized|join(", ")) else "" end)' \
    "$stage/manifest.json"
}

# --- import ------------------------------------------------------------------
import_conflicts() {
  local payload="$1" f rel
  find "$payload" -type f | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$payload"/}"
    if [ -e "$DM_HOME/$rel" ]; then printf '%s\n' "$rel"; fi
  done
}

# Installs from the VERIFIED manifest list, never from whatever the payload dir
# happens to hold. There is no rollback: a mid-way failure leaves the state root
# partially restored, so say exactly how far it got.
install_payload() {
  local stage="$1" rel total done_n=0
  total="$(jq -r '.files | length' "$stage/manifest.json")"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    require_safe_relpath "$rel"
    mkdir -p "$(dirname "$DM_HOME/$rel")" || install_failed "$rel" "$done_n" "$total"
    cp -p "$stage/payload/$rel" "$DM_HOME/$rel" || install_failed "$rel" "$done_n" "$total"
    done_n=$((done_n + 1))
  done <<EOF
$(jq -r '.files[].path' "$stage/manifest.json")
EOF
  [ "$done_n" = "$total" ] || dm_die "installed $done_n of $total file(s) (internal)"
}

install_failed() {
  dm_die "failed installing '$1' after $2 of $3 file(s). $DM_HOME is now PARTIALLY restored and there is no rollback: fix the cause, then re-run with --force (a plain retry hits the populated-root refusal)."
}

# Everything the archive could not carry, as a to-do list. A restore that looks
# complete and is not is worse than one that refuses, so this always prints.
report_reestablish() {
  local stage="$1" name remote branch id wt missing_wt=0
  dm_info ""
  dm_info "re-establish (not carried by the archive):"
  while IFS="$TAB" read -r name remote branch; do
    [ -n "$name" ] || continue
    if [ -d "$DM_REPOS/$name/.git" ]; then continue; fi
    # `git clone` refuses a non-empty target and the restored .dm/ sidecar is
    # already there, so seed the clone in place instead of cloning over it.
    dm_info "  clone missing for '$name':"
    dm_info "    git init -q -b ${branch:-main} repos/$name && git -C repos/$name remote add origin $remote \\"
    dm_info "      && git -C repos/$name fetch origin && git -C repos/$name checkout ${branch:-main} \\"
    dm_info "      && bin/dm-memory.sh seed $name"
  done <<EOF
$(jq -r '.repos // {} | to_entries[] | "\(.key)\t\(.value.remote // "")\t\(.value.default_branch // "")"' "$DM_REGISTRY" 2>/dev/null || true)
EOF
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    wt="$(dm_meta_get "$id" worktree)"
    [ -n "$wt" ] || continue
    if [ -d "$wt" ]; then continue; fi
    missing_wt=$((missing_wt + 1))
  done <<EOF
$(dm_all_task_ids)
EOF
  if [ "$missing_wt" -gt 0 ]; then
    dm_info "  $missing_wt task(s) record a local copy that is not on this machine (the recorded path is absolute, from the exporting machine). Work committed there but never landed was NOT in the archive and cannot be restored from it; recover it from the task's branch on the remote, or re-do it."
  fi
  jq -e '.with_artifacts' "$stage/manifest.json" >/dev/null \
    || dm_info "  briefs, scout reports, and review pages under data/ were not in this archive (exported without --with-artifacts)"
  jq -r '.omitted_unrecognized[]? | "  not carried (unrecognized at export): " + .' "$stage/manifest.json"
  dm_info "  run bin/dm-doctor.sh to confirm the restored state is readable"
}

cmd_import() {
  local archive='' force=0 stage conflicts n
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) dm_die "usage: dm-state.sh import <archive.tar.gz> [--force]" ;;
      *) [ -z "$archive" ] || dm_die "usage: dm-state.sh import <archive.tar.gz> [--force]"
         archive="$1"; shift ;;
    esac
  done
  [ -n "$archive" ] || dm_die "usage: dm-state.sh import <archive.tar.gz> [--force]"
  [ -f "$archive" ] || dm_die "no such archive: $archive"
  resolve_sha_cmd
  make_stage import; stage="$STAGE"
  verify_archive "$stage" "$archive"
  conflicts="$(import_conflicts "$stage/payload")"
  if [ -n "$conflicts" ] && [ "$force" -eq 0 ]; then
    n="$(printf '%s\n' "$conflicts" | wc -l | tr -d ' ')"
    dm_warn "refusing to overwrite $n existing file(s) in $DM_HOME:"
    # sed, not `head`: `head` closing the pipe early SIGPIPEs the producer,
    # which pipefail then reports as a failure.
    printf '%s\n' "$conflicts" | sed -n '1,20s/^/  /p' >&2
    if [ "$n" -gt 20 ]; then printf '  ... and %s more (first 20 shown)\n' "$((n - 20))" >&2; fi
    dm_die "state root is populated; re-run with --force to replace those $n file(s) (import never deletes files the archive does not carry)"
  fi
  dm_ensure_dirs
  install_payload "$stage"
  dm_info "imported $(jq -r '.files | length' "$stage/manifest.json") files into $DM_HOME"
  report_reestablish "$stage"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  export) cmd_export "$@" ;;
  verify) cmd_verify "$@" ;;
  import) cmd_import "$@" ;;
  *)
    cat >&2 <<'USAGE'
usage: dm-state.sh <command>

  export [--out FILE] [--with-artifacts]   archive the record set (default:
                                           ./dockmaster-state-<UTC>.tar.gz;
                                           --with-artifacts adds data/ and
                                           archived task dirs)
  verify FILE                              check format and checksums only
  import FILE [--force]                    restore into $DM_HOME; refuses to
                                           replace existing files without --force

The archive carries private and dockmaster-only memory. Treat it as a secret.
USAGE
    exit 2
    ;;
esac

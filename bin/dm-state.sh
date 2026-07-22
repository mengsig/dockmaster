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
#   import FILE [--force] [--overwrite-newer] [--dry-run]
#                                            restore into THIS checkout ($DM_HOME)
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
#   symlinks, non-regular    verify refuses a non-regular payload member, so one
#                            is skipped at EXPORT and named in the manifest's
#                            omitted_non_regular (npm/playwright leave symlinks
#                            under data/). Skipped, never dereferenced:
#                            following one pulls in out-of-tree content and can
#                            hang on a cycle
# Per-repo SHARED knowledge (.dm-knowledge/) is committed to each managed repo,
# so it already travels with git and is deliberately not duplicated here.
#
# EXPORT VERIFIES ITSELF: the written archive is re-read through the same checks
# import runs before export reports success, and is deleted if it fails them. An
# archive tool must never report success for an archive it would itself reject.
#
# IMPORT SAFETY: a populated state root needs --force. On top of that, a local
# file NEWER than the archive's copy (written after the export) needs
# --overwrite-newer, because replacing it discards state the archive predates.
# Every replaced file is copied to state/backups/pre-import-<UTC>/ first, and
# --dry-run reports the whole plan without writing. Import never DELETES a file
# the archive does not carry, so a wholesale-replaced repos.json can still
# orphan on-disk data it no longer references - --dry-run first if unsure.
#
# NO ROLLBACK on import: files are installed one at a time. A mid-way failure
# leaves the state root partially restored; the error names how many landed
# and where their pre-import copies are.
#
# CONSISTENCY - per-file, not point-in-time. Every record file is copied while
# holding the same advisory lock its writers take (dm-lib's mkdir mutex), so no
# file in the archive is a torn mid-write copy. The archive is NOT an atomic
# snapshot: files are copied one at a time, so a write that lands between two
# copies appears in one and not the other. Append-only status logs and
# write-once artifacts are copied without a lock.
#
# SECRETS - the archive is OPERATOR-PRIVATE and must not be shared. It carries
# the dockmaster-only memory store (repos/<repo>/.dm/private.md, which exists
# precisely so it is never relayed), operator preferences, and, with
# --with-artifacts, briefs and scout reports. It also DISCLOSES THE EXPORTING
# MACHINE'S LAYOUT: manifest.source_home and task-meta worktree paths are
# absolute. Both are deliberate - a restore needs them - but they make the
# archive unfit to hand to anyone. Exporting moves that content past the machine
# boundary it was written under - treat the archive as a secret, store it
# encrypted, and see docs/architecture.md. It is written mode 0600.

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
cleanup_stage() {
  [ -n "$STAGE" ] || return 0
  # A hostile archive can extract a mode-0644 dir; without u+x `rm -rf` fails and
  # leaks the payload into TMPDIR. Best-effort repair; rm's own failure stays loud.
  chmod -R u+rwX "$STAGE" 2>/dev/null || true
  rm -rf "$STAGE"
}
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

# Regular files ONLY. `find -P` (the default) does not follow symlinks, so
# -type f both skips them and never descends a symlinked dir - no cycle to hang
# on, and no out-of-tree content pulled in by dereferencing.
copy_regular_tree() {
  local src="$1" dst="$2" f rel
  find "$src" -type f | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$src"/}"
    mkdir -p "$dst/$(dirname "$rel")" || dm_die "failed staging directory for $rel"
    cp -p "$f" "$dst/$rel" || dm_die "failed copying $rel"
  done
}

# Non-regular artifact members - npm/playwright leave symlinks under data/.
# verify refuses them, so export must skip them AND name them; otherwise the
# tool writes an archive its own verify rejects. Paths are archive-relative.
list_non_regular_artifacts() {
  local d name f
  if [ -d "$DM_DATA" ]; then
    find "$DM_DATA" ! -type f ! -type d | LC_ALL=C sort | while IFS= read -r f; do
      printf 'data/%s\n' "${f#"$DM_DATA"/}"
    done
  fi
  for d in "$DM_STATE"/archive/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    find "$d" ! -type f ! -type d | LC_ALL=C sort | while IFS= read -r f; do
      printf 'state/archive/%s/%s\n' "$name" "${f#"$d"}"
    done
  done
}

stage_artifacts() {
  local stage="$1" d name
  if [ -d "$DM_DATA" ]; then
    copy_regular_tree "$DM_DATA" "$stage/payload/data"
  fi
  for d in "$DM_STATE"/archive/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    copy_regular_tree "${d%/}" "$stage/payload/state/archive/$name"
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

# The file index goes in on STDIN, never as --arg: Linux caps a SINGLE argv
# string at 128K (MAX_ARG_STRLEN), well under total ARG_MAX, and a real
# --with-artifacts export blows past it - jq then dies "Argument list too long"
# and no archive is written at all. Remaining --args are small and bounded.
write_manifest() {
  local stage="$1" artifacts="$2" omitted nonreg=''
  omitted="$(list_unrecognized)"
  if [ "$artifacts" -eq 1 ]; then nonreg="$(list_non_regular_artifacts)"; fi
  payload_index "$stage/payload" \
    | jq -R -s --arg format "$DM_STATE_FORMAT" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg source_home "$DM_HOME" \
        --arg artifacts "$artifacts" \
        --arg omitted "$omitted" \
        --arg nonreg "$nonreg" '
    def lines: split("\n") | map(select(length > 0));
    { format: $format, created: $created, source_home: $source_home,
      with_artifacts: ($artifacts == "1"),
      omitted_unrecognized: ($omitted | lines),
      omitted_non_regular: ($nonreg | lines),
      files: (lines | map(split("\t") | {sha256: .[0], bytes: (.[1] | tonumber), path: .[2]})) }
  ' > "$stage/manifest.json" || dm_die "failed writing manifest"
}

# Only the default archive name is gitignored, so an --out inside the checkout
# can be committed by accident - and the archive holds private memory.
warn_if_output_inside_home() {
  local dir home
  dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" \
    || dm_die "output directory does not exist: $(dirname "$1")"
  # Resolve BOTH sides: `pwd -P` expands symlinks, and on macOS /var -> /private/var
  # makes an unresolved $DM_HOME never match its own resolved subdirectory.
  home="$(cd "$DM_HOME" 2>/dev/null && pwd -P)" || return 0
  case "$dir/" in
    "$home"/*) dm_warn "writing the archive inside the dockmaster checkout ($DM_HOME). It holds private and dockmaster-only memory - move it out, or confirm it is gitignored, before committing anything." ;;
  esac
}

# Export's postcondition: an archive tool must never report success for an
# archive it would itself reject. Re-reads the written file through the very
# checks import runs (verify_archive is defined below, resolved at call time).
assert_archive_verifies() {
  local out="$1" stage="$2"
  mkdir -p "$stage/selfcheck" || dm_die "failed staging self-check directory"
  ( verify_archive "$stage/selfcheck" "$out" >/dev/null ) && return 0
  rm -f "$out"
  dm_die "export produced an archive that fails its own verification (see the error above); removed $out rather than leave an unrestorable backup"
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
  assert_archive_verifies "$out" "$stage"
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
  jq -r '.omitted_non_regular[]? | "  symlink/non-regular, NOT carried: " + .' "$stage/manifest.json"
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
count_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

# Print a refusal list at most 20 entries long, then how many more there were.
print_capped() {
  local list="$1" n
  n="$(count_lines "$list")"
  # sed, not `head`: `head` closing the pipe early SIGPIPEs the producer, which
  # pipefail then reports as a failure.
  printf '%s\n' "$list" | sed -n '1,20s/^/  /p' >&2
  if [ "$n" -gt 20 ]; then printf '  ... and %s more (first 20 shown)\n' "$((n - 20))" >&2; fi
}

import_conflicts() {
  local payload="$1" f rel
  find "$payload" -type f | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$payload"/}"
    if [ -e "$DM_HOME/$rel" ]; then printf '%s\n' "$rel"; fi
  done
}

# Conflicts whose LOCAL copy is newer than the archive's. `cp -p` preserves
# mtime at export, so the staged payload carries the source file's export-time
# mtime - a local file newer than it was written after this archive was taken,
# and replacing it silently discards that work. Reads the verified manifest,
# not the payload dir. Same-second edits are invisible (mtime granularity).
import_newer_conflicts() {
  local stage="$1" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -e "$DM_HOME/$rel" ] || continue
    if [ "$DM_HOME/$rel" -nt "$stage/payload/$rel" ]; then printf '%s\n' "$rel"; fi
  done <<EOF
$(jq -r '.files[].path' "$stage/manifest.json")
EOF
}

# The two import gates: a populated root needs --force, and staler-archive-over-
# newer-local needs --overwrite-newer on top. Refuses; never mutates.
require_import_allowed() {
  local conflicts="$1" newer="$2" force="$3" overwrite_newer="$4" n
  if [ -n "$conflicts" ] && [ "$force" -eq 0 ]; then
    n="$(count_lines "$conflicts")"
    dm_warn "refusing to overwrite $n existing file(s) in $DM_HOME:"
    print_capped "$conflicts"
    if [ -n "$newer" ]; then
      printf '  %s of those are NEWER locally than the archive copy\n' "$(count_lines "$newer")" >&2
    fi
    dm_die "state root is populated; re-run with --force to replace those $n file(s), or --dry-run to inspect first (import never deletes files the archive does not carry)"
  fi
  [ -n "$newer" ] || return 0
  [ "$overwrite_newer" -eq 0 ] || return 0
  n="$(count_lines "$newer")"
  dm_warn "refusing: $n local file(s) are NEWER than this archive's copy, so the archive is stale for them and --force would discard the newer state:"
  print_capped "$newer"
  dm_die "re-run with --force --overwrite-newer to replace them anyway (every replaced file is backed up under state/backups/ first), or --dry-run to inspect"
}

import_dry_run_report() {
  local stage="$1" conflicts="$2" newer="$3"
  dm_info "dry run: nothing was written to $DM_HOME"
  dm_info "  would install $(jq -r '.files | length' "$stage/manifest.json") file(s)"
  if [ -n "$conflicts" ]; then
    dm_info "  would replace $(count_lines "$conflicts") existing file(s) (needs --force; each backed up under state/backups/ first)"
    printf '%s\n' "$conflicts" | sed -n '1,20s/^/    /p'
  else
    dm_info "  would replace nothing (state root is clean for these paths)"
  fi
  if [ -n "$newer" ]; then
    dm_info "  of those, $(count_lines "$newer") are NEWER locally than the archive copy (needs --overwrite-newer):"
    printf '%s\n' "$newer" | sed -n '1,20s/^/    /p'
  fi
  report_reestablish "$stage"
}

# Installs from the VERIFIED manifest list, never from whatever the payload dir
# happens to hold. There is no rollback: a mid-way failure leaves the state root
# partially restored, so say exactly how far it got.
install_payload() {
  local stage="$1" backup_dir="$2" rel total done_n=0
  total="$(jq -r '.files | length' "$stage/manifest.json")"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    require_safe_relpath "$rel"
    # Back up BEFORE overwriting, and abort if the backup fails - a failed
    # backup must never be followed by the destructive copy.
    if [ -n "$backup_dir" ] && [ -e "$DM_HOME/$rel" ]; then
      mkdir -p "$backup_dir/$(dirname "$rel")" || install_failed "$rel" "$done_n" "$total" "$backup_dir"
      cp -p "$DM_HOME/$rel" "$backup_dir/$rel" || install_failed "$rel" "$done_n" "$total" "$backup_dir"
    fi
    mkdir -p "$(dirname "$DM_HOME/$rel")" || install_failed "$rel" "$done_n" "$total" "$backup_dir"
    cp -p "$stage/payload/$rel" "$DM_HOME/$rel" || install_failed "$rel" "$done_n" "$total" "$backup_dir"
    done_n=$((done_n + 1))
  done <<EOF
$(jq -r '.files[].path' "$stage/manifest.json")
EOF
  [ "$done_n" = "$total" ] || dm_die "installed $done_n of $total file(s) (internal)"
}

install_failed() {
  local where=''
  if [ -n "${4:-}" ]; then where=" Files replaced before the failure are in $4."; fi
  dm_die "failed installing '$1' after $2 of $3 file(s). $DM_HOME is now PARTIALLY restored and there is no rollback: fix the cause, then re-run with --force (a plain retry hits the populated-root refusal).$where"
}

# The restored registry drives the clone-reestablish list. It was installed
# byte-for-byte, so it can legitimately be the corrupt file the operator backed
# up to recover from (#112). Three states, matching dm-lib's registry contract:
# missing/empty is a first-run registry (nothing to list); a parseable one is
# enumerated; anything else is NAMED, never silently reported as zero clones -
# a restore that looks complete and is not is worse than one that says so. Not
# a die: the import already installed the file faithfully, so the report stays
# honest and finishes rather than turning a good restore into a failure.
report_missing_clones() {
  local name remote branch repos_tsv
  [ -s "$DM_REGISTRY" ] || return 0
  if ! repos_tsv="$(jq -r '.repos | to_entries[] | "\(.key)\t\(.value.remote // "")\t\(.value.default_branch // "")"' "$DM_REGISTRY" 2>&1)"; then
    dm_info "  the restored registry ($DM_REGISTRY) does NOT parse - its repos cannot be listed here. It was restored exactly as archived (backing up a corrupt registry to recover from is legitimate); run bin/dm-doctor.sh, then repair or restore it before re-establishing any clone."
    return 0
  fi
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
$repos_tsv
EOF
}

# Everything the archive could not carry, as a to-do list. A restore that looks
# complete and is not is worse than one that refuses, so this always prints.
report_reestablish() {
  local stage="$1" id wt missing_wt=0
  dm_info ""
  dm_info "re-establish (not carried by the archive):"
  report_missing_clones
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
  jq -r '.omitted_non_regular[]? | "  not carried (symlink/non-regular at export): " + .' "$stage/manifest.json"
  dm_info "  run bin/dm-doctor.sh to confirm the restored state is readable"
}

IMPORT_USAGE='usage: dm-state.sh import <archive.tar.gz> [--force] [--overwrite-newer] [--dry-run]'

cmd_import() {
  local archive='' force=0 overwrite_newer=0 dry_run=0 stage conflicts newer backup_dir=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --overwrite-newer) overwrite_newer=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -*) dm_die "$IMPORT_USAGE" ;;
      *) [ -z "$archive" ] || dm_die "$IMPORT_USAGE"
         archive="$1"; shift ;;
    esac
  done
  [ -n "$archive" ] || dm_die "$IMPORT_USAGE"
  [ -f "$archive" ] || dm_die "no such archive: $archive"
  resolve_sha_cmd
  make_stage import; stage="$STAGE"
  verify_archive "$stage" "$archive"
  conflicts="$(import_conflicts "$stage/payload")"
  newer="$(import_newer_conflicts "$stage")"
  if [ "$dry_run" -eq 1 ]; then import_dry_run_report "$stage" "$conflicts" "$newer"; return 0; fi
  require_import_allowed "$conflicts" "$newer" "$force" "$overwrite_newer"
  dm_ensure_dirs
  if [ -n "$conflicts" ]; then
    # mktemp, not a bare timestamp: two imports in the same second would share a
    # directory and the second would overwrite the first's only copy.
    mkdir -p "$DM_STATE/backups" || dm_die "failed creating $DM_STATE/backups"
    backup_dir="$(mktemp -d "$DM_STATE/backups/pre-import-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" \
      || dm_die "failed creating a backup directory under $DM_STATE/backups"
  fi
  install_payload "$stage" "$backup_dir"
  dm_info "imported $(jq -r '.files | length' "$stage/manifest.json") files into $DM_HOME"
  if [ -n "$backup_dir" ]; then
    dm_info "  replaced $(count_lines "$conflicts") file(s); the previous copies are in $backup_dir"
  fi
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
  import FILE [--force] [--overwrite-newer] [--dry-run]
                                           restore into $DM_HOME; refuses to
                                           replace existing files without
                                           --force, and refuses to replace a
                                           file newer than the archive's copy
                                           without --overwrite-newer. Replaced
                                           files are backed up under
                                           state/backups/ first. --dry-run
                                           reports and writes nothing.

The archive is OPERATOR-PRIVATE: it carries private and dockmaster-only memory,
and its manifest and task records disclose the exporting machine's absolute
paths. Treat it as a secret and do not share it.
USAGE
    exit 2
    ;;
esac

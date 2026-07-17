#!/usr/bin/env bash
# mh-sync.sh - refresh managed clones by FAST-FORWARD ONLY.
#
# Safe automation for touching many repos unattended: only move a clone if the
# move is provably lossless (a fast-forward on the default branch). Every unsafe
# condition is reported as STUCK and left completely untouched - never merged,
# rebased, reset, or forced.
#
# Commands:
#   one <name>     sync a single registered repo
#   all            sync every registered repo
#
# Exit is always 0; unsafe repos are reported on stdout as "STUCK: ..." lines.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_need git; mh_need jq
mh_ensure_dirs

sync_one() {
  local name="$1" dir def cur
  dir="$MH_HOME/$(mh_registry_get "$name" path)"
  [ -d "$dir/.git" ] || { echo "SKIP: $name (no clone)"; return 0; }
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    echo "SKIP: $name (no origin remote)"; return 0
  fi
  if mh_tracked_dirty "$dir"; then
    echo "STUCK: $name has uncommitted changes to tracked files; left untouched"; return 0
  fi
  def="$(mh_default_branch "$dir")"
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  if [ "$cur" != "$def" ]; then
    echo "STUCK: $name is on '$cur', not default '$def'; left untouched"; return 0
  fi
  if ! git -C "$dir" fetch --quiet origin "$def" 2>/dev/null; then
    echo "SKIP: $name (fetch failed; offline?)"; return 0
  fi
  local before after
  before="$(git -C "$dir" rev-parse --short "$def")"
  if git -C "$dir" merge-base --is-ancestor "origin/$def" "$def" 2>/dev/null; then
    echo "OK: $name already up to date ($before)"; return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor "$def" "origin/$def" 2>/dev/null; then
    echo "STUCK: $name has diverged from origin/$def; left untouched"; return 0
  fi
  git -C "$dir" merge --ff-only "origin/$def" >/dev/null 2>&1 || { echo "STUCK: $name ff merge failed; left untouched"; return 0; }
  after="$(git -C "$dir" rev-parse --short "$def")"
  echo "OK: $name fast-forwarded $before -> $after"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  one) name="${1:-}"; [ -n "$name" ] || mh_die "usage: mh-sync.sh one <name>"; sync_one "$name" ;;
  all)
    mapfile -t names < <(jq -r '.repos | keys[]' "$MH_REGISTRY" 2>/dev/null || true)
    [ "${#names[@]}" -eq 0 ] && { echo "no repos registered"; exit 0; }
    for n in "${names[@]}"; do sync_one "$n"; done
    ;;
  *) echo "usage: mh-sync.sh {one <name>|all}" >&2; exit 2 ;;
esac

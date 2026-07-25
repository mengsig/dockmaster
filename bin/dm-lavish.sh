#!/usr/bin/env bash
# dm-lavish.sh - standard location and wrappers for a task's lavish review surface.
#
# A crewmate renders its change into a reviewable HTML artifact; the operator
# reviews and annotates it in the browser; feedback returns through lavish-axi.
# The artifact lives under data/<id>/lavish/ in the dockmaster home (NOT in the
# worktree) so it survives teardown and never dirties the worktree.
#
# Commands:
#   list [--json]      every task with a rendered artifact, newest first
#   path <id>          print (and create the dir for) the artifact path
#   open <id>          open/resume the lavish session for the artifact
#   poll <id>          long-poll for operator feedback (caller owns wake delivery)
#   end  <id>          end the lavish session
#
# lavish-axi is an OPTIONAL review tool: it drives the interactive browser
# surface. The artifact (change.html) is written by the crewmate regardless, so
# the review can still happen by opening the HTML directly and giving feedback in
# chat. When lavish-axi is absent, open/poll/end DEGRADE (print a fallback and
# exit 0) rather than collapsing the whole review gate. A missing artifact is a
# genuine error and still fails, tool present or not.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs

# stat_number <fmt-bsd> <fmt-gnu> <file> - one numeric stat field, BSD spelling
# first then GNU (the order tests/smoke.sh's file_mode helper uses). GNU `stat -f`
# rejects the BSD format but still PRINTS filesystem info for the file operand,
# so that attempt is captured and discarded unless it exits 0. Anything
# non-numeric prints nothing, so a caller can tell unknown from a real value.
stat_number() {
  local out
  out="$(stat -f "$1" "$3" 2>/dev/null)" || out="$(stat -c "$2" "$3" 2>/dev/null)" || return 0
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$out"
}

# epoch_iso <epoch> - a unix timestamp as UTC ISO-8601. BSD `date -r <epoch>`
# first, then GNU `date -d @<epoch>`. An unreadable mtime prints nothing rather
# than a fabricated timestamp.
epoch_iso() {
  [ -n "$1" ] || return 0
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

# `list` takes no <id>, so it is answered before the id requirement below.
if [ "${1:-}" = "list" ]; then
  json=0
  case "${2:-}" in
    "") ;;
    --json) json=1 ;;
    *) echo "usage: dm-lavish.sh list [--json]" >&2; exit 2 ;;
  esac
  [ "$json" -eq 0 ] || dm_need jq
  # The glob owns the same data/<id>/lavish/change.html layout `path <id>`
  # composes, so discovery and creation cannot drift. Key each hit by mtime so
  # the whole set can be sorted newest-first before anything is formatted.
  keyed=""
  for f in "$DM_DATA"/*/lavish/change.html; do
    [ -f "$f" ] || continue
    d="${f%/lavish/change.html}"
    keyed="$keyed$(stat_number %m %Y "$f")	${d##*/}"$'\n'
  done
  rows=""
  # -t<TAB>: an unreadable mtime leaves field 1 EMPTY, and the default separator
  # would then read the id as field 1 and sort by it.
  while IFS=$'\t' read -r epoch lid; do
    [ -n "$lid" ] || continue
    lf="$DM_DATA/$lid/lavish/change.html"
    if [ "$json" -eq 1 ]; then
      # 0 only when stat itself failed on a file we just confirmed exists.
      bytes="$(stat_number %z %s "$lf")"
      rows="$rows$(jq -c -n --arg id "$lid" --arg path "$lf" \
        --arg rendered_at "$(epoch_iso "$epoch")" --argjson bytes "${bytes:-0}" \
        '{id:$id,path:$path,rendered_at:$rendered_at,bytes:$bytes}')"$'\n'
    else
      rows="$rows$lid	$(epoch_iso "$epoch")	$lf"$'\n'
    fi
  done <<EOF
$(printf '%s' "$keyed" | sort -t$'\t' -k1,1nr)
EOF
  if [ "$json" -eq 1 ]; then printf '%s' "$rows" | jq -c -s '.'; else printf '%s' "$rows"; fi
  exit 0
fi

id="${2:-}"; [ -n "$id" ] || { echo "usage: dm-lavish.sh {list|path|open|poll|end} <id>" >&2; exit 2; }
dm_require_id "$id"
dir="$DM_DATA/$id/lavish"
file="$dir/change.html"

have_lavish() { command -v lavish-axi >/dev/null 2>&1; }

case "${1:-}" in
  path) mkdir -p "$dir"; printf '%s\n' "$file" ;;
  open)
    [ -f "$file" ] || dm_die "no artifact at $file (the crewmate writes it first)"
    if have_lavish; then
      lavish-axi "$file"
    else
      dm_warn "lavish-axi not installed; the interactive review surface is unavailable."
      dm_info "Open the review artifact directly in a browser: $file"
      dm_info "Give feedback in chat; the dockmaster relays it to the worker."
    fi
    ;;
  poll)
    [ -f "$file" ] || dm_die "no artifact at $file"
    if have_lavish; then
      lavish-axi poll "$file"
    else
      dm_warn "lavish-axi not installed; live feedback polling is unavailable."
      dm_info "Feedback should come directly in chat rather than through the lavish surface."
    fi
    ;;
  end)  if have_lavish; then lavish-axi end "$file" 2>/dev/null || true; fi ;;
  *)    echo "usage: dm-lavish.sh {list|path|open|poll|end} <id>" >&2; exit 2 ;;
esac

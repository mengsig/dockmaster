#!/usr/bin/env bash
# dm-lavish.sh - standard location and wrappers for a task's lavish review surface.
#
# A crewmate renders its change into a reviewable HTML artifact; the operator
# reviews and annotates it in the browser; feedback returns through lavish-axi.
# The artifact lives under data/<id>/lavish/ in the dockmaster home (NOT in the
# worktree) so it survives teardown and never dirties the worktree.
#
# Commands:
#   path <id>          print (and create the dir for) the artifact path
#   open <id>          reserve/open a review and print its epoch
#   poll <id> <epoch>  long-poll for feedback from that exact session
#   end  <id> <epoch>  end that exact session
#
# lavish-axi is an OPTIONAL review tool: it drives the interactive browser
# surface. The artifact (change.html) is written by the crewmate regardless, so
# the review can still happen by opening the HTML directly and giving feedback in
# chat. A missing tool creates an explicit manual session; poll fails closed and
# end still closes that epoch. Tool-backed open/end failures remain guarded.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs

id="${2:-}"; [ -n "$id" ] || { echo "usage: dm-lavish.sh {path|open|poll|end} <id> [epoch]" >&2; exit 2; }
dm_require_id "$id"
dir="$DM_DATA/$id/lavish"
file="$dir/change.html"

have_lavish() { command -v lavish-axi >/dev/null 2>&1; }
next_session_generation() {
  case "${1:-}" in ''|*[!0-9]*) printf '1\n' ;; *) printf '%s\n' "$(( $1 + 1 ))" ;; esac
}
session_cas_locked() {
  local expected="$1" epoch="$2"
  [ "$(dm_meta_get "$id" review_session_state)" = "$expected" ] \
    && [ "$(dm_meta_get "$id" review_session_epoch)" = "$epoch" ]
}

case "${1:-}" in
  path) mkdir -p "$dir"; printf '%s\n' "$file" ;;
  open)
    [ -f "$file" ] || dm_die "no artifact at $file (the crewmate writes it first)"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    dm_task_terminal_locked "$id" && dm_die "task '$id' is terminal; refusing a new review session"
    old_state="$(dm_meta_get "$id" review_session_state)"
    case "$old_state" in ''|terminal) ;; *) dm_die "task '$id' already has review session state '$old_state'" ;; esac
    epoch="$(next_session_generation "$(dm_meta_get "$id" review_session_generation)")"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mode=manual
    have_lavish && mode=tool
    dm_task_transition_locked "$id" review-ready "review session opening (epoch $epoch, $mode)" \
      review_session_state opening review_session_started_at "$started_at" \
      review_session_generation "$epoch" review_session_epoch "$epoch" review_session_mode "$mode"
    dm_unlock "$meta"
    if [ "$mode" = tool ]; then
      if ! lavish-axi "$file"; then
        dm_lock "$meta"
        current_state="$(dm_meta_get "$id" review_session_state)"
        current_epoch="$(dm_meta_get "$id" review_session_epoch)"
        if [ "$current_epoch" = "$epoch" ] && { [ "$current_state" = opening ] || [ "$current_state" = closing ]; }; then
          dm_task_transition_locked "$id" working "review open failed; epoch $epoch closed" \
            review_session_state terminal review_session_started_at "" review_session_epoch "" review_session_mode ""
        fi
        dm_unlock "$meta"
        dm_die "lavish-axi failed opening the review; opening reservation cleared"
      fi
      dm_lock "$meta"
      current_state="$(dm_meta_get "$id" review_session_state)"
      current_epoch="$(dm_meta_get "$id" review_session_epoch)"
      if [ "$current_epoch" != "$epoch" ]; then
        dm_unlock "$meta"
        lavish-axi end "$file" >/dev/null 2>&1 || true
        dm_die "review epoch changed while opening; stale open refused"
      fi
      case "$current_state" in
        opening)
          dm_task_transition_locked "$id" review-ready "review session active (epoch $epoch)" \
            review_session_state active
          dm_unlock "$meta"
          ;;
        closing)
          dm_unlock "$meta"
          lavish-axi end "$file" \
            || dm_die "review was closed during open, but lavish-axi end failed; session remains guarded"
          dm_lock "$meta"
          session_cas_locked closing "$epoch" \
            || { dm_unlock "$meta"; dm_die "review epoch changed while closing a slow open"; }
          dm_task_transition_locked "$id" working "review session terminal (epoch $epoch)" \
            review_session_state terminal review_session_started_at "" review_session_epoch "" review_session_mode ""
          dm_unlock "$meta"
          ;;
        *) dm_unlock "$meta"; dm_die "review state changed to '$current_state' while opening" ;;
      esac
    else
      dm_lock "$meta"
      session_cas_locked opening "$epoch" \
        || { dm_unlock "$meta"; dm_die "review state changed while opening manual fallback"; }
      dm_task_transition_locked "$id" review-ready "manual review session active (epoch $epoch)" \
        review_session_state active-manual
      dm_unlock "$meta"
      dm_warn "lavish-axi not installed; the interactive review surface is unavailable."
      printf 'Open the review artifact directly in a browser: %s\n' "$file" >&2
      printf 'Give feedback in chat; the dockmaster relays it to the worker.\n' >&2
    fi
    printf '%s\n' "$epoch"
    ;;
  poll)
    epoch="${3:-}"
    [ -n "$epoch" ] || dm_die "usage: dm-lavish.sh poll <id> <epoch>"
    [ -f "$file" ] || dm_die "no artifact at $file"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    session_cas_locked active "$epoch" \
      || { dm_unlock "$meta"; dm_die "no matching active tool-backed review session for '$id' epoch '$epoch'"; }
    dm_unlock "$meta"
    have_lavish || dm_die "lavish-axi unavailable; cannot verify or poll tool-backed review epoch '$epoch'"
    lavish-axi poll "$file"
    ;;
  end)
    epoch="${3:-}"
    [ -n "$epoch" ] || dm_die "usage: dm-lavish.sh end <id> <epoch>"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    current_state="$(dm_meta_get "$id" review_session_state)"
    [ "$(dm_meta_get "$id" review_session_epoch)" = "$epoch" ] \
      || { dm_unlock "$meta"; dm_die "stale review end refused for epoch '$epoch'"; }
    case "$current_state" in
      opening)
        dm_task_transition_locked "$id" review-ready "review close requested during open (epoch $epoch)" \
          review_session_state closing
        dm_unlock "$meta"
        exit 0
        ;;
      active|active-manual)
        mode="$(dm_meta_get "$id" review_session_mode)"
        dm_task_transition_locked "$id" review-ready "review session closing (epoch $epoch)" \
          review_session_state closing
        ;;
      closing) mode="$(dm_meta_get "$id" review_session_mode)" ;;
      *) dm_unlock "$meta"; dm_die "review epoch '$epoch' is not active (state '$current_state')" ;;
    esac
    dm_unlock "$meta"
    if [ "$mode" = tool ]; then
      have_lavish || dm_die "lavish-axi unavailable; tool-backed review remains closing"
      lavish-axi end "$file" \
        || dm_die "lavish-axi failed ending the review; session remains closing"
    fi
    dm_lock "$meta"
    session_cas_locked closing "$epoch" \
      || { dm_unlock "$meta"; dm_die "review epoch changed while ending; stale completion refused"; }
    dm_task_transition_locked "$id" working "review session terminal (epoch $epoch)" \
      review_session_state terminal review_session_started_at "" review_session_epoch "" review_session_mode ""
    dm_unlock "$meta"
    ;;
  *)    echo "usage: dm-lavish.sh {path|open|poll|end} <id> [epoch]" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# dm-lavish.sh - standard location and wrappers for a task's lavish review surface.
#
# A crewmate renders its change into a reviewable HTML artifact; the operator
# reviews and annotates it in the browser; feedback returns through lavish-axi.
# The artifact lives under data/<id>/lavish/ in the dockmaster home (NOT in the
# worktree) so it survives teardown and never dirties the worktree.
#
# Commands:
#   path <id>                         print/create the artifact path
#   prepare <id>                      opt in to guarded Codex review
#   open <id> [--guarded]             legacy open, or guarded open with epoch
#   poll <id> [epoch] [--guarded]     legacy poll, or exact guarded poll
#   end <id> [epoch] [--guarded]      legacy end, or exact guarded end
#   cancel <id> --guarded             cancel a prepared, unopened review
#
# lavish-axi is an OPTIONAL review tool: it drives the interactive browser
# surface. The artifact (change.html) is written by the crewmate regardless, so
# the review can still happen by opening the HTML directly and giving feedback in
# chat. A missing tool creates an explicit manual session; poll fails closed and
# end still closes that epoch. Tool-backed open/end failures remain guarded.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs

id="${2:-}"; [ -n "$id" ] || { echo "usage: dm-lavish.sh {path|prepare|open|poll|end|cancel} <id> [epoch] [--guarded]" >&2; exit 2; }
dm_require_id "$id"
dir="$DM_DATA/$id/lavish"
file="$dir/change.html"

have_lavish() { command -v lavish-axi >/dev/null 2>&1; }
next_session_generation() {
  case "${1:-}" in ''|*[!0-9]*) printf '1\n' ;; *) printf '%s\n' "$(( $1 + 1 ))" ;; esac
}
guarded_flag_present() {
  local arg
  for arg in "$@"; do [ "$arg" = "--guarded" ] && return 0; done
  return 1
}
require_guarded_protocol_locked() {
  local protocol
  protocol="$(dm_meta_get "$id" review_protocol)"
  [ "$protocol" = "$DM_CODEX_REVIEW_PROTOCOL" ] \
    || dm_die "task '$id' review protocol changed or is not guarded Codex"
}
session_cas_locked() {
  local expected="$1" epoch="$2"
  [ "$(dm_meta_get "$id" review_session_state)" = "$expected" ] \
    && [ "$(dm_meta_get "$id" review_session_epoch)" = "$epoch" ]
}
lavish_end_bounded() {
  local pid spins rc
  lavish-axi end "$file" >/dev/null 2>&1 &
  pid=$!
  spins=0
  while kill -0 "$pid" 2>/dev/null && [ "$spins" -lt 50 ]; do
    sleep 0.1
    spins=$((spins + 1))
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    rc=0
    wait "$pid" || rc=$?
    return "$rc"
  fi
  kill -TERM "$pid" 2>/dev/null || true
  spins=0
  while kill -0 "$pid" 2>/dev/null && [ "$spins" -lt 20 ]; do
    sleep 0.1
    spins=$((spins + 1))
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  kill -KILL "$pid" 2>/dev/null || true
  spins=0
  while kill -0 "$pid" 2>/dev/null && [ "$spins" -lt 20 ]; do
    sleep 0.1
    spins=$((spins + 1))
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  dm_warn "lavish-axi end did not terminate after TERM and KILL; cleanup remains uncertain"
  return 125
}
finish_cleanup() {
  local meta="$1" epoch="$2" note="$3"
  dm_lock "$meta"
  session_cas_locked closing "$epoch" || session_cas_locked closing-opening "$epoch" \
    || session_cas_locked cleanup-uncertain "$epoch" \
    || { dm_unlock "$meta"; dm_die "review epoch changed while finalizing cleanup"; }
  dm_task_transition_locked "$id" working "$note" \
    review_session_state terminal review_session_started_at "" review_session_epoch "" review_session_mode ""
  dm_unlock "$meta"
}
retain_cleanup_guard() {
  local meta="$1" epoch="$2" note="$3"
  dm_lock "$meta"
  session_cas_locked closing "$epoch" || session_cas_locked closing-opening "$epoch" \
    || { dm_unlock "$meta"; dm_die "review epoch changed while retaining cleanup guard"; }
  dm_task_transition_locked "$id" review-ready "$note" \
    review_session_state cleanup-uncertain
  dm_unlock "$meta"
}
quarantine_feedback() {
  local epoch="$1" feedback="$2" quarantine
  quarantine="$(mktemp "$dir/stale-feedback.$epoch.XXXXXX")" \
    || dm_die "stale review feedback rejected, but quarantine creation failed"
  chmod 600 "$quarantine"
  printf '%s\n' "$feedback" >"$quarantine"
  printf '%s\n' "$quarantine"
}

# Artifact paths are runtime-neutral and never select a review protocol.
if [ "${1:-}" = "path" ]; then
  [ "$#" -eq 2 ] || { echo "usage: dm-lavish.sh path <id>" >&2; exit 2; }
  mkdir -p "$dir"
  printf '%s\n' "$file"
  exit 0
fi

if [ "${1:-}" = "prepare" ]; then
  [ "$#" -eq 2 ] || dm_die "usage: dm-lavish.sh prepare <id>"
  [ -f "$file" ] || dm_die "no artifact at $file (the crewmate writes it first)"
  meta="$(dm_meta_path "$id")"
  dm_lock "$meta"
  dm_require_complete_task_locked "$id"
  dm_task_terminal_locked "$id" && dm_die "task '$id' is terminal; refusing guarded review preparation"
  [ -z "$(dm_meta_get "$id" approved_at)" ] && [ -z "$(dm_meta_get "$id" pipeline_repo)" ] \
    || dm_die "task '$id' already has delivery approval or binding; guarded review must be prepared first"
  protocol="$(dm_meta_get "$id" review_protocol)"
  old_state="$(dm_meta_get "$id" review_session_state)"
  case "$protocol" in
    "")
      [ -z "$old_state" ] \
        || dm_die "task '$id' has review state '$old_state' without a protocol marker"
      dm_task_transition_locked "$id" review-ready "guarded Codex review prepared" \
        review_protocol "$DM_CODEX_REVIEW_PROTOCOL" review_session_state prepared \
        review_session_started_at "" review_session_epoch "" review_session_mode ""
      ;;
    "$DM_CODEX_REVIEW_PROTOCOL")
      case "$old_state" in
        prepared) ;;
        terminal)
          dm_task_transition_locked "$id" review-ready "guarded Codex review prepared" \
            review_session_state prepared review_session_started_at "" \
            review_session_epoch "" review_session_mode ""
          ;;
        *) dm_die "task '$id' already has guarded review state '${old_state:-missing}'" ;;
      esac
      ;;
    *) dm_die "task '$id' has unknown review protocol '$protocol'" ;;
  esac
  dm_unlock "$meta"
  exit 0
fi

protocol="$(dm_meta_get "$id" review_protocol)"
if [ -z "$protocol" ]; then
  old_state="$(dm_meta_get "$id" review_session_state)"
  [ -z "$old_state" ] \
    || dm_die "task '$id' has review state '$old_state' without a protocol marker; refusing legacy fallback"
  guarded_flag_present "$@" \
    && dm_die "task '$id' is not prepared for guarded Codex review; run dm-lavish.sh prepare $id first"
  # Claude and unmarked callers predate durable review epochs. Preserve their
  # commands and lavish-axi calls exactly; they create no review state.
  case "${1:-}" in
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
    end)
      if have_lavish; then lavish-axi end "$file" 2>/dev/null || true; fi
      ;;
    *) echo "usage: dm-lavish.sh {path|open|poll|end} <id>" >&2; exit 2 ;;
  esac
  exit 0
fi
[ "$protocol" = "$DM_CODEX_REVIEW_PROTOCOL" ] \
  || dm_die "task '$id' has unknown review protocol '$protocol'"

case "${1:-}" in
  open)
    [ "$#" -eq 3 ] && [ "${3:-}" = "--guarded" ] \
      || dm_die "guarded task '$id' requires: dm-lavish.sh open $id --guarded"
    ;;
  poll|end)
    [ "$#" -eq 4 ] && [ "${4:-}" = "--guarded" ] \
      || dm_die "guarded task '$id' requires an exact epoch and --guarded"
    ;;
  cancel)
    [ "$#" -eq 3 ] && [ "${3:-}" = "--guarded" ] \
      || dm_die "guarded task '$id' requires: dm-lavish.sh cancel $id --guarded"
    ;;
  *) echo "usage: dm-lavish.sh {prepare|open|poll|end|cancel} <id> [epoch] --guarded" >&2; exit 2 ;;
esac

case "${1:-}" in
  open)
    [ -f "$file" ] || dm_die "no artifact at $file (the crewmate writes it first)"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    require_guarded_protocol_locked
    dm_task_terminal_locked "$id" && dm_die "task '$id' is terminal; refusing a new review session"
    [ -z "$(dm_meta_get "$id" approved_at)" ] && [ -z "$(dm_meta_get "$id" pipeline_repo)" ] \
      || dm_die "task '$id' already has delivery approval or binding; guarded review is closed"
    old_state="$(dm_meta_get "$id" review_session_state)"
    case "$old_state" in
      prepared|terminal) ;;
      *) dm_die "task '$id' guarded review is not prepared or terminal (state '${old_state:-missing}')" ;;
    esac
    epoch="$(next_session_generation "$(dm_meta_get "$id" review_session_generation)")"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mode=manual
    have_lavish && mode=tool
    dm_task_transition_locked "$id" review-ready "review session opening (epoch $epoch, $mode)" \
      review_session_state opening review_session_started_at "$started_at" \
      review_session_generation "$epoch" review_session_epoch "$epoch" review_session_mode "$mode"
    dm_unlock "$meta"
    if [ "$mode" = tool ]; then
      open_rc=0
      lavish-axi "$file" || open_rc=$?
      if [ "$open_rc" -ne 0 ]; then
        dm_lock "$meta"
        current_state="$(dm_meta_get "$id" review_session_state)"
        current_epoch="$(dm_meta_get "$id" review_session_epoch)"
        if [ "$current_epoch" = "$epoch" ] && [ "$current_state" = opening ]; then
          dm_task_transition_locked "$id" review-ready "review open failed; cleanup required (epoch $epoch)" \
            review_session_state closing
        fi
        dm_unlock "$meta"
        if lavish_end_bounded; then
          finish_cleanup "$meta" "$epoch" "review open failed; external cleanup confirmed (epoch $epoch)"
          dm_die "lavish-axi failed opening the review; external cleanup confirmed"
        fi
        dm_lock "$meta"
        current_state="$(dm_meta_get "$id" review_session_state)"
        dm_unlock "$meta"
        if [ "$current_state" = closing ] || [ "$current_state" = closing-opening ]; then
          retain_cleanup_guard "$meta" "$epoch" "review open failed and external cleanup is uncertain (epoch $epoch)"
        fi
        dm_die "lavish-axi failed opening the review; external cleanup unconfirmed, session remains guarded"
      fi
      dm_lock "$meta"
      current_state="$(dm_meta_get "$id" review_session_state)"
      current_epoch="$(dm_meta_get "$id" review_session_epoch)"
      if [ "$current_epoch" != "$epoch" ]; then
        dm_unlock "$meta"
        lavish_end_bounded \
          || dm_die "review epoch changed while opening; stale open cleanup unconfirmed"
        dm_die "review epoch changed while opening; stale open cleaned and refused"
      fi
      case "$current_state" in
        opening)
          dm_task_transition_locked "$id" review-ready "review session active (epoch $epoch)" \
            review_session_state active
          dm_unlock "$meta"
          ;;
        closing-opening)
          dm_unlock "$meta"
          if ! lavish_end_bounded; then
            dm_lock "$meta"
            session_cas_locked closing-opening "$epoch" \
              || { dm_unlock "$meta"; dm_die "review epoch changed while retaining slow-open cleanup guard"; }
            dm_task_transition_locked "$id" review-ready "slow review open returned; cleanup uncertain (epoch $epoch)" \
              review_session_state cleanup-uncertain
            dm_unlock "$meta"
            dm_die "review was closed during open, but external cleanup is unconfirmed; session remains guarded"
          fi
          dm_lock "$meta"
          session_cas_locked closing-opening "$epoch" \
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
    case "$epoch" in *[!0-9]*) dm_die "review epoch must be numeric" ;; esac
    [ -f "$file" ] || dm_die "no artifact at $file"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    require_guarded_protocol_locked
    session_cas_locked active "$epoch" \
      || { dm_unlock "$meta"; dm_die "no matching active tool-backed review session for '$id' epoch '$epoch'"; }
    dm_unlock "$meta"
    have_lavish || dm_die "lavish-axi unavailable; cannot verify or poll tool-backed review epoch '$epoch'"
    poll_rc=0
    feedback="$(lavish-axi poll "$file")" || poll_rc=$?
    dm_lock "$meta"
    if ! session_cas_locked active "$epoch"; then
      dm_unlock "$meta"
      quarantine="$(quarantine_feedback "$epoch" "$feedback")"
      dm_die "review epoch changed while polling; stale feedback quarantined at $quarantine"
    fi
    dm_unlock "$meta"
    [ "$poll_rc" -eq 0 ] || dm_die "lavish-axi poll failed for active review epoch '$epoch'"
    printf '%s\n' "$feedback"
    ;;
  end)
    epoch="${3:-}"
    [ -n "$epoch" ] || dm_die "usage: dm-lavish.sh end <id> <epoch>"
    case "$epoch" in *[!0-9]*) dm_die "review epoch must be numeric" ;; esac
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    require_guarded_protocol_locked
    current_state="$(dm_meta_get "$id" review_session_state)"
    [ "$(dm_meta_get "$id" review_session_epoch)" = "$epoch" ] \
      || { dm_unlock "$meta"; dm_die "stale review end refused for epoch '$epoch'"; }
    case "$current_state" in
      opening)
        dm_task_transition_locked "$id" review-ready "review close requested during open (epoch $epoch)" \
          review_session_state closing-opening
        mode="$(dm_meta_get "$id" review_session_mode)"
        ;;
      active|active-manual)
        mode="$(dm_meta_get "$id" review_session_mode)"
        dm_task_transition_locked "$id" review-ready "review session closing (epoch $epoch)" \
          review_session_state closing
        ;;
      closing|cleanup-uncertain|closing-opening) mode="$(dm_meta_get "$id" review_session_mode)" ;;
      *) dm_unlock "$meta"; dm_die "review epoch '$epoch' is not active (state '$current_state')" ;;
    esac
    dm_unlock "$meta"
    if [ "$mode" = tool ]; then
      have_lavish || dm_die "lavish-axi unavailable; tool-backed review remains closing"
      if ! lavish_end_bounded; then
        if [ "$current_state" = opening ] || [ "$current_state" = closing-opening ]; then
          dm_die "lavish-axi cleanup during open is unconfirmed; opening guard retained"
        fi
        case "$current_state" in
          active|active-manual|closing)
            retain_cleanup_guard "$meta" "$epoch" "review cleanup uncertain (epoch $epoch)"
            ;;
        esac
        dm_die "lavish-axi failed ending the review; cleanup guard retained"
      fi
    fi
    if [ "$current_state" = opening ] || [ "$current_state" = closing-opening ]; then
      dm_info "review close attempted during open; guard retained until the opening call resolves (epoch $epoch)"
      exit 0
    fi
    finish_cleanup "$meta" "$epoch" "review session terminal (epoch $epoch)"
    ;;
  cancel)
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    require_guarded_protocol_locked
    [ "$(dm_meta_get "$id" review_session_state)" = "prepared" ] \
      && [ -z "$(dm_meta_get "$id" review_session_epoch)" ] \
      || dm_die "only a prepared, unopened guarded review can be cancelled"
    dm_task_transition_locked "$id" working "guarded Codex review preparation cancelled" \
      review_session_state terminal review_session_started_at "" \
      review_session_epoch "" review_session_mode ""
    dm_unlock "$meta"
    ;;
esac

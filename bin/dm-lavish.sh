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
#   open <id>          open/resume and durably mark the review session active
#   poll <id>          long-poll for operator feedback (caller owns wake delivery)
#   end  <id>          end the session, then durably mark it terminal
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

id="${2:-}"; [ -n "$id" ] || { echo "usage: dm-lavish.sh {path|open|poll|end} <id>" >&2; exit 2; }
dm_require_id "$id"
dir="$DM_DATA/$id/lavish"
file="$dir/change.html"

have_lavish() { command -v lavish-axi >/dev/null 2>&1; }

case "${1:-}" in
  path) mkdir -p "$dir"; printf '%s\n' "$file" ;;
  open)
    [ -f "$file" ] || dm_die "no artifact at $file (the crewmate writes it first)"
    if have_lavish; then
      started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      dm_meta_set_fields "$id" review_session_state opening review_session_started_at "$started_at"
      if ! lavish-axi "$file"; then
        dm_meta_set_fields "$id" review_session_state terminal review_session_started_at ""
        dm_die "lavish-axi failed opening the review; opening reservation cleared"
      fi
      dm_meta_set_fields "$id" review_session_state active review_session_started_at "$started_at"
    else
      dm_warn "lavish-axi not installed; the interactive review surface is unavailable."
      dm_info "Open the review artifact directly in a browser: $file"
      dm_info "Give feedback in chat; the dockmaster relays it to the worker."
    fi
    ;;
  poll)
    [ -f "$file" ] || dm_die "no artifact at $file"
    if have_lavish; then
      [ "$(dm_meta_get "$id" review_session_state)" = "active" ] \
        || dm_die "no active Lavish session recorded for '$id'; run dm-lavish.sh open first"
      lavish-axi poll "$file"
    else
      dm_warn "lavish-axi not installed; live feedback polling is unavailable."
      dm_info "Feedback should come directly in chat rather than through the lavish surface."
    fi
    ;;
  end)
    if have_lavish; then
      lavish-axi end "$file" \
        || dm_die "lavish-axi failed ending the review; session remains active"
    fi
    dm_meta_set_fields "$id" review_session_state terminal review_session_started_at ""
    ;;
  *)    echo "usage: dm-lavish.sh {path|open|poll|end} <id>" >&2; exit 2 ;;
esac

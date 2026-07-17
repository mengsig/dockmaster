#!/usr/bin/env bash
# mh-lavish.sh - standard location and wrappers for a task's lavish review surface.
#
# A crewmate renders its change into a reviewable HTML artifact; the operator
# reviews and annotates it in the browser; feedback returns through lavish-axi.
# The artifact lives under data/<id>/lavish/ in the manhandler home (NOT in the
# worktree) so it survives teardown and never dirties the worktree.
#
# Commands:
#   path <id>          print (and create the dir for) the artifact path
#   open <id>          open/resume the lavish session for the artifact
#   poll <id>          long-poll for operator feedback (run as a background task)
#   end  <id>          end the lavish session

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_ensure_dirs

id="${2:-}"; [ -n "$id" ] || { echo "usage: mh-lavish.sh {path|open|poll|end} <id>" >&2; exit 2; }
mh_require_id "$id"
dir="$MH_DATA/$id/lavish"
file="$dir/change.html"

case "${1:-}" in
  path) mkdir -p "$dir"; printf '%s\n' "$file" ;;
  open) mh_need lavish-axi; [ -f "$file" ] || mh_die "no artifact at $file (the crewmate writes it first)"; lavish-axi "$file" ;;
  poll) mh_need lavish-axi; [ -f "$file" ] || mh_die "no artifact at $file"; lavish-axi poll "$file" ;;
  end)  mh_need lavish-axi; lavish-axi end "$file" 2>/dev/null || true ;;
  *)    echo "usage: mh-lavish.sh {path|open|poll|end} <id>" >&2; exit 2 ;;
esac

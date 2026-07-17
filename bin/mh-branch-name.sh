#!/usr/bin/env bash
# mh-branch-name.sh - compute a branch name from a type, an issue, and a summary.
#
# Convention:  <type>/<issue>/<slug>
#   type   one of: feat fix bug chore refactor docs perf test build ci
#   issue  the issue/ticket number, or "x" when there is none
#   slug   a short kebab-case summary (<= 6 words is plenty)
#
# Examples:
#   mh-branch-name.sh fix 412 "flaky login test"      -> fix/412/flaky-login-test
#   mh-branch-name.sh feat x "dark mode toggle"       -> feat/x/dark-mode-toggle
#
# The slug is lowercased, non-alphanumerics collapse to single hyphens, and the
# whole name is capped so it stays a valid, readable git ref.

set -euo pipefail

usage() { echo "usage: mh-branch-name.sh <type> <issue|x> <summary...>" >&2; exit 2; }
[ "$#" -ge 3 ] || usage

type="$1"; issue="$2"; shift 2
summary="$*"

case "$type" in
  feat|fix|bug|chore|refactor|docs|perf|test|build|ci) ;;
  *) echo "error: type must be one of: feat fix bug chore refactor docs perf test build ci (got '$type')" >&2; exit 2 ;;
esac

# issue is a positive integer or the literal "x"
case "$issue" in
  x) ;;
  ''|*[!0-9]*) echo "error: issue must be a number or 'x' (got '$issue')" >&2; exit 2 ;;
esac

slug="$(printf '%s' "$summary" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

# cap slug length to keep the ref readable
slug="${slug:0:48}"
slug="${slug%-}"
[ -n "$slug" ] || slug="change"

printf '%s/%s/%s\n' "$type" "$issue" "$slug"

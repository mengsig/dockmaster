#!/usr/bin/env bash
# mh-test.sh - run a repo's registered test command in a task's worktree.
#
# This is the concrete implementation of the pr-workflow "tests" gate. It runs
# the repo's test_cmd (from the registry) inside the task's worktree, records the
# result in task meta and the status log, and exits non-zero on failure so a
# caller can gate on it.
#
# Usage: mh-test.sh <id>
#   Exit 0 = passed (or a declared soft-skip when no test command is registered).
#   Exit 1 = failed. Exit 2 = usage error.
#
# A soft-skip (no test_cmd) is reported explicitly and never counted as a pass.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_ensure_dirs

id="${1:-}"; [ -n "$id" ] || { echo "usage: mh-test.sh <id>" >&2; exit 2; }
mh_require_id "$id"
wt="$(mh_meta_get "$id" worktree)"; repo="$(mh_meta_get "$id" repo)"
[ -n "$wt" ] && [ -d "$wt" ] || mh_die "no worktree for $id"
cmd="$(mh_registry_get "$repo" test_cmd)"

if [ -z "$cmd" ]; then
  mh_meta_set "$id" tests "skip"
  mh_status_append "$id" working "tests: no test command registered (soft skip, not a pass)"
  echo "SKIP: no test command registered for $repo (register one: mh-repo.sh set $repo test_cmd \"<cmd>\")"
  exit 0
fi

echo "running in $wt: $cmd"
if ( cd "$wt" && eval "$cmd" ); then
  mh_meta_set "$id" tests "pass"
  mh_status_append "$id" working "tests: pass"
  echo "PASS: $cmd"
  exit 0
else
  rc=$?
  mh_meta_set "$id" tests "fail"
  mh_status_append "$id" blocked "tests: FAILED (exit $rc)"
  echo "FAIL: $cmd (exit $rc)" >&2
  exit 1
fi

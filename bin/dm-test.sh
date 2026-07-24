#!/usr/bin/env bash
# dm-test.sh - run a repo's registered test command in a task's worktree.
#
# This is the concrete implementation of the pr-workflow "tests" gate. It runs
# the repo's test_cmd (from the registry) inside the task's worktree, records the
# result in task meta and the status log, and exits non-zero on failure so a
# caller can gate on it.
#
# Usage: dm-test.sh <id>
#   Exit 0 = passed (or a declared soft-skip when no test command is registered).
#   Exit 1 = failed. Exit 2 = usage error.
#
# A soft-skip (no test_cmd) is reported explicitly and never counted as a pass.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# Resolves the repo's test_cmd from the registry; a corrupt one must refuse
# rather than read as "no test command" and soft-skip the gate.
dm_registry_require_valid

id="${1:-}"; [ -n "$id" ] || { echo "usage: dm-test.sh <id>" >&2; exit 2; }
dm_require_id "$id"
wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
cmd="$(dm_registry_get "$repo" test_cmd)"
before="$(dm_task_git_snapshot "$id")"
base_sha="${before%%$'\t'*}"; head_sha="${before#*$'\t'}"

if [ -z "$cmd" ]; then
  dm_meta_set_fields "$id" tests skip tests_base_sha "$base_sha" tests_head_sha "$head_sha"
  dm_status_append "$id" working "tests: no test command registered (soft skip, not a pass)"
  echo "SKIP: no test command registered for $repo (register one: dm-repo.sh set $repo test_cmd \"<cmd>\")"
  exit 0
fi

echo "running in $wt: $cmd"
if ( cd "$wt" && eval "$cmd" ); then
  after="$(dm_task_git_snapshot "$id")"
  if [ "$after" != "$before" ]; then
    dm_meta_set_fields "$id" tests fail tests_base_sha "" tests_head_sha ""
    dm_status_append "$id" blocked "tests: git snapshot changed during the test run"
    echo "FAIL: base/HEAD changed during tests; result is stale" >&2
    exit 1
  fi
  dm_meta_set_fields "$id" tests pass tests_base_sha "$base_sha" tests_head_sha "$head_sha"
  dm_status_append "$id" working "tests: pass"
  echo "PASS: $cmd"
  exit 0
else
  rc=$?
  dm_meta_set_fields "$id" tests fail tests_base_sha "$base_sha" tests_head_sha "$head_sha"
  dm_status_append "$id" blocked "tests: FAILED (exit $rc)"
  echo "FAIL: $cmd (exit $rc)" >&2
  exit 1
fi

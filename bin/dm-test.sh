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
#        dm-test.sh evidence <id>
#   Print this gate's evidence block for the PR body (dm-evidence.sh collects
#   it), or nothing when the gate never ran. It reports the recorded result and
#   never runs a test; it exits non-zero only when the id or registry is
#   unusable, which the collector renders as "evidence unavailable".
#   Two args is what selects it, so a task literally named `evidence` still runs
#   via the one-arg form.
#
# A soft-skip (no test_cmd) is reported explicitly and never counted as a pass —
# and, since #175, it is reported ON THE PR rather than only to a log.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# Resolves the repo's test_cmd from the registry; a corrupt one must refuse
# rather than read as "no test command" and soft-skip the gate.
dm_registry_require_valid

# tests_evidence <id> -- print the block, from what the gate RECORDED. The
# command comes from task meta (what actually ran), falling back to the registry
# for a record written before that was captured; a registry edit since the run
# must not be reported as the command that ran.
tests_evidence() {
  local id="$1" result repo cmd
  result="$(dm_meta_get "$id" tests)"
  [ -n "$result" ] || return 0
  repo="$(dm_meta_get "$id" repo)"
  case "$result" in
    skip)
      printf '**tests** — NOT RUN · no test command is registered for `%s`, so no test executed\n' "$repo"
      return 0 ;;
    pass|fail) : ;;
    *)
      printf '**tests** — evidence unavailable · unrecognized recorded result `%s`\n' "$result"
      return 0 ;;
  esac
  cmd="$(dm_meta_get "$id" tests_cmd)"
  [ -n "$cmd" ] || cmd="$(dm_registry_get "$repo" test_cmd)"
  [ -n "$cmd" ] || cmd="(command not recorded)"
  case "$result" in
    pass) printf '**tests** — pass · `%s`\n' "$cmd" ;;
    fail) printf '**tests** — FAILED · `%s`\n' "$cmd" ;;
  esac
}

if [ "$#" -eq 2 ] && [ "${1:-}" = "evidence" ]; then
  dm_require_id "$2"
  tests_evidence "$2"
  exit 0
fi

id="${1:-}"; [ -n "$id" ] || { echo "usage: dm-test.sh <id> | dm-test.sh evidence <id>" >&2; exit 2; }
dm_require_id "$id"
wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
cmd="$(dm_registry_get "$repo" test_cmd)"

if [ -z "$cmd" ]; then
  dm_meta_set "$id" tests "skip"
  dm_status_append "$id" working "tests: no test command registered (soft skip, not a pass)"
  echo "SKIP: no test command registered for $repo (register one: dm-repo.sh set $repo test_cmd \"<cmd>\")"
  exit 0
fi

echo "running in $wt: $cmd"
# Recorded BEFORE the run so the result and the command that produced it are
# never a mismatched pair, whatever the outcome.
dm_meta_set "$id" tests_cmd "$cmd"
if ( cd "$wt" && eval "$cmd" ); then
  dm_meta_set "$id" tests "pass"
  dm_status_append "$id" working "tests: pass"
  echo "PASS: $cmd"
  exit 0
else
  rc=$?
  dm_meta_set "$id" tests "fail"
  dm_status_append "$id" blocked "tests: FAILED (exit $rc)"
  echo "FAIL: $cmd (exit $rc)" >&2
  exit 1
fi

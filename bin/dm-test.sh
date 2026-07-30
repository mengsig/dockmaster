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
#   it). It reports the recorded result and never runs a test; it exits
#   non-zero only when the id or registry is unusable, which the collector
#   renders as "evidence unavailable".
#   Two args is what selects it, so a task literally named `evidence` still runs
#   via the one-arg form.
#
# A soft-skip (no test_cmd) is reported explicitly and never counted as a pass —
# and, since #175, it is reported ON THE PR rather than only to a log.
#
# Two truthfulness fixes (#185, #188) on top of #175's evidence block:
#   - A recorded `pass` is bound to the code-state fingerprint (dm_code_state,
#     dm-lib.sh — the same one dm-verify.sh pins an app boot to) at the moment
#     the run exited. `evidence` re-derives the CURRENT fingerprint and renders
#     `pass @<sha>` only while they still match; once the code has moved (a
#     later commit, an edit) it renders STALE instead — never a plain pass over
#     code nothing tested.
#   - When the gate has no record at all, silence used to be the whole answer,
#     indistinguishable from a docs-only PR that legitimately never needed one.
#     `evidence` now asks dm-verify.sh's `gate_decision` (via its documented
#     `--json` machine contract) whether this task's diff is docs-only; if not,
#     it renders an explicit "the tests gate was never invoked" line. Silence
#     survives only for the genuinely docs-only case.

set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$BIN_DIR/dm-lib.sh"
dm_ensure_dirs
# Resolves the repo's test_cmd from the registry; a corrupt one must refuse
# rather than read as "no test command" and soft-skip the gate.
dm_registry_require_valid

# tests_gate_decision <id> -- dm-verify.sh's `gate_decision` verdict for this
# task's diff (required|not-applicable|undetermined|unavailable), read through
# its documented `--json` contract for machine callers, which always exits 0
# and carries the answer in `.decision` — exit code alone cannot be trusted
# here (dm-verify.sh's own `gate` overloads exit 1 between "not-applicable" and
# an unrelated die). Falls back to "undetermined" if dm-verify.sh cannot be
# asked at all: this gate fails toward REPORTING a possible never-ran, never
# toward the silence #188 exists to close.
tests_gate_decision() {
  local id="$1" verify_bin json
  verify_bin="$BIN_DIR/dm-verify.sh"
  [ -x "$verify_bin" ] || { printf 'undetermined\n'; return 0; }
  json="$("$verify_bin" gate "$id" --json 2>/dev/null)" || { printf 'undetermined\n'; return 0; }
  printf '%s' "$json" | jq -r '.decision // "undetermined"' 2>/dev/null || printf 'undetermined\n'
}

# tests_never_ran_line <id> -- the #188 fix: report a gate that never ran,
# rather than staying silent. Silence survives only for a genuinely docs-only
# diff, using dm-verify.sh's `gate_decision` as the single owner of that call
# (the same decision `verify (e2e)` evidence is built on) rather than a second
# docs-vs-code classifier.
tests_never_ran_line() {
  local id="$1" decision
  decision="$(tests_gate_decision "$id")"
  [ "$decision" = "not-applicable" ] && return 0
  printf '**tests** — NOT RUN · the tests gate was never invoked for this task\n'
}

# tests_evidence <id> -- print the block, from what the gate RECORDED. The
# command comes from task meta (what actually ran), falling back to the registry
# for a record written before that was captured; a registry edit since the run
# must not be reported as the command that ran.
tests_evidence() {
  local id="$1" result repo cmd head wt now at
  result="$(dm_meta_get "$id" tests)"
  if [ -z "$result" ]; then
    tests_never_ran_line "$id"
    return 0
  fi
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
  if [ "$result" = fail ]; then
    printf '**tests** — FAILED · `%s`\n' "$cmd"
    return 0
  fi
  # result = pass: never render it plain unless the fingerprint recorded at run
  # time still matches the worktree RIGHT NOW (#185). A pass with no fingerprint
  # (a record from before this pin existed) and a pass whose worktree cannot be
  # re-read both count as unconfirmed, same as a genuinely moved HEAD — none of
  # them may read as a plain pass.
  head="$(dm_meta_get "$id" tests_head)"
  wt="$(dm_meta_get "$id" worktree)"
  now=""
  [ -n "$wt" ] && { now="$(dm_code_state "$wt" 2>/dev/null)" || now=""; }
  if [ -n "$head" ] && [ -n "$now" ] && [ "$now" = "$head" ]; then
    printf '**tests** — pass @%s · `%s`\n' "${head%%/*}" "$cmd"
  else
    at="an earlier, unpinned state"; [ -n "$head" ] && at="${head%%/*}"
    printf '**tests** — STALE · `%s` recorded a pass at %s, but the code under test cannot be reconfirmed as what is on the branch now — re-run the tests gate\n' \
      "$cmd" "$at"
  fi
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
rc=0
( cd "$wt" && eval "$cmd" ) || rc=$?
# Fingerprint the code AS TESTED, at the moment the command exited — win or
# lose, so evidence rendered later can tell this result apart from a PR that
# has since moved (#185). A fingerprint failure must not mask the test result:
# it just leaves `tests_head` unset, which evidence treats as unconfirmed.
fp="$(dm_code_state "$wt" 2>/dev/null)" || fp=""
if [ "$rc" -eq 0 ]; then
  dm_meta_set "$id" tests "pass"
  [ -n "$fp" ] && dm_meta_set "$id" tests_head "$fp"
  dm_status_append "$id" working "tests: pass"
  echo "PASS: $cmd"
  exit 0
else
  dm_meta_set "$id" tests "fail"
  [ -n "$fp" ] && dm_meta_set "$id" tests_head "$fp"
  dm_status_append "$id" blocked "tests: FAILED (exit $rc)"
  echo "FAIL: $cmd (exit $rc)" >&2
  exit 1
fi

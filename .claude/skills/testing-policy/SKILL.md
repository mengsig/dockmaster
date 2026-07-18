---
name: testing-policy
description: What the tests gate means when a repo has no registered test command, and how to handle a flaky test — never a fabricated pass, never a weakened test. Load before relying on the tests gate for a repo with no test command, or when a test is flaky.
---

# testing-policy

The tests gate (`bin/dm-test.sh <id>`) is only as strong as what it can run. Two
situations where it cannot simply return green, and what to do instead.

## No registered test command

A repo with no `test_cmd` makes the gate a **declared soft skip**, never a
fabricated pass — `dm-test` and `pr-workflow` already state this. A soft skip is
not verification, so do not report the change as tested on the strength of it.
Instead, load the `verify` skill and drive the change end-to-end, then report
**what was actually exercised** (the flow you ran, what you observed). Honest
"verified manually by X" beats a hollow "tests passed."

## A flaky test

1. Re-run a **bounded** number of times (a small fixed cap, not unbounded).
2. If it passes on retry, record it as **flaky** — do not treat an intermittent
   failure as green, and note it so it is not mistaken for a solid pass.
3. **Never delete or weaken a test to go green.** That violates the commandments
   (do not weaken a valid test to make it pass) and hides a real signal.
4. Surface **persistent** flakiness to the operator — a test that fails
   unpredictably is a defect to decide on, not a gate to route around.

## Turning a bug into coverage

A reproduced bug becomes a regression test (as `task-lifecycle` says) — add the
failing case, confirm it fails before the fix and passes after.

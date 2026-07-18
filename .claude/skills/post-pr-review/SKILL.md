---
name: post-pr-review
description: The tail of the PR pipeline after the PR is open — handle review comments and post-open CI failures on the same branch until reviewers are satisfied and checks are green. Load when an open PR gets review comments, or its CI goes red after it was opened.
---

# post-pr-review

`pr-workflow` ends at PR creation. This is what happens next, while the PR is
open: reviewers comment and CI runs. The change is not delivered until the PR is
approved and green — keep iterating on the **same branch** (the PR auto-updates
on push). Never merge red.

## Fetch what changed

- **Review comments** — `gh-axi pr view <n> --comments` for the human-readable
  thread. If you must parse fields (comment ids, paths, resolved state), use
  `gh api` — `gh-axi`'s wrapper output is for humans, not JSON.
- **CI status** — `bin/dm-pr.sh check <id>` for the recorded checks state.

## Triage

Sort each comment into one of:
- **Actionable** — a concrete change request. Fix it.
- **Discussion / question** — answer it (relay the reviewer's point; the operator
  or the implementing crewmate replies), no code change.
- **Operator decision** — a request that changes scope, contract, or risk beyond
  the task. Escalate to the operator; do not decide it silently.

## Loop until green and satisfied

1. Relay each actionable item to the implementing crewmate as one clear
   instruction, on the **same branch** (do not open a second branch or task).
2. The crewmate fixes, commits, and the branch pushes — the PR updates itself.
3. Re-run the tests gate (`bin/dm-test.sh <id>`) and re-check the PR
   (`bin/dm-pr.sh check <id>`).
4. Repeat until reviewers are satisfied and checks are green.

Then the merge gate in `pr-workflow` applies as before: never merge red, respect
the repo's `merge_authority` (`never` is operator-merge-only), and merge only on
the operator's word — or, under a standing `yolo`, for LOW/MEDIUM-risk green work
(a HIGH-risk change always needs the explicit word; risk tiers in `pr-workflow`).

## Rules

- Same branch, same task, same crewmate — this is a continuation, not new work.
- A post-open CI failure is treated like any red gate: fix and re-run, never
  merge around it.
- Escalate only comments that require a decision the operator owns.

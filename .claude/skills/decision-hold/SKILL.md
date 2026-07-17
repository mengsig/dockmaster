---
name: decision-hold
description: Track an operator-owned decision surfaced during an investigation or review so it cannot evaporate when the task ends. Load before treating an investigation or visual review as complete, and when recording the operator's answer.
---

# decision-hold

An unresolved decision that only the operator can make must not vanish when the
scout that found it finishes or is torn down. Capture it durably first.

## The gate

Before treating any investigation or visual review as complete:

1. Read the complete result and **inventory the genuine unresolved choices**
   that belong to the operator. (You do this semantically — do not expect a
   script to infer decisions from prose.)
2. For each, file a durable, operator-gated backlog item in `state/backlog.md`
   with a stable, privacy-safe key, e.g.:
   ```
   ## Decisions (operator)
   - [ ] <origin-id>-decision-<key>  <the choice, in plain terms>
       options: <A> | <B>
       origin: data/<origin-id>/report.md
   ```
   Filing is idempotent on the key — re-running does not duplicate it.
3. Only then may the originating task be considered complete. A resolved
   finding, a no-choice recommendation, or merely decision-*sounding* prose does
   not create a hold.

## Relay and resolve

- Relay each choice to the operator as a plain decision (evidence, options,
  recommendation). Never use the word "hold" in operator chat.
- When the operator decides, record the exact decision in the item body and any
  dependent work as a new backlog item blocked by nothing further, then close
  the hold (mark it `[x]` with the decision recorded).
- A hold stays open until the answer is durably recorded — tearing down the
  originating task never closes it.

## Why

Scout worktrees are scratch and get discarded. Without this gate, a real
operator decision discovered mid-investigation would be lost with the worktree.
The hold makes "this investigation is done" mean "every decision it surfaced is
either resolved or durably queued."

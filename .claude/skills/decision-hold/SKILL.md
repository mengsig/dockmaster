---
name: decision-hold
description: Track an operator-owned decision surfaced during an investigation or review so it cannot evaporate when the task ends. Load before treating an investigation or visual review as complete, and when recording the operator's answer.
---

# decision-hold

An unresolved decision that only the operator can make must not vanish when the
scout that found it finishes or is torn down. Capture it durably first.

## When a task raises a decision event

The moment a crewmate reconciles to `needs-decision` (or a `blocked`/
`awaiting-review` state that turns on an operator choice), the choice lives only
in the append-only status log — which teardown discards. **Open a backlog hold
that references the task right then**, before you relay or supervise further:

```
bin/mh-backlog.sh hold <id>-decision-<key> "<the choice, in plain terms>" \
  --options "<A> | <B>" --origin data/<id>/report.md
```

`bin/mh-status.sh` flags any task in `blocked`/`needs-decision`/`awaiting-review`
with **no open hold referencing it** (the `UNTRACKED DECISIONS` section) — treat
such a flag as a missing hold to open now, not noise.

## The gate

Before treating any investigation or visual review as complete:

1. Read the complete result and **inventory the genuine unresolved choices**
   that belong to the operator. (You do this semantically — do not expect a
   script to infer decisions from prose.)
2. For each, file a durable, operator-gated hold with a stable, privacy-safe key:
   ```
   bin/mh-backlog.sh hold <origin-id>-decision-<key> "<the choice, in plain terms>" \
     --options "<A> | <B>" --origin data/<origin-id>/report.md
   ```
   Filing is idempotent on the key — re-running updates, never duplicates.
3. Only then may the originating task be considered complete. A resolved
   finding, a no-choice recommendation, or merely decision-*sounding* prose does
   not create a hold.

## Relay and resolve

- Relay each choice to the operator as a plain decision (evidence, options,
  recommendation). Never use the word "hold" in operator chat.
- When the operator decides, record it and, if it unblocks work, queue that work:
  ```
  bin/mh-backlog.sh resolve <origin-id>-decision-<key> "<the operator's exact decision>"
  bin/mh-backlog.sh add <new-id> "<dependent work>" --status queued   # if any
  ```
- A hold stays open until resolved — tearing down the originating task never
  closes it. Verify with `bin/mh-backlog.sh list` before treating the
  investigation as complete.

## Why

Scout worktrees are scratch and get discarded. Without this gate, a real
operator decision discovered mid-investigation would be lost with the worktree.
The hold makes "this investigation is done" mean "every decision it surfaced is
either resolved or durably queued."

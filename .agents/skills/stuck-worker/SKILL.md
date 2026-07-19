---
name: stuck-worker
description: Recover a stalled, looping, confused, or dead crewmate along a cost gradient without ever duplicating a worker or losing its work. Load after a failed task, an unresponsive agent, or a restart that finds unaccounted-for work.
---

# stuck-worker

Recover along a cost gradient. Preserve the work and the task identity. Never
spawn a duplicate crewmate for a task that already has one — a second worktree
splits one task across two copies.

## First: reconcile, don't assume

"The agent is gone" is a presence signal, not proof the work is lost. Start with
`bin/dm-task.sh state <id>`:

- A merged PR or landed work → the task is actually done; finish the paperwork.
- Committed, unlanded work in the worktree → the work survives; recover the
  worker, keep the worktree.
- Nothing produced → safe to re-dispatch cleanly.

## Live but stuck — the ladder

1. **Look** — use `list_agents`, then `send_message` to the running agent.
2. **Answer** — if it is waiting on something already in its brief, send one
   short line that unblocks it.
3. **Correct** — use `send_message` for a live turn or `followup_task` for an
   idle thread. (Low
   remaining context is not "stuck" — agents compact; give it a moment.)
4. **Relaunch** — if it is genuinely wedged (repeating the same obstacle,
   unresponsive, or dead), `interrupt_agent` that specific thread and relaunch
   the **same task** with the
   **same brief plus a progress note**, pointed at the **same worktree**. The
   worktree and its commits persist, so relaunch is cheap.
5. **Escalate** — if a second relaunch also fails, mark the task failed, tell the
   operator the plain outcome, and report exactly what work is preserved and
   where.

## Continuing an already-completed or terminated worker

Not every case is a wedged live agent — a common one is picking up a worker
that already finished (one more fix, a review comment to address). `send_message`
to a finished worker can fail with "no transcript": its thread is gone once the
agent terminates, which is not evidence the work is stuck. Recover it the same
way as step 4 above — relaunch with `spawn_agent` in the **same worktree**, same
task id, same brief plus a short progress note. Never a new worktree, never
`--force`: either risks a split-brain duplicate or loses the worker's prior
commits.

## Dead endpoint after a restart

Before relaunching anything:

- Read the persisted `agent_id` and `thread_name`, then inspect `list_agents`.
  An exact id or exactly one exact-name match is still the owner; persist any
  recovered id and reattach. Multiple exact-name matches are ambiguous and
  block recovery. Only zero matches proves there is no live owner.
- Preserve uncommitted changes and commits; keep the same task id.
- Relaunch in the **same worktree** with the same brief and a progress note;
  reuse the deterministic `bin/dm-thread-name.sh <id> worker` label and persist
  the new returned id immediately.

If ownership cannot be reconciled safely, leave the state exactly as it is and
report `blocked`/`failed` with evidence — do not risk a split-brain duplicate.

## Rules

- Never `--force` a teardown to "clean up" a stuck task's worktree unless the
  operator explicitly authorized discarding that work.
- Never broadly kill subagents; interrupt the specific one by id.
- A refusal from any `dm-*` script during recovery is a signal to stop and
  investigate, not to work around.

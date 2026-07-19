---
name: supervision
description: How the dockmaster supervises in-flight crew work using Codex collaboration threads, mailbox waits, yielded commands, and scheduled tasks without a polling daemon. Load whenever work is in flight.
---

# supervision

Codex collaboration threads are the worker backend. Use their mailbox and
control tools; do not build a watcher daemon or burn turns on status polling.

## The model

A crewmate is a **Codex subagent thread**. `spawn_agent` returns immediately.
Completion is delivered to the parent mailbox; `wait_agent` blocks efficiently
until a mailbox update or steered user input rather than polling task files.

1. **Dispatch** a crewmate with `spawn_agent(..., fork_turns="none")`; record its id.
2. **Resume** the conversation and dispatch other independent work. Do not block.
3. **On a mailbox completion**, reconcile and act:
   - `bin/dm-task.sh state <id>` for authoritative current state.
   - Read the crewmate's status events (`state/tasks/<id>.status`) as a log of
     *what happened*, never as current truth.
   - Advance the pipeline, report an outcome, or handle a blocker/decision.

## Events vs current state

A status line is a **wake event**, not current state. Always reconcile with
`bin/dm-task.sh state <id>` before re-escalating an old blocker or decision — the
task may have moved on. The state reconciler keys off real signals (merged PR,
merge event, report existence, committed-unlanded worktree), not the last line.

Handle events by kind:
- **done / ready** — advance delivery (run the next gate, or land after approval).
- **blocked** — the crewmate needs *you* to act; do exactly what it names. If the
  blocker is an operator choice, treat it as **needs-decision** below.
- **needs-decision** — an operator choice. Open a durable backlog hold that
  references the task *first* (load `decision-hold`), then decide only under
  standing authority, otherwise escalate to the operator. The hold must exist
  before teardown or the choice is lost — `bin/dm-status.sh` flags a
  `blocked`/`needs-decision`/`awaiting-review` task that has none.
- **failed** — load `stuck-worker`; preserve work, never duplicate the crewmate.
- **paused** — a bounded external wait expected to clear on its own; leave it,
  but re-check if it has been quiet unusually long.

## External waits

For state changes with no completion notification — CI turning green, an external
deploy, a remote queue — do not busy-wait:

- **Active-session wait** — run `bin/dm-pr.sh await-checks <id>
  [--timeout-secs N] [--interval-secs N]` through the command tool. If it yields
  a running session, resume that session with the runtime wait/write tool. The
  script polls until the rollup is terminal (`passing`/`failing`/`none`) or it
  times out, exiting 0 on passing/none and non-zero on failing/timeout.
- **Long or recurring wait** — use a Codex scheduled task or thread automation
  in the desktop/web surface for a periodic check-in or fleet sweep. Codex CLI
  has no Scheduled management UI; in CLI-only operation, keep an active bounded
  `await-checks` command or ask the operator to schedule the prepared prompt.

## Fleet PR sweep

`bin/dm-pr.sh sweep` walks every task with an OPEN PR and reports, one line each,
its CI rollup and whether a review requests changes — read-only, merges nothing.
An open PR gets no collaboration completion when its CI later goes red or a
reviewer requests changes, so run the sweep on a cadence (a `schedule`/`loop`
"babysit the PRs" wakeup) or read it mid-session — `bin/dm-status.sh` folds the
same sweep into its snapshot. Escalate to the operator only the PRs needing a
decision: red CI or an unaddressed review (changes requested); load
`post-pr-review` to drive them. A green PR with no review action is supervised
silently.

## Checking up and reporting

- "Check up on it" — `list_agents` / `bin/dm-task.sh state <id>`, or
  `send_message` to a running agent. Use `followup_task` to trigger a new turn on
  an idle worker.
- "Report back" — surface outcomes, not mechanics (see AGENTS.md §Reporting):
  the PR with its full URL, the finding, the blocker, the decision. Never relay
  raw status lines, task ids, or worktree paths into operator chat.
- Waiting on a healthy in-flight task is silent. Empty polls and unchanged state
  are not progress worth reporting.

## Session death / restart recovery

Supervision state lives on disk, not in this conversation. On restart,
`dm-session-start` reconciles it. For each in-flight task whose agent is gone but
whose worktree still holds unlanded work, load `stuck-worker`: re-attach by
`agent_id` if the thread is still addressable, else prove no live owner remains
before re-dispatching the same task into the same worktree. Never spawn a
duplicate — a second worktree splits one task across two copies.

## Discipline

- One dispatch, one crewmate, one worktree. Do not spawn a second crewmate for a
  task that already has a live one.
- Never end a turn having *started* work you then forget. Use `wait_agent` while
  the goal remains active; durable task state is still the source of truth if
  the session restarts. Keep the backlog current on dispatch, completion, and
  decision.

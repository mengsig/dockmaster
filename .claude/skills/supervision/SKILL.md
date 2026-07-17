---
name: supervision
description: How the manhandler supervises in-flight crew work using Claude Code native primitives — background agents, task-completion notifications, Monitor, and scheduled wakeups — at zero idle token cost. Load whenever work is in flight.
---

# supervision

firstmate needed a bash watcher daemon, a wake queue, and turn-end guard hooks
to fake asynchronous supervision on generic harnesses. Claude Code gives it to
us natively. Use the primitive; do not rebuild the daemon.

## The model

A crewmate is a **background agent**. Spawning it returns immediately and costs
nothing while it runs. When it finishes, Claude Code delivers a
`<task-notification>` — that *is* the wake. There is no polling.

1. **Dispatch** a crewmate with `Agent(..., run in background)`; record its id.
2. **Resume** the conversation and dispatch other independent work. Do not block.
3. **On the completion notification**, reconcile and act:
   - `bin/mh-task.sh state <id>` for authoritative current state.
   - Read the crewmate's status events (`state/tasks/<id>.status`) as a log of
     *what happened*, never as current truth.
   - Advance the pipeline, report an outcome, or handle a blocker/decision.

## Events vs current state

A status line is a **wake event**, not current state. Always reconcile with
`bin/mh-task.sh state <id>` before re-escalating an old blocker or decision — the
task may have moved on. The state reconciler keys off real signals (merged PR,
merge event, report existence, committed-unlanded worktree), not the last line.

Handle events by kind:
- **done / ready** — advance delivery (run the next gate, or land after approval).
- **blocked** — the crewmate needs *you* to act; do exactly what it names.
- **needs-decision** — an operator choice; decide only under standing authority,
  otherwise escalate to the operator (load `decision-hold` if it must persist).
- **failed** — load `stuck-worker`; preserve work, never duplicate the crewmate.
- **paused** — a bounded external wait expected to clear on its own; leave it,
  but re-check if it has been quiet unusually long.

## Waits Claude Code cannot notify on

For state changes with no completion notification — CI turning green, an external
deploy, a remote queue — do not busy-wait:

- **Monitor** — poll an until-condition (e.g. `bin/mh-pr.sh check <id>` reporting
  `checks: passing`). Size the interval to how fast the state actually changes
  (a ~8-minute CI run wants one ~480s check, not eight 60s ones). For the common
  wait-for-CI case, `bin/mh-pr.sh await-checks <id> [--timeout-secs N]
  [--interval-secs N]` is the packaged form of this loop: it polls `check` until
  the rollup is terminal (`passing`/`failing`/`none`) or it times out, exiting 0
  on passing/none and non-zero on failing/timeout.
- **ScheduleWakeup / CronCreate** — schedule a periodic check-in for very
  long-running or recurring supervision, or a routine "babysit the PRs" sweep.

## Checking up and reporting

- "Check up on it" — `TaskList` / `bin/mh-task.sh state <id>`, or `SendMessage`
  to a still-running agent.
- "Report back" — surface outcomes, not mechanics (see AGENTS.md §Reporting):
  the PR with its full URL, the finding, the blocker, the decision. Never relay
  raw status lines, task ids, or worktree paths into operator chat.
- Waiting on a healthy in-flight task is silent. Empty polls and unchanged state
  are not progress worth reporting.

## Session death / restart recovery

Supervision state lives on disk, not in this conversation. On restart,
`mh-session-start` reconciles it. For each in-flight task whose agent is gone but
whose worktree still holds unlanded work, load `stuck-worker`: re-attach by
`agent_id` if the agent is resumable, else re-dispatch the same task into the
same worktree with the same identity. Never spawn a duplicate — a second worktree
splits one task across two copies.

## Discipline

- One dispatch, one crewmate, one worktree. Do not spawn a second crewmate for a
  task that already has a live one.
- Never end a turn having *started* work you then forget: the completion
  notification will re-invoke you, but the durable task record is the source of
  truth if the session restarts. Keep the backlog current on every dispatch,
  completion, and decision.

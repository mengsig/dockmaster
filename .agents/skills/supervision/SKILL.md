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

1. **Dispatch** only after persisting its deterministic role-specific thread
   name. Call `spawn_agent(..., fork_turns="none")`, persist its returned id
   immediately, then mark the backlog item in flight.
2. **Resume** the conversation and dispatch other independent work. Do not block.
3. **On a mailbox completion**, reconcile and act:
   - `bin/dm-task.sh state <id>` for authoritative current state.
   - Read the crewmate's status events (`state/tasks/<id>.status`) as a log of
     *what happened*, never as current truth.
   - Advance the pipeline, report an outcome, or handle a blocker/decision.
   - Reconcile ready work once (`bin/dm-task.sh ready-gates`, then
     `bin/dm-backlog.sh ready`) and schedule one safe gate/task when capacity
     exists before waiting again.

## Productive mailbox waits

Use the native mailbox wait, not short polling. While healthy work is live, call
`wait_agent(timeout_ms=3600000)` (the longest supported one-hour deadline).
Worker completion and steered user input interrupt it.

An empty timeout is a scheduling boundary, never an instruction to repeat the
same wait. After a timeout:

1. Call `list_agents` once and reconcile each relevant task once.
2. Run `bin/dm-task.sh ready-gates` and `bin/dm-backlog.sh ready`.
3. Start one safe ready gate/task when a slot exists. Approved ready gates take
   priority over new work; integration-blocked gates stay blocked.
4. Only after that reconciliation/scheduling pass may another long mailbox wait
   begin.

Never issue an immediate identical empty re-wait. Do not shorten the timeout to
manufacture progress rows. If nothing changed and no safe work is ready, stay
silent and begin the next long wait only after the pass above.

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

## Notification-producing waits

A yielded terminal command has no collaboration identity, so its exit does not
produce a parent-mailbox wake. It is safe only while the current agent remains
attached and resumes it explicitly. Never leave a raw background or yielded
command session behind and assume its completion will wake the dockmaster.

When an external wait must wake the dockmaster after the current turn—every
task review and every ad-hoc diagnosis/report/plan Lavish surface included—spawn
one dedicated low-cost waiter with `fork_turns="none"`,
`model="gpt-5.6-terra"`, and `reasoning_effort="low"` when supported. Give it the
complete command and working directory. It must run the command synchronously,
resume any yielded session until terminal, and return only the result or visible
failure. The waiter completion reaches the parent mailbox; `wait_agent` is the
native wake path. Keep this waiter read-only and single-purpose.

For a task-bound review, derive its identity with
`bin/dm-thread-name.sh <id> review_waiter`. Before spawning, reconcile the saved
id and exact name with `list_agents`: reattach one exact match, block on multiple,
and spawn only after proving zero. Persist the name before spawning, then the
returned identity:

```
waiter_epoch="$(bin/dm-task.sh waiter <id> prepare <thread-name>)"
spawn_agent(...)
bin/dm-task.sh waiter <id> active <thread-name> "$waiter_epoch" <agent-id>
```

When feedback returns, set it `idle`, relay feedback to the artifact/code owner,
then re-arm that exact waiter with `followup_task`; do not consume another
thread. On approval, session end, or visible waiter failure, run
`bin/dm-task.sh waiter <id> terminal <waiter-epoch> <agent-id>`. An active session or waiter makes
`dm-worktree.sh remove` and `dm-task.sh archive` refuse.

For an ad-hoc surface with no task, derive one stable thread name from the
artifact label and apply the same exact-id/name reconciliation in the live
session. If the loop must survive a restart, create a scout task so the waiter
identity has a durable owner; do not invent a second state file.

A root may poll directly only when it stays attached for the entire current
turn and explicitly resumes the same yielded command session until exit. Root
must never leave a raw/yielded `lavish-axi` or `dm-lavish.sh poll` behind and
expect it to wake a later turn. Capacity or identity ambiguity is a visible
blocker, never a reason to fall back to an unattended poll.

## External waits

For state changes with no completion notification — CI turning green, an external
deploy, a remote queue — do not busy-wait:

- **Attached active-session wait** — run `bin/dm-pr.sh await-checks <id>
  [--timeout-secs N] [--interval-secs N]` through the command tool. If it yields
  a running session, resume that session with the runtime wait/write tool. The
  script polls until the rollup is terminal (`passing`/`failing`/`none`) or it
  times out, exiting 0 on passing/none and non-zero on failing/timeout. Use this
  only while the current agent stays attached. If the result must wake a later
  parent turn, delegate the same bounded command to a dedicated waiter instead.
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
whose worktree still holds unlanded work, load `stuck-worker`: re-attach by exact
`agent_id`; if absent, list and match the exact persisted `thread_name`. One
match is adopted, zero requires a no-live-owner proof, and multiple matches fail
closed as ambiguous. Never spawn a duplicate — a second worktree splits one
task across two copies. The same move covers a worker that already finished but
needs a follow-up — `stuck-worker`'s completed-worker case.

## Discipline

- One dispatch, one crewmate, one worktree. Do not spawn a second crewmate for a
  task that already has a live one.
- Never end a turn having *started* work you then forget. Use `wait_agent` while
  the goal remains active under the productive long-wait policy above; durable
  task state is still the source of truth if the session restarts. Keep the
  backlog and pipeline gate state current on dispatch, completion, and decision.

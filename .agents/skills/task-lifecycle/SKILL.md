---
name: task-lifecycle
description: The end-to-end contract for a delegated task — intake, classify (ship vs scout), dispatch a crewmate in an isolated worktree, supervise, deliver, tear down, and promote. Load before taking on any project work.
---

# task-lifecycle

The dockmaster never does project work itself. It delegates each task to a
crewmate (a subagent) in its own worktree, supervises to completion, and reports
outcomes. This is that contract.

## 1. Intake — resolve the repo

Resolve which registered repo a request targets. An explicit repo wins; a clear
follow-up inherits the previous one; otherwise match against the registry
(`bin/dm-repo.sh list`), in-flight work, and the repo's code/README. Proceed on
one confident match and name it in plain language. Ask one concise question only
when several or no repos plausibly match.

If the request targets a repo that does not exist yet (a brand-new project) or an
un-enrolled remote, the first step is to create/enroll it via `project-management`
(`dm-repo.sh create` for a new repo, `add` for an existing remote), then dispatch
against the enrolled repo — never build it outside the framework.

## 2. Classify — two independent axes

**Deliverable — ship or scout:**
- **ship** (default) — delivers a change: ends in a PR or an approved local
  merge.
- **scout** — investigates, plans, reproduces, or audits: ends in a report at
  `data/<id>/report.md`, never a code change. Default for "look into / why is /
  plan / audit / reproduce" requests.
- A diagnosis or recommendation is **evidence, not authorization to implement**.
  Implementation is a separate, explicit request. (Load `diagnostic-reasoning`
  before scoping a bug.)

**Dispatchability:**
- The configured six-thread ceiling is a hard fleet budget. Keep at most three
  ordinary task owners live at once, reserving three slots for an approval
  waiter, recovery, and review/verification. Count live agents with
  `list_agents` before every spawn. If fewer slots remain, leave the item queued;
  never claim it is in flight before a runtime owner exists.
- Serialize (queue as blocked) when it touches the same repo subsystem as live
  work or depends on unlanded work. Record it durably:
  `bin/dm-backlog.sh add <id> "<title>" --repo <repo> --status queued --blocked-by <other-id>`.
- Before spawning a queued item, consult `bin/dm-backlog.sh ready` — it lists
  queued items whose blockers are all complete, judging each blocker by its real
  reconciled task state (`bin/dm-task.sh state`), not a hand-set backlog status.
  A queued item absent from `ready` is still genuinely blocked; do not dispatch it.

## 3. Dispatch

Give the task an id (short kebab, e.g. `fix-login-412`), then:

```
bin/dm-task.sh new <id> --kind ship|scout --repo <repo> --title "<title>"
bin/dm-backlog.sh add <id> "<title>" --repo <repo> --status queued
bin/dm-worktree.sh create <id> <repo>
bin/dm-brief.sh <id>              # scaffolds data/<id>/brief.md
```

Open the brief, replace `{TASK}` with a concrete description, acceptance
criteria, constraints, and context. Keep additions task-specific; do not restate
the lifecycle. The durable id allows dots, hyphens, and uppercase, but Codex
`task_name` accepts only lowercase letters, digits, and underscores. Derive a
separate deterministic thread label; its digest suffix prevents normalized ids
such as `fix-a`, `fix.a`, and `fix_a` from colliding:

```
thread_name="$(bin/dm-thread-name.sh <id> worker)"
bin/dm-task.sh set <id> thread_name "$thread_name"
spawn_agent(task_name=<thread_name>, message=<contents of data/<id>/brief.md>,
            fork_turns="none")
```

**Right-size the dispatch — you decide the shape.** Use one bounded worker for
ordinary implementation; split only independent, material subproblems; reserve
parallel reviewers for difficult or high-risk changes. `fork_turns="none"` is
required because the generated brief already contains the full task, repository
memory, isolation contract, and coding standards. Forking the parent history
would duplicate context and make both runtimes slower and less predictable.

The current Codex collaboration call does not expose a per-spawn model or
reasoning-effort field. Do not claim or simulate one. Preserve right-sizing with
task granularity, role-specific prompts, and the smallest sufficient number of
agents; use a configured custom agent only when the active Codex surface actually
offers that selector. Bias toward sufficient reasoning for safety-critical work.

The crew already has a dedicated worktree from `dm-worktree.sh`, so pass its
absolute path in the brief and require the worker to verify and enter it before
acting. The spawn result's agent id is the runtime identity; never substitute
the durable id or thread label for it. Record both values for recovery:

```
bin/dm-task.sh set <id> agent_id <returned-agent-id>
bin/dm-backlog.sh move <id> inflight
```

Persist `thread_name` **before** spawning. Persist the returned `agent_id`
immediately, before any confirmation message, then mark the backlog item
in-flight. If spawn is rejected, it remains queued with its prepared worktree.
If `agent_id` persistence fails after spawn, interrupt that exact returned id
and leave/requeue the item visibly; never create an owner that durable state
cannot name.

Confirm the crewmate is processing the brief, then resume supervision
(load `supervision`).

**Stacked sub-PRs (dispatching off a parent branch, not the default branch).**
When a task is a piece of a larger in-flight change, dispatch it as a child of
the parent task's branch instead of the default branch:

```
bin/dm-worktree.sh create <child-id> <repo> <child-branch> --base <parent-branch>
```

This branches the child worktree off the parent ref (fetched fresh) and records
it as the child's `base` meta; `bin/dm-pr.sh open` then defaults the child's PR
base to that recorded parent when no explicit `--base` is passed, so the sub-PR
targets the parent's "main PR" instead of the default branch. If the parent
branch moves before the child lands, restack the child via the `merge-conflict`
skill (rebase onto the new parent tip) — automating that restack is deferred.

## 4. Deliver — the canonical requested-change flow

Every requested change goes through the same gated flow:

1. **Build + review artifact.** The crewmate implements and commits in its
   worktree, then renders the change as a lavish review page and signals
   `review-ready`.
2. **Lavish approval gate.** Load `change-review`: present the artifact, let its
   no-fork waiter own the poll through exit, relay feedback, loop until the
   operator approves. Nothing lands before this approval.
3. **Ask how it lands: PR or local?** Put the plain question to the operator.
   - **local** (or a `local-only` repo) → set the task to local mode, then land
     after approval: `bin/dm-task.sh set <id> mode local-only` then
     `bin/dm-merge.sh local <id>`. `dm-merge.sh local` refuses any task whose
     mode isn't `local-only`, and a task on a pipeline/direct-pr repo inherits
     that repo's mode — so set it explicitly here (or classify the task local at
     dispatch with `dm-task.sh new --mode local-only`).
   - **PR** → load `pr-workflow` and run the pipeline: coldstart review → fix +
     tests → merge-gate review → fix + tests → PR creation.
4. **Merge gate.** After the PR is open, the operator either merges on GitHub
   (you watch for it and then sync + teardown) or you ask for approval and merge
   with `bin/dm-pr.sh merge`. Never merge red. Report the full `https://…` URL.
   Review comments and post-open CI on an open PR are handled by `post-pr-review`.

**Fast path for a trivial change.** When the change is *objectively trivial*
(see `change-review` for the canonical criteria), the lavish approval gate
(step 2) MAY be skipped and the PR path uses the single-pass `fast` pipeline
(`config/pr-pipeline.fast.json`). Tests still run, one cold review still happens,
and merge authority is unchanged. When unsure, use the full path above.

Do not stack an extra manual review on top of the pipeline — the two review
passes in `pr-workflow` are the rigor. The tests step in either path follows
`testing-policy` — a repo with no test command is a declared soft skip (verify
the change instead), never a fabricated pass. Undoing a change that already
landed is a new task under `rollback`, not a teardown.

## 5. Teardown

Tear down a ship task only after landing is confirmed:

```
bin/dm-worktree.sh remove <id>
```

A refusal ("unlanded work") is a **stop-and-investigate** signal, never an
obstacle to force past. `--force` requires explicit operator discard authority.
A scout worktree may be removed once `data/<id>/report.md` exists and any
operator decision it surfaced is recorded (load `decision-hold`).

After teardown, record completion, archive the landed task's records, and
re-evaluate the queue:
```
bin/dm-backlog.sh done <id> --note "<PR url / landed / report>"
bin/dm-task.sh archive <id>    # move <id>.meta/.status + data/<id>/ to state/archive/
bin/dm-backlog.sh ready        # queued items whose blockers have now cleared
```
Archival fails closed unless the task reconciles to terminal `done` with no live
worktree, so run it only after landing is confirmed and teardown has removed the
local copy. It keeps `list`/`status` from re-scanning an unbounded set of
finished tasks; the records stay recoverable under `state/archive/`.

## 6. Scout → ship promotion

When implementation is separately authorized, promote in place — do not respawn.
Flip the kind and re-brief the same crewmate to carry over only the intended fix
(not scratch commits/debug edits), create a proper branch, and follow the repo's
delivery mode:

```
bin/dm-task.sh set <id> kind ship
bin/dm-brief.sh <id>     # regenerate as a ship brief; fill {TASK} with the fix scope
```

A reproduced bug becomes the regression test.

## Recovery

State lives on disk, not in conversation memory. After any restart, reconcile
each task with `bin/dm-task.sh state <id>` (authoritative current state) before
acting. For every queued/in-flight item, read both `thread_name` and `agent_id`,
then `list_agents`. An exact live `agent_id` wins; otherwise match the exact
persisted thread name. Exactly one match is reattached and its id persisted.
Zero matches permits recovery only after the no-owner proof in `stuck-worker`;
multiple matches are an ambiguity blocker and **must not** trigger another
spawn. Preserve the worktree and identity; never spawn a duplicate.

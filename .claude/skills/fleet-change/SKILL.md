---
name: fleet-change
description: Fan one operator intent out across multiple repos as a campaign — one ordinary gated child task per repo, tracked and reported as a unit. Load before dispatching a multi-repo change.
---

# fleet-change

A **campaign** is one operator intent that applies to many repos ("bump this
dep everywhere", "add this header to every service"). It fans out to one child
task PER repo. This skill is only the grouping and the rollup: each child is an
**ordinary gated task** run through `task-lifecycle` — its own worktree, normal
`change-review` + PR-or-local gate. No prime directive is relaxed. There is no
new engine, scheduler, or DAG resolver — you reuse the existing task, worktree,
PR, and `--blocked-by` machinery.

## Invariants that still hold (per child, unchanged)

- Read-only over `repos/`; every change lands from a crewmate's worktree.
- Each child passes the lavish approval gate and the PR-or-local decision.
- Never merge red; never merge without the operator's word (a repo's
  `merge_authority`: `never` forbids merging outright, `ask` is the default, and
  a standing `yolo` is the only relaxation — and only for LOW/MEDIUM-risk green
  work, never a HIGH-risk change; per repo, not "the whole campaign").
- Never tear down unlanded work.

## 1. Classify and resolve the target repo set

Confirm the intent is genuinely multi-repo, then resolve the concrete targets
from the registry — do not act on "all repos" vaguely:

```
bin/dm-repo.sh list
```

Name the resolved set back to the operator in plain language and get a nod
before fanning out. If the set is ambiguous or large, ask one concise question.

## 2. Open the campaign

Give the campaign a short kebab id (e.g. `bump-axios-3`). It is a backlog
grouping, not a task — do not create a task record for it. Each child item
carries the id via `--campaign`:

```
bin/dm-backlog.sh add <child-id> "<title>" --repo <repo> --campaign <campaign-id> \
  --status queued [--blocked-by <other-child-id>]
```

Sequence dependent repos with `--blocked-by` (e.g. a shared library must land
before its consumers). Independent repos carry no blocker and dispatch in
parallel. `bin/dm-backlog.sh ready` still gates each child on its blockers'
**real** reconciled task state.

## 3. Dispatch one ordinary child task per repo

The phase-2 backlog item stays `queued` while its worktree and brief are
prepared. For each ready child, follow this exact ownership transition:

```
bin/dm-task.sh new <child-id> --kind ship --repo <repo> --title "<title>"
bin/dm-worktree.sh create <child-id> <repo>
bin/dm-brief.sh <child-id>
Agent(prompt=<brief>, run in background,
      subagent_type/model/effort per task-lifecycle)
bin/dm-task.sh set <child-id> agent_id <returned-agent-id>
bin/dm-backlog.sh move <child-id> inflight
```

Never move a child to `inflight` before the returned runtime owner is durably
recorded. On spawn failure it remains queued; on owner-persistence failure,
stop that exact returned id and leave/requeue it visibly. Nothing else is
special-cased: each child is briefed, gated, and delivered exactly as a
single-repo task. Route a child to an existing `secondmate` where one owns that
repo (load `secondmate`).
Dispatch independent children in bounded waves through `task-lifecycle`; respect
the active runtime's capacity and keep enough room for approval, recovery, and
review workers. Keep excess children queued and mark a child `inflight` only
after its runtime owner is durably recorded. Hold `--blocked-by` children until
`bin/dm-backlog.sh ready` clears them. A campaign is never authority for
unbounded fan-out.

## 4. Supervise and report as a unit

Supervise all children with `supervision` (background agents, completion
notifications — no polling). See the campaign's state at any time with:

```
bin/dm-backlog.sh campaign <campaign-id>
```

Report **one aggregate outcome** to the operator, per repo: the PR URL (full
`https://…`), landed, or the concrete blocker. Batch routine progress; surface
immediately only what `task-lifecycle` already says to (review-ready, a
decision, a real blocker). A child that stalls or dies is recovered with
`stuck-worker` — the campaign does not license duplicating a worker or skipping
a gate.

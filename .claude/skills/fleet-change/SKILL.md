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
- Never merge red; never merge without the operator's word (a repo's standing
  `yolo` posture is the only relaxation, per repo, not "the whole campaign").
- Never tear down unlanded work.

## 1. Classify and resolve the target repo set

Confirm the intent is genuinely multi-repo, then resolve the concrete targets
from the registry — do not act on "all repos" vaguely:

```
bin/mh-repo.sh list
```

Name the resolved set back to the operator in plain language and get a nod
before fanning out. If the set is ambiguous or large, ask one concise question.

## 2. Open the campaign

Give the campaign a short kebab id (e.g. `bump-axios-3`). It is a backlog
grouping, not a task — do not create a task record for it. Each child item
carries the id via `--campaign`:

```
bin/mh-backlog.sh add <child-id> "<title>" --repo <repo> --campaign <campaign-id> \
  --status queued [--blocked-by <other-child-id>]
```

Sequence dependent repos with `--blocked-by` (e.g. a shared library must land
before its consumers). Independent repos carry no blocker and dispatch in
parallel. `bin/mh-backlog.sh ready` still gates each child on its blockers'
**real** reconciled task state.

## 3. Dispatch one ordinary child task per repo

For each target repo, run the normal `task-lifecycle` dispatch (`mh-task.sh new`
→ `mh-backlog.sh add ... --campaign <id> --status inflight` → `mh-worktree.sh
create` → `mh-brief.sh` → spawn the crewmate). Nothing here is special-cased:
the child is briefed, gated, and delivered exactly as a single-repo task. Route
a child to an existing `secondmate` where one owns that repo (load `secondmate`).
Dispatch independent children immediately; hold `--blocked-by` children until
`bin/mh-backlog.sh ready` clears them.

## 4. Supervise and report as a unit

Supervise all children with `supervision` (background agents, completion
notifications — no polling). See the campaign's state at any time with:

```
bin/mh-backlog.sh campaign <campaign-id>
```

Report **one aggregate outcome** to the operator, per repo: the PR URL (full
`https://…`), landed, or the concrete blocker. Batch routine progress; surface
immediately only what `task-lifecycle` already says to (review-ready, a
decision, a real blocker). A child that stalls or dies is recovered with
`stuck-worker` — the campaign does not license duplicating a worker or skipping
a gate.

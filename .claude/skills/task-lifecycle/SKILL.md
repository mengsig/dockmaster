---
name: task-lifecycle
description: The end-to-end contract for a delegated task — intake, classify (ship vs scout), dispatch a crewmate in an isolated worktree, supervise, deliver, tear down, and promote. Load before taking on any project work.
---

# task-lifecycle

The manhandler never does project work itself. It delegates each task to a
crewmate (a subagent) in its own worktree, supervises to completion, and reports
outcomes. This is that contract.

## 1. Intake — resolve the repo

Resolve which registered repo a request targets. An explicit repo wins; a clear
follow-up inherits the previous one; otherwise match against the registry
(`bin/mh-repo.sh list`), in-flight work, and the repo's code/README. Proceed on
one confident match and name it in plain language. Ask one concise question only
when several or no repos plausibly match.

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
- Dispatch immediately when the work does not overlap in-flight work — no
  concurrency cap.
- Serialize (queue as blocked) when it touches the same repo subsystem as live
  work or depends on unlanded work. Record it durably:
  `bin/mh-backlog.sh add <id> "<title>" --repo <repo> --status queued --blocked-by <other-id>`.

## 3. Dispatch

Give the task an id (short kebab, e.g. `fix-login-412`), then:

```
bin/mh-task.sh new <id> --kind ship|scout --repo <repo> --title "<title>"
bin/mh-backlog.sh add <id> "<title>" --repo <repo> --status inflight
bin/mh-worktree.sh create <id> <repo>
bin/mh-brief.sh <id>              # scaffolds data/<id>/brief.md
```

Open the brief, replace `{TASK}` with a concrete description, acceptance
criteria, constraints, and context. Keep additions task-specific; do not restate
the lifecycle. Then spawn the crewmate with the brief as its prompt:

```
Agent(prompt=<contents of data/<id>/brief.md>, run in background,
      subagent_type/model/effort per config/dispatch judgment)
```

For work that mutates files where a plain subagent would collide with siblings,
prefer `isolation: "worktree"`; here the crew already has a dedicated worktree
from `mh-worktree.sh`, so pass the worktree path in the brief and let the agent
`cd` into it. Record the returned agent id: `bin/mh-task.sh set <id> agent_id <id>`.
Confirm the crewmate is processing the brief, then resume supervision
(load `supervision`).

## 4. Deliver — the canonical requested-change flow

Every requested change goes through the same gated flow:

1. **Build + review artifact.** The crewmate implements and commits in its
   worktree, then renders the change as a lavish review page and signals
   `review-ready`.
2. **Lavish approval gate.** Load `change-review`: present the artifact, collect
   feedback (poll as a background task), relay it to the crewmate, loop until the
   operator approves. Nothing lands before this approval.
3. **Ask how it lands: PR or local?** Put the plain question to the operator.
   - **local** (or a `local-only` repo) → `bin/mh-merge.sh local <id>` after
     approval.
   - **PR** → load `pr-workflow` and run the pipeline: coldstart review → fix +
     tests → merge-gate review → fix + tests → PR creation.
4. **Merge gate.** After the PR is open, the operator either merges on GitHub
   (you watch for it and then sync + teardown) or you ask for approval and merge
   with `bin/mh-pr.sh merge`. Never merge red. Report the full `https://…` URL.

Do not stack an extra manual review on top of the pipeline — the two review
passes in `pr-workflow` are the rigor.

## 5. Teardown

Tear down a ship task only after landing is confirmed:

```
bin/mh-worktree.sh remove <id>
```

A refusal ("unlanded work") is a **stop-and-investigate** signal, never an
obstacle to force past. `--force` requires explicit operator discard authority.
A scout worktree may be removed once `data/<id>/report.md` exists and any
operator decision it surfaced is recorded (load `decision-hold`).

After teardown, record completion and re-evaluate the queue:
```
bin/mh-backlog.sh done <id> --note "<PR url / landed / report>"
bin/mh-backlog.sh ready        # queued items whose blockers have now cleared
```

## 6. Scout → ship promotion

When implementation is separately authorized, promote in place — do not respawn.
Flip the kind and re-brief the same crewmate to carry over only the intended fix
(not scratch commits/debug edits), create a proper branch, and follow the repo's
delivery mode:

```
bin/mh-task.sh set <id> kind ship
bin/mh-brief.sh <id>     # regenerate as a ship brief; fill {TASK} with the fix scope
```

A reproduced bug becomes the regression test.

## Recovery

State lives on disk, not in conversation memory. After any restart, reconcile
each task with `bin/mh-task.sh state <id>` (authoritative current state) before
acting. For a crewmate whose agent is gone but whose worktree holds unlanded
work, load `stuck-worker` — preserve the worktree and identity; never spawn a
duplicate.

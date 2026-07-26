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
- Dispatch immediately when the work does not overlap in-flight work — no
  concurrency cap.
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
bin/dm-backlog.sh add <id> "<title>" --repo <repo> --status inflight
bin/dm-worktree.sh create <id> <repo>
bin/dm-brief.sh <id>              # scaffolds data/<id>/brief.md
```

Open the brief, replace `{TASK}` with a concrete description, acceptance
criteria, constraints, and context. Keep additions task-specific; do not restate
the lifecycle. Confirm it, then spawn the crewmate with the brief as its prompt:

```
bin/dm-brief.sh check <id>        # refuses while {TASK} is still unfilled
Agent(prompt=<contents of data/<id>/brief.md>, run in background,
      model=<tier>, subagent_type=crew-<level>)   # both dials, see below
bin/dm-task.sh set <id> model <tier>
bin/dm-task.sh set <id> effort <level>    # set agent_id refuses without both
bin/dm-task.sh set <id> agent_id <returned-agent-id>
```

`set agent_id` re-runs that same guard, so an unfilled brief cannot reach a
recorded dispatch; `dm-status` flags a live task on an unfilled brief as
UNFILLED. Every other section of a brief looks complete on a skim, so nothing
else would catch an empty task section.

**Right-size the dispatch — two dials, both yours, both chosen by judgment.**
The dockmaster runs on the strongest model precisely so it can size everything
else down from there. There is no computed recommendation to defer to; you
read the brief and pick. Do NOT inherit your own tier by default. Every spawn
sets both:

- **Model** — the Agent `model` parameter: `haiku` | `sonnet` | `opus` | `fable`.
  What the crewmate must be able to DO.
- **Reasoning effort** — the Agent `subagent_type`: `crew-low` | `crew-medium` |
  `crew-high` | `crew-xhigh`. How long it must THINK first. (No `max` tier: a
  deliberate cost ceiling.)

Think of them as **one ladder**, not two independent knobs to eyeball
separately:

```
haiku < sonnet·low < sonnet·medium < sonnet·high
      < opus·low < opus·medium < opus·high < opus·xhigh
```

Pick a rung from what the brief actually asks for: how precise and
unambiguous the instructions are, how trivial the work is, and how expensive
being wrong would be. Clear instructions on a small, mechanical change land
near the bottom. Anything ambiguous, adversarial, or risky to get wrong —
debugging, security, a large cross-cutting diff — climbs toward the top.
A `review` pass never drops below `opus`·`high` (under-powering a review is
how bad code lands, see `pr-workflow`); that floor is the one deliberate
exception, not the rule for everything else.

Each `crew-<level>` pins a **default model** — `crew-low` haiku, `crew-medium`
sonnet, `crew-high` / `crew-xhigh` opus — so an omitted `model` parameter lands
on a considered tier instead of inheriting your own; the parameter still
overrides it when the ladder calls for a different pairing (sonnet at low
effort is an ordinary rung, not a mismatch to avoid).

**A model that does not support a level ignores it silently** rather than
failing, so a dial can be inert without ever saying so. `haiku` ignores effort
entirely and always runs at its own default — `crew-low` + haiku buys nothing;
pick haiku for cheapness, never for restraint. `sonnet`, `opus`, and `fable`
honored all four levels when this was measured, but support is per-build and
`xhigh` is the level most likely to be unavailable, so treat the top of the
range as best-effort rather than guaranteed.

Record the choice once the crewmate is spawned:

```
dm-task.sh set <id> model <tier>
dm-task.sh set <id> effort <level>       # must match the crew-<level> you spawned
dm-task.sh set <id> agent_id <returned-agent-id>
```

`dm-task.sh set agent_id` REFUSES until the task records both `model` and
`effort` (an effort outside the valid set is refused too) — it forces the
choice to be made and written down, not any particular value. This is a
**record gate, not a spawn gate**: the crewmate is already running by the time
it executes, and nothing compares the recorded effort against the
`subagent_type` you actually passed — same shape as the `{TASK}` brief guard.
Record what you really passed, or the meta lies.

`dm-status` flags a live task missing either dial as UNSIZED, and
`dm-task.sh sizing` prints the fleet's recorded distribution — counts by
model, by effort, and how many dispatches recorded neither.

`sizing --transcripts <dir>` goes further and checks each record against what
the crewmate ACTUALLY ran, reading the model out of its transcript (one
`<agent_id>.output` per spawn, in the runtime's own per-session `tasks/` dir).
That is the only check that can catch a record which lies — `set agent_id`
records a choice and cannot verify the spawn. A missing transcript is reported
unproven, never a pass; a contradiction is a MISMATCH and exits non-zero.

The same judgment applies to **every** sub-unit you spawn downstream — review
passes, verification, fix rounds, merge-gate reasoning (see `pr-workflow`) —
not just the implementing crewmate. Pick the rung the pass earns; don't reach
for the top by reflex.

For work that mutates files where a plain subagent would collide with siblings,
prefer `isolation: "worktree"`; here the crew already has a dedicated worktree
from `dm-worktree.sh`, so pass the worktree path in the brief and let the agent
`cd` into it. Record the returned agent id as shown above. Confirm the crewmate
is processing the brief, then resume supervision (load `supervision`).

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
2. **Lavish approval gate.** Load `change-review`: present the artifact, collect
   feedback (poll as a background task), relay it to the crewmate, loop until the
   operator approves. Nothing lands before this approval.
3. **Ask how it lands: PR or local?** Put the plain question to the operator.
   - **local** (or a `local-only` repo) → land after approval with
     `bin/dm-merge.sh local <id>`. The REGISTRY decides a repo's delivery mode,
     not the task: `dm-merge.sh local` re-reads it and refuses unless the repo is
     registered `local-only`, and `dm-task.sh set <id> mode` only re-syncs a task
     to what its repo is registered as. So for a local landing on a
     pipeline/direct-pr repo, get the operator's word and record it where it
     belongs: `bin/dm-repo.sh set <repo> mode local-only`.
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

A reproduced bug becomes the regression test. The promotion runs one way only:
`ship → scout` is refused, because demoting a ship task would let a report file
reconcile it to done and let teardown discard its committed work as scratch.

## 7. The task that must not be built

A ship task whose honest answer is "do not build it" ends here, not by being
reshaped into something that looks finished. Tear down the local copy, then:

```
bin/dm-task.sh close <id> --reason "<why nothing was built>"
```

It records a terminal state with the reason, claiming nothing landed — then
`dm-backlog.sh done <id> --note "<why>"` and `dm-task.sh archive <id>` as usual.
It refuses while a local copy is still present (teardown is what inspects the
work) and refuses a task that is already terminal. Report the conclusion and the
reason to the operator; a decision only they can make goes through
`decision-hold` first.

## Recovery

State lives on disk, not in conversation memory. After any restart, reconcile
each task with `bin/dm-task.sh state <id>` (authoritative current state) before
acting. For a crewmate whose agent is gone but whose worktree holds unlanded
work, load `stuck-worker` — preserve the worktree and identity; never spawn a
duplicate.

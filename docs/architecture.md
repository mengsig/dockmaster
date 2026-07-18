# dockmaster architecture

dockmaster is an **agent distro**: a portable directory of instructions, skills,
helper scripts, and state conventions that turns a Claude Code session into a
fleet handler. You talk to one agent — the **dockmaster** — and it runs a crew
of autonomous subagents across many repositories on your behalf.

dockmaster targets exactly one runtime — **Claude Code** — and leans on the
primitives it provides natively: background agents, a task list, structured
subagents, worktree isolation, completion notifications, Monitor, and cron.
Generic terminal harnesses have none of those, so *simulating* async, gated,
worktree-isolated fleet supervision there takes tens of thousands of lines of
bash and a terminal multiplexer (tmux/zellij/…). dockmaster needs none of that
machinery — it keeps the hard-won *contracts* of that model (async supervision,
worktree isolation, gated delivery, durable memory) and lets Claude Code supply
the mechanism.

## The core bet

> Anywhere you would otherwise build infrastructure to *simulate* async
> supervision, Claude Code has a native primitive that does it with zero idle
> token cost and higher fidelity. Use the primitive.

| concern | dockmaster mechanism |
| --- | --- |
| liaison agent | `AGENTS.md` persona |
| per-task worker ("crewmate") | **`Agent` subagent** run in background |
| visible session backend | Claude Code task list + background-agent transcripts (`/tasks`) |
| zero-token supervision | **background task → `<task-notification>`** (idle costs nothing; the harness re-invokes the dockmaster on completion) |
| external / periodic waits (CI, deploy) | **`Monitor`** (until-condition) and **`CronCreate` / `ScheduleWakeup`** |
| "no turn ends blind" | completion notifications + optional Stop hook; no polling |
| worktree isolation | native `git worktree` (`bin/dm-worktree.sh`) + `Agent(isolation:"worktree")` |
| durable backlog | native **Task list** (session) mirrored to `state/backlog.md` (cross-session) |
| project registry | `state/repos.json` + clones under `repos/` |
| global memory | dockmaster home memory: native `memory/`, `state/operator.md`, `state/learnings.md` |
| per-repo memory | **dm-memory hybrid**: committed `dm:knowledge` section in the repo's `AGENTS.md` + git-excluded private `.dm/` notes |
| delivery modes | modular **PR pipeline** (ordered gates) per repo |
| the no-mistakes gate | composable gates the dockmaster drives (`code-review` / `lavish`), optionally a `Workflow` script |
| persistent domain supervisor ("secondmate") | long-lived **background agent** addressed via `SendMessage` (can spawn its own crew) |
| per-task model/effort | `Agent` `model` / `effort` / `subagent_type` per dispatch — the orchestrator's per-task judgment, not a fixed table (`task-lifecycle` §3 Dispatch) |
| review surface | lavish-axi (`/lavish` skill) |
| self-update / fleet sync | guarded `git` fast-forward, via `bin/` + `git` |
| stacked sub-PRs | `dm-worktree.sh create --base <ref>` branches a child off a parent branch; `dm-pr.sh open` auto-targets the parent's PR |

The result is a small distro — instructions, skills, and helper scripts, no
daemon — that spends **zero tokens while work is in flight** and loses no accuracy
versus driving a Claude Code agent by hand: each worker *is* a full agent with the
full tool surface, not a constrained pane.

## The Dockyard

The vocabulary below is framed as a working dockyard:

> **The Dockyard.** You are the *captain*; the **dockmaster** runs your dockyard —
> it never handles cargo itself, it directs a crew of *dockhands* (crewmates)
> working in the holds (worktrees), hoisting *cargo* (changes) aboard the *ships*
> (repos) of your fleet, and reports back to you. One hand on the dock, a whole
> crew on the water.

## Roles and vocabulary

- **operator** — you. The only human. You state intent and make the decisions
  that are genuinely yours (merge, irreversible/destructive/security choices,
  credentials).
- **dockmaster** — the single agent you talk to. It never edits managed repos
  itself; it delegates, supervises, and reports outcomes. Read-only over
  `repos/` except for the narrow guarded paths (clone, sync, approved local
  merge).
- **crewmate** — a subagent the dockmaster spawns for one task, in its own git
  worktree. Ship or scout (below). Crewmates never talk to the operator; all
  reporting flows through the dockmaster.
- **domain agent** ("secondmate") — an optional *persistent* background agent
  that owns a domain (one repo or a family of repos), keeps its own memory, and
  can spawn its own crewmates. Addressed via `SendMessage`. Idle by default.

## Task shapes

- **ship** — delivers a change. Ends in a PR (or an approved local merge) and a
  torn-down worktree. The default.
- **scout** — investigates, plans, reproduces, or audits. Ends in a report at
  `data/<id>/report.md` and never touches project code. The default for
  "look into…", "why is…", "plan…", "audit…" requests. A scout report may
  *recommend* implementation but never authorizes it — implementation is a
  separate, explicit request (the discipline that diagnosis ≠
  authorization, and it matters for accuracy).

## Memory model (the centerpiece)

Knowledge is routed to its **most specific durable owner**. Per-repo memory is **plain markdown** driven by `bin/dm-memory.sh` — no
bespoke store, no query engine, nothing to install. It is a hybrid of two stores
so contributor knowledge travels while dockmaster-private context stays local.

**Per-repo SHARED (`dm:knowledge` section of the repo's own `AGENTS.md`):**
- Contributor-relevant facts: build/test commands, invariants, conventions,
  pitfalls, routing hints, decisions — one curated `- **[<kind>]** <fact>` bullet
  each, between `<!-- dm:knowledge:start -->` / `<!-- dm:knowledge:end -->`.
- It is **committed** in the repo's own `AGENTS.md`, so git materializes it in
  every worktree and clone — which is what makes recall work for crewmates, who
  work in worktrees.
- Delivered through the normal PR/land flow: a crewmate edits the section in its
  worktree and commits it alongside its work, so it travels with the repo. The
  dockmaster **never hand-writes** a managed repo's `AGENTS.md` (prime directive)
  and never force-commits onto a clone's default branch (that would diverge from
  origin and break fast-forward sync). `bin/dm-repo.sh seed` scaffolds only the
  private store at onboarding and never touches the clone's `AGENTS.md`, so the
  clone stays pristine.

**Per-repo PRIVATE (`repos/<repo>/.dm/notes.md`):**
- Dockmaster-only context that must not enter the user's project history: fleet
  strategy, sensitive routing, per-repo operator preferences.
- Git-excluded via the clone's `.git/info/exclude`, so it never shows as untracked
  or gets committed. Written with `bin/dm-memory.sh remember <repo> --private`.

Before working, the dockmaster and every crewmate recall with
`bin/dm-memory.sh recall <repo> [query]` instead of loading memory wholesale — and
the crewmate brief injects that recall output automatically, so a crewmate has the
repo's knowledge with no tool call.

**Global (dockmaster home):**
- `memory/` — Claude Code native file memory (operator identity, standing
  feedback, cross-repo project state). Indexed by `MEMORY.md`.
- `state/operator.md` — operator preferences and working style (inspect-then-update,
  curated, never append-forever).
- `state/learnings.md` — fleet-wide operational facts and gotchas that are *not*
  specific to any one repo (dated, evidence-backed, pruned).
- `state/repos.json` — the repo registry (source of truth for what is managed).

**Routing rule:** a contributor-relevant fact about *one repo* → that repo's
`dm:knowledge` section; a dockmaster-private repo fact → that repo's `.dm/` notes.
A fact about the *operator* or *the fleet as a whole* → global memory. Task-scoped
notes → the backlog item. Investigation findings → the scout report. This is the
single source of truth per fact — no duplication that can drift.

## Supervision model

There is no daemon. The lifecycle of a background crewmate is:

1. dockmaster spawns it with `Agent(..., background)` → returns an `agentId`
   immediately, costing nothing while it runs.
2. dockmaster records it in the backlog (native task + `state/backlog.md`
   mirror) and resumes the conversation / other dispatches.
3. When the crewmate finishes, Claude Code delivers a `<task-notification>`;
   the dockmaster wakes, reconciles state, and either reports an outcome to the
   operator or advances the pipeline.
4. For waits Claude Code cannot notify on (CI turning green, an external deploy),
   the dockmaster uses `Monitor` (poll an until-condition) or schedules a
   `CronCreate`/`ScheduleWakeup` check sized to how fast that state changes.

"Check up on them" = `TaskList` / `SendMessage` to a running agent. "Report
back" = surface outcomes (not mechanics) in chat. See `escalation` etiquette in
`AGENTS.md` §Escalation.

## Concurrency & worktrees

Independent work dispatches immediately with no cap. Work that touches the same
repo subsystem, or depends on unlanded work, is serialized or recorded as
blocked. Every ship task runs in its **own** worktree created by
`bin/dm-worktree.sh` (or `Agent(isolation:"worktree")`), so parallel work on one
repo never collides. Teardown refuses to discard uncommitted or unlanded work —
a refusal is a stop-and-investigate signal, never an obstacle to force past.

## Merge conflicts

Handled by the `merge-conflict` skill: a crewmate rebases/merges inside the
worktree with full repo context, resolves conflicts, re-runs the repo's tests,
and reports. Never forced, never discards unlanded work.

## The PR pipeline (modular gates)

Every requested change follows one canonical flow. The crewmate implements in
its worktree and renders the change as a **lavish review artifact**; the operator
approves it (with back-and-forth, all mediated by the dockmaster); only then does
the dockmaster ask **PR or local**. See `.claude/skills/change-review/SKILL.md`.

On the PR path, delivery is an **ordered list of named gates** declared per repo
in `config/pr-pipeline.<repo>.json` (falling back to
`config/pr-pipeline.default.json`). Each gate is a small, composable module. The
default pipeline runs **two independent review passes**, each followed by fix and
tests:

```
coldstart review → fix → tests → merge-gate review → fix → tests → (security?) → pr
```

then a **merge gate**: the operator merges on GitHub, or the dockmaster asks for
approval and merges (`bin/dm-pr.sh merge`, never red). By default the gates are
executed by the **dockmaster itself**, driving each one with ordinary `Agent`
calls while following `.claude/skills/pr-workflow/SKILL.md`; nothing else runs
them. `workflows/pr-pipeline.js` is an **optional** deterministic `Workflow`
runner for the same gates — used only when the operator opts into hands-off
multi-agent orchestration (invoked via the Workflow tool; not auto-discovered and
not wired to any `bin/` script). Adding a gate = document it in the skill and
list its name in the config array. See `.claude/skills/pr-workflow/SKILL.md` and
`config/README.md` (which part of the config each executor reads).

**Branch naming:** `<type>/<issue>/<slug>` — `type ∈ {feat,fix,bug,chore,refactor,docs,perf,test}`,
`issue` = the issue number (or `x` when none), `slug` = a short kebab summary.
Computed by `bin/dm-branch-name.sh`.

**PR descriptions** are short, plain, and human. Imperative summary of what
changed and why, the risk level, and how it was verified. Never any
"generated by an agent" line, never an agent co-author, never LLM
throat-clearing. See the pr-workflow skill for the template and anti-patterns.

**Stacked sub-PRs (Phase 1).** When a task is one piece of a larger in-flight
change, dispatch it off the parent task's branch instead of the default branch:
`bin/dm-worktree.sh create <child-id> <repo> <child-branch> --base <parent-branch>`
fetches that ref fresh and records it as the child's `base` meta; `bin/dm-pr.sh
open` then defaults the child's PR base to that recorded parent when no
explicit `--base` is passed, so the sub-PR targets the parent's PR instead of
main. If the parent branch moves before the child lands, restack the child via
the `merge-conflict` skill (rebase onto the new parent tip) — automating that
restack is deferred to a later phase.

## Layout

```
AGENTS.md                operating contract for the dockmaster (CLAUDE.md → this)
README.md                overview
docs/architecture.md     this file
bin/                     portable helper scripts (repo/worktree/pr/backlog/merge/memory)
.claude/skills/          dockmaster skills (some /-invocable, some agent-loaded at triggers)
workflows/               optional Workflow runner for the PR pipeline (opt-in)
config/                  pipeline defaults + per-repo overrides (committed defaults)
tests/                   tests/smoke.sh, the end-to-end regression check
.github/                 CI workflow (smoke + syntax on ubuntu + macos)
CONTRIBUTING.md          how to test, portability rules, branch/commit style
SECURITY.md              trust model and private vulnerability reporting
LICENSE                  MIT
assets/                  logo and theme assets
state/                   runtime, gitignored: repos.json, operator.md, learnings.md, backlog.md
repos/                   managed clones, gitignored, READ-ONLY to the dockmaster
data/                    per-task artifacts (scout reports), gitignored
```

This distro is itself a managed repo: its own per-repo memory is the
`dm:knowledge` section of this `AGENTS.md`.

`state/`, `repos/`, `data/`, and `.env` are operator-private and gitignored. The
tracked surface (`AGENTS.md`, `bin/`, `.claude/skills/`, `workflows/`, `config/`
defaults, docs) is the shared distro and ships through this repo's own PR path.

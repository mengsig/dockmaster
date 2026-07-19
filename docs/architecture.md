# dockmaster architecture

dockmaster is an **agent distro**: shared instructions, runtime-native skill
adapters, helper scripts, and state conventions that turn either Claude Code or
OpenAI Codex into a fleet handler. You talk to one **dockmaster**; it runs a crew
of autonomous subagents across many repositories.

The shared layer owns policy and durable state. Runtime adapters own tool nouns
and scheduling semantics: `.claude/skills/` for Claude, `.agents/skills/` plus
trusted `.codex/config.toml` for Codex. They have exact skill-name parity but are
never loaded by the other runtime. This keeps prompt context clean while
preserving one lifecycle and one toolbelt.

## The core bet

> Keep lifecycle policy shared; use each runtime's native collaboration and wait
> primitives behind an adapter. Never teach one runtime the other's tool schema.

| concern | shared contract | Claude adapter | Codex adapter |
| --- | --- | --- | --- |
| liaison | `AGENTS.md` | `CLAUDE.md` includes it | Codex discovers it directly |
| per-task worker | one task / one worktree | background `Agent` | `spawn_agent`, `fork_turns="none"` |
| supervision | durable state + no daemon | completion notification, task controls | mailbox, `wait_agent`, collaboration controls |
| follow-up / steering | same worker identity | `SendMessage` | `send_message` / `followup_task` |
| external wait | bounded command + native wake | `Monitor` or schedule | attached command, waiter subagent, or scheduled task |
| nested domain crew | root → secondmate → worker | native nested agents | `agents.max_depth=2`, six-thread cap |
| worktree isolation | `bin/dm-worktree.sh` | worktree-aware agent | brief-pinned existing worktree |
| durable backlog | `state/backlog.json` + rendered markdown | task list mirror | thread list mirror |
| project registry | `state/repos.json` + clones under `repos/` | shared | shared |
| global memory | `state/operator.md`, `state/learnings.md`, optional runtime memory | shared | shared |
| per-repo memory | committed `dm:knowledge` + private `.dm/` stores | shared | shared |
| delivery modes | modular **PR pipeline** (ordered gates) per repo | shared | shared |
| no-mistakes gate | review/test/security gates + optional runner | Claude reviewers | Codex fresh subagents; focused fallback if optional review skill absent |
| right-sizing | task shape, review tier, focused context | per-agent model/effort where available | agent count and prompt scope; no unproved per-spawn selector |
| review surface | lavish-axi | background poll notification | no-fork waiter completion notification |
| self-update / fleet sync | guarded fast-forward via `bin/` | shared | shared |
| stacked sub-PRs | recorded parent base + guarded PR open | shared | shared |

The result remains a small distro with no supervisor daemon. Each worker is a
full runtime agent, while generated briefs and `fork_turns="none"` keep redundant
parent context out of Codex workers. The complete mapping and evidence live in
[`runtime-capabilities.md`](runtime-capabilities.md).

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
- **domain agent** ("secondmate") — an optional long-lived background agent that
  owns a domain, keeps durable scope/memory, and can spawn its own crewmates.
  Addressed through the active runtime's follow-up adapter. Idle by default.

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
- Optional runtime memory — recall aid only, never the sole owner of a required
  fact.
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

There is no daemon. The dockmaster creates a background worker, records its
runtime id beside durable task state, and resumes other work. Runtime-native
completion/mailbox events wake the dockmaster; it reconciles real state before
advancing. CI and deploy waits use the bounded toolbelt wait during an active
session or a scheduled task for long-running/recurring work.

"Check up on them" uses the runtime adapter's list/message controls plus
`bin/dm-task.sh state`. "Report back" surfaces outcomes, never mechanics.

## Concurrency & worktrees

Independent work dispatches immediately within the runtime concurrency cap.
Work that touches the same
repo subsystem, or depends on unlanded work, is serialized or recorded as
blocked. Every ship task runs in its **own** worktree created by
`bin/dm-worktree.sh`, so parallel work on one
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
the dockmaster ask **PR or local**. See the active runtime's `change-review` skill.
Codex approval polls run inside a dedicated no-fork waiter: the waiter owns any
yielded terminal session through exit, and its subagent completion wakes the
dockmaster mailbox. A raw terminal session is never treated as a wake source.

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
executed by the **dockmaster itself**, driving runtime-native review workers
while following `pr-workflow`; nothing else runs them.
`workflows/pr-pipeline.js` is an **optional** deterministic runner for hosts that
expose its injected workflow API. It is not auto-discovered or wired to a `bin/`
script. Adding a gate means documenting it in both runtime adapters and listing
it in the config array. See `config/README.md` for executor coverage.

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
.claude/skills/          Claude-native workflow adapters
.agents/skills/          Codex-native workflow adapters
.codex/                  trusted-project Codex config/rules (including hooks)
workflows/               optional Workflow runner for the PR pipeline (opt-in)
config/                  pipeline defaults + per-repo overrides (committed defaults)
tests/                   lifecycle, parity, runtime, and performance checks
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
tracked surface (`AGENTS.md`, `bin/`, both runtime adapters, `.codex/`,
`workflows/`, `config/` defaults, docs) is the shared distro and ships through
this repo's own PR path.

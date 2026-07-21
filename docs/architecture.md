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
| per-repo memory | committed `.dm-knowledge/` notes + private `.dm/` stores | shared | shared |
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
bespoke store, no query engine, nothing to install. It is three stores, split by
who may see a fact: contributor knowledge travels with the repo, private context
stays local but reaches crewmates, and dockmaster-only context reaches neither.

**Per-repo SHARED (committed `.dm-knowledge/<task-id>.md` note files):**
- Contributor-relevant facts: build/test commands, invariants, conventions,
  pitfalls, routing hints, decisions — one curated `- **[<kind>]** <fact>` bullet
  per note file under the repo's tracked `.dm-knowledge/` directory (a committed
  dir, distinct from the git-excluded `.dm/`).
- It is **committed**, so git materializes it in every worktree and clone — which
  is what makes recall work for crewmates, who work in worktrees. Recall assembles
  the note files plus any legacy `dm:knowledge` `AGENTS.md` block, so pre-existing
  inline knowledge is never stranded.
- One file per task is the point: two concurrent tasks recording knowledge write
  **different files**, so notes never serialize on a hot `AGENTS.md` block and
  stop manufacturing a rebase conflict on nearly every PR.
- Delivered through the normal PR/land flow: a crewmate runs `bin/dm-memory.sh
  remember <id> --shared` in its worktree and commits the note alongside its work,
  so it travels with the repo. The dockmaster **never writes a managed repo
  directly** (prime directive) and never force-commits onto a clone's default
  branch (that would diverge from origin and break fast-forward sync).
  `bin/dm-repo.sh seed` scaffolds only the private store at onboarding and never
  touches the clone, so it stays pristine.

**Per-repo PRIVATE (`repos/<repo>/.dm/notes.md`):**
- Context that must not enter the user's project history: fleet strategy,
  routing, per-repo operator preferences.
- Git-excluded via the clone's `.git/info/exclude`, so it never shows as untracked
  or gets committed. Written with `bin/dm-memory.sh remember <repo> --private`.
- **It IS relayed into every crewmate brief** for the worker's awareness. Private
  means "never committed", not "never seen by a crewmate" — anything a worker
  must not see belongs in the dockmaster-only store below.

**Per-repo DOCKMASTER-ONLY (`repos/<repo>/.dm/private.md`):**
- Git-excluded *and* never relayed: `recall` shows it to the dockmaster, but the
  brief-facing `recall --crew` excludes it. Written with `remember <repo>
  --dockmaster-only`. This is the only store a crewmate never reads.

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
committed `.dm-knowledge/` notes; a dockmaster-private repo fact → that repo's
`.dm/` notes.
A fact about the *operator* or *the fleet as a whole* → global memory. Task-scoped
notes → the backlog item. Investigation findings → the scout report. This is the
single source of truth per fact — no duplication that can drift.

## State portability (backup and recovery)

`state/` is the system of record and it is gitignored single-copy local files.
Per-repo SHARED knowledge (`.dm-knowledge/`) is committed to each managed repo
and merged PRs live on GitHub, but the registry, the task history, the backlog,
and the operator/fleet/private memory exist on exactly one disk. `bin/dm-state.sh`
is the export/import path (`export | verify | import`).

**The record set** — what travels: `state/repos.json`; `state/tasks/*.meta` and
`*.status`; `state/backlog.json` and `backlog.md`; `state/operator.md`;
`state/learnings.md`; `state/secondmates.json`; `state/archive/*.meta|.status`;
and the git-excluded per-repo memory sidecars `repos/<repo>/.dm/*.md`.
`--with-artifacts` adds `data/**` and archived task dirs (briefs, scout reports,
review pages). The set is an explicit allowlist, not a sweep: a file the toolbelt
does not own is reported in the manifest as unrecognized and left behind, so a
restore can never look more complete than it is. The unrecognized scan covers the
top level of `state/` plus one level into `state/tasks/`, `state/archive/`, and
each `repos/<repo>/.dm/` — the dirs that hold records — so a future record type
added there surfaces as unrecognized instead of going silently missing from every
backup. It does not recurse further.

Native runtime `memory/` is global memory too, but it lives outside `$DM_HOME`
and is owned by the runtime; it is not carried and must be backed up with the
rest of your runtime configuration.

**What is deliberately excluded, and the cost.** Managed clones under `repos/`
are re-clonable from the registry's remotes, and live worktrees under
`state/worktrees/` are checkouts off those clones — both are large and mostly
reproducible, so neither is archived. The exception that matters: work committed
in a worktree but never landed is single-copy and is *not* recoverable from an
archive. Import says so explicitly and prints, per repo, how to re-establish the
clone. Note it prints `git init` + `fetch` + `checkout` rather than `git clone`:
the restored `.dm/` sidecar already occupies the directory, and `git clone`
refuses a non-empty target.

**Consistency: per-file, not point-in-time.** Every record file is copied while
holding the same `dm_lock` advisory mutex its writers take, so no file in the
archive is a torn mid-write copy. The archive is *not* an atomic snapshot —
files are copied one at a time, so a write landing between two copies appears in
one and not the other. Status logs and artifacts are copied without a lock (their
writers are append-only or write-once). For a clean snapshot, export with no crew
work in flight. Export is strictly read-only; import refuses a populated state
root without `--force`, names every file it would replace, and never deletes
files the archive does not carry. Import has **no rollback**: files are installed
one at a time, so a mid-way failure (an unwritable path, a full disk) leaves the
root partially restored — the error names how many files landed and where their
pre-import copies are, and recovery is to fix the cause and re-run with `--force`.

**Export verifies what it wrote.** Before reporting success, export re-reads the
finished archive through the same `verify_archive` checks import runs, and
deletes the file if they fail. This closes a whole bug class rather than one bug:
a backup tool that reports success for an archive it would itself reject converts
a silent export-time defect into total backup loss discovered at restore time.
The concrete instance was symlinks — `verify` refuses a non-regular payload
member, while `--with-artifacts` copied `data/` recursively and preserved the
`node_modules/.bin/` symlinks npm and playwright leave behind, so a successful
export produced an archive its own `verify` refused. Non-regular members are now
skipped at export and named in `manifest.omitted_non_regular`. They are skipped
rather than dereferenced deliberately: dereferencing would pull out-of-tree
content (a link to `/etc/passwd`) into the archive and can hang on a symlink
cycle, whereas the copy walk uses `find -P`, which neither follows a link nor
descends a symlinked directory.

Self-verification is what surfaced a second, larger defect in the same path: the
manifest's file index was passed to `jq` as a command-line argument, and Linux
caps a *single* argv string at 128K (`MAX_ARG_STRLEN`, far below total
`ARG_MAX`). Any real `--with-artifacts` export — a few hundred files is enough —
overflowed it, and `jq` died with "Argument list too long" before an archive was
written at all. The index now goes in on stdin; only small, bounded values stay
as `--arg`.

**Import will not silently overwrite newer state.** `cp -p` preserves mtime, so
the staged payload carries each file's export-time mtime; a local file newer than
the archive's copy was written *after* the export, and replacing it discards
state the archive predates. `--force` refuses those and names them, and
`--overwrite-newer` is the explicit escalation. Every replaced file is copied to
`state/backups/pre-import-<UTC>.<rand>/` before being overwritten (the random
suffix keeps two imports in the same second from sharing a directory and
clobbering the first one's only copy), and `--dry-run` reports the whole plan
without writing. This bounds, but does not eliminate, the cost of importing a
stale archive: `state/repos.json` is replaced wholesale, so a repo registered
after the export disappears from the registry while its `.dm/` sidecar stays
orphaned on disk. What is lost is the metadata that *finds* work, never the work
itself — `state/worktrees/` is never written, so committed-unlanded work survives
on disk regardless.

**Secrets.** An export changes who can read the state. The archive carries the
DOCKMASTER-ONLY store (`repos/<repo>/.dm/private.md`) — which exists precisely so
its contents are never relayed to a crewmate — plus operator preferences and,
with `--with-artifacts`, briefs and scout reports. It also discloses the
exporting machine's directory layout: `manifest.source_home` and the `worktree`
paths in task records are absolute. That is deliberate, because a restore needs
them to report what is missing, but the consequence is that the archive is
OPERATOR-PRIVATE — a backup for its owner, not something to share, attach to an
issue, or hand to a third party. It is written mode 0600 and should be stored
encrypted and treated as a secret. `.env` is never included.

Integrity is checked before anything is installed. The manifest must describe the
payload as an exact SET of paths — duplicates refuse, and a path present in one
and not the other refuses, naming the difference. (Comparing counts instead would
let one duplicated entry mask exactly one unlisted, never-checksummed file.) Any
checksum mismatch, unknown format, non-regular payload member (a symlink is
otherwise invisible to a regular-file scan), or path outside `state/`, `data/`,
`repos/<repo>/.dm/` refuses. Extraction runs before validation and relies on
`tar` rejecting absolute and `..` member paths — GNU tar and bsdtar both do —
after which every installed file is taken from the verified manifest list rather
than from whatever landed on disk.

## Supervision model

There is no daemon. The dockmaster creates a background worker, records its
runtime id beside durable task state, and resumes other work. Runtime-native
completion/mailbox events wake the dockmaster; it reconciles real state before
advancing. CI and deploy waits use the bounded toolbelt wait during an active
session or a scheduled task for long-running/recurring work.

"Check up on them" uses the runtime adapter's list/message controls plus
`bin/dm-task.sh state`. "Report back" surfaces outcomes, never mechanics.

## Concurrency & worktrees

Independent work dispatches in bounded waves within runtime capacity. Durable
thread name is recorded before spawn; returned runtime id is recorded before the
backlog item moves to in-flight. Codex keeps three of six slots available for
approval, recovery, and review work.
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
.dm-knowledge/           this repo's own committed shared-memory notes
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

This distro is itself a managed repo: its own shared memory is the committed
`.dm-knowledge/` note files. Its `AGENTS.md` no longer carries a `dm:knowledge`
block — that migration is finished here (#129), and `AGENTS.md` keeps only the
operating contract plus an index into the notes. Recall still unions the legacy
block for managed repos that have not migrated, so nothing is stranded.

`state/`, `repos/`, `data/`, and `.env` are operator-private and gitignored. The
tracked surface (`AGENTS.md`, `bin/`, both runtime adapters, `.codex/`,
`workflows/`, `config/` defaults, docs) is the shared distro and ships through
this repo's own PR path.

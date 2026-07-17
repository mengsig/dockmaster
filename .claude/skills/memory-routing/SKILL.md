---
name: memory-routing
description: Where durable knowledge goes — per-repo facts to contextgraph inside that repo, operator/fleet facts to manhandler global memory, task notes to the backlog, findings to the scout report. Load before persisting knowledge or when sweeping a session for durable facts.
---

# memory-routing

Every durable fact has exactly one owner. Routing it to the most specific owner
keeps a single source of truth that cannot drift. There are two tiers.

## Per-repo memory — contextgraph, TRACKED in each managed repo

Facts about **one repo**: build/test commands, invariants, conventions,
pitfalls, routing hints, decisions.

Per-repo memory is **committed in the repo's own `.contextgraph/`** (plus file
sidecars), so git materializes it in every worktree and clone and recall works
for crewmates. It travels with the repo. It is delivered through the normal
PR/land flow, never force-committed onto a clone's default branch.

- **Onboarding:** `bin/mh-repo.sh init-memory <repo>` initializes contextgraph in
  a worktree and delivers it — a PR you approve (or a local fast-forward for
  `local-only` repos). `bin/mh-repo.sh add` runs this by default.
- **Recall before working** — bounded and task-relevant, never the whole store.
  The manhandler and scouts may recall against the read-only clone; crewmates
  recall in their worktree:
  ```
  contextgraph recall --query "<the task in a sentence>" --file <path you'll touch>
  ```
- **Remember happens in a worktree and is committed with the change.** A crewmate
  persists one atomic fact and `git add`s the `.contextgraph/` change (and any
  `.<file>.md` sidecar) so it lands with the PR and travels:
  ```
  contextgraph remember file <path> --key <slug> --kind <command|convention|decision|invariant|pitfall|routing> \
    --source verified --fact "<fact>" --reason "<why it matters, >= 8 chars>" --evidence <path>
  ```
  Use `remember repo` for a cross-cutting repo fact; reuse a key with `--replace`
  when a fact changes. The manhandler does **not** `remember` directly in a
  read-only clone (that would leave uncommitted changes it cannot land) — a scout
  records durable repo facts in its report, and the next ship task commits them.

## Global memory — the manhandler home

Facts about the **operator** or the **fleet as a whole**, not tied to one repo.

- `memory/` (native Claude Code file memory, indexed by `MEMORY.md`) — operator
  identity, standing preferences and feedback, cross-repo project state.
- `state/operator.md` — the operator's working style and preferences, curated.
- `state/learnings.md` — fleet-wide operational facts and gotchas (dated,
  evidence-backed, pruned).
- The manhandler repo's own `.contextgraph/` — facts about *this distro's* code.

## Task- and finding-scoped

- Task-scoped notes → the backlog item (`state/backlog.md`).
- Investigation findings → the scout report `data/<id>/report.md`.
- Undone next steps → a queued backlog item, blocked if dependent.

## The routing table

| Fact is about… | Owner |
| --- | --- |
| one managed repo | that repo's contextgraph |
| this distro's own code | this repo's `.contextgraph/` |
| the operator (prefs, style) | `state/operator.md` + native `memory/` |
| the fleet as a whole | `state/learnings.md` |
| a single task | the backlog item |
| an investigation | the scout report |

## Discipline

- **Inspect then update.** Read the destination first; rewrite the entry it
  supersedes rather than appending forever. Prune stale facts.
- **One fact per entry.** Atomic, evidence-backed, non-obvious.
- **Never** store secrets, transient failures, task status, plans, or code
  excerpts. **Never** route knowledge into a skill — skills are instructions,
  not a memory sink.
- Save progressively, at each durable discovery — not in one end-of-session
  sweep. (The `/stow` habit: before a reset, sweep for uncaptured durable
  knowledge and route each item by this table.)

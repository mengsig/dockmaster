---
name: memory-routing
description: Where durable knowledge goes — per-repo shared facts to the repo's AGENTS.md dm:knowledge section, per-repo private notes to repos/<repo>/.dm, operator/fleet facts to dockmaster global memory, task notes to the backlog, findings to the scout report. Load before persisting knowledge or when sweeping a session for durable facts.
---

# memory-routing

Every durable fact has exactly one owner. Routing it to the most specific owner
keeps a single source of truth that cannot drift. Memory is plain markdown —
readable, diffable, hand-editable — driven by `bin/dm-memory.sh` (no bespoke
tool). There are three stores.

## Per-repo SHARED — the repo's own `AGENTS.md` dm:knowledge section

Contributor-relevant facts about **one repo**: build/test commands, invariants,
conventions, pitfalls, routing hints, decisions.

They live in a dockmaster-managed section of the repo's own `AGENTS.md`,
delimited by exact markers:

```
<!-- dm:knowledge:start -->
## Repository knowledge (dockmaster-maintained)
...
- **[command]** ...
- **[convention]** ...
<!-- dm:knowledge:end -->
```

It is **committed**, so git materializes it in every clone and worktree and
crewmates get it for free. The dockmaster **never hand-writes** a managed repo's
AGENTS.md (prime directive): a crewmate edits this section **in its worktree** and
commits it with the work, exactly like any other change — it lands through the
normal PR/local flow, never force-committed onto a clone's default branch.

- **Onboarding:** `bin/dm-repo.sh seed <repo>` scaffolds the git-excluded private
  store below; `bin/dm-repo.sh add` runs it by default. `seed` never touches the
  clone's AGENTS.md — the shared section is added by a crewmate in a worktree,
  which keeps the clone pristine (landable and fast-forward-syncable).
- **Recall:** `bin/dm-memory.sh recall <repo> [query]` prints the section (plus
  private notes), filtered by an optional query. Bounded and task-relevant — the
  crewmate brief injects this automatically so a crewmate needs no tool call.
- **Remember:** edit the `dm:knowledge` section as one curated
  `- **[<kind>]** <fact>` bullet and commit it. Rewrite a superseded fact; do not
  append forever. `<kind> ∈ {command, convention, invariant, pitfall, routing,
  decision}`.

## Per-repo PRIVATE — `repos/<repo>/.dm/notes.md`

Per-repo orchestration context that must **not** enter the user's project
history: routing, per-repo operator preferences, strategy. It is git-excluded via
the clone's `.git/info/exclude`, so it never shows as untracked or gets committed.

```
bin/dm-memory.sh remember <repo> --private --kind <kind> "<fact>"
```

`recall <repo>` prints it alongside the shared knowledge, and **it is relayed
into every crewmate brief** for the worker's awareness (the brief tells the
worker not to copy it into the repo's history). So it is *private to the project
history*, not private from the crew — do **not** put a secret or anything a
crewmate must never see here. Curate with `bin/dm-memory.sh forget <repo>
--private <substring>`.

## Per-repo DOCKMASTER-ONLY — `repos/<repo>/.dm/private.md`

The truly orchestrator-private store, also git-excluded: sensitive routing the
crew must **not** see. `recall <repo>` shows it to the dockmaster, but
`bin/dm-brief.sh` recalls with `--crew` and **excludes** it, so it never reaches
a crewmate brief.

```
bin/dm-memory.sh remember <repo> --dockmaster-only --kind <kind> "<fact>"
bin/dm-memory.sh forget   <repo> --dockmaster-only <substring>
```

Still never write a raw secret value in any store — pass a reference
(credential-handoff), never the value.

## Global — the dockmaster home

Facts about the **operator** or the **fleet as a whole**, not tied to one repo.

- `state/operator.md` — the operator's working style and preferences, curated.
- `state/learnings.md` — fleet-wide operational facts and gotchas (dated,
  evidence-backed, pruned). Append with
  `bin/dm-memory.sh remember --global --kind <kind> "<fact>"`.
- `memory/` — Claude Code native file memory (operator identity, standing
  feedback, cross-repo state), indexed by `MEMORY.md`.
- This distro's own repo knowledge lives in **this repo's** `AGENTS.md`
  `dm:knowledge` section (it is itself a managed repo).

Recall both global files with `bin/dm-memory.sh recall --global [query]`.

## Task- and finding-scoped

- Task-scoped notes → the backlog item (`state/backlog.md`).
- Investigation findings → the scout report `data/<id>/report.md`.
- Undone next steps → a queued backlog item, blocked if dependent.

## The routing table

| Fact is about… | Owner |
| --- | --- |
| one managed repo, contributor-relevant | that repo's `AGENTS.md` dm:knowledge section |
| one managed repo, orchestration (crew may see) | `repos/<repo>/.dm/notes.md` |
| one managed repo, crew must NOT see | `repos/<repo>/.dm/private.md` |
| this distro's own code | this repo's `AGENTS.md` dm:knowledge section |
| the operator (prefs, style) | `state/operator.md` + native `memory/` |
| the fleet as a whole | `state/learnings.md` |
| a single task | the backlog item |
| an investigation | the scout report |

## Discipline

- **Inspect then update.** Read the destination first; rewrite the entry it
  supersedes rather than appending forever. Prune stale facts. In the two
  tool-writable stores (private, dockmaster-only, global), `remember` warns on a
  duplicate fact body and `forget <…> <substring>` removes matching bullets —
  use them to curate rather than let the store drift.
- **One fact per entry.** Atomic, evidence-backed, non-obvious.
- **Never** store secrets, transient failures, task status, plans, or code
  excerpts. **Never** route knowledge into a skill — skills are instructions,
  not a memory sink.
- Save progressively, at each durable discovery — not in one end-of-session
  sweep. Before a reset, sweep for any uncaptured durable knowledge and route
  each item by this table.

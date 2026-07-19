---
name: secondmate
description: Stand up a persistent domain supervisor — a long-lived background agent that owns a repo or family of repos, keeps its own memory, and spawns its own crewmates. Load before creating, addressing, or retiring a domain supervisor.
---

# secondmate (domain supervisor)

For a large or long-running domain, the dockmaster can delegate to a
**persistent domain supervisor**: a long-lived background agent that owns a
scope, keeps its own memory, and runs its own crew. It is an ordinary direct
report of the dockmaster — a second *level*, not a second architecture.

## When to create one

- A domain with sustained, ongoing work (one big repo, or a family of related
  repos) where re-establishing context every session is wasteful.
- Clear scope boundaries so routing is unambiguous.

Do not create one for a single task or for `local-only` work — keep that in the
main home.

## Model on Codex

A domain supervisor is a **named Codex subagent thread** created with
`spawn_agent(..., fork_turns="none")`. Address it with `send_message` while it is
running and `followup_task` when it is idle. It can itself use `spawn_agent` for
crewmates, so delegation nests one level. Project config sets
`agents.max_depth = 2`: root (0) → secondmate (1) → worker (2).

Give it, in its spawn brief:
- its **scope** in plain language (what work routes to it);
- the repos it owns (registry names) and the fact that it works only in
  worktrees off those clones, never their primary checkout;
- the same lifecycle, memory-routing, and PR conventions the dockmaster follows
  (point it at these skills);
- its **return channel**: it reports outcomes back through its parent thread,
  never to the operator directly.

Record the supervisor in `state/secondmates.md`: its agent id, scope, and repo
list. That file is the routing table; the scope drives routing, and the repo
list is provisioning data, not exclusive ownership.

## Routing to it

Route a request by matching its nature against each supervisor's scope, with
judgment — not by a mechanical repo lookup. Send in-scope work to the fitting
supervisor unless it is blocked or the operator redirects. Route new work with
`followup_task`; use the returned summary rather than reading its internal chat
to reconstruct the answer.

## Memory

A domain supervisor keeps domain-local memory: per-repo facts in each repo's
`AGENTS.md` `dm:knowledge` section and private `.dm/` notes (shared, since it uses
the same clones), and domain-level operating notes in its own working notes.
Operator preferences that should reach every domain live in the main home's global
memory and are conveyed to the supervisor when it is created or when they change.

## Idle and retire

A domain supervisor is **idle by default** and acts only on routed work. An
empty queue is healthy — it never self-initiates surveys or audits. Codex thread
identity is not guaranteed to survive a host restart; durable scope and work
remain in `state/secondmates.md` and task/worktree state, and recovery relaunches
the same scope only after proving the prior thread is gone. Retire one only on an
explicit decision and with no in-flight work: `interrupt_agent` the specific
thread if active, confirm no unlanded work remains, then remove its entry.
Forced discard of unlanded work requires explicit operator authority.

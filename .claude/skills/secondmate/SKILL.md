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

## Model on Claude Code

A domain supervisor is a **named, long-lived background agent** (spawn with a
persistent identity; keep it alive). It is addressed with `SendMessage` to its
agent id. It can itself use the Agent tool to spawn crewmates for its domain, so
delegation nests one level.

Give it, in its spawn brief:
- its **scope** in plain language (what work routes to it);
- the repos it owns (registry names) and the fact that it works only in
  worktrees off those clones, never their primary checkout;
- the same lifecycle, memory-routing, and PR conventions the dockmaster follows
  (point it at these skills);
- its **return channel**: it reports outcomes back to the dockmaster via
  `SendMessage`, never to the operator directly.

Prepare the supervisor through the locked state owner before launch:

```
thread_name="$(bin/dm-thread-name.sh <id> secondmate)"
bin/dm-secondmate.sh prepare <id> --scope "<scope>" --repos "<repo,...>" \
  --thread-name "$thread_name"
```

Start that exact identity and immediately persist its returned runtime id with
`bin/dm-secondmate.sh attach <id> <returned-agent-id>`. If persistence fails,
stop that exact agent and leave the launching record visible. Never hand-edit
`state/secondmates.json`; it is the routing table and the script is its locked,
atomic owner.

## Routing to it

Route a request by matching its nature against each supervisor's scope, with
judgment — not by a mechanical repo lookup. Send in-scope work to the fitting
supervisor unless it is blocked or the operator redirects. A supervisor's routed
reply comes back through `SendMessage`; do not read its internal chat to find
the answer.

## Memory

A domain supervisor keeps domain-local memory: per-repo facts in each repo's
`AGENTS.md` `dm:knowledge` section and private `.dm/` notes (shared, since it uses
the same clones), and domain-level operating notes in its own working notes.
Operator preferences that should reach every domain live in the main home's global
memory and are conveyed to the supervisor when it is created or when they change.

## Idle and retire

A domain supervisor is **idle by default** and acts only on routed work. An
empty queue is healthy — it never self-initiates surveys or audits. At startup,
run `bin/dm-secondmate.sh reconcile`; match each saved runtime id/name against
the live agent list before any relaunch. One match is reused, multiple matches or
a `launching` record block as ambiguous. After proving an unowned launching
record has no live match, resolve it with `bin/dm-secondmate.sh abandon <id>
--confirmed-no-live`; clear an active saved owner only after proving it gone.
Retire only on an explicit
decision and with no in-flight work: stop the exact agent, confirm no unlanded
work, then `bin/dm-secondmate.sh retire <id> --confirmed-idle`. Forced discard
of unlanded work requires explicit operator authority.

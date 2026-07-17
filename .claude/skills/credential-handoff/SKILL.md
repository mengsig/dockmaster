---
name: credential-handoff
description: Get a secret to a crewmate that needs one without ever writing the value into memory, a brief, a commit, task meta, the backlog, a log, or a lavish artifact. Load when a crewmate needs a credential to do its task.
---

# credential-handoff

This operationalizes the "a needed credential" escalation in AGENTS.md
§Reporting. A crewmate sometimes needs a secret (API token, deploy key,
password) to do its task. The value never enters anything the fleet persists or
renders — only a **reference** to it travels.

## Where a secret may never go

Never write a secret value into: any memory store (a repo's `mh:knowledge`
section, `.mh/` private notes, or global memory), a brief, a commit, task meta,
the backlog, a log, or a lavish artifact. (`memory-routing` already forbids
storing secrets — this is the same rule at the boundary.)

## The handoff

1. The operator supplies the secret **out-of-band** — an env var in the
   operator's shell, or a file outside version control (e.g. `.env`, which is
   gitignored; verify it is before relying on it).
2. The manhandler passes a **reference** into the brief — the env var name or the
   file path — never the value.
3. The crewmate reads it at runtime from that reference and uses it; it does not
   echo, log, or persist it.

## If a secret leaks

A secret that lands in a commit, a log, or any persisted artifact is a **security
incident**, not a cleanup task. Stop, tell the operator immediately, and have
them rotate the credential. Removing the commit does not un-expose the value.

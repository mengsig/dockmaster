---
name: project-management
description: Add, initialize, configure, and remove the repositories the manhandler operates on. Load before onboarding a repo, changing its delivery mode, or removing it.
---

# project-management

A request to create or build a brand-new project is manhandler work: `create` it
under `repos/` (below) and deliver it via `task-lifecycle`. Never build it as a
standalone directory outside the framework, and never hand-edit its files — a new
repo is enrolled here first, then every change goes through a crewmate worktree.

The registry `state/repos.json` is the single source of truth for what is
managed. Every managed repo is cloned once under `repos/<name>` (read-only to
the manhandler; crews work in worktrees off it) and gets its per-repo memory
scaffolded with `bin/mh-memory.sh seed` (see the `memory-routing` skill).

## Add a repo

```
bin/mh-repo.sh add <name> <remote> [--mode pipeline|direct-pr|local-only] \
  [--test-cmd "<cmd>"] [--branch <default>] [--no-memory]
```

This clones the repo, resolves its default branch, registers it (`mode=pipeline`,
`yolo=false` by default), and scaffolds the repo's git-excluded private memory
store via `seed` (below). The shared `AGENTS.md` `mh:knowledge` section is added
later by a crewmate in a worktree.

- Only clone a remote the operator actually named. Never invent a remote.
- Set `--test-cmd` so the `tests` gate has a command to run; without it the
  pipeline's tests gate is a declared soft-skip, not a fake pass.
- Choose the delivery mode deliberately:
  - **pipeline** — full gated PR flow (default; highest assurance).
  - **direct-pr** — crewmate opens a PR without the gate pipeline (faster).
  - **local-only** — never pushes; lands via guarded local fast-forward.

## Create a brand-new repo

`add` clones an **existing, populated** remote. When the operator wants a repo
that does not exist yet — "make me a repo called X", or "I created an empty
GitHub repo, wire it up" — use `create`:

```
bin/mh-repo.sh create <name> [<remote>] [--mode M] [--test-cmd "<cmd>"] \
  [--branch <default>] [--public|--private] [--https] [--description D] [--no-memory]
```

- **No remote given** → creates the GitHub repo via `gh-axi` (default
  `--private`; pass `--public` to publish), then wires it up. Requires GitHub
  auth. The git remote defaults to SSH (`git@github.com:…`); pass `--https` for
  an HTTPS origin.
- **Remote given** → the operator already made the repo. It must be **empty**;
  `create` refuses a remote that already has branches and points you at `add`.

Either way it initializes `repos/<name>` with one commit (a minimal `README.md`)
so the repo has a default branch and a base for worktrees, sets `origin` as the
upstream, publishes, registers it (same defaults as `add`), and seeds per-repo
memory. This publish is the repo-initialization write sanctioned for
`mh-repo.sh`; it never forces and never touches an existing clone.

- Confirm the visibility with the operator before creating a **public** repo —
  publishing is outward-facing and hard to reverse.
- Only name a remote the operator actually gave. Never invent one.

## Onboarding scout (optional)

`add`/`create` leave two things unbootstrapped: with no `test_cmd` the tests gate
is a permanent soft-skip (see `testing-policy`), and the repo's SHARED
`mh:knowledge` section starts empty. To seed both, you MAY dispatch an
**onboarding scout** right after onboarding — an ordinary read-only scout task
over the fresh clone (classify it `--kind scout` per `task-lifecycle`; no new
machinery). It is optional: the operator can skip it and configure both by hand.

The scout reads the clone (package-manager files, CI config, Makefile, existing
test dirs) and **reports** — it never changes the clone:

- a proposed `test_cmd`. You apply it on the operator's word with
  `bin/mh-repo.sh set <repo> test_cmd '<cmd>'`; surface the proposal, never
  auto-apply it silently.
- a proposed initial `mh:knowledge` section (build/test, conventions,
  invariants, pitfalls). Committing it is a **separate, gated task**: a crewmate
  writes the section in a worktree and lands it through the normal PR/local flow
  (`memory-routing`). The manhandler **never** hand-writes a managed repo's
  `AGENTS.md` (prime directive) — the scout only proposes the text.

The report is evidence, not authorization: the scout stays strictly read-only,
and each follow-up (apply the command, commit the section) is a distinct step on
the operator's word.

## Configure a repo

```
bin/mh-repo.sh set <name> mode pipeline|direct-pr|local-only
bin/mh-repo.sh set <name> yolo true|false        # standing routine-merge autonomy
bin/mh-repo.sh set <name> test_cmd "<cmd>"
bin/mh-repo.sh set <name> pipeline <config-name>  # points at config/pr-pipeline.<name>.json
```

Delivery **mode** and **yolo** are orthogonal: mode is *how work lands*, yolo is
*how much routine confirmation the manhandler skips*. Yolo never authorizes
destructive, irreversible, or security-sensitive actions.

## Per-repo memory

`bin/mh-repo.sh seed <name>` scaffolds the repo's git-excluded private store
(`repos/<name>/.mh/`) in the clone. It is idempotent and never touches the clone's
`AGENTS.md`, so the clone stays pristine (landable and fast-forward-syncable). The
SHARED `mh:knowledge` section is authored by a crewmate in a worktree and
committed with its work, so it travels to every clone and worktree. Route
knowledge with the `memory-routing` skill. The committed `mh:knowledge` section
holds facts useful to *every* contributor; keep fleet-private strategy in the
private store, never in the committed section.

## Keep clones fresh

A managed clone must stay fast-forwarded to origin so every worktree branches
off fresh `main` — see the `repo-sync` skill for the freshness contract (the
`bin/mh-sync.sh` mechanic, when it runs automatically, and when to run it by
hand).

## Remove a repo

```
bin/mh-repo.sh remove <name>
```

Fails closed if the clone has uncommitted changes or active worktrees — resolve
those first. It only unregisters and leaves the clone on disk; deleting the
clone directory is a separate, deliberate step.

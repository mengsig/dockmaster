---
name: project-management
description: Add, initialize, configure, and remove the repositories the manhandler operates on. Load before onboarding a repo, changing its delivery mode, or removing it.
---

# project-management

The registry `state/repos.json` is the single source of truth for what is
managed. Every managed repo is cloned once under `repos/<name>` (read-only to
the manhandler; crews work in worktrees off it) and gets per-repo contextgraph
memory.

## Add a repo

```
bin/mh-repo.sh add <name> <remote> [--mode pipeline|direct-pr|local-only] \
  [--test-cmd "<cmd>"] [--branch <default>] [--no-memory]
```

This clones the repo, resolves its default branch, registers it (`mode=pipeline`,
`yolo=false` by default), and delivers **tracked** contextgraph memory via
`init-memory` (below) so per-repo context travels with the repo and reaches
crewmates in their worktrees.

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
upstream, publishes, registers it (same defaults as `add`), and delivers
contextgraph memory. This publish is the repo-initialization write sanctioned for
`mh-repo.sh`; it never forces and never touches an existing clone.

- Confirm the visibility with the operator before creating a **public** repo —
  publishing is outward-facing and hard to reverse.
- Only name a remote the operator actually gave. Never invent one.

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

`bin/mh-repo.sh init-memory <name>` initializes contextgraph in a worktree and
delivers it as **tracked** repo content: a PR you approve, or a local
fast-forward for `local-only` repos. It is idempotent — a no-op once memory is
already tracked. This is what makes recall work for crewmates in their worktrees.
Route knowledge with the `memory-routing` skill. The repo's own committed
`AGENTS.md` (authored by a crewmate through the delivery path, never hand-written
by the manhandler) holds knowledge useful to *every* contributor; keep
fleet-private strategy out of it.

## Keep clones fresh

`bin/mh-sync.sh all` fast-forwards every clean clone on its default branch and
reports anything unsafe as `STUCK:` (left untouched — never merged, rebased, or
reset). Run it at session start and after a PR merges.

## Remove a repo

```
bin/mh-repo.sh remove <name>
```

Fails closed if the clone has uncommitted changes or active worktrees — resolve
those first. It only unregisters and leaves the clone on disk; deleting the
clone directory is a separate, deliberate step.

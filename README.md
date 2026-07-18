<p align="center"><img src="assets/dockmaster.png" alt="dockmaster" width="720"></p>

# dockmaster

**Talk to one agent. Ship across every repo.**

> v0.2.0 · MIT licensed · built for [Claude Code](https://claude.com/claude-code)

[![CI](https://github.com/mengsig/dockmaster/actions/workflows/ci.yml/badge.svg)](https://github.com/mengsig/dockmaster/actions/workflows/ci.yml)

*The Dockyard.* You are the captain; the dockmaster is your dockmaster — it never
handles cargo itself, but directs a crew of dockhands (crewmates) working in the
holds, hoisting cargo aboard the ships of your fleet, and reports back to you. See
[the theme note](docs/architecture.md#the-dockyard) for the full mapping.

dockmaster is an *agent distro* for Claude Code: a portable directory of
instructions, skills, and helper scripts that turns a Claude Code session into a
fleet handler. You talk to a single agent — the **dockmaster** — and it runs a
crew of autonomous subagents across all of your repositories: spawning each in
its own clean git worktree, supervising them to completion at zero idle token
cost, and handing you finished PRs, approved local merges, or investigation
reports.

It is built natively for Claude Code — no bash daemon, no terminal multiplexer.
Rather than *simulating* asynchronous supervision on a generic harness, dockmaster
uses Claude Code's native primitives — background agents, task-completion
notifications, worktree-isolated subagents, Monitor, and cron — which do the job
with less machinery and no polling. See
[docs/architecture.md](docs/architecture.md) for the full concept→primitive map.

## What it does

- **One liaison.** You talk only to the dockmaster; it delegates, supervises, and
  reports outcomes — never mechanics.
- **A crew in worktrees.** Every task runs in its own disposable git worktree, so
  parallel work on one repo never collides.
- **Two task shapes.** *Ship* delivers a change (PR or approved local merge);
  *scout* investigates and leaves a report — a diagnosis is never an
  authorization to implement.
- **Per-repo + global memory.** Memory is plain markdown, no bespoke tool: each
  managed repo's shared knowledge lives in an `dm:knowledge` section of its own
  `AGENTS.md` (committed, so it travels and reaches crewmates in every worktree),
  with dockmaster-private notes in a git-excluded `.dm/`; operator and fleet-wide
  knowledge live in the dockmaster's global memory. One owner per fact.
- **Lavish approval, then modular PR pipelines.** Every change is first rendered
  as a lavish artifact you approve (with back-and-forth); then you choose PR or
  local. (The artifact needs the optional `lavish-axi`; without it you approve
  the change directly — see Requirements.) On the PR path, delivery is an
  ordered list of named gates — two review
  passes (coldstart → fix+tests → merge-gate → fix+tests) then PR — declared per
  repo in one JSON array you can reorder. Branches follow `<type>/<issue>/<slug>`;
  descriptions are short and human; nothing merges without your word.
- **Zero-token supervision.** Crewmates run as background agents; a completion
  notification is the wake. Nothing polls while work is in flight.
- **Guarded by construction.** The dockmaster is read-only over your repos except
  for narrow, guarded fast-forward paths. Teardown refuses to discard unlanded
  work. Nothing merges red or without your word.
- **Fleet campaigns.** One intent that spans many repos ("bump this dependency
  everywhere") fans out to one ordinary, gated child task per repo, tracked and
  reported as a single campaign.
- **Fleet PR/health sweep.** A read-only sweep across every open PR reports its
  CI rollup and whether a reviewer requested changes, surfaced in the status
  snapshot — no per-repo polling.
- **CI on every push and PR.** This distro's own smoke suite and syntax/lint
  checks run on GitHub Actions across ubuntu and macOS on every push to main and
  every pull request.
- **Persistent domain supervisors.** For large domains, delegate to a long-lived
  agent that owns a scope, keeps its own memory, and runs its own crew.

## Layout

```
AGENTS.md            the dockmaster's operating contract (CLAUDE.md includes it)
docs/architecture.md the design and why it is built this way
bin/                 the toolbelt; run `bin/dm help` for the full list (`bin/dm <sub>` dispatches to `bin/dm-<sub>.sh`)
.claude/skills/      skills loaded at their trigger points
workflows/           optional deterministic PR-pipeline runner
config/              PR-pipeline defaults and per-repo overrides
tests/               tests/smoke.sh, the end-to-end regression check
.github/             CI workflow (smoke + syntax on ubuntu + macos)
CONTRIBUTING.md      how to test, portability rules, branch/commit style
SECURITY.md          trust model and private vulnerability reporting
LICENSE              MIT
assets/              logo and theme assets
state/ repos/ data/  operator-private runtime, clones, and artifacts (gitignored)
```

## Getting started

1. **Clone** this repository and `cd` into it.
2. **Run `bin/dm-doctor.sh`** — it checks your tools and GitHub auth and
   scaffolds the runtime layout (`state/`, `data/`, `repos/`).
3. **Launch Claude Code** in the repo root — `CLAUDE.md` pulls in `AGENTS.md`,
   which activates the dockmaster persona.
4. **Ask it to add a repo** and give it work (see Quick start).

## Quick start

```sh
# from a Claude Code session started in this directory:
> add my repo git@github.com:me/app.git and fix the flaky login test in #412
```

The dockmaster registers the repo (cloning it and seeding its memory) and spawns
a crewmate in a fresh worktree. It pauses for your approval of the change and
your PR-or-local choice before opening anything, then runs the PR pipeline and
comes back with:

```
PR ready for review: https://github.com/me/app/pull/57
(fix flaky login test — risk: low — tests green)

> merge it
```

Under the hood that is `bin/dm-repo.sh add` (running the onboarding scout to
propose a test command and starter knowledge for a repo new to the fleet),
`bin/dm-task.sh new`, `bin/dm-worktree.sh create`, the `pr-workflow` skill, and
`bin/dm-pr.sh merge` — each usable directly, or through the `bin/dm` dispatcher
(`dm <sub> ...` runs `bin/dm-<sub>.sh ...`; `dm help` lists the subcommands).
Run any script with no arguments for its usage.

## Requirements

Supported platforms: macOS and Linux; the scripts run on bash 3.2+.

- **Required for anything:** Claude Code, `git`, and `jq`.
- **Required for the PR flow:** the GitHub CLI `gh`, authenticated with
  `gh auth login` (or the `gh-axi` wrapper below). Without it the dockmaster
  still runs in local-only mode — approved fast-forward landing, no PR.
- **Optional enhancements — the operator's own tooling, not bundled with this
  distro:** `gh-axi` (ergonomic GitHub wrapper), `lavish-axi` (the reviewable
  approval artifact), and `chrome-devtools-axi` (browser tasks). Without them
  the dockmaster degrades to a real, plainer mode: plain `gh` for GitHub, and
  you review and approve each change directly rather than through a lavish
  artifact.

Per-repo memory is plain markdown — no extra tool to install. Run
`bin/dm-doctor.sh` to see what you have and what each tool gates.

## License

MIT — see [LICENSE](LICENSE). Changelog in [CHANGELOG.md](CHANGELOG.md).

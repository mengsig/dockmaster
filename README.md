# manhandler

**Talk to one agent. Ship across every repo.**

> v0.2.0 · MIT licensed · built for [Claude Code](https://claude.com/claude-code)

manhandler is an *agent distro* for Claude Code: a portable directory of
instructions, skills, and helper scripts that turns a Claude Code session into a
fleet handler. You talk to a single agent — the **manhandler** — and it runs a
crew of autonomous subagents across all of your repositories: spawning each in
its own clean git worktree, supervising them to completion at zero idle token
cost, and handing you finished PRs, approved local merges, or investigation
reports.

It re-implements the ideas proven by [firstmate](https://github.com/kunchenguid/firstmate),
but built natively for Claude Code instead of on bash + a terminal multiplexer.
Where firstmate builds a shell daemon to *simulate* asynchronous supervision on
generic harnesses, manhandler uses Claude Code's native primitives — background
agents, task-completion notifications, worktree-isolated subagents, Monitor, and
cron — which do the same job with less machinery and no polling. See
[docs/architecture.md](docs/architecture.md) for the full concept→primitive map.

## What it does

- **One liaison.** You talk only to the manhandler; it delegates, supervises, and
  reports outcomes — never mechanics.
- **A crew in worktrees.** Every task runs in its own disposable git worktree, so
  parallel work on one repo never collides.
- **Two task shapes.** *Ship* delivers a change (PR or approved local merge);
  *scout* investigates and leaves a report — a diagnosis is never an
  authorization to implement.
- **Per-repo + global memory.** Memory is plain markdown, no bespoke tool: each
  managed repo's shared knowledge lives in an `mh:knowledge` section of its own
  `AGENTS.md` (committed, so it travels and reaches crewmates in every worktree),
  with manhandler-private notes in a git-excluded `.mh/`; operator and fleet-wide
  knowledge live in the manhandler's global memory. One owner per fact.
- **Lavish approval, then modular PR pipelines.** Every change is first rendered
  as a lavish artifact you approve (with back-and-forth); then you choose PR or
  local. On the PR path, delivery is an ordered list of named gates — two review
  passes (coldstart → fix+tests → merge-gate → fix+tests) then PR — declared per
  repo in one JSON array you can reorder. Branches follow `<type>/<issue>/<slug>`;
  descriptions are short and human; nothing merges without your word.
- **Zero-token supervision.** Crewmates run as background agents; a completion
  notification is the wake. Nothing polls while work is in flight.
- **Guarded by construction.** The manhandler is read-only over your repos except
  for narrow, guarded fast-forward paths. Teardown refuses to discard unlanded
  work. Nothing merges red or without your word.
- **Persistent domain supervisors.** For large domains, delegate to a long-lived
  agent that owns a scope, keeps its own memory, and runs its own crew.

## Layout

```
AGENTS.md            the manhandler's operating contract (CLAUDE.md includes it)
docs/architecture.md the design and the firstmate → manhandler mapping
bin/                 the toolbelt (mh-repo, mh-worktree, mh-task, mh-pr, mh-merge, mh-sync, mh-brief, mh-branch-name); `bin/mh <sub>` dispatches to any of them
.claude/skills/      skills loaded at their trigger points
workflows/           optional deterministic PR-pipeline runner
config/              PR-pipeline defaults and per-repo overrides
state/ repos/ data/  operator-private runtime, clones, and artifacts (gitignored)
```

## Quick start

```sh
# from a Claude Code session started in this directory:
> add my repo git@github.com:me/app.git and fix the flaky login test in #412
```

The manhandler registers the repo (cloning it and seeding its memory), spawns a
crewmate in a fresh worktree, runs the PR pipeline, and comes back with:

```
PR ready for review: https://github.com/me/app/pull/57
(fix flaky login test — risk: low — tests green)

> merge it
```

Under the hood that is `bin/mh-repo.sh add`, `bin/mh-task.sh new`,
`bin/mh-worktree.sh create`, the `pr-workflow` skill, and `bin/mh-pr.sh merge` —
each usable directly, or through the `bin/mh` dispatcher (`mh <sub> ...` runs
`bin/mh-<sub>.sh ...`; `mh help` lists the subcommands). Run any script with no
arguments for its usage.

## Requirements

- Claude Code, with `git` and the GitHub CLI authenticated (`gh auth login`).
- `gh-axi` and `lavish-axi` on `PATH` (the manhandler uses them for GitHub and
  review surfaces). `jq` for the registry. Per-repo memory is plain markdown —
  no extra tool to install.

## License

MIT — see [LICENSE](LICENSE). Changelog in [CHANGELOG.md](CHANGELOG.md).

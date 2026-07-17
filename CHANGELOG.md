# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning is
[SemVer](https://semver.org/).

## [0.1.0] - 2026-07-17

Initial release. manhandler is an agent distro for Claude Code that runs a crew
of autonomous subagents across many repositories from a single liaison agent.

### Added

- **Operating contract** (`AGENTS.md`) turning a Claude Code session into the
  manhandler: read-only over managed repos, delegates all project work, reports
  outcomes.
- **Toolbelt** (`bin/`): repo registry + memory onboarding (`mh-repo`), isolated
  worktrees with isolation/tangle/landed checks (`mh-worktree`), durable task
  records with on-demand state reconciliation (`mh-task`), strict PR
  open/check/merge that never merges red (`mh-pr`), guarded fast-forward local
  landing and conflict-aware rebase (`mh-merge`), fast-forward-only clone sync
  (`mh-sync`), the crewmate brief contract (`mh-brief`), the lavish review
  surface (`mh-lavish`), and branch naming `<type>/<issue>/<slug>`
  (`mh-branch-name`).
- **Skills** (`.claude/skills/`): task-lifecycle, change-review (lavish approval
  gate), pr-workflow (two-pass gate pipeline), supervision (zero-token
  background-agent supervision), memory-routing, project-management,
  merge-conflict, secondmate, diagnostic-reasoning, decision-hold, stuck-worker.
- **Delivery flow** for a requested change: crewmate implements in a worktree and
  renders a lavish review artifact → operator approves (with back-and-forth) →
  choose PR or local → on PR: coldstart review → fix + tests → merge-gate review
  → fix + tests → PR creation → merge gate.
- **Per-repo memory** via contextgraph, tracked in each managed repo so it
  travels with the repo and reaches crewmates in every worktree; global
  (operator/fleet) memory in the manhandler home.
- **Modular PR pipeline** declared as an ordered gate array
  (`config/pr-pipeline.default.json`), with an optional deterministic runner
  (`workflows/pr-pipeline.js`).

[0.1.0]: https://github.com/mengsig/manhandler-cc/releases/tag/v0.1.0

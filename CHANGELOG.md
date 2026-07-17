# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning is
[SemVer](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-07-18

### Changed

- **Per-repo memory is now native plain markdown** (`bin/mh-memory.sh`),
  replacing the third-party `contextgraph` dependency. Shared, contributor-facing
  facts live in an `mh:knowledge` section of each repo's own `AGENTS.md`
  (committed, so it travels); manhandler-private notes live in a git-excluded
  `repos/<repo>/.mh/`; global facts stay in `state/learnings.md` and
  `state/operator.md`. `mh-repo` now `seed`s this scaffold (the old `init-memory`
  subcommand and contextgraph install requirement are gone), and briefs inject the
  recalled knowledge directly. No external memory tool is required anymore.

### Added

- **`rigorous` PR-pipeline tier** (`config/pr-pipeline.rigorous.json`) for
  high-stakes changes: a **dimension-parallel** cold review (one reviewer per
  lens — correctness, security, concurrency, portability, tests), an adversarial
  **`verify-findings`** gate (N skeptics refute each finding; only findings not
  refuted by a majority survive to the fix round), then fix → tests → a
  behavioral `verify` gate → auto `security` → `await-checks` → pr. Documented
  with selection criteria in the `pr-workflow` skill and `config/README.md`, and
  implemented in the optional deterministic runner (`workflows/pr-pipeline.js`)
  via `parallel()`. Complements the existing `fast` and `default` tiers; the
  never-merge-red merge gate and lavish-approval-first ordering are unchanged.

- **`mh-repo create`**: stand up a brand-new repo. With no remote it creates the
  GitHub repo via `gh-axi` (private by default; `--public` to publish, `--https`
  for an HTTPS origin); with an empty remote you supply it wires that up instead
  (and refuses a populated remote, pointing at `add`). Either way it initializes
  `repos/<name>` with a first commit, sets the upstream, publishes, registers the
  repo, and seeds per-repo memory. Complements `add`, which clones an existing
  populated remote.

- **`mh-doctor`**: readiness check + `MH_HOME` scaffold. Owns the toolbelt's
  dependency contract (required vs recommended tools, GitHub auth) with
  actionable hints, and creates any missing home directories idempotently.
  `mh-session-start` now delegates its tooling check here so the list lives in
  one place.
- **`mh-status`**: a read-only, no-sync mid-session snapshot — managed repos
  (flagging tangled clones), in-flight tasks with an attention summary, active
  worktrees with disk use plus orphaned directories and dangling records, and
  the ready backlog with open operator decisions.
- **`mh-backlog decisions`**: lists open operator decisions (key + question) as
  a machine-readable interface for status views.

## [0.1.0] - 2026-07-17

Initial release. manhandler is an agent distro for Claude Code that runs a crew
of autonomous subagents across many repositories from a single liaison agent.

### Added

- **Operating contract** (`AGENTS.md`) turning a Claude Code session into the
  manhandler: read-only over managed repos, delegates all project work, reports
  outcomes.
- **Toolbelt** (`bin/`): a composed startup/recovery digest (`mh-session-start`),
  repo registry + memory onboarding (`mh-repo`), isolated worktrees with
  isolation/tangle/landed checks (`mh-worktree`), durable task records with
  on-demand state reconciliation (`mh-task`), a durable cross-session backlog and
  operator-decision log (`mh-backlog`), the tests gate runner (`mh-test`), strict
  PR open/check/merge that never merges red (`mh-pr`), guarded fast-forward local
  landing and conflict-aware rebase (`mh-merge`), fast-forward-only clone sync
  (`mh-sync`), the crewmate brief contract (`mh-brief`), the lavish review
  surface (`mh-lavish`), and branch naming `<type>/<issue>/<slug>`
  (`mh-branch-name`).
- **Skills** (`.claude/skills/`): task-lifecycle, change-review (lavish approval
  gate), pr-workflow (two-pass gate pipeline), supervision (zero-token
  background-agent supervision), memory-routing, project-management,
  merge-conflict, secondmate, diagnostic-reasoning, decision-hold, stuck-worker,
  and coding-guidelines (the maintainable-code commandments, baked verbatim into
  every crewmate brief and mirrored in `AGENTS.md`).
- **Claude Code integration**: `.claude/settings.json` permissions allowlist so
  the toolbelt runs without repeated prompts, and a `tests/smoke.sh` end-to-end
  regression check.
- **Delivery flow** for a requested change: crewmate implements in a worktree and
  renders a lavish review artifact → operator approves (with back-and-forth) →
  choose PR or local → on PR: coldstart review → fix + tests → merge-gate review
  → fix + tests → PR creation → merge gate.
- **Per-repo memory**, tracked in each managed repo so it travels with the repo
  and reaches crewmates in every worktree; global (operator/fleet) memory in the
  manhandler home.
- **Modular PR pipeline** declared as an ordered gate array
  (`config/pr-pipeline.default.json`), with an optional deterministic runner
  (`workflows/pr-pipeline.js`).

[0.2.0]: https://github.com/mengsig/manhandler/releases/tag/v0.2.0
[0.1.0]: https://github.com/mengsig/manhandler/releases/tag/v0.1.0

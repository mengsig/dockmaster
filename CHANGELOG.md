# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning is
[SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **Honest onboarding docs and one dependency contract.** The README and
  `mh-doctor` now state the tool contract identically in three tiers: `git`/`jq`
  required for anything, `gh` (or `gh-axi`) required for the PR flow, and the
  `gh-axi`/`lavish-axi`/`chrome-devtools-axi` axi wrappers as optional
  enhancements — the operator's own tooling, not bundled with this distro.
  Without them the manhandler runs in a real, plainer mode (plain `gh` for
  GitHub, operator-run review with no lavish artifact); a green doctor verdict
  now needs only `git`+`jq`, matching what the README promises. Added a numbered
  "Getting started" first-run path, a supported-platforms note (macOS/Linux,
  bash 3.2+), and replaced the stale hand-maintained `bin/` list with a pointer
  to `bin/mh help`.
- **Concise communication is now contract.** Reporting to the operator, and PR
  descriptions/commits/review comments, sacrifice grammar for concision.
- **Memory recall is bounded and curatable.** Briefs inject a soft-capped slice
  (with a tail pointer) of per-repo knowledge plus a fleet-wide context slice;
  recall supports multi-term OR queries; recall failures surface instead of being
  swallowed. Private notes are honestly documented as relayed to crewmates.

### Added

- **`CONTRIBUTING.md`** (how to test, the bash-3.2 portability invariant,
  branch/commit style) and **`SECURITY.md`** (trust model and private
  vulnerability reporting).
- **Fleet campaigns** — one operator intent fanned out to one gated child task
  per repo, grouped and rolled up via `mh-backlog --campaign` / `campaign` and the
  `fleet-change` skill (no directive relaxed; each child is an ordinary task).
- **Fleet PR/health sweep** — `mh-pr.sh sweep` (also a section in `mh-status`)
  reports every open PR's CI rollup and whether a review requests changes;
  read-only, offline under `MH_NO_FETCH`.
- **Repo onboarding scout** — an optional read-only scout on `add` that proposes a
  `test_cmd` and an initial `mh:knowledge` section, self-bootstrapping the tests
  gate and memory.
- **Memory curation** — a `forget` verb and a duplicate-fact warning, plus an
  optional truly-manhandler-only per-repo store excluded from crewmate briefs.
- **Resourcing policy** — the orchestrator right-sizes `model`/`effort` for every
  spawned unit (dispatch, review, verify, fix, merge-gate reasoning): the least
  power that still gets an excellent result, biased toward sufficient power when
  unsure. Not a fixed table — the orchestrator's per-task judgment, documented in
  `task-lifecycle` §3.
- **New-repo requests route through the framework** — a "make/build me a repo or
  project" request is delegated work: create/enroll it under `repos/` first
  (`mh-repo.sh create`/`add`), then dispatch normally against the enrolled repo;
  never scaffolded standalone outside the framework.
- **`repo-sync` skill + clone-freshness guards** — `mh-worktree.sh create`
  fast-forward-syncs the repo's clone before cutting a worktree's base and fails
  closed on a diverged/dirty clone instead of branching off a stale one;
  `mh-pr.sh merge` best-effort syncs the clone after a successful merge. Never
  branch off a stale base again.
- **GitHub Actions CI** — the smoke suite plus bash/JS syntax checks run on
  every push to main and every PR, matrixed across `ubuntu-latest` and
  `macos-latest` to exercise the bash-3.2 portability invariant.
- **Stacked sub-PRs (Phase 1)** — `mh-worktree.sh create --base <ref>` branches
  a child task off a parent ref instead of the default branch and records it as
  the task's `base`; `mh-pr.sh open` then defaults the child's PR base to that
  recorded parent, so a sub-PR auto-targets the parent's PR instead of main.
  Restacking after the parent moves is a manual `merge-conflict` rebase for now.

### Fixed

- **Task-state and landing-signal integrity** — `merged` events and the
  `pr`/`pr_state`/`merge_state` meta fields can no longer be forged via
  `mh-task.sh event`/`set`; `state`/`landed` refresh from GitHub so an out-of-band
  merge is seen.
- **Never merge red** — `mh-pr.sh merge` no longer treats an unreported (`none`)
  check rollup as green; it requires an explicit `--allow-no-checks`.
- **Mutex crash-safety** — a lock abandoned by a killed holder self-heals
  (dead-PID reclaim, serialized and re-verified); signal handlers clean up and
  exit rather than resuming an unlocked critical section.
- **Toolbelt hardening** — `mh-backlog` shares the single locked JSON writer,
  `mh-repo create` uses a git-version-portable init, and the PR-pipeline runner
  verifies a real PR URL before reporting success.
- **Merge-gate CI-aware loophole closed** — `--allow-no-checks` now bypasses a
  `none` (unreported) check rollup only on a repo with no CI configured; once
  `.github/workflows` exists, an unreported rollup always refuses the merge.

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

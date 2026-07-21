# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning is
[SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **`AGENTS.md` is now the contract, not the manual** (#129). Cut roughly in half
  (28680 → 12736 bytes) by retiring two blocks that did not need to be re-read on
  every session and in every crewmate brief. The commandments mirror is gone — the
  `coding-guidelines` skill is the single canonical copy, and `dm-brief.sh` already
  bakes that same file verbatim into every brief, so crewmates are unaffected; the
  main agent loads it at its trigger. The `dm:knowledge` block moved to committed
  `.dm-knowledge/` area notes (`toolbelt`, `lifecycle`, `merge-safety`,
  `runtime-and-tests`), read on demand and indexed from `AGENTS.md`. Recall still
  unions the legacy block for repos that have not migrated. The performance
  baseline is re-set to the curated size, and `base_commit` now names the change
  (`#129`) instead of a SHA that squash-merge made unresolvable on arrival.
- **Codex Lavish waits now wake reliably.** A dedicated no-fork waiter owns the
  long poll through terminal completion; its collaboration completion wakes the
  parent mailbox. Raw command sessions are explicitly attached-only, with a
  negative regression that rejects loss of the waiter wake contract. Claude's
  existing background-notification path is unchanged.
- **Honest onboarding docs and one dependency contract.** The README and
  `dm-doctor` now state the tool contract identically in three tiers: `git`/`jq`
  required for anything; `gh` required for the PR flow; `gh-axi`/`lavish-axi`/
  `chrome-devtools-axi` optional and degrading cleanly. Added a numbered
  "Getting started" first-run path, a supported-platforms note (macOS/Linux,
  bash 3.2+), and replaced the stale hand-maintained `bin/` list with a pointer
  to `bin/dm help`.

### Fixed

- **The command guard is an allowlist, and its parsers agree with each other**
  (#121). A Git subcommand is now refused unless it is named permitted, so
  unknown and future subcommands fail closed — the old denylist had silently
  permitted force-push, stash, `reflog expire`, `gc --prune`, `filter-branch`,
  `branch -D`, `update-ref -d`, and anything behind `timeout`/`nohup`/`xargs`.
  The allowlist is walked against git's real subcommand list so ordinary work
  does not discover each refusal as an incident. Closed on top of that: `&`
  inside a redirection no longer ends the segment and strands later flags;
  `--opt=value` is matched alongside the detached spelling (`--force-with-lease`
  stays permitted); config keys are matched case-insensitively and by pattern;
  a comment now ends at end of LINE rather than end of INPUT, which had
  discarded every later newline-separated command unguarded. Process
  redirection is refused in both spellings — `--exec-path`, `--git-dir`,
  `--work-tree` alongside `GIT_EXEC_PATH`, `GIT_DIR`, `GIT_WORK_TREE`, `PATH`,
  `LD_PRELOAD`, `DYLD_*` — and an unrecognized pre-subcommand option fails
  closed. `-C` is documented as a deliberate exception to that rule, not as
  coverage — it reaches another repo's config and hooks exactly as `--git-dir`
  does, but the toolbelt depends on it. The same both-spellings rule applies to
  the environment: Git falls back to plain `PAGER`, `EDITOR`, `VISUAL` and
  `SSH_ASKPASS` when the `GIT_*` twin is unset, and all four were verified
  executing a payload against git 2.54. Over-blocking fixed in the same pass:
  `git <sub> --help` is permitted, and a quoted string is classified by
  re-entering the guard rather than refused for starting with the word "git", so
  a PR body reading `--body "git log shows the bug"` is no longer collateral —
  while ` git push --force`, `env git push --force` and `timeout 5 git push
  --force` inside such a string are still refused, since re-entry runs the
  normal segmentation and wrapper handling instead of testing the first word.
  Config keys whose `.path` Git executes (the `difftool`/`mergetool`/`browser`/
  `man` tool family, plus `include.path`) are refused alongside `*.cmd`. The
  re-entry trigger consults a second table, `is_command_runner`, kept separate
  from the unwrapping table because the two fail in opposite directions —
  widening the re-entry list is safety-neutral, while widening the unwrap list
  would make the guard trust an argv it cannot see, which is exactly why `xargs`
  stays out of it. The execute-a-handed-string class is narrowed, NOT closed,
  and the guard says so rather than implying a boundary.
- **A leaked reclaim marker no longer wedges `dm_lock` recovery** (#122). The
  marker was unstamped and untrapped, so one reclaimer killed mid-reclaim made
  every later dead-PID lock hard-fail at ~30s, permanently.
- **The PR path no longer requires the maintainer's private `gh-axi` wrapper**
  (#104). `dm-pr.sh open`, `dm-pr.sh merge`, and `dm-repo.sh create` hard-failed
  without it, while the docs promised a plain-`gh` fallback that did not exist.
  All three now resolve the CLI through `dm_require_github_cli` — `gh-axi` when
  installed, plain `gh` otherwise — building per-binary argv, since the two take
  the same request differently. Reads parsed by `jq` still call `gh api`
  directly (`gh-axi api` emits YAML). `dm-doctor` stops overstating readiness:
  a bare `READY` now means the PR flow really works, and a missing or
  unauthenticated `gh` reports `READY (LOCAL-ONLY)` with the reason and the fix.
  Also fixes a silent failure in `dm-pr.sh open` — the PR-url parse aborted
  under `set -e` after the push and create had already succeeded; it now fails
  loudly and names `dm-pr.sh adopt` as the recovery.
- **Concise communication is now contract.** Reporting to the operator, and PR
  descriptions/commits/review comments, sacrifice grammar for concision.
- **Memory recall is bounded and curatable.** Briefs inject a soft-capped slice
  (with a tail pointer) of per-repo knowledge plus a fleet-wide context slice;
  recall supports multi-term OR queries; recall failures surface instead of being
  swallowed. Private notes are honestly documented as relayed to crewmates.

### Added

- **Complete OpenAI Codex runtime adapter** — all 18 workflow skills now have
  exact-name Codex discovery under `.agents/skills`, with runtime-native
  delegation, nesting, follow-up, supervision, waits, and recovery contracts.
  Trusted project config bounds depth/concurrency and adds destructive-command
  rules plus a shell-command hook guardrail. Task/thread identities stay
  separate; rigorous native and compatible-host gates fail closed. A checked
  capability matrix, adapter drift tests, private evidence paths, negative paths,
  context-performance guardrails, and installed Claude/Codex validation preserve
  the unchanged Claude path while making platform differences explicit.
- **`CONTRIBUTING.md`** (how to test, the bash-3.2 portability invariant,
  branch/commit style) and **`SECURITY.md`** (trust model and private
  vulnerability reporting).
- **Fleet campaigns** — one operator intent fanned out to one gated child task
  per repo, grouped and rolled up via `dm-backlog --campaign` / `campaign` and the
  `fleet-change` skill (no directive relaxed; each child is an ordinary task).
- **Fleet PR/health sweep** — `dm-pr.sh sweep` (also a section in `dm-status`)
  reports every open PR's CI rollup and whether a review requests changes;
  read-only, offline under `DM_NO_FETCH`.
- **Repo onboarding scout** — an optional read-only scout on `add` that proposes a
  `test_cmd` and an initial `dm:knowledge` section, self-bootstrapping the tests
  gate and memory.
- **Memory curation** — a `forget` verb and a duplicate-fact warning, plus an
  optional truly-dockmaster-only per-repo store excluded from crewmate briefs.
- **Resourcing policy** — the orchestrator right-sizes `model`/`effort` for every
  spawned unit (dispatch, review, verify, fix, merge-gate reasoning): the least
  power that still gets an excellent result, biased toward sufficient power when
  unsure. Not a fixed table — the orchestrator's per-task judgment, documented in
  `task-lifecycle` §3.
- **New-repo requests route through the framework** — a "make/build me a repo or
  project" request is delegated work: create/enroll it under `repos/` first
  (`dm-repo.sh create`/`add`), then dispatch normally against the enrolled repo;
  never scaffolded standalone outside the framework.
- **`repo-sync` skill + clone-freshness guards** — `dm-worktree.sh create`
  fast-forward-syncs the repo's clone before cutting a worktree's base and fails
  closed on a diverged/dirty clone instead of branching off a stale one;
  `dm-pr.sh merge` best-effort syncs the clone after a successful merge. Never
  branch off a stale base again.
- **GitHub Actions CI** — the smoke suite plus bash/JS syntax checks run on
  every push to main and every PR, matrixed across `ubuntu-latest` and
  `macos-latest` to exercise the bash-3.2 portability invariant.
- **Stacked sub-PRs (Phase 1)** — `dm-worktree.sh create --base <ref>` branches
  a child task off a parent ref instead of the default branch and records it as
  the task's `base`; `dm-pr.sh open` then defaults the child's PR base to that
  recorded parent, so a sub-PR auto-targets the parent's PR instead of main.
  Restacking after the parent moves is a manual `merge-conflict` rebase for now.

### Fixed

- **Task-state and landing-signal integrity** — `merged` events and the
  `pr`/`pr_state`/`merge_state` meta fields can no longer be forged via
  `dm-task.sh event`/`set`; `state`/`landed` refresh from GitHub so an out-of-band
  merge is seen.
- **Never merge red** — `dm-pr.sh merge` no longer treats an unreported (`none`)
  check rollup as green; it requires an explicit `--allow-no-checks`.
- **Mutex crash-safety** — a lock abandoned by a killed holder self-heals
  (dead-PID reclaim, serialized and re-verified); signal handlers clean up and
  exit rather than resuming an unlocked critical section.
- **Toolbelt hardening** — `dm-backlog` shares the single locked JSON writer,
  `dm-repo create` uses a git-version-portable init, and the PR-pipeline runner
  verifies a real PR URL before reporting success.
- **Merge-gate CI-aware loophole closed** — `--allow-no-checks` now bypasses a
  `none` (unreported) check rollup only on a repo with no CI configured; once
  `.github/workflows` exists, an unreported rollup always refuses the merge.

## [0.2.0] - 2026-07-18

### Changed

- **Per-repo memory is now native plain markdown** (`bin/dm-memory.sh`),
  replacing the third-party `contextgraph` dependency. Shared, contributor-facing
  facts live in an `dm:knowledge` section of each repo's own `AGENTS.md`
  (committed, so it travels); dockmaster-private notes live in a git-excluded
  `repos/<repo>/.dm/`; global facts stay in `state/learnings.md` and
  `state/operator.md`. `dm-repo` now `seed`s this scaffold (the old `init-memory`
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

- **`dm-repo create`**: stand up a brand-new repo. With no remote it creates the
  GitHub repo via `gh-axi` (private by default; `--public` to publish, `--https`
  for an HTTPS origin); with an empty remote you supply it wires that up instead
  (and refuses a populated remote, pointing at `add`). Either way it initializes
  `repos/<name>` with a first commit, sets the upstream, publishes, registers the
  repo, and seeds per-repo memory. Complements `add`, which clones an existing
  populated remote.

- **`dm-doctor`**: readiness check + `DM_HOME` scaffold. Owns the toolbelt's
  dependency contract (required vs recommended tools, GitHub auth) with
  actionable hints, and creates any missing home directories idempotently.
  `dm-session-start` now delegates its tooling check here so the list lives in
  one place.
- **`dm-status`**: a read-only, no-sync mid-session snapshot — managed repos
  (flagging tangled clones), in-flight tasks with an attention summary, active
  worktrees with disk use plus orphaned directories and dangling records, and
  the ready backlog with open operator decisions.
- **`dm-backlog decisions`**: lists open operator decisions (key + question) as
  a machine-readable interface for status views.

## [0.1.0] - 2026-07-17

Initial release. dockmaster is an agent distro for Claude Code that runs a crew
of autonomous subagents across many repositories from a single liaison agent.

### Added

- **Operating contract** (`AGENTS.md`) turning a Claude Code session into the
  dockmaster: read-only over managed repos, delegates all project work, reports
  outcomes.
- **Toolbelt** (`bin/`): a composed startup/recovery digest (`dm-session-start`),
  repo registry + memory onboarding (`dm-repo`), isolated worktrees with
  isolation/tangle/landed checks (`dm-worktree`), durable task records with
  on-demand state reconciliation (`dm-task`), a durable cross-session backlog and
  operator-decision log (`dm-backlog`), the tests gate runner (`dm-test`), strict
  PR open/check/merge that never merges red (`dm-pr`), guarded fast-forward local
  landing and conflict-aware rebase (`dm-merge`), fast-forward-only clone sync
  (`dm-sync`), the crewmate brief contract (`dm-brief`), the lavish review
  surface (`dm-lavish`), and branch naming `<type>/<issue>/<slug>`
  (`dm-branch-name`).
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
  dockmaster home.
- **Modular PR pipeline** declared as an ordered gate array
  (`config/pr-pipeline.default.json`), with an optional deterministic runner
  (`workflows/pr-pipeline.js`).

[0.2.0]: https://github.com/mengsig/dockmaster/releases/tag/v0.2.0
[0.1.0]: https://github.com/mengsig/dockmaster/releases/tag/v0.1.0

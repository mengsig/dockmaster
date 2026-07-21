# Runtime adapters, tests, and the context budget

Read before adding a skill, changing a runtime adapter, or touching anything the
test suite measures.

- **[convention]** Workflow skills have exact-name runtime adapters under
  `.claude/skills/` and `.agents/skills/`; `tests/check-runtime-parity.js` owns
  name, trigger, separation, capability, and context-budget drift checks. New
  behavior = both adapters + an `AGENTS.md` trigger bullet, not an inline
  contract. The trigger check parses `AGENTS.md` for `- **<name>** —` at line
  start and demands an exact set match against
  `config/runtime-capabilities.json`, so prose must not accidentally form that
  shape.
- **[pitfall]** `tests/check-runtime-parity.js` CAPABILITY_ASSERTIONS pins exact
  prose phrases in `AGENTS.md`, `README.md`, `.codex/config.toml`, and several
  skills per capability id; rewording those lines fails the parity suite (and
  smoke, which runs it). `AGENTS.md` currently anchors two: the phrase "load the
  skill at its trigger" and a literal `chrome-devtools-axi` mention.
- **[pitfall]** `tests/smoke.sh` is offline: the PR path is covered only through
  stubbed CLIs (not `workflows/pr-pipeline.js`), so no test hits real GitHub.
  Under `set -euo pipefail`, piping output to `grep -q` SIGPIPEs the producer
  (exit 141) which pipefail reports as failure — capture once and match with a
  here-string (`grep -q pat <<<"$VAR"`).
- **[pitfall]** To capture a command's exit code in a test that SOURCES
  `dm-lib.sh`, use `rc=0; cmd || rc=$?`, never `cmd; echo $?`. Sourcing turns on
  `set -e` inside that subshell, so a bare nonzero return aborts it before the
  `echo` — and WHETHER bash aborts there is version-dependent (green on a dev
  box, red in CI). External-command exit checks inside `check`'s `if eval` are
  safe (the `if` suspends `set -e`); the trap is only the sourced-lib subshell.
- **[pitfall]** Any smoke test comparing a resolver/worktree path against an
  expected value must run on a CANONICAL temp root — `smoke.sh` sets
  `TMP="$(cd "$(mktemp -d …)" && pwd -P)"`. `dm-lib` canonicalizes `DM_HOME`
  (`pwd -P`) and git records paths physically, so on a symlinked TMPDIR (macOS
  `/var` -> `/private/var`) resolver output is canonical while a verbatim `$TMP`
  expectation is not — the comparison misses only there, invisible on Linux.
  Reproduce locally with `TMPDIR=<symlink> bash tests/smoke.sh`. (Distinct from
  `scout-cleanup.sh`, which keeps a symlinked root on purpose to EXERCISE the
  canonicalization — see `dm-100-cleanup-safety`.)
- **[convention]** `tests/runtime-performance.js` caps `AGENTS.md` at
  `shared_agents_bytes + 2048` from
  `config/runtime-performance-baseline.json`. That allowance is a ratchet
  against a file loaded into every session and every crewmate brief, so it is
  meant to bind. Raising `shared_agents_bytes` because the cap blocked an
  addition launders the growth the guard exists to catch (#129): curate first,
  then re-baseline to the curated size and justify the new floor in the PR body.
- **[convention]** `base_commit` in that baseline names the CHANGE that set the
  floor (a PR reference, e.g. `#129`), not a SHA. It was a SHA and went stale
  immediately: this repo squash-merges, so the main SHA does not exist when the
  baseline is authored, and nobody could update it. Bump it with
  `shared_agents_bytes` in the same commit. Nothing resolves it as a git ref —
  `runtime-performance.js` only echoes it as `baseline_commit`.
- **[convention]** `AGENTS.md` also has a hard ceiling: Codex truncates a
  project doc past `project_doc_max_bytes` (32768) from `.codex/config.toml`,
  and both `runtime-performance.js` and `check-runtime-parity.js` fail before
  that happens. The 2048 B allowance is the soft ratchet; 32768 B is the
  external wall.

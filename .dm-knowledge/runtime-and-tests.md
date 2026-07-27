# Skills, tests, and the context budget

Read before adding a skill or touching anything the test suite measures.

- **[convention]** Workflow skills live under `.claude/skills/<name>/SKILL.md`
  with frontmatter `name` equal to the directory; `tests/check-skill-triggers.js`
  owns name, trigger, and fleet-ownership-order drift. New behavior = a skill +
  an `AGENTS.md` trigger bullet, not an inline contract. The trigger check parses
  `AGENTS.md` for `- **<name>** —` at line start and demands an exact set match
  against the discovered skill directories, so prose must not accidentally form
  that shape.
- **[decision]** The distro is Claude-only. The Codex adapter (`.agents/`,
  `.codex/`, the parity/capability matrix) was dropped before release: keeping
  two adapters in sync taxed every change and let runtime-neutral policy drift
  between them unnoticed.
- **[pitfall]** `tests/smoke.sh` is offline: the PR path is covered only through
  stubbed CLIs, so no test hits real GitHub. Under `set -euo pipefail`, piping
  output to `grep -q` SIGPIPEs the producer
  (exit 141) which pipefail reports as failure — capture once and match with a
  here-string (`grep -q pat <<<"$VAR"`).
- **[pitfall]** Alternation in a smoke grep MUST use `grep -E` with a plain `|`.
  BSD/macOS grep does not implement `\|` in a basic RE — it matches a LITERAL
  pipe, so the pattern silently never matches. CI runs the whole suite on
  `macos-latest`, and most such checks are negative (`! grep -q ...`), so they
  go VACUOUSLY GREEN on the leg that matters while passing honestly on a GNU dev
  box. Five checks shipped this way in #166. Same class: grep is line-based, so
  a pattern spanning a wrapped sentence in a `.md` can never match — anchor on a
  phrase that lives on one line.
- **[pitfall]** To capture a command's exit code in a test that SOURCES
  `dm-lib.sh`, use `rc=0; cmd || rc=$?`, never `cmd; echo $?`. Sourcing turns on
  `set -e` inside that subshell, so a bare nonzero return aborts it before the
  `echo` — and WHETHER bash aborts there is version-dependent (green on a dev
  box, red in CI). External-command exit checks inside `check`'s `if eval` are
  safe (the `if` suspends `set -e`); the trap is only the sourced-lib subshell.
- **[pitfall]** `check` runs `eval "$2"` in the CURRENT shell, so a bare `exit`
  inside a check body kills the whole suite instead of failing that one
  assertion — and the run then prints a TRUNCATED pass count with no FAIL
  summary, which reads like success. A loop that needs early exit must be
  subshelled: `'( for x in …; do … || exit 1; done )'`.
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
- **[convention]** `runtime-performance.js` also pins `.claude/settings.json`
  and every `.claude/skills/*/SKILL.md` by SHA-256 and exact inventory. Any
  intentional skill edit must re-baseline those hashes in the same commit; the
  pin is a context-budget tripwire, not an objection to the edit.

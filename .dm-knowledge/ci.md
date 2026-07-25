# CI: the job graph and where each platform's coverage lives

Read before changing `.github/workflows/ci.yml` or adding a test file.

- **[measured]** The smoke suite IS the CI cost. On a green PR every other step
  — the bash-4 grep, `bash -n`, all four node checks, the waiter child — takes
  0-1 s *combined*; `bash tests/smoke.sh` took 4m24s on ubuntu and 9m07s on
  macOS. Any question of the form "why is CI slow" is a question about that one
  script. Caching buys nothing: the workflow installs no dependencies.
- **[measured]** What the split bought, run 30152362149 on the PR that made
  this change (green, all legs): `changes` 6s, `fast` 10s, `node14-compat` 9s,
  `macos` 33s, `smoke-linux` 3m05s, `smoke-bash32` 4m54s, `ci-gate` 4s — 5m12s
  wall clock against 8m27s / 9m33s / 20m45s for the three runs before it. A
  docs-only PR (run 30152386547) finished in **23 seconds** with all four heavy
  legs skipped and `ci-gate` green. `smoke-bash32` is now the critical path.
  With the `ci:macos` label (run 30152527444) the whole thing is 7m41s, of
  which `macos-full` is 6m47s. Every PR-blocking cap therefore has 2x+ headroom:
  10 min against a 3m05s longest, 12 against `smoke-bash32`'s 4m54s, and the
  20-min `macos-full` cap blocks nobody.
- **[decision]** Jobs are `changes` → {`fast`, `smoke-linux`, `smoke-bash32`,
  `macos`, `node14-compat`} → `ci-gate`. `fast` and `node14-compat` have no
  `if:` and no `needs:` on purpose — they run on every event, so a docs-only PR
  still gets a real gate and `ci-gate` is never vacuous.
- **[convention]** `ci-gate` is the single required status for branch
  protection. It runs `if: always()` and fails closed: only `success` and
  `skipped` pass, so a cancelled leg (a `timeout-minutes` kill reads as
  cancelled, not failed) can never be mistaken for one that had nothing to do.
  `changes` must succeed outright — if it fails we do not know what should have
  run, so no downstream skip can be trusted.
- **[convention]** The path filter is an EXCLUSION list (`'**'` minus a short
  list) under `predicate-quantifier: 'every'`, not an inclusion list. A path
  nobody has classified is therefore code by default, and so is every future
  path. Outside `pull_request` the output is hardcoded `true`. Do not invert
  this into "run the heavy legs when `bin/**` changed" — that fails open.
- **[pitfall]** `README.md`, `AGENTS.md` and `CLAUDE.md` are NOT inert and must
  never be added to the exclusion list. The suite asserts on their contents:
  the plain-gh parity sentence, the derived `DM_*` override list, and the
  `AGENTS.md` byte cap. A "docs-only" edit to them can genuinely fail a test.
- **[decision]** bash 3.2 is tested on ubuntu in a `bash:3.2` container, not
  only on macOS. This is strictly MORE 3.2 coverage than macOS ever gave: there
  only the harness ran under `/bin/bash` 3.2 while every `bin/dm-*.sh` resolved
  `#!/usr/bin/env bash` through PATH to Homebrew bash 5 (#164). In the container
  3.2 is the only bash on PATH, so the toolbelt itself runs on it. Measured
  identical result to the ubuntu bash-5 leg: 1180 passed, 0 failed.
- **[pitfall]** That container MUST install a GNU userland AND every tool the
  hosted runners already carry. The one variable under test is the bash
  version; a thinner install produced 12 false failures. Nine came from a
  missing `column` alone — `bin/` renders tables with `… | column -t … || cat`,
  and when `column` is absent the `|| cat` reads the script's stdin, not the
  consumed pipe, so the command prints NOTHING instead of the unaligned
  fallback. Two more came from a missing `gh`. Add to the `apk add` line
  whenever a test starts depending on a new tool.
- **[pitfall]** `smoke-bash32` is now the critical path and it pulls `bash:3.2`
  from Docker Hub unauthenticated. An anonymous-pull rate limit would fail the
  job — loudly, not silently. If that starts happening, mirror the image to
  GHCR rather than dropping the leg. The tag (not a digest) is deliberate: the
  image is rebuilt on a current Alpine, and the job asserts `version 3.2`
  itself, so a bad rebuild fails instead of rotting silently.
- **[decision]** macOS keeps the coverage nothing else can give (BSD userland,
  the `/var -> /private/var` symlinked tmpdir, macOS lock/process semantics) but
  is off the PR critical path: it was 100% of wall clock, 9m07s of runtime plus
  queue waits measured up to 11m04s. On a PR it runs the cheap half — the 3.2
  parse that caught #164 plus `scout-cleanup.sh` (which keeps a deliberately
  symlinked root) and the runtime scripts. `macos-full` runs the whole suite on
  main, nightly, and on a PR labelled `ci:macos`. `macos-full` needs `macos` so
  the system-bash-is-v3 assertion still guards it.
- **[pitfall]** `tests/smoke.sh` asserts on this workflow file: `/bin/bash -n`
  must appear in it, and the `no longer version 3` assertion must come first.
  Both strings must stay UNIQUE — the check compares `grep -n … | cut -d: -f1`
  as an integer, so a second occurrence of either makes it fail with a shell
  error rather than a clear message.
- **[finding]** Sharding the suite was investigated and rejected. It is one
  linear script over one `$DM_HOME`: sections build task/repo state that later
  sections assert on (the `dm-state` round-trip at ~L3237 reads `arch-wip`,
  created at ~L400), and many `check` bodies MUTATE state rather than just
  reading it, so no-op'ing out-of-range checks changes what later sections see.
  Splitting needs a real refactor into hermetic files, not a line-range split.
  If that is ever done, the shard runner must assert the shard counts SUM to the
  expected total: a shard that dies in top-level setup prints a truncated pass
  count and no FAIL summary, which reads exactly like success.
- **[measured]** Where the time actually goes (219 s local run, 131 sections):
  `brief: unfilled {TASK}` 38.7 s, `dm-state export/import` 25.3 s, `toolbelt
  input guards` 11.8 s, `brief: both recommendations` 11.7 s, `dispatch
  right-sizing` 10.4 s, `worktree cleanup safety matrix` 10.3 s (that one is
  `tests/scout-cleanup.sh`). Top 10 sections are 60% of the run. The cost is
  subprocess spawns — `dm-worktree.sh create`, `dm-status.sh`, and the jq
  passes every `bin/` invocation pays to validate the registry — not sleeps:
  deliberate synchronization sleeps total ~5 s, 2% of the run.

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
- **[decision]** Eight jobs. `changes` gates `smoke-linux`, `smoke-bash32` and
  `macos`; `macos-full` additionally needs `macos`. `fast` and `node14-compat`
  depend on NOTHING — no `needs:`, no `if:` — on purpose, so they run on every
  event and a docs-only PR still gets a real gate. `ci-gate` needs all seven.
- **[pitfall]** `ci-gate` is DESIGNED to be the single required status for
  branch protection, but branch protection is not configured on `main`:
  `GET /repos/mengsig/dockmaster/branches/main` returns `"protected": false` and
  `/rulesets` is empty, so nothing is required from GitHub's side. Today the
  operative merge gate is `bin/dm-pr.sh:381-406`, which reads all check runs
  itself and treats `skipped` as passing. Nothing is unsafe as a result, but do
  not read `ci-gate` as enforced until protection is actually turned on.
- **[convention]** `ci-gate` runs `if: always()` and fails closed. It does not
  take a leg's own `skipped` as evidence the leg was not needed: it re-reads the
  `changes` outputs (`code`, `macos_full`) that decided whether each heavy leg
  runs, and when the output says the leg was required, only `success` passes.
  A leg that is not required must be `success` or `skipped` — failed, cancelled
  (a `timeout-minutes` kill reads as cancelled, not failed), errored, or an
  empty result all fail. `changes` must succeed outright: if it fails we do not
  know what should have run, so no downstream skip can be trusted.
- **[convention]** `tests/check-ci-graph.js` pins the job graph's SHAPE, because
  the workflow gates itself and a PR that weakens the gate would verify itself
  green. It pins: `ci-gate.needs` covering every job; each job bound to exactly
  one `needs.<job>.result` env line that the gate script actually READS (all
  three wires, so a new job cannot be added half-wired); no duplicate env key
  shadowing a real expression; `predicate-quantifier: 'every'`; the exclusion
  list verbatim; both `changes` output expressions verbatim; each heavy leg's
  `if:` guard verbatim; the load-bearing lines of the gate script; `fast` and
  `node14-compat` having no `if:`/`needs:`; `timeout-minutes` present and
  <= 30; and its own invocation step. 24 planted drifts caught, 6 legitimate
  edits stayed green.
- **[pitfall]** That checker is a LINE parser, not a YAML parser — no
  dependencies, and it must run on Node 14. It normalizes whole-line comments
  (so hiding the original in a comment beside a hardcoded pass does not fool a
  pin), block- and flow-style `needs:`, and quoted job keys. It does NOT model
  YAML anchors/aliases, flow-style job mappings, folded (`>`) scalars beyond
  refusing one on `filters:`, multi-document files, or a trailing same-line
  comment. A pin defeated by any of those would pass. Treat it as a drift
  tripwire, not a proof: it raises the cost of an accidental regression, it
  does not stop a determined one. The real guarantee is the gate script itself,
  which was swept over 2500 result combinations against an independent oracle.
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
  version; a thinner install produced 12 false failures — nine from a missing
  `column`, two from a missing `gh`, and one from a test copy that had no
  `.git` (that last one was the harness, not the container). The `column` nine
  are the interesting ones: `bin/` renders tables with `… | column -t … || cat`,
  and when `column` is absent the `|| cat` reads the script's STDIN, not the
  consumed pipe — so the command prints nothing instead of the unaligned
  fallback, and on a terminal it blocks outright. Add to the `apk add` line
  whenever a test starts depending on a new tool.
- **[pitfall]** Unproven at the time of writing: the `push: main` and `schedule`
  paths had never executed — every run was `pull_request`. `code` cannot come
  back `false` there (the filter step is skipped and the output is hardcoded
  `true`), but that is reasoning, not evidence. The first push-to-main run must
  show `smoke-linux`, `smoke-bash32`, `macos` and `macos-full` all RUNNING.
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
- **[decision]** On a PARTIAL re-run, a job that failed in attempt 1 can splice
  stale empty outputs into attempt 2 (actions/runner#2598). If `changes` itself
  failed and is re-run alone, `ci-gate` fails with `changes output code is not
  true/false (got: '')`. That is deliberate: it is loud, diagnosable, and fixed
  by "Re-run all jobs". Before the outputs were validated the same scenario was
  a silent fail-OPEN. Do not "fix" it back into tolerating an empty output.
- **[pitfall]** A run superseded by `cancel-in-progress` shows `ci-gate` as
  FAILED, not cancelled — the cancel lands as an empty result, which the gate
  correctly refuses. Harmless: the check-runs API defaults to `filter=latest`,
  so only the newest run is what any consumer sees. Do not chase it as a red.
- **[finding]** Sharding the suite was investigated and rejected. It is one
  linear script over one `$DM_HOME`: sections build task/repo state that later
  sections assert on (the `dm-state` round-trip at L3237 reads `arch-wip`,
  created at L964), and many `check` bodies MUTATE state rather than just
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

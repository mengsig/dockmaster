# PR pipeline config

`pr-pipeline.default.json` (and per-repo `pr-pipeline.<repo>.json` overrides)
declare the PR delivery pipeline as an **ordered list of gates**. Two things read
this file, and they read different parts of it — so keep every field meaningful:

## Rigor tiers

Three shipped tiers share one gate schema; the tier is a per-task choice (see
`.claude/skills/pr-workflow` for the selection criteria):

- **`pr-pipeline.fast.json`** — objectively trivial changes: one review pass.
- **`pr-pipeline.default.json`** — the norm: two independent review passes.
- **`pr-pipeline.rigorous.json`** — high-stakes changes (this distro's own
  merge/safety-gate code, auth, migrations, concurrency/locking, money/secrets,
  or anything the operator is nervous about). Its `review` gate is
  **dimension-parallel** (one reviewer per lens), followed by an adversarial
  **`verify-findings`** gate, then fix → tests → a behavioral `verify` gate →
  auto `security` → `await-checks` → `pr`.

## The default executor: the manhandler (agent-driven)

By default the manhandler runs the pipeline itself, driving each gate with
ordinary `Agent` calls while following `.claude/skills/pr-workflow/SKILL.md`. It
reads:

- the gate **order** (top to bottom), and
- each review gate's **`pass`** label (`coldstart` | `merge-gate`), which names
  which of the two review passes it is.

It also honors the `pr` gate's **`method`** at the merge-authority step, by
passing it to `bin/mh-pr.sh merge --method <method>`.

## The optional executor: `workflows/pr-pipeline.js`

Only when the operator opts into hands-off multi-agent orchestration (run via the
Workflow tool — nothing auto-discovers it). It reads the rest:

- **`effort`** on `review` / `security` gates — the reviewer subagent's effort
  (falls back to `high`).
- **`dimensions`** on a `review` gate (rigorous) — an array of lenses
  (`correctness`, `security`, `concurrency`, `portability`, `tests`); the runner
  fans out one fresh reviewer per lens with `parallel()` and merges their
  findings. Absent → a single generalist read.
- **`voters`** on the `verify-findings` gate (rigorous) — how many skeptics
  independently try to refute each finding (default 3); a finding survives only
  if it is not refuted by a majority. Only survivors reach `fix`.
- **`optional`** on the `verify` gate (rigorous) — with a caller-declared
  `noRuntimeSurface` (docs/config-only diff), skips the behavioral gate.
- **`max_rounds`** on a `fix` gate — the fix→re-review loop cap.
- **`optional`** on the `security` gate — skip it unless the caller declares a
  security surface. **`method: "auto"`** (rigorous) instead runs
  `bin/mh-pr.sh security-scan` and escalates to `security-review` only on a hit.
- **`method`** on the `pr` gate — surfaced in the runner's result so the
  operator-mediated merge step can honor it (the runner never merges).

The rigorous `await-checks` gate is the CI-wait; because the runner opens the PR
at the terminal `pr` gate and never merges, the runner defers it to the
operator-mediated merge gate rather than waiting on a PR it has not opened.

## `note`

Every gate may carry a free-form **`note`** — a human comment for whoever edits
this file. Nothing executes it.

Adding a gate: document its contract in the pr-workflow skill, then add its name
(and any fields above) to the `gates` array here.

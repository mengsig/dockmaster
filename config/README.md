# PR pipeline config

`pr-pipeline.default.json` (and per-repo `pr-pipeline.<repo>.json` overrides)
declare the PR delivery pipeline as an **ordered list of gates**, read by the
dockmaster while it drives the pipeline agent-style — so keep every field
meaningful:

## Rigor tiers

Four shipped tiers share one gate schema; the tier is a per-task choice (see
the `pr-workflow` skill for the selection criteria, and the higher-tier-when-
unsure rule):

- **`pr-pipeline.fast.json`** — objectively trivial, non-logic changes: one
  review pass.
- **`pr-pipeline.standard.json`** — small, low-blast-radius code changes: one
  review pass, but real logic, so the lavish approval gate still applies.
- **`pr-pipeline.default.json`** — the norm: two independent review passes.
- **`pr-pipeline.rigorous.json`** — high-stakes changes (this distro's own
  merge/safety-gate code, auth, migrations, concurrency/locking, money/secrets,
  or anything the operator is nervous about). Its `review` gate is
  **dimension-parallel** (one reviewer per lens), then fix → tests → the
  behavioral `verify` gate → auto `security` → `pr`. (The CI-wait is not a
  config gate; it runs in the operator-mediated merge tail after the PR opens —
  see `pr-workflow`.)

## The executor: the dockmaster (agent-driven)

The dockmaster runs the pipeline itself, driving each gate with a subagent
while following `pr-workflow`. It reads:

- the gate **order** (top to bottom), and
- each review gate's **`pass`** label (`coldstart` | `merge-gate`), which names
  which of the two review passes it is.

It also honors the `pr` gate's **`method`** at the merge-authority step, by
passing it to `bin/dm-pr.sh merge --method <method>`.

There is no CI-wait gate in the config: the dockmaster opens the PR at the
terminal `pr` gate and never merges, so waiting for CI (`bin/dm-pr.sh
await-checks`) belongs to the operator-mediated merge tail that runs after the
PR is open — see `pr-workflow` ("Merge authority").

The remaining gate fields — `effort`, `max_rounds`, `dimensions`, `optional`,
and `method` on `security` — are contract too; `pr-workflow` covers their
semantics. In the agent-driven path, `effort` maps
to the `crew-<level>` subagent_type; choosing it is sized per
task-lifecycle's ladder.

## `note`

Every gate may carry a free-form **`note`** — a human comment for whoever edits
this file. Nothing executes it.

Adding a gate: document its contract in the `pr-workflow` skill, then add its
name (and any fields above) to the `gates` array here.

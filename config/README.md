# PR pipeline config

`pr-pipeline.default.json` (and per-repo `pr-pipeline.<repo>.json` overrides)
declare the PR delivery pipeline as an **ordered list of gates**. Two things read
this file, and they read different parts of it — so keep every field meaningful:

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
- **`max_rounds`** on a `fix` gate — the fix→re-review loop cap.
- **`optional`** on the `security` gate — skip it unless the caller declares a
  security surface.
- **`method`** on the `pr` gate — surfaced in the runner's result so the
  operator-mediated merge step can honor it (the runner never merges).

## `note`

Every gate may carry a free-form **`note`** — a human comment for whoever edits
this file. Nothing executes it.

Adding a gate: document its contract in the pr-workflow skill, then add its name
(and any fields above) to the `gates` array here.

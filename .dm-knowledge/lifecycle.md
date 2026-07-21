# Task records, state, and delivery

Read before changing how tasks are created, reconciled, dispatched, or
delivered. The contract a crewmate follows lives in the `task-lifecycle` and
`change-review` skills; this is how the machinery underneath behaves.

- **[invariant]** Task records are created and mutated as COMPLETE units — a
  typo'd id fails visibly (#101). `dm_task_create` is the sole creator:
  meta+status under the task lock, status first (`dm_all_task_ids` globs
  `*.meta`, so a half-made task never enumerates; an interrupted create strands
  a `.status`, named in the refusal). `dm_meta_set`/`dm_status_append` refuse
  without a complete record (valid `kind`/`mode`, non-empty `repo`/`created`,
  status log), checked INSIDE the lock so archive cannot race into
  resurrection. `event` allowlists
  `working|review-ready|ready|done|blocked|needs-decision|failed|paused`; `set`
  also reserves `worktree` (dm-worktree).
- **[convention]** Task current-state is reconciled on demand by `dm-task.sh
  state` from real signals (merged PR, merge event, report.md,
  committed-unlanded worktree), never from the last status line;
  `state/tasks/<id>.status` is an append-only event log. Add new signals to
  `dm-task.sh state`, not to callers.
- **[convention]** Dispatch right-sizing is ADVISORY, not a gate (the Codex
  adapter has no per-spawn model field to enforce one): `dm_recommended_model
  <kind> <text>` (dm-lib, pure) picks haiku|sonnet|opus; `dm-brief` surfaces it
  in the header and records `model_recommended` in meta; `dm-status` flags a
  `working` task with no `model` as UNSIZED. Claude sets the Agent `model`;
  Codex biases effort/granularity. Additive — never blocks dispatch.
- **[decision]** Requested-change delivery flow: crewmate implements in a
  worktree and renders a lavish artifact (review-ready) → operator approves via
  lavish (mediated by the dockmaster) → ask PR-or-local → on PR: coldstart
  review, fix + tests, merge-gate review, fix + tests, PR creation → merge gate.
  Lavish approval precedes PR/local and applies to both.
- **[routing]** Open-PR fleet health → `dm-pr.sh sweep` (read-only; surfaced in
  `dm-status`). A new repo with no test command → the onboarding scout
  (`project-management` skill) proposes a `test_cmd` and initial shared notes.

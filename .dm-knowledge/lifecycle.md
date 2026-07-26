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
  also reserves `worktree` (dm-worktree) and `repo` (fixed at creation — it
  decides which clone the work lands in and whose merge authority gates it, and
  `dm-worktree.sh create` refuses a repo argument that disagrees with the record,
  because writing it there unconditionally was a one-command way around the
  reservation), and
  constrains `mode` to the repo's REGISTERED delivery mode (#127, see
  merge-safety.md). `kind` is DIRECTIONAL: `scout -> ship` is the documented
  promotion, `ship -> scout` is refused — kind selects how `state` reconciles, so
  a demotion turns a fabricated `data/<id>/report.md` into a terminal `done` and
  lets teardown read committed work as investigation scratch. Teardown's gate is
  kind-INDEPENDENT as well, so the two hold the same line from both sides.
  `new` refuses an UNREGISTERED `--repo` outright (#124) rather
  than failing later at worktree-create; the reserved distro name is the one
  accepted non-registry name, since it has no entry by design.
- **[decision]** A ship task whose honest answer is "do not build it" ends with
  `dm-task.sh close <id> --reason "<why>"` (#103). Before it, such a task had NO
  reachable terminal state — `state` derives done only from positive landing
  evidence — so it either pinned at `working` forever or was laundered into
  looking finished (flipped to a scout with a report; mode forged so a local land
  appended a `merged` event). `close` records the EXISTING `discarded` verb, not
  a new token: `state`, `archive`, and `dm-repo.sh remove` already read that as
  terminal, and a new one would read as non-terminal to all three. It refuses on
  ANY recorded worktree — present (teardown is what inspects the work) or absent
  (the interrupted-cleanup shape `remove` refuses without `--force`, so closing
  there would reach `discarded` with none of that discard authority) — and
  refuses an already-terminal task; `dm-task.sh event` still bars the verb, so
  `close` and `dm-worktree.sh remove --force` remain its only writers. When you
  add a second writer of an existing state, carry over the FIRST writer's
  preconditions or it becomes the soft way in.
- **[convention]** Task current-state is reconciled on demand by `dm-task.sh
  state` from real signals (merged PR, merge event, report.md,
  committed-unlanded worktree), never from the last status line;
  `state/tasks/<id>.status` is an append-only event log. Add new signals to
  `dm-task.sh state`, not to callers.
- **[convention]** Dispatch right-sizing is TWO INDEPENDENT DIALS, and choosing
  both is a GATE (#166). Model is the Agent `model` parameter; reasoning effort
  is the Agent `subagent_type`, selecting a `crew-<level>` definition under
  `.claude/agents/` whose frontmatter carries `effort:`. Since #177 each
  definition ALSO pins `model:` (low haiku, medium sonnet, high/xhigh opus), so
  an omitted parameter resolves to a considered default instead of the session
  model. Documented resolution order is `CLAUDE_CODE_SUBAGENT_MODEL` env var >
  per-invocation `model` parameter > frontmatter `model:` > the main
  conversation's model — so the pin is a DEFAULT, never a coupling, and every
  model x effort pair is still one line. `DM_EFFORT_LEVELS` is the closed set
  the gate accepts — `max` exists in the runtime and is deliberately excluded as
  a cost ceiling.
- **[decision]** There is deliberately NO computed dispatch recommendation
  (tried as `dm_recommended_dispatch` / `dm-task.sh recommend` across #166-#187,
  removed after operator feedback: a table driven by role/kind/diff-size
  under- and over-fired against real judgment, and no default is worth the
  machinery). Sizing is the dockmaster reading the brief and picking a rung on
  the ladder in `task-lifecycle` — prompting, not a formula. Before that it was
  keyword heuristics over the task TITLE, which over-fired the same way (`auth`
  matched author/authority). Do not reintroduce keyword OR table-driven sizing.
  `dm-status` flags a `working` task missing EITHER dial as UNSIZED.
- **[convention]** The record gate can be AUDITED even though it cannot verify a
  spawn: `dm-task.sh sizing --transcripts <dir>` compares each task's recorded
  `model` against the model its crewmate actually ran, read by
  `dm_transcript_model` from the first `"model":"..."` in the transcript. The
  runtime writes one `<agent_id>.output` per spawn under its per-session
  `tasks/` dir (a symlink to `subagents/agent-<id>.jsonl`); the DIRECTORY is a
  caller argument so nothing in `bin/` hardcodes a runtime-internal path, and a
  wrong directory degrades to "unproven" for every task rather than a false
  pass. Matching is CONTAINMENT (`opus` vs `claude-opus-5`) because meta holds a
  tier alias and the transcript a full id; no alias is a substring of another. A
  contradiction exits 3.
- **[gotcha]** `dm-task.sh set agent_id` REFUSES unless the task records both
  `model` and `effort`, and refuses an effort outside `DM_EFFORT_LEVELS`. It is
  a RECORD gate, not a SPAWN gate: the agent is already running by the time it
  executes, and nothing verifies the recorded effort matches the `subagent_type`
  actually passed. Same shape as the `{TASK}` brief guard — it forces the choice
  to be made and written down, it does not verify what was spawned. Read
  "enforced" as "cannot go unrecorded", never as "verified".
- **[gotcha]** `haiku` has no reasoning-effort support: it ignores the
  `crew-<level>` definition and runs at its own default. Verified empirically,
  not documented by the runtime. Pick haiku for cheapness, never for restraint.
- **[gotcha]** Agent definitions load at SESSION START, not on write. A newly
  added `.claude/agents/*.md` is invisible to the running session ("agent type
  not found"); it takes a restart.
- **[gotcha]** The frontmatter `name:` is the DISPATCH KEY, not the filename.
  The loader reads `agentType` from `name:` and drops a file with no `name:`
  entirely. Verified: a file `probe-alpha.md` declaring `name: probe-beta`
  resolves only as `probe-beta`. So a `crew-*.md` whose `name:` is missing or
  misspelled passes every filename-based check and still fails at spawn — the
  drift guard checks `name:` and `effort:`, not just the path.
- **[gotcha]** A `crew-*` spawn REPLACES the general-purpose system prompt with
  the definition body — it is not appended. Anything the built-in preamble
  provided (absolute-path guidance, "don't create unnecessary files", the
  report-shaped-.md deterrence `dm-brief` relies on) is gone unless the body
  restates it. Keep those few lines in the crew bodies.
- **[decision]** Requested-change delivery flow: crewmate implements in a
  worktree and renders a lavish artifact (review-ready) → operator approves via
  lavish (mediated by the dockmaster) → ask PR-or-local → on PR: coldstart
  review, fix + tests, merge-gate review, fix + tests, PR creation → merge gate.
  Lavish approval precedes PR/local and applies to both.
- **[routing]** Open-PR fleet health → `dm-pr.sh sweep` (read-only; surfaced in
  `dm-status`). A new repo with no test command → the onboarding scout
  (`project-management` skill) proposes a `test_cmd` and initial shared notes.

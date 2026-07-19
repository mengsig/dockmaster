---
name: change-review
description: The lavish approval gate for a requested change — a crewmate renders the change as a reviewable lavish artifact, the operator approves (with back-and-forth), and only then does delivery proceed to the PR-or-local decision. Load when a crewmate signals review-ready, or before deciding how a change lands.
---

# change-review

Every requested change goes through one human approval gate on a **lavish
artifact** before it is delivered. This is where the operator sees and shapes the
change; the PR-or-local decision and any pipeline come *after* approval.

## The flow

1. **Crewmate renders the change.** In its worktree, the crewmate implements the
   change, commits it, then writes a review artifact to the standard path:
   ```
   bin/dm-lavish.sh path <id>     # -> data/<id>/lavish/change.html
   ```
   The artifact shows, at a glance: what changed and why, the diff (or the
   meaningful parts), before/after where it helps, and the risk. It uses the
   `code` and `comparison`/`plan` lavish playbooks as fits. The crewmate then
   signals:
   ```
   bin/dm-task.sh event <id> review-ready "lavish artifact ready"
   ```

2. **Dockmaster presents it.** On the `review-ready` wake, the dockmaster opens
   the surface and tells the operator it is ready to review, with a one-line plain
   summary of the change:
   ```
   bin/dm-lavish.sh open <id>
   ```
   Then start the notification-producing wait described below. Do not run the
   poll in an unattended command session.

## Codex notification contract

`bin/dm-lavish.sh poll <id>` is a long-running terminal command, but completion
of a command session does **not** wake the dockmaster's collaboration mailbox.
The dockmaster therefore delegates each approval wait to one dedicated Codex
waiter with `spawn_agent(..., fork_turns="none")`.

Before spawning, derive and persist the waiter identity:

```
waiter_thread="$(bin/dm-thread-name.sh <id> review_waiter)"
bin/dm-task.sh set <id> waiter_thread_name "$waiter_thread"
```

Reconcile any saved `waiter_agent_id` and exact thread name with `list_agents`.
Reuse one exact idle match with `followup_task`; multiple matches are an
ambiguity blocker. Only a proven zero-owner state permits `spawn_agent`. Persist
its returned id immediately as `waiter_agent_id`, then set
`waiter_state=active`.

Give the waiter the absolute dockmaster directory, task id, and this exact job:

1. Run `bin/dm-lavish.sh poll <id>` synchronously in the dockmaster directory.
2. If the command yields a running session, keep resuming that same session
   until it exits. The waiter must not return while the command is still live.
3. Return the complete feedback, layout warning, session-end result, or visible
   command failure. Do not modify files, act on feedback, or address the operator.

The waiter's completion is delivered to the parent mailbox. Use `wait_agent`
while the approval goal is active; when the waiter completes, reconcile the
review and relay actionable feedback to the implementation crewmate. Never
treat a raw background or yielded terminal session as a parent wake source.
Keep the waiter id for this review session. On approval, session end, or visible
waiter failure, set `waiter_agent_id` to empty and `waiter_state=terminal`. If dispatch fails because no thread
slot is available, remain attached to the poll or surface the capacity blocker;
never silently fall back to an unattended terminal wait.

3. **Back-and-forth.** Feedback from the poll is relayed by the dockmaster to the
   crewmate as one clear instruction. The crewmate revises the code, updates the
   artifact, and signals `review-ready` again. Re-arm the same idle waiter with
   `followup_task` for the next poll instead of consuming another thread. Repeat
   until the operator approves. (Crewmates never talk to the operator directly;
   the dockmaster mediates — but the operator's annotations on the lavish
   surface are authoritative input.)

4. **Approval → decide how it lands.** Once the operator approves, end the
   session (`bin/dm-lavish.sh end <id>`) and ask the operator one plain question:
   **create a PR, or keep it local?**
   - **local** → set the task to local mode first — `bin/dm-merge.sh local`
     refuses any task whose mode isn't `local-only` — then land with the guarded
     fast-forward after approval:
     ```
     bin/dm-task.sh set <id> mode local-only
     bin/dm-merge.sh local <id>
     ```
     See `task-lifecycle`.
   - **PR** → run the PR pipeline (load `pr-workflow`).

## Fast path for trivial changes

The full ceremony — lavish approval gate plus a two-pass PR pipeline — is right
for real code but heavy for a typo or a doc line. A change that is **objectively
trivial** MAY skip the lavish approval gate and use the single-pass `fast`
pipeline (`config/pr-pipeline.fast.json`; see `pr-workflow`).

**A change is trivial only if it is one of:**
- docs, comments, a config *value*, or string/copy text only; OR
- a very small diff with **no** logic, control-flow, dependency, schema, auth,
  security, or externally-visible-contract change.

Anything that touches logic, control flow, dependencies, a schema, auth,
security, or a public/externally-visible contract is **not** trivial — take the
full path. When unsure, it is not trivial: default to the full path.

**The fast path relaxes only two things, and nothing else:**
- the lavish approval gate MAY be skipped, and
- the PR pipeline runs one review pass instead of two.

**These hard rules never relax, on any path:**
- Tests still run (`fast` keeps the `tests` gate).
- One cold, independent review still happens (`fast` keeps the coldstart
  `review` gate).
- Merge authority is unchanged: never merge red, honor the repo's
  `merge_authority` (`never` means the operator merges on GitHub, never the
  dockmaster), and otherwise it is still the operator's explicit word — or, under
  a standing `yolo`, auto-merge only LOW/MEDIUM-risk green work, while a HIGH-risk
  change always needs the explicit word (risk tiers defined in `pr-workflow`).
- The operator can always demand the full path for any change.

## Rules

- The lavish approval gate is not skippable for a requested change — it is how
  the operator steers the change before any pipeline spends effort on it — with
  the single carve-out above: an objectively trivial change may skip it.
- Keep the operator-facing summary in outcomes, not mechanics. The artifact
  carries the detail; the chat line says what the change does and that it is
  ready to look at.
- Approval of the *change* is not approval to *merge*. Merge authority is a
  separate gate after the PR exists (see `pr-workflow`).
- A `local-only` repo still gets the lavish gate; it simply lands locally instead
  of opening a PR.

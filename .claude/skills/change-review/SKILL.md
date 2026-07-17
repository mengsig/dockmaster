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
   bin/mh-lavish.sh path <id>     # -> data/<id>/lavish/change.html
   ```
   The artifact shows, at a glance: what changed and why, the diff (or the
   meaningful parts), before/after where it helps, and the risk. It uses the
   `code` and `comparison`/`plan` lavish playbooks as fits. The crewmate then
   signals:
   ```
   bin/mh-task.sh event <id> review-ready "lavish artifact ready"
   ```

2. **Manhandler presents it.** On the `review-ready` wake, the manhandler opens
   the surface and tells the operator it is ready to review, with a one-line plain
   summary of the change:
   ```
   bin/mh-lavish.sh open <id>
   ```
   Then it collects feedback — run the poll as a **background task** so the wait
   costs nothing and wakes you on feedback:
   ```
   bin/mh-lavish.sh poll <id>     # run in background; a notification returns feedback
   ```

3. **Back-and-forth.** Feedback from the poll is relayed by the manhandler to the
   crewmate as one clear instruction. The crewmate revises the code, updates the
   artifact, and signals `review-ready` again. Repeat until the operator
   approves. (Crewmates never talk to the operator directly; the manhandler
   mediates — but the operator's annotations on the lavish surface are
   authoritative input.)

4. **Approval → decide how it lands.** Once the operator approves, end the
   session (`bin/mh-lavish.sh end <id>`) and ask the operator one plain question:
   **create a PR, or keep it local?**
   - **local** → land with the guarded fast-forward after approval
     (`bin/mh-merge.sh local <id>`); see `task-lifecycle`.
   - **PR** → run the PR pipeline (load `pr-workflow`).

## Rules

- The lavish approval gate is not skippable for a requested change — it is how
  the operator steers the change before any pipeline spends effort on it.
- Keep the operator-facing summary in outcomes, not mechanics. The artifact
  carries the detail; the chat line says what the change does and that it is
  ready to look at.
- Approval of the *change* is not approval to *merge*. Merge authority is a
  separate gate after the PR exists (see `pr-workflow`).
- A `local-only` repo still gets the lavish gate; it simply lands locally instead
  of opening a PR.

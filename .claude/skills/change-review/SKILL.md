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
- Merge authority is unchanged: never merge red, and it is still the operator's
  explicit word or the repo's standing `yolo` for routine green work.
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

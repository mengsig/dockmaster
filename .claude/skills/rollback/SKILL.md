---
name: rollback
description: Revert a change that has already landed. A revert is itself a change and goes through the normal gate — never a force-push or history rewrite. Load when a landed change must be reverted.
---

# rollback

The prime directives and every prior safety rule cover **unlanded** work. This
covers **landed** work — a merged PR or a completed local fast-forward that must
be undone. A rollback is not an emergency bypass: it is a new change that goes
through the normal gate (change-review + merge authority).

## Choose the path by how it landed

- **Merged PR** — prefer a **revert PR**: `gh-axi pr revert <n>`. This is the
  sanctioned path: it opens a clean PR that reverses the merge commit. To run it
  through the normal gate tooling, **adopt the revert PR into a fresh task** — the
  gates (`mh-pr check`, merge) read `meta.pr`, so record the revert PR's URL on a
  new task id:
  ```
  bin/mh-task.sh new <revert-id> --kind ship --repo <repo> --title "revert #<n>"
  bin/mh-task.sh set <revert-id> pr <revert-pr-url>
  bin/mh-pr.sh check <revert-id>     # then the merge gate, as any PR
  ```
  A bare revert PR with no adopting task can still be merged on GitHub by the
  operator, but then the gates are applied by hand, not by the tooling.
- **local-only landing** — `git revert <sha>` in a **fresh worktree** (dispatch a
  crewmate; the manhandler stays read-only over `repos/`), then land it the same
  way the original did (`bin/mh-merge.sh local <id>` after approval).

## Rules

- **Never force-push or rewrite published history** to "undo" a merge. The revert
  goes forward as a new commit, not by erasing the old one.
- The revert passes the same gates as any change — lavish approval and merge
  authority. Do not skip them because it is "just a revert."
- **Record why** it was reverted (in the revert PR/commit message, and any
  durable fact per `memory-routing`) so the next attempt does not repeat the
  cause.
- If the revert itself conflicts, load `merge-conflict`.

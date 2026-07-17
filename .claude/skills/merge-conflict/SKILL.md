---
name: merge-conflict
description: Resolve merge/rebase conflicts safely by dispatching a crewmate to rebase in the worktree with full repo context, re-run tests, and report. Never force, never discard unlanded work. Load when a branch has diverged or a rebase/merge hit conflicts.
---

# merge-conflict

Conflicts are resolved by a crewmate that understands the code, in the worktree,
with tests — never by the manhandler force-merging or discarding work.

## Detect

When landing (`bin/mh-merge.sh local`) or opening/updating a PR reports the
branch has diverged from the default, bring it current:

```
bin/mh-merge.sh rebase <id>
```

- Clean rebase → the branch is current; continue delivery.
- Conflicts → `mh-merge.sh rebase` **aborts the rebase**, leaves the worktree
  exactly as it was, and prints the conflicted files with exit 3. Nothing is
  lost. Now dispatch a crewmate to resolve.

## Resolve (dispatch a crewmate)

Brief the crewmate (or re-brief the task's existing crewmate) with:

- its worktree path and branch, and the base branch to rebase onto;
- the list of conflicted files from the detect step;
- the instruction: rebase onto the latest default, resolve each conflict by
  understanding *both* sides (not by blindly taking one), keep the intended
  change intact, drop nothing, then run the repo's test command and confirm
  green;
- report `ready` when the rebase is complete and tests pass, or `blocked` with
  specifics if a conflict needs an operator decision.

Give the crewmate the exact commands it may use inside the worktree:

```
git fetch origin <default>
git rebase origin/<default>
# resolve, then:
git add <files>; git rebase --continue
<test command>
```

## Rules

- Never `git rebase --skip` a conflict away or `git checkout --theirs/--ours`
  wholesale without understanding what is dropped.
- Never force-push over shared history without operator authority; for a task's
  own PR branch, a `--force-with-lease` after a clean local rebase is acceptable
  and is the crewmate's action, reported back.
- If resolution is genuinely ambiguous (two intended changes truly conflict),
  stop and escalate the specific decision to the operator — do not guess.
- After a clean resolution, re-run the affected pipeline gates (`tests`, and
  `review` if the resolution changed logic) before proceeding to merge.

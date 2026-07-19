---
name: repo-sync
description: Keep managed clones current with origin so a worktree always branches off fresh main, never a stale one. Load at session start, before dispatching a task or creating a worktree, after any merge, and whenever the operator asks to "update my repos".
---

# repo-sync

A managed clone under `repos/<name>` is the base every worktree branches off.
If it drifts behind origin (a PR merged out-of-band, another clone pushed), a
new worktree inherits that staleness — we hit a 9-behind base once. This skill
is the freshness contract: keep clones current, and never touch one that can't
be caught up safely.

## The mechanic (already built — reuse it, never reimplement it)

```
bin/dm-sync.sh one <name>     # sync a single registered repo
bin/dm-sync.sh all            # sync every registered repo
```

Fast-forward ONLY. A clone only ever moves if the move is provably lossless (a
fast-forward on its default branch). Anything unsafe — diverged, dirty, on the
wrong branch — is reported as a `STUCK: <name> ...` line and left completely
untouched: never merged, rebased, reset, or forced. A `STUCK:` line means
report it and let a human resolve the clone; do not force past it.

## When sync happens

- **Session start** — `dm-session-start.sh` already runs `dm-sync.sh all` and
  surfaces `STUCK:` lines in the digest.
- **Before dispatching a task / creating a worktree** — `dm-worktree.sh create`
  now guards this automatically: it FF-syncs the repo's clone before cutting the
  worktree's base, and fails closed (never cuts a stale base) if the clone can't
  fast-forward. Under `DM_NO_FETCH=1` (offline/smoke) it skips the sync and does
  not block.
- **After any merge** — `dm-pr.sh merge` now FF-syncs the clone automatically,
  best-effort, right after a successful merge. After an OUT-OF-BAND merge (the
  operator merged on GitHub directly, or a `local-only` landing happened outside
  `dm-merge`), sync it by hand: `bin/dm-sync.sh one <name>`.
- **On request** — "update my repos" (or similar) → `bin/dm-sync.sh all`;
  reconcile any `STUCK:` lines before moving on.

## STUCK means stop, not force

A `STUCK:` line is a signal, not an obstacle. Never respond to it by forcing,
resetting, stashing, or discarding the clone's state — report it and let a
human resolve the divergence or dirty state, then re-sync.

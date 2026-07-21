# Security

## Trust model

The dockmaster is read-only over the repositories it manages except for a few
narrow, guarded fast-forward paths (clone, sync, approved local landing). It
never rewrites history, and it never discards unlanded work: teardown refuses a
worktree with unlanded commits or untracked files unless the operator passes
`--force`. Credentials a crewmate needs are passed **by reference, never by
value** — the secret is never written into a brief, commit, task record, log, or
review artifact.

There is exactly one force operation against a remote: after a PR merges
successfully, `bin/dm-pr.sh` may delete the merged branch with a
`--force-with-lease` pinned to the merged SHA, and only for a same-repo head.
A fork ref, or one that advanced since the merge, is never deleted. No path
force-pushes commits. (Locally, teardown calls `git worktree remove --force`,
but only after the unlanded-work and untracked-file refusals above have passed.)

## What is not protected

Be explicit about the boundary, because the guardrails are narrower than they
look:

- **The destructive-command guard is a guardrail, not a security boundary.**
  `bin/dm-command-guard.sh` (and the mirrored `.codex/rules/dockmaster.rules`)
  parse shell commands and deny destructive Git forms. Read the script for the
  current list, which is the authority — but understand its scope before relying
  on it. As of this writing it denies only `git reset`, `clean`, `restore`,
  `checkout`, and `switch` with a discard/force flag. It does **not** classify
  `git push --force`, `branch -D`, `stash`, `reflog expire`, `gc --prune`,
  `filter-branch`, `update-ref -d`, or `rm -rf`. Separately, it is a best-effort
  parser over an unbounded language: a command reached through a wrapper
  (`timeout`, `nohup`, `xargs`, `find -exec`, a shell indirection) evades every
  rule, and a tool that emits no Bash hook event is never seen at all. Both gaps
  are tracked in [#121](https://github.com/mengsig/dockmaster/issues/121).

  Note what this means against the trust model above: "never rewrites history"
  describes what the *dockmaster's own guarded paths* do. It is not a guarantee
  the guard enforces on an agent's shell commands — a force-push or a
  `reflog expire` issued directly is not currently blocked. Do not rely on the
  guard as the only thing standing between an agent and your repositories; the
  guarded toolbelt paths, worktree isolation, and the operating contract are the
  primary controls.
- **Agents run with your credentials.** A crewmate inherits the ambient `git`
  and `gh` authentication of the session. Worktree isolation bounds *which*
  working tree a task edits; it does not sandbox network or filesystem access
  outside the repo.
- **The review gate depends on you reading it.** Nothing merges without an
  explicit operator decision (`merge_authority`), but the content of a change is
  only as reviewed as you make it.

## Reporting a vulnerability

Report privately — please do **not** open a public issue for a security problem.
Use GitHub's private vulnerability reporting on this repository ("Security" tab →
"Report a vulnerability"), which discloses the report only to the maintainer.

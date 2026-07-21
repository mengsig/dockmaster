# Security

## Trust model

The dockmaster is read-only over the repositories it manages except for a few
narrow, guarded fast-forward paths (clone, sync, approved local landing). It
never rewrites history, and it never discards unlanded work: teardown refuses a
worktree with unlanded commits or untracked files unless the operator passes
`--force`. Credentials a crewmate needs are passed **by reference, never by
value** — the secret is never written into a brief, commit, task record, log, or
review artifact.

There is exactly one force operation in the toolbelt: after a PR merges
successfully, `bin/dm-pr.sh` may delete the merged branch with a
`--force-with-lease` pinned to the merged SHA, and only for a same-repo head.
A fork ref, or one that advanced since the merge, is never deleted. No path
force-pushes commits.

## What is not protected

Be explicit about the boundary, because the guardrails are narrower than they
look:

- **The destructive-command guard is a guardrail, not a security boundary.**
  `bin/dm-command-guard.sh` (and the mirrored `.codex/rules/dockmaster.rules`)
  parse shell commands and deny a specific set of destructive Git forms — read
  the script for the current list, which is the authority. It is a best-effort
  parser over an unbounded language: commands reached through a wrapper
  (`timeout`, `xargs`, `find -exec`, a shell indirection) can evade it, and a
  tool that emits no Bash hook event is never seen by it at all. Known gaps are
  tracked in [#121](https://github.com/mengsig/dockmaster/issues/121). Do not
  rely on it as the only thing standing between an agent and your repositories;
  the guarded toolbelt paths, worktree isolation, and the operating contract are
  the primary controls.
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

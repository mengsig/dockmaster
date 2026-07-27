# Security

## Trust model

The dockmaster is read-only over the repositories it manages except for a few
narrow, guarded fast-forward paths (clone, sync, approved local landing). Within
those paths it never rewrites history. It never discards unlanded work:
teardown refuses a worktree with unlanded commits or untracked files unless the
operator passes `--force`. Credentials a crewmate needs are passed **by
reference, never by value** — the secret is never written into a brief,
commit, task record, log, or review artifact.

There is exactly one force operation against a remote: after a PR merges
successfully, `bin/dm-pr.sh` may delete the merged branch with a
`--force-with-lease` pinned to the merged SHA, and only for a same-repo head.
A fork ref, or one that advanced since the merge, is never deleted. No path
force-pushes commits. (Locally, teardown calls `git worktree remove --force`,
but only after the unlanded-work and untracked-file refusals above have passed.)

## What is not protected

Be explicit about the boundary, because the guardrails are narrower than they
look:

- **Agents run with your credentials.** A crewmate inherits the ambient `git`
  and `gh` authentication of the session. Worktree isolation bounds *which*
  working tree a task edits; it does not sandbox network or filesystem access
  outside the repo.
- **The review gate depends on you reading it.** Nothing merges without an
  explicit operator decision (`merge_authority`), but the content of a change is
  only as reviewed as you make it.
- **A state archive is operator-private, and nothing encrypts it for you.** A
  `bin/dm-state.sh export` archive is as sensitive as `state/` itself: it carries
  the dockmaster-only memory store (the one that is never relayed to a crewmate),
  operator preferences, and — with `--with-artifacts` — briefs and scout reports.
  It additionally discloses your machine's directory layout: the manifest's
  `source_home` and the worktree paths in task records are absolute. Both are
  deliberate, because a restore needs them — but together they make the archive
  unfit to share, attach to an issue, or hand to a third party. It is a backup
  for you alone. Exporting moves that content past the machine boundary it was
  written under. The archive is written mode 0600 and `.env` is never included,
  but storing it encrypted, and keeping it out of any repository, is on you.

Guarded toolbelt paths, worktree isolation, `settings.json` permission rules,
and the operating contract are the primary controls against a confused or
destructive agent. Anything worth blocking at the command level belongs in
`permissions.deny`, which the permission engine evaluates in-process — no
timeout or exit-code race. There is no command-level PreToolUse guardrail
today: an earlier destructive-command parser was attempted and reverted
(arming it as a `PreToolUse` hook refused ordinary compound shell, and a hook
that times out fails open — a control that disarms itself on exactly the
inputs that take longest is not a control worth carrying), and it was later
removed rather than re-attempted. This repo's `.claude/settings.json` carries
`permissions.allow` only.

## Reporting a vulnerability

Report privately — please do **not** open a public issue for a security problem.
Use GitHub's private vulnerability reporting on this repository ("Security" tab →
"Report a vulnerability"), which discloses the report only to the maintainer.

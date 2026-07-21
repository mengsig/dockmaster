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
  `bin/dm-command-guard.sh` parses shell commands and refuses destructive Git
  forms; the script is the authority and [Command guard](#command-guard) below
  describes it. `.codex/rules/dockmaster.rules` is a **coarser second layer**,
  not a mirror of it: seven argv-prefix rules against an allowlist that refuses
  dozens more.

  Be precise about what the guard is for. It raises the cost of an *accidental*
  destructive command and catches the forms an agent actually emits — which is
  most of the real risk, because the usual failure is a confused agent, not a
  hostile one. It is **not** a sandbox and does not resist someone who knows it
  is there: it parses one command rather than interpreting a shell, so
  expansion and substitution resolve after it has already decided.

  Note what this means against the trust model above: "never rewrites history"
  describes what the *dockmaster's own guarded paths* do. Do not rely on the
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

## Command guard

`bin/dm-command-guard.sh` is a PreToolUse hook (wired from `.codex/config.toml`)
that parses a shell command and refuses Git forms that can lose work. It is an
**allowlist**: a Git subcommand is refused unless it is named permitted, so an
unrecognized or future subcommand fails closed.

Refused outright: `reset`, `clean`, `restore`, `checkout`, `gc`, `prune`,
`repack`, `filter-branch`, `update-ref`, `symbolic-ref`, `pack-refs`,
`read-tree`, `update-index`, `replace`, `rerere`, `maintenance`, `fast-import`,
`credential`, `daemon`, `send-email`, and `for-each-repo`. Each is refused
because it has no clean split between a safe and a destructive form — that is a
decision, not an oversight, and widening it is a one-line change.

Refused in their destructive form only, permitted otherwise: `push` that
forces/deletes/prunes a remote ref (including a bare `+refspec`), `branch`
delete/force, `tag` delete/force, forced `switch`, `worktree remove --force`,
`rm` with `-f` or with `-r` outside `--cached`, `reflog expire`/`delete`,
`stash` anything but `list`/`show`, `remote remove`/`set-url`/`prune`,
`submodule deinit`, `notes prune`/`remove`, `bisect reset`, and
`sparse-checkout` anything but `list`.

Wrappers do not help: `timeout`, `nohup`, `nice`, `env`, `sudo` and friends are
unwrapped, and an unrecognized executable holding a bare `git` token is refused
rather than assumed harmless — its real argv is whatever follows, which the
guard cannot see. A quoted string that *begins a command* — whether with `git`
itself, an env assignment, a wrapper, or a shell (`parallel " git push --force"`,
`parallel "timeout 5 git push --force"`, `parallel "sh -c 'git push --force'"`) —
is re-entered into the guard and classified by the normal segmentation, so a
destructive one is refused while ordinary prose mentioning git is not.
`xargs` is deliberately not unwrapped: it appends arguments from stdin, so the
argv the guard sees is never the one Git runs. At top level it is refused,
because it holds a bare `git` token that nothing can classify; inside a quoted
string it is re-entered like any other command runner.

Redirection of the Git process itself is refused in both spellings, since an
option guarded in only one of its two forms is a bypass: `--exec-path`,
`--git-dir` and `--work-tree` (joined or detached) alongside the environment
twins `GIT_EXEC_PATH`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and
friends, plus `PATH`, `LD_PRELOAD` and the `DYLD_*` loader variables. Pointing
Git at another repository is not merely a scoping change — that repository
supplies its own config and hooks. An unrecognized pre-subcommand option fails
closed for the same reason the subcommand list does.

**`-C <dir>` is a deliberate exception to that paragraph, not coverage.** It
reaches another repository — and so another config and another set of hooks —
exactly as `--git-dir` does, but the toolbelt uses it constantly and refusing it
is not viable. This class is narrowed, not closed.

The same both-spellings rule applies to the environment: Git falls back to the
plain-spelled variable when the `GIT_*` one is unset, so `PAGER`, `EDITOR`,
`VISUAL` and `SSH_ASKPASS` are refused alongside `GIT_PAGER`, `GIT_EDITOR` and
`GIT_ASKPASS`. Those four fallbacks were verified executing a payload against
git 2.54, not inferred. `MANPAGER` and `GIT_MAN_VIEWER` are refused as the same
family, but were not reproduced here and should be treated as unverified.

The guard also refuses the forms it knows would carry a refused command past the
allowlist as an opaque string: `rebase --exec`, `bisect run`,
`submodule foreach`, `difftool --extcmd`, an alias shadowing the invoked
subcommand, and any `-c`/`git config`/`GIT_*` setting of a config key whose
value Git executes (`core.pager`, `core.editor`, `diff.external`,
`credential.helper`, `pager.*`, `filter.*`, `*.command`, `*.driver`, …).

**This class is narrowed, not closed** — say so plainly rather than reading the
list as a boundary. Git keeps adding settings whose values it executes, the key
list is matched by pattern against a moving target, and a subcommand that grows
a new command-executing option gains it silently. Treat these rules as removing
the easy paths, not as an argument that no path remains.

**Deliberately permitted**, so this is a decision and not an oversight:

- `git push --force-with-lease` / `--force-if-includes` — the toolbelt itself
  uses lease-pinned force (`dm-pr.sh`), and it cannot clobber an unseen ref.
- `git rebase`, `merge`, `pull` — they refuse to run against a dirty tree.
- `git reflog` and `git stash list` — reading the recovery net destroys nothing,
  and `reflog` is the tool for recovering work someone else lost.
- ordinary two-level work: `remote add`, `submodule update`, `notes add`,
  `bisect start`, `rm --cached`, `worktree prune`.
- `git config` against a key Git does not execute, read or write
  (`git config --get user.email`). For an executing key BOTH are refused —
  `git config <key>` is itself a read, so splitting read from write would mean
  counting operands.
- `git <subcommand> --help`, which renders documentation and executes nothing.
- a Git alias that is defined but never invoked.
- text tools (`grep`, `echo`, `cat`, …) taking `git` as an argument.
- `git -C <dir>` — see the exception noted above.
- prose that merely mentions git (`--body "the git repo is broken"`). A quoted
  string that *begins* a command is re-entered into the guard and classified on
  its merits instead, so `parallel " git push --force"` is still refused.

**Known limits.** The guard is a guardrail, not a sandbox, and should not be
the only thing standing between an agent and a repository:

- **It sees only commands that emit a Bash tool event.** It is a `PreToolUse`
  hook on one tool. A specialized tool that edits files, calls an API, or drives
  a browser produces no Bash event, so the guard never runs — nothing reached
  that way is covered, however destructive.
- **It parses one command; it does not interpret a shell.** It has its own
  lexer, and a real shell will always resolve more than any parser models —
  variable expansion, command substitution, and dynamically assembled strings
  resolve at execution time, after the guard has already decided. It refuses the
  unresolved forms it can detect and fails closed on what it cannot classify,
  but detection is not a proof, and a determined caller with an interpreter is
  outside its reach.
- It classifies the command in front of it, not the repository's state.
  Execution-capable settings already written into a config file, or a hook
  already installed in `.git/hooks`, are not inspected — only the attempt to set
  one on the command line is.
- It does not restrict non-Git destruction (`rm -rf`, a build script, an
  interpreter). Worktree isolation and the operating contract carry that.
- It is enforced on the Codex runtime today; Claude-side wiring is #89.

Guarded toolbelt paths and the operating contract remain the primary controls.

## Reporting a vulnerability

Report privately — please do **not** open a public issue for a security problem.
Use GitHub's private vulnerability reporting on this repository ("Security" tab →
"Report a vulnerability"), which discloses the report only to the maintainer.

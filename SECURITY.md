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

- **The destructive-command guard is a guardrail, not a security boundary — and
  it is not wired into any runtime today.** `bin/dm-command-guard.sh` parses
  shell commands and refuses destructive Git forms; the script is the authority
  and [Command guard](#command-guard) below describes it, including why it is
  currently dormant.

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

> **Dormant today.** Nothing installs this guard as a PreToolUse hook, so it is
> not currently protecting any session. Read this section as the contract it
> will enforce once #89 wires it up. Arming was attempted and reverted: the
> guard refused ordinary compound shell, and a `PreToolUse` hook **fails open**
> (see [Why arming is not free](#why-arming-is-not-free)). The rest of this page
> assumes nothing from it.

`bin/dm-command-guard.sh` is a PreToolUse hook handler that parses a shell
command and refuses Git forms that can lose work. It is an
**allowlist**: a Git subcommand is refused unless it is named permitted, so an
unrecognized or future subcommand fails closed.

Refused outright: `reset`, `clean`, `gc`, `prune`, `repack`, `filter-branch`,
`update-ref`, `symbolic-ref`, `pack-refs`, `read-tree`, `update-index`,
`replace`, `rerere`, `maintenance`, `fast-import`, `credential`, `daemon`,
`send-email`, and `for-each-repo`. Each is refused
because it has no clean split between a safe and a destructive form — that is a
decision, not an oversight, and widening it is a one-line change.

Refused in their destructive form only, permitted otherwise: `push` that
forces/deletes/prunes a remote ref (including a bare `+refspec`), `branch`
delete/force, `tag` delete/force, forced `switch`, `worktree remove --force`,
`rm` with `-f` or with `-r` outside `--cached`, `reflog expire`/`delete`,
`stash` anything but `list`/`show`, `remote remove`/`set-url`/`prune`,
`submodule deinit`, `notes prune`/`remove`, `bisect reset`, and
`sparse-checkout` anything but `list`.

`restore` and `checkout` are in that second group rather than the first.
Restoring a drifted tracked file (a regenerated lockfile) is ordinary crew work,
so refusing the whole subcommand made the guard unadoptable — but `git restore
.` discards the entire working tree, which is exactly what the guard exists to
stop. Permitted only when scoped to literal paths: `git restore <path>…` and
`git checkout [<tree-ish>] -- <path>…`. No pathspec, `.`, a glob, `:` pathspec
magic, an argument the guard cannot read, or a `checkout` without `--` (which
moves HEAD rather than restoring a file) are all refused. The pathspec test runs
per **component**, not on the whole string: naming only `.` and `..` let
`../..`, `./.`, `.//` and `src/../..` through, and any of those from one
directory down discards the whole worktree. Absolute paths and brace expansion
are refused with globs. Be clear about the edge that remains: the test is
lexical, so a named *directory* passes and discards its whole subtree. What it
guarantees is that the caller named a scope, not that the scope is small.

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

Re-entry distinguishes **command position from argument position**. An option,
or the value of the option before it, is data the executable was handed — a
`--body`, a `--title`, an `-m` message — so a quoted sentence there is prose and
is not re-entered. Without that distinction the guard refused ordinary PR bodies
("watch the git log for changes", "xargs with git ls-files is faster"), and
over-blocking is the failure mode that gets a guard switched off.

Three rules keep that from becoming a hole, each with a test pinning it:

- a string whose own first word is `git` is classified **wherever** it sits, so
  `entr -s "git reset --hard"` and `rsync -e "git push --force"` are refused;
- a bare shell or runner token **in the arguments** makes the rest of the scan
  strict, so `find . -exec sh -c "git push --force" \;` and
  `docker run img sh -c "git reset --hard"` are refused. That path is not
  covered by the nested-shell rule, because there the shell is `find`'s
  argument rather than the segment's executable;
- a command runner keeps all of its arguments strict from the start
  (`flock -c "git push --force"`), and a bare `git` token is refused in every
  position (`find . -exec git reset --hard`).

**The narrowing that remains**, stated plainly: an unmodelled executable that
runs its own option value, where that value does *not* begin with `git` — say
`./deploy.sh --cmd "timeout 5 git push --force"` — is not classified.

The cost of the first rule, equally plainly: prose that *starts* with the word
`git` is still classified, so `--body "git push --force loses work"` is refused
while `--body "git log shows the bug"` passes. That is the same behavior the
guard has always had, and it is the price of keeping `entr -s "git reset
--hard"` refused. Lead such a sentence with any other word.

Shell **keywords** are transparent: the lexer models no grammar, so without this
`for r in a b; do git -C "$r" status; done` made `do` the executable and refused
ordinary compound shell. `if`, `while`, `until`, `for`, `do`, `done`, `case`,
`!`, `time` and friends are skipped so the real command behind them is the one
classified — `if git push --force; then` still refuses.

A **heredoc body** is stdin data, not commands, and is skipped: without that,
`--body "$(cat <<'EOF' … EOF)"` re-lexed the prose and any line holding a bare
`git` refused. `<<<` is a herestring, not a heredoc, and still reaches the rule
that refuses a shell fed unresolved stdin — `bash <<EOF … EOF` is refused too.

Content of a `$(…)` or backtick substitution is classified wherever it appears —
as the executable, in an argument, quoted or unquoted. Argument position used to
leak, so `echo $(git push --force)` ran the push. Content inside single quotes
is not classified, because the shell does not execute it either. Paren counting
is quote-aware (`$(grep "(" file)` is balanced to a real shell); a genuinely
unbalanced substitution is left opaque rather than refused, because a real shell
fails to parse it and runs nothing.

## Why arming is not free

Arming this guard is tracked in #89 and is **not** a matter of adding a hook.
Two properties of the runtime decide how much a `PreToolUse` hook can ever be
worth, and both were measured rather than assumed:

- **A hook that times out fails OPEN.** Verified on Claude Code 2.1.219: a
  `PreToolUse` command hook that sleeps past its `timeout` does **not** block —
  the tool runs. A control hook that exits 2 immediately blocks, so the hook
  was live and the timeout is what let the command through. The documentation
  states this for `UserPromptSubmit` but not for `PreToolUse`; this is an
  observed result, not a documented one.
- **Any exit code other than 0 or 2 also fails open** — documented. A crashed
  or missing guard script does not block anything.

Together those mean a slow or broken guard silently disarms on exactly the
inputs that take longest, which is why the parser is now linear in the command
length and why an oversized command is **refused** rather than parsed: the
guard decides deterministically instead of racing a timeout it loses silently.
A command over 64KB is refused; the largest command under that limit parses in
under 4s here. Whatever eventually arms this must set a timeout well clear of
that — the platform default is 600s, and the reverted attempt had pinned it to
10s, which would have created the race it was trying to prevent.

`permissions.deny` rules in `settings.json` are evaluated by the permission
engine rather than a subprocess, so they carry no timeout or exit-code race.
Anything expressible as a deny rule belongs there, not here.

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

The whole `GIT_TRACE*` family takes a destination. `1`, `2` and `true` write to
stderr and stay permitted, because `GIT_TRACE=1 git status` is the debugging
idiom; any other value names a file Git **appends** to, which is an unguarded
filesystem write through an otherwise allowed command, so it is refused. The
config twin (`trace2.*Target`) is refused the same way.

The guard also refuses the forms it knows would carry a refused command past the
allowlist as an opaque string: `rebase --exec`, `bisect run`,
`submodule foreach`, `difftool --extcmd`, an alias shadowing the invoked
subcommand, and any `-c`/`git config`/`GIT_*` setting of a config key whose
value Git executes (`core.pager`, `core.editor`, `diff.external`,
`credential.helper`, `pager.*`, `filter.*`, `*.command`, `*.driver`, …). The
tool families whose `.path` names an executable — `difftool.<t>.path`,
`mergetool.<t>.path`, `browser.<t>.path`, `man.<t>.path`, `guitool.<t>.path` —
are enumerated rather than matched as a blanket `*.path`, which also refused
`submodule.<name>.path`, a tree path that executes nothing. A new tool family
has to be added by hand.

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
  string that *begins* a command in an operand position is re-entered into the
  guard and classified on its merits, so `parallel " git push --force"` is still
  refused.
- `git restore <path>` and `git checkout [<tree-ish>] -- <path>`, scoped to
  literal paths — the drifted-lockfile restore, without which the guard could
  not be armed at all.
- `GIT_TRACE=1` and the other stderr trace destinations.
- ordinary compound shell: `if git diff --quiet; then …; fi`,
  `for r in …; do git -C "$r" status; done`, `time git status`, `! git diff`.
- a heredoc body, and a PR body assembled with `--body "$(cat <<'EOF' … EOF)"`.

**Known limits.** The guard is a guardrail, not a sandbox, and should not be
the only thing standing between an agent and a repository:

- **It sees only commands that emit a Bash tool event.** It is a `PreToolUse`
  hook on one tool. A specialized tool that edits files, calls an API, or drives
  a browser produces no Bash event, so the guard never runs — nothing reached
  that way is covered, however destructive.
- **It fails open when it is slow or broken.** See
  [Why arming is not free](#why-arming-is-not-free): a timed-out or crashed
  hook does not block the command. A guard cannot be the last line of defence
  when its failure mode is silence.
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
  interpreter). Worktree isolation, the settings.json permission rules, and the
  operating contract carry that — the guard will not stop `rm -rf`.
- **An option's value is treated as data** unless it begins with `git`, or a
  shell/runner token appeared earlier in the argument list. So an unmodelled
  executable running its own option value that starts with something else
  (`./deploy.sh --cmd "timeout 5 git push --force"`) is not classified.
- **A restore scoped to a named directory discards its subtree.** The pathspec
  test is lexical: it refuses `.`, `..`, any `./` or `../` component, absolute
  paths, globs and brace expansion, but `git restore src` names a scope without
  bounding its size. The guard does not stat the path.
- It is **not wired into a runtime today**, so it currently guards nothing. It
  is reachable as `dm-command-guard.sh check <command>` and as a hook handler,
  but no `settings.json` installs it. #89 owns the wiring.

Guarded toolbelt paths and the operating contract remain the primary controls.

## Reporting a vulnerability

Report privately — please do **not** open a public issue for a security problem.
Use GitHub's private vulnerability reporting on this repository ("Security" tab →
"Report a vulnerability"), which discloses the report only to the maintainer.

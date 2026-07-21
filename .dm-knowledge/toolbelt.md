# Toolbelt (`bin/dm-*.sh`)

Read before editing a `bin/` script. Each script's own header is the detail;
these are the constraints that are not obvious from the code you are editing.

- **[routing]** Every `bin/dm-*.sh` sources `dm-lib.sh` and is reachable via the
  `bin/dm` dispatcher (`dm <sub> ...` runs `bin/dm-<sub>.sh ...`; `dm help`
  lists them). Roles: `dm-session-start` startup digest; `dm-doctor` readiness +
  scaffold; `dm-status` read-only snapshot; `dm-repo` registry+memory;
  `dm-worktree` isolation; `dm-task` meta + on-demand state reconcile;
  `dm-brief`; `dm-branch-name`; `dm-pr` open/check/merge; `dm-merge` FF local
  land + rebase; `dm-sync` FF clone refresh; `dm-backlog`; `dm-lavish` review
  artifact; `dm-test` tests gate; `dm-memory` context system; `dm-thread-name`
  role-specific runtime labels; `dm-secondmate` locked supervisor identities;
  `dm-command-guard` destructive-Git command parsing. Point work at the right
  script instead of reinventing lifecycle logic.
- **[invariant]** Scripts in `bin/` must run on bash 3.2 (macOS default): no
  `mapfile`/`readarray`, no `declare -A`, no `${var^^}`/`${var,,}`, no `&>>`.
  Use while-read loops and parallel indexed arrays instead. No test pins this —
  CI runs macOS, but a local-only change can break it silently.
- **[invariant]** Shared-state writes (registry, task meta, memory appends) are
  serialized with the mkdir-based mutex in `dm-lib.sh` (`dm_lock`/`dm_unlock`) —
  not `flock` (absent on macOS). Not reentrant; do not set your own
  EXIT/INT/TERM trap between lock and unlock (the lock owns them, and its signal
  handlers clean up AND exit — a trapped signal must not resume the unlocked
  section). It self-heals only a DEAD-PID lock (reclaim serialized by a second
  lock, re-verified before removal); a stuck-but-alive or metadata-less lock
  fails visibly at ~30s.
- **[invariant]** `dm-lib.sh` owns task-meta syntax: ids and keys are
  allowlisted, keys cannot contain `=`/line breaks, and values cannot contain
  CR/LF. Validate there before locking so every writer shares the same injection
  guard.
- **[convention]** GitHub access splits by need: `jq`-parsed reads call plain
  `gh api` (`gh-axi api` emits YAML); mutations go through
  `dm_require_github_cli` (`.dm-knowledge/dm-104-gh-fallback`).
- **[pitfall]** `dm-repo.sh add` clones unconditionally and fails if
  `repos/<name>` already exists non-empty; there is no re-adopt path. To
  re-enroll an already-cloned repo, move the clone aside first, then run `add`.
- **[invariant]** `dm_repo_dir_or_none` is the SOLE owner of the
  `$DM_HOME/<registry path>` composition — never re-compose it (#119: an
  unregistered repo made the path component empty, so it resolved to `$DM_HOME`,
  the distro root, and the `.git` probe meant to catch that always passes there).
  Its exit codes are contract: `0` resolved, `2` no such repo (benign — a caller
  MAY continue, as `dm-sync`'s SKIP line does), **any other nonzero = the lookup
  FAILED** and must be propagated, never reported as "unknown repo" — that turns
  registry corruption into a healthy-looking fleet. `dm_repo_dir` is the
  die-on-failure wrapper. The rule is about COMPOSING a clone directory, not
  about looking at the field: reading `path` for display or inspection is fine.
  The smoke lint enforces a narrower, checkable PROXY — no `bin/` script outside
  `dm-lib.sh` calls `dm_registry_get … path` — chosen over a shape pattern
  because the same path can be rebuilt as `printf '%s/%s'`, `${DM_HOME}/...`, or
  a two-step variable. The proxy is partial by construction: it cannot see raw
  `jq '.repos[$n].path'`, nor a field passed as a variable (`dm-repo.sh get "$n"
  "$f"`). So closing routes at the SOURCE is the durable half — which is why
  `dm-repo.sh get <unknown> <field>` now dies instead of returning empty-success.
- **[invariant]** The distro resolves by RESERVED NAME, not by accident.
  `DM_DISTRO_REPO` (`dockmaster`) has no registry entry and must never gain one
  (`dm-repo.sh` refuses it; `dm-doctor` fails on a pre-existing entry rather than
  let the alias shadow a real repo). It resolves to `$DM_HOME` so the distro's
  own self-ship lifecycle works — `dm-worktree create`/`assert`/`landed`/`remove`
  — while a typo'd name still dies at the resolver. MUTATING the distro stays
  refused with no bypass: `dm-merge.sh local` (authority `never`), `dm-sync`
  (SKIP), and `dm_assert_not_distro` for any hand-edited path resolving there.
- **[pitfall]** `set -e` does NOT propagate out of a `[ ]` argument, a `case`
  word, or a nested command substitution. So `[ -d "$(dm_repo_dir "$r")/x" ]` and
  `"$(cmd "$(dm_repo_dir "$r")")"` SWALLOW a resolver `dm_die` — the message goes
  to stderr and execution continues with an empty value. Four call sites did
  this (#119); two were exploitable. Worse, `git -C ""` is a documented no-op
  that reads the CWD repo, so an empty path silently targets whatever repo you
  happen to be standing in. ALWAYS resolve into a variable, then test it.
- **[invariant]** `dm-worktree.sh landed` exits `2` for "could not determine",
  distinct from `1` for "not landed". The contract binds EVERY consumer, not just
  the one that motivated it — all three today: `dm-worktree.sh remove` (states the
  real reason rather than claiming unlanded work; `--force` still cleans up a
  worktree whose repo no longer resolves), `dm-task.sh state`, and `dm-status.sh`
  drift. A `! cmd` test folds 2 onto 1 and silently reasserts the false claim, so
  capture the rc. A refusal that misstates its reason is what trains reflexive
  `--force` (the #84 lesson).

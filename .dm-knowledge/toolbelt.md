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

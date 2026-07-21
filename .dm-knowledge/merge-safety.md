# Merge and landing safety

Read before touching `dm-pr.sh`, `dm-merge.sh`, or any merge gate in
`dm-lib.sh`. The operator-facing contract ("never merge without the operator's
explicit word", "never merge red") is prime directive 3 in `AGENTS.md`; the risk
tiers are in the `pr-workflow` skill. This is the enforcement underneath — every
gate here is deliberately pure and offline-testable, so keep new gates that way.

- **[invariant]** Landing/PR fields (`pr`, `pr_state`, `merge_state`, the atomic
  `pr_check_snapshot`, and the `merged` status event) are written ONLY by
  `dm-pr`/`dm-merge` (directly via `dm_meta_set`/`dm_status_append`);
  `dm-task.sh set`/`event` reject them so a crewmate cannot forge a landed
  signal. Merge/await consume the snapshot returned by their own `check`
  invocation, never a concurrently-overwritable cached snapshot. `dm-task.sh
  state`/`landed` refresh `pr_state` live (skipped under `DM_NO_FETCH=1`) so an
  out-of-band merge is seen; bulk `list` and `dm-status` run offline.
- **[invariant]** Never merge red: `dm-pr.sh merge` refuses
  `failing`/`pending`/`unknown`, and refuses `none` (no checks reported) unless
  `--allow-no-checks` AND the repo has no CI (`has_ci=0`, from
  `.github/workflows` absence in the worktree/clone) — once a repo has CI,
  `none` always refuses regardless of the flag (#49). `.github/workflows`
  presence is used only to FORBID the bypass, never to auto-pass `none`. The
  decision is the pure, offline-testable `dm_merge_gate <rollup>
  <allow_no_checks> <has_ci>`. Check-runs request one bounded 100-item page and
  become `unknown` if `total_count` proves it incomplete; only completed
  `success|neutral|skipped` conclusions pass, and unknown/future conclusions
  fail closed. Merge additionally requires state `OPEN`, matching local+remote
  head refs, and GitHub's atomic merge endpoint accepting the checked `sha`.
  Requested branch deletion happens only after success, only for same-repo
  heads, and through a server-enforced `--force-with-lease` pinned to the merged
  SHA; fork or concurrently-advanced refs are never deleted.
- **[invariant]** Per-repo `merge_authority` (yolo|ask|never) is an enforced
  merge gate, not just prose. `never` HARD-refuses in `dm-pr.sh merge` and
  `dm-merge.sh local` (before any gh call, no flag bypasses) via the pure
  `dm_merge_authority_gate <authority>`; it runs BEFORE the never-merge-red
  gate. Authority is read through `dm_merge_authority <repo>`, the single owner
  of the value and its legacy migration (old `yolo:true`→yolo,
  `yolo:false`/absent→ask); `dm-repo.sh set merge_authority` (and the `yolo`
  alias) drop the legacy key so the two never coexist. `dm-repo.sh
  list`/`dm-status` show it as the AUTH column. `ask` and `yolo` permit the
  mechanics — operator approval for `ask`, and for HIGH-risk work even under
  `yolo`, stays a skill duty; the gate itself is risk-blind.
- **[invariant]** The ONE carve-out to `never`: a repo with operator-granted
  `merge_allowed_bases` (registry array, `dm-repo.sh set <repo>
  merge_allowed_bases "<csv>"`, empty clears; read via
  `dm_merge_allowed_bases`) lets `dm-pr.sh merge` proceed to the normal
  downstream gates ONLY for a PR whose LIVE GitHub base branch (fetched at merge
  time, never trusted from task meta) exactly full-string matches a listed
  branch and is neither the LIVE default branch (same-response snapshot) nor the
  registry `default_branch` — decided by the pure `dm_merge_base_exception
  <authority> <base> <default_branch> <allowed_bases>` run against both anchors,
  which fails closed (non-never authority, empty/unverifiable base or default,
  empty list, default-branch base even if listed, partial match, whitespace →
  refuse), and re-verified immediately before the merge mutation (TOCTOU guard:
  any base change since first verification refuses; the residual instant is
  inherent to GitHub's API). Write guards hold the invariant in both directions:
  `set merge_allowed_bases` refuses the default branch and refuses entirely when
  `default_branch` is unset; `set default_branch` refuses a currently-listed
  name. `dm-merge.sh local` has NO exception: it always lands on the default
  branch, so `never` keeps hard-refusing there.
- **[invariant]** `dm_merge_authority` fails CLOSED on anything it cannot vouch
  for (#119): an unregistered repo, a null registry entry, or an unreadable
  registry returns `invalid` (→ `refuse-invalid`), never the permissive legacy
  `ask` default. The reserved distro name returns `never` — the dockmaster may
  not merge or land the distro; the operator merges its PRs on GitHub. Only an
  absent `merge_authority` FIELD on a REGISTERED repo still migrates via the
  legacy `yolo` boolean.
- **[consequence]** Because `dm-repo.sh` refuses the reserved distro name,
  `merge_allowed_bases` can never be granted for the distro — its authority is
  fixed at `never`. Deliberate: no code change should be able to relax it. If
  the integration-branch workflow needs that carve-out for the distro, it is an
  operator decision, not a code fix.
- **[pitfall]** `has_ci` is an INPUT to the merge gate, so a wrong answer there
  unlocks a bypass: `dm_merge_gate none 1 0` returns `allow`. `task_has_ci` used
  to answer "no CI" whenever its repo lookup failed (the `set -e`-in-`[ ]`
  swallow — see `toolbelt.md`), so an unresolvable repo silently satisfied
  `--allow-no-checks`. It now refuses. Treat any "default to the permissive
  value on error" in a gate input as the same bug.
- **[pitfall]** `repo_slug` derives the GitHub slug from the clone's origin. When
  its lookup failed, `git -C ""` read the CWD repo instead — in production the
  distro — and `dm-pr.sh check` then WROTE `pr_state`/`checks`/`merge_state`/
  `pr_head`/`pr_check_snapshot` from the wrong repository (observed returning
  `MERGED`), while `adopt`'s cross-repo guard compared against that same wrong
  slug. Any code deriving a remote/slug must resolve the directory first and
  refuse on failure, never fall through to the working directory.

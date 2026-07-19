---
name: pr-workflow
description: Modular, per-repo PR pipeline run AFTER lavish approval. Two review passes (coldstart then merge-gate), each followed by fix + tests, then PR creation and the merge-authority gate. Load once the operator has approved a change and chosen the PR path.
---

# pr-workflow

Runs **after** the operator has approved the change on its lavish artifact and
chosen "PR" (see `change-review`). A PR is produced by running an **ordered list
of gates** declared in config, so a pipeline is declared, not hard-coded —
reorder, drop, or add gates by editing one array.

## Where the pipeline comes from

1. Per repo: `config/pr-pipeline.<repo>.json` if it exists.
2. Otherwise: `config/pr-pipeline.default.json`.

## Rigor tiers

Scale review rigor to stakes. The tier is a **per-task** choice (not a per-repo
default); when in doubt, use `default`.

**Right-size each pass, not just the tier.** The current Codex collaboration
call has no per-spawn model/effort selector, so right-size with gate choice,
focused prompts, and agent count. Use `fork_turns="none"` for fresh reviewers;
give each only the diff, changed files, lens, and acceptance criteria. Do not
claim per-child model control unless the active surface exposes and proves it.
The advisory tier `dm-brief` surfaces (and `dm-status` flags when a `working`
task is unsized) is the same signal — use it to bias gate choice and agent count.

- **`fast`** (`config/pr-pipeline.fast.json`) — **objectively trivial** changes
  only (see `change-review` for the criteria): one review pass instead of two,
  the lavish approval gate may be skipped. Tests still run; merge authority
  unchanged.
- **`default`** (`config/pr-pipeline.default.json`) — **the norm.** Two
  independent review passes (coldstart, then merge-gate), each followed by
  fix + tests.
- **`rigorous`** (`config/pr-pipeline.rigorous.json`) — **high-stakes changes.**
  Select it for: this distro's own merge-gate / safety-gate code, auth,
  migrations, concurrency or locking, anything touching money or secrets, or any
  change the operator is nervous about. It replaces the two generalist passes
  with a dimension-parallel cold review, adversarially verifies every finding
  before spending a fix round, and adds a behavioral `verify` gate.

The tiers share one gate schema, so a tier is just a different ordered `gates`
array. The two new mechanics the rigorous tier introduces are executable
procedure the dockmaster drives with native Codex collaboration (and the
compatible-host runner drives with its injected API):

- **dimension-parallel review** — instead of one generalist read, spawn one
  fresh reviewer per lens (`dimensions`: `correctness`, `security`,
  `concurrency`, `portability`, `tests`), each reading **only** the diff
  `git -C <worktree> diff <base>...HEAD`. Merge their findings. One cold pass,
  fanned out by lens.
- **adversarial `verify-findings`** — before any fix round, each review finding
  is independently checked by `voters` skeptics (default 3), **each prompted to
  REFUTE it** by citing the actual code. A finding survives only if it is **not
  refuted by a majority** (a tie is not a majority). This is the key quality
  lever: it kills plausible-but-wrong findings before they cost a fix cycle. Only
  the survivors go to `fix`.

Before each reviewer or skeptic wave, inspect `list_agents` and the durable task
owners. The six-thread ceiling still reserves three slots for waiter/recovery;
therefore launch at most three review children at once, and fewer when fewer
slots are actually free. Run the five lenses as bounded waves (for example 3+2)
and skeptic votes as one wave of at most three; with one free slot, run serially.
With zero free slots, wait or report capacity—never exceed the ceiling or skip a
lens/vote.

The rigorous gate order is
`review (dimension-parallel) → verify-findings → fix → tests → verify → security
→ pr`. The behavioral `verify` gate drives the changed behavior end to end and
reports what was actually exercised — not just that tests pass; it is skippable
only when the diff has no runtime surface (docs/config-only). `security` is
auto-triggered (`bin/dm-pr.sh security-scan`, then a focused general security
reviewer only on a hit, else an explicit skip), and `pr` opens the PR. Waiting
for CI is **not** a pipeline gate — it runs in the operator-mediated merge tail
after the PR opens (see "Merge authority" below). The never-merge-red merge gate
and the lavish-approval-first ordering are unchanged across all three tiers.

The file has a `gates` array. Run the gates top to bottom. A repo's delivery
**mode** (registry: `pipeline` | `direct-pr` | `local-only`) shapes it:

- **pipeline** — run the full two-pass gate list below, ending in a PR.
- **direct-pr** — skip the review/fix passes; the crewmate opens the PR through
  `bin/dm-pr.sh open <id>` so the URL is recorded to the task record (`check` and
  `merge` need it); you then enforce the merge gate with `bin/dm-pr.sh check`. If
  a PR was opened out of band, record its URL first with
  `bin/dm-pr.sh adopt <id> <url>` (validates the url is a canonical PR for the
  task's own repo, then records it and queries its real state).
- **local-only** — no PR; this skill does not apply. Land with
  `bin/dm-merge.sh local <id>` after approval (see `task-lifecycle`).

## The canonical pipeline (two review passes)

```
coldstart review → fix → tests → merge-gate review → fix → tests → pr
```

The two passes are deliberate: the first is a cold, independent read that will
surface most issues; the second is a stricter gate on the *already-fixed* code,
so nothing introduced by the fixes slips through. Each gate reads the task's
worktree/branch from meta, communicates only through the task record, and
**stops the pipeline and reports** if it cannot pass.

- **review (coldstart)** — `spawn_agent(..., fork_turns="none")` for a *fresh*
  reviewer using the available review skill, or a focused general reviewer when
  that optional skill is absent. It reads only the diff
  `git -C <worktree> diff <base>...HEAD` and the changed files. It must not trust
  the crewmate's summary. Report concrete findings ranked by severity;
  correctness and safety before style.
- **fix** — hand the findings to the implementing crewmate as one exact
  instruction; it fixes on the same branch and commits. Loop up to `max_rounds`;
  escalate if findings persist past the cap.
- **tests** — `bin/dm-test.sh <id>` runs the repo's registered test command in
  the worktree and records the result. Non-zero fails the gate. No registered
  command → it reports a soft skip (never a fabricated pass).
- **review (merge-gate)** — a second, independent reviewer pass acting as the
  final gate before the PR: same cold-read discipline, on the fixed tree. This
  is the "merge gate."
- **fix / tests** — resolve any merge-gate findings and re-confirm green.
- **verify** — rigorous only. Unless the diff is proven docs/config-only, spawn a
  fresh no-fork general verifier using a label from `bin/dm-thread-name.sh
  <id> verify`. Give it the acceptance criteria, worktree, and diff base. It
  must exercise the affected behavior end to end without editing: use the real
  browser for a web flow, otherwise the narrowest executable CLI/API path. It
  returns `PASS` with observed evidence or `FAIL` with concrete findings. A
  missing browser/runtime/capability is `FAIL`, never a skip.
- **security** — optional or auto. Run `bin/dm-pr.sh security-scan <id>` first.
  On a hit, spawn a fresh no-fork general reviewer using a label from
  `bin/dm-thread-name.sh <id> security` with this exact scope: inspect only
  `<base>...HEAD` and changed files for auth/authz, input validation/injection,
  secret exposure, crypto misuse, unsafe external I/O, and privilege/data-loss
  paths; do not edit; return `PASS` or ranked concrete findings with file/line
  evidence. Any finding or unavailable review capability fails the gate. Exit 1
  from the scan means an explicit no-security-surface skip, not a pass claim.
- **pr** — open the PR (below).

Adding a gate: document it here with the same contract (single responsibility,
reads meta, fails closed, machine-readable pass/fail), then add its name to the
`gates` array. Reordering/removing is just editing the array. A review gate's
`pass` field (`coldstart` | `merge-gate`) names which pass it is.

## Branch naming

`<type>/<issue>/<slug>` computed by `bin/dm-branch-name.sh <type> <issue|x> "<summary>"`.

- `type` ∈ `feat fix bug chore refactor docs perf test build ci`
- `issue` = the issue/ticket number, or `x` when there is none
- `slug` = short kebab summary

Example: `bin/dm-branch-name.sh fix 412 "flaky login test"` → `fix/412/flaky-login-test`.

## Opening the PR

Always through `bin/dm-pr.sh open <id> --title "<title>" --body-file <file>`.
It pushes the branch, opens the PR against the repo default, and records the URL.

**Title**: imperative, specific, lowercase-first is fine. e.g. `fix flaky login test`.

**Description** — short, plain, and human. Write it the way a working engineer
writes a PR: what changed, why, and how it was checked. Structure:

```
<one-line summary of the change>

<1-3 sentences of context: the problem and the approach, only if not obvious>

- key change 1
- key change 2

Risk: low|medium|high. Verified: <how — tests, manual check>.
```

Hard rules for the description:
- No "Generated by", no "Co-Authored-By: <agent>", no "as an AI" — nothing that
  reads as machine-authored.
- No filler openers ("This PR...", "In this change we..."). Lead with the change.
- No restating the diff line by line. Say what matters.
- Link the issue with `Closes #<n>` when there is one.

## After the PR is open

Opening the PR is not the end. Review comments and post-open CI failures are the
pipeline's tail — load `post-pr-review` to handle them on the same branch until
reviewers are satisfied and checks are green, then apply the merge gate below.

## Merge authority (the final gate)

Once the PR is open, report the full `https://…` URL and a plain outcome, then
one of two paths — the operator's choice:

- **Operator merges on GitHub.** The dockmaster watches for it with the bounded
  `bin/dm-pr.sh await-checks <id>`/`check` path or a scheduled task and, once it
  reports `state: MERGED`, refreshes the clone (`bin/dm-sync.sh one <repo>`) and
  tears down.
- **Dockmaster merges after approval.** Only when the repo's `merge_authority`
  allows it (`ask` or `yolo`; a `never` repo is operator-merge-only — see below).
  The dockmaster asks "approve merge?"; on an explicit yes — or, under a standing
  `yolo`, for a LOW/MEDIUM-risk green change (see **Risk tiers** below; a
  HIGH-risk change always needs the explicit yes even under `yolo`) — it runs
  `bin/dm-pr.sh merge <id> [--method squash] [--delete-branch]`, then syncs and
  tears down.
- **`merge_authority=never` — operator merges on GitHub, always.** The pipeline
  runs to completion and the PR is reported merge-ready; `bin/dm-pr.sh merge`
  hard-refuses (before any GitHub call, no flag bypasses). Report the PR URL and
  let the operator merge.

**Wait for CI, don't refuse it.** `bin/dm-pr.sh merge` checks CI exactly once and
refuses a still-pending PR. When Actions is mid-run, first
`bin/dm-pr.sh await-checks <id> [--timeout-secs N] [--interval-secs N]` — it polls
`check` until the CI rollup is terminal (`passing`/`failing`/`none`) or it times
out (defaults ~600s / ~15s), exiting 0 on passing/none and non-zero on failing or
timeout. Run it before the merge gate so the gate acts on a settled result; on a
non-zero exit, do not attempt the merge.

**Never merge red** — `await-checks` is only a wait, never a relaxation:
`bin/dm-pr.sh merge` still refuses a failing or pending PR, and you must also have
the operator's actual approval (and a repo whose `merge_authority` is not
`never`). Destructive, irreversible, or security-sensitive merges are HIGH risk
and always escalate, even under `yolo`.

### Risk tiers (canonical — what a standing `yolo` may auto-merge)

`merge_authority` is enforced in the toolbelt, but the risk tier is a **judgment
the supervising dockmaster makes** — the bash gate is risk-blind (it only knows
`yolo|ask|never`). Under a standing `yolo`, the dockmaster may auto-merge a green
**LOW or MEDIUM** risk change without asking; a **HIGH-risk** change behaves like
`ask` everywhere — it always needs the operator's explicit word, even in a `yolo`
repo. `never` stays absolute (mechanically refused) regardless of tier.

- **HIGH** — security/auth changes; destructive or irreversible effects; data
  migrations or schema changes; secrets handling; public API/contract breaks;
  safety-critical toolbelt / merge-gate / state logic; or anything the reviewer
  flags as risky. Always needs the operator's explicit yes.
- **MEDIUM** — ordinary logic changes covered by tests.
- **LOW** — docs/copy, config values, trivial diffs.

When unsure which tier applies, treat the change as the **higher** tier.

**`--allow-no-checks` is for CI-less repos only.** On a repo with
`.github/workflows`, the merge gate refuses a `none` rollup outright — always
`await-checks` after opening the PR and merge only once checks go green.
`--allow-no-checks` bypasses `none` solely when the repo has no CI configured;
it can never be used to skip real checks that just haven't registered yet.
`await-checks` itself keeps polling on a `none` rollup while the repo has CI
(that's the race window before Actions registers a check) and only treats
`none` as terminal on a confirmed CI-less repo.

**`dm-pr.sh merge` also refuses on `mergeable_state`**, independent of CI:
`dirty` (merge conflicts), `draft` (still a draft PR), and `blocked` (required
checks/reviews not satisfied) all refuse outright — resolve the conflict/draft/
requirement, then retry. `unknown` does not refuse (GitHub often hasn't
computed it yet on first fetch); `gh pr merge`'s own failure is the backstop.

**Rebase a behind-main branch before merging.** If the branch has drifted
behind the base, rebase it first so CI validates the actual combined state,
not a stale diff against an older base (see `merge-conflict` if the rebase hits
conflicts).

## Optional: compatible-host runner

The default is the native `spawn_agent(..., fork_turns="none")` procedure above.
`workflows/pr-pipeline.js` is an opt-in adapter only for a compatible host that
injects its documented `args`, `agent`, `parallel`, and `log` API. It has a
built-in gate list for each tier (`fast` | `default` | `rigorous`) when the host
passes no explicit `gates`. The host also passes its currently available review
slots as `parallelCapacity` (1..3); the runner batches every `parallel()` call to
that bound. Do not invoke a nonexistent Codex workflow primitive
or treat the file as auto-discovered. If the injected API is absent, run the
complete native path; never skip a gate. A live rigorous run remains a
dockmaster/operator action. See `config/README.md` for executor coverage.

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

**Right-size each pass, not just the tier.** Beyond picking the tier, set the
`model` and `effort` of every reviewer, verifier, and fix agent you spawn to fit
the diff's difficulty — the resourcing policy in `task-lifecycle` (§3 Dispatch).
A low-stakes diff's cold review can run on a small fast model; a subtle
safety / concurrency diff's review and adversarial verification get the top tier
at high effort. Bias toward enough power to catch what matters — never under-power
a review to save tokens.

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
procedure the manhandler drives agent-style (and the optional runner drives the
same way):

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

The rigorous gate order is
`review (dimension-parallel) → verify-findings → fix → tests → verify → security
→ pr`. The behavioral `verify` gate drives the changed behavior
end to end (via the `verify` skill) and reports what was actually exercised — not
just that tests pass; it is skippable only when the diff has no runtime surface
(docs/config-only). `security` is auto-triggered (`bin/mh-pr.sh security-scan`,
then `security-review` only on a hit, else an explicit skip), and `pr` opens the
PR. Waiting for CI is **not** a pipeline gate — it runs in the operator-mediated
merge tail after the PR opens (see "Merge authority" below). The never-merge-red
merge gate and the lavish-approval-first ordering are unchanged across all three
tiers.

The file has a `gates` array. Run the gates top to bottom. A repo's delivery
**mode** (registry: `pipeline` | `direct-pr` | `local-only`) shapes it:

- **pipeline** — run the full two-pass gate list below, ending in a PR.
- **direct-pr** — skip the review/fix passes; the crewmate opens the PR through
  `bin/mh-pr.sh open <id>` so the URL is recorded to the task record (`check` and
  `merge` need it); you then enforce the merge gate with `bin/mh-pr.sh check`. If
  a PR was opened out of band, record its URL first with
  `bin/mh-pr.sh adopt <id> <url>` (validates the url is a canonical PR for the
  task's own repo, then records it and queries its real state).
- **local-only** — no PR; this skill does not apply. Land with
  `bin/mh-merge.sh local <id>` after approval (see `task-lifecycle`).

## The canonical pipeline (two review passes)

```
coldstart review → fix → tests → merge-gate review → fix → tests → pr
```

The two passes are deliberate: the first is a cold, independent read that will
surface most issues; the second is a stricter gate on the *already-fixed* code,
so nothing introduced by the fixes slips through. Each gate reads the task's
worktree/branch from meta, communicates only through the task record, and
**stops the pipeline and reports** if it cannot pass.

- **review (coldstart)** — spawn a *fresh* reviewer subagent (`code-review`
  skill, or a general agent at the configured `effort`) that reads only the diff
  `git -C <worktree> diff <base>...HEAD` and the changed files. It must not trust
  the crewmate's summary. Report concrete findings ranked by severity;
  correctness and safety before style.
- **fix** — hand the findings to the implementing crewmate as one exact
  instruction; it fixes on the same branch and commits. Loop up to `max_rounds`;
  escalate if findings persist past the cap.
- **tests** — `bin/mh-test.sh <id>` runs the repo's registered test command in
  the worktree and records the result. Non-zero fails the gate. No registered
  command → it reports a soft skip (never a fabricated pass).
- **review (merge-gate)** — a second, independent reviewer pass acting as the
  final gate before the PR: same cold-read discipline, on the fixed tree. This
  is the "merge gate."
- **fix / tests** — resolve any merge-gate findings and re-confirm green.
- **security** — optional. Run `security-review` on the diff only when the change
  touches auth, input handling, secrets, crypto, or external I/O. To make the
  skip deliberate rather than silent, `bin/mh-pr.sh security-scan <id>` greps the
  task's diff for those signals and prints whether a review is warranted (exit 0
  = signals found, 1 = none); it is advisory only and never blocks. Skip
  explicitly when there is no security surface; do not stack it as a reflex.
- **pr** — open the PR (below).

Adding a gate: document it here with the same contract (single responsibility,
reads meta, fails closed, machine-readable pass/fail), then add its name to the
`gates` array. Reordering/removing is just editing the array. A review gate's
`pass` field (`coldstart` | `merge-gate`) names which pass it is.

## Branch naming

`<type>/<issue>/<slug>` computed by `bin/mh-branch-name.sh <type> <issue|x> "<summary>"`.

- `type` ∈ `feat fix bug chore refactor docs perf test build ci`
- `issue` = the issue/ticket number, or `x` when there is none
- `slug` = short kebab summary

Example: `bin/mh-branch-name.sh fix 412 "flaky login test"` → `fix/412/flaky-login-test`.

## Opening the PR

Always through `bin/mh-pr.sh open <id> --title "<title>" --body-file <file>`.
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

- **Operator merges on GitHub.** The manhandler watches for it (poll
  `bin/mh-pr.sh check <id>` via `Monitor`, or on a merged-PR wake) and, once it
  reports `state: MERGED`, refreshes the clone (`bin/mh-sync.sh one <repo>`) and
  tears down.
- **Manhandler merges after approval.** The manhandler asks "approve merge?"; on
  an explicit yes (or a repo's standing `yolo` for routine work) it runs
  `bin/mh-pr.sh merge <id> [--method squash] [--delete-branch]`, then syncs and
  tears down.

**Wait for CI, don't refuse it.** `bin/mh-pr.sh merge` checks CI exactly once and
refuses a still-pending PR. When Actions is mid-run, first
`bin/mh-pr.sh await-checks <id> [--timeout-secs N] [--interval-secs N]` — it polls
`check` until the CI rollup is terminal (`passing`/`failing`/`none`) or it times
out (defaults ~600s / ~15s), exiting 0 on passing/none and non-zero on failing or
timeout. Run it before the merge gate so the gate acts on a settled result; on a
non-zero exit, do not attempt the merge.

**Never merge red** — `await-checks` is only a wait, never a relaxation:
`bin/mh-pr.sh merge` still refuses a failing or pending PR, and you must also have
the operator's actual approval. Destructive, irreversible, or security-sensitive
merges always escalate, even under `yolo`.

**`--allow-no-checks` is for CI-less repos only.** On a repo with
`.github/workflows`, the merge gate refuses a `none` rollup outright — always
`await-checks` after opening the PR and merge only once checks go green.
`--allow-no-checks` bypasses `none` solely when the repo has no CI configured;
it can never be used to skip real checks that just haven't registered yet.
`await-checks` itself keeps polling on a `none` rollup while the repo has CI
(that's the race window before Actions registers a check) and only treats
`none` as terminal on a confirmed CI-less repo.

**`mh-pr.sh merge` also refuses on `mergeable_state`**, independent of CI:
`dirty` (merge conflicts), `draft` (still a draft PR), and `blocked` (required
checks/reviews not satisfied) all refuse outright — resolve the conflict/draft/
requirement, then retry. `unknown` does not refuse (GitHub often hasn't
computed it yet on first fetch); `gh pr merge`'s own failure is the backstop.

**Rebase a behind-main branch before merging.** If the branch has drifted
behind the base, rebase it first so CI validates the actual combined state,
not a stale diff against an older base (see `merge-conflict` if the rebase hits
conflicts).

## Optional: deterministic runner

The default is to drive the gates above with ordinary `Agent` calls. For a
hands-off run of the whole pipeline instead, `workflows/pr-pipeline.js` executes
the same gates as a `Workflow` with zero-token idle between stages. It has a
built-in gate list for each tier (`fast` | `default` | `rigorous`), selected by
`tier:` when the caller passes no explicit `gates` — e.g. the `rigorous` tier
(dimension-parallel review via `parallel()`, adversarial `verify-findings`, then
fix → tests → verify → security → pr). It is opt-in and not wired to anything — invoke it via the
Workflow tool only when the operator has asked for multi-agent orchestration, and
a live **rigorous** run is a manhandler/operator action. See `config/README.md`
for which config fields it reads versus the agent-driven path.

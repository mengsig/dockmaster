# Runtime validation evidence

Validated 2026-07-19 in the task worktree. All live prompts were non-mutating:
Claude used plan permissions; Codex used an ephemeral read-only execution. Raw
auth/session output existed only while each assertion ran and was then deleted.
The mode-0700 evidence directory is removed on success or failure by default;
`--keep-evidence` retains only sanitized statuses plus version/help output.

> **Read this as a dated snapshot, not a standing guarantee.** Every absolute
> number below (test counts, byte sizes, CLI versions, token counts) is what one
> run measured on the date above, and nothing in CI pins this document to the
> code — so these figures drift as the repo moves and are expected to be stale.
> The before/after byte table is a record of one change's impact and is
> deliberately *not* refreshed; rewriting "after" would destroy the delta it
> documents. What *is* continuously enforced lives in the tests themselves: the
> 32,768 B shared-instruction cap, the per-file Claude SHA-256 pins, the exact
> 13/9/6 capability split, and the 18-skill parity checks all fail CI on drift.
> To see current numbers, run the commands rather than trusting this table.

## Automated evidence

| command | result |
| --- | --- |
| `bash tests/smoke.sh` | passed, 0 failed; includes wrapper/alias guard probes, fail-closed supervisor status, ordered fleet ownership, runner-command mutation, recursive runtime inventory, and all prior lifecycle/safety regressions |
| `node tests/check-runtime-parity.js` | 18 exact skills/triggers; 28 capability-specific assertions classified as 13 direct, 9 contract, and 6 manual; vocabulary separation, durable identities, and executable rigorous fallbacks |
| `node tests/check-pr-runner.js` | table-driven fast/default/rigorous order, capacity-bounded review/voter waves, full porcelain checks around every mutation/gate, every failure, skips, malformed PR, and unavailable-host paths |
| `node tests/check-gate-drift.js` | all three built-in gate sequences match shipped configs |
| `bash tests/runtime-performance.sh` | deterministic context, per-file Claude SHA-256, exact inventory, and same-size no-regression guardrails passed; startup sampling disabled by default |
| `bash tests/runtime-codex-offline.sh` | pinned Codex 0.144.6 strict doctor, structured discovery, execpolicy, and spaced-path hook handler passed without model login |
| Node 14 compatibility run | runner, parity, and performance checks passed on the documented minimum |
| `bash tests/runtime-smoke.sh --live` | canonical/symlink discovery, command-guard probes, both authenticated model probes, real PreToolUse block, and default evidence cleanup passed |

## Installed runtimes

| runtime | version | config/discovery proof | authenticated proof |
| --- | --- | --- | --- |
| Claude Code | 2.1.215 | CLI/auth probe passed; existing `.claude/settings.json` parsed | loaded project task/fleet lifecycle; confirmed queued → returned-owner persistence → inflight and returned `RUNTIME_OK` under plan mode |
| Codex CLI | 0.144.6 | strict config parsed; canonical and symlink-root prompt checks found exact structured descriptions/locators for all skills; mutations failed; quoted/nested/indirect rule/parser probes passed | ephemeral read-only run confirmed native fleet ownership plus dispatch/waiter/rigorous contracts and returned `RUNTIME_OK`; the injected project PreToolUse hook blocked absolute-path `git -C ... restore` |

The isolated Claude worktree had not accepted Claude's trust dialog, so the CLI
reported that its 45 project permission allow entries were ignored. This did not
prevent `CLAUDE.md`, `AGENTS.md`, or skill discovery—the live proof passed—but a
normal installation must accept each runtime's project trust prompt before its
project-local permission/config layer is relied on.

Codex trust is path-specific, so this isolated worktree did not load its project
hook directly. The live hook proof injected the same checked handler for one
ephemeral invocation with `--dangerously-bypass-hook-trust`; it persisted no
trust change. Normal use loads `.codex/config.toml` only after project and hook
trust. Rules and hooks remain guardrails, not complete enforcement boundaries.

## Real Codex collaboration proof

From a Codex child thread (depth 1), the root spawned
`task_runtime_nesting_probe_secondmate_4f26853b1de4` with `fork_turns="none"`.
The depth-2 worker returned `NESTED_OK`. A `followup_task` on the same idle
thread returned `FOLLOWUP_OK`.
This directly proves the secondmate → worker nesting edge and same-thread
follow-up surface used by the adapter. No model/effort selector was present in
the actual spawn call, so the adapters make no per-child selection claim.

The approval-wake regression used the repeatable manual procedure in
`tests/runtime-waiter-live.md`. The no-fork
`task_runtime_waiter_probe_review_waiter_e7c4cdc551b0` ran the deterministic
child synchronously and returned `WAITER_COMPLETION_OK` through the parent
mailbox, without a terminal read or file poll. CI runs only the child sentinel
and labels mailbox delivery manual; it does not overclaim this live observation.

## Performance evidence

| model-visible or startup surface | before | after | result |
| --- | ---: | ---: | --- |
| shared `AGENTS.md` | 26,634 B (~6,659 tokens) | 27,252 B (~6,813 tokens) | +618 B / +2.32%; under explicit 32,768 B cap |
| Claude settings | 1,579 B | 1,579 B | byte-identical |
| Claude full skill bodies on disk | 80,906 B | 82,540 B | +1,634 B including durable fleet ownership; every discovered runtime file SHA-256 pinned |
| Claude discovery descriptions | 4,603 B | 4,603 B | byte-identical |
| Codex adapter/config/rules | none | 89,224 B / 516 B / 1,746 B | full bodies load only when selected; descriptions 4,567 B, under documented 8,000-character fallback budget |

A bounded opt-in five-run local `--version` process-start sample reported
medians of 68.5 ms for Claude and 40.5 ms for Codex. Each child has a three-second
timeout and any failure is a non-fatal diagnostic. This is process overhead, not
model inference latency, and is reported only as a diagnostic—not used to claim
network/model speed. The guardrail instead enforces the causal performance
properties: Claude files match their per-file approved hashes, one runtime never scans the
other's discovery root, shared instructions stay capped, and Codex workers use
complete briefs with `fork_turns="none"` rather than duplicate parent history.
The protected Claude runtime surface is `.claude/settings.json` plus every
recursively discovered `.claude/skills/<name>/SKILL.md`. No other file class
under `.claude` is currently part of this distro's runtime contract; adding one
fails the guard until the discovery rule and baseline are explicitly extended.
The Codex approval waiter adds no always-loaded text: its detailed contract is
progressively loaded only with `change-review` or `supervision`, and it consumes
one bounded collaboration thread only while operator feedback is pending. The
same idle waiter is re-armed for revision rounds instead of leaking threads.

The live Codex proof consumed 23,369 input tokens (5,888 cached) and 131 output
tokens. The live Claude proof consumed 30,282 cache-creation, 56,491 cache-read,
4 uncached input, and 541 output tokens across skill loading and response. These
are one-run environment measurements, not cross-model performance comparisons.

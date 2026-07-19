# Runtime validation evidence

Validated 2026-07-19 in the task worktree. All live prompts were non-mutating:
Claude used plan permissions; Codex used an ephemeral read-only execution. Raw
machine-local evidence was written to a unique mode-0700 child under `/tmp`, not
committed because it contains session identifiers.

## Automated evidence

| command | result |
| --- | --- |
| `bash tests/smoke.sh` | 456 passed, 0 failed; includes thread-name collisions, command bypasses, private evidence/symlink attacks, minimal parity fixture, missing skill, lost mailbox wake, and instruction bloat |
| `node tests/check-runtime-parity.js` | 18 exact skills/triggers, vocabulary separation, executable rigorous fallbacks, notification-producing Lavish wait, 28 mapped capabilities, every evidence path present |
| `node tests/check-pr-runner.js` | compatible-host security finding and missing-capability paths fail closed |
| `node tests/check-gate-drift.js` | all three built-in gate sequences match shipped configs |
| `bash tests/runtime-performance.sh` | context and Claude no-regression guardrails passed |
| `bash tests/runtime-smoke.sh --live` | structured discovery, rule/parser bypasses, both authenticated model probes, and real PreToolUse block passed |

## Installed runtimes

| runtime | version | config/discovery proof | authenticated proof |
| --- | --- | --- | --- |
| Claude Code | 2.1.215 | CLI/auth probe passed; existing `.claude/settings.json` parsed | loaded project `task-lifecycle`; returned `RUNTIME_OK` under plan mode |
| Codex CLI | 0.144.6 | strict config parsed; prompt-input contained exact structured descriptions/locators for all skills; mutations failed; rule/parser bypass probes passed | ephemeral read-only run loaded dispatch/waiter/rigorous contracts and returned `RUNTIME_OK`; an injected equivalent of the project PreToolUse hook blocked absolute-path `git -C ... restore` |

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
`parity_nested_probe` with `fork_turns="none"`. The depth-2 worker returned
`NESTED_OK`. A `followup_task` on the same idle thread returned `FOLLOWUP_OK`.
This directly proves the secondmate → worker nesting edge and same-thread
follow-up surface used by the adapter. No model/effort selector was present in
the actual spawn call, so the adapters make no per-child selection claim.

The approval-wake regression also used the native path. A depth-1 parent spawned
a no-fork dedicated waiter. The waiter deliberately started a command with an
early yield, resumed the same terminal session through exit, and returned
`WAITER_COMPLETION_OK`; that subagent completion arrived in the parent mailbox
without a manual terminal read. The wake therefore came from collaboration
completion, not from the command session.

After the cold-review fixes, the same no-fork waiter proof was rerun and returned
`WAITER_COMPLETION_OK` through the parent mailbox after owning its yielded shell
session through exit.

## Performance evidence

| model-visible or startup surface | before | after | result |
| --- | ---: | ---: | --- |
| shared `AGENTS.md` | 26,634 B (~6,659 tokens) | 26,905 B (~6,727 tokens) | +271 B / +1.02%; under explicit 32,768 B cap |
| Claude settings | 1,579 B | 1,579 B | byte-identical |
| Claude full skill bodies on disk | 80,906 B | 80,906 B | byte-identical; still progressive load |
| Claude discovery descriptions | 4,603 B | 4,603 B | byte-identical |
| Codex adapter/config/rules | none | 84,247 B / 516 B / 1,959 B | full bodies load only when selected; descriptions 4,567 B, under documented 8,000-character fallback budget |

A five-run local `--version` process-start sample reported medians of 71.3 ms
for Claude and 35.8 ms for Codex. This is reproducible CLI process overhead, not
model inference latency, and is reported only as a diagnostic—not used to claim
network/model speed. The guardrail instead enforces the causal performance
properties: Claude files stay byte-identical, one runtime never scans the
other's discovery root, shared instructions stay capped, and Codex workers use
complete briefs with `fork_turns="none"` rather than duplicate parent history.
The Codex approval waiter adds no always-loaded text: its detailed contract is
progressively loaded only with `change-review` or `supervision`, and it consumes
one bounded collaboration thread only while operator feedback is pending. The
same idle waiter is re-armed for revision rounds instead of leaking threads.

The live Codex proof consumed 23,369 input tokens (5,888 cached) and 131 output
tokens. The live Claude proof consumed 30,282 cache-creation, 56,491 cache-read,
4 uncached input, and 541 output tokens across skill loading and response. These
are one-run environment measurements, not cross-model performance comparisons.

# Runtime validation evidence

Validated 2026-07-19 in the task worktree. All live prompts were non-mutating:
Claude used plan permissions; Codex used an ephemeral read-only execution. Raw
machine-local evidence was written under `/tmp/dockmaster-runtime-live-*`, not
committed because it contains session identifiers.

## Automated evidence

| command | result |
| --- | --- |
| `bash tests/smoke.sh` | 439 passed, 0 failed; includes missing-Codex-skill and instruction-bloat negative cases |
| `node tests/check-runtime-parity.js` | 18 exact skills, 18 exact triggers, vocabulary separation, 28 mapped capabilities, every evidence path present |
| `node tests/check-gate-drift.js` | all three built-in gate sequences match shipped configs |
| `bash tests/runtime-performance.sh` | context and Claude no-regression guardrails passed |
| `bash tests/runtime-smoke.sh --live` | installed config/discovery/policy probes and both authenticated model probes passed |

## Installed runtimes

| runtime | version | config/discovery proof | authenticated proof |
| --- | --- | --- | --- |
| Claude Code | 2.1.215 | CLI/auth probe passed; existing `.claude/settings.json` parsed | loaded project `task-lifecycle`; returned `RUNTIME_OK` under plan mode |
| Codex CLI | 0.144.6 | strict-config doctor: 18 checks, no failures/warnings; prompt-input contained dockmaster skills; rule allow/deny probes passed | ephemeral read-only run loaded `task-lifecycle`; returned `RUNTIME_OK` |

The isolated Claude worktree had not accepted Claude's trust dialog, so the CLI
reported that its 45 project permission allow entries were ignored. This did not
prevent `CLAUDE.md`, `AGENTS.md`, or skill discovery—the live proof passed—but a
normal installation must accept each runtime's project trust prompt before its
project-local permission/config layer is relied on.

## Real Codex collaboration proof

From a Codex child thread (depth 1), the root spawned
`parity_nested_probe` with `fork_turns="none"`. The depth-2 worker returned
`NESTED_OK`. A `followup_task` on the same idle thread returned `FOLLOWUP_OK`.
This directly proves the secondmate → worker nesting edge and same-thread
follow-up surface used by the adapter. No model/effort selector was present in
the actual spawn call, so the adapters make no per-child selection claim.

## Performance evidence

| model-visible or startup surface | before | after | result |
| --- | ---: | ---: | --- |
| shared `AGENTS.md` | 26,634 B (~6,659 tokens) | 26,905 B (~6,727 tokens) | +271 B / +1.02%; under explicit 32,768 B cap |
| Claude settings | 1,579 B | 1,579 B | byte-identical |
| Claude full skill bodies on disk | 80,906 B | 80,906 B | byte-identical; still progressive load |
| Claude discovery descriptions | 4,603 B | 4,603 B | byte-identical |
| Codex adapter/config/rules | none | 80,863 B / 295 B / 985 B | full bodies load only when selected; descriptions 4,567 B, under documented 8,000-character fallback budget |

A five-run local `--version` process-start sample reported medians of 72.0 ms
for Claude and 37.4 ms for Codex. This is reproducible CLI process overhead, not
model inference latency, and is reported only as a diagnostic—not used to claim
network/model speed. The guardrail instead enforces the causal performance
properties: Claude files stay byte-identical, one runtime never scans the
other's discovery root, shared instructions stay capped, and Codex workers use
complete briefs with `fork_turns="none"` rather than duplicate parent history.

The live Codex proof consumed 23,340 input tokens (5,888 cached) and 69 output
tokens. The live Claude proof consumed 28,545 cache-creation, 59,590 cache-read,
4 uncached input, and 589 output tokens across skill loading and response. These
are one-run environment measurements, not cross-model performance comparisons.

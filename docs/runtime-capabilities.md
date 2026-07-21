# Runtime capability matrix

`config/runtime-capabilities.json` is the machine-readable source. This table is
the review surface; `tests/check-runtime-parity.js` fails if an id, skill,
trigger, adapter, or evidence path drifts. `direct` means deterministic or live
behavior was executed; `contract` means CI asserts the exact documented
procedure but does not execute the external/runtime outcome; `manual` requires
an authenticated runtime/browser/mailbox observation. Current split: 13 direct,
9 contract, 6 manual.

| id | capability | Claude implementation | Codex implementation | evidence / verification |
| --- | --- | --- | --- | --- |
| `guidance-and-triggers` | shared contract and exact triggers | `CLAUDE.md` → `AGENTS.md` | direct `AGENTS.md` discovery | **contract** + parity assertion |
| `skill-discovery` | all 18 skills, separated vocabularies | `.claude/skills` | official `.agents/skills` | adapter trees + parity test |
| `task-dispatch` | async complete-brief worker | background `Agent` | sanitized thread label + returned `agent_id`, `fork_turns=none` | **contract** + identity helper tests |
| `worktree-isolation` | one guarded copy per task | toolbelt + agent isolation | toolbelt + absolute path in brief | `dm-worktree.sh` + smoke suite |
| `nested-secondmate` | root → supervisor → worker | nested background agents | depth 2, six-thread cap | **manual** live nesting; direct state/config assertions |
| `followup-and-steering` | same-worker correction | `SendMessage`/task controls | message/follow-up/interrupt/list controls | **manual** live identity controls; direct adapter assertion |
| `background-supervision` | no polling daemon | completion notification | mailbox + efficient agent wait | **manual** mailbox wake; deterministic waiter harness in CI |
| `recovery` | same task/work survives restart | reconcile and relaunch ladder | list/message/interrupt then same-copy relaunch | **contract** + state assertions |
| `bounded-ci-wait` | terminal CI rollup | Monitor/schedule + `await-checks` | attached command, dedicated waiter, or schedule + `await-checks` | dm-pr + supervision adapters |
| `scheduled-fleet-sweep` | recurring PR health | runtime schedule/cron | desktop/web scheduled task; CLI prepares it | **manual** desktop/web schedule; direct sweep assertion |
| `change-review` | pre-delivery approval loop | background Lavish poll | no-fork waiter owns poll; mailbox completion wakes parent | **manual** mailbox wake; direct identity/adapter regressions |
| `pr-gates` | fast/default/rigorous gates | fresh reviewers | executable no-fork verify/security fallbacks; fail closed | pr-workflow + configs + runner tests |
| `post-pr-review` | review comments/red CI tail | shared skill | shared skill | **contract** in both skills |
| `github-tooling` | PR API/checks/merge | gh-axi/gh | gh-axi/gh or plugin tools | dm-pr + smoke |
| `browser-tooling` | real browser validation | chrome-devtools-axi | chrome-devtools-axi or Browser Use | **manual** authenticated browser flow; direct readiness assertion |
| `lavish-tooling` | reviewable HTML/plain fallback | lavish-axi | lavish-axi | dm-lavish + smoke |
| `credential-handoff` | reference-only secret handoff | shared contract | shared contract | **contract** in both skills |
| `memory-routing` | six durable ownership scopes | plain stores + optional runtime memory | same stores + optional Codex memory | dm-memory + both adapters + smoke |
| `diagnostics` | evidence before authorization | shared contract | shared contract | **contract** in both skills |
| `merge-conflicts` | safe in-copy resolution | shared contract | shared contract | conflict skills + dm-merge |
| `rollback` | revert through normal gates | shared contract | shared contract | **contract** in both skills |
| `testing-policy` | real tests/visible skips/flakes | shared contract | shared contract | dm-test + both skills + smoke |
| `fleet-campaigns` | one gated child per repo | background fan-out | bounded collaboration fan-out | backlog + fleet skills + smoke |
| `deterministic-workflow` | optional configured runner | Workflow host when available | compatible injected host; full native fallback | runner + gate drift test |
| `merge-safety` | red/authority/unlanded guards | shared toolbelt | shared toolbelt + trusted rules/hook guardrails | dm-pr/dm-merge/rules/hook/smoke |
| `right-sizing` | quality-aware resource use | per-agent model/effort and tiers | tiers, bounded count, focused no-fork prompts | **contract** + bounded runner test |
| `plugins-and-fallbacks` | optional tools degrade or fail loudly, never silently vanish | lavish/browser degrade; GitHub mutations hard-require `gh-axi` and fail loudly | plugins/local tools with focused fallback | **contract** + doctor assertions |
| `project-safety-config` | project policy | Claude settings allowlist | trusted config + tested rules/PreToolUse hook | configs + guard + runtime smoke |

## Clean separation

The two discovery roots intentionally duplicate only skill content stored on
disk. They do not add both contracts to either model's always-loaded prompt.
Ten runtime-neutral skills must stay byte-identical. Eight adapters may
differ because they contain native calls: `change-review`, `fleet-change`,
`memory-routing`, `pr-workflow`, `secondmate`, `stuck-worker`, `supervision`, and
`task-lifecycle`. The parity test forbids Claude tool names in Codex adapters and
Codex collaboration names in Claude adapters.

## Codex platform boundaries

- Project `.codex/config.toml` and project rules load only after the project is
  trusted. The CLI must show no config warning; runtime smoke uses strict config.
- Codex command rules use exact argv prefixes, so project `PreToolUse` also
  parses shell commands for absolute Git paths, global options such as `-C`, and
  destructive flag variants. Both layers are trust-scoped guardrails, not a
  complete security boundary: specialized tools may not emit a Bash hook event,
  and shell interpretation can exceed the parser. Guarded toolbelt paths and the
  operating contract remain primary.
- Nesting defaults to one edge, so dockmaster explicitly sets depth 2 for
  secondmate → worker. Six concurrent open threads bound fan-out; ordinary work
  uses at most three so approval, recovery, and review retain capacity.
- The active collaboration call has no per-spawn model/effort field. Codex
  therefore right-sizes tiers, task shape, prompt scope, and agent count and does
  not claim a selector it did not invoke.
- Scheduled-task management exists in desktop/web, not the CLI. CLI sessions use
  bounded attached waits, a dedicated no-fork waiter when parent notification is
  required, or prepare a scheduled prompt for the supported surface. A raw
  command session never counts as a collaboration wake source.
- The optional deterministic runner needs a host that injects its workflow API.
  Both runtimes retain a complete native `pr-workflow` path when it is absent.

## Official Codex anchors

Adapter decisions were checked against the current official Codex manual:

- [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Skills](https://learn.chatgpt.com/docs/customization/skills)
- [Project config and trust](https://learn.chatgpt.com/docs/config-file/config-advanced#project-config-files-codexconfigtoml)
- [Scheduled tasks](https://learn.chatgpt.com/docs/automations)
- [Rules](https://learn.chatgpt.com/docs/agent-configuration/rules)
- [Plugins](https://learn.chatgpt.com/docs/plugins)

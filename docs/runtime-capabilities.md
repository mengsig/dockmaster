# Runtime capability matrix

`config/runtime-capabilities.json` is the machine-readable source. This table is
the review surface; `tests/check-runtime-parity.js` fails if an id, skill,
trigger, adapter, or evidence path drifts.

| id | capability | Claude implementation | Codex implementation | direct evidence |
| --- | --- | --- | --- | --- |
| `guidance-and-triggers` | shared contract and exact triggers | `CLAUDE.md` → `AGENTS.md` | direct `AGENTS.md` discovery | contract + parity test |
| `skill-discovery` | all 18 skills, separated vocabularies | `.claude/skills` | official `.agents/skills` | adapter trees + parity test |
| `task-dispatch` | async complete-brief worker | background `Agent` | `spawn_agent`, `fork_turns=none` | both task-lifecycle skills + brief generator |
| `worktree-isolation` | one guarded copy per task | toolbelt + agent isolation | toolbelt + absolute path in brief | `dm-worktree.sh` + smoke suite |
| `nested-secondmate` | root → supervisor → worker | nested background agents | depth 2, six-thread cap | secondmate skills + Codex config/runtime smoke |
| `followup-and-steering` | same-worker correction | `SendMessage`/task controls | message/follow-up/interrupt/list controls | supervision + recovery adapters |
| `background-supervision` | no polling daemon | completion notification | mailbox + efficient agent wait | supervision adapters |
| `recovery` | same task/work survives restart | reconcile and relaunch ladder | list/message/interrupt then same-copy relaunch | session-start + stuck-worker + smoke |
| `bounded-ci-wait` | terminal CI rollup | Monitor/schedule + `await-checks` | attached command, dedicated waiter, or schedule + `await-checks` | dm-pr + supervision adapters |
| `scheduled-fleet-sweep` | recurring PR health | runtime schedule/cron | desktop/web scheduled task; CLI prepares it | `dm-pr sweep` + supervision adapters |
| `change-review` | pre-delivery approval loop | background Lavish poll | no-fork waiter owns poll; mailbox completion wakes parent | dm-lavish + adapters + parity regression |
| `pr-gates` | fast/default/rigorous gates | fresh reviewers | fresh no-fork reviewers; focused fallback | pr-workflow + configs + drift test |
| `post-pr-review` | review comments/red CI tail | shared skill | shared skill | both post-pr-review skills |
| `github-tooling` | PR API/checks/merge | gh-axi/gh | gh-axi/gh or plugin tools | dm-pr + smoke |
| `browser-tooling` | real browser validation | chrome-devtools-axi | chrome-devtools-axi or Browser Use | contract + doctor |
| `lavish-tooling` | reviewable HTML/plain fallback | lavish-axi | lavish-axi | dm-lavish + smoke |
| `credential-handoff` | reference-only secret handoff | shared contract | shared contract | both credential skills |
| `memory-routing` | six durable ownership scopes | plain stores + optional runtime memory | same stores + optional Codex memory | dm-memory + both adapters + smoke |
| `diagnostics` | evidence before authorization | shared contract | shared contract | both diagnostic skills |
| `merge-conflicts` | safe in-copy resolution | shared contract | shared contract | conflict skills + dm-merge |
| `rollback` | revert through normal gates | shared contract | shared contract | both rollback skills |
| `testing-policy` | real tests/visible skips/flakes | shared contract | shared contract | dm-test + both skills + smoke |
| `fleet-campaigns` | one gated child per repo | background fan-out | bounded collaboration fan-out | backlog + fleet skills + smoke |
| `deterministic-workflow` | optional configured runner | Workflow host when available | compatible injected host; full native fallback | runner + gate drift test |
| `merge-safety` | red/authority/unlanded guards | shared toolbelt | shared toolbelt + command rules | dm-pr/dm-merge/rules/smoke |
| `right-sizing` | quality-aware resource use | per-agent model/effort and tiers | tiers, bounded count, focused no-fork prompts | task/pr adapters + perf guard |
| `plugins-and-fallbacks` | optional tools never silently vanish | installed tools/skills with plain fallback | plugins/local tools with focused fallback | README + doctor + pr adapter |
| `project-safety-config` | project policy | Claude settings allowlist | trusted config + inline-tested rules | both configs + runtime smoke |

## Clean separation

The two discovery roots intentionally duplicate only skill content stored on
disk. They do not add both contracts to either model's always-loaded prompt.
Eleven runtime-neutral skills must stay byte-identical. Seven adapters may
differ because they contain native calls: `change-review`, `memory-routing`,
`pr-workflow`, `secondmate`, `stuck-worker`, `supervision`, and
`task-lifecycle`. The parity test forbids Claude tool names in Codex adapters and
Codex collaboration names in Claude adapters.

## Codex platform boundaries

- Project `.codex/config.toml` and project rules load only after the project is
  trusted. The CLI must show no config warning; runtime smoke uses strict config.
- Codex command rules are experimental and cover shell commands outside the
  sandbox. They are an extra destructive-command guardrail, not the enforcement
  boundary; guarded toolbelt paths and the operating contract remain primary.
- Nesting defaults to one edge, so dockmaster explicitly sets depth 2 for
  secondmate → worker. Six concurrent open threads bound fan-out.
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

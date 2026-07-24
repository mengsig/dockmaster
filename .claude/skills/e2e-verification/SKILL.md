---
name: e2e-verification
description: Boot the real app from a task's worktree, drive the changed user-facing surface in a real browser, and return a verdict backed by screenshots. Load when a change touches a user-facing surface and must be proven working in the real app, not just green in CI.
---

# e2e-verification

Green tests prove the scripted flows still pass. This proves **the changed
feature actually works** — the app boots, a user can reach it, and it does what
the change claims. Screenshots are the evidence. `bin/dm-verify.sh` is the whole
mechanism; read its header for exact usage.

## Does the gate fire?

`bin/dm-verify.sh gate <id>` decides from the task's own diff:

- **exit 0 `required`** — the diff touches a user-facing surface and the repo has
  app config. Run the gate.
- **exit 1 `not-applicable`** — no user-facing surface moved. Skip, and say so.
- **exit 3 `UNAVAILABLE`** — a surface moved but the repo registers no
  `app_start_cmd`, so nothing can be booted. **Report it as unavailable.** It is
  not a pass, and it is not a skip you may stay quiet about.

A repo opts in with `bin/dm-repo.sh set <repo> app_start_cmd|app_stop_cmd|
app_ready_cmd|app_seed_cmd|app_url|verify_surfaces`. Every command runs in the
task's worktree and **must honor `$DM_VERIFY_PORT`** — the app is booted on a
per-task port so a verification can never be run against the operator's own
running instance.

## The run

```
up  →  session  →  (drive · shot)*  →  flow …  →  report        down in a trap
```

1. `dm-verify.sh up <id>` — boots the app on a free per-task port and waits for
   readiness. **Arm the teardown immediately**: `trap 'bin/dm-verify.sh down
   <id>' EXIT` so a failed verification never leaks a running app or container.
2. `dm-verify.sh session <id>` — gives the task its own browser. The browser is
   reachable **only** through `dm-verify.sh drive` / `shot`. Never call
   `chrome-devtools-axi` yourself: its bridge is a single global process, so a
   raw call lands in another crewmate's browser (issue #80).
3. Drive the flows with `dm-verify.sh drive <id> <args…>` (`open`, `snapshot`,
   `fillform`, `click`, `wait`, …). `snapshot` first — element refs go stale
   after every action, so re-snapshot before each interaction.
4. `dm-verify.sh shot <id> <name>` at each asserted state.
5. `dm-verify.sh flow <id> <name> pass|fail|flake "<what you observed>"` per flow.
6. `dm-verify.sh report <id>` — renders the report and **is** the verdict:
   exit 0 all passed, 1 something did not, 3 nothing was recorded.

## Choosing the flows

Derive them from the diff, not from the repo's test suite: for each changed
surface, what would a user *do* to see it, and what would they *see*? A login
form changed → sign in with real credentials and assert the signed-in state. A
route added → reach it and assert it renders. Cover the change, plus the one
flow most likely broken by it.

## What counts as evidence

An assertion is a concrete observation — text present, url changed, element
visible — read out of `drive … snapshot`, not an impression. Every recorded flow
needs a screenshot of the asserted state and a note saying what you expected and
what you saw. "Looked fine" is not a result.

## Never fabricate

The one unforgivable outcome (same stance as `testing-policy`):

- App will not boot → **FAIL**, with the boot output. Never "assumed working".
- A flow cannot be driven, or the feature is unreachable → **FAIL**, say why.
- No app config → **unavailable**, reported, never silently passed.
- A screenshot that did not get written → the session is unusable; nothing is
  verified. `shot` already refuses this rather than record a phantom file.
- Never record `pass` for a flow you did not actually drive to its asserted state.

**Flakes:** retry a flow at most twice. If it only passes on retry, record it
`flake` with what differed — a flake is not a pass, and `report` will not go
green on one.

## Reporting

`data/<id>/verify/report.md` and `report.html` (screenshots inline) are the
artifacts; the previous run's flows are kept under `runs/`. A failed
verification is operator-facing — surface it with the failing flow and its
screenshot. A clean one is silent.

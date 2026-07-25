---
name: e2e-verification
description: Boot the real app from a task's worktree, drive the changed user-facing surface in a real browser, and return a verdict backed by screenshots. Load when a change touches a user-facing surface and must be proven working in the real app, not just green in CI.
---

# e2e-verification

Green tests prove the scripted flows still pass. This proves **the changed
feature actually works** — the app boots, a user can reach it, and it does what
the change claims. Screenshots are the evidence. `bin/dm-verify.sh` is the whole
mechanism; read its header for exact usage.

The gate enforces its own invariants, so this skill is how to work with them,
not a promise you are asked to keep:

- `flow … pass` is **refused** without a live app, a live browser, an unmoved
  worktree, and a real PNG of that flow. There is no way to record a green flow
  you did not drive.
- `report` re-checks every pass against the file on disk, refuses a truncated
  or malformed record, and refuses once HEAD or the dirty state has moved since
  boot — a green run cannot be carried across a later edit.
- `up` refuses unless `app_ready_cmd` proves the process on the port is the one
  this task started.

## Does the gate fire?

`bin/dm-verify.sh gate <id>` decides from the task's own diff:

- **exit 0 `required`** — a user-facing surface moved and the repo has app
  config. Run the gate.
- **exit 1 `not-applicable`** — only documentation moved. Skip, and say so.
- **exit 2** — it could not read the diff. Not a skip; report it.
- **exit 3 `UNAVAILABLE`** — a surface moved but the repo registers no
  `app_start_cmd`, so nothing can be booted. **Report it as unavailable.** It is
  not a pass, and not a skip you may stay quiet about.

With no `verify_surfaces` registered, everything except documentation counts —
a gate that under-fires is indistinguishable from one that always passes.
`verify_surfaces` **narrows** that for a repo whose runtime surface is smaller.

## Registering a repo

`bin/dm-repo.sh set <repo> app_start_cmd|app_stop_cmd|app_ready_cmd|
app_seed_cmd|app_url|verify_surfaces`. Every command runs in the task's worktree
and **must honor `$DM_VERIFY_PORT`** — the app boots on a per-task port so a
verification is never run against the operator's own running instance.

An `app_start_cmd` that backgrounds a server must **detach** it
(`nohup … >log 2>&1 </dev/null &`); a job left attached to the calling shell does
not reliably outlive it.

`app_ready_cmd` is the **ownership probe** and is mandatory. It must establish
that what answers on `$DM_VERIFY_PORT` is *this task's* instance — the container
of this task's compose project, the process this start command spawned — and
only then `cp "$DM_VERIFY_DIR/token" "$DM_VERIFY_DIR/ready-proof"`. `up` refuses
to come up without that proof. A bare `curl "$DM_VERIFY_URL"` proves the port
answers, not who is answering.

## The run

```
up  →  session  →  (drive · shot)*  →  flow …  →  report        down in a trap
```

1. `dm-verify.sh up <id>` — boots the app on a free per-task port, waits for the
   ownership proof, and pins the code under test. **Arm the teardown
   immediately**: `trap 'bin/dm-verify.sh down <id>' EXIT`. (Worktree removal
   also calls `down`, so a killed crewmate still cannot leak an app — but the
   trap is what stops it now instead of at teardown.)
2. `dm-verify.sh session <id>` — gives the task its own browser. The browser is
   reachable **only** through `dm-verify.sh drive` / `shot`. Never call
   `chrome-devtools-axi` yourself: its bridge is a single global process, so a
   raw call lands in another crewmate's browser (issue #80).
3. Drive the flows with `dm-verify.sh drive <id> <args…>` (`open`, `snapshot`,
   `fillform`, `click`, `wait`, …). `snapshot` first — element refs go stale
   after every action, so re-snapshot before each interaction.
4. `dm-verify.sh shot <id> <flow-name>` at the asserted state. The screenshot
   name must match the flow name; that binding is what `flow` and `report`
   check.
5. `dm-verify.sh flow <id> <name> pass|fail|flake "<what you observed>"`.
6. `dm-verify.sh report <id>` — renders the report and **is** the verdict:
   exit 0 all passed, 1 something did not, 3 nothing was recorded.

Do not edit the worktree between `up` and `report`. The verdict is pinned to the
code that was booted, so an edit invalidates the run — `down`, edit, `up` again.

## Choosing the flows

Derive them from the diff, not from the repo's test suite: for each changed
surface, what would a user *do* to see it, and what would they *see*? A login
form changed → sign in with real credentials and assert the signed-in state. A
route added → reach it and assert it renders. Cover the change, plus the one
flow most likely broken by it.

## What counts as evidence

An assertion is a concrete observation — text present, url changed, element
visible — read out of `drive … snapshot`, not an impression. Say what you
expected and what you saw. "Looked fine" is not a result.

## Never fabricate

The one unforgivable outcome (same stance as `testing-policy`):

- App will not boot → **FAIL**, with the boot output. Never "assumed working".
- A flow cannot be driven, or the feature is unreachable → **FAIL**, say why.
- No app config → **unavailable**, reported, never silently passed.
- Never record `pass` for a flow you did not drive to its asserted state. The
  gate refuses the obvious forms; do not go looking for the rest.

**Flakes:** retry a flow at most twice. If it only passes on retry, record it
`flake` with what differed — a flake is not a pass, and `report` will not go
green on one.

## Reporting and retention

`data/<id>/verify/report.md` and `report.html` (screenshots inline) are the
artifacts, stamped with the sha they verified; previous runs' flows are kept
under `runs/`. **The screenshots show the app signed in** — treat them as
task-sensitive and do not attach them outside the operator's review surface. The
browser profile (cookies, local storage, saved logins) is purged by `down`.

A failed verification is operator-facing — surface it with the failing flow and
its screenshot. A clean one is silent.

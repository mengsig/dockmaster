---
name: dockmaster
description: Open the dockmaster console — one local page carrying the conversation with the operator plus what needs them, what is in flight and how far along, every open PR, repos, backlog, decisions and the review archive. Load when the operator types /dockmaster, asks to open the console or the dashboard, or when you want to reach them through the page instead of the terminal.
---

# dockmaster (the console)

One local page at `http://127.0.0.1:4877/` that replaces the terminal plus a
scatter of review URLs. It reads the fleet ONLY by running the `dm-*` scripts,
so it can never disagree with the toolbelt, and it carries the conversation.

## Open it

    bin/dm-ui.sh open            # start (idempotent) and open a browser
    bin/dm-ui.sh start           # start only; prints the URL
    bin/dm-ui.sh status | stop

Defaults to `--source live`, the real fleet. `--source fixture` serves the
committed demo fleet — for design work on the page, never to show the operator
"their" fleet. Starting on a different source than the running server replaces
it and says so. Port via `DM_UI_PORT`.

## Talk through it

The page cannot BE this session, so it uses the same shape as `lavish-axi poll`:

    bin/dm-ui.sh poll [--timeout <seconds>]   # BLOCKS at zero idle cost until the
                                              # operator sends something, prints it,
                                              # exits 0. Exit 3 = timed out, nothing
                                              # queued.
    bin/dm-ui.sh say "<reply>"                # posts your reply; the open page shows
    bin/dm-ui.sh say --file <path>            # it without a refresh

Claiming a message is a **rename**, so a killed or timed-out poll loses nothing —
re-run it and anything queued is still there. Answer with `say` before polling
again; the page shows the operator how many messages are still unpicked-up.

Poll it the way you already wait on work: run it in the background and let the
completion wake you (see `supervision`). Do not busy-loop it.

## What it will not do

Nothing on the page is destructive — no merge, no cleanup, no teardown control.
It reports, and it talks. Every action stays in this session under the usual
gates, so the merge authority in `AGENTS.md` §3 is untouched by anything the
operator clicks. A decision answered from the page arrives as an ordinary
message; record the resolution with `decision-hold` exactly as before.

## When a panel says it could not read something

The page names the source it lost rather than rendering an empty panel, and
`--source live` fails loudly instead of falling back to fixtures. Treat a named
degradation as a real toolbelt failure and investigate the script it names — a
plausible-looking wrong fleet is the one outcome this must never produce.

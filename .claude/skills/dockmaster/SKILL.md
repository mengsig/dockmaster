---
name: dockmaster
description: Open the dockmaster console — one local page carrying the conversation with the operator plus what needs them, what is in flight and how far along, every open PR, repos, backlog, decisions and the review archive. Load when the operator types /dockmaster, asks to open the console or the dashboard, or when you want to reach them through the page instead of the terminal.
---

# dockmaster (the console)

One local page at `http://127.0.0.1:4877/` that replaces the terminal plus a
scatter of review URLs. It reads the fleet ONLY by running the `dm-*` scripts,
so it can never disagree with the toolbelt, and it carries the conversation.

## Open it

    bin/dm-ui.sh open            # start (idempotent), open a browser
    bin/dm-ui.sh start           # start only; prints the URL
    bin/dm-ui.sh status | stop

Opening the console is **two actions, not one followed by remembering a second**:
`start`/`open` always print whether the watcher (below) is armed, and the exact
command to arm it when it is not — read that line off the output you already
have, and arm it before doing anything else. `status` reports the same line at
any later check-in. `stop` disarms the watcher along with the server, so the two
share one lifecycle: stopping the console is the only thing that disarms it.

Defaults to `--source live`, the real fleet. `--source fixture` serves the
committed demo fleet — for design work on the page, never to show the operator
"their" fleet. Starting on a different source than the running server replaces
it and says so. Port via `DM_UI_PORT`.

## Talk through it

The page cannot BE this session. A single `poll` stops watching TWO ways, not
one — it drains everything queued and exits 0, or it times out with nothing
queued and exits 3 — and left unarmed after either, both reproduce the exact
defect this closed: messages sat unclaimed because nothing re-armed after a
drain, or nothing re-armed after a quiet stretch. Arm `watch` instead: it
keeps calling `poll` in bounded slices for as long as it runs, treating a
drain and an idle timeout the same way — keep going — so delivery survives
both a drain and a quiet hour.

    bin/dm-ui.sh watch                        # blocks in DM_UI_WATCH_TIMEOUT-second
                                              # slices (default 300), printing
                                              # everything queued per drain -
                                              # oldest first, each numbered
                                              # `[n/total]` and stamped -
                                              # forever, until stopped. Refuses
                                              # to double-arm; exits loudly
                                              # (never silently) if the inbox
                                              # breaks.
    bin/dm-ui.sh say "<reply>"                # posts your reply; the open page shows
    bin/dm-ui.sh say --file <path>            # it without a refresh

One drain is bounded at 50 messages — past that it says how many are still
queued, and the next slice picks them up, no separate action needed.

Arm it with a **persistent Monitor**, immediately after `start`/`open` (or the
moment `status` reports it not armed) — this is the one step nothing can do FOR
you, since only this session can register a wake, so treat it as part of opening
the console rather than a separate thing to recall later:

    Monitor({ command: "bin/dm-ui.sh watch", description: "console: operator messages", persistent: true })

Each drain `watch` prints — one message or several — is its own wake, the same
completion-wakes-the-supervisor model as any other background work (see
`supervision`). Do **not** back it with a bare `&` shell background job instead
of Monitor: it claims messages exactly as well, but produces no wake at all, so
a message would be claimed and then sit invisibly in the log — silence that
reads as covered when it is not.

Claiming a message is a **rename**, and it is only marked delivered once the
text is written out — so a watcher killed at any point, mid-drain included,
loses nothing: re-arming it delivers anything still queued. The one thing to
expect is the mirror image, rarely: a message delivered twice, if the process
died between printing and recording it.

## Ask through the page, never the terminal

While the console is running, a question for the operator goes to the PAGE. Your
runtime's terminal prompt reaches a window they are not looking at.

    bin/dm-ui.sh ask <key> "<question>" [--options "A | B"] [--origin <path>]

It opens a `decision-hold` under that key — so the question is durable and the
Needs-you panel holds it open across a restart of either side — and posts it
into the conversation. The key must be FRESH: it refuses rather than write over a
decision already on the board. If the question belongs to a specific task, pass
`--origin data/<id>/report.md` — that is the backlink `dm-trash.sh` resolves a
trashed task's open holds through; without it, trashing that task leaves the
question open forever. One line, and `|` separates options. An option is
answered in ONE click; the answer arrives on `poll` as an ordinary operator
message quoting the question. The page shows the row answered until you resolve
the hold with `decision-hold`, as always.

A one-line `say` renders as a log row rather than a message, and the Updates panel
is every line you have posted, newest first. That surface is for terse, timestamped
status — write it that way.

## What it will not do

No control on the page carries anything out. The cleanup, trash, and
awaiting-review controls all **enqueue a request**: it arrives as an ordinary
operator message on the same queue as the composer, opening `Cleanup request:`,
`Trash request:`, `Approval:`, or `Revision request:`, and you run it here under
the usual gates. So the merge authority in `AGENTS.md` §3 is untouched by
anything the operator clicks — and a confirmed trash request IS the operator's
explicit discard authority for directive 4, for the item it names: the confirm
strip quotes the exact request text before it is sent, which is the
informed-consent step the directive asks for. That authority covers only what the
request names — anything a discard would touch beyond it still stops and escalates.
`Approval:` is explicitly NOT the merge word directive 3 requires — it feeds
`change-review`'s lavish approval gate, and merge authority is decided separately,
same as always. `Revision request:` routes back into `change-review` as the
operator's own feedback, relayed to the crewmate.

A request names work by **title and repo**, never a task id — the document behind
the page deliberately carries none. Resolve it yourself, and ask if two pieces of
work would answer to the same description.

Filters and folded groups are page-side only, stored in the operator's browser.
They hide nothing from you and nothing from the fleet, so "I tidied that away" on
the page is not a request to clean anything up.

A decision answered from the page arrives as an ordinary message opening
`Answer — <the question>`; record the resolution with `decision-hold` as before.

It is not read-only, though. Refreshing runs `dm-pr.sh sweep`, which RECORDS
each PR's state and checks on the work it sweeps and takes the task lock to do
it — the same write the fleet snapshot has always made. So an open tab is a
periodic writer: it refreshes every 30s while visible, skips entirely while the
tab is hidden, and the sweep itself is behind a much longer cache. Expect
`pr_state`/`checks` to move without you asking, and do not leave a console
running against a home you are debugging locks in.

## When a panel says it could not read something

The page names, on the panel that lost it, what could not be read — never an
empty panel, and never "all clear" over a source it never reached. `--source
live` fails loudly instead of falling back to fixtures, and a demo fleet says so
in a banner and in the tab title. Treat a named degradation as a real toolbelt
failure and investigate: the console's own log has the script, argv and stderr
behind it (the page deliberately shows none of that). A plausible-looking wrong
fleet is the one outcome this must never produce.

The repo panel shows what `dm-memory.sh recall --crew` returns — the shared and
private stores, the same view a crewmate gets. The dockmaster-only store is
excluded by design; it never leaves this session.

# The verify gate (`bin/dm-verify.sh`)

Read before editing the verify gate or anything that drives a browser.

- **[invariant]** The app is booted on a PER-TASK port and the port must be
  SILENT before start. Never attach to whatever is listening: the operator runs
  their own instance of the same app, and "verifying" theirs is a fabricated
  pass. `app_start_cmd` therefore has to honor `$DM_VERIFY_PORT`.
- **[invariant]** Silence-then-start is a TOCTOU whose window is the whole
  readiness timeout — a start command that binds nothing, plus anything that
  binds the port seconds later, and the gate verified a foreign process. So
  `app_ready_cmd` is MANDATORY and is an OWNERSHIP probe: it must establish the
  listener is this task's instance, then copy `$DM_VERIFY_DIR/token` (fresh per
  boot) to `ready-proof`. `up` refuses without that proof, so a repo that has not
  done the work fails closed instead of passing.
- **[invariant]** `down` must never record success over a live app. It resolves
  its cwd to the worktree OR the clone (the stop command has to work after
  teardown removed the worktree), and after stopping it re-probes the port: still
  listening means `verify_app_state=leaked` and a loud failure, never `down`.
  `dm-worktree.sh remove` calls it, so a SIGKILLed crewmate cannot leak an app.
- **[invariant]** Under-firing is the one failure mode this gate cannot afford —
  a gate that never fires is indistinguishable from one that always passes. With
  no `verify_surfaces` registered, EVERYTHING except documentation counts;
  `verify_surfaces` only NARROWS. A hand-written surface list missed
  `src/pages/Home.tsx`, `app/views/home.erb` and `app.py` and skipped the very
  change that broke the app.
- **[convention]** `verify` ships in the RIGOROUS tier only. In `default` it
  fails the pipeline before `pr` for every repo with no app config, and the only
  escape is a blanket `noRuntimeSurface` override whose routine use turns the
  gate into a no-op. Add it to `default` once the fleet is configured.
- **[invariant]** A `pass` is EVIDENCE, not an assertion, and the gate enforces
  it rather than asking a crewmate to: `flow … pass` refuses without a live app,
  a live browser, an unmoved worktree, and a real PNG named after the flow;
  `report` re-checks every pass row against the file on disk. Prose in a skill
  cannot hold this — the first version's own smoke section forged a green run.
- **[pitfall]** The pin has now been wrong in BOTH directions, so hash both
  derivatives and never swap one for the other. Porcelain status was blind to
  content (an edit to an already-dirty file did not move it); content alone was
  blind to structure (renaming an untracked file, or merging two into one with
  the same bytes, did not move it either — and that is a route change). The
  material is `git diff HEAD` + the untracked PATH list + the untracked CONTENTS.
- **[invariant]** A verdict is bound to CODE. `up` pins `verify_head` =
  `<sha>/<cksum of the diff plus a per-file digest of every untracked path>` — HEAD alone is not enough because crew work is
  uncommitted for most of its life — and `flow`/`report` refuse once it moves,
  so a green run cannot be carried across the edit that breaks the app.
- **[pitfall]** One file, three parsers, three answers. `wc -l` counted 0 rows in
  a `flows.tsv` whose last line lacked a newline while `awk` counted 1, so a
  truncated record read as `PASS: 0/0`, exit 0. Tally in ONE awk pass, and refuse
  a file that does not end in a newline.
- **[pitfall]** `dm_unlock` runs `trap - EXIT INT TERM`, so ANY locked write
  (`dm_meta_set`, `dm_status_append`) silently disarms a cleanup trap set before
  it. `up` records its meta FIRST and arms the teardown trap after, or a failed
  boot leaks the app.
- **[pitfall]** `chrome-devtools-axi screenshot <path>` prints a success line
  naming a file it may never have written: chrome-devtools-mcp restricts writes
  to its negotiated roots (the temp dir by default) and the axi CLI echoes the
  requested path regardless. `shot` therefore captures into the temp dir, checks
  the file is non-empty, and only then moves it into `data/<id>/verify/shots/`.
- **[invariant]** Browser isolation (#80) does NOT come from
  `CHROME_DEVTOOLS_AXI_PORT` alone. `ensureBridge()` reads ONE pid file at
  `$HOME/.chrome-devtools-axi/bridge.pid` and reuses whatever bridge it names,
  ignoring the requested port whenever a bridge is already alive. Isolation is
  a per-task `HOME` (own state dir → own pid file → own bridge) plus a per-task
  Chrome process, profile, and devtools port. `npm_config_cache` is pinned back
  to the real home so the remapped HOME does not re-bootstrap the MCP server per
  task. It is VERIFIED, not assumed: `start` must report the allocated port, and
  a mismatch falls back to an exclusive lease on the one shared browser.
- **[pitfall]** An `app_start_cmd` that backgrounds a server must DETACH it
  (`nohup … >log 2>&1 </dev/null &`). A job still attached to the calling shell's
  terminal and descriptors does not reliably outlive it — macOS kills it the
  moment `up` returns, Linux does not, so this shows up only on the 3.2 CI leg.
- **[pitfall]** `verify_surfaces` globs are normalized (`**` -> `*`) with `sed`,
  not `${v//\*\*/\*}`: bash 3.2 yields an ESCAPED star there, which matches a
  literal `*` and therefore no path at all — the gate would silently under-fire
  on macOS while passing every Linux test. Only CI's macOS smoke leg catches it.
- **[scope]** The pin covers what `changed_files` covers: tracked changes plus
  untracked-but-not-ignored files. A gitignored file (build output, a local
  `.env`) can change under a green run without moving it. That is deliberate and
  consistent with the gate's firing rule, not an oversight — but it means the pin
  answers "did the SOURCE move", not "did anything on disk move".
- **[invariant]** Re-checks read what was PINNED AT BOOT — the probe, the url,
  the port, the token, the code state — never the live registry. Two crewmates share one `state/repos.json`, so clearing
  `app_ready_cmd` mid-run turned the liveness re-probe into `return 0` and a
  foreign process on the port passed as the app. `up` records
  `verify_ready_cmd`; `require_app_serving` uses that copy.
- **[invariant]** `dm-verify.sh drive|shot` is the only sanctioned way to reach
  a browser. `session` deliberately prints a HANDLE, not an export block — an
  eval-able block would let a raw `chrome-devtools-axi` call land on the shared
  bridge, which is the collision the gate exists to prevent.
- **[convention]** The shared-browser lease (`state/browser.lease`) is a
  cross-process lease, not `dm_lock` — `dm_lock` releases on process exit, so it
  cannot outlive `session`. `dm_lock` still brackets the take-and-stamp, which
  is why an empty `owner` observed under the lock proves a crashed holder.

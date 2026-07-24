# The verify gate (`bin/dm-verify.sh`)

Read before editing the verify gate or anything that drives a browser.

- **[invariant]** The app is booted on a PER-TASK port and the port must be
  SILENT before start. Never attach to whatever is listening: the operator runs
  their own instance of the same app, and "verifying" theirs is a fabricated
  pass. `app_start_cmd` therefore has to honor `$DM_VERIFY_PORT`; a repo whose
  start command ignores it cannot be verified safely.
- **[invariant]** The verdict is mechanical. `report` reads only the flows
  recorded by `flow`, and exits 3 when there are none — an unverified change can
  never read as a pass. Nothing else may write `verify=pass` to task meta.
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
- **[pitfall]** `verify_surfaces` globs are normalized (`**` -> `*`) with `sed`,
  not `${v//\*\*/\*}`: bash 3.2 yields an ESCAPED star there, which matches a
  literal `*` and therefore no path at all — the gate would silently under-fire
  on macOS while passing every Linux test. Only CI's macOS smoke leg catches it.
- **[invariant]** `dm-verify.sh drive|shot` is the only sanctioned way to reach
  a browser. `session` deliberately prints a HANDLE, not an export block — an
  eval-able block would let a raw `chrome-devtools-axi` call land on the shared
  bridge, which is the collision the gate exists to prevent.
- **[convention]** The shared-browser lease (`state/browser.lease`) is a
  cross-process lease, not `dm_lock` — `dm_lock` releases on process exit, so it
  cannot outlive `session`. `dm_lock` still brackets the take-and-stamp, which
  is why an empty `owner` observed under the lock proves a crashed holder.

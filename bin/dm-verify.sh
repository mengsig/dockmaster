#!/usr/bin/env bash
# dm-verify.sh - the verify gate: boot a task's app and drive it in a real browser.
#
# Records the evidence (screenshots, per-flow results) the gate's verdict reads.
# This is the concrete implementation of the pr-workflow "verify" gate (see the
# e2e-verification skill). It brings the app up FROM THE TASK'S WORKTREE on a
# per-task port, hands out an isolated browser, captures screenshots, and turns
# the recorded per-flow results into a verdict. A repo opts in by registering
# app-lifecycle commands (dm-repo.sh set <repo> app_start_cmd ...).
#
# Commands:
#   gate <id> [--json]     should the verify gate run for this task's diff?
#                          exit 0 = required, 1 = no user-facing surface,
#                          2 = could not determine (never reported as a skip),
#                          3 = surface touched but the repo has no app config
#                          (UNAVAILABLE — report it, never a silent pass).
#                          --json ALWAYS exits 0 and carries the same answer as
#                          `decision`: required|not-applicable|undetermined|
#                          unavailable. Machine callers read that, not $?.
#   evidence <id>          print this gate's evidence block for the PR body
#                          (dm-evidence.sh collects it); read-only, and it
#                          reports the SAME decision `gate` exits on. Nothing
#                          when no surface moved — a docs-only PR stays clean.
#   up <id>                start the app on a free per-task port, wait for it to
#                          prove itself ready, and pin the verdict to this HEAD
#   down <id>              stop the app and the browser; fails loudly if the app
#                          is still listening afterwards
#   session <id>           give the task its own browser and print its handle
#   drive <id> <args...>   run chrome-devtools-axi against the task's browser —
#                          the ONLY sanctioned way to drive one (issue #80)
#   shot <id> <name>       screenshot into data/<id>/verify/shots/<name>.png
#   flow <id> <name> <pass|fail|flake> [<note>]
#                          record one driven user flow's outcome. `pass` is
#                          REFUSED unless the app is still serving, the browser
#                          is live, the code has not moved, and THIS run's `shot`
#                          captured the screenshot named after the flow.
#   report <id>            render data/<id>/verify/report.{md,html} and exit
#                          0 = every flow passed, 1 = some flow did not,
#                          2 = not a verdict at all (the code moved under it,
#                          or the app stopped serving), 3 = nothing was
#                          recorded (never a pass)
#
# What the gate enforces itself rather than asking an agent to honor:
#   - A `pass` needs EVIDENCE THIS RUN PRODUCED. `shot` records name + content
#     digest + boot token; `flow` and `report` require a matching entry for the
#     CURRENT boot, so a copied image, one image reused across flows, a symlink,
#     or a whole archived run copied back over `shots/` is refused.
#   - A verdict is bound to CODE BY CONTENT AND STRUCTURE. `up` pins HEAD plus a
#     checksum of `git diff HEAD` and a per-file digest of every untracked path,
#     so content, names and layout all move it; `flow` and `report` refuse once
#     it does. Porcelain status alone was blind to content; content alone was
#     blind to renames and to moving bytes between two untracked files.
#   - The app is SERVING NOW, not stamped up. `flow … pass` and `report` re-probe
#     the port and re-run the ownership probe; a killed app fails them both.
#   - The app is the one WE started. The port must be silent before start, and
#     `app_ready_cmd` must copy the per-boot (unguessable) token to
#     $DM_VERIFY_DIR/ready-proof. `up` first runs that probe with NOTHING
#     started: a probe that passes then proves nothing and is refused.
#
# The limit, stated plainly: every check above defends against accident, stale
# state and a dead app. None of it survives a determined same-user forgery — the
# operator's own shell can write flows.tsv and the manifest directly. No
# same-privilege scheme can close that, and this gate does not pretend to.
#
# Port probing uses bash's /dev/tcp redirection (present in every stock bash on
# Linux and macOS); no netcat/ss/lsof dependency.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need git
dm_ensure_dirs
# Every command resolves per-repo app config from the registry; a corrupt one
# must refuse rather than read as "no app configured" and skip the gate.
dm_registry_require_valid

# App ports live well above the 8080/8000 an operator's own stack usually takes;
# browser bridge ports above chrome-devtools-axi's 9224 default for the same
# reason. Both are scanned forward from a per-task offset, so two tasks that
# hash close together still get distinct ports.
APP_PORT_BASE=8600
APP_PORT_SPAN=400
BRIDGE_PORT_BASE=9300
BRIDGE_PORT_SPAN=200
CDP_PORT_BASE=9600
CDP_PORT_SPAN=200
READY_TIMEOUT="${DM_VERIFY_READY_TIMEOUT:-300}"
READY_INTERVAL=3
READY_FIRST_WAIT=0.2
STOP_SETTLE_SECS="${DM_VERIFY_STOP_SETTLE:-20}"
LEASE_TIMEOUT="${DM_VERIFY_LEASE_TIMEOUT:-600}"
LEASE_DIR="$DM_STATE/browser.lease"
# A screenshot smaller than this, or without PNG magic, is not evidence.
MIN_SHOT_BYTES=512
# One content-digest tool, resolved once: sha256sum (Linux), shasum (macOS), and
# cksum as the last resort. All three print "<digest...> <path>" for file
# arguments, which is what binds a path to its own bytes.
if command -v sha256sum >/dev/null 2>&1; then DIGEST_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then DIGEST_CMD=(shasum -a 256)
else DIGEST_CMD=(cksum); fi
# Paths that cannot change what a user sees. With no `verify_surfaces` set, a
# repo that HAS app config verifies any change outside this set — under-firing
# is the one failure mode a verification gate cannot afford, so the default is
# broad and `verify_surfaces` NARROWS it.
# `*.txt` is deliberately NOT here: requirements.txt and CMakeLists.txt are
# build inputs, and a pin bump is exactly an app-breaking change.
DOC_ONLY_PATHS='*.md,*.rst,docs/**,doc/**,LICENSE*,NOTICE*,CHANGELOG*,AGENTS.md,.github/**,.gitignore,.dm-knowledge/**'

verify_dir() { printf '%s/%s/verify\n' "$DM_DATA" "$1"; }
flows_file() { printf '%s/flows.tsv\n' "$(verify_dir "$1")"; }
shot_path() { printf '%s/shots/%s.png\n' "$(verify_dir "$1")" "$2"; }

# app_field <repo> <field> -> the registered value, or empty. Single owner of the
# registry read so every subcommand resolves app config identically.
app_field() { dm_registry_get "$1" "$2"; }

# port_busy <port> -- exit 0 when something is already listening on 127.0.0.1.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

# derive_port <id> <base> <span> -- a stable per-task starting port, so repeated
# runs of one task reuse a port instead of walking the range.
derive_port() {
  local sum
  sum="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  case "$sum" in ''|*[!0-9]*) dm_die "cksum produced no usable checksum for '$1'" ;; esac
  printf '%s\n' "$(( $2 + sum % $3 ))"
}

# allocate_port <id> <base> <span> -- first free port at or after the derived
# offset, wrapping inside the range. Dies rather than returning a busy port: a
# busy port means attaching to somebody else's process.
allocate_port() {
  local port tried=0
  port="$(derive_port "$1" "$2" "$3")"
  while [ "$tried" -lt "$3" ]; do
    port_busy "$port" || { printf '%s\n' "$port"; return 0; }
    tried=$((tried + 1))
    port=$(( $2 + (port - $2 + 1) % $3 ))
  done
  dm_die "no free port in $2..$(( $2 + $3 - 1 )) for task '$1'; stop something before verifying"
}

# --- what code is under test -------------------------------------------------
# A verdict that is not bound to a revision is not a verdict: a green run could
# be carried across the very edit that breaks the app. HEAD alone is not enough
# either — crew work is uncommitted for most of its life — so the fingerprint
# also covers the dirty state.

# code_state <worktree> -- "<head>/<content-checksum>", or empty when the
# worktree cannot be read.
#
# The checksum must cover file CONTENT, not the porcelain listing. `git status
# --porcelain` emits status letters and paths and never CONTENT, so once a file
# was dirty every further edit produced the identical line and checksum — and
# crew work is dirty for most of its life, the exact case this pin exists for.
#
# Hash BOTH derivatives, never one instead of the other. Hashing content alone
# was blind in the mirror direction: an untracked file RENAMED, or two untracked
# files merged into one with the same bytes, left the checksum identical while
# the app's routes moved. So the material is:
#   - `git diff HEAD`  — tracked content AND tracked paths (renames included)
#   - the untracked PATH list — structure
#   - the untracked file CONTENTS — bytes
# `git diff HEAD` also carries binary changes, via its `index <blob>..<blob>` line.
# untracked_digests <worktree> -- "<digest>  <path>" per untracked file, sorted.
# Each path is bound to ITS OWN content. Concatenating all the bytes into one
# stream did not: moving a line from one untracked file to another left the path
# list and the byte total identical, so the pin sat still while the routes moved.
# Same root as `aa.js` containing the text `zz.js` hashing like an empty pair.
untracked_digests() {
  local wt="$1" paths
  # Emptiness is checked FIRST: GNU xargs runs its command once on empty input,
  # and a digest tool with no arguments reads stdin and hangs.
  paths="$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)" || return 1
  [ -n "$paths" ] || return 0
  # `--` is load-bearing: paths arrive as bare arguments, so an untracked file
  # named `--help` or `-c` is read as an OPTION. sha256sum then prints usage,
  # hashes NOTHING and exits 0 — the untracked digest set collapses to a
  # constant and the pin stops moving on new uncommitted source entirely.
  # No `|| true` either: a digest tool that fails must fail the pin, not empty it.
  git -C "$wt" ls-files --others --exclude-standard -z 2>/dev/null \
    | ( cd "$wt" && xargs -0 -n 50 "${DIGEST_CMD[@]}" -- ) \
    | LC_ALL=C sort
}

code_state() {
  local wt="$1" head content udigests
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  # Prove both reads work BEFORE hashing: a `return` inside the group below runs
  # in a subshell, so a failed git would otherwise hash to a stable checksum of
  # nothing — a pin that never moves, which is the failure this guards.
  git -C "$wt" diff HEAD >/dev/null 2>&1 || return 1
  git -C "$wt" ls-files --others --exclude-standard >/dev/null 2>&1 || return 1
  udigests="$(untracked_digests "$wt")" || return 1
  # cksum's byte count is kept, not discarded: this is the security-critical pin
  # and CRC-32 is linear, so length is a cheap independent term.
  content="$( { git -C "$wt" diff HEAD 2>/dev/null
                printf '%s\n' "$udigests"
              } | cksum | awk '{print $1"-"$2}' )"
  [ -n "$content" ] || return 1
  printf '%s/%s\n' "$head" "$content"
}

# require_app_serving <id> <what> -- refuse unless the app is serving RIGHT NOW.
# `verify_app_state` is a stamp `up` wrote and nothing re-checks, so a crashed or
# killed app left it reading `up` forever and a green verdict followed. Probe the
# port, and re-run the repo's ownership probe so the answer is still OUR app.
require_app_serving() {
  local id="$1" what="$2" port repo cwd url ready token
  [ "$(dm_meta_get "$id" verify_app_state)" = "up" ] \
    || dm_die "refusing $what: the app for '$id' is not up, so no flow was driven"
  port="$(dm_meta_get "$id" verify_port)"
  [ -n "$port" ] || dm_die "refusing $what: no app port recorded for '$id'"
  # Exit 2, like a moved code pin: a run whose app died is not a failing verdict,
  # it is no verdict — and 1 would be indistinguishable from "a flow failed".
  if ! port_busy "$port"; then
    printf 'error: refusing %s: nothing is listening on port %s any more — the app for %s died during this run, so what it recorded cannot be trusted. Re-run: dm-verify.sh down %s && dm-verify.sh up %s\n' \
      "$what" "$port" "'$id'" "$id" "$id" >&2
    exit 2
  fi
  # The probe PINNED AT BOOT, not the current registry value. Two crewmates share
  # one registry, so clearing app_ready_cmd mid-run used to turn this check into
  # `return 0` — and a foreign process on the port then passed as the app.
  repo="$(dm_meta_get "$id" repo)"; ready="$(dm_meta_get "$id" verify_ready_cmd)"
  [ -n "$ready" ] \
    || dm_die "refusing $what: no ownership probe was recorded when '$id' booted, so nothing can confirm what is on port $port is this run's app. Re-run: dm-verify.sh down $id && dm-verify.sh up $id"
  cwd="$(app_cwd "$id")" || dm_die "refusing $what: cannot resolve a directory to re-probe the app for '$id'"
  # Pinned at boot, like the probe itself. Read live, a concurrent crewmate
  # editing shared `app_url` would repoint $DM_VERIFY_URL at a different running
  # instance, and a probe whose ownership test is local would pass against it.
  url="$(dm_meta_get "$id" verify_url)"
  [ -n "$url" ] \
    || dm_die "refusing $what: no app url was recorded when '$id' booted. Re-run: dm-verify.sh down $id && dm-verify.sh up $id"
  token="$(dm_meta_get "$id" verify_token)"
  rm -f "$(verify_dir "$id")/ready-proof"
  run_app_cmd "$cwd" "$port" "$url" "$id" "$ready" >/dev/null 2>&1 || true
  if [ "$(cat "$(verify_dir "$id")/ready-proof" 2>/dev/null || true)" != "$token" ]; then
    printf 'error: refusing %s: the app for %s no longer proves it is the instance this run booted on port %s\n' \
      "$what" "'$id'" "$port" >&2
    exit 2
  fi
}

# require_unmoved_code <id> -- refuse once the worktree differs from what `up`
# pinned. Callers: flow and report, the two places a verdict is created.
require_unmoved_code() {
  local id="$1" pinned now wt what
  pinned="$(dm_meta_get "$id" verify_head)"
  [ -n "$pinned" ] || dm_die "no verified code state recorded for '$id'; the app was never brought up (dm-verify.sh up $id)"
  wt="$(dm_meta_get "$id" worktree)"
  now="$(code_state "$wt")" || dm_die "cannot read the worktree for '$id' to confirm the code has not moved"
  [ "$now" = "$pinned" ] && return 0
  if [ "${now%%/*}" = "${pinned%%/*}" ]; then
    what="its working tree was edited (HEAD is still ${pinned%%/*})"
  else
    what="HEAD moved from ${pinned%%/*} to ${now%%/*}"
  fi
  # Exit 2, not 1: this run is not a failing verdict, it is not a verdict at all.
  printf 'error: the worktree changed since the app was booted — %s. This run verified different code, so its result cannot stand. Re-run: dm-verify.sh down %s && dm-verify.sh up %s\n' \
    "$what" "$id" "$id" >&2
  exit 2
}

# --- app lifecycle -----------------------------------------------------------

# app_url_for <repo> <port> -- the base URL with the port token substituted. Done
# by string replacement, never eval: the value is registry data, not code.
app_url_for() {
  local url; url="$(app_field "$1" app_url)"
  [ -n "$url" ] || dm_die "repo '$1' has app_start_cmd but no app_url; set one (dm-repo.sh set $1 app_url 'http://localhost:\$DM_VERIFY_PORT')"
  url="${url//\$\{DM_VERIFY_PORT\}/$2}"
  printf '%s\n' "${url//\$DM_VERIFY_PORT/$2}"
}

# run_app_cmd <cwd> <port> <url> <task> <cmd> -- run a registered lifecycle
# command with the verification environment exported.
run_app_cmd() {
  local cwd="$1" port="$2" url="$3" id="$4" cmd="$5"
  # EXPORT, not an assignment prefix: a prefix on `eval` (a special builtin) sets
  # the variable in the shell without reliably marking it exported across bash
  # versions, so a start command that spawns a program would hand it nothing.
  ( cd "$cwd" || exit 1
    export DM_VERIFY_PORT="$port" DM_VERIFY_URL="$url" DM_VERIFY_TASK="$id"
    DM_VERIFY_DIR="$(verify_dir "$id")"; export DM_VERIFY_DIR
    eval "$cmd" )
}

# app_cwd <id> -- where a lifecycle command runs. The worktree while it exists,
# else the clone: a stop command must still work after teardown removed the
# worktree, or a running app becomes unstoppable through the toolbelt.
app_cwd() {
  local id="$1" wt dir
  wt="$(dm_meta_get "$id" verify_cwd)"
  [ -n "$wt" ] || wt="$(dm_meta_get "$id" worktree)"
  if [ -n "$wt" ] && [ -d "$wt" ]; then printf '%s\n' "$wt"; return 0; fi
  dir="$(dm_repo_dir "$(dm_meta_get "$id" repo)")" || return 1
  printf '%s\n' "$dir"
}

# wait_ready <cwd> <port> <url> <id> <ready_cmd> -- poll until the app proves
# itself ready, or the bounded deadline passes. Readiness needs BOTH a listener
# on our port and the per-boot token echoed into ready-proof by the repo's own
# probe; a probe that only fetches the url proves liveness, not ownership.
wait_ready() {
  local cwd="$1" port="$2" url="$3" id="$4" ready_cmd="$5" deadline proof token wait_s
  token="$(dm_meta_get "$id" verify_token)"
  proof="$(verify_dir "$id")/ready-proof"
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  # Back off from a short first wait rather than sleeping a flat interval: an app
  # that is already up should cost milliseconds, not seconds. A flat 3s was
  # several minutes of pure sleeping across a test suite's worth of boots.
  wait_s="$READY_FIRST_WAIT"
  while :; do
    if port_busy "$port" && run_app_cmd "$cwd" "$port" "$url" "$id" "$ready_cmd" >/dev/null 2>&1; then
      [ "$(cat "$proof" 2>/dev/null || true)" = "$token" ] && return 0
      dm_warn "app_ready_cmd reported ready but did not write this boot's token to $proof, so nothing proves the process on port $port is the one this task started"
      return 2
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$wait_s"
    case "$wait_s" in
      0.2) wait_s=0.5 ;; 0.5) wait_s=1 ;; 1) wait_s=2 ;; *) wait_s="$READY_INTERVAL" ;;
    esac
  done
}

# stop_app <id> -- run the repo's stop command. Idempotent; also runs from the
# failed-start cleanup path. Returns non-zero when the stop could not be run at
# all, so no caller can record `down` over an app it never stopped.
stop_app() {
  local id="$1" repo cwd port url cmd
  repo="$(dm_meta_get "$id" repo)"; port="$(dm_meta_get "$id" verify_port)"
  cmd="$(app_field "$repo" app_stop_cmd)"
  [ -n "$port" ] && [ -n "$cmd" ] || return 0
  cwd="$(app_cwd "$id")" \
    || { dm_warn "cannot resolve a directory to stop '$id' from; the app may still be running on port $port"; return 1; }
  # Pinned, like every other re-use of boot state: a stop command must target the
  # instance this task started, not whatever the registry says now.
  url="$(dm_meta_get "$id" verify_url)"
  [ -n "$url" ] || url="$(app_url_for "$repo" "$port")"
  run_app_cmd "$cwd" "$port" "$url" "$id" "$cmd" \
    || { dm_warn "app_stop_cmd failed for '$id'"; return 1; }
}

# --- browser isolation (issue #80) -------------------------------------------
# Two crewmates driving one browser interleave and produce garbage — or a false
# pass. chrome-devtools-axi keeps ONE bridge, recorded in ONE pid file under
# $HOME/.chrome-devtools-axi, and reuses whatever that file names: setting
# CHROME_DEVTOOLS_AXI_PORT alone is silently ignored while any bridge is alive.
# That IS the collision. So a task gets its own everything — Chrome process,
# profile, devtools port, bridge port, and (the load-bearing one) its own axi
# state dir via a per-task HOME. Isolation is then VERIFIED, not assumed: the
# bridge must report the allocated port. If it cannot be established, `session`
# falls back to an exclusive LEASE on the one shared browser so two tasks still
# can never overlap.

# browser_binary -- the Chrome/Chromium to launch, or empty. An operator override
# wins; otherwise a PATH install, else the newest Playwright-managed Chromium
# (already present on most machines that do browser work).
browser_binary() {
  local c newest
  if [ -n "${DM_VERIFY_BROWSER_BIN:-}" ]; then
    [ -x "$DM_VERIFY_BROWSER_BIN" ] || dm_die "DM_VERIFY_BROWSER_BIN is not executable: $DM_VERIFY_BROWSER_BIN"
    printf '%s\n' "$DM_VERIFY_BROWSER_BIN"; return 0
  fi
  for c in google-chrome google-chrome-stable chromium chromium-browser chrome; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  newest="$(ls -1d "$HOME"/.cache/ms-playwright/chromium-[0-9]* 2>/dev/null | sort -t- -k2 -n | tail -1)"
  [ -n "$newest" ] && [ -x "$newest/chrome-linux64/chrome" ] && printf '%s\n' "$newest/chrome-linux64/chrome"
  return 0
}

# browser_launch <profile> <devtools_port> -- start a headless browser that owns
# nothing but this task, and print its pid. Fails if it never answers CDP.
browser_launch() {
  local profile="$1" port="$2" bin pid deadline
  bin="$(browser_binary)"
  [ -n "$bin" ] || return 1
  rm -rf "$profile"; mkdir -p "$profile"
  "$bin" --headless=new --no-first-run --no-default-browser-check \
    --disable-gpu --remote-debugging-port="$port" --user-data-dir="$profile" \
    about:blank >"$profile/browser.log" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + 30 ))
  while ! curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/json/version" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$(date +%s)" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      dm_warn "browser at $bin did not expose CDP on port $port (see $profile/browser.log)"
      return 1
    fi
    sleep 1
  done
  printf '%s\n' "$pid"
}

# browser_stop <id> -- stop this task's bridge and browser, in both modes. The
# SHARED bridge is stopped too: the next holder must get a fresh browser, or it
# inherits the previous task's cookies and "already signed in" is a false green.
browser_stop() {
  local id="$1" pid axi_home
  if command -v chrome-devtools-axi >/dev/null 2>&1; then
    axi_home="$(dm_meta_get "$id" verify_axi_home)"
    if [ -n "$axi_home" ]; then
      HOME="$axi_home" CHROME_DEVTOOLS_AXI_PORT="$(dm_meta_get "$id" verify_browser_port)" \
        chrome-devtools-axi stop >/dev/null 2>&1 || true
    elif [ "$(dm_meta_get "$id" verify_browser_mode)" = "shared" ]; then
      chrome-devtools-axi stop >/dev/null 2>&1 || true
    fi
  fi
  pid="$(dm_meta_get "$id" verify_browser_pid)"
  # `0` must be excluded explicitly: it passes a numeric test, and `kill 0`
  # SIGTERMs every process in the caller's group — the crewmate's own shell and
  # the app included. It also succeeds, so `|| true` never fires and 2>/dev/null
  # hides it. This runs from `down`, which every crewmate arms in a trap.
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  case "$pid" in *[!0]*) ;; *) return 0 ;; esac   # 0, 00, 000 … all mean the group
  kill "$pid" 2>/dev/null || true
}

# purge_browser_state <id> -- delete the per-task Chrome profile and axi state.
# They hold cookies, local storage and saved logins for the app just signed into,
# under data/, which `dm-state.sh export` copies wholesale.
purge_browser_state() {
  local dir; dir="$(verify_dir "$1")"
  rm -rf "$dir/chrome-profile" "$dir/axi-home"
}

# lease_abandoned <owner> -- exit 0 when the recorded owner cannot still be using
# the browser. It reads only what was written INSIDE the lock (the owner file)
# and the owner's task record, never a stamp written after the lock was dropped —
# that gap let a second task declare the holder dead and take the same browser.
lease_abandoned() {
  local owner="$1"
  [ -n "$owner" ] || return 0
  dm_valid_id "$owner" || return 0
  [ -f "$(dm_meta_path "$owner")" ] && return 1
  return 0
}

# lease_acquire <id> -- take the shared-browser lease, waiting for a live holder
# up to a bounded deadline and then failing visibly rather than driving anyway.
lease_acquire() {
  local id="$1" owner deadline
  deadline=$(( $(date +%s) + LEASE_TIMEOUT ))
  while :; do
    dm_lock "$LEASE_DIR"
    # The owner file is the lease. Written under the lock, in the same critical
    # section as the mkdir, so a holder is never momentarily anonymous.
    if mkdir "$LEASE_DIR" 2>/dev/null && printf '%s\n' "$id" > "$LEASE_DIR/owner"; then
      dm_unlock "$LEASE_DIR"; dm_meta_set "$id" verify_browser_lease held; return 0
    fi
    owner="$(cat "$LEASE_DIR/owner" 2>/dev/null || true)"
    if [ "$owner" = "$id" ]; then dm_unlock "$LEASE_DIR"; return 0; fi
    if lease_abandoned "$owner"; then
      dm_warn "reclaiming the shared-browser lease from '${owner:-<unrecorded>}' (its task record is gone)"
      rm -rf "$LEASE_DIR"; dm_unlock "$LEASE_DIR"; continue
    fi
    dm_unlock "$LEASE_DIR"
    [ "$(date +%s)" -lt "$deadline" ] \
      || dm_die "the shared verification browser is held by task '$owner'; wait for it, or release it with: dm-verify.sh down $owner"
    sleep 2
  done
}

# lease_held_by <id> -- exit 0 when the lease dir names this task as holder.
lease_held_by() { [ "$(cat "$LEASE_DIR/owner" 2>/dev/null || true)" = "$1" ]; }

# lease_release <id> -- give the shared browser back, only if we still hold it.
lease_release() {
  local id="$1"
  dm_lock "$LEASE_DIR"
  lease_held_by "$id" && rm -rf "$LEASE_DIR"
  dm_unlock "$LEASE_DIR"
  [ -f "$(dm_meta_path "$id")" ] && dm_meta_set "$id" verify_browser_lease released
  return 0
}

# release_browser <id> -- give back whichever browser this task took. One owner
# so no teardown path can free the lease but leak the process, or the reverse.
release_browser() {
  local id="$1"
  browser_stop "$id"
  lease_release "$id"
  purge_browser_state "$id"
  [ -n "$(dm_meta_get "$id" verify_browser_mode)" ] && dm_meta_set "$id" verify_browser_mode released
  return 0
}

# session_is_live <id> -- exit 0 when the task's recorded browser can still be
# driven. A released session, a dead browser process, or a shared lease that is
# no longer ours is NOT live: reusing its env would drive somebody else's
# browser while every command still "succeeds".
session_is_live() {
  local id="$1" mode pid
  mode="$(dm_meta_get "$id" verify_browser_mode)"
  case "$mode" in
    shared) lease_held_by "$id"; return $? ;;
    isolated) ;;
    *) return 1 ;;
  esac
  pid="$(dm_meta_get "$id" verify_browser_pid)"
  # Same exclusion, opposite default: `kill -0 0` tests the caller's own process
  # group and always succeeds, which would report a live browser unconditionally.
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$pid" in *[!0]*) ;; *) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# browser_env <id> -- the `K=V` lines env(1) applies to a browser command. NOT an
# export block: HOME is remapped for the browser tooling only, and leaking that
# into a crewmate's own shell would repoint everything else it runs.
browser_env() {
  local id="$1"
  session_is_live "$id" \
    || dm_die "no live browser for '$id'; run: dm-verify.sh session $id (never drive the default shared browser — that is issue #80)"
  printf 'DM_VERIFY_URL=%s\n' "$(dm_meta_get "$id" verify_url)"
  [ "$(dm_meta_get "$id" verify_browser_mode)" = "isolated" ] || return 0
  # npm_config_cache stays pinned to the REAL home, so the remapped HOME does not
  # re-bootstrap the MCP server from scratch for every task.
  printf 'npm_config_cache=%s\n' "${npm_config_cache:-$HOME/.npm}"
  printf 'HOME=%s\n' "$(dm_meta_get "$id" verify_axi_home)"
  printf 'CHROME_DEVTOOLS_AXI_PORT=%s\n' "$(dm_meta_get "$id" verify_browser_port)"
  printf 'CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:%s\n' "$(dm_meta_get "$id" verify_cdp_port)"
}

# run_browser <id> <args...> -- run chrome-devtools-axi against THIS task's
# browser. The single sanctioned entry point; nothing else may drive a browser.
run_browser() {
  local id="$1" line envs=()
  shift
  while IFS= read -r line; do envs+=("$line"); done < <(browser_env "$id")
  # browser_env's dm_die exits only the process substitution, so an empty result
  # is how its refusal reaches here — never run the browser on it.
  [ "${#envs[@]}" -gt 0 ] || dm_die "no usable browser environment for '$id'; run: dm-verify.sh session $id"
  env "${envs[@]}" chrome-devtools-axi "$@"
}

# session_open_isolated <id> -- give the task its own browser + bridge, and PROVE
# the bridge is this task's own. Returns non-zero (leaving nothing usable
# recorded) when isolation cannot be established, so the caller leases the shared
# browser instead of quietly driving whatever bridge happens to be running.
session_open_isolated() {
  local id="$1" profile axi_home bport cport pid reported
  [ "${DM_VERIFY_BROWSER_SHARED:-0}" = "1" ] && return 1
  # Readiness of a launched browser is polled over CDP with curl. Without it we
  # cannot tell a live browser from a dead one, so degrade to the leased shared
  # browser rather than hand back one we never confirmed.
  if ! command -v curl >/dev/null 2>&1; then
    dm_warn "curl is not installed, so a per-task browser cannot be confirmed ready"
    return 1
  fi
  profile="$(verify_dir "$id")/chrome-profile"; axi_home="$(verify_dir "$id")/axi-home"
  # Retire this task's PREVIOUS browser first. Its bridge would otherwise still
  # hold the task's port and still be named by the pid file, so the new session
  # would allocate a different port and axi would silently reuse the old bridge.
  browser_stop "$id"
  bport="$(allocate_port "$id" "$BRIDGE_PORT_BASE" "$BRIDGE_PORT_SPAN")"
  cport="$(allocate_port "$id" "$CDP_PORT_BASE" "$CDP_PORT_SPAN")"
  rm -rf "$axi_home"; mkdir -p "$axi_home"
  pid="$(browser_launch "$profile" "$cport")" || return 1
  dm_meta_set "$id" verify_browser_port "$bport"
  dm_meta_set "$id" verify_cdp_port "$cport"
  dm_meta_set "$id" verify_browser_pid "$pid"
  dm_meta_set "$id" verify_browser_profile "$profile"
  dm_meta_set "$id" verify_axi_home "$axi_home"
  dm_meta_set "$id" verify_browser_mode isolated
  reported="$(run_browser "$id" start 2>/dev/null | sed -n 's/^port: *//p')"
  if [ "$reported" != "$bport" ]; then
    dm_warn "chrome-devtools-axi bound its bridge to '${reported:-<none>}', not this task's port $bport, so isolation is NOT in effect"
    browser_stop "$id"; dm_meta_set "$id" verify_browser_mode released
    return 1
  fi
  dm_warn "browser: isolated — own process (pid $pid), profile, CDP port $cport, bridge port $bport (verified)"
}

# --- evidence ----------------------------------------------------------------

# shot_is_real <file> -- exit 0 only for a plausible PNG. A tool that reports a
# screenshot it never took, or writes a stub, must not become evidence.
shot_is_real() {
  local f="$1" magic
  [ -f "$f" ] || return 1
  [ -L "$f" ] && return 1   # a symlink can point anywhere, including a prior run
  [ "$(wc -c < "$f" | tr -d ' ')" -ge "$MIN_SHOT_BYTES" ] || return 1
  magic="$(od -An -tx1 -N8 < "$f" 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "89504e470d0a1a0a" ]
}

# --- evidence provenance -----------------------------------------------------
# PNG shape is not provenance. Checking only magic+size accepted any image copied
# in, one image reused for three flows, a symlink into a previous run's shots,
# and `cp -a runs/<ts>/shots shots` restoring a whole archived run. So `shot`
# records what it captured — name, content digest, boot token — and a pass is
# only credible when the file on disk still matches an entry for the CURRENT
# boot. Same-user tampering can still edit the manifest; this defends against
# accident and stale evidence, which is what actually happens.

shots_manifest() { printf '%s/shots.manifest\n' "$(verify_dir "$1")"; }

# shot_digest <file> -- content digest, or empty. sha256sum on Linux, shasum on
# macOS; cksum is the last resort so a missing tool cannot silently disable this.
shot_digest() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$f" | awk '{print $1}'
  else cksum < "$f" | awk '{print $1"-"$2}'; fi
}

# shot_record <id> <name> <file> -- note that THIS boot captured this image.
shot_record() {
  printf '%s\t%s\t%s\n' "$2" "$(shot_digest "$3")" "$(dm_meta_get "$1" verify_token)" \
    >> "$(shots_manifest "$1")"
}

# shot_from_this_run <id> <name> -- exit 0 when a usable PNG for <name> exists AND
# this boot's `shot` is what produced the bytes now on disk.
shot_from_this_run() {
  local id="$1" name="$2" f digest token
  f="$(shot_path "$id" "$name")"
  shot_is_real "$f" || return 1
  digest="$(shot_digest "$f")"; token="$(dm_meta_get "$id" verify_token)"
  [ -n "$digest" ] && [ -n "$token" ] || return 1
  awk -F'\t' -v n="$name" -v d="$digest" -v t="$token" \
    '$1 == n && $2 == d && $3 == t { found = 1 } END { exit found ? 0 : 1 }' \
    "$(shots_manifest "$id")" 2>/dev/null
}

# --- surface detection: does the diff touch a user-facing surface? -----------

# changed_files <id> -- every path the task has touched, one per line: its
# committed range against the base PLUS uncommitted and new files. The gate must
# fire on work in progress too — a surface that has moved but is not committed
# yet is exactly the change a crewmate is about to ask to have verified.
changed_files() {
  local id="$1" wt repo dir base
  # Every resolution is checked EXPLICITLY, not left to set -e: this runs inside
  # the caller's command substitution on the left of a `||`, where set -e is
  # suppressed. An unchecked failure would leave $wt empty, and `git -C ""` is a
  # documented no-op that reads the CURRENT directory's repo instead (#119).
  wt="$(dm_require_worktree "$id")" || return 1
  repo="$(dm_meta_get "$id" repo)" || return 1
  [ -n "$wt" ] && [ -n "$repo" ] || return 1
  dir="$(dm_repo_dir "$repo")" || return 1
  base="$(dm_pr_base_for "$id" "" "$dir")" || return 1
  [ -n "$base" ] || return 1
  # An unreachable base is NOT "no committed changes": dropping the range would
  # report only the working tree, and a committed-but-unfetched surface would
  # come back as not-applicable — the silent skip the exit-2 path exists for.
  git -C "$wt" rev-parse --verify --quiet "$base" >/dev/null 2>&1 || return 1
  { git -C "$wt" diff --name-only "$base"...HEAD 2>/dev/null || true
    git -C "$wt" diff --name-only HEAD 2>/dev/null || true
    git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true
  } | LC_ALL=C sort -u
}

# path_matches <path> <normalized-pattern> -- bash-case glob match (`*` crosses
# `/`), also trying the pattern with a leading `*/` stripped so a top-level
# directory still matches `**/api/**`.
path_matches() {
  local path="$1" pat="$2"
  case "$path" in $pat) return 0 ;; esac
  case "$pat" in
    '*/'*) case "$path" in ${pat#'*/'}) return 0 ;; esac ;;
  esac
  return 1
}

# matches_any <path> <normalized-comma-list> -- exit 0 if any pattern matches.
matches_any() {
  local path="$1" rest="$2," pat
  while [ -n "$rest" ]; do
    pat="${rest%%,*}"; rest="${rest#*,}"
    [ -n "$pat" ] || continue
    path_matches "$path" "$pat" && return 0
  done
  return 1
}

# normalize_globs <comma-list> -- `**` to `*`, ONCE, via sed. bash 3.2's
# `${v//\*\*/\*}` yields an ESCAPED star, which matches a literal `*` and never
# a path — the gate would silently under-fire on macOS only.
normalize_globs() { printf '%s' "$1" | sed 's/\*\*/*/g'; }

# gate_decision <id> <repo> -- the SINGLE owner of "should this gate run?". Prints
# the changed paths that touch a user-facing surface; returns 0 required, 1 no
# surface moved, 2 could not determine, 3 surface moved but the repo has no app
# config. `gate` exits on it and `evidence` reports it, so a PR body can never
# claim a decision the gate did not make.
gate_decision() {
  local id="$1" repo="$2" changed hits
  changed="$(changed_files "$id")" || return 2
  hits="$(surface_hits "$repo" "$changed")"
  [ -n "$hits" ] || return 1
  printf '%s\n' "$hits"
  [ -n "$(app_field "$repo" app_start_cmd)" ] || return 3
  return 0
}

# gate_json <id> <repo> <rc> <hits> <count> -- gate_decision's answer as one
# object, exiting 0 for ALL FOUR decisions. 1/2/3 are answers, not failures, and
# a machine reader that treats nonzero as failure loses them — the worst of those
# losses defaults to "nothing to verify", the silent skip this gate exists to
# prevent. Call it from the MAIN shell: inside $( ) its dm_die would be swallowed.
gate_json() {
  local id="$1" repo="$2" rc="$3" hits="$4" n="$5" decision detail
  case "$rc" in
    0) decision=required
       detail="$n changed file(s) touch a user-facing surface of $repo" ;;
    1) decision=not-applicable
       detail="the diff touches no user-facing surface for $repo" ;;
    2) decision=undetermined
       detail="could not determine what '$id' changed, so the verify gate cannot decide" ;;
    3) decision=unavailable
       detail="$n changed file(s) touch a user-facing surface, but '$repo' has no app_start_cmd registered, so the app cannot be booted and NOTHING can be verified" ;;
    *) dm_die "the verify gate returned an unrecognized decision ($rc) for '$id'" ;;
  esac
  jq -nc --arg id "$id" --arg repo "$repo" --arg decision "$decision" \
    --arg detail "$detail" --arg files "$hits" \
    '{id:$id, repo:$repo, decision:$decision, detail:$detail,
      files: ($files | split("\n") | map(select(length > 0)))}'
}

# gate_hit_count <hits> -- how many paths gate_decision named. awk, not `wc -l`:
# an empty list piped through printf still carries a newline and counts as 1.
gate_hit_count() { printf '%s' "$1" | awk 'END { print NR + 0 }'; }

# surface_hits <repo> <changed-paths> -- print each changed path that could change
# what a user sees. With `verify_surfaces` set, only those globs count; without
# it, everything except documentation counts. It takes the path list rather than
# computing it: a resolver failure inside a process substitution would arrive
# here as "nothing changed", i.e. a silent skip.
surface_hits() {
  local surfaces docs path
  surfaces="$(app_field "$1" verify_surfaces)"
  docs="$(normalize_globs "$DOC_ONLY_PATHS")"
  [ -z "$surfaces" ] || surfaces="$(normalize_globs "$surfaces")"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -n "$surfaces" ]; then
      matches_any "$path" "$surfaces" && printf '%s\n' "$path"
    else
      matches_any "$path" "$docs" || printf '%s\n' "$path"
    fi
  done <<EOF
$2
EOF
  # The loop's status is its LAST iteration's: with `verify_surfaces` set, a
  # final non-matching path left it 1, which under set -e aborted `gate` with
  # exit 1 — read by every caller as "no user-facing surface", the silent skip
  # this gate exists to prevent. Only stdout carries the answer, so say so.
  return 0
}

# --- report ------------------------------------------------------------------

# html_escape <text> -- escape for the rendered report page, TEXT and ATTRIBUTE
# contexts alike. The quotes are the load-bearing pair: every value here also
# lands inside `src="..."`/`alt="..."`, where a bare `"` closes the attribute and
# `x" onerror="alert(1)` becomes a working event handler. `&` must go first.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# flows_tally <file> -- "<total> <bad> <malformed>" from ONE pass. Three separate
# parsers over this file disagreed about an unterminated last line, which read as
# `PASS: 0/0` and exit 0 — an empty verdict that looked green.
flows_tally() {
  awk -F'\t' '
    { total++ }
    NF != 6 { malformed++; next }
    $3 != "pass" { bad++ }
    END { printf "%d %d %d\n", total + 0, bad + 0, malformed + 0 }
  ' "$1"
}

# render_report <id> <verdict> -- write report.md and report.html from the
# recorded flows. Never invents a result: the files render flows.tsv verbatim.
render_report() {
  local id="$1" verdict="$2" dir md html ts name result head shot note cls
  dir="$(verify_dir "$id")"; md="$dir/report.md"; html="$dir/report.html"
  { printf '# verification report — %s\n\n' "$id"
    printf 'repo: %s\napp: %s\ncode: %s\nverdict: **%s**\n\n' \
      "$(dm_meta_get "$id" repo)" "$(dm_meta_get "$id" verify_url)" \
      "$(dm_meta_get "$id" verify_head)" "$verdict"
    printf '| flow | result | note | screenshot |\n|---|---|---|---|\n'
  } > "$md"
  { printf '<!doctype html><meta charset="utf-8"><title>verification %s</title>' "$(html_escape "$id")"
    printf '<style>body{font:14px/1.5 system-ui;margin:2rem;max-width:60rem}img{max-width:100%%;border:1px solid #ccc;margin:.5rem 0}.fail{color:#b00}.pass{color:#070}</style>'
    printf '<h1>verification report — %s</h1><p>app: %s<br>code: <code>%s</code><br>verdict: <b class="%s">%s</b></p>' \
      "$(html_escape "$id")" "$(html_escape "$(dm_meta_get "$id" verify_url)")" \
      "$(html_escape "$(dm_meta_get "$id" verify_head)")" \
      "$([ "$verdict" = PASS ] && printf pass || printf fail)" "$verdict"
  } > "$html"
  while IFS="$(printf '\t')" read -r ts name result head shot note; do
    [ -n "$name" ] || continue
    cls="$([ "$result" = pass ] && printf pass || printf fail)"
    printf '| %s | %s | %s | %s |\n' "$name" "$result" "${note:-}" "$shot" >> "$md"
    # Every field here is data read back from a file, so every one is escaped —
    # `$shot` lands inside an attribute, where `x.png"><script>` would otherwise
    # close it, and `$result` is rendered too.
    { printf '<h2 class="%s">%s — %s</h2><p>%s <small>%s · %s</small></p>' \
        "$cls" "$(html_escape "$name")" "$(html_escape "$result")" \
        "$(html_escape "${note:-}")" "$(html_escape "$ts")" "$(html_escape "$head")"
      [ "$shot" != "-" ] && printf '<img src="%s" alt="%s">' \
        "$(html_escape "$shot")" "$(html_escape "$name")"
    } >> "$html"
  done < "$(flows_file "$id")"
  printf '%s\n' "$md"
}

# verify_evidence <id> <surface-file-count> -- the block for a gate that WAS
# required. Rows come from flows.tsv, the same file `report` renders its verdict
# from; a recorded verdict whose flow record is gone, truncated or malformed
# reports itself unavailable rather than restating a verdict nothing backs.
verify_evidence() {
  local id="$1" n="$2" verdict flows head total bad malformed
  verdict="$(dm_meta_get "$id" verify)"
  if [ -z "$verdict" ]; then
    printf '**verify (e2e)** — NOT VERIFIED · %s changed file(s) touch a user-facing surface and no verification was recorded\n' "$n"
    return 0
  fi
  flows="$(flows_file "$id")"
  if [ ! -s "$flows" ] || [ -n "$(tail -c 1 "$flows")" ]; then
    printf '**verify (e2e)** — evidence unavailable · a `%s` verdict is recorded but its flow record is missing or truncated\n' "$verdict"
    return 0
  fi
  set -- $(flows_tally "$flows")
  total="${1:-0}"; bad="${2:-0}"; malformed="${3:-0}"
  if [ "$total" -eq 0 ] || [ "$malformed" -ne 0 ]; then
    printf '**verify (e2e)** — evidence unavailable · the flow record behind a `%s` verdict has %s malformed row(s)\n' "$verdict" "$malformed"
    return 0
  fi
  head="$(dm_meta_get "$id" verify_head)"
  printf '**verify (e2e)** — %s · %s/%s flow(s) at `%s`\n\n' \
    "$verdict" "$((total - bad))" "$total" "${head:-unrecorded}"
  printf '| flow | result | note |\n|---|---|---|\n'
  # The note is CREW-WRITTEN free text going onto a GitHub-rendered page, so its
  # two structural weapons are neutralised as entities: `|` (splits the row) and
  # `<` (opens raw HTML). `&` goes first, and `\` with them — escaping `|` as
  # `\|` was the trap, since a note already containing `\|` became `\\|`, a
  # literal backslash followed by a LIVE delimiter. Inline markdown still
  # renders, inside the cell, where it cannot pose as another gate's verdict.
  # `name` and `result` need nothing: `flow` validates them to [A-Za-z0-9._-]
  # and pass|fail|flake, and refuses a multi-line or tabbed note, so no field
  # here can forge a row or reach a line of its own.
  awk -F'\t' '
    function cell(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      gsub(/\\/, "\\&#92;", s); gsub(/\|/, "\\&#124;", s)
      return s
    }
    NF == 6 { printf "| %s | %s | %s |\n", $2, $3, cell($6) }' "$flows"
}

# --- commands ----------------------------------------------------------------

cmd="${1:-}"; shift || true
id="${1:-}"
case "$cmd" in
  gate|evidence|up|down|session|drive|shot|flow|report)
    [ -n "$id" ] || { echo "usage: dm-verify.sh $cmd <id> ..." >&2; exit 2; }
    dm_require_id "$id"; shift
    ;;
esac

case "$cmd" in
  gate)
    want_json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) want_json=1; shift ;;
        *) dm_die "usage: dm-verify.sh gate <id> [--json]" ;;
      esac
    done
    [ "$want_json" -eq 0 ] || dm_need jq
    repo="$(dm_meta_get "$id" repo)"
    [ -n "$repo" ] || dm_die "task '$id' has no repo recorded"
    grc=0; hits="$(gate_decision "$id" "$repo")" || grc=$?
    n="$(gate_hit_count "$hits")"
    if [ "$want_json" -eq 1 ]; then gate_json "$id" "$repo" "$grc" "$hits" "$n"; exit 0; fi
    case "$grc" in
      # Exit 2 for "could not determine", never 1: 1 means "no surface moved",
      # and reporting an unreadable worktree as nothing-to-verify is the silent
      # skip this gate exists to prevent.
      2) echo "error: could not determine what '$id' changed, so the verify gate cannot decide" >&2; exit 2 ;;
      1) echo "not-applicable: the diff touches no user-facing surface for $repo"; exit 1 ;;
      3)
        echo "UNAVAILABLE: $n changed file(s) touch a user-facing surface, but '$repo' has no app_start_cmd registered, so the app cannot be booted and NOTHING was verified. Report this as unavailable, never as a pass. Register one: dm-repo.sh set $repo app_start_cmd '<cmd honoring \$DM_VERIFY_PORT>'" >&2
        printf '%s\n' "$hits" >&2
        exit 3 ;;
      0)
        echo "required: $n changed file(s) touch a user-facing surface of $repo"
        printf '%s\n' "$hits" ;;
      *) dm_die "the verify gate returned an unrecognized decision ($grc) for '$id'" ;;
    esac
    ;;

  evidence)
    # Read-only: report what the gate DECIDED and what the run RECORDED, for the
    # PR body (#175). Never boots anything and never writes; the decision comes
    # from gate_decision, the same function `gate` exits on, so the PR cannot
    # disagree with the gate.
    repo="$(dm_meta_get "$id" repo)"
    [ -n "$repo" ] || dm_die "task '$id' has no repo recorded"
    grc=0; hits="$(gate_decision "$id" "$repo")" || grc=$?
    n="$(gate_hit_count "$hits")"
    case "$grc" in
      1) : ;;   # no surface moved: the gate never ran, so it contributes nothing
      2) printf '**verify (e2e)** — evidence unavailable · the gate could not determine what this task changed\n' ;;
      3) printf '**verify (e2e)** — NOT VERIFIED · %s changed file(s) touch a user-facing surface, but `%s` has no app config, so the app was never booted\n' "$n" "$repo" ;;
      0) verify_evidence "$id" "$n" ;;
      *) printf '**verify (e2e)** — evidence unavailable · the gate returned an unrecognized decision (%s)\n' "$grc" ;;
    esac
    ;;

  up)
    dm_need od
    wt="$(dm_require_worktree "$id")"; repo="$(dm_meta_get "$id" repo)"
    start_cmd="$(app_field "$repo" app_start_cmd)"
    [ -n "$start_cmd" ] || dm_die "repo '$repo' has no app_start_cmd registered, so the app cannot be booted. This is UNAVAILABLE, not a pass. Register one: dm-repo.sh set $repo app_start_cmd '<cmd honoring \$DM_VERIFY_PORT>'"
    # Refuse a start we could not undo: a leaked app/container outlives the task.
    [ -n "$(app_field "$repo" app_stop_cmd)" ] \
      || dm_die "repo '$repo' registers app_start_cmd but no app_stop_cmd; a started app must always be stoppable"
    # An ownership probe is mandatory. Without one, "the port answers" is the only
    # evidence there is, and any process that binds the port during the readiness
    # window passes as the app under test.
    ready_cmd="$(app_field "$repo" app_ready_cmd)"
    [ -n "$ready_cmd" ] || dm_die "repo '$repo' registers app_start_cmd but no app_ready_cmd. The readiness probe is what proves the process on \$DM_VERIFY_PORT is the instance THIS task started: it must check the app AND copy \"\$DM_VERIFY_DIR/token\" to \"\$DM_VERIFY_DIR/ready-proof\". A bare url fetch proves liveness, not ownership."
    [ "$(dm_meta_get "$id" verify_app_state)" = "up" ] \
      && dm_die "the app for '$id' is already recorded up on port $(dm_meta_get "$id" verify_port); stop it first: dm-verify.sh down $id"
    pinned="$(code_state "$wt")" || dm_die "cannot read the worktree HEAD for '$id'"
    port="$(allocate_port "$id" "$APP_PORT_BASE" "$APP_PORT_SPAN")"
    url="$(app_url_for "$repo" "$port")"
    vdir="$(verify_dir "$id")"
    mkdir -p "$vdir/runs"
    # A boot starts a NEW run, and BOTH halves of the old one are set aside — the
    # flows AND their screenshots. Archiving the flows alone left last run's PNGs
    # in place, and a stale screenshot is exactly what makes an undriven flow look
    # driven. Nothing is deleted; the previous run stays readable under runs/.
    if [ -s "$(flows_file "$id")" ] || [ -n "$(ls -A "$vdir/shots" 2>/dev/null)" ]; then
      prev="$vdir/runs/$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$prev"
      [ -s "$(flows_file "$id")" ] && mv -f "$(flows_file "$id")" "$prev/flows.tsv"
      [ -d "$vdir/shots" ] && mv -f "$vdir/shots" "$prev/shots"
      [ -s "$(shots_manifest "$id")" ] && mv -f "$(shots_manifest "$id")" "$prev/shots.manifest"
    fi
    rm -f "$(flows_file "$id")" "$(shots_manifest "$id")"
    rm -rf "$vdir/shots"; mkdir -p "$vdir/shots"
    rm -f "$vdir/ready-proof"
    # Unguessable, so the proof cannot be replayed or precomputed from the task
    # id and port. Falls back to pid+time only where /dev/urandom is absent.
    token="$(od -An -tx1 -N16 < /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$token" ] || token="$(date -u +%s)-$$-$(printf '%s' "$id$port$pinned" | cksum | awk '{print $1}')"
    printf '%s' "$token" > "$vdir/token"
    # Is app_ready_cmd actually an OWNERSHIP probe? Run it once now, with the
    # port provably silent and nothing started. A real probe cannot pass; one
    # that ends in a bare `cp` of the token passes anything, and would adopt a
    # foreign listener that binds during the readiness window. Detect that here
    # rather than discover it as a green verdict over somebody else's server.
    run_app_cmd "$wt" "$port" "$url" "$id" "$ready_cmd" >/dev/null 2>&1 || true
    if [ "$(cat "$vdir/ready-proof" 2>/dev/null || true)" = "$token" ]; then
      rm -f "$vdir/ready-proof"
      dm_die "repo '$repo' has an app_ready_cmd that proves nothing: it wrote the ownership proof with NOTHING running on port $port. A probe that always passes would adopt any process that binds the port during the readiness window. It must verify the listener is this task's own instance (its container in this task's compose project, the pid its start command spawned) BEFORE copying \"\$DM_VERIFY_DIR/token\" to \"\$DM_VERIFY_DIR/ready-proof\"."
    fi
    rm -f "$vdir/ready-proof"
    dm_meta_set "$id" verify_port "$port"
    dm_meta_set "$id" verify_url "$url"
    dm_meta_set "$id" verify_token "$token"
    dm_meta_set "$id" verify_ready_cmd "$ready_cmd"
    dm_meta_set "$id" verify_head "$pinned"
    dm_meta_set "$id" verify_cwd "$wt"
    dm_meta_set "$id" verify_app_state starting
    # Armed AFTER the meta writes: dm_unlock clears EXIT/INT/TERM, so a trap set
    # before them would be silently disarmed by the next locked write.
    on_failed_start() {
      trap - EXIT INT TERM
      dm_warn "app start failed for '$id'; tearing the app back down"
      stop_app "$id" || dm_warn "the app may still be running on port $port — stop it by hand"
      release_browser "$id"
      dm_meta_set "$id" verify_app_state down
    }
    trap 'on_failed_start' EXIT
    trap 'on_failed_start; exit 130' INT
    trap 'on_failed_start; exit 143' TERM
    dm_info "starting $repo in $wt on port $port ($url)"
    run_app_cmd "$wt" "$port" "$url" "$id" "$start_cmd" \
      || dm_die "app_start_cmd failed for '$repo'"
    ready_rc=0; wait_ready "$wt" "$port" "$url" "$id" "$ready_cmd" || ready_rc=$?
    case "$ready_rc" in
      0) : ;;
      2) dm_die "the app for '$repo' answered but never proved it is this task's instance, so nothing here is verified" ;;
      *) dm_die "the app did not become ready at $url within ${READY_TIMEOUT}s" ;;
    esac
    seed_cmd="$(app_field "$repo" app_seed_cmd)"
    if [ -n "$seed_cmd" ]; then
      run_app_cmd "$wt" "$port" "$url" "$id" "$seed_cmd" || dm_die "app_seed_cmd failed for '$repo'"
    fi
    trap - EXIT INT TERM
    dm_meta_set "$id" verify_app_state up
    dm_status_append "$id" working "verify: app up at $url (${pinned%%/*})"
    dm_info "READY: $url"
    ;;

  down)
    port="$(dm_meta_get "$id" verify_port)"
    stop_rc=0; stop_app "$id" || stop_rc=$?
    release_browser "$id"
    if [ -n "$port" ]; then
      # A `down` that records success over a still-serving app is worse than a
      # failure: the state record says stopped, and nothing stops it later.
      settle=0
      while [ "$settle" -lt "$STOP_SETTLE_SECS" ] && port_busy "$port"; do
        settle=$((settle + 1)); sleep 1
      done
      if port_busy "$port"; then
        [ -f "$(dm_meta_path "$id")" ] && dm_meta_set "$id" verify_app_state leaked
        dm_die "the app for '$id' is STILL listening on port $port after app_stop_cmd; it is not stopped and the task record says so. Stop it by hand before re-running."
      fi
    fi
    [ "$stop_rc" -eq 0 ] || dm_die "could not run app_stop_cmd for '$id'; nothing is listening on port ${port:-<none>}, but the stop was not completed"
    [ -f "$(dm_meta_path "$id")" ] && dm_meta_set "$id" verify_app_state down
    dm_info "stopped the app and browser for '$id' (port ${port:-<none>})"
    ;;

  session)
    # NOT `dm_need curl` here: curl is used only to poll CDP while launching a
    # per-task browser. Requiring it up front made the whole gate unavailable on
    # a host without curl, including the degraded shared-browser path that never
    # calls it. The isolated path checks for it and falls back instead.
    dm_need chrome-devtools-axi
    [ "$(dm_meta_get "$id" verify_app_state)" = "up" ] \
      || dm_die "the app for '$id' is not up; run: dm-verify.sh up $id"
    if ! session_is_live "$id"; then
      if ! session_open_isolated "$id"; then
        lease_acquire "$id"
        # A shared browser is reused across tasks, so retire whatever the last
        # holder left running before this task drives it.
        chrome-devtools-axi stop >/dev/null 2>&1 || true
        dm_meta_set "$id" verify_browser_mode shared
        dm_warn "browser: SHARED — this task could not get one of its own, so it holds an exclusive lease on the default browser; release it with: dm-verify.sh down $id"
      fi
    fi
    # A handle, not an export block: the browser is reachable only through
    # `dm-verify.sh drive|shot`, so a raw chrome-devtools-axi call cannot
    # silently land on the shared bridge this exists to avoid.
    printf 'mode: %s\napp: %s\nbridge_port: %s\ncdp_port: %s\nprofile: %s\n' \
      "$(dm_meta_get "$id" verify_browser_mode)" "$(dm_meta_get "$id" verify_url)" \
      "$(dm_meta_get "$id" verify_browser_port)" "$(dm_meta_get "$id" verify_cdp_port)" \
      "$(dm_meta_get "$id" verify_browser_profile)"
    printf 'drive it with: dm-verify.sh drive %s <chrome-devtools-axi args...>\n' "$id"
    ;;

  drive)
    dm_need chrome-devtools-axi
    [ "$#" -gt 0 ] || dm_die "usage: dm-verify.sh drive <id> <chrome-devtools-axi args...>"
    run_browser "$id" "$@"
    ;;

  shot)
    name="${1:-}"
    [ -n "$name" ] || dm_die "usage: dm-verify.sh shot <id> <name>"
    case "$name" in *[!A-Za-z0-9._-]*|.*) dm_die "screenshot name must be [A-Za-z0-9._-] with no leading dot: '$name'" ;; esac
    dm_need chrome-devtools-axi; dm_need od
    dest="$(shot_path "$id" "$name")"; mkdir -p "$(dirname "$dest")"
    # Capture under the system temp dir, then move. chrome-devtools-mcp only
    # writes inside its negotiated roots (temp by default) and REFUSES anything
    # else — while chrome-devtools-axi still prints a success line naming the
    # path it never wrote. Evidence that silently does not exist is the exact
    # fabricated pass this gate must not produce, so the file is verified here.
    tmp_shot="$(mktemp "${TMPDIR:-/tmp}/dm-verify-shot.XXXXXX")" || dm_die "mktemp failed for a screenshot of '$id'"
    rm -f "$tmp_shot"; tmp_shot="$tmp_shot.png"
    run_browser "$id" screenshot "$tmp_shot" >/dev/null \
      || { rm -f "$tmp_shot"; dm_die "chrome-devtools-axi failed to screenshot for '$id'"; }
    if ! shot_is_real "$tmp_shot"; then
      rm -f "$tmp_shot"
      dm_die "chrome-devtools-axi reported a screenshot but produced no usable PNG; the browser session is not usable, so nothing is verified"
    fi
    rm -f "$dest"   # never write through a symlink planted at the destination
    mv -f "$tmp_shot" "$dest" || { rm -f "$tmp_shot"; dm_die "could not store the screenshot at $dest"; }
    shot_record "$id" "$name" "$dest"
    printf '%s\n' "$dest"
    ;;

  flow)
    name="${1:-}"; result="${2:-}"; note="${3:-}"
    [ -n "$name" ] && [ -n "$result" ] || dm_die "usage: dm-verify.sh flow <id> <name> <pass|fail|flake> [<note>]"
    case "$name" in *[!A-Za-z0-9._-]*|.*) dm_die "flow name must be [A-Za-z0-9._-] with no leading dot: '$name'" ;; esac
    case "$result" in pass|fail|flake) ;; *) dm_die "flow result must be pass|fail|flake" ;; esac
    dm_require_single_line "flow note" "$note"
    case "$note" in *"$(printf '\t')"*) dm_die "flow note must not contain a tab" ;; esac
    shot="-"
    shot_from_this_run "$id" "$name" && shot="shots/$name.png"
    if [ "$result" = "pass" ]; then
      # A pass is a claim about a running app seen through a real browser. Each
      # of these is the mechanical form of that claim; prose in a skill is not.
      dm_need od
      require_app_serving "$id" "'pass' for '$name'"
      session_is_live "$id" \
        || dm_die "refusing 'pass' for '$name': '$id' has no live browser, so no flow was driven"
      require_unmoved_code "$id"
      [ "$shot" != "-" ] \
        || dm_die "refusing 'pass' for '$name': no screenshot of '$name' was taken during THIS run. A PNG on disk is not evidence unless this run's \`shot\` produced it — capture the asserted state: dm-verify.sh shot $id $name"
    fi
    mkdir -p "$(verify_dir "$id")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$result" \
      "$(dm_meta_get "$id" verify_head)" "$shot" "$note" >> "$(flows_file "$id")"
    dm_info "recorded flow '$name': $result${shot:+ ($shot)}"
    ;;

  report)
    dm_need od
    flows="$(flows_file "$id")"; vdir="$(verify_dir "$id")"
    if [ ! -s "$flows" ]; then
      echo "NOTHING VERIFIED: no flow was recorded for '$id'. An unverified change is not a passing one — drive a flow and record it (dm-verify.sh flow $id <name> pass|fail), or report the gate as unavailable." >&2
      exit 3
    fi
    # A truncated final line used to read as `PASS: 0/0` (wc counted 0 rows, awk
    # counted 1), so an interrupted write looked green. Refuse the file instead.
    [ -z "$(tail -c 1 "$flows")" ] \
      || dm_die "the flow record for '$id' does not end in a newline, so it was truncated mid-write; nothing here can be trusted as a verdict"
    set -- $(flows_tally "$flows")
    total="${1:-0}"; bad="${2:-0}"; malformed="${3:-0}"
    [ "$malformed" -eq 0 ] \
      || dm_die "$malformed malformed row(s) in the flow record for '$id'; nothing here can be trusted as a verdict"
    [ "$total" -gt 0 ] \
      || dm_die "the flow record for '$id' holds no usable row; nothing was verified"
    # Re-check every pass against the file on disk AND against this boot's
    # capture manifest. `flow` checked both at record time; this catches evidence
    # deleted, swapped, symlinked, or restored wholesale from an archived run.
    missing=""
    while IFS="$(printf '\t')" read -r _ts fname fresult _fhead fshot _fnote; do
      # The path check runs for EVERY row, above the pass filter: a `fail` row
      # renders into report.html just the same, so `../../../../x.png` reaching
      # an <img src> does not care what the verdict was.
      # `$fname` is validated FIRST, against the charset `flow` enforces. Checking
      # only `$fshot` = "shots/$fname.png" compared two fields from the same
      # untrusted file, so a crafted matching pair passed the filter unread.
      case "$fname" in
        ''|.*|*[!A-Za-z0-9._-]*) missing="$missing <malformed-flow-name>"; continue ;;
      esac
      case "$fshot" in
        -|"shots/$fname.png") ;;
        *) missing="$missing $fname"; continue ;;
      esac
      [ "$fresult" = "pass" ] || continue
      shot_from_this_run "$id" "$fname" || missing="$missing $fname"
    done < "$flows"
    [ -z "$missing" ] \
      || dm_die "flow(s) name a screenshot that is not this run's own:$missing — the evidence for this verdict does not exist, or is not what this run captured"
    require_app_serving "$id" "this verdict"
    require_unmoved_code "$id"
    if [ "$bad" -eq 0 ]; then verdict="PASS"; else verdict="FAIL"; fi
    out="$(render_report "$id" "$verdict")"
    dm_info "$verdict: $((total - bad))/$total flow(s) passed at $(dm_meta_get "$id" verify_head) — $out"
    if [ "$bad" -eq 0 ]; then
      dm_meta_set "$id" verify "pass"
      dm_status_append "$id" working "verify: pass ($total flow(s))"
      exit 0
    fi
    dm_meta_set "$id" verify "fail"
    dm_status_append "$id" blocked "verify: FAILED ($bad of $total flow(s) did not pass)"
    awk -F'\t' '$3 != "pass" { printf "  %s: %s %s\n", $2, $3, $6 }' "$flows" >&2
    exit 1
    ;;

  *)
    echo "usage: dm-verify.sh {gate|evidence|up|down|session|drive|shot|flow|report} <id> ..." >&2; exit 2 ;;
esac

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
#   gate <id>              should the verify gate run for this task's diff?
#                          exit 0 = required, 1 = no user-facing surface,
#                          2 = could not determine (never reported as a skip),
#                          3 = surface touched but the repo has no app config
#                          (UNAVAILABLE — report it, never a silent pass)
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
#                          REFUSED without a live app, a live browser, an
#                          unmoved HEAD, and a real screenshot of that flow.
#   report <id>            render data/<id>/verify/report.{md,html} and exit
#                          0 = every flow passed, 1 = some flow did not,
#                          2 = not a verdict at all (the code moved under it),
#                          3 = nothing was recorded (never a pass)
#
# Three things the gate enforces itself rather than asking an agent to honor:
#   - A `pass` needs EVIDENCE. `flow` refuses one without a screenshot that is a
#     real PNG, and `report` re-checks every pass row against the file on disk.
#   - A verdict is bound to CODE. `up` pins the worktree's HEAD and dirty-state
#     fingerprint; `flow` and `report` refuse once either has moved, so a green
#     run cannot be carried over a later edit.
#   - The app under test is the one WE started. The port must be silent before
#     start, and `app_ready_cmd` must copy the per-boot token to
#     $DM_VERIFY_DIR/ready-proof — proving the listener is this task's instance,
#     not an operator's server that happened to appear on the port.
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
STOP_SETTLE_SECS="${DM_VERIFY_STOP_SETTLE:-20}"
LEASE_TIMEOUT="${DM_VERIFY_LEASE_TIMEOUT:-600}"
LEASE_DIR="$DM_STATE/browser.lease"
# A screenshot smaller than this, or without PNG magic, is not evidence.
MIN_SHOT_BYTES=512
# Paths that cannot change what a user sees. With no `verify_surfaces` set, a
# repo that HAS app config verifies any change outside this set — under-firing
# is the one failure mode a verification gate cannot afford, so the default is
# broad and `verify_surfaces` NARROWS it.
DOC_ONLY_PATHS='*.md,*.txt,*.rst,docs/**,doc/**,LICENSE*,NOTICE*,CHANGELOG*,AGENTS.md,.github/**,.gitignore,.dm-knowledge/**'

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

# code_state <worktree> -- "<head>/<porcelain-checksum>", or empty when the
# worktree cannot be read.
code_state() {
  local wt="$1" head dirty
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  dirty="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null | cksum | awk '{print $1}')" || return 1
  printf '%s/%s\n' "$head" "$dirty"
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
  ( cd "$cwd" \
    && DM_VERIFY_PORT="$port" DM_VERIFY_URL="$url" DM_VERIFY_TASK="$id" \
       DM_VERIFY_DIR="$(verify_dir "$id")" \
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
  local cwd="$1" port="$2" url="$3" id="$4" ready_cmd="$5" deadline proof token
  token="$(dm_meta_get "$id" verify_token)"
  proof="$(verify_dir "$id")/ready-proof"
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while :; do
    if port_busy "$port" && run_app_cmd "$cwd" "$port" "$url" "$id" "$ready_cmd" >/dev/null 2>&1; then
      [ "$(cat "$proof" 2>/dev/null || true)" = "$token" ] && return 0
      dm_warn "app_ready_cmd reported ready but did not write this boot's token to $proof, so nothing proves the process on port $port is the one this task started"
      return 2
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$READY_INTERVAL"
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
  url="$(app_url_for "$repo" "$port")"
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
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
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
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
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
  [ "$(wc -c < "$f" | tr -d ' ')" -ge "$MIN_SHOT_BYTES" ] || return 1
  magic="$(od -An -tx1 -N8 < "$f" 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "89504e470d0a1a0a" ]
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
  { if git -C "$wt" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      git -C "$wt" diff --name-only "$base"...HEAD 2>/dev/null || true
    fi
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
}

# --- report ------------------------------------------------------------------

# html_escape <text> -- minimal escaping for the rendered report page.
html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

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
    { printf '<h2 class="%s">%s — %s</h2><p>%s <small>%s · %s</small></p>' \
        "$cls" "$(html_escape "$name")" "$result" "$(html_escape "${note:-}")" "$ts" "$(html_escape "$head")"
      [ "$shot" != "-" ] && printf '<img src="%s" alt="%s">' "$shot" "$(html_escape "$name")"
    } >> "$html"
  done < "$(flows_file "$id")"
  printf '%s\n' "$md"
}

# --- commands ----------------------------------------------------------------

cmd="${1:-}"; shift || true
id="${1:-}"
case "$cmd" in
  gate|up|down|session|drive|shot|flow|report)
    [ -n "$id" ] || { echo "usage: dm-verify.sh $cmd <id> ..." >&2; exit 2; }
    dm_require_id "$id"; shift
    ;;
esac

case "$cmd" in
  gate)
    repo="$(dm_meta_get "$id" repo)"
    [ -n "$repo" ] || dm_die "task '$id' has no repo recorded"
    # Exit 2 for "could not determine", never 1: 1 means "no surface moved", and
    # reporting an unreadable worktree as nothing-to-verify is the silent skip
    # this gate exists to prevent.
    changed="$(changed_files "$id")" \
      || { echo "error: could not determine what '$id' changed, so the verify gate cannot decide" >&2; exit 2; }
    hits="$(surface_hits "$repo" "$changed")"
    if [ -z "$hits" ]; then
      echo "not-applicable: the diff touches no user-facing surface for $repo"
      exit 1
    fi
    n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    if [ -z "$(app_field "$repo" app_start_cmd)" ]; then
      echo "UNAVAILABLE: $n changed file(s) touch a user-facing surface, but '$repo' has no app_start_cmd registered, so the app cannot be booted and NOTHING was verified. Report this as unavailable, never as a pass. Register one: dm-repo.sh set $repo app_start_cmd '<cmd honoring \$DM_VERIFY_PORT>'" >&2
      printf '%s\n' "$hits" >&2
      exit 3
    fi
    echo "required: $n changed file(s) touch a user-facing surface of $repo"
    printf '%s\n' "$hits"
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
    fi
    rm -f "$(flows_file "$id")"
    mkdir -p "$vdir/shots"
    rm -f "$vdir/ready-proof"
    token="$(date -u +%s)-$$-$(printf '%s' "$id$port$pinned" | cksum | awk '{print $1}')"
    printf '%s' "$token" > "$vdir/token"
    dm_meta_set "$id" verify_port "$port"
    dm_meta_set "$id" verify_url "$url"
    dm_meta_set "$id" verify_token "$token"
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
    dm_need chrome-devtools-axi; dm_need curl
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
    mv -f "$tmp_shot" "$dest" || { rm -f "$tmp_shot"; dm_die "could not store the screenshot at $dest"; }
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
    if shot_is_real "$(shot_path "$id" "$name")"; then shot="shots/$name.png"; fi
    if [ "$result" = "pass" ]; then
      # A pass is a claim about a running app seen through a real browser. Each
      # of these is the mechanical form of that claim; prose in a skill is not.
      dm_need od
      [ "$(dm_meta_get "$id" verify_app_state)" = "up" ] \
        || dm_die "refusing 'pass' for '$name': the app for '$id' is not up, so no flow was driven"
      session_is_live "$id" \
        || dm_die "refusing 'pass' for '$name': '$id' has no live browser, so no flow was driven"
      require_unmoved_code "$id"
      [ "$shot" != "-" ] \
        || dm_die "refusing 'pass' for '$name': no usable screenshot at $(shot_path "$id" "$name"). Capture the asserted state first: dm-verify.sh shot $id $name"
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
    # Re-check every pass against the file on disk. `flow` checked it at record
    # time; this catches a screenshot deleted, replaced, or never really written.
    missing=""
    while IFS="$(printf '\t')" read -r _ts fname fresult _fhead fshot _fnote; do
      [ "$fresult" = "pass" ] || continue
      shot_is_real "$vdir/$fshot" || missing="$missing $fname"
    done < "$flows"
    [ -z "$missing" ] \
      || dm_die "flow(s) recorded as passing have no screenshot on disk:$missing — the evidence for this verdict does not exist"
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
    echo "usage: dm-verify.sh {gate|up|down|session|drive|shot|flow|report} <id> ..." >&2; exit 2 ;;
esac

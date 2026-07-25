#!/usr/bin/env bash
# dm-ui.sh - run the dockmaster console, the operator's local page.
#
# One local page on 127.0.0.1 that shows what needs the operator, what is in
# flight, every open PR, the repos, the backlog and the review archive - and
# carries the conversation with the dockmaster.
#
# Zero runtime dependencies: Node stdlib serves plain HTML/CSS/JS from ui/.
# No build step, no CDN, no package.json. It works with the network off.
#
# Every panel is read by shelling out to the dm-* scripts, which own the on-disk
# formats. Nothing under ui/ opens state/repos.json, state/tasks/*.meta or
# state/backlog.json.
#
# Commands:
#   start [--source live|fixture]  start the server (idempotent), print its URL.
#                                  Default `live` - the real fleet. `fixture` is
#                                  the committed demo fleet, for design work.
#   open  [--source ...]           start it and open a browser
#   url                            print the URL
#   status                         is it running, and on which source?
#   stop                           stop the server this script started
#   poll [--timeout <seconds>]     BLOCK until the operator sends a message,
#                                  print it, exit 0. Exit 3 on timeout. Claiming
#                                  is a rename, so a killed poll loses nothing -
#                                  re-run it and the message is still queued.
#   say "<text>" | say --file <p>  post the dockmaster's reply into the page
#
# Port: 4877 by default (DM_UI_PORT overrides). Chosen clear of lavish (4387),
# chrome-devtools (9224), and the verify gate's app/bridge/CDP ranges
# (8600-8999, 9300-9499, 9600-9799).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_need node
dm_ensure_dirs

# The page and the toolbelt are CODE: resolved from this script, like bin/ is,
# not from DM_HOME. Only the runtime files below follow DM_HOME, so a distro can
# serve a home that is not its own (which is exactly how this is developed).
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
UI_DIR="$(cd "$BIN_DIR/../ui" 2>/dev/null && pwd -P)" || UI_DIR="$BIN_DIR/../ui"
RUN_DIR="$DM_STATE/ui"
PID_FILE="$RUN_DIR/server.pid"
SOURCE_FILE="$RUN_DIR/server.source"
LOG_FILE="$RUN_DIR/server.log"
PORT="${DM_UI_PORT:-4877}"
URL="http://127.0.0.1:$PORT/"
BOOT_TIMEOUT_SPINS=100   # 100 x 0.1s

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Print the running server's pid, or nothing. A pid file naming a dead process
# is stale; one naming a RECYCLED pid belongs to somebody else, so the command
# line is checked before we ever report it as ours - `stop` kills this pid.
running_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE")"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q "$UI_DIR/server.js" || return 1
  printf '%s\n' "$pid"
}

running_source() { cat "$SOURCE_FILE" 2>/dev/null; }

start_server() {
  local source="$1" pid spins was
  # An already-running server on the OTHER source is the one failure this must
  # never wave through: `start --source live` would otherwise print a URL and
  # keep serving the demo fleet. Replace it, and say so.
  if running_pid >/dev/null; then
    was="$(running_source)"
    if [ "$was" = "$source" ]; then dm_info "$URL"; return 0; fi
    dm_warn "console: was serving '${was:-unknown}', restarting on '$source'"
    stop_server >/dev/null
  fi

  [ -f "$UI_DIR/server.js" ] || dm_die "console: $UI_DIR/server.js is missing"
  mkdir -p "$RUN_DIR"
  : > "$LOG_FILE"
  DM_UI_PORT="$PORT" DM_UI_SOURCE="$source" DM_BIN="$BIN_DIR" \
    nohup node "$UI_DIR/server.js" >>"$LOG_FILE" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  printf '%s\n' "$source" > "$SOURCE_FILE"

  # The server prints its URL once it is actually listening; anything else in
  # the log is the real failure and belongs on screen, not swallowed.
  spins=0
  while [ "$spins" -lt "$BOOT_TIMEOUT_SPINS" ]; do
    if grep -q "^http://127.0.0.1:$PORT/" "$LOG_FILE" 2>/dev/null; then
      dm_info "$URL"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || { rm -f "$PID_FILE" "$SOURCE_FILE"; cat "$LOG_FILE" >&2; dm_die "console: server exited during startup"; }
    sleep 0.1
    spins=$((spins + 1))
  done
  cat "$LOG_FILE" >&2
  dm_die "console: server did not start listening on $PORT within 10s"
}

stop_server() {
  local pid
  pid="$(running_pid)" || { dm_info "console: not running"; rm -f "$PID_FILE" "$SOURCE_FILE"; return 0; }
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE" "$SOURCE_FILE"
  dm_info "console: stopped"
}

open_browser() {
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1 &
  else dm_info "console: open this in a browser: $URL"; fi
}

# --source live|fixture, defaulting to live. Rejected here rather than in the
# server so a typo fails before a process is spawned. Sets DM_UI_ARG_SOURCE and
# returns a status: a dm_die inside $( ) would only kill the subshell, and the
# caller would carry on with an empty value - which is how an invalid source
# used to start the console on the demo fleet.
DM_UI_ARG_SOURCE=""
read_source() {
  local source="live"
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source="${2:-}"; shift 2 || { dm_warn "console: --source needs a value"; return 2; } ;;
      *) dm_warn "console: unexpected argument '$1'"; return 2 ;;
    esac
  done
  case "$source" in
    fixture|live) DM_UI_ARG_SOURCE="$source" ;;
    *) dm_warn "console: --source must be live or fixture, got '$source'"; return 2 ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  start) read_source "$@" || exit $?; start_server "$DM_UI_ARG_SOURCE" ;;
  open)  read_source "$@" || exit $?; start_server "$DM_UI_ARG_SOURCE"; open_browser ;;
  url)   dm_info "$URL" ;;
  status)
    if pid="$(running_pid)"; then dm_info "console: running (pid $pid, source $(running_source)) $URL"
    else dm_info "console: not running"; exit 1; fi
    ;;
  stop) stop_server ;;
  poll)
    timeout=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) timeout="${2:-}"; shift 2 || dm_die "console: --timeout needs a value" ;;
        *) dm_die "console: unexpected argument '$1'" ;;
      esac
    done
    case "$timeout" in ''|*[!0-9]*) dm_die "console: --timeout must be whole seconds" ;; esac
    DM_UI_POLL_TIMEOUT="$timeout" exec node "$UI_DIR/poll.js"
    ;;
  say)
    case "${1:-}" in
      '') dm_die "usage: dm-ui.sh say \"<text>\" | dm-ui.sh say --file <path>" ;;
      --file)
        [ -f "${2:-}" ] || dm_die "console: no such file: '${2:-}'"
        node "$UI_DIR/say.js" < "$2" ;;
      *) printf '%s' "$1" | node "$UI_DIR/say.js" ;;
    esac
    ;;
  ''|help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

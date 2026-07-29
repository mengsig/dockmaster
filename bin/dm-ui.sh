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
#   poll [--timeout <seconds>]     BLOCK until the operator sends something, then
#                                  print EVERYTHING queued - oldest first, each
#                                  record numbered and stamped - and exit 0. Exit
#                                  3 on timeout. Each claim is an atomic rename
#                                  acknowledged only once the text is written, so
#                                  a killed poll (mid-drain included) loses
#                                  nothing: re-run it and it arrives again.
#   say "<text>" | say --file <p>  post the dockmaster's reply into the page
#   ask <key> "<question>"         ask the operator a question through the PAGE
#       [--options "A | B"]        rather than the terminal. Records it as a
#                                  decision hold (durable: it outlives this
#                                  session and the console) so the Needs-you
#                                  panel holds it open, and posts it into the
#                                  conversation. The answer comes back on `poll`
#                                  as an ordinary operator message - no second
#                                  transport, and nothing to resume.
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

usage() { sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# running_pid - print the pid the file names, and return WHICH of three states
# it is in. Callers must distinguish all three:
#
#   0  our server is running on that pid
#   1  nothing is running: no pid file, or it names a dead process
#   2  that pid is ALIVE but is not this console - a recycled pid, or a console
#      started from another checkout
#
# 2 is never "not running". Deleting that file orphans whatever holds the port,
# and the next `start` then fails with a bare address-in-use naming no cause.
running_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
  # -F: the path is a literal. Unquoted it is a regex, where every `.` matches
  # anything and a path with a metacharacter matches the wrong process.
  ps -p "$pid" -o args= 2>/dev/null | grep -qF -- "$UI_DIR/server.js" || return 2
}

# A live pid that is not ours: refuse, and touch neither the process nor the
# file. The operator is the only one who knows what that process is.
die_not_ours() {
  dm_die "console: $PID_FILE names live process $1, which is not this console - leaving both alone. Find out what it is, then remove that file."
}

running_source() { cat "$SOURCE_FILE" 2>/dev/null; }

start_server() {
  local source="$1" pid spins was rc=0
  pid="$(running_pid)" || rc=$?
  [ "$rc" -ne 2 ] || die_not_ours "$pid"
  # An already-running server on the OTHER source is the one failure this must
  # never wave through: `start --source live` would otherwise print a URL and
  # keep serving the demo fleet. Replace it, and say so.
  if [ "$rc" -eq 0 ]; then
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
  local pid rc=0
  pid="$(running_pid)" || rc=$?
  [ "$rc" -ne 2 ] || die_not_ours "$pid"
  if [ "$rc" -ne 0 ]; then
    dm_info "console: not running"
    rm -f "$PID_FILE" "$SOURCE_FILE"
    return 0
  fi
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
    rc=0; pid="$(running_pid)" || rc=$?
    case "$rc" in
      0) dm_info "console: running (pid $pid, source $(running_source)) $URL" ;;
      2) die_not_ours "$pid" ;;
      *) dm_info "console: not running"; exit 1 ;;
    esac
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
  ask)
    # A question asked through the page, built out of the two stores that
    # already exist rather than a third: the decision log holds it OPEN (the
    # Needs-you panel reads exactly that, and it survives both this session and
    # the console dying), and the transcript carries it into the conversation
    # where the operator is reading. The answer comes back on `poll` as an
    # ordinary operator message, so poll's contract is untouched.
    key="${1:-}"; question="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$key" ] && [ -n "$question" ] \
      || dm_die "usage: dm-ui.sh ask <key> \"<question>\" [--options \"A | B\"]"
    options=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --options) options="${2:-}"; shift 2 || dm_die "console: --options needs a value" ;;
        *) dm_die "console: unexpected argument '$1'" ;;
      esac
    done
    # `hold` is an upsert that KEEPS an existing answer, so reusing an answered
    # key would post a question into the conversation with nothing holding it
    # open - the exact failure this command exists to prevent, and silent.
    dm_need jq
    answered="$("$BIN_DIR/dm-backlog.sh" decisions --json \
      | jq -r --arg k "$key" '.[] | select(.key==$k and .status=="resolved") | .key')"
    [ -z "$answered" ] || dm_die "console: '$key' is already answered - a new question needs a new key"
    # Recorded before it is said. A question in the conversation that no panel
    # is holding open is the one that scrolls away unanswered.
    if [ -n "$options" ]; then
      "$BIN_DIR/dm-backlog.sh" hold "$key" "$question" --options "$options" >/dev/null
    else
      "$BIN_DIR/dm-backlog.sh" hold "$key" "$question" >/dev/null
    fi
    # Two lines, always: a one-line dockmaster post renders as a terse log row,
    # and a question is not a status line.
    if [ -n "$options" ]; then
      printf '%s\n\nPick one under Needs you to send it, or answer here: %s\n' "$question" "$options"
    else
      printf '%s\n\nOnly you can answer this - answer here.\n' "$question"
    fi | node "$UI_DIR/say.js" >/dev/null
    rc=0; running_pid >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] \
      || dm_warn "console: not running - the question is recorded and shows the next time it starts"
    dm_info "console: asked '$key'; the answer arrives on poll"
    ;;
  ''|help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

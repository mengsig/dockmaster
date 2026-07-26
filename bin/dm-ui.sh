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
#                                  Prints a reminder to arm `watch` (below) when
#                                  it is not already running.
#   open  [--source ...]           start it and open a browser
#   url                            print the URL
#   status                         is it running, and on which source? Also
#                                  reports whether the watcher is armed.
#   stop                           stop the server this script started, and
#                                  this script's own watcher if one is running.
#   poll [--timeout <seconds>]     BLOCK until the operator sends something, then
#                                  print EVERYTHING queued - oldest first, each
#                                  record numbered and stamped - and exit 0. Exit
#                                  3 on timeout. Each claim is an atomic rename
#                                  acknowledged only once the text is written, so
#                                  a killed poll (mid-drain included) loses
#                                  nothing: re-run it and it arrives again.
#   watch                          run `poll` in bounded slices (DM_UI_WATCH_
#                                  TIMEOUT seconds, default 300), forever, so
#                                  delivery survives a drain AND an idle
#                                  timeout instead of going quiet after either.
#                                  Meant to run under a persistent watch
#                                  (Monitor or equivalent) so each poll call
#                                  that delivers - one message or several - is
#                                  its own wake - see
#                                  .claude/skills/dockmaster/SKILL.md for how
#                                  to arm it. Refuses to double-arm; exits
#                                  loudly (never silently) if the inbox
#                                  becomes unreadable.
#   say "<text>" | say --file <p>  post the dockmaster's reply into the page
#   ask <key> "<question>"         ask the operator a question through the PAGE
#       [--options "A | B"]        rather than the terminal. Records it as a
#       [--origin <path>]          decision hold (durable: it outlives this
#                                  session and the console) so the Needs-you
#                                  panel holds it open, and posts it into the
#                                  conversation. The answer comes back on `poll`
#                                  as an ordinary operator message - no second
#                                  transport, and nothing to resume. --origin
#                                  ties the question to a task's data/<id>/
#                                  report, the backlink dm-trash.sh resolves
#                                  that task's open holds through.
#                                  <key> must be UNUSED: it will not write over
#                                  a decision already on the board, and two asks
#                                  racing on one key cannot both write. A question
#                                  is one line, no tab, at most 300 characters
#                                  (the length at which the page's answer stops
#                                  identifying it); options split on '|', which is
#                                  therefore not expressible inside one - reword
#                                  the option.
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
WATCH_PID_FILE="$RUN_DIR/watch.pid"
PORT="${DM_UI_PORT:-4877}"
URL="http://127.0.0.1:$PORT/"
BOOT_TIMEOUT_SPINS=100   # 100 x 0.1s
# The longest question `ask` will take. It is the length at which the page cuts
# the question in the answer header it matches an answer back by (dom.mjs
# QUESTION_MAX); past it, two questions become one identity. The two numbers must
# agree, and tests/check-console.js pins them equal.
ASK_QUESTION_MAX=300

usage() { sed -n '2,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

# running_watch_pid - same three states as running_pid, for the watcher this
# script arms separately (see watch_cmd). The watcher is not spawned BY this
# script (it runs foreground, held open by whatever armed it), so identity is
# checked by command line rather than by a pid this process itself recorded.
running_watch_pid() {
  local pid
  [ -f "$WATCH_PID_FILE" ] || return 1
  pid="$(cat "$WATCH_PID_FILE" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
  # Anchored at the END of the command line: a caller whose args merely
  # MENTION "dm-ui.sh watch" somewhere inside a larger invocation (a wrapper
  # script, a quoted instruction) must not match - only a process that is
  # ACTUALLY exec'ing this script with `watch` as its final argument does.
  ps -p "$pid" -o args= 2>/dev/null | grep -qE '(^|/| )dm-ui\.sh watch[[:space:]]*$' || return 2
}

# watch_armed - true (rc 0) only when OUR watcher is confirmed running. An
# unidentified live pid (state 2) is deliberately NOT "armed" here: it is not
# safe to trust a process this script cannot positively identify as its own.
watch_armed() {
  local rc=0
  running_watch_pid >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

# A live pid that is not ours: refuse, and touch neither the process nor the
# file. The operator is the only one who knows what that process is.
die_not_ours() {
  local file="$1" pid="$2" label="$3"
  dm_die "console: $file names live process $pid, which is not $label - leaving both alone. Find out what it is, then remove that file."
}

running_source() { cat "$SOURCE_FILE" 2>/dev/null; }

# Printed on every successful start/open, so arming is something the caller
# READS off the command it just ran rather than something it has to recall
# later. This is the one step a shell script cannot do for itself: only the
# session talking to the operator can hold a persistent watch open (see
# watch_cmd and .claude/skills/dockmaster/SKILL.md) - so it is stated here,
# every time, instead of left to be remembered.
announce_watch() {
  if watch_armed; then
    dm_info "console: watcher armed - operator messages reach this session"
  else
    dm_info "console: watcher NOT armed - arm it now or operator messages will queue without waking this session:"
    dm_info "  $BIN_DIR/dm-ui.sh watch    (run under a persistent watch/Monitor, not in the foreground)"
  fi
}

start_server() {
  local source="$1" pid spins was rc=0
  pid="$(running_pid)" || rc=$?
  [ "$rc" -ne 2 ] || die_not_ours "$PID_FILE" "$pid" "this console"
  # An already-running server on the OTHER source is the one failure this must
  # never wave through: `start --source live` would otherwise print a URL and
  # keep serving the demo fleet. Replace it, and say so.
  if [ "$rc" -eq 0 ]; then
    was="$(running_source)"
    if [ "$was" = "$source" ]; then dm_info "$URL"; announce_watch; return 0; fi
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
      announce_watch
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
  [ "$rc" -ne 2 ] || die_not_ours "$PID_FILE" "$pid" "this console"
  if [ "$rc" -ne 0 ]; then
    dm_info "console: not running"
    rm -f "$PID_FILE" "$SOURCE_FILE"
  else
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$SOURCE_FILE"
    dm_info "console: stopped"
  fi
  stop_watch
}

# The watcher's whole point is delivering messages INTO an open console, so
# stopping the console disarms it too rather than leaving it polling forever
# for a page nobody can type into. An unidentified live pid is left alone,
# same rule as the server: this only ever touches a process it can name.
stop_watch() {
  local pid rc=0
  pid="$(running_watch_pid)" || rc=$?
  case "$rc" in
    1) return 0 ;;
    2) dm_warn "console: $WATCH_PID_FILE names live process $pid, which is not this console's watcher - leaving it alone"; return 0 ;;
  esac
  kill "$pid" 2>/dev/null || true
  rm -f "$WATCH_PID_FILE"
  dm_info "console: watcher stopped"
}

# watch_cmd - run `poll` forever, one operator message at a time, so delivery
# survives a claim instead of disarming after the first message (the original
# defect: a single poll answers one wake and exits, and nothing re-armed it).
#
# Meant to run under a persistent watch (Monitor or equivalent): each message
# node poll.js prints IS the wake, one per delivered message, for as long as
# this keeps running - not a bare background shell loop, which produces no
# wake at all and only buries messages in a log nobody is reading.
#
# There are TWO ways a single `poll` stops watching, not one: it claims a
# message and exits 0, OR it times out with nothing queued and exits 3 (see
# `poll` above). Both must re-arm; only a real failure (the inbox unreadable,
# poll.js crashing) must not. A single unbounded poll.js call turns exit 3
# into an unreachable code path, which trades a periodic, provable checkpoint
# for one theoretical shortcoming: an all-day node process nothing ever
# re-verifies is still alive. Chosen instead: poll in bounded slices
# (DM_UI_WATCH_TIMEOUT, default 300s) and treat exit 0 and exit 3 as the SAME
# outcome - keep going - so no single node process outlives one slice without
# proving, by exiting 0 or 3 on its own, that it was still functioning.
#
# Refuses to double-arm (idempotent like `start`) and never silently stops:
# an unreadable inbox or a killed poll ends this loop LOUDLY, because a
# watcher that silently isn't running reads as covered when it is not.
watch_cmd() {
  local pid rc=0 child="" timeout="${DM_UI_WATCH_TIMEOUT:-300}"
  case "$timeout" in ''|*[!0-9]*) dm_die "console: DM_UI_WATCH_TIMEOUT must be whole seconds, got '$timeout'" ;; esac
  pid="$(running_watch_pid)" || rc=$?
  case "$rc" in
    2) die_not_ours "$WATCH_PID_FILE" "$pid" "this console's watcher" ;;
    0) dm_info "console: watcher already armed (pid $pid)"; return 0 ;;
  esac
  mkdir -p "$RUN_DIR"
  printf '%s\n' "$$" > "$WATCH_PID_FILE"
  # A bare `kill` on this process alone would orphan whatever poll.js child is
  # in flight: it blocks (up to $timeout), so it would keep holding the
  # inbox's fs.watch open with no pid file naming it. Stopping the watcher
  # means stopping its child too, on every exit path (normal, killed, or a
  # broken inbox). "${child:-NONE}" keeps this well-formed even between polls,
  # when there is no child to kill.
  trap 'kill "${child:-NONE}" 2>/dev/null || true; rm -f "$WATCH_PID_FILE"; exit' EXIT INT TERM
  dm_info "console: watcher armed (pid $$) - delivering operator messages until stopped"
  while true; do
    DM_UI_POLL_TIMEOUT="$timeout" node "$UI_DIR/poll.js" &
    child=$!
    rc=0
    wait "$child" || rc=$?
    child=""
    case "$rc" in
      0|3) ;;  # 0: delivered a message. 3: idle timeout, nothing queued. Both loop again.
      *) dm_die "console: watcher: poll exited $rc - the inbox could not be read; investigate, then re-arm with 'dm-ui.sh watch'" ;;
    esac
  done
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
      0) dm_info "console: running (pid $pid, source $(running_source)) $URL"; announce_watch ;;
      2) die_not_ours "$PID_FILE" "$pid" "this console" ;;
      # The watcher is its own process (see watch_cmd), so a console that died
      # on its own - a crash, a killed session, anything short of `stop` -
      # does not necessarily take the watcher with it. Report it here too, or
      # a surviving watcher is invisible: neither "armed" (no console to
      # reach) nor "not running" (it still is) covers it, so name it plainly.
      *)
        dm_info "console: not running"
        if watch_armed; then
          dm_info "console: watcher is still armed with no console running - it keeps watching state/ui/inbox, but nothing can reach it without the server up. Run 'stop' to clear it, or 'start'/'open' to bring the console back."
        fi
        exit 1
        ;;
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
  watch)
    [ $# -eq 0 ] || dm_die "console: watch takes no arguments"
    watch_cmd
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
      || dm_die "usage: dm-ui.sh ask <key> \"<question>\" [--options \"A | B\"] [--origin <path>]"
    options=""; origin=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --options) options="${2:-}"; shift 2 || dm_die "console: --options needs a value" ;;
        # A question about a specific task's data/<id>/ report: passed straight
        # through to the hold's --origin, the backlink dm-trash.sh resolves that
        # task's open holds through. Without it, an ask's free-form key matches
        # neither of dm-trash.sh's two conventions (<id>-decision-* key prefix,
        # or this origin), and trashing the task leaves the question open forever.
        --origin) origin="${2:-}"; shift 2 || dm_die "console: --origin needs a value" ;;
        *) dm_die "console: unexpected argument '$1'" ;;
      esac
    done
    # A question is ONE line with no tabs. The decision log prints one line per
    # hold, tab-separated (dm-backlog.sh decisions, dm-status.sh), and the answer
    # echoes the question as a single header line: a newline shreds both surfaces
    # and a tab shreds the column layout of the first.
    case "$question" in
      *$'\n'*) dm_die "console: a question must be one line - the decision log and the answer both print it on one" ;;
      *$'\t'*) dm_die "console: a question must not contain a tab - the decision log is tab-separated and a tab breaks its columns" ;;
    esac
    # The page identifies an answer by the question echoed back in its header, cut
    # at ASK_QUESTION_MAX. Two questions identical up to that cut produce
    # byte-identical answers, and neither the page nor the dockmaster could tell
    # which one was answered - so a question that would be cut is refused here
    # rather than asked ambiguously. (Characters, as bash counts them; the page
    # cuts in UTF-16 units, so an astral character leaves less room than one.)
    [ "${#question}" -le "$ASK_QUESTION_MAX" ] \
      || dm_die "console: a question must be at most $ASK_QUESTION_MAX characters - the page matches an answer back by the question it echoes, and a longer one is cut, so two of them could not be told apart"
    # Recorded before it is said. A question in the conversation that no panel
    # is holding open is the one that scrolls away unanswered.
    #
    # Keys are free-form and invented per question, and `hold` is an upsert:
    # reusing one would destroy whatever decision was already open under it - its
    # question, its options and the --origin backlink dm-trash.sh resolves holds
    # through - with nothing left to say it happened. --only-if-free is the
    # compare-and-set that refuses that inside the backlog's own lock, so two asks
    # racing on one key cannot both write; reading the log here and then writing
    # was that race, and each collision cost a question. dm-backlog.sh owns the
    # verdict; this only words it for the operator, and reports anything else that
    # went wrong as itself rather than as a taken key.
    hold_cmd=(hold "$key" "$question")
    [ -n "$options" ] && hold_cmd=(hold "$key" "$question" --options "$options")
    [ -n "$origin" ] && hold_cmd=("${hold_cmd[@]}" --origin "$origin")
    hold_cmd=("${hold_cmd[@]}" --only-if-free)
    hold_rc=0
    hold_err="$("$BIN_DIR/dm-backlog.sh" "${hold_cmd[@]}" 2>&1 >/dev/null)" || hold_rc=$?
    if [ "$hold_rc" -ne 0 ]; then
      # Matched on the FIXED tail of dm-backlog.sh's own wording, not the
      # `dm:hold-taken`/`dm:hold-answered` token: the token sits right next to the
      # caller-chosen key in that message, so a key that happens to contain the
      # OTHER token as literal text (e.g. a key of "dm:hold-taken-mykey" that is
      # actually answered) used to match the first `case` arm on that substring
      # alone and report the wrong reason. The tail phrase carries no key text.
      case "$hold_err" in
        *"is already answered"*) dm_die "console: '$key' is already answered - a new question needs a new key" ;;
        *"already holds a different open decision"*) dm_die "console: '$key' already holds a different open decision - asking under it would erase that question. Use a new key." ;;
        *) printf '%s\n' "$hold_err" >&2
           dm_die "console: the decision hold for '$key' could not be recorded, so nothing was asked" ;;
      esac
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

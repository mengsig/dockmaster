#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LIVE=0; KEEP_EVIDENCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --keep-evidence) KEEP_EVIDENCE=1; shift ;;
    *) echo "usage: runtime-smoke.sh [--live] [--keep-evidence]" >&2; exit 2 ;;
  esac
done
umask 077
EVIDENCE_ROOT="${DM_RUNTIME_EVIDENCE_DIR:-${TMPDIR:-/tmp}}"
EVIDENCE="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_ROOT")"

cleanup_evidence() {
  local status="$1" raw
  trap - EXIT
  for raw in "$EVIDENCE"/*.raw "$EVIDENCE"/*.raw.*; do
    [ ! -e "$raw" ] || rm -f "$raw"
  done
  if [ "$KEEP_EVIDENCE" -eq 1 ]; then
    printf 'evidence retained: %s\n' "$EVIDENCE"
  else
    rm -rf "$EVIDENCE"
    printf 'evidence cleaned\n'
  fi
  exit "$status"
}
trap 'cleanup_evidence $?' EXIT

evidence_file() {
  "$ROOT/tests/runtime-evidence-dir.sh" reserve "$EVIDENCE" "$1"
}

if [ "${DM_RUNTIME_SMOKE_TEST_ONLY:-0}" = 1 ]; then
  raw="$(evidence_file session.raw)"
  printf '%s\n' "${DM_RUNTIME_SMOKE_FIXTURE_SECRET:-session-secret}" > "$raw"
  status_file="$(evidence_file probe-status.txt)"
  printf 'authenticated probe passed\n' > "$status_file"
  [ "${DM_RUNTIME_SMOKE_FAIL_AFTER_EVIDENCE:-0}" != 1 ] || exit 9
  rm -f "$raw"
  exit 0
fi

node "$ROOT/tests/check-skill-triggers.js"

if command -v claude >/dev/null 2>&1; then
  CLAUDE_VERSION="$(evidence_file claude-version.txt)"
  CLAUDE_HELP="$(evidence_file claude-help.txt)"
  claude --version | tee "$CLAUDE_VERSION"
  claude auth status --json >/dev/null
  printf 'authenticated\n' > "$(evidence_file claude-auth-status.txt)"
  claude --help > "$CLAUDE_HELP"
  printf 'ok   Claude CLI/config compatibility probes\n'
else
  printf 'skip Claude binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

[ "$LIVE" -eq 1 ] || exit 0

CLAUDE_LIVE="$(evidence_file claude-live.raw.json)"
claude -p --permission-mode plan --max-turns 2 --output-format json \
  "Do not modify files. Load task-lifecycle and fleet-change from this project. Reply exactly RUNTIME_OK only if tasks use isolated worktrees and a fleet child stays queued through Agent spawn, then persists the returned agent id before moving inflight; otherwise reply RUNTIME_FAIL." \
  > "$CLAUDE_LIVE"
grep -q 'RUNTIME_OK' "$CLAUDE_LIVE"
rm -f "$CLAUDE_LIVE"
printf 'RUNTIME_OK\n' > "$(evidence_file claude-live-status.txt)"

printf 'ok   live Claude read-only project/skill probe\n'

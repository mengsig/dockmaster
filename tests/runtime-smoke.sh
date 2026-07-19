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

node "$ROOT/tests/check-runtime-parity.js"

check_rule() {
  local expected="$1"; shift
  local output
  output="$(codex execpolicy check --rules "$ROOT/.codex/rules/dockmaster.rules" "$@")"
  [ "$(printf '%s' "$output" | jq -r '.decision // "allow"')" = "$expected" ]
}

check_guard_blocked() {
  if "$ROOT/bin/dm-command-guard.sh" check "$1" >/dev/null 2>&1; then
    printf 'command guard allowed destructive probe: %s\n' "$1" >&2
    return 1
  fi
}

if command -v codex >/dev/null 2>&1; then
  CODEX_VERSION="$(evidence_file codex-version.txt)"
  CODEX_DOCTOR="$(evidence_file codex-doctor.raw.json)"
  CODEX_PROMPT="$(evidence_file codex-prompt-input.raw.json)"
  codex --version | tee "$CODEX_VERSION"
  codex --strict-config doctor --json > "$CODEX_DOCTOR"
  codex debug prompt-input "Do not act." > "$CODEX_PROMPT"
  node "$ROOT/tests/check-codex-skill-discovery.js" "$CODEX_PROMPT" "$ROOT"
  SYMLINK_ROOT="$EVIDENCE/project-link"
  ln -s "$ROOT" "$SYMLINK_ROOT"
  node "$ROOT/tests/check-codex-skill-discovery.js" "$CODEX_PROMPT" "$SYMLINK_ROOT"
  rm -f "$CODEX_DOCTOR" "$CODEX_PROMPT"
  printf 'strict config and structured discovery passed\n' > "$(evidence_file codex-probe-status.txt)"
  check_rule forbidden git reset --hard
  check_rule forbidden git reset HEAD --hard
  check_rule forbidden git clean -fd
  check_rule forbidden git checkout -- file.txt
  check_rule forbidden git checkout feature-branch
  check_rule forbidden git restore file.txt
  check_rule allow git status
  check_guard_blocked 'git -C /tmp reset HEAD --hard'
  check_guard_blocked '/usr/bin/git --no-pager -C /tmp clean -d -f'
  check_guard_blocked '/usr/bin/git -C /tmp restore --source HEAD file.txt'
  check_guard_blocked '/usr/bin/git -C /tmp switch --discard-changes main'
  check_guard_blocked 'git -C "/tmp/a path with spaces" reset --hard'
  check_guard_blocked 'bash -c "git clean -fd"'
  check_guard_blocked '$GIT restore file.txt'
  "$ROOT/bin/dm-command-guard.sh" check 'git -C "/tmp/a path with spaces" status'
  SPACED_GUARD_DIR="$EVIDENCE/root with spaces/bin"
  mkdir -p "$SPACED_GUARD_DIR"
  cp "$ROOT/bin/dm-command-guard.sh" "$SPACED_GUARD_DIR/"
  printf '{"tool_input":{"command":"git status"}}' \
    | "${SPACED_GUARD_DIR}/dm-command-guard.sh" hook
  printf 'ok   Codex config, discovery, and command-policy probes\n'
else
  printf 'skip Codex binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

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

CODEX_LIVE="$(evidence_file codex-live.raw.jsonl)"
codex exec -C "$ROOT" --dangerously-bypass-hook-trust --ephemeral --sandbox read-only --json \
  "Use read-only tools to read task-lifecycle, fleet-change, change-review, and pr-workflow from this project. Do not modify files. Reply exactly RUNTIME_OK only if: task-lifecycle derives a separate valid thread_name and stores the returned agent id; fleet-change keeps a child queued through spawn_agent, persists its returned agent id, then moves inflight; change-review uses a no-fork waiter whose completion wakes the parent; rigorous verification and security review fail closed when required capabilities or findings remain. Otherwise reply RUNTIME_FAIL." \
  > "$CODEX_LIVE"
grep -q 'RUNTIME_OK' "$CODEX_LIVE"
rm -f "$CODEX_LIVE"
printf 'RUNTIME_OK\n' > "$(evidence_file codex-live-status.txt)"

CODEX_HOOK="$(evidence_file codex-hook-live.raw.jsonl)"
HOOK_CONFIG="hooks.PreToolUse=[{matcher=\"^Bash$\",hooks=[{type=\"command\",command=\"'$ROOT/bin/dm-command-guard.sh' hook\",timeout=10}]}]"
# Worktree trust is path-specific. Inject the checked project's exact hook for
# this read-only proof while leaving the user's persistent trust config untouched.
codex exec -C "$ROOT" -c "$HOOK_CONFIG" --dangerously-bypass-hook-trust --ephemeral --sandbox read-only --json \
  "Run exactly this harmless help command through the shell: /usr/bin/git -C '$ROOT' restore --help. Reply exactly HOOK_BLOCKED only if the project hook rejects it before execution; otherwise reply HOOK_FAIL." \
  > "$CODEX_HOOK"
grep -q 'HOOK_BLOCKED' "$CODEX_HOOK"
rm -f "$CODEX_HOOK"
printf 'HOOK_BLOCKED\n' > "$(evidence_file codex-hook-status.txt)"

printf 'ok   live Claude and Codex read-only project/skill probes\n'

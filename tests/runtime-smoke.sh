#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1
umask 077
EVIDENCE_ROOT="${DM_RUNTIME_EVIDENCE_DIR:-${TMPDIR:-/tmp}}"
EVIDENCE="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_ROOT")"

evidence_file() {
  "$ROOT/tests/runtime-evidence-dir.sh" reserve "$EVIDENCE" "$1"
}

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
  CODEX_DOCTOR="$(evidence_file codex-doctor.json)"
  CODEX_PROMPT="$(evidence_file codex-prompt-input.json)"
  codex --version | tee "$CODEX_VERSION"
  codex --strict-config doctor --json > "$CODEX_DOCTOR"
  codex debug prompt-input "Do not act." > "$CODEX_PROMPT"
  node "$ROOT/tests/check-codex-skill-discovery.js" "$CODEX_PROMPT" "$ROOT"
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
  printf 'ok   Codex config, discovery, and command-policy probes\n'
else
  printf 'skip Codex binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

if command -v claude >/dev/null 2>&1; then
  CLAUDE_VERSION="$(evidence_file claude-version.txt)"
  CLAUDE_AUTH="$(evidence_file claude-auth.json)"
  CLAUDE_HELP="$(evidence_file claude-help.txt)"
  claude --version | tee "$CLAUDE_VERSION"
  claude auth status --json > "$CLAUDE_AUTH"
  claude --help > "$CLAUDE_HELP"
  printf 'ok   Claude CLI/config compatibility probes\n'
else
  printf 'skip Claude binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

[ "$LIVE" -eq 1 ] || exit 0

CLAUDE_LIVE="$(evidence_file claude-live.json)"
claude -p --permission-mode plan --max-turns 2 --output-format json \
  "Do not modify files. Load the task-lifecycle skill from this project. Reply exactly RUNTIME_OK if the project contract says the dockmaster delegates project work into isolated worktrees and the skill covers dispatch through delivery; otherwise reply RUNTIME_FAIL." \
  > "$CLAUDE_LIVE"
grep -q 'RUNTIME_OK' "$CLAUDE_LIVE"

CODEX_LIVE="$(evidence_file codex-live.jsonl)"
codex exec -C "$ROOT" --dangerously-bypass-hook-trust --ephemeral --sandbox read-only --json \
  "Use read-only tools to read task-lifecycle, change-review, and pr-workflow from this project. Do not modify files. Reply exactly RUNTIME_OK only if: task-lifecycle derives a separate valid thread_name and stores the returned agent id; change-review uses a no-fork waiter whose completion wakes the parent; rigorous verification has executable browser or CLI/API fallback and missing capability fails; security review uses explicit general-review lenses and findings fail the gate. Otherwise reply RUNTIME_FAIL." \
  > "$CODEX_LIVE"
grep -q 'RUNTIME_OK' "$CODEX_LIVE"

CODEX_HOOK="$(evidence_file codex-hook-live.jsonl)"
HOOK_CONFIG="hooks.PreToolUse=[{matcher=\"^Bash$\",hooks=[{type=\"command\",command=\"$ROOT/bin/dm-command-guard.sh hook\",timeout=10}]}]"
# Worktree trust is path-specific. Inject the checked project's exact hook for
# this read-only proof while leaving the user's persistent trust config untouched.
codex exec -C "$ROOT" -c "$HOOK_CONFIG" --dangerously-bypass-hook-trust --ephemeral --sandbox read-only --json \
  "Run exactly this harmless help command through the shell: /usr/bin/git -C '$ROOT' restore --help. Reply exactly HOOK_BLOCKED only if the project hook rejects it before execution; otherwise reply HOOK_FAIL." \
  > "$CODEX_HOOK"
grep -q 'HOOK_BLOCKED' "$CODEX_HOOK"

printf 'ok   live Claude and Codex read-only project/skill probes\n'
printf 'evidence: %s\n' "$EVIDENCE"

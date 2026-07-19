#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1
EVIDENCE="${DM_RUNTIME_EVIDENCE_DIR:-${TMPDIR:-/tmp}/dockmaster-runtime-evidence}"
mkdir -p "$EVIDENCE"

node "$ROOT/tests/check-runtime-parity.js"

check_rule() {
  local expected="$1"; shift
  local output
  output="$(codex execpolicy check --rules "$ROOT/.codex/rules/dockmaster.rules" "$@")"
  [ "$(printf '%s' "$output" | jq -r '.decision // "allow"')" = "$expected" ]
}

if command -v codex >/dev/null 2>&1; then
  codex --version | tee "$EVIDENCE/codex-version.txt"
  codex --strict-config doctor --json > "$EVIDENCE/codex-doctor.json"
  codex debug prompt-input "Do not act." > "$EVIDENCE/codex-prompt-input.json"
  prompt_strings="$(jq -r '.. | strings' "$EVIDENCE/codex-prompt-input.json")"
  for skill in $(jq -r '.skills[]' "$ROOT/config/runtime-capabilities.json"); do
    grep -q "$skill" <<<"$prompt_strings"
  done
  check_rule forbidden git reset --hard
  check_rule forbidden git clean -fd
  check_rule forbidden git checkout -- file.txt
  check_rule allow git status
  printf 'ok   Codex config, discovery, and command-policy probes\n'
else
  printf 'skip Codex binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

if command -v claude >/dev/null 2>&1; then
  claude --version | tee "$EVIDENCE/claude-version.txt"
  claude auth status --json > "$EVIDENCE/claude-auth.json"
  claude --help > "$EVIDENCE/claude-help.txt"
  printf 'ok   Claude CLI/config compatibility probes\n'
else
  printf 'skip Claude binary absent\n'
  [ "$LIVE" -eq 0 ] || exit 1
fi

[ "$LIVE" -eq 1 ] || exit 0

claude -p --permission-mode plan --max-turns 2 --output-format json \
  "Do not modify files. Load the task-lifecycle skill from this project. Reply exactly RUNTIME_OK if the project contract says the dockmaster delegates project work into isolated worktrees and the skill covers dispatch through delivery; otherwise reply RUNTIME_FAIL." \
  > "$EVIDENCE/claude-live.json"
grep -q 'RUNTIME_OK' "$EVIDENCE/claude-live.json"

codex exec -C "$ROOT" --ephemeral --sandbox read-only --json \
  "Do not use tools or modify files. Load the task-lifecycle skill from this project. Reply exactly RUNTIME_OK if the project contract says the dockmaster delegates project work into isolated worktrees and the skill covers dispatch through delivery; otherwise reply RUNTIME_FAIL." \
  > "$EVIDENCE/codex-live.jsonl"
grep -q 'RUNTIME_OK' "$EVIDENCE/codex-live.jsonl"

printf 'ok   live Claude and Codex read-only project/skill probes\n'
printf 'evidence: %s\n' "$EVIDENCE"

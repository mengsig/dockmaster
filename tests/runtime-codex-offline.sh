#!/usr/bin/env bash
# Deterministic Codex CLI/config/policy proof that requires no model login.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v codex >/dev/null 2>&1 || { echo "Codex CLI is required" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dm-codex-offline.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

codex --version
codex --strict-config doctor --json > "$tmp/doctor.json"
codex debug prompt-input "Do not act." > "$tmp/prompt.json"
node "$ROOT/tests/check-codex-skill-discovery.js" "$tmp/prompt.json" "$ROOT"

check_rule() {
  local expected="$1"; shift
  local actual
  actual="$(codex execpolicy check --rules "$ROOT/.codex/rules/dockmaster.rules" "$@" | jq -r '.decision // "allow"')"
  [ "$actual" = "$expected" ] || {
    printf 'execpolicy expected %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
    return 1
  }
}

check_rule forbidden git reset --hard
check_rule forbidden git clean -fd
check_rule forbidden git restore file.txt
check_rule forbidden git checkout feature
check_rule allow git status

spaced="$tmp/root with spaces/bin"
mkdir -p "$spaced"
cp "$ROOT/bin/dm-command-guard.sh" "$spaced/"
printf '{"tool_input":{"command":"git status"}}' | "$spaced/dm-command-guard.sh" hook
if printf '{"tool_input":{"command":"git -C \\"/tmp/a path\\" reset --hard"}}' \
    | "$spaced/dm-command-guard.sh" hook >/dev/null 2>&1; then
  echo "spaced-path hook guard allowed reset" >&2
  exit 1
fi
printf 'ok   offline strict config, structured discovery, execpolicy, and hook handler\n'

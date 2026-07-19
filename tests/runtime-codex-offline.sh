#!/usr/bin/env bash
# Deterministic Codex CLI/config/policy proof that requires no model login.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v codex >/dev/null 2>&1 || { echo "Codex CLI is required" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dm-codex-offline.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

check_strict_config() {
  local codex_home="$tmp/codex-home"
  local config="$codex_home/config.toml"
  local doctor_rc=0

  # Validate project config independently of per-user trust and credentials.
  mkdir -p "$codex_home"
  cp "$ROOT/.codex/config.toml" "$config"
  CODEX_HOME="$codex_home" codex --strict-config doctor --json \
    > "$tmp/doctor.json" 2> "$tmp/doctor.stderr" || doctor_rc=$?

  if [ "$doctor_rc" -le 1 ] && jq -e --arg home "$codex_home" --arg config "$config" '
    .schemaVersion == 1 and
    .checks["config.load"].status == "ok" and
    .checks["config.load"].details.CODEX_HOME == $home and
    .checks["config.load"].details["config.toml"] == $config and
    .checks["config.load"].details["config.toml parse"] == "ok" and
    ([.checks | to_entries[] |
      select(.value.status == "fail" and .key != "auth.credentials")] | length) == 0
  ' "$tmp/doctor.json" >/dev/null; then
    return 0
  fi

  printf 'Codex strict config check failed (doctor exit %s)\n' "$doctor_rc" >&2
  sed -n '1,80p' "$tmp/doctor.stderr" >&2
  jq -r '.checks | to_entries[] | select(.value.status == "fail") |
    "  \(.key): \(.value.summary)"' "$tmp/doctor.json" >&2
  return 1
}

codex --version
check_strict_config
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

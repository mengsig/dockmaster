#!/usr/bin/env bash
set -euo pipefail

mode="${1:-create}"
root="${2:-${TMPDIR:-/tmp}}"
umask 077

physical_dir() {
  local directory="$1"
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  (cd "$directory" && pwd -P)
}

if [ "$mode" = "create" ]; then
  mkdir -p "$root"
  root="$(physical_dir "$root")"
  evidence="$(mktemp -d "$root/dockmaster-runtime-evidence.XXXXXX")"
  chmod 700 "$evidence"
  [ -d "$evidence" ] && [ ! -L "$evidence" ]
  printf '%s\n' "$evidence"
  exit 0
fi

[ "$mode" = "reserve" ] || { printf 'unknown mode: %s\n' "$mode" >&2; exit 2; }
name="${3:-}"
[ -n "$name" ] && [ "$name" = "${name##*/}" ] || { printf 'invalid evidence name\n' >&2; exit 2; }
root="$(physical_dir "$root")"
path="$root/$name"
(set -C; : > "$path") 2>/dev/null || { printf 'evidence path already exists: %s\n' "$path" >&2; exit 2; }
chmod 600 "$path"
[ -f "$path" ] && [ ! -L "$path" ] || { printf 'unsafe evidence path: %s\n' "$path" >&2; exit 2; }
printf '%s\n' "$path"

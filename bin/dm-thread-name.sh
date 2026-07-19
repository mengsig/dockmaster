#!/usr/bin/env bash
# dm-thread-name.sh - derive a valid, collision-resistant Codex thread label.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"

id="${1:-}"
role="${2:-}"
[ -n "$id" ] && [ -n "$role" ] || dm_die "usage: dm-thread-name.sh <durable-id> <role>"
dm_require_id "$id"
case "$role" in
  ''|*[!a-z0-9_]*) dm_die "invalid thread role: '$role' (use [a-z0-9_], <= 24 chars)" ;;
esac
[ "${#role}" -le 24 ] || dm_die "invalid thread role: '$role' (use [a-z0-9_], <= 24 chars)"

normalized="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr '.-' '__' | sed 's/__*/_/g')"
digest="$(printf '%s\n%s' "$id" "$role" | git -c extensions.objectFormat=sha1 hash-object --stdin)"
case "$digest" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) dm_die "could not derive a stable Git digest for task '$id'" ;;
esac

normalized="${normalized:0:27}"
role="${role:0:16}"
thread_name="task_${normalized}_${role}_${digest:0:12}"
case "$thread_name" in *[!a-z0-9_]*) dm_die "derived invalid Codex thread name" ;; esac
[ "${#thread_name}" -le 64 ] || dm_die "derived Codex thread name exceeds 64 characters"
printf '%s\n' "$thread_name"

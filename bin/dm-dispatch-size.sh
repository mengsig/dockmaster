#!/usr/bin/env bash
# dm-dispatch-size.sh - deterministic Codex model/effort mapping.

set -euo pipefail

tier="${1:-}"
selectors="${2:-}"
[ "$#" -eq 2 ] \
  || { echo "usage: dm-dispatch-size.sh <haiku|sonnet|opus|waiter> <supported|unsupported>" >&2; exit 2; }

case "$selectors" in
  supported) ;;
  unsupported)
    printf 'model=inherited\nreasoning_effort=inherited\n'
    exit 0
    ;;
  *) echo "selectors must be supported|unsupported" >&2; exit 2 ;;
esac

case "$tier" in
  haiku|waiter) model=gpt-5.6-terra; effort=low ;;
  sonnet) model=gpt-5.6-terra; effort=medium ;;
  opus) model=gpt-5.6-sol; effort=high ;;
  *) echo "tier must be haiku|sonnet|opus|waiter" >&2; exit 2 ;;
esac
printf 'model=%s\nreasoning_effort=%s\n' "$model" "$effort"

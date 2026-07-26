#!/usr/bin/env bash
# tests/smoke-parallel.sh - run every tests/smoke.sh shard at once on this host.
#
# Same coverage as `tests/smoke.sh`, wall clock divided by the shard count. The
# sequential form still works and is what CI's non-sharded consumers use; this
# is the local loop. Background jobs + wait, because GNU parallel is not a given
# on macOS.
# Run: tests/smoke-parallel.sh   (exit 0 = all shards passed)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$ROOT/tests/smoke.sh"
SHARDS="$("$SMOKE" --shards)"
# Every section must be accounted for by exactly one shard. A shard that dies in
# top-level setup prints a truncated pass count and no FAIL summary, which reads
# exactly like success — the section total is what catches it.
EXPECTED_SECTIONS="$(grep -c '^echo "== ' "$SMOKE")"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/dm-smoke-parallel.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

pids=""
k=1
while [ "$k" -le "$SHARDS" ]; do
  ( "$SMOKE" --shard "$k/$SHARDS" > "$OUT/$k.log" 2>&1; printf '%s\n' "$?" > "$OUT/$k.rc" ) &
  pids="$pids $!"
  k=$((k + 1))
done
# Wait on OUR pids only, and never let one shard's failure abort the wait: every
# shard's log is wanted, not just the ones before the first red.
for p in $pids; do wait "$p" || true; done

failed=0
sections=0
passed=0
k=1
while [ "$k" -le "$SHARDS" ]; do
  rc="$(cat "$OUT/$k.rc" 2>/dev/null || echo 1)"
  summary="$(grep '^smoke\[' "$OUT/$k.log" || true)"
  if [ "$rc" != 0 ] || [ -z "$summary" ]; then
    failed=$((failed + 1))
    printf '\n=== shard %s/%s FAILED (exit %s) ===\n' "$k" "$SHARDS" "$rc"
    grep -E '^  FAIL|^error:|^smoke\[' "$OUT/$k.log" || tail -n 20 "$OUT/$k.log"
  else
    printf '%s\n' "$summary"
    passed=$((passed + $(printf '%s' "$summary" | sed 's/.*: \([0-9]*\) passed.*/\1/')))
    sections=$((sections + $(printf '%s' "$summary" | sed 's/.*failed, \([0-9]*\) sections/\1/')))
  fi
  k=$((k + 1))
done

echo
if [ "$failed" -ne 0 ]; then
  echo "smoke-parallel: $failed of $SHARDS shards failed (full logs above)"
  exit 1
fi
if [ "$sections" -ne "$EXPECTED_SECTIONS" ]; then
  echo "smoke-parallel: shards ran $sections sections, the suite has $EXPECTED_SECTIONS — a shard exited early"
  exit 1
fi
echo "smoke-parallel: $passed passed across $SHARDS shards, all $sections sections"

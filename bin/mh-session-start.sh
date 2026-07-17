#!/usr/bin/env bash
# mh-session-start.sh - one composed startup + recovery digest for the manhandler.
#
# Run this once at session start. It reconciles reality with durable records
# before any new work: what is managed, whether clones are fresh, what is
# in-flight, and the operator/fleet memory. It mutates only the guarded
# fast-forward clone sync; everything else is read-only.
#
# Usage: mh-session-start.sh [--no-sync]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mh-lib.sh"
mh_ensure_dirs
here="$(dirname "${BASH_SOURCE[0]}")"

do_sync=1; [ "${1:-}" = "--no-sync" ] && do_sync=0

section() { printf '\n=== %s ===\n' "$1"; }

section "TOOLING"
# mh-doctor owns the dependency contract; delegate so the list never drifts. A
# missing required tool makes doctor exit non-zero — do not let that abort the
# rest of the digest (the missing tool is already reported in its output).
"$here/mh-doctor.sh" check || true

section "MANAGED REPOS"
"$here/mh-repo.sh" list 2>/dev/null || echo "  (none registered)"

if [ "$do_sync" -eq 1 ]; then
  section "CLONE SYNC (fast-forward only; STUCK = needs attention)"
  "$here/mh-sync.sh" all 2>/dev/null || echo "  (sync skipped)"
fi

section "IN-FLIGHT WORK (reconciled state)"
"$here/mh-task.sh" list 2>/dev/null || echo "  (no tasks)"

section "BACKLOG"
if [ -f "$MH_STATE/backlog.md" ]; then "$here/mh-backlog.sh" list; else echo "  ABSENT (no backlog yet)"; fi

for f in operator.md learnings.md; do
  section "$(printf '%s' "$f" | tr '[:lower:].' '[:upper:] ' )"
  if [ -f "$MH_STATE/$f" ]; then cat "$MH_STATE/$f"; else echo "  ABSENT (template defaults; create $MH_STATE/$f when you have content)"; fi
done

section "NEXT"
echo "  Reconcile any STUCK clones and non-pending in-flight tasks before taking new work."
echo "  Load task-lifecycle before dispatching; supervision whenever work is in flight."

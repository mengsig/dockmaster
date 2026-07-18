#!/usr/bin/env bash
# dm-session-start.sh - one composed startup + recovery digest for the dockmaster.
#
# Run this once at session start. It reconciles reality with durable records
# before any new work: what is managed, whether clones are fresh, what is
# in-flight, and the operator/fleet memory. It mutates only the guarded
# fast-forward clone sync; everything else is read-only.
#
# Usage: dm-session-start.sh [--no-sync]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
here="$(dirname "${BASH_SOURCE[0]}")"

do_sync=1; [ "${1:-}" = "--no-sync" ] && do_sync=0

section() { printf '\n=== %s ===\n' "$1"; }

section "TOOLING"
# dm-doctor owns the dependency contract; delegate so the list never drifts. A
# missing required tool makes doctor exit non-zero. Capture that verdict rather
# than swallowing it (the old `|| true` always exited 0, hiding a broken
# environment behind a green-looking digest); still render the full digest, then
# surface an explicit NOT READY banner and a non-zero exit at the end.
if "$here/dm-doctor.sh" check; then ready=1; else ready=0; fi

section "MANAGED REPOS"
"$here/dm-repo.sh" list 2>/dev/null || echo "  (none registered)"

if [ "$do_sync" -eq 1 ]; then
  section "CLONE SYNC (fast-forward only; STUCK = needs attention)"
  "$here/dm-sync.sh" all 2>/dev/null || echo "  (sync skipped)"
fi

section "IN-FLIGHT WORK (reconciled state)"
"$here/dm-task.sh" list 2>/dev/null || echo "  (no tasks)"

section "BACKLOG"
if [ -f "$DM_STATE/backlog.md" ]; then "$here/dm-backlog.sh" list; else echo "  ABSENT (no backlog yet)"; fi

for f in operator.md learnings.md; do
  section "$(printf '%s' "$f" | tr '[:lower:].' '[:upper:] ' )"
  if [ -f "$DM_STATE/$f" ]; then cat "$DM_STATE/$f"; else echo "  ABSENT (template defaults; create $DM_STATE/$f when you have content)"; fi
done

section "NEXT"
echo "  Reconcile any STUCK clones and non-pending in-flight tasks before taking new work."
echo "  Load task-lifecycle before dispatching; supervision whenever work is in flight."

# A broken environment must not read as a clean start. Render the whole digest
# first (above), then make the failure the last thing seen and the exit code, so
# both a human and a scripted caller can gate on readiness.
if [ "$ready" -ne 1 ]; then
  printf '\n*** NOT READY: required tooling/auth check FAILED (see TOOLING) — resolve before dispatching work. ***\n'
  exit 1
fi

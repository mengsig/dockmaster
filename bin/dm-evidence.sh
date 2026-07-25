#!/usr/bin/env bash
# dm-evidence.sh - collect what a task's gates saw, as the block dm-pr.sh appends to a PR body.
#
# A reviewer should not have to go find whether a gate ran. Each gate that
# learned something a reviewer would want exposes an `evidence <id>` subcommand
# printing a small block: one bolded line naming the gate and its verdict, plus
# optional detail. This script concatenates whichever blocks exist under one
# heading. It DECIDES NOTHING and RUNS NOTHING: every producer reports only what
# its own gate already recorded, so a verdict here can never differ from the
# gate's.
#
# Producers, in value order:
#   dm-test.sh    which test command ran and its result — or, the case that used
#                 to be invisible, that no test command is registered at all.
#   dm-verify.sh  the e2e verdict, its flows and the code it verified — or that a
#                 user-facing surface moved and nothing verified it.
#
# A producer prints NOTHING when its gate did not run, so a PR whose gates all
# stayed out contributes no section at all. A producer that is missing or fails
# degrades to a stated "evidence unavailable" line: a gate that ran is never
# silently dropped, which is the whole point (checks that appear to run and do
# not are the defect class this exists for).
#
# Commands:
#   block <id>   print the section to append (empty when no gate contributed)
#   strip        read a PR body on stdin, print it with a previously appended
#                section removed, so re-running `open` never stacks blocks

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# The line that introduces an appended section. It renders as nothing on GitHub
# and is the only anchor `strip` needs, so a body can be recomposed idempotently.
EVIDENCE_MARKER='<!-- dm:gate-evidence -->'

# producer_block <label> <script> <id> -- print one producer's block, or the
# stated unavailable line when it cannot be asked. Never fails: the caller is
# composing a PR body, not gating on it.
producer_block() {
  local label="$1" script="$2" id="$3" out rc
  if [ ! -x "$script" ]; then
    printf '**%s** — evidence unavailable · `%s` is missing or not executable\n\n' "$label" "${script##*/}"
    return 0
  fi
  rc=0; out="$("$script" evidence "$id" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '**%s** — evidence unavailable · `%s evidence` exited %s\n\n' "$label" "${script##*/}" "$rc"
    return 0
  fi
  [ -n "$out" ] || return 0
  printf '%s\n\n' "$out"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  block)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-evidence.sh block <id>"
    dm_require_id "$id"
    blocks="$(
      producer_block tests "$BIN_DIR/dm-test.sh" "$id"
      producer_block verify "$BIN_DIR/dm-verify.sh" "$id"
    )"
    [ -n "$blocks" ] || exit 0
    printf -- '---\n%s\n\n### Gate evidence\n\n%s\n' "$EVIDENCE_MARKER" "$blocks"
    ;;

  strip)
    [ "$#" -eq 0 ] || dm_die "usage: dm-evidence.sh strip  (body on stdin)"
    # Buffer so the separator and blank lines that PRECEDE a removed section go
    # with it. Only trim when a marker was actually found: with no section to
    # remove the operator's body comes back as written (bar a final newline).
    awk -v marker="$EVIDENCE_MARKER" '
      $0 == marker { found = 1; exit }
      { lines[++n] = $0 }
      END {
        if (found) { while (n > 0 && (lines[n] == "" || lines[n] == "---")) n-- }
        for (i = 1; i <= n; i++) print lines[i]
      }'
    ;;

  *)
    echo "usage: dm-evidence.sh {block <id>|strip}" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# dm-brief.sh - scaffold a crewmate brief. The brief is the CONTRACT with the
# subagent: isolation, memory, status protocol, and definition of done.
#
# Usage: dm-brief.sh <id>
#   Requires the task to exist (dm-task.sh new ...) with kind/repo/mode set and a
#   worktree created (dm-worktree.sh create ...). Writes data/<id>/brief.md with a
#   {TASK} placeholder the dockmaster MUST replace with the concrete task
#   description, acceptance criteria, constraints, and context before dispatch.
#
#        dm-brief.sh check <id>
#   Refuses when <id> has no brief, or when its {TASK} placeholder is still
#   unfilled — the scaffold called itself a safety contract but nothing enforced
#   it, so a crewmate could be dispatched against an empty task section (#115).
#   Run it before dispatch. (A task literally named `check` still generates with
#   the bare `dm-brief.sh check` form; only `check <id>` selects this mode.)
#
# The scaffold is a safety contract, not a suggestion. Fill {TASK}; do not strip
# the isolation, memory, or status sections.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs

# Where the toolbelt scripts LIVE, which is not necessarily $DM_HOME: DM_HOME is
# overridable and relocates state only, so interpolating $DM_HOME/bin into the
# brief handed every crewmate its status/memory commands under a path that does
# not exist (#116). Follow the running script instead, as the sourcing above does.
bindir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [ "${1:-}" = "check" ] && [ -n "${2:-}" ]; then
  id="$2"
  dm_require_id "$id"
  brief="$DM_DATA/$id/brief.md"
  # Per-arm recovery: regeneration is the fix for a missing/empty brief and the
  # DESTROYER of a partly-filled one (dm-brief.sh <id> rewrites unconditionally).
  if reason="$(dm_brief_unready_reason "$brief")"; then
    case "$reason" in
      missing) dm_die "no brief for $id at $brief; generate it with: dm-brief.sh $id, then replace its {TASK} line" ;;
      empty)   dm_die "brief for $id is empty ($brief) — a write died part-way. Regenerate it: dm-brief.sh $id, then replace its {TASK} line" ;;
      *)       dm_die "brief for $id still has its bare {TASK} line unreplaced ($brief). EDIT that file in place — replace the {TASK} line with the concrete task, acceptance criteria and constraints. Do NOT regenerate: dm-brief.sh $id would overwrite what is already written." ;;
    esac
  fi
  dm_info "$brief"
  exit 0
fi

id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-brief.sh <id> | dm-brief.sh check <id>"
dm_require_id "$id"
kind="$(dm_meta_get "$id" kind)"; repo="$(dm_meta_get "$id" repo)"
mode="$(dm_meta_get "$id" mode)"; wt="$(dm_meta_get "$id" worktree)"
title="$(dm_meta_get "$id" title)"
[ -n "$kind" ] || dm_die "task $id has no kind; run dm-task.sh new first"
[ -n "$wt" ] || dm_die "task $id has no worktree; run dm-worktree.sh create first"

out="$DM_DATA/$id"; mkdir -p "$out"
brief="$out/brief.md"

# Inject the repo's known context (shared AGENTS.md dm:knowledge + private
# notes), byte-capped by dm-memory.sh, so the crewmate has it without a tool
# call. Best-effort on CONTENT (an unregistered repo or empty store must not
# fail brief generation), but recall's STDERR is surfaced, not swallowed: a
# truncated knowledge-block warning must reach the dockmaster, or a crewmate is
# dispatched context-blind. The dockmaster-only store is excluded via --crew.
# The GLOBAL fleet-learnings store is deliberately NOT injected here - see the
# note below, at the call site.
memtool="$(dirname "${BASH_SOURCE[0]}")/dm-memory.sh"

# recall_block <warn-tag> <friendly-empty-line> <recall-args...>  -- run recall,
# re-emit any stderr via dm_warn (to the dockmaster, NOT into the brief), and
# collapse a genuinely-empty result (only section scaffolds) to the friendly line
# instead of injecting empty scaffolds.
recall_block() {
  local warn_tag="$1" empty_line="$2"; shift 2
  local errf res body line
  errf="$(mktemp "$out/.recall.XXXXXX")" || dm_die "mktemp failed generating brief $id"
  res="$("$memtool" recall "$@" 2>"$errf" || true)"
  if [ -s "$errf" ]; then
    while IFS= read -r line; do dm_warn "$warn_tag: $line"; done < "$errf"
  fi
  rm -f "$errf"
  # Emptiness from CONTENT, not the labeled output: strip section headers, the
  # (empty)/(no lines match)/cap-tail markers, and blank lines; if nothing
  # remains, the stores hold no recorded knowledge.
  body="$(grep -v -e '^== ' -e '^  (empty)$' -e '^  (no lines match' -e '^  … ' -e '^[[:space:]]*$' <<<"$res" || true)"
  if [ -n "$body" ]; then printf '%s\n' "$res"; else printf '%s\n' "$empty_line"; fi
}

if [ -n "$repo" ]; then
  mem="$(recall_block "recall($repo)" "(no repository knowledge recorded yet.)" --crew "$repo")"
else
  mem="(no repository knowledge recorded yet.)"
fi
# The global fleet-learnings store is the ORCHESTRATOR's memory, not a
# crewmate's: measured, it was 64% of an average brief's bytes and almost
# entirely irrelevant to the task in front of the worker (isolation rules the
# crew actually needs are baked into the scaffold text below instead). If a
# specific fleet fact bears on this task, the dockmaster pastes it into
# {TASK} - where it is task-relevant instead of fleet-wide noise.

# shared header ----------------------------------------------------------------
{
cat <<EOF
# Task $id ($kind) - repo: $repo

> Sized by the dockmaster: model tier + reasoning effort, judged from this
> brief's clarity and the work's stakes (task-lifecycle has the ladder).

You are a crewmate working one task to completion. You report only to the
dockmaster through short status lines, never to a human. Work only inside your
assigned worktree.

## Working directory (isolation - verify first, stop if wrong)

Your worktree: $wt

Before doing anything else, confirm you are isolated:

    pwd -P
    git rev-parse --show-toplevel

The toplevel MUST equal your worktree path above and MUST NOT be the repo's
primary clone. If it is not, do nothing else - append a blocked status and stop:

    $bindir/dm-task.sh event $id blocked "not in isolated worktree"

Isolation also covers shared HOST resources - a prior crewmate's bare
\`docker compose\` derived its project name from cwd, which was the operator's
live production stack, and took it down:

- every \`docker compose\` call carries an explicit \`-p <project-unique-to-this-task>\`
  AND an explicit \`-f <absolute path inside your worktree>\` - never bare
  \`docker compose\` relying on cwd.
- never bind a host port you were not explicitly handed.
- kill only PIDs you yourself captured - never \`pkill\`/\`killall\` by name, which
  reaches sibling sessions' processes.

## Memory (per-repo, plain markdown - no bespoke tool)

What this repo already knows that bears on your task is injected below. SHARED
knowledge lives as committed per-note files in this repo's \`.dm-knowledge/\`
directory (so it travels to every clone and worktree; the notes are assembled
into the section below). PRIVATE notes (the \`private notes\`
section) are dockmaster orchestration context relayed to you for your awareness
ONLY: use them to inform your work, but never copy or paraphrase them into
commits, PR descriptions, code comments, or the repo's \`AGENTS.md\` — they must
not enter the project's history. Read it all before you start.

$mem

When you learn something durable, non-obvious, and repo-specific, record it:
- A SHARED, contributor-relevant fact (a build/test command, an invariant, a
  pitfall, a convention, a routing hint) → record it IN YOUR WORKTREE with
  \`$bindir/dm-memory.sh remember $id --shared --kind <kind> "<fact>"\` (writes
  a \`- **[<kind>]** <fact>\` bullet to \`.dm-knowledge/$id.md\`), then \`git add\` and
  commit that file with your change. One file per task, so concurrent work never
  collides; to supersede a fact, edit the note file that holds it.
- A private/orchestration fact → \`$bindir/dm-memory.sh remember $repo --private --kind <kind> "<fact>"\`.

Do not store secrets, transient failures, task status, or code excerpts.

## The task

${title:+Recorded title: $title

}{TASK}

EOF

# kind/mode-specific body ------------------------------------------------------
if [ "$kind" = "scout" ]; then
cat <<EOF
## Definition of done (scout)

You investigate, reproduce, plan, or audit. You do NOT change project code and
you do NOT open a PR. Diagnosis is evidence, not authorization to implement.

Produce a self-contained report at:

    $out/report.md

Do NOT use the Write tool for this file - a report-shaped .md (report/summary/
findings/analysis) is exactly what a worker is told not to write, so the write
may be refused. This report is the deliverable and the exception. Write it with
a shell heredoc, which is never ambiguous:

    cat > $out/report.md <<'REPORT'
    ...report body...
    REPORT

The report states: what you were asked, what you found (observed facts vs
hypotheses, kept separate), the evidence, and any recommendation. If you
uncover a genuine decision that only the operator can make, name it explicitly
in the report so it is not lost.

When the report is written, signal done:

    $bindir/dm-task.sh event $id done "report at data/$id/report.md"
EOF
else
  # ship
  branch_hint="Create a branch with a name of the form <type>/<issue>/<slug>. Compute it with:
    $bindir/dm-branch-name.sh <type> <issue-or-x> \"<short summary>\"
  types: feat fix bug chore refactor docs perf test build ci"
cat <<EOF
## Definition of done (ship, mode: $mode)

$branch_hint

Implement the change and commit it on your branch. Keep commits focused. Do not
add any agent name as a co-author and do not add "generated by" / "written by an
agent" text anywhere - not in commits, not in the PR.

Leave the worktree clean before you signal: \`git add\` any intended new files,
and remove build/test artifacts you generated (e.g. __pycache__, coverage
output) that the repo does not already ignore. Uncommitted tracked changes and
stray untracked files will block landing.

## Review artifact (lavish) - required before delivery

When the change is implemented and committed, render it as a review page for the
operator. Write a self-contained HTML page to:

    $DM_DATA/$id/lavish/change.html

(get this path with \`$bindir/dm-lavish.sh path $id\`). Show, at a glance:
what changed and why, the meaningful diff, before/after where it helps, and the
risk. Then signal:

    $bindir/dm-task.sh event $id review-ready "lavish artifact ready"

The operator reviews it. If the dockmaster relays feedback, revise BOTH the code
and the page, then signal \`review-ready\` again. Repeat until approved.

After approval the dockmaster decides with the operator how the change lands (a
PR, or local) and steers you from there: for a PR it drives the review/fix/test
gates - apply fixes on this same branch when asked; for local it lands your
branch. Do NOT push or open a PR yourself unless the dockmaster tells you to.
EOF
fi

# coding standards (baked verbatim from the coding-guidelines skill so every
# crewmate carries them in its prompt, with no dependency on skill loading) -----
cg_skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.claude/skills/coding-guidelines/SKILL.md"
if [ -f "$cg_skill" ]; then
  printf '\n## Coding standards - follow these whenever you write or change code\n\n'
  awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {f=0; next} !f' "$cg_skill"
else
  # The coding standards are a safety contract baked into every brief. If the
  # skill file is missing or renamed, warn loudly (to stderr, not the brief) so
  # the dropped standard is visible rather than silently omitted.
  dm_warn "coding-guidelines skill not found at $cg_skill; brief $id omits the baked-in coding standards"
fi

# status protocol (shared) -----------------------------------------------------
cat <<EOF

## Status protocol

Append a status line only at meaningful, supervisor-actionable transitions -
not routine progress. Use:

    $bindir/dm-task.sh event $id <state> "<one line>"

States: working (starting), review-ready (lavish artifact ready for the operator
to review - the main ship signal), ready / done (see above), blocked (you need
the dockmaster to act - name exactly what), needs-decision (an operator choice
is required - name the options), failed (you could not complete it - say why),
paused (a bounded external wait you expect to clear on its own).

Never bypass a refusal from any dm-* script; a refusal means stop and report.
EOF
} > "$brief"

dm_info "$brief"

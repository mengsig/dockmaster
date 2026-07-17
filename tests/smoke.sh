#!/usr/bin/env bash
# tests/smoke.sh - end-to-end regression smoke test for the manhandler toolbelt.
#
# Exercises the full local-only lifecycle plus the backlog and test gate in a
# throwaway MH_HOME, asserting behavior at each step. No network, no GitHub.
# Run: tests/smoke.sh   (exit 0 = all passed)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MH_HOME="$TMP/home"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- fixtures ----------------------------------------------------------------
git init -q --bare -b main "$TMP/origin.git"
git init -q -b main "$TMP/seed"
( cd "$TMP/seed"; git config user.email t@t.co; git config user.name t
  mkdir src; printf 'def add(a,b):\n    return a+b\n' > src/calc.py
  git add .; git commit -qm init; git remote add origin "$TMP/origin.git"; git push -q origin main ) >/dev/null 2>&1

cd "$ROOT"
b() { "$ROOT/bin/$@"; }

echo "== registry =="
b mh-repo.sh add demo "$TMP/origin.git" --mode local-only --test-cmd "test -f src/calc.py" >/dev/null 2>&1
check "repo registered" '[ "$(b mh-repo.sh get demo mode)" = "local-only" ]'
check "clone present"    '[ -d "$MH_HOME/repos/demo/.git" ]'

echo "== doctor =="
# Capture once, match with a here-string: piping to `grep -q` would let grep
# close the pipe on first match and SIGPIPE the script, which pipefail reports
# as failure. Capturing avoids that flake.
DOC="$(b mh-doctor.sh check)"
check "doctor check passes (git+jq present)" 'b mh-doctor.sh check >/dev/null'
check "doctor reports git ok"                'grep -qE "ok +git" <<<"$DOC"'
check "doctor scaffolds home"                'b mh-doctor.sh >/dev/null && [ -d "$MH_HOME/state/tasks" ] && [ -d "$MH_HOME/state/worktrees" ] && [ -f "$MH_HOME/state/repos.json" ]'

echo "== create (new repo from an empty remote) =="
git init -q --bare -b main "$TMP/new.git"   # an empty remote the operator "made"
b mh-repo.sh create fresh "$TMP/new.git" --mode local-only --test-cmd "true" --no-memory >/dev/null
check "create registers repo"        '[ "$(b mh-repo.sh get fresh mode)" = "local-only" ]'
check "create initializes clone"     '[ -d "$MH_HOME/repos/fresh/.git" ]'
check "create sets origin upstream"  '[ "$(git -C "$MH_HOME/repos/fresh" remote get-url origin)" = "$TMP/new.git" ]'
check "create publishes first commit" 'git -C "$TMP/new.git" log --oneline -1 2>/dev/null | grep -q "initialize repository"'
check "create yields a workable base" 'b mh-worktree.sh create fresh-wt fresh >/dev/null 2>&1'
check "create refuses populated remote" '! b mh-repo.sh create taken "$TMP/origin.git" --no-memory >/dev/null 2>&1'

echo "== task + worktree + brief =="
b mh-task.sh new demo-1 --kind ship --repo demo --title "add multiply" >/dev/null
WT="$(b mh-worktree.sh create demo-1 demo | tail -n1)"
check "worktree created"        '[ -d "$WT" ]'
check "isolation asserts"       'b mh-worktree.sh assert "$WT" demo >/dev/null'
b mh-brief.sh demo-1 >/dev/null
check "brief bakes commandments" 'grep -q "The Ten Commandments" "$MH_HOME/data/demo-1/brief.md"'
check "brief has review-ready"    'grep -q "review-ready" "$MH_HOME/data/demo-1/brief.md"'
check "brief labels the private-notes boundary" 'grep -q "never copy or paraphrase them" "$MH_HOME/data/demo-1/brief.md"'

echo "== status (read-only view) =="
STATUS="$(b mh-status.sh)"   # capture once (see doctor note on grep -q + pipefail)
check "status runs"                'b mh-status.sh >/dev/null'
check "status shows managed repo"  'grep -q demo <<<"$STATUS"'
check "status shows in-flight task" 'grep -q demo-1 <<<"$STATUS"'
check "status shows task age"       'grep -E "age.*demo-1" <<<"$STATUS" >/dev/null'

echo "== fast pipeline config =="
FAST="$ROOT/config/pr-pipeline.fast.json"
check "fast pipeline config exists"       '[ -f "$FAST" ]'
check "fast pipeline is valid JSON"       'jq -e . "$FAST" >/dev/null'
check "fast pipeline has one review pass" '[ "$(jq "[.gates[]|select(.gate==\"review\")]|length" "$FAST")" = "1" ]'
check "fast pipeline keeps tests gate"    '[ "$(jq "[.gates[]|select(.gate==\"tests\")]|length" "$FAST")" -ge 1 ]'
check "fast pipeline ends in pr gate"     '[ "$(jq -r ".gates[-1].gate" "$FAST")" = "pr" ]'

echo "== rigorous pipeline config =="
RIG="$ROOT/config/pr-pipeline.rigorous.json"
check "rigorous pipeline config exists"        '[ -f "$RIG" ]'
check "rigorous pipeline is valid JSON"        'jq -e . "$RIG" >/dev/null'
# The rigorous tier's signature is the dimension-parallel review followed by the
# adversarial verify-findings gate; assert both the shape and the gate order.
check "rigorous review is dimension-parallel"  '[ "$(jq "[.gates[]|select(.gate==\"review\")][0].dimensions|length" "$RIG")" -ge 1 ]'
check "rigorous verify-findings has voters"    '[ "$(jq "[.gates[]|select(.gate==\"verify-findings\")][0].voters" "$RIG")" -ge 1 ]'
check "rigorous starts review then verify-findings" '[ "$(jq -r ".gates[0].gate" "$RIG")" = "review" ] && [ "$(jq -r ".gates[1].gate" "$RIG")" = "verify-findings" ]'
check "rigorous ends in pr gate"               '[ "$(jq -r ".gates[-1].gate" "$RIG")" = "pr" ]'
# The three shipped tiers must share the same top-level shape (a consistent gate
# schema is what lets one runner drive any of them).
check "all three tiers share the top-level shape" 'for f in default fast rigorous; do [ "$(jq -r "has(\"version\") and has(\"description\") and has(\"gates\")" "$ROOT/config/pr-pipeline.$f.json")" = "true" ] || exit 1; done'

echo "== lavish degradation (optional tool absent) =="
# Simulate lavish-axi being absent: a PATH of symlinks to only the real tools
# mh-lavish needs, deliberately excluding lavish-axi. This works whether or not
# lavish-axi happens to be installed on the machine running the test.
NB="$TMP/nolavish"; mkdir -p "$NB"
for t in bash env dirname basename mkdir date sed awk jq git cat mv rm mktemp; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NB/$t"
done
lav() { PATH="$NB" "$ROOT/bin/mh-lavish.sh" "$@"; }
check "lavish-axi absent from probe PATH"   '! PATH="$NB" command -v lavish-axi'
check "lavish open fails on missing artifact (tool absent)" '! lav open demo-1 >/dev/null 2>&1'
ART="$(b mh-lavish.sh path demo-1)"
printf '<!doctype html><title>x</title>\n' > "$ART"
check "lavish open degrades (exit 0, tool absent)" 'lav open demo-1 >/dev/null 2>&1'
check "lavish poll degrades (exit 0, tool absent)" 'lav poll demo-1 >/dev/null 2>&1'
OPENOUT="$(lav open demo-1 2>&1)"
check "lavish open names the artifact path"        'grep -qF "$ART" <<<"$OPENOUT"'

echo "== state reconciliation =="
check "state pending pre-work" 'b mh-task.sh state demo-1 | grep -q pending'
git -C "$WT" checkout -q -b feat/x/add-multiply
printf 'def multiply(a,b):\n    return a*b\n' >> "$WT/src/calc.py"
git -C "$WT" -c user.email=c@c.co -c user.name=c commit -qam "add multiply" >/dev/null
check "state working post-commit" 'b mh-task.sh state demo-1 | grep -q working'
# MH_NO_FETCH (used by mh-status) must reconcile from local refs only and still
# report the committed-but-unlanded case correctly.
check "no-fetch landed: reports unlanded" '! MH_NO_FETCH=1 b mh-worktree.sh landed demo-1 >/dev/null 2>&1'

echo "== state reconcile: 'merged:' in a note must not fake done (anchored verb) =="
b mh-task.sh new fix1 --kind ship --repo demo >/dev/null
b mh-task.sh event fix1 note "waiting on upstream PR merged: #123" >/dev/null
check "note text 'merged:' does not reconcile to done" '! b mh-task.sh state fix1 | grep -q done'
b mh-task.sh event fix1 merged "landed via local ff" >/dev/null
check "a real merge event reconciles to done"          'b mh-task.sh state fix1 | grep -q done'

echo "== test gate =="
check "tests pass (registered cmd)" 'b mh-test.sh demo-1 >/dev/null'
check "tests recorded pass"         '[ "$(b mh-task.sh get demo-1 tests)" = "pass" ]'

echo "== backlog (dependency completion from real task state) =="
b mh-backlog.sh add demo-1 "add multiply" --repo demo --status inflight >/dev/null
b mh-backlog.sh add demo-2 "docs" --status queued --blocked-by demo-1 >/dev/null
check "ready hides blocked item"  '! b mh-backlog.sh ready | grep -q demo-2'
# demo-1 is a real task, committed but NOT yet landed (state: working). Marking
# it done in the backlog is a lie `ready` must not believe: it consults real
# task state, so demo-2 stays blocked despite the hand-set done.
b mh-backlog.sh done demo-1 --note "claimed landed" >/dev/null
check "ready ignores hand-set done until the task has landed" '! b mh-backlog.sh ready | grep -q demo-2'
# A blocker id with NO task record falls back to its hand-set backlog status.
b mh-backlog.sh add blk-untracked "no task record" --status done >/dev/null
b mh-backlog.sh add dep-untracked "needs blk-untracked" --status queued --blocked-by blk-untracked >/dev/null
check "ready falls back to backlog status without a task record" 'b mh-backlog.sh ready | grep -q dep-untracked'
b mh-backlog.sh hold demo-1-decision-scope "ship v1 or v2?" --options "v1 | v2" >/dev/null
check "hold is open"     'b mh-backlog.sh list | grep -q "demo-1-decision-scope"'
b mh-backlog.sh resolve demo-1-decision-scope "v1" >/dev/null
check "hold resolved"    'b mh-backlog.sh list | grep -A2 "demo-1-decision-scope" | grep -q "answer: v1"'

echo "== mh dispatcher (additive convenience entrypoint) =="
MH="$ROOT/bin/mh"
HELP="$("$MH" help)"   # capture once (see doctor note on grep -q + pipefail)
check "mh help lists subcommands"     'grep -q "^  task " <<<"$HELP" && grep -q "^  backlog " <<<"$HELP" && grep -q "^  pr " <<<"$HELP"'
check "mh help omits the sourced lib" '! grep -q "^  lib " <<<"$HELP"'
check "mh (no args) prints usage"     '"$MH" >/dev/null'
check "mh dispatches to target script" '[ "$("$MH" task list)" = "$(b mh-task.sh list)" ]'
check "mh passes through exit codes"   '"$MH" task >/dev/null 2>&1; [ "$?" -eq 2 ]'
check "mh rejects unknown subcommand"  '! "$MH" definitely-not-a-cmd >/dev/null 2>&1'
check "mh rejects the sourced lib"     '! "$MH" lib >/dev/null 2>&1'

echo "== security-scan (advisory gate hint; local-only, no GitHub tools) =="
# A diff touching a security surface must be flagged (exit 0 + named signals);
# the silent-skip failure mode is exactly what this guards against.
b mh-task.sh new sec-scan --kind ship --repo demo >/dev/null
WTS="$(b mh-worktree.sh create sec-scan demo | tail -n1)"
git -C "$WTS" checkout -q -b feat/x/sec
printf 'def login(password):\n    return authenticate(password)\n' > "$WTS/src/auth.py"
git -C "$WTS" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$WTS" -c user.email=c@c.co -c user.name=c commit -qm "add auth" >/dev/null
SCANOUT="$(b mh-pr.sh security-scan sec-scan 2>&1 || true)"   # capture once (grep -q + pipefail)
check "security-scan flags a security-surface diff" 'b mh-pr.sh security-scan sec-scan >/dev/null 2>&1'
check "security-scan names the signals"             'grep -qi "signals present" <<<"$SCANOUT"'
# demo-1's diff is a pure arithmetic helper: no security surface -> exit non-zero.
check "security-scan clears a benign diff"          '! b mh-pr.sh security-scan demo-1 >/dev/null 2>&1'
check "security-scan requires an id"                '! b mh-pr.sh security-scan >/dev/null 2>&1'
b mh-worktree.sh remove sec-scan --force >/dev/null 2>&1
# `open` on a local-only task must refuse (its path is mh-merge.sh local). The
# guard fires before any GitHub tool or push, so it is exercisable offline.
b mh-task.sh new pr-localonly --kind ship --repo demo --mode local-only >/dev/null
check "pr open refuses a local-only task" '! b mh-pr.sh open pr-localonly --title x >/dev/null 2>&1'
PRLO="$(b mh-pr.sh open pr-localonly --title x 2>&1 || true)"
check "pr open names the local-only path" 'grep -q "local-only" <<<"$PRLO"'

echo "== status drift lint (three-source reconciliation) =="
# demo-1 is marked done in the backlog above, but its work is committed and not
# yet landed (state reconciles to working) — a real three-source disagreement.
DRIFT="$(b mh-status.sh)"
check "drift flags backlog-done vs task-not-done" 'grep -q "DRIFT.*demo-1" <<<"$DRIFT"'
# an artifact dir with no task record is an orphan (parallel to worktree ORPHAN)
mkdir -p "$MH_HOME/data/orphan-xyz"; : > "$MH_HOME/data/orphan-xyz/leftover"
DRIFT2="$(b mh-status.sh)"
check "status flags orphan data dir" 'grep -q "ORPHAN-DATA.*orphan-xyz" <<<"$DRIFT2"'
rm -rf "$MH_HOME/data/orphan-xyz"

echo "== status: decision event without a hold is flagged =="
b mh-task.sh new needdec --kind scout --repo demo >/dev/null
b mh-task.sh event needdec needs-decision "ship option a or b?" >/dev/null
NODEC="$(b mh-status.sh)"
check "status flags missing decision hold" 'grep -q "NO-HOLD.*needdec" <<<"$NODEC"'
b mh-backlog.sh hold needdec-decision-opt "ship option a or b?" --options "a | b" --origin data/needdec/report.md >/dev/null
NODEC2="$(b mh-status.sh)"
check "an open hold clears the missing-hold flag" '! grep -q "NO-HOLD.*needdec" <<<"$NODEC2"'

echo "== status tolerates a non-integer stuck-age (fix 6) =="
check "non-integer MH_STUCK_AGE_HOURS does not crash status" 'MH_STUCK_AGE_HOURS=4.5 b mh-status.sh >/dev/null 2>&1'

echo "== meta parsing (fixed-string keys; metachar/= values) =="
b mh-task.sh set metatest re '.*[x]^$ +(a|b)' >/dev/null
check "meta round-trips regex metachars" '[ "$(b mh-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
b mh-task.sh set metatest eq 'k=v=x' >/dev/null
check "meta round-trips value with ="   '[ "$(b mh-task.sh get metatest eq)" = "k=v=x" ]'
check "meta update leaves sibling key"   '[ "$(b mh-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
# KEY-side regression: the old sed/grep treated the key as a regex, so "a.c"
# also matched "abc". awk matches the key as a fixed string. Set abc first, then
# a.c: the old grep -v "^a.c=" would drop the abc line too (. matches b).
b mh-task.sh set keytest abc WRONG >/dev/null
b mh-task.sh set keytest a.c RIGHT >/dev/null
check "meta get matches key literally"    '[ "$(b mh-task.sh get keytest a.c)" = "RIGHT" ]'
check "meta set does not clobber sibling" '[ "$(b mh-task.sh get keytest abc)" = "WRONG" ]'

echo "== concurrent meta writes (locking; no lost update) =="
b mh-task.sh new conc --kind ship --repo demo >/dev/null
for i in $(seq 1 20); do b mh-task.sh set conc "k$i" "v$i" & done
wait
missing=0
for i in $(seq 1 20); do [ "$(b mh-task.sh get conc "k$i")" = "v$i" ] || missing=$((missing+1)); done
check "all 20 concurrent keys survived" '[ "$missing" -eq 0 ]'

echo "== gitignore =="
check "gitignore ignores settings.local.json" 'git -C "$ROOT" check-ignore .claude/settings.local.json >/dev/null'

echo "== guarded land + teardown =="
check "local land ff"    'b mh-merge.sh local demo-1 >/dev/null'
check "no-fetch landed: reports landed" 'MH_NO_FETCH=1 b mh-worktree.sh landed demo-1 >/dev/null 2>&1'
check "state done"       'b mh-task.sh state demo-1 | grep -q done'
# demo-1's task state is now `done` (landed above). Even with the backlog moved
# back to inflight (NOT done), `ready` unblocks demo-2 from the reconciled task
# state — the "landed but never marked done" case the old status-only check missed.
b mh-backlog.sh move demo-1 inflight >/dev/null
check "ready unblocks from real task state, not backlog status" 'b mh-backlog.sh ready | grep -q demo-2'
check "teardown ok"      'b mh-worktree.sh remove demo-1 >/dev/null'
check "origin has commit" 'git -C "$MH_HOME/repos/demo" log --oneline | grep -q "add multiply"'

echo "== archive (prune a landed, torn-down task) =="
# fail closed: a task that has not reached terminal done cannot be archived.
b mh-task.sh new arch-wip --kind ship --repo demo >/dev/null
check "archive refuses a non-done task"       '! b mh-task.sh archive arch-wip >/dev/null 2>&1'
check "refused task keeps its meta"           '[ -f "$MH_HOME/state/tasks/arch-wip.meta" ]'
# demo-1 landed and was torn down above (state done, no worktree) -> archivable.
check "archive moves a done task's records"   'b mh-task.sh archive demo-1 >/dev/null'
check "archived meta leaves tasks/"           '[ ! -f "$MH_HOME/state/tasks/demo-1.meta" ]'
check "archived meta under archive/"          '[ -f "$MH_HOME/state/archive/demo-1.meta" ]'
check "archived status under archive/"        '[ -f "$MH_HOME/state/archive/demo-1.status" ]'
check "archived data dir under archive/"      '[ -d "$MH_HOME/state/archive/demo-1" ]'
check "archived data dir left data/"          '[ ! -d "$MH_HOME/data/demo-1" ]'

echo "== fail-closed guards =="
b mh-task.sh new demo-3 --kind ship --repo demo >/dev/null
WT3="$(b mh-worktree.sh create demo-3 demo | tail -n1)"
git -C "$WT3" checkout -q -b feat/x/wip
printf 'x\n' > "$WT3/stray.txt"   # untracked
check "teardown refuses untracked" '! b mh-worktree.sh remove demo-3 >/dev/null 2>&1'
b mh-worktree.sh remove demo-3 --force >/dev/null 2>&1
SYNC="$(b mh-sync.sh all)"   # capture once (see doctor note on grep -q + pipefail)
check "sync reports OK"   'grep -q "OK:" <<<"$SYNC"'

echo "== toolbelt input guards =="
# mh-repo.sh set: whitelist + default_branch validation. 'main' is a real branch
# in the clone; a bogus ref and an unknown field must both be refused.
check "set default_branch to a real branch works" 'b mh-repo.sh set demo default_branch main >/dev/null 2>&1'
check "set default_branch to a bogus ref refused"  '! b mh-repo.sh set demo default_branch no-such-branch >/dev/null 2>&1'
check "set unknown field refused"                  '! b mh-repo.sh set demo not_a_field x >/dev/null 2>&1'
# mh-worktree.sh remove: flag order must not matter (`--force` before the id).
b mh-task.sh new demo-4 --kind ship --repo demo >/dev/null
WT4="$(b mh-worktree.sh create demo-4 demo | tail -n1)"
git -C "$WT4" checkout -q -b feat/x/wip4
check "remove parses '--force <id>' regardless of order" 'b mh-worktree.sh remove --force demo-4 >/dev/null 2>&1'
# mh-doctor.sh validates state JSON: corrupt repos.json, expect a named failure.
cp "$MH_HOME/state/repos.json" "$TMP/repos.bak"
printf 'not json{' > "$MH_HOME/state/repos.json"
DOCBAD="$(b mh-doctor.sh 2>&1 || true)"
check "doctor fails on invalid repos.json" '! b mh-doctor.sh >/dev/null 2>&1'
check "doctor names the invalid JSON"      'grep -q "not valid JSON" <<<"$DOCBAD"'
cp "$TMP/repos.bak" "$MH_HOME/state/repos.json"

echo "== branch name =="
# Pure function (no MH_HOME): type/issue validation, slug kebab-collapsing, cap.
check "branch name maps issue+slug"        '[ "$(b mh-branch-name.sh fix 412 "flaky login test")" = "fix/412/flaky-login-test" ]'
check "branch name accepts x issue"        '[ "$(b mh-branch-name.sh feat x "foo")" = "feat/x/foo" ]'
check "branch name kebab-collapses slug"   '[ "$(b mh-branch-name.sh feat x "Dark   MODE!! toggle")" = "feat/x/dark-mode-toggle" ]'
check "branch name rejects bad type"       '! b mh-branch-name.sh bogus x "foo" >/dev/null 2>&1'
check "branch name rejects non-numeric issue" '! b mh-branch-name.sh feat abc "foo" >/dev/null 2>&1'
BN="$(b mh-branch-name.sh chore x "this is an extremely long summary that should be truncated well beyond the forty eight character cap")"
check "branch name caps slug at 48"        '[ "$(printf "%s" "${BN#chore/x/}" | wc -c | tr -d " ")" -le 48 ]'
check "branch name drops trailing hyphen"  'case "$BN" in *-) false;; *) true;; esac'

echo "== backlog move =="
b mh-backlog.sh add mv-1 "movable item" --status queued >/dev/null
check "queued item shows in ready"         'b mh-backlog.sh ready | grep -q mv-1'
b mh-backlog.sh move mv-1 inflight >/dev/null
check "moved-to-inflight leaves ready"     '! b mh-backlog.sh ready | grep -q mv-1'
b mh-backlog.sh move mv-1 queued >/dev/null
check "moved-back-to-queued rejoins ready" 'b mh-backlog.sh ready | grep -q mv-1'
check "move rejects invalid status"        '! b mh-backlog.sh move mv-1 bogus >/dev/null 2>&1'
check "move rejects unknown id"            '! b mh-backlog.sh move no-such queued >/dev/null 2>&1'

echo "== worktree tangle detection =="
check "tangle: clean clone on default is untangled" 'b mh-worktree.sh tangle demo >/dev/null 2>&1'
git -C "$MH_HOME/repos/demo" checkout -q -b sidebranch
check "tangle: detects non-default branch"  '! b mh-worktree.sh tangle demo >/dev/null 2>&1'
TANGLE="$(b mh-worktree.sh tangle demo 2>&1 || true)"
check "tangle: message names the branch"    'grep -q "TANGLE.*sidebranch" <<<"$TANGLE"'
git -C "$MH_HOME/repos/demo" checkout -q main
git -C "$MH_HOME/repos/demo" branch -q -D sidebranch
check "tangle: clears after return to default" 'b mh-worktree.sh tangle demo >/dev/null 2>&1'

echo "== scout lifecycle =="
b mh-task.sh new sc-1 --kind scout --repo demo >/dev/null
b mh-worktree.sh create sc-1 demo >/dev/null
b mh-brief.sh sc-1 >/dev/null
check "scout state pending before report"   'b mh-task.sh state sc-1 | grep -q pending'
check "scout brief is scout-flavored"       'grep -q "Definition of done (scout)" "$MH_HOME/data/sc-1/brief.md"'
check "scout brief names the report path"   'grep -q "data/sc-1/report.md" "$MH_HOME/data/sc-1/brief.md"'
check "scout brief omits the ship branch flow" '! grep -q "Create a branch" "$MH_HOME/data/sc-1/brief.md"'
printf '# findings\n' > "$MH_HOME/data/sc-1/report.md"
check "scout state done once report exists"  'b mh-task.sh state sc-1 | grep -q done'

echo "== repo remove guards =="
b mh-repo.sh add rmtest "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
printf 'dirty\n' > "$MH_HOME/repos/rmtest/DIRTY.txt"   # uncommitted change in the clone
check "remove refuses dirty clone"           '! b mh-repo.sh remove rmtest >/dev/null 2>&1'
rm -f "$MH_HOME/repos/rmtest/DIRTY.txt"
b mh-task.sh new rmscout --kind scout --repo rmtest >/dev/null   # non-terminal referencing task
check "remove refuses repo with a live task" '! b mh-repo.sh remove rmtest >/dev/null 2>&1'
check "remove keeps registry entry on refusal" '[ "$(b mh-repo.sh get rmtest mode)" = "local-only" ]'
mkdir -p "$MH_HOME/data/rmscout"; printf '# report\n' > "$MH_HOME/data/rmscout/report.md"   # task now terminal (done)
check "remove proceeds once referencing task is done" 'b mh-repo.sh remove rmtest >/dev/null 2>&1'
check "removed repo is unregistered"         '! b mh-repo.sh get rmtest >/dev/null 2>&1'
# A live extra worktree off the clone must block removal (the guard counts
# worktrees in one shot so a SIGPIPE'd `grep -q` cannot silently skip it). Use
# raw `git worktree add` so no task meta is created — this isolates the
# worktree guard from the live-task guard exercised above.
b mh-repo.sh add wtguard "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$MH_HOME/repos/wtguard" worktree add -q --detach "$TMP/wtguard-extra" >/dev/null 2>&1
check "remove refuses repo with a live worktree" '! b mh-repo.sh remove wtguard >/dev/null 2>&1'
WTGUARD="$(b mh-repo.sh remove wtguard 2>&1 || true)"
check "remove names the active-worktree reason"  'grep -q "active worktrees" <<<"$WTGUARD"'
git -C "$MH_HOME/repos/wtguard" worktree remove "$TMP/wtguard-extra" >/dev/null 2>&1
check "remove proceeds after the worktree is torn down" 'b mh-repo.sh remove wtguard >/dev/null 2>&1'

echo "== merge rebase (offline) =="
# Clean rebase: worktree branch adds a new file, primary main advances with an
# unrelated file -> rebase replays cleanly and picks up the base change.
b mh-task.sh new rb-clean --kind ship --repo demo --mode local-only >/dev/null
RBWT="$(b mh-worktree.sh create rb-clean demo | tail -n1)"
git -C "$RBWT" checkout -q -b feat/x/rb-clean
printf 'clean\n' > "$RBWT/rb_clean.txt"
git -C "$RBWT" -c user.email=c@c.co -c user.name=c add rb_clean.txt >/dev/null
git -C "$RBWT" -c user.email=c@c.co -c user.name=c commit -qm "rb clean feature"
git -C "$MH_HOME/repos/demo" checkout -q main
printf 'base\n' > "$MH_HOME/repos/demo/rb_base.txt"
git -C "$MH_HOME/repos/demo" -c user.email=c@c.co -c user.name=c add rb_base.txt >/dev/null
git -C "$MH_HOME/repos/demo" -c user.email=c@c.co -c user.name=c commit -qm "advance main unrelated"
check "rebase clean succeeds"                'b mh-merge.sh rebase rb-clean >/dev/null 2>&1'
check "rebase clean picks up base + keeps feature" '[ -f "$RBWT/rb_base.txt" ] && [ -f "$RBWT/rb_clean.txt" ]'
check "rebase clean stays on its branch"     '[ "$(git -C "$RBWT" rev-parse --abbrev-ref HEAD)" = "feat/x/rb-clean" ]'
check "rebase clean leaves no in-progress rebase" '! [ -d "$(git -C "$RBWT" rev-parse --git-path rebase-merge)" ] && ! [ -d "$(git -C "$RBWT" rev-parse --git-path rebase-apply)" ]'
# Conflicting rebase: worktree branch and primary main edit the same file -> the
# rebase must report CONFLICT, exit 3, abort, and leave the worktree restored.
b mh-task.sh new rb-conf --kind ship --repo demo --mode local-only >/dev/null
CFWT="$(b mh-worktree.sh create rb-conf demo | tail -n1)"
git -C "$CFWT" checkout -q -b feat/x/rb-conf
printf 'branch change\n' > "$CFWT/src/calc.py"
git -C "$CFWT" -c user.email=c@c.co -c user.name=c commit -qam "branch edits calc"
git -C "$MH_HOME/repos/demo" checkout -q main
printf 'main change\n' > "$MH_HOME/repos/demo/src/calc.py"
git -C "$MH_HOME/repos/demo" -c user.email=c@c.co -c user.name=c commit -qam "main edits calc"
CF_HEAD_BEFORE="$(git -C "$CFWT" rev-parse HEAD)"
if b mh-merge.sh rebase rb-conf >/dev/null 2>&1; then RBRC=0; else RBRC=$?; fi
check "rebase conflict exits 3"              '[ "$RBRC" -eq 3 ]'
check "rebase conflict restores worktree HEAD" '[ "$(git -C "$CFWT" rev-parse HEAD)" = "$CF_HEAD_BEFORE" ]'
check "rebase conflict stays on its branch"  '[ "$(git -C "$CFWT" rev-parse --abbrev-ref HEAD)" = "feat/x/rb-conf" ]'
check "rebase conflict leaves no in-progress rebase" '! [ -d "$(git -C "$CFWT" rev-parse --git-path rebase-merge)" ] && ! [ -d "$(git -C "$CFWT" rev-parse --git-path rebase-apply)" ]'
CFOUT="$(b mh-merge.sh rebase rb-conf 2>&1 || true)"
check "rebase conflict reports CONFLICT"     'grep -q "CONFLICT" <<<"$CFOUT"'
git -C "$MH_HOME/repos/demo" checkout -q main   # leave the demo clone on default for later sections

echo "== mh-memory (native plain-markdown context) =="
# seed scaffolds only the git-excluded private store; it never touches the clone's
# AGENTS.md, so the clone stays pristine (landable and fast-forward-syncable).
b mh-memory.sh seed demo >/dev/null
check "seed creates the private notes store"          '[ -f "$MH_HOME/repos/demo/.mh/notes.md" ]'
check "seed git-excludes the private store"           'grep -qxF ".mh/" "$MH_HOME/repos/demo/.git/info/exclude"'
check "seed leaves the clone pristine"                '[ -z "$(git -C "$MH_HOME/repos/demo" status --porcelain)" ]'
check "seed is idempotent"                            'b mh-memory.sh seed demo >/dev/null 2>&1'
# SHARED knowledge is authored by a crewmate in a worktree and committed; simulate
# a committed mh:knowledge section and assert recall surfaces + filters it.
printf '# demo\n\n<!-- mh:knowledge:start -->\n## Repository knowledge\n- **[command]** run tests with pytest -q\n<!-- mh:knowledge:end -->\n' > "$MH_HOME/repos/demo/AGENTS.md"
b mh-memory.sh remember demo --private --kind routing "prefer squash merges here" >/dev/null
check "remember --private appends the fact"           'grep -q "squash merges" "$MH_HOME/repos/demo/.mh/notes.md"'
b mh-memory.sh remember --global --kind pitfall "fleet gotcha alpha" >/dev/null
check "remember --global appends to learnings"        'grep -q "fleet gotcha alpha" "$MH_HOME/state/learnings.md"'
RECALL="$(b mh-memory.sh recall demo)"          # capture once (grep -q + pipefail)
check "recall shows shared knowledge"                 'grep -q "pytest -q" <<<"$RECALL"'
check "recall shows private knowledge"                'grep -q "squash merges" <<<"$RECALL"'
RQ="$(b mh-memory.sh recall demo pytest)"
check "recall query keeps the matching line"          'grep -q "pytest -q" <<<"$RQ"'
check "recall query drops non-matching lines"         '! grep -q "squash merges" <<<"$RQ"'
GRECALL="$(b mh-memory.sh recall --global)"
check "recall --global shows fleet learnings"         'grep -q "fleet gotcha alpha" <<<"$GRECALL"'
check "multi-line fact is rejected"     '! b mh-memory.sh remember demo --private --kind command "$(printf "a\nb")" >/dev/null 2>&1'
check "invalid kind is rejected"        '! b mh-memory.sh remember demo --private --kind bogus "x" >/dev/null 2>&1'
check "shared append via tool is refused" '! b mh-memory.sh remember demo --kind command "x" >/dev/null 2>&1'
check "unregistered repo is rejected"   '! b mh-memory.sh seed nope >/dev/null 2>&1'

echo "== mh-memory: recall query is a literal substring, not a regex (fix 4) =="
# 'p.test' matches 'pytest' as a regex but not as a literal string; grep -F must
# treat the query literally, so the pytest line is NOT returned.
RXQ="$(b mh-memory.sh recall demo 'p.test')"
check "recall treats a regex-metachar query literally" '! grep -q "pytest" <<<"$RXQ"'
LITQ="$(b mh-memory.sh recall demo 'pytest -q')"
check "recall matches a literal substring query"       'grep -q "pytest -q" <<<"$LITQ"'

echo "== mh-memory: -- ends flag parsing so a fact can start with a dash (fix 3) =="
b mh-memory.sh remember demo --private --kind command -- "-Wall enables all warnings" >/dev/null
check "-- lets a fact begin with a dash"  'grep -q -- "-Wall enables all warnings" "$MH_HOME/repos/demo/.mh/notes.md"'
check "usage documents the -- terminator" 'b mh-memory.sh --help | grep -q -- "-- to end flag parsing"'

echo "== mh-memory: a start marker with no end must not leak the file tail (fix 1) =="
# A truncated/mis-edited AGENTS.md (start marker, no matching end) must yield an
# empty shared block and a stderr warning — never the file's whole tail.
cp "$MH_HOME/repos/demo/AGENTS.md" "$TMP/agents.bak"
printf '# demo\n\n<!-- mh:knowledge:start -->\n- **[command]** buffered fact\nSECRET_TAIL_LEAK\n' > "$MH_HOME/repos/demo/AGENTS.md"
NOEND="$(b mh-memory.sh recall demo 2>/dev/null)"
check "recall omits an unclosed knowledge block" '! grep -q "buffered fact" <<<"$NOEND"'
check "recall does not leak the file tail"        '! grep -q "SECRET_TAIL_LEAK" <<<"$NOEND"'
NOEND_ERR="$(b mh-memory.sh recall demo 2>&1 >/dev/null)"
check "recall warns about the missing end marker" 'grep -q "without a matching end" <<<"$NOEND_ERR"'
cp "$TMP/agents.bak" "$MH_HOME/repos/demo/AGENTS.md"

echo "== mh-memory: concurrent first private writes don't truncate each other (fix 2) =="
# No notes store yet: fire concurrent first `remember --private` calls. The header
# is created under the lock, so they cannot erase each other (mirrors the
# concurrent-meta-writes test).
b mh-repo.sh add memconc "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
check "memconc starts with no private notes store" '[ ! -f "$MH_HOME/repos/memconc/.mh/notes.md" ]'
for i in $(seq 1 15); do b mh-memory.sh remember memconc --private --kind routing "concfact$i" & done
wait
cmiss=0
for i in $(seq 1 15); do grep -q "concfact$i" "$MH_HOME/repos/memconc/.mh/notes.md" || cmiss=$((cmiss+1)); done
check "all 15 concurrent private facts survived" '[ "$cmiss" -eq 0 ]'
check "exactly one private-notes header"         '[ "$(grep -c "manhandler private notes" "$MH_HOME/repos/memconc/.mh/notes.md")" -eq 1 ]'

# === toolbelt-debt tests (#23) ===
echo "== toolbelt debt: backlog write via delegated bwrite =="
# bwrite now delegates to mh_json_update; the full add/list/close cycle must still
# work (the read-modify-write behaves identically through the shared owner).
b mh-backlog.sh add td-1 "delegated write" --status queued >/dev/null
check "backlog add persists via delegated bwrite" 'b mh-backlog.sh list | grep -q "delegated write"'
check "queued item shows in ready (delegated)"    'b mh-backlog.sh ready | grep -q td-1'
b mh-backlog.sh done td-1 --note "closed" >/dev/null
check "backlog close persists via delegated bwrite" 'b mh-backlog.sh list | grep -A2 "td-1" | grep -q "note: closed"'
check "closed item drops out of ready (delegated)"  '! b mh-backlog.sh ready | grep -q td-1'

echo "== toolbelt debt: create yields the requested initial branch (portable init) =="
# Portable git init (no `-b`): the initial branch must be exactly the requested
# one on a clean init. Use an empty bare local remote (offline).
git init -q --bare -b main "$TMP/tb-init.git"
b mh-repo.sh create tbinit "$TMP/tb-init.git" --mode local-only --branch trunk --test-cmd "true" --no-memory >/dev/null
check "create registers with requested branch" '[ "$(b mh-repo.sh get tbinit default_branch)" = "trunk" ]'
check "clone HEAD is the requested branch"      '[ "$(git -C "$MH_HOME/repos/tbinit" rev-parse --abbrev-ref HEAD)" = "trunk" ]'
check "requested branch exists in the clone"    'git -C "$MH_HOME/repos/tbinit" rev-parse --verify --quiet refs/heads/trunk >/dev/null'

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

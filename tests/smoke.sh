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

echo "== status (read-only view) =="
STATUS="$(b mh-status.sh)"   # capture once (see doctor note on grep -q + pipefail)
check "status runs"                'b mh-status.sh >/dev/null'
check "status shows managed repo"  'grep -q demo <<<"$STATUS"'
check "status shows in-flight task" 'grep -q demo-1 <<<"$STATUS"'

echo "== state reconciliation =="
check "state pending pre-work" 'b mh-task.sh state demo-1 | grep -q pending'
git -C "$WT" checkout -q -b feat/x/add-multiply
printf 'def multiply(a,b):\n    return a*b\n' >> "$WT/src/calc.py"
git -C "$WT" -c user.email=c@c.co -c user.name=c commit -qam "add multiply" >/dev/null
check "state working post-commit" 'b mh-task.sh state demo-1 | grep -q working'
# MH_NO_FETCH (used by mh-status) must reconcile from local refs only and still
# report the committed-but-unlanded case correctly.
check "no-fetch landed: reports unlanded" '! MH_NO_FETCH=1 b mh-worktree.sh landed demo-1 >/dev/null 2>&1'

echo "== test gate =="
check "tests pass (registered cmd)" 'b mh-test.sh demo-1 >/dev/null'
check "tests recorded pass"         '[ "$(b mh-task.sh get demo-1 tests)" = "pass" ]'

echo "== backlog =="
b mh-backlog.sh add demo-1 "add multiply" --repo demo --status inflight >/dev/null
b mh-backlog.sh add demo-2 "docs" --status queued --blocked-by demo-1 >/dev/null
check "ready hides blocked item"  '! b mh-backlog.sh ready | grep -q demo-2'
b mh-backlog.sh done demo-1 --note landed >/dev/null
check "ready shows unblocked item" 'b mh-backlog.sh ready | grep -q demo-2'
b mh-backlog.sh hold demo-1-decision-scope "ship v1 or v2?" --options "v1 | v2" >/dev/null
check "hold is open"     'b mh-backlog.sh list | grep -q "demo-1-decision-scope"'
b mh-backlog.sh resolve demo-1-decision-scope "v1" >/dev/null
check "hold resolved"    'b mh-backlog.sh list | grep -A2 "demo-1-decision-scope" | grep -q "answer: v1"'

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
check "teardown ok"      'b mh-worktree.sh remove demo-1 >/dev/null'
check "origin has commit" 'git -C "$MH_HOME/repos/demo" log --oneline | grep -q "add multiply"'

echo "== fail-closed guards =="
b mh-task.sh new demo-3 --kind ship --repo demo >/dev/null
WT3="$(b mh-worktree.sh create demo-3 demo | tail -n1)"
git -C "$WT3" checkout -q -b feat/x/wip
printf 'x\n' > "$WT3/stray.txt"   # untracked
check "teardown refuses untracked" '! b mh-worktree.sh remove demo-3 >/dev/null 2>&1'
b mh-worktree.sh remove demo-3 --force >/dev/null 2>&1
SYNC="$(b mh-sync.sh all)"   # capture once (see doctor note on grep -q + pipefail)
check "sync reports OK"   'grep -q "OK:" <<<"$SYNC"'

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

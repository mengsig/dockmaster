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

echo "== guarded land + teardown =="
check "local land ff"    'b mh-merge.sh local demo-1 >/dev/null'
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
check "sync reports OK"   'b mh-sync.sh all | grep -q "OK:"'

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

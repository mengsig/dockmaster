#!/usr/bin/env bash
# tests/smoke.sh - end-to-end regression smoke test for the dockmaster toolbelt.
#
# Exercises the full local-only lifecycle plus the backlog and test gate in a
# throwaway DM_HOME, asserting behavior at each step. No network, no GitHub.
# Run: tests/smoke.sh   (exit 0 = all passed)

set -euo pipefail

# Hermetic git identity: the toolbelt shells out to `git commit`, which needs
# an author identity. A fresh machine/CI runner has no global user.name/email
# configured, so export throwaway values git honors for commits rather than
# depending on (or mutating) the caller's global git config.
export GIT_AUTHOR_NAME="dockmaster smoke" GIT_AUTHOR_EMAIL="smoke@dockmaster.test"
export GIT_COMMITTER_NAME="dockmaster smoke" GIT_COMMITTER_EMAIL="smoke@dockmaster.test"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DM_HOME="$TMP/home"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Hermetic authenticated runtime snapshot. Production doctor still probes real
# auth; smoke must not inherit developer login state or hosted-CI anonymity.
RUNTIME_OK="$TMP/runtime-ok"
mkdir -p "$RUNTIME_OK"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNTIME_OK/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNTIME_OK/codex"
chmod +x "$RUNTIME_OK/claude" "$RUNTIME_OK/codex"
export PATH="$RUNTIME_OK:$PATH"

# --- fixtures ----------------------------------------------------------------
git init -q --bare -b main "$TMP/origin.git"
git init -q -b main "$TMP/seed"
( cd "$TMP/seed"; git config user.email t@t.co; git config user.name t
  mkdir src; printf 'def add(a,b):\n    return a+b\n' > src/calc.py
  git add .; git commit -qm init; git remote add origin "$TMP/origin.git"; git push -q origin main ) >/dev/null 2>&1

cd "$ROOT"
b() { "$ROOT/bin/$@"; }

echo "== Codex thread identity + command guard =="
THREAD_A="$(b dm-thread-name.sh fix-login-412 worker)"
THREAD_B="$(b dm-thread-name.sh fix.login-412 worker)"
THREAD_C="$(b dm-thread-name.sh fix_login_412 worker)"
LONG_THREAD="$(b dm-thread-name.sh task-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-12345 review_waiter)"
ROLE_THREAD="$(b dm-thread-name.sh fix-login-412 verify)"
MAX_ID="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
MAX_THREAD="$(b dm-thread-name.sh "$MAX_ID" secondmate)"
check "thread name is stable" '[ "$THREAD_A" = "$(b dm-thread-name.sh fix-login-412 worker)" ]'
check "thread name matches Codex grammar" 'grep -Eq "^[a-z0-9_]{1,64}$" <<<"$THREAD_A"'
check "normalized collisions retain distinct identities" '[ "$THREAD_A" != "$THREAD_B" ] && [ "$THREAD_A" != "$THREAD_C" ] && [ "$THREAD_B" != "$THREAD_C" ]'
check "role participates in identity" '[ "$THREAD_A" != "$ROLE_THREAD" ]'
check "long and max-length ids stay bounded" '[ "${#LONG_THREAD}" -le 64 ] && [ "${#MAX_THREAD}" -le 64 ]'
check "invalid durable id and role are rejected separately" '! b dm-thread-name.sh "bad id" worker >/dev/null 2>&1 && ! b dm-thread-name.sh valid-id "bad-role" >/dev/null 2>&1'
check "guard blocks git -C reset flag permutation" '! b dm-command-guard.sh check "git -C /tmp reset HEAD --hard" >/dev/null 2>&1'
check "guard blocks absolute git clean flag permutation" '! b dm-command-guard.sh check "/usr/bin/git --no-pager -C /tmp clean -d -f" >/dev/null 2>&1'
check "guard blocks non-hard reset and dry-run clean bypasses" '! b dm-command-guard.sh check "/usr/bin/git -C /tmp reset --merge HEAD" >/dev/null 2>&1 && ! b dm-command-guard.sh check "/usr/bin/git -C /tmp clean -n" >/dev/null 2>&1'
check "guard blocks restore and destructive switch" '! b dm-command-guard.sh check "git restore file" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git switch --discard-changes main" >/dev/null 2>&1'
check "guard blocks checkout and combined switch flags" '! b dm-command-guard.sh check "git checkout feature" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git switch -fq main" >/dev/null 2>&1'
check "guard blocks quoted spaced-path destructive Git" '! b dm-command-guard.sh check "git -C \"/tmp/path with spaces\" reset --hard" >/dev/null 2>&1'
check "guard blocks nested, indirect, and alias destructive Git" '! b dm-command-guard.sh check "bash -c \"git clean -fd\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env bash -c \"git reset --hard\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "\$GIT restore file" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git -c alias.nuke=\"!git reset --hard\" nuke" >/dev/null 2>&1'
check "guard blocks dynamic Git executable and subcommands" '! b dm-command-guard.sh check "op=reset; git \"\$op\" --hard" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git \"\$(printf reset)\" --hard" >/dev/null 2>&1 && ! b dm-command-guard.sh check "\$(printf git) reset --hard" >/dev/null 2>&1'
ESCAPED_RESET=$'git re\\\nset --hard'
check "guard blocks escaped-newline destructive Git" '! b dm-command-guard.sh check "$ESCAPED_RESET" >/dev/null 2>&1'
check "guard blocks shell-fed and alternate-shell destructive content" '! b dm-command-guard.sh check "printf \"git reset --hard\" | bash" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env dash -c \"git restore file\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "bash <<< \"git clean -fd\"" >/dev/null 2>&1'
check "guard permits read-only Git" 'b dm-command-guard.sh check "git -C /tmp status" >/dev/null'
check "guard permits quoted spaced-path read-only Git" 'b dm-command-guard.sh check "git -C \"/tmp/path with spaces\" status" >/dev/null'
check "guard ignores harmless Git words in argv text" 'b dm-command-guard.sh check "echo git reset --hard" >/dev/null && b dm-command-guard.sh check "printf %s \"git restore file\"" >/dev/null && b dm-command-guard.sh check "bash -c \"echo git clean -fd\"" >/dev/null'

echo "== secondmate durable identity state =="
SECOND_THREAD="$(b dm-thread-name.sh payments secondmate)"
b dm-secondmate.sh prepare payments --scope "payments services" --repos "demo,fresh" --thread-name "$SECOND_THREAD"
check "prepared secondmate is visibly ambiguous until attach" 'b dm-secondmate.sh reconcile | grep -q "AMBIGUOUS-LAUNCH.*payments"'
b dm-secondmate.sh attach payments agent-123
check "secondmate attach persists exact owner" '[ "$(b dm-secondmate.sh get payments | jq -r .agent_id)" = agent-123 ] && b dm-secondmate.sh reconcile | grep -q "VERIFY-LIVE.*agent-123"'
check "secondmate clear refuses wrong owner" '! b dm-secondmate.sh clear payments agent-wrong stopped >/dev/null 2>&1'
b dm-secondmate.sh clear payments agent-123 stopped
check "secondmate clear records dormant state" '[ "$(b dm-secondmate.sh get payments | jq -r .status)" = dormant ]'
b dm-secondmate.sh retire payments --confirmed-idle
check "secondmate retirement is durable" '[ "$(b dm-secondmate.sh get payments | jq -r .status)" = retired ]'
for i in 1 2 3 4 5; do
  thread="$(b dm-thread-name.sh "domain-$i" secondmate)"
  b dm-secondmate.sh prepare "domain-$i" --scope "scope $i" --repos demo --thread-name "$thread" &
done
wait
check "concurrent secondmate writes remain valid and complete" 'jq -e ".secondmates | length == 6" "$DM_HOME/state/secondmates.json" >/dev/null'
check "secondmate prepare rejects another record's active thread name" \
  '! b dm-secondmate.sh prepare domain-dup --scope duplicate --repos demo --thread-name "$(b dm-thread-name.sh domain-3 secondmate)" >/dev/null 2>&1'
check "prepare refuses to overwrite an ambiguous launch" '! b dm-secondmate.sh prepare domain-1 --scope overwritten --repos demo --thread-name "$(b dm-thread-name.sh domain-1 secondmate)" >/dev/null 2>&1'
b dm-secondmate.sh abandon domain-1 --confirmed-no-live
check "confirmed no-live launch can be abandoned" '[ "$(b dm-secondmate.sh get domain-1 | jq -r .status)" = dormant ]'
(b dm-secondmate.sh attach domain-2 agent-a >/dev/null 2>&1 || true) &
(b dm-secondmate.sh attach domain-2 agent-b >/dev/null 2>&1 || true) &
wait
check "concurrent attach records exactly one runtime owner" 'OWNER="$(b dm-secondmate.sh get domain-2 | jq -r .agent_id)"; [ "$OWNER" = agent-a ] || [ "$OWNER" = agent-b ]'
OWNER="$(b dm-secondmate.sh get domain-2 | jq -r .agent_id)"
check "secondmate attach rejects another record's agent id" '! b dm-secondmate.sh attach domain-3 "$OWNER" >/dev/null 2>&1'
(b dm-secondmate.sh attach domain-3 agent-shared >/dev/null 2>&1 || true) &
(b dm-secondmate.sh attach domain-4 agent-shared >/dev/null 2>&1 || true) &
wait
SHARED_AGENT_COUNT="$(jq '[.secondmates[].agent_id | select(. == "agent-shared")] | length' "$DM_HOME/state/secondmates.json")"
check "concurrent cross-record attach preserves unique agent ids" '[ "$SHARED_AGENT_COUNT" = 1 ]'

echo "== registry =="
b dm-repo.sh add demo "$TMP/origin.git" --mode local-only --test-cmd "test -f src/calc.py" >/dev/null 2>&1
check "repo registered" '[ "$(b dm-repo.sh get demo mode)" = "local-only" ]'
check "clone present"    '[ -d "$DM_HOME/repos/demo/.git" ]'

echo "== doctor =="
# Capture once, match with a here-string: piping to `grep -q` would let grep
# close the pipe on first match and SIGPIPE the script, which pipefail reports
# as failure. Capturing avoids that flake.
DOC="$(b dm-doctor.sh check)"
check "doctor check passes (git+jq present)" 'b dm-doctor.sh check >/dev/null'
check "doctor reports git ok"                'grep -qE "ok +git" <<<"$DOC"'
check "doctor scaffolds home"                'b dm-doctor.sh >/dev/null && [ -d "$DM_HOME/state/tasks" ] && [ -d "$DM_HOME/state/worktrees" ] && [ -f "$DM_HOME/state/repos.json" ]'
RUNTIME_BAD="$TMP/runtime-bad"
mkdir -p "$RUNTIME_BAD"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNTIME_BAD/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RUNTIME_BAD/codex"
chmod +x "$RUNTIME_BAD/claude" "$RUNTIME_BAD/codex"
check "doctor requires only selected Claude runtime" 'PATH="$RUNTIME_BAD:$PATH" b dm-doctor.sh check --runtime claude >/dev/null'
check "doctor fails selected unavailable Codex runtime" '! PATH="$RUNTIME_BAD:$PATH" b dm-doctor.sh check --runtime codex >/dev/null 2>&1'
CLEAN_DOCTOR_HOME="$TMP/clean-doctor-home"
check "doctor passes CI-like environment only through explicit authenticated stub" \
  'env -i HOME="$HOME" DM_HOME="$CLEAN_DOCTOR_HOME" PATH="$RUNTIME_OK:$PATH" "$ROOT/bin/dm-doctor.sh" check --runtime codex >/dev/null'
STATEFUL_RUNTIME="$TMP/runtime-stateful"
STATEFUL_COUNT="$TMP/runtime-stateful-count"
mkdir -p "$STATEFUL_RUNTIME"
printf '%s\n' '#!/usr/bin/env bash' 'n=0; [ ! -f "$STATEFUL_COUNT" ] || n="$(cat "$STATEFUL_COUNT")"' 'n=$((n + 1)); printf "%s\n" "$n" > "$STATEFUL_COUNT"' '[ "$n" -eq 1 ]' > "$STATEFUL_RUNTIME/codex"
chmod +x "$STATEFUL_RUNTIME/codex"
STATEFUL_OUT="$(STATEFUL_COUNT="$STATEFUL_COUNT" PATH="$STATEFUL_RUNTIME:$PATH" b dm-doctor.sh check --runtime codex)"
check "doctor probes selected runtime exactly once" '[ "$(cat "$STATEFUL_COUNT")" = 1 ]'
check "doctor reports and exits from the same immutable snapshot" 'grep -qE "ok +codex-runtime" <<<"$STATEFUL_OUT" && ! grep -q "MISSING.*codex-runtime" <<<"$STATEFUL_OUT"'

echo "== create (new repo from an empty remote) =="
git init -q --bare -b main "$TMP/new.git"   # an empty remote the operator "made"
b dm-repo.sh create fresh "$TMP/new.git" --mode local-only --test-cmd "true" --no-memory >/dev/null
check "create registers repo"        '[ "$(b dm-repo.sh get fresh mode)" = "local-only" ]'
check "create initializes clone"     '[ -d "$DM_HOME/repos/fresh/.git" ]'
check "create sets origin upstream"  '[ "$(git -C "$DM_HOME/repos/fresh" remote get-url origin)" = "$TMP/new.git" ]'
check "create publishes first commit" 'OUT="$(git -C "$TMP/new.git" log --oneline -1 2>/dev/null)"; grep -q "initialize repository" <<<"$OUT"'
# A worktree needs a task record with a kind first (dm-worktree.sh create fails
# closed without one, so `state` can always classify the task).
b dm-task.sh new fresh-wt --kind ship --repo fresh >/dev/null
check "create yields a workable base" 'b dm-worktree.sh create fresh-wt fresh >/dev/null 2>&1'
check "create refuses populated remote" '! b dm-repo.sh create taken "$TMP/origin.git" --no-memory >/dev/null 2>&1'

echo "== task + worktree + brief =="
b dm-task.sh new demo-1 --kind ship --repo demo --title "add multiply" >/dev/null
WT="$(b dm-worktree.sh create demo-1 demo | tail -n1)"
check "worktree created"        '[ -d "$WT" ]'
check "isolation asserts"       'b dm-worktree.sh assert "$WT" demo >/dev/null'
b dm-brief.sh demo-1 >/dev/null
check "brief bakes commandments" 'grep -q "The Ten Commandments" "$DM_HOME/data/demo-1/brief.md"'
check "brief has review-ready"    'grep -q "review-ready" "$DM_HOME/data/demo-1/brief.md"'
check "brief labels the private-notes boundary" 'grep -q "never copy or paraphrase them" "$DM_HOME/data/demo-1/brief.md"'

echo "== status (read-only view) =="
STATUS="$(b dm-status.sh)"   # capture once (see doctor note on grep -q + pipefail)
check "status runs"                'b dm-status.sh >/dev/null'
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
# dm-lavish needs, deliberately excluding lavish-axi. This works whether or not
# lavish-axi happens to be installed on the machine running the test.
NB="$TMP/nolavish"; mkdir -p "$NB"
for t in bash env dirname basename mkdir date sed awk jq git cat mv rm mktemp; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NB/$t"
done
lav() { PATH="$NB" "$ROOT/bin/dm-lavish.sh" "$@"; }
check "lavish-axi absent from probe PATH"   '! PATH="$NB" command -v lavish-axi'
check "lavish open fails on missing artifact (tool absent)" '! lav open demo-1 >/dev/null 2>&1'
ART="$(b dm-lavish.sh path demo-1)"
printf '<!doctype html><title>x</title>\n' > "$ART"
check "lavish open degrades (exit 0, tool absent)" 'lav open demo-1 >/dev/null 2>&1'
check "lavish poll degrades (exit 0, tool absent)" 'lav poll demo-1 >/dev/null 2>&1'
OPENOUT="$(lav open demo-1 2>&1)"
check "lavish open names the artifact path"        'grep -qF "$ART" <<<"$OPENOUT"'

echo "== state reconciliation =="
check "state pending pre-work" 'OUT="$(b dm-task.sh state demo-1)"; grep -q pending <<<"$OUT"'
git -C "$WT" checkout -q -b feat/x/add-multiply
printf 'def multiply(a,b):\n    return a*b\n' >> "$WT/src/calc.py"
git -C "$WT" -c user.email=c@c.co -c user.name=c commit -qam "add multiply" >/dev/null
check "state working post-commit" 'OUT="$(b dm-task.sh state demo-1)"; grep -q working <<<"$OUT"'
# DM_NO_FETCH (used by dm-status) must reconcile from local refs only and still
# report the committed-but-unlanded case correctly.
check "no-fetch landed: reports unlanded" '! DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 >/dev/null 2>&1'

echo "== state reconcile: 'merged:' in a note must not fake done (anchored verb) =="
b dm-task.sh new fix1 --kind ship --repo demo >/dev/null
b dm-task.sh event fix1 note "waiting on upstream PR merged: #123" >/dev/null
check "note text 'merged:' does not reconcile to done" 'OUT="$(b dm-task.sh state fix1)"; ! grep -q done <<<"$OUT"'
# The sanctioned landing paths (dm-merge/dm-pr) append the 'merged' event
# directly via the status-append helper; `dm-task.sh event` can no longer forge
# it (see the state-gate-integrity block at the end). Simulate the sanctioned
# append through the same helper those paths use.
( . "$ROOT/bin/dm-lib.sh"; dm_status_append fix1 merged "landed via local ff" ) >/dev/null
check "a real merge event reconciles to done"          'OUT="$(b dm-task.sh state fix1)"; grep -q done <<<"$OUT"'

echo "== test gate =="
check "tests pass (registered cmd)" 'b dm-test.sh demo-1 >/dev/null'
check "tests recorded pass"         '[ "$(b dm-task.sh get demo-1 tests)" = "pass" ]'

echo "== backlog (dependency completion from real task state) =="
b dm-backlog.sh add demo-1 "add multiply" --repo demo --status inflight >/dev/null
b dm-backlog.sh add demo-2 "docs" --status queued --blocked-by demo-1 >/dev/null
check "ready hides blocked item"  'OUT="$(b dm-backlog.sh ready)"; ! grep -q demo-2 <<<"$OUT"'
# demo-1 is a real task, committed but NOT yet landed (state: working). Marking
# it done in the backlog is a lie `ready` must not believe: it consults real
# task state, so demo-2 stays blocked despite the hand-set done.
b dm-backlog.sh done demo-1 --note "claimed landed" >/dev/null
check "ready ignores hand-set done until the task has landed" 'OUT="$(b dm-backlog.sh ready)"; ! grep -q demo-2 <<<"$OUT"'
# A blocker id with NO task record falls back to its hand-set backlog status.
b dm-backlog.sh add blk-untracked "no task record" --status done >/dev/null
b dm-backlog.sh add dep-untracked "needs blk-untracked" --status queued --blocked-by blk-untracked >/dev/null
check "ready falls back to backlog status without a task record" 'OUT="$(b dm-backlog.sh ready)"; grep -q dep-untracked <<<"$OUT"'
b dm-backlog.sh hold demo-1-decision-scope "ship v1 or v2?" --options "v1 | v2" >/dev/null
check "hold is open"     'OUT="$(b dm-backlog.sh list)"; grep -q "demo-1-decision-scope" <<<"$OUT"'
b dm-backlog.sh resolve demo-1-decision-scope "v1" >/dev/null
check "hold resolved"    'OUT="$(b dm-backlog.sh list)"; CTX="$(grep -A2 "demo-1-decision-scope" <<<"$OUT")"; grep -q "answer: v1" <<<"$CTX"'

echo "== dm dispatcher (additive convenience entrypoint) =="
DM="$ROOT/bin/dm"
HELP="$("$DM" help)"   # capture once (see doctor note on grep -q + pipefail)
check "dm help lists subcommands"     'grep -q "^  task " <<<"$HELP" && grep -q "^  backlog " <<<"$HELP" && grep -q "^  pr " <<<"$HELP"'
check "dm help omits the sourced lib" '! grep -q "^  lib " <<<"$HELP"'
check "dm (no args) prints usage"     '"$DM" >/dev/null'
check "dm dispatches to target script" '[ "$("$DM" task list)" = "$(b dm-task.sh list)" ]'
check "dm passes through exit codes"   '"$DM" task >/dev/null 2>&1; [ "$?" -eq 2 ]'
check "dm rejects unknown subcommand"  '! "$DM" definitely-not-a-cmd >/dev/null 2>&1'
check "dm rejects the sourced lib"     '! "$DM" lib >/dev/null 2>&1'

echo "== security-scan (advisory gate hint; local-only, no GitHub tools) =="
# A diff touching a security surface must be flagged (exit 0 + named signals);
# the silent-skip failure mode is exactly what this guards against.
b dm-task.sh new sec-scan --kind ship --repo demo >/dev/null
WTS="$(b dm-worktree.sh create sec-scan demo | tail -n1)"
git -C "$WTS" checkout -q -b feat/x/sec
printf 'def login(password):\n    return authenticate(password)\n' > "$WTS/src/auth.py"
git -C "$WTS" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$WTS" -c user.email=c@c.co -c user.name=c commit -qm "add auth" >/dev/null
SCANOUT="$(b dm-pr.sh security-scan sec-scan 2>&1 || true)"   # capture once (grep -q + pipefail)
check "security-scan flags a security-surface diff" 'b dm-pr.sh security-scan sec-scan >/dev/null 2>&1'
check "security-scan names the signals"             'grep -qi "signals present" <<<"$SCANOUT"'
# demo-1's diff is a pure arithmetic helper: no security surface -> exit non-zero.
check "security-scan clears a benign diff"          '! b dm-pr.sh security-scan demo-1 >/dev/null 2>&1'
check "security-scan requires an id"                '! b dm-pr.sh security-scan >/dev/null 2>&1'
b dm-worktree.sh remove sec-scan --force >/dev/null 2>&1
# `open` on a local-only task must refuse (its path is dm-merge.sh local). The
# guard fires before any GitHub tool or push, so it is exercisable offline.
b dm-task.sh new pr-localonly --kind ship --repo demo --mode local-only >/dev/null
check "pr open refuses a local-only task" '! b dm-pr.sh open pr-localonly --title x >/dev/null 2>&1'
PRLO="$(b dm-pr.sh open pr-localonly --title x 2>&1 || true)"
check "pr open names the local-only path" 'grep -q "local-only" <<<"$PRLO"'
PR_OPEN_STUB="$TMP/pr-open-stub"
mkdir -p "$PR_OPEN_STUB"
printf '#!/bin/sh\n: > "%s/invoked"\nexit 1\n' "$PR_OPEN_STUB" > "$PR_OPEN_STUB/gh-axi"
chmod +x "$PR_OPEN_STUB/gh-axi"
b dm-task.sh new pr-untracked --kind ship --repo demo --mode pipeline >/dev/null
PR_UNTRACKED_WT="$(b dm-worktree.sh create pr-untracked demo | tail -n1)"
git -C "$PR_UNTRACKED_WT" checkout -q -b feat/x/pr-untracked
printf 'not committed\n' > "$PR_UNTRACKED_WT/untracked.txt"
PR_UNTRACKED_OUT="$(PATH="$PR_OPEN_STUB:$PATH" b dm-pr.sh open pr-untracked --title x 2>&1 || true)"
check "pr open refuses untracked files before push" 'grep -q "untracked files" <<<"$PR_UNTRACKED_OUT" && [ ! -f "$PR_OPEN_STUB/invoked" ]'
b dm-worktree.sh remove pr-untracked --force >/dev/null 2>&1

echo "== status drift lint (three-source reconciliation) =="
# demo-1 is marked done in the backlog above, but its work is committed and not
# yet landed (state reconciles to working) — a real three-source disagreement.
DRIFT="$(b dm-status.sh)"
check "drift flags backlog-done vs task-not-done" 'grep -q "DRIFT.*demo-1" <<<"$DRIFT"'
# an artifact dir with no task record is an orphan (parallel to worktree ORPHAN)
mkdir -p "$DM_HOME/data/orphan-xyz"; : > "$DM_HOME/data/orphan-xyz/leftover"
DRIFT2="$(b dm-status.sh)"
check "status flags orphan data dir" 'grep -q "ORPHAN-DATA.*orphan-xyz" <<<"$DRIFT2"'
rm -rf "$DM_HOME/data/orphan-xyz"

echo "== status: decision event without a hold is flagged =="
b dm-task.sh new needdec --kind scout --repo demo >/dev/null
b dm-task.sh event needdec needs-decision "ship option a or b?" >/dev/null
NODEC="$(b dm-status.sh)"
check "status flags missing decision hold" 'grep -q "NO-HOLD.*needdec" <<<"$NODEC"'
b dm-backlog.sh hold needdec-decision-opt "ship option a or b?" --options "a | b" --origin data/needdec/report.md >/dev/null
NODEC2="$(b dm-status.sh)"
check "an open hold clears the missing-hold flag" '! grep -q "NO-HOLD.*needdec" <<<"$NODEC2"'

echo "== needs-decision is its own reconciled state, distinct from blocked =="
# A needs-decision event must surface as its own token, not collapse into
# 'blocked' — decision-hold/supervision key off the exact string to gate
# teardown on a durable hold, and dm-status's UNTRACKED DECISIONS arm for
# needs-decision would otherwise be dead code.
check "state reconciles needs-decision, not blocked" \
  '[ "$(b dm-task.sh state needdec | sed "s/ · .*//; s/^state: //")" = "needs-decision" ]'
b dm-task.sh new blkonly --kind scout --repo demo >/dev/null
b dm-task.sh event blkonly blocked "waiting on ci creds" >/dev/null
check "a plain blocked event still reconciles to blocked" \
  '[ "$(b dm-task.sh state blkonly | sed "s/ · .*//; s/^state: //")" = "blocked" ]'
check "status attention count includes a needs-decision task" \
  'OUT="$(b dm-status.sh)"; grep -qE "ATTENTION.*needs-decision" <<<"$OUT"'

echo "== status tolerates a non-integer stuck-age (fix 6) =="
check "non-integer DM_STUCK_AGE_HOURS does not crash status" 'DM_STUCK_AGE_HOURS=4.5 b dm-status.sh >/dev/null 2>&1'

echo "== meta parsing (fixed-string keys; metachar/= values) =="
b dm-task.sh set metatest re '.*[x]^$ +(a|b)' >/dev/null
check "meta round-trips regex metachars" '[ "$(b dm-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
b dm-task.sh set metatest eq 'k=v=x' >/dev/null
check "meta round-trips value with ="   '[ "$(b dm-task.sh get metatest eq)" = "k=v=x" ]'
check "meta update leaves sibling key"   '[ "$(b dm-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
# KEY-side regression: the old sed/grep treated the key as a regex, so "a.c"
# also matched "abc". awk matches the key as a fixed string. Set abc first, then
# a.c: the old grep -v "^a.c=" would drop the abc line too (. matches b).
b dm-task.sh set keytest abc WRONG >/dev/null
b dm-task.sh set keytest a.c RIGHT >/dev/null
check "meta get matches key literally"    '[ "$(b dm-task.sh get keytest a.c)" = "RIGHT" ]'
check "meta set does not clobber sibling" '[ "$(b dm-task.sh get keytest abc)" = "WRONG" ]'
check "meta owner rejects an equals-bearing key" '! b dm-task.sh set metatest "safe=pr_state" forged >/dev/null 2>&1'
check "meta owner rejects a newline-bearing key" '! b dm-task.sh set metatest $'"'"'safe\npr_state'"'"' MERGED >/dev/null 2>&1'
check "meta owner rejects a newline-bearing value" '! b dm-task.sh set metatest safe $'"'"'ok\npr_state=MERGED'"'"' >/dev/null 2>&1'
check "meta owner rejects a carriage-return value" '! b dm-task.sh set metatest safe $'"'"'ok\rpr_state=MERGED'"'"' >/dev/null 2>&1'
check "invalid meta input cannot forge a reserved field" '[ -z "$(b dm-task.sh get metatest pr_state)" ]'

echo "== read-path id validation (get/state reject a path-escaping id) =="
# get/state used to pass a raw <id> straight into dm_meta_path with no
# dm_require_id, unlike every write path (set/event/new/archive), which could
# let a crafted id (e.g. containing ../) read a *.meta file outside
# state/tasks/. Plant a decoy one directory above DM_TASKS and confirm a
# traversal id is refused rather than reading it.
: > "$DM_HOME/state/secret.meta"
check "get refuses a path-escaping id"   '! b dm-task.sh get "../secret" >/dev/null 2>&1'
check "state refuses a path-escaping id" '! b dm-task.sh state "../secret" >/dev/null 2>&1'
rm -f "$DM_HOME/state/secret.meta"

echo "== concurrent meta writes (locking; no lost update) =="
b dm-task.sh new conc --kind ship --repo demo >/dev/null
for i in $(seq 1 20); do b dm-task.sh set conc "k$i" "v$i" & done
wait
missing=0
for i in $(seq 1 20); do [ "$(b dm-task.sh get conc "k$i")" = "v$i" ] || missing=$((missing+1)); done
check "all 20 concurrent keys survived" '[ "$missing" -eq 0 ]'

echo "== gitignore =="
check "gitignore ignores settings.local.json" 'git -C "$ROOT" check-ignore .claude/settings.local.json >/dev/null'

echo "== guarded land + teardown =="
check "local land ff"    'b dm-merge.sh local demo-1 >/dev/null'
check "no-fetch landed: reports landed" 'DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 >/dev/null 2>&1'
check "state done"       'OUT="$(b dm-task.sh state demo-1)"; grep -q done <<<"$OUT"'
# demo-1's task state is now `done` (landed above). Even with the backlog moved
# back to inflight (NOT done), `ready` unblocks demo-2 from the reconciled task
# state — the "landed but never marked done" case the old status-only check missed.
b dm-backlog.sh move demo-1 inflight >/dev/null
check "ready unblocks from real task state, not backlog status" 'OUT="$(b dm-backlog.sh ready)"; grep -q demo-2 <<<"$OUT"'
check "teardown ok"      'b dm-worktree.sh remove demo-1 >/dev/null'
check "origin has commit" 'OUT="$(git -C "$DM_HOME/repos/demo" log --oneline)"; grep -q "add multiply" <<<"$OUT"'

echo "== archive (prune a landed, torn-down task) =="
# fail closed: a task that has not reached terminal done cannot be archived.
b dm-task.sh new arch-wip --kind ship --repo demo >/dev/null
check "archive refuses a non-done task"       '! b dm-task.sh archive arch-wip >/dev/null 2>&1'
check "refused task keeps its meta"           '[ -f "$DM_HOME/state/tasks/arch-wip.meta" ]'
# demo-1 landed and was torn down above (state done, no worktree) -> archivable.
check "archive moves a done task's records"   'b dm-task.sh archive demo-1 >/dev/null'
check "archived meta leaves tasks/"           '[ ! -f "$DM_HOME/state/tasks/demo-1.meta" ]'
check "archived meta under archive/"          '[ -f "$DM_HOME/state/archive/demo-1.meta" ]'
check "archived status under archive/"        '[ -f "$DM_HOME/state/archive/demo-1.status" ]'
check "archived data dir under archive/"      '[ -d "$DM_HOME/state/archive/demo-1" ]'
check "archived data dir left data/"          '[ ! -d "$DM_HOME/data/demo-1" ]'

echo "== fail-closed guards =="
b dm-task.sh new demo-3 --kind ship --repo demo >/dev/null
WT3="$(b dm-worktree.sh create demo-3 demo | tail -n1)"
git -C "$WT3" checkout -q -b feat/x/wip
printf 'x\n' > "$WT3/stray.txt"   # untracked
check "teardown refuses untracked" '! b dm-worktree.sh remove demo-3 >/dev/null 2>&1'
b dm-worktree.sh remove demo-3 --force >/dev/null 2>&1
SYNC="$(b dm-sync.sh all)"   # capture once (see doctor note on grep -q + pipefail)
check "sync reports OK"   'grep -q "OK:" <<<"$SYNC"'

echo "== toolbelt input guards =="
# dm-repo.sh set: whitelist + default_branch validation. 'main' is a real branch
# in the clone; a bogus ref and an unknown field must both be refused.
check "set default_branch to a real branch works" 'b dm-repo.sh set demo default_branch main >/dev/null 2>&1'
check "set default_branch to a bogus ref refused"  '! b dm-repo.sh set demo default_branch no-such-branch >/dev/null 2>&1'
check "set unknown field refused"                  '! b dm-repo.sh set demo not_a_field x >/dev/null 2>&1'
# dm-worktree.sh remove: flag order must not matter (`--force` before the id).
b dm-task.sh new demo-4 --kind ship --repo demo >/dev/null
WT4="$(b dm-worktree.sh create demo-4 demo | tail -n1)"
git -C "$WT4" checkout -q -b feat/x/wip4
check "remove parses '--force <id>' regardless of order" 'b dm-worktree.sh remove --force demo-4 >/dev/null 2>&1'
# dm-doctor.sh validates state JSON: corrupt repos.json, expect a named failure.
cp "$DM_HOME/state/repos.json" "$TMP/repos.bak"
printf 'not json{' > "$DM_HOME/state/repos.json"
DOCBAD="$(b dm-doctor.sh 2>&1 || true)"
check "doctor fails on invalid repos.json" '! b dm-doctor.sh >/dev/null 2>&1'
check "doctor names the invalid JSON"      'grep -q "not valid JSON" <<<"$DOCBAD"'
cp "$TMP/repos.bak" "$DM_HOME/state/repos.json"
cp "$DM_HOME/state/secondmates.json" "$TMP/secondmates.bak"
printf '{"secondmates":{"bad":{"status":"active"}}}\n' > "$DM_HOME/state/secondmates.json"
check "doctor fails malformed secondmate identity state" '! b dm-doctor.sh check >/dev/null 2>&1'
cp "$TMP/secondmates.bak" "$DM_HOME/state/secondmates.json"

echo "== branch name =="
# Pure function (no DM_HOME): type/issue validation, slug kebab-collapsing, cap.
check "branch name maps issue+slug"        '[ "$(b dm-branch-name.sh fix 412 "flaky login test")" = "fix/412/flaky-login-test" ]'
check "branch name accepts x issue"        '[ "$(b dm-branch-name.sh feat x "foo")" = "feat/x/foo" ]'
check "branch name kebab-collapses slug"   '[ "$(b dm-branch-name.sh feat x "Dark   MODE!! toggle")" = "feat/x/dark-mode-toggle" ]'
check "branch name rejects bad type"       '! b dm-branch-name.sh bogus x "foo" >/dev/null 2>&1'
check "branch name rejects non-numeric issue" '! b dm-branch-name.sh feat abc "foo" >/dev/null 2>&1'
BN="$(b dm-branch-name.sh chore x "this is an extremely long summary that should be truncated well beyond the forty eight character cap")"
check "branch name caps slug at 48"        '[ "$(printf "%s" "${BN#chore/x/}" | wc -c | tr -d " ")" -le 48 ]'
check "branch name drops trailing hyphen"  'case "$BN" in *-) false;; *) true;; esac'

echo "== backlog move =="
b dm-backlog.sh add mv-1 "movable item" --status queued >/dev/null
check "queued item shows in ready"         'OUT="$(b dm-backlog.sh ready)"; grep -q mv-1 <<<"$OUT"'
b dm-backlog.sh move mv-1 inflight >/dev/null
check "moved-to-inflight leaves ready"     'OUT="$(b dm-backlog.sh ready)"; ! grep -q mv-1 <<<"$OUT"'
b dm-backlog.sh move mv-1 queued >/dev/null
check "moved-back-to-queued rejoins ready" 'OUT="$(b dm-backlog.sh ready)"; grep -q mv-1 <<<"$OUT"'
check "move rejects invalid status"        '! b dm-backlog.sh move mv-1 bogus >/dev/null 2>&1'
check "move rejects unknown id"            '! b dm-backlog.sh move no-such queued >/dev/null 2>&1'

echo "== worktree tangle detection =="
check "tangle: clean clone on default is untangled" 'b dm-worktree.sh tangle demo >/dev/null 2>&1'
git -C "$DM_HOME/repos/demo" checkout -q -b sidebranch
check "tangle: detects non-default branch"  '! b dm-worktree.sh tangle demo >/dev/null 2>&1'
TANGLE="$(b dm-worktree.sh tangle demo 2>&1 || true)"
check "tangle: message names the branch"    'grep -q "TANGLE.*sidebranch" <<<"$TANGLE"'
git -C "$DM_HOME/repos/demo" checkout -q main
git -C "$DM_HOME/repos/demo" branch -q -D sidebranch
check "tangle: clears after return to default" 'b dm-worktree.sh tangle demo >/dev/null 2>&1'

echo "== scout lifecycle =="
b dm-task.sh new sc-1 --kind scout --repo demo >/dev/null
b dm-worktree.sh create sc-1 demo >/dev/null
b dm-brief.sh sc-1 >/dev/null
check "scout state pending before report"   'OUT="$(b dm-task.sh state sc-1)"; grep -q pending <<<"$OUT"'
check "scout brief is scout-flavored"       'grep -q "Definition of done (scout)" "$DM_HOME/data/sc-1/brief.md"'
check "scout brief names the report path"   'grep -q "data/sc-1/report.md" "$DM_HOME/data/sc-1/brief.md"'
check "scout brief omits the ship branch flow" '! grep -q "Create a branch" "$DM_HOME/data/sc-1/brief.md"'
printf '# findings\n' > "$DM_HOME/data/sc-1/report.md"
check "scout state done once report exists"  'OUT="$(b dm-task.sh state sc-1)"; grep -q done <<<"$OUT"'

echo "== repo remove guards =="
b dm-repo.sh add rmtest "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
printf 'dirty\n' > "$DM_HOME/repos/rmtest/DIRTY.txt"   # uncommitted change in the clone
check "remove refuses dirty clone"           '! b dm-repo.sh remove rmtest >/dev/null 2>&1'
rm -f "$DM_HOME/repos/rmtest/DIRTY.txt"
b dm-task.sh new rmscout --kind scout --repo rmtest >/dev/null   # non-terminal referencing task
check "remove refuses repo with a live task" '! b dm-repo.sh remove rmtest >/dev/null 2>&1'
check "remove keeps registry entry on refusal" '[ "$(b dm-repo.sh get rmtest mode)" = "local-only" ]'
mkdir -p "$DM_HOME/data/rmscout"; printf '# report\n' > "$DM_HOME/data/rmscout/report.md"   # task now terminal (done)
check "remove proceeds once referencing task is done" 'b dm-repo.sh remove rmtest >/dev/null 2>&1'
check "removed repo is unregistered"         '! b dm-repo.sh get rmtest >/dev/null 2>&1'
# A live extra worktree off the clone must block removal (the guard counts
# worktrees in one shot so a SIGPIPE'd `grep -q` cannot silently skip it). Use
# raw `git worktree add` so no task meta is created — this isolates the
# worktree guard from the live-task guard exercised above.
b dm-repo.sh add wtguard "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/wtguard" worktree add -q --detach "$TMP/wtguard-extra" >/dev/null 2>&1
check "remove refuses repo with a live worktree" '! b dm-repo.sh remove wtguard >/dev/null 2>&1'
WTGUARD="$(b dm-repo.sh remove wtguard 2>&1 || true)"
check "remove names the active-worktree reason"  'grep -q "active worktrees" <<<"$WTGUARD"'
git -C "$DM_HOME/repos/wtguard" worktree remove "$TMP/wtguard-extra" >/dev/null 2>&1
check "remove proceeds after the worktree is torn down" 'b dm-repo.sh remove wtguard >/dev/null 2>&1'

echo "== merge rebase (offline) =="
# Clean rebase: worktree branch adds a new file, primary main advances with an
# unrelated file -> rebase replays cleanly and picks up the base change.
b dm-task.sh new rb-clean --kind ship --repo demo --mode local-only >/dev/null
RBWT="$(b dm-worktree.sh create rb-clean demo | tail -n1)"
git -C "$RBWT" checkout -q -b feat/x/rb-clean
printf 'clean\n' > "$RBWT/rb_clean.txt"
git -C "$RBWT" -c user.email=c@c.co -c user.name=c add rb_clean.txt >/dev/null
git -C "$RBWT" -c user.email=c@c.co -c user.name=c commit -qm "rb clean feature"
git -C "$DM_HOME/repos/demo" checkout -q main
printf 'base\n' > "$DM_HOME/repos/demo/rb_base.txt"
git -C "$DM_HOME/repos/demo" -c user.email=c@c.co -c user.name=c add rb_base.txt >/dev/null
git -C "$DM_HOME/repos/demo" -c user.email=c@c.co -c user.name=c commit -qm "advance main unrelated"
check "rebase clean succeeds"                'b dm-merge.sh rebase rb-clean >/dev/null 2>&1'
check "rebase clean picks up base + keeps feature" '[ -f "$RBWT/rb_base.txt" ] && [ -f "$RBWT/rb_clean.txt" ]'
check "rebase clean stays on its branch"     '[ "$(git -C "$RBWT" rev-parse --abbrev-ref HEAD)" = "feat/x/rb-clean" ]'
check "rebase clean leaves no in-progress rebase" '! [ -d "$(git -C "$RBWT" rev-parse --git-path rebase-merge)" ] && ! [ -d "$(git -C "$RBWT" rev-parse --git-path rebase-apply)" ]'
# Conflicting rebase: worktree branch and primary main edit the same file -> the
# rebase must report CONFLICT, exit 3, abort, and leave the worktree restored.
b dm-task.sh new rb-conf --kind ship --repo demo --mode local-only >/dev/null
CFWT="$(b dm-worktree.sh create rb-conf demo | tail -n1)"
git -C "$CFWT" checkout -q -b feat/x/rb-conf
printf 'branch change\n' > "$CFWT/src/calc.py"
git -C "$CFWT" -c user.email=c@c.co -c user.name=c commit -qam "branch edits calc"
git -C "$DM_HOME/repos/demo" checkout -q main
printf 'main change\n' > "$DM_HOME/repos/demo/src/calc.py"
git -C "$DM_HOME/repos/demo" -c user.email=c@c.co -c user.name=c commit -qam "main edits calc"
CF_HEAD_BEFORE="$(git -C "$CFWT" rev-parse HEAD)"
if b dm-merge.sh rebase rb-conf >/dev/null 2>&1; then RBRC=0; else RBRC=$?; fi
check "rebase conflict exits 3"              '[ "$RBRC" -eq 3 ]'
check "rebase conflict restores worktree HEAD" '[ "$(git -C "$CFWT" rev-parse HEAD)" = "$CF_HEAD_BEFORE" ]'
check "rebase conflict stays on its branch"  '[ "$(git -C "$CFWT" rev-parse --abbrev-ref HEAD)" = "feat/x/rb-conf" ]'
check "rebase conflict leaves no in-progress rebase" '! [ -d "$(git -C "$CFWT" rev-parse --git-path rebase-merge)" ] && ! [ -d "$(git -C "$CFWT" rev-parse --git-path rebase-apply)" ]'
CFOUT="$(b dm-merge.sh rebase rb-conf 2>&1 || true)"
check "rebase conflict reports CONFLICT"     'grep -q "CONFLICT" <<<"$CFOUT"'
git -C "$DM_HOME/repos/demo" checkout -q main   # leave the demo clone on default for later sections

echo "== dm-memory (native plain-markdown context) =="
# seed scaffolds only the git-excluded private store; it never touches the clone's
# AGENTS.md, so the clone stays pristine (landable and fast-forward-syncable).
b dm-memory.sh seed demo >/dev/null
check "seed creates the private notes store"          '[ -f "$DM_HOME/repos/demo/.dm/notes.md" ]'
check "seed git-excludes the private store"           'grep -qxF ".dm/" "$DM_HOME/repos/demo/.git/info/exclude"'
check "seed leaves the clone pristine"                '[ -z "$(git -C "$DM_HOME/repos/demo" status --porcelain)" ]'
check "seed is idempotent"                            'b dm-memory.sh seed demo >/dev/null 2>&1'
# SHARED knowledge is authored by a crewmate in a worktree and committed; simulate
# a committed dm:knowledge section and assert recall surfaces + filters it.
printf '# demo\n\n<!-- dm:knowledge:start -->\n## Repository knowledge\n- **[command]** run tests with pytest -q\n<!-- dm:knowledge:end -->\n' > "$DM_HOME/repos/demo/AGENTS.md"
b dm-memory.sh remember demo --private --kind routing "prefer squash merges here" >/dev/null
check "remember --private appends the fact"           'grep -q "squash merges" "$DM_HOME/repos/demo/.dm/notes.md"'
b dm-memory.sh remember --global --kind pitfall "fleet gotcha alpha" >/dev/null
check "remember --global appends to learnings"        'grep -q "fleet gotcha alpha" "$DM_HOME/state/learnings.md"'
RECALL="$(b dm-memory.sh recall demo)"          # capture once (grep -q + pipefail)
check "recall shows shared knowledge"                 'grep -q "pytest -q" <<<"$RECALL"'
check "recall shows private knowledge"                'grep -q "squash merges" <<<"$RECALL"'
RQ="$(b dm-memory.sh recall demo pytest)"
check "recall query keeps the matching line"          'grep -q "pytest -q" <<<"$RQ"'
check "recall query drops non-matching lines"         '! grep -q "squash merges" <<<"$RQ"'
GRECALL="$(b dm-memory.sh recall --global)"
check "recall --global shows fleet learnings"         'grep -q "fleet gotcha alpha" <<<"$GRECALL"'
check "multi-line fact is rejected"     '! b dm-memory.sh remember demo --private --kind command "$(printf "a\nb")" >/dev/null 2>&1'
check "invalid kind is rejected"        '! b dm-memory.sh remember demo --private --kind bogus "x" >/dev/null 2>&1'
check "shared append via tool is refused" '! b dm-memory.sh remember demo --kind command "x" >/dev/null 2>&1'
check "unregistered repo is rejected"   '! b dm-memory.sh seed nope >/dev/null 2>&1'

echo "== dm-memory: recall query is a literal substring, not a regex (fix 4) =="
# 'p.test' matches 'pytest' as a regex but not as a literal string; grep -F must
# treat the query literally, so the pytest line is NOT returned.
RXQ="$(b dm-memory.sh recall demo 'p.test')"
check "recall treats a regex-metachar query literally" '! grep -q "pytest" <<<"$RXQ"'
LITQ="$(b dm-memory.sh recall demo 'pytest -q')"
check "recall matches a literal substring query"       'grep -q "pytest -q" <<<"$LITQ"'

echo "== dm-memory: -- ends flag parsing so a fact can start with a dash (fix 3) =="
b dm-memory.sh remember demo --private --kind command -- "-Wall enables all warnings" >/dev/null
check "-- lets a fact begin with a dash"  'grep -q -- "-Wall enables all warnings" "$DM_HOME/repos/demo/.dm/notes.md"'
check "usage documents the -- terminator" 'OUT="$(b dm-memory.sh --help)"; grep -q -- "-- to end flag parsing" <<<"$OUT"'

echo "== dm-memory: a start marker with no end must not leak the file tail (fix 1) =="
# A truncated/mis-edited AGENTS.md (start marker, no matching end) must yield an
# empty shared block and a stderr warning — never the file's whole tail.
cp "$DM_HOME/repos/demo/AGENTS.md" "$TMP/agents.bak"
printf '# demo\n\n<!-- dm:knowledge:start -->\n- **[command]** buffered fact\nSECRET_TAIL_LEAK\n' > "$DM_HOME/repos/demo/AGENTS.md"
NOEND="$(b dm-memory.sh recall demo 2>/dev/null)"
check "recall omits an unclosed knowledge block" '! grep -q "buffered fact" <<<"$NOEND"'
check "recall does not leak the file tail"        '! grep -q "SECRET_TAIL_LEAK" <<<"$NOEND"'
NOEND_ERR="$(b dm-memory.sh recall demo 2>&1 >/dev/null)"
check "recall warns about the missing end marker" 'grep -q "without a matching end" <<<"$NOEND_ERR"'
cp "$TMP/agents.bak" "$DM_HOME/repos/demo/AGENTS.md"

echo "== dm-memory: concurrent first private writes don't truncate each other (fix 2) =="
# No notes store yet: fire concurrent first `remember --private` calls. The header
# is created under the lock, so they cannot erase each other (mirrors the
# concurrent-meta-writes test).
b dm-repo.sh add memconc "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
check "memconc starts with no private notes store" '[ ! -f "$DM_HOME/repos/memconc/.dm/notes.md" ]'
for i in $(seq 1 15); do b dm-memory.sh remember memconc --private --kind routing "concfact$i" & done
wait
cmiss=0
for i in $(seq 1 15); do grep -q "concfact$i" "$DM_HOME/repos/memconc/.dm/notes.md" || cmiss=$((cmiss+1)); done
check "all 15 concurrent private facts survived" '[ "$cmiss" -eq 0 ]'
check "exactly one private-notes header"         '[ "$(grep -c "dockmaster private notes" "$DM_HOME/repos/memconc/.dm/notes.md")" -eq 1 ]'

# === toolbelt-debt tests (#23) ===
echo "== toolbelt debt: backlog write via delegated bwrite =="
# bwrite now delegates to dm_json_update; the full add/list/close cycle must still
# work (the read-modify-write behaves identically through the shared owner).
b dm-backlog.sh add td-1 "delegated write" --status queued >/dev/null
check "backlog add persists via delegated bwrite" 'OUT="$(b dm-backlog.sh list)"; grep -q "delegated write" <<<"$OUT"'
check "queued item shows in ready (delegated)"    'OUT="$(b dm-backlog.sh ready)"; grep -q td-1 <<<"$OUT"'
b dm-backlog.sh done td-1 --note "closed" >/dev/null
check "backlog close persists via delegated bwrite" 'OUT="$(b dm-backlog.sh list)"; CTX="$(grep -A2 "td-1" <<<"$OUT")"; grep -q "note: closed" <<<"$CTX"'
check "closed item drops out of ready (delegated)"  'OUT="$(b dm-backlog.sh ready)"; ! grep -q td-1 <<<"$OUT"'

echo "== toolbelt debt: create yields the requested initial branch (portable init) =="
# Portable git init (no `-b`): the initial branch must be exactly the requested
# one on a clean init. Use an empty bare local remote (offline).
git init -q --bare -b main "$TMP/tb-init.git"
b dm-repo.sh create tbinit "$TMP/tb-init.git" --mode local-only --branch trunk --test-cmd "true" --no-memory >/dev/null
check "create registers with requested branch" '[ "$(b dm-repo.sh get tbinit default_branch)" = "trunk" ]'
check "clone HEAD is the requested branch"      '[ "$(git -C "$DM_HOME/repos/tbinit" rev-parse --abbrev-ref HEAD)" = "trunk" ]'
check "requested branch exists in the clone"    'git -C "$DM_HOME/repos/tbinit" rev-parse --verify --quiet refs/heads/trunk >/dev/null'
# === docs-doctor tests (#24) ===
echo "== doctor tool tiers (#24) =="
DOCF="$(b dm-doctor.sh 2>&1 || true)"   # capture once (grep -q + pipefail)
check "doctor verdict is READY with only git+jq required" 'grep -q "READY:" <<<"$DOCF"'
check "doctor lists chrome-devtools-axi"                  'grep -q "chrome-devtools-axi" <<<"$DOCF"'
# The axi wrappers must never read as required: a fresh clone without them still
# gets a green verdict, matching the README contract.
AXILINES="$(grep -E 'gh-axi|lavish-axi|chrome-devtools-axi' <<<"$DOCF" || true)"
check "doctor does not mark axi tools required"           '! grep -qi "required" <<<"$AXILINES"'
check "check mode still exits 0 without axi tools"        'b dm-doctor.sh check >/dev/null'
# === memory-context tests (#22) ===
# Relevance caps (F1), curation verbs (F2), fleet reach + dockmaster-only store
# (F3/F5), silent-failure surfacing (F4), multi-term recall (F6), and whole-line
# marker anchoring (F7). A fresh repo keeps counts deterministic.
b dm-repo.sh add memctx "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-memory.sh seed memctx >/dev/null

echo "== memory-context: multi-term OR recall (F6) =="
b dm-memory.sh remember memctx --private --kind routing "alpha lions roam" >/dev/null
b dm-memory.sh remember memctx --private --kind routing "beta tigers hunt" >/dev/null
b dm-memory.sh remember memctx --private --kind routing "gamma bears sleep" >/dev/null
ORQ="$(b dm-memory.sh recall memctx "lions bears")"   # capture once (grep -q + pipefail)
check "OR recall keeps a line matching the first term"  'grep -q "alpha lions" <<<"$ORQ"'
check "OR recall keeps a line matching the second term" 'grep -q "gamma bears" <<<"$ORQ"'
check "OR recall drops a line matching neither term"    '! grep -q "beta tigers" <<<"$ORQ"'

echo "== memory-context: soft line cap + tail pointer (F1) =="
for i in $(seq 1 12); do b dm-memory.sh remember memctx --private --kind routing "capfact-$i" >/dev/null; done
# Direct invocation so the env-var prefix reaches the external script unambiguously.
CAP="$(DM_RECALL_MAX_LINES=5 "$ROOT/bin/dm-memory.sh" recall memctx)"
check "cap emits the omitted-lines tail pointer" 'grep -q "older line(s) omitted" <<<"$CAP"'
check "cap hides some bullets under the limit"   '[ "$(grep -c "capfact-" <<<"$CAP")" -lt 12 ]'
# Full content stays reachable on an explicit query (filtered BEFORE the cap).
CAPQ="$(DM_RECALL_MAX_LINES=5 "$ROOT/bin/dm-memory.sh" recall memctx "capfact-7")"
check "explicit query still surfaces a capped-out fact" 'grep -q "capfact-7" <<<"$CAPQ"'

echo "== memory-context: forget removes a bullet, fails on no-match (F2) =="
b dm-memory.sh forget memctx --private "beta tigers" >/dev/null
check "forget removes the matching bullet"   '! grep -q "beta tigers" "$DM_HOME/repos/memctx/.dm/notes.md"'
check "forget leaves a non-matching bullet"  'grep -q "alpha lions" "$DM_HOME/repos/memctx/.dm/notes.md"'
check "forget preserves the store header"    'grep -q "dockmaster private notes" "$DM_HOME/repos/memctx/.dm/notes.md"'
check "forget fails when nothing matches"    '! b dm-memory.sh forget memctx --private "no-such-substring-zzz" >/dev/null 2>&1'

echo "== memory-context: duplicate-fact warning (F2) =="
DUPERR="$(b dm-memory.sh remember memctx --private --kind routing "alpha lions roam" 2>&1 >/dev/null)"
check "remember warns on a duplicate fact body" 'grep -qi "already exists" <<<"$DUPERR"'

echo "== memory-context: dockmaster-only store shown to dockmaster, hidden from crew (F5) =="
b dm-memory.sh remember memctx --dockmaster-only --kind routing "DMONLY-crew-must-not-see" >/dev/null
MREC="$(b dm-memory.sh recall memctx)"
CREC="$(b dm-memory.sh recall memctx --crew)"
check "dockmaster recall includes the dockmaster-only store" 'grep -q "DMONLY-crew-must-not-see" <<<"$MREC"'
check "crew recall excludes the dockmaster-only store"       '! grep -q "DMONLY-crew-must-not-see" <<<"$CREC"'

echo "== memory-context: brief relays private + fleet, excludes dockmaster-only (F3/F5) =="
b dm-task.sh new memctx-1 --kind ship --repo memctx >/dev/null
b dm-worktree.sh create memctx-1 memctx >/dev/null 2>&1
b dm-brief.sh memctx-1 >/dev/null 2>/dev/null
BR="$DM_HOME/data/memctx-1/brief.md"
check "brief injects the Fleet-wide context heading" 'grep -q "Fleet-wide context" "$BR"'
check "brief relays a fleet learning"                'grep -q "fleet gotcha alpha" "$BR"'
check "brief relays a private note"                  'grep -q "alpha lions" "$BR"'
check "brief excludes the dockmaster-only note"      '! grep -q "DMONLY-crew-must-not-see" "$BR"'

echo "== memory-context: marker recognized only as a whole line (F7) =="
# An AGENTS.md that only MENTIONS the marker in prose (as a substring) must not
# trigger extraction: no content surfaced and no false 'unclosed block' warning.
printf '# memctx\n\nWrap facts between <!-- dm:knowledge:start --> and <!-- dm:knowledge:end --> in prose.\n- **[note]** PROSE-NOT-KNOWLEDGE should stay out\n' > "$DM_HOME/repos/memctx/AGENTS.md"
F7ERR="$(b dm-memory.sh recall memctx 2>&1 >/dev/null)"
check "prose marker mention raises no false unclosed-block warning" '! grep -q "without a matching end" <<<"$F7ERR"'
F7OUT="$(b dm-memory.sh recall memctx)"
check "prose marker mention surfaces no shared knowledge"           '! grep -q "PROSE-NOT-KNOWLEDGE" <<<"$F7OUT"'

echo "== memory-context: empty repo yields the friendly line, not empty scaffolds (bug) =="
b dm-repo.sh add memblank "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new memblank-1 --kind ship --repo memblank >/dev/null
b dm-worktree.sh create memblank-1 memblank >/dev/null 2>&1
b dm-brief.sh memblank-1 >/dev/null 2>/dev/null
check "empty repo brief shows the friendly single line"     'grep -q "no repository knowledge recorded yet" "$DM_HOME/data/memblank-1/brief.md"'
check "empty repo brief injects no empty knowledge scaffold" '! grep -q "== shared knowledge" "$DM_HOME/data/memblank-1/brief.md"'
# === state-gate-integrity tests (#20 #21) ===
# Kept in one clearly-marked block at the end so parallel branches union-merge
# cleanly. All offline: GitHub-dependent paths are exercised via their pure
# decision helpers (sourced from dm-lib) rather than the network.
echo "== state-gate-integrity: forgeable 'merged' event (#20-a) =="
b dm-repo.sh add sgi "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new sgi-land --kind ship --repo sgi >/dev/null
check "event rejects the reserved 'merged' landing verb" '! b dm-task.sh event sgi-land merged "forged" >/dev/null 2>&1'
SGIERR="$(b dm-task.sh event sgi-land merged "forged" 2>&1 || true)"
check "event names the landing-signal reason"            'grep -q "landing signal" <<<"$SGIERR"'
check "a forged merged event does not reconcile to done" 'OUT="$(b dm-task.sh state sgi-land)"; ! grep -q done <<<"$OUT"'
# The sanctioned local-land path (dm-merge.sh local) still records the landing
# under the reservation (it appends 'merged' directly via the status helper).
SGIWT="$(b dm-worktree.sh create sgi-land sgi | tail -n1)"
git -C "$SGIWT" checkout -q -b feat/x/sgi-land
printf 'sgi\n' > "$SGIWT/sgi.txt"
git -C "$SGIWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$SGIWT" -c user.email=c@c.co -c user.name=c commit -qm "sgi work" >/dev/null
check "sanctioned merge path records the landing"        'b dm-merge.sh local sgi-land >/dev/null 2>&1'
check "a real landing reconciles to done"                'OUT="$(b dm-task.sh state sgi-land)"; grep -q done <<<"$OUT"'
b dm-worktree.sh remove sgi-land >/dev/null 2>&1

echo "== state-gate-integrity: kind-less worktree create (#20-c) =="
check "worktree create refuses a task with no record" '! b dm-worktree.sh create sgi-norecord sgi >/dev/null 2>&1'
SGINR="$(b dm-worktree.sh create sgi-norecord sgi 2>&1 || true)"
check "worktree create points at dm-task.sh new"      'grep -q "dm-task.sh new" <<<"$SGINR"'

echo "== state-gate-integrity: merge check-gate never merges red on 'none' (#21-a, #49) =="
gate() { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_gate "$1" "$2" "$3" ); }
check "gate refuses 'none' without --allow-no-checks (no CI)"        '[ "$(gate none 0 0)" = "refuse-none" ]'
check "gate refuses 'none' without --allow-no-checks (CI present)"   '[ "$(gate none 0 1)" = "refuse-none" ]'
check "gate allows 'none' with --allow-no-checks when repo has no CI" '[ "$(gate none 1 0)" = "allow" ]'
check "gate refuses 'none' with --allow-no-checks when repo HAS CI"   '[ "$(gate none 1 1)" = "refuse-none" ]'
check "gate allows 'passing'"                           '[ "$(gate passing 0 0)" = "allow" ]'
check "gate refuses 'failing'"                          '[ "$(gate failing 0 0)" = "refuse-failing" ]'
check "gate refuses 'pending'"                          '[ "$(gate pending 0 0)" = "refuse-pending" ]'
check "gate refuses an unknown rollup"                  '[ "$(gate bogus 0 0)" = "refuse-unknown" ]'

echo "== state-gate-integrity: pr_state cannot be forged via 'set' (#20 F6) =="
b dm-task.sh new sgi-forge --kind ship --repo sgi >/dev/null 2>&1 || true
for protected_field in pr pr_state merge_state pr_check_snapshot base; do
  check "set refuses protected field $protected_field" \
    "! b dm-task.sh set sgi-forge '$protected_field' forged >/dev/null 2>&1"
done

echo "== state-gate-integrity: mutex reclaims a crashed holder (#21-b) =="
# Pre-create a lock dir owned by a dead PID; the next dm_lock must reclaim it
# (with a loud warning) and succeed, while the primitive stays mutually
# exclusive for a live holder. Reclaim is judged purely from the dead PID.
( . "$ROOT/bin/dm-lib.sh"
  LF="$TMP/reclaim-test"
  mkdir -p "$LF.lock"; printf '999999\n' > "$LF.lock/pid"
  dm_lock "$LF" 2>"$TMP/reclaim.warn"
  mkdir "$LF.lock" 2>/dev/null && exit 11   # a successful mkdir => lock not exclusive
  dm_unlock "$LF" )
RECLAIM_RC=$?
check "dm_lock reclaims a dead-PID stale lock and succeeds" '[ "$RECLAIM_RC" -eq 0 ]'
check "stale reclaim warns loudly"                          'grep -q "reclaiming stale lock" "$TMP/reclaim.warn"'
# A fresh live lock is still held exclusively: after acquiring, a bare mkdir of
# the same lock dir fails (the concurrent-meta-writes test above covers the
# no-lost-update guarantee end to end).
( . "$ROOT/bin/dm-lib.sh"
  LF2="$TMP/live-lock-test"
  dm_lock "$LF2"
  mkdir "$LF2.lock" 2>/dev/null && exit 12   # held => this mkdir must fail
  dm_unlock "$LF2" )
LIVE_RC=$?
check "a live lock is still mutually exclusive" '[ "$LIVE_RC" -eq 0 ]'

# === fleet-campaign tests (#25) ===
echo "== fleet campaign: grouping persists and rolls up =="
b dm-backlog.sh add camp-web "web bump" --repo demo --campaign fleet-bump --status inflight >/dev/null
b dm-backlog.sh add camp-api "api bump" --repo demo --campaign fleet-bump --status queued --blocked-by camp-web >/dev/null
b dm-backlog.sh add camp-other "unrelated item" --repo demo --status queued >/dev/null
check "campaign field persists on the item" 'jq -e ".items[]|select(.id==\"camp-web\")|.campaign==\"fleet-bump\"" "$DM_HOME/state/backlog.json" >/dev/null'
ROLL="$(b dm-backlog.sh campaign fleet-bump)"   # capture once (grep -q + pipefail)
check "campaign rollup lists a member"          'grep -q camp-web <<<"$ROLL"'
check "campaign rollup lists the second member" 'grep -q camp-api <<<"$ROLL"'
check "campaign rollup excludes non-members"    '! grep -q camp-other <<<"$ROLL"'
check "campaign rollup shows member status"     'grep -E "camp-web +inflight" <<<"$ROLL" >/dev/null && grep -E "camp-api +queued" <<<"$ROLL" >/dev/null'
check "campaign rejects an invalid id"          '! b dm-backlog.sh campaign ".bad" >/dev/null 2>&1'
check "add rejects an invalid campaign id"       '! b dm-backlog.sh add camp-bad "x" --campaign ".bad" >/dev/null 2>&1'
# === repo-scout tests (#27) ===
echo "== repo-scout onboarding hint (#27) =="
# Adding a repo with no test_cmd must point at the onboarding scout (the tests
# gate would otherwise soft-skip silently and knowledge start empty); supplying a
# test_cmd means there is nothing to bootstrap, so no hint.
ADDHINT="$(b dm-repo.sh add scouthint "$TMP/origin.git" --mode local-only --no-memory 2>&1)"
check "add without a test_cmd hints the onboarding scout" 'grep -qi "onboarding scout" <<<"$ADDHINT"'
check "scout hint names the set test_cmd escape hatch"    'grep -q "test_cmd" <<<"$ADDHINT"'
ADDQUIET="$(b dm-repo.sh add scoutquiet "$TMP/origin.git" --mode local-only --test-cmd "true" --no-memory 2>&1)"
check "add WITH a test_cmd prints no scout hint"          '! grep -qi "onboarding scout" <<<"$ADDQUIET"'
# === pr-sweep tests (#26) ===
# The GitHub-dependent path (check refresh + review query) is offline-unreachable
# here, so we assert the SELECTION logic (the pure dm_open_pr_tasks selector) and
# the offline sweep/status rendering. `pr`/`pr_state` are PR-tracking fields the
# `set` verb refuses to hand-write, so seed them through dm_meta_set directly —
# the same owner path dm-pr.sh check uses.
echo "== pr-sweep: open-PR selector picks exactly open PRs (#26) =="
b dm-task.sh new sweep-open   --kind ship --repo demo >/dev/null 2>&1 || true
b dm-task.sh new sweep-merged --kind ship --repo demo >/dev/null 2>&1 || true
b dm-task.sh new sweep-closed --kind ship --repo demo >/dev/null 2>&1 || true
b dm-task.sh new sweep-nopr   --kind ship --repo demo >/dev/null 2>&1 || true
( . "$ROOT/bin/dm-lib.sh"
  dm_meta_set sweep-open   pr "https://github.com/o/r/pull/1"
  dm_meta_set sweep-merged pr "https://github.com/o/r/pull/2"
  dm_meta_set sweep-merged pr_state MERGED
  dm_meta_set sweep-closed pr "https://github.com/o/r/pull/3"
  dm_meta_set sweep-closed pr_state CLOSED ) >/dev/null 2>&1
SEL="$( . "$ROOT/bin/dm-lib.sh"; dm_open_pr_tasks )"
check "selector includes an open PR task"   'grep -qx "sweep-open" <<<"$SEL"'
check "selector excludes a merged PR task"   '! grep -qx "sweep-merged" <<<"$SEL"'
check "selector excludes a closed PR task"   '! grep -qx "sweep-closed" <<<"$SEL"'
check "selector excludes a task with no PR"  '! grep -qx "sweep-nopr" <<<"$SEL"'

echo "== pr-sweep: offline sweep renders open PRs from cache (#26) =="
SWEEP="$(DM_NO_FETCH=1 b dm-pr.sh sweep 2>&1 || true)"
check "offline sweep lists the open PR"    'grep -q "sweep-open" <<<"$SWEEP"'
check "offline sweep omits the merged PR"  '! grep -q "sweep-merged" <<<"$SWEEP"'
check "offline sweep marks output cached"  'grep -q "no fetch" <<<"$SWEEP"'
check "offline sweep prints a summary"     'grep -q "open PR(s)" <<<"$SWEEP"'
# A missing clone must be surfaced per-line, not abort the sweep.
b dm-task.sh new sweep-noclone --kind ship --repo not-a-real-repo >/dev/null 2>&1 || true
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set sweep-noclone pr "https://github.com/o/r/pull/9" ) >/dev/null 2>&1
SWEEP2="$(DM_NO_FETCH=1 b dm-pr.sh sweep 2>&1 || true)"
check "sweep flags a missing clone, keeps going" 'grep -q "clone missing" <<<"$SWEEP2" && grep -q "sweep-open" <<<"$SWEEP2"'

echo "== pr-sweep: status surfaces the open-PRs section (#26) =="
STATUS_PR="$(b dm-status.sh 2>&1 || true)"
check "status shows the open-PRs section"  'grep -q "OPEN PRs" <<<"$STATUS_PR"'
check "status open-PRs lists the open PR"  'grep -q "sweep-open" <<<"$STATUS_PR"'

echo "== stale-base guard: dm-worktree create FF-syncs a behind clone (#44/#40) =="
git init -q --bare -b main "$TMP/stale-origin.git"
git init -q -b main "$TMP/stale-seed"
( cd "$TMP/stale-seed"; git config user.email t@t.co; git config user.name t
  printf 'v1\n' > f.txt; git add .; git commit -qm init
  git remote add origin "$TMP/stale-origin.git"; git push -q origin main ) >/dev/null 2>&1
b dm-repo.sh add staletest "$TMP/stale-origin.git" --mode local-only --no-memory >/dev/null 2>&1
# Advance origin independently of the clone, as an out-of-band merge would.
( cd "$TMP/stale-seed"; printf 'v2\n' >> f.txt; git commit -qam advance; git push -q origin main ) >/dev/null 2>&1
ADV_SHA="$(git -C "$TMP/stale-seed" rev-parse HEAD)"
check "clone starts behind the advanced origin" '[ "$(git -C "$DM_HOME/repos/staletest" rev-parse main)" != "'"$ADV_SHA"'" ]'
b dm-task.sh new stale-1 --kind ship --repo staletest >/dev/null
STALEWT="$(b dm-worktree.sh create stale-1 staletest | tail -n1)"
check "create FF-syncs the clone to the advanced origin" '[ "$(git -C "$DM_HOME/repos/staletest" rev-parse main)" = "'"$ADV_SHA"'" ]'
check "worktree base includes the synced commit" 'grep -q v2 "$STALEWT/f.txt"'

echo "== stale-base guard: a clone that cannot fast-forward fails closed (#44/#40) =="
git init -q --bare -b main "$TMP/div-origin.git"
git init -q -b main "$TMP/div-seed"
( cd "$TMP/div-seed"; git config user.email t@t.co; git config user.name t
  printf 'base\n' > g.txt; git add .; git commit -qm init
  git remote add origin "$TMP/div-origin.git"; git push -q origin main ) >/dev/null 2>&1
b dm-repo.sh add divtest "$TMP/div-origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new div-1 --kind ship --repo divtest >/dev/null
# Diverge: origin advances one way, the clone's main advances another -> no FF
# is possible in either direction.
( cd "$TMP/div-seed"; printf 'remote-side\n' >> g.txt; git commit -qam "remote advance"; git push -q origin main ) >/dev/null 2>&1
git -C "$DM_HOME/repos/divtest" -c user.email=c@c.co -c user.name=c commit --allow-empty -qm "local-only commit on main" >/dev/null 2>&1
check "create fails closed on a diverged clone" '! b dm-worktree.sh create div-1 divtest >/dev/null 2>&1'
DIVOUT="$(b dm-worktree.sh create div-1 divtest 2>&1 || true)"
check "guard message names the repo and says resolve" 'grep -q divtest <<<"$DIVOUT" && grep -qi resolve <<<"$DIVOUT"'
check "no worktree left behind by the failed create" '[ ! -e "$DM_HOME/state/worktrees/div-1" ]'
check "DM_NO_FETCH bypasses the stale-base guard" 'DM_NO_FETCH=1 b dm-worktree.sh create div-1 divtest >/dev/null 2>&1'
check "DM_NO_FETCH create actually produced a worktree" '[ -d "$DM_HOME/state/worktrees/div-1" ]'

echo "== cold-review fix: an unborn default branch never crashes dm-sync or its callers =="
# A clone of a never-committed-to bare remote has an unborn HEAD: `git rev-parse
# --abbrev-ref HEAD` exits 128 there (sync_one's own rev-parse was unguarded -
# the root-cause bug). sync_one must still return 0 and report SKIP/STUCK, never
# a raw git fatal, and its two new callers must not crash either.
git init -q --bare -b main "$TMP/unborn-origin.git"   # never gets a commit
b dm-repo.sh add unborntest "$TMP/unborn-origin.git" --mode local-only --no-memory >/dev/null 2>&1
if SYNC_UNBORN="$(b dm-sync.sh one unborntest 2>&1)"; then SYNC_RC=0; else SYNC_RC=$?; fi
check "sync on an unborn clone still exits 0" '[ "$SYNC_RC" -eq 0 ]'
check "sync on an unborn clone reports SKIP/STUCK, not a raw git fatal" \
  'grep -qE "^(SKIP|STUCK):" <<<"$SYNC_UNBORN" && ! grep -q "fatal:" <<<"$SYNC_UNBORN"'
b dm-task.sh new unborn-1 --kind ship --repo unborntest >/dev/null
if UNBORN_OUT="$(b dm-worktree.sh create unborn-1 unborntest 2>&1)"; then UNBORN_RC=0; else UNBORN_RC=$?; fi
check "worktree create on an unborn clone never raw-crashes" '! grep -q "fatal:" <<<"$UNBORN_OUT"'
check "worktree create on an unborn clone succeeds or fails closed with a clean message" \
  '[ "$UNBORN_RC" -eq 0 ] || grep -qi "not fast-forwardable" <<<"$UNBORN_OUT"'

echo "== sub-PR stack: --base branches a child off a PARENT ref and records it (#45 phase 1) =="
b dm-repo.sh add substack "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/substack" checkout -q -b parent-feature
printf 'parent v1\n' > "$DM_HOME/repos/substack/parent.txt"
git -C "$DM_HOME/repos/substack" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$DM_HOME/repos/substack" -c user.email=c@c.co -c user.name=c commit -qm "parent feature v1" >/dev/null
git -C "$DM_HOME/repos/substack" push -q origin parent-feature >/dev/null 2>&1
git -C "$DM_HOME/repos/substack" checkout -q main
MAIN_SHA="$(git -C "$DM_HOME/repos/substack" rev-parse main)"

# Advance the parent branch on ORIGIN independently of the substack clone (as
# another crewmate pushing to the parent PR would), so the clone's own view of
# parent-feature is stale before --base fetches it fresh.
git clone -q "$TMP/origin.git" "$TMP/substack-seed" >/dev/null 2>&1
( cd "$TMP/substack-seed"; git config user.email t@t.co; git config user.name t
  git checkout -q parent-feature
  printf 'parent v2\n' >> parent.txt
  git commit -qam "parent feature v2"
  git push -q origin parent-feature ) >/dev/null 2>&1
PARENT_SHA="$(git -C "$TMP/substack-seed" rev-parse parent-feature)"
check "clone's local view of the parent starts stale" \
  '[ "$(git -C "$DM_HOME/repos/substack" rev-parse origin/parent-feature 2>/dev/null || echo none)" != "'"$PARENT_SHA"'" ]'

b dm-task.sh new sub-child --kind ship --repo substack >/dev/null
SUBWT="$(b dm-worktree.sh create sub-child substack sub-branch --base parent-feature | tail -n1)"
check "--base worktree created"             '[ -d "$SUBWT" ]'
check "--base fetches the parent ref fresh (picks up v2)" '[ "$(git -C "$SUBWT" rev-parse HEAD)" = "'"$PARENT_SHA"'" ]'
check "child sits on the parent, not main"  '[ "$(git -C "$SUBWT" rev-parse HEAD)" != "'"$MAIN_SHA"'" ]'
check "child is on the requested branch"    '[ "$(git -C "$SUBWT" rev-parse --abbrev-ref HEAD)" = "sub-branch" ]'
check "base is recorded in task meta"       '[ "$(b dm-task.sh get sub-child base)" = "parent-feature" ]'

echo "== sub-PR stack: DM_NO_FETCH bypasses the parent fetch, same convention as the default path =="
b dm-task.sh new sub-child-nf --kind ship --repo substack >/dev/null
check "DM_NO_FETCH create with --base still succeeds" \
  'DM_NO_FETCH=1 b dm-worktree.sh create sub-child-nf substack sub-branch-nf --base parent-feature >/dev/null 2>&1'

echo "== sub-PR stack: default (no --base) path is unaffected (byte-identical behavior) =="
b dm-task.sh new sub-default --kind ship --repo substack >/dev/null
DEFWT="$(b dm-worktree.sh create sub-default substack | tail -n1)"
check "default worktree still branches off main"  '[ "$(git -C "$DEFWT" rev-parse HEAD)" = "'"$MAIN_SHA"'" ]'
check "default create records no base meta"       '[ -z "$(b dm-task.sh get sub-default base)" ]'

echo "== sub-PR stack: --base flag order is independent of the positional args =="
b dm-task.sh new sub-child-order --kind ship --repo substack >/dev/null
ORDERWT="$(b dm-worktree.sh create --base parent-feature sub-child-order substack sub-branch-order | tail -n1)"
check "--base before positional args still works" '[ "$(git -C "$ORDERWT" rev-parse HEAD)" = "'"$PARENT_SHA"'" ]'

echo "== sub-PR stack: dm-pr.sh open's base resolution favors the recorded parent (#45 phase 1) =="
# Pure-function check (mirrors the `gate()` merge-gate test above): exercises the
# exact resolution dm-pr.sh open performs, without needing gh-axi/network.
prbase() { ( . "$ROOT/bin/dm-lib.sh"; dm_pr_base_for "$1" "$2" "$3" ); }
check "explicit --base always wins over the recorded parent" \
  '[ "$(prbase sub-child other-explicit-base "$DM_HOME/repos/substack")" = "other-explicit-base" ]'
check "no explicit --base falls back to the recorded parent" \
  '[ "$(prbase sub-child "" "$DM_HOME/repos/substack")" = "parent-feature" ]'
check "no --base and no recorded parent falls back to the default branch" \
  '[ "$(prbase sub-default "" "$DM_HOME/repos/substack")" = "main" ]'

echo "== sub-PR stack: cold-review fixes (malformed flag + base meta forge guard) =="
# `--base` as the last token (no value) must fail VISIBLY with a named message,
# not a silent crash from `shift 2` running out of positional args under -u.
b dm-task.sh new sub-badflag --kind ship --repo substack >/dev/null
check "--base with no value fails (not a bare crash)" \
  '! b dm-worktree.sh create sub-badflag substack sub-branch-bad --base >/dev/null 2>&1'
BADFLAGOUT="$(b dm-worktree.sh create sub-badflag substack sub-branch-bad --base 2>&1 || true)"
check "--base with no value names the requirement" 'grep -q -- "--base requires" <<<"$BADFLAGOUT"'
check "--base with no value leaves no worktree behind" '[ ! -e "$DM_HOME/state/worktrees/sub-badflag" ]'
# `base` feeds `gh pr create --base`; a hand-set value would silently retarget a
# sub-PR, so `dm-task.sh set` must refuse it like pr/pr_state/merge_state.
check "set refuses hand-writing base" '! b dm-task.sh set sub-child base evil-branch >/dev/null 2>&1'
check "set base recorded by --base is untouched by the guard" '[ "$(b dm-task.sh get sub-child base)" = "parent-feature" ]'

echo "== never-merge-red: pure-function coverage for dm-pr.sh's url/rollup helpers (#53) =="
# dm-pr.sh is a script with a dispatch `case` at the bottom, not a pure library
# like dm-lib.sh, so sourcing it runs that case. An empty $1 falls to the usage
# branch and exits before any function below could be called. `url` with a
# harmless task id resolves through dm_meta_get, which returns cleanly (empty)
# for a nonexistent task and never exits, so sourcing completes and the
# functions become callable in the same subshell — same technique as `gate()`
# above, adapted because dm-pr.sh (unlike dm-lib.sh) always dispatches.
prfn() { ( . "$ROOT/bin/dm-pr.sh" url _smoke_helper_probe_ >/dev/null 2>&1; "$@" ); }

check "owner_repo parses an scp-style ssh remote"      '[ "$(prfn owner_repo "git@github.com:owner/repo.git")" = "owner/repo" ]'
check "owner_repo parses an https remote with .git"    '[ "$(prfn owner_repo "https://github.com/owner/repo.git")" = "owner/repo" ]'
check "owner_repo parses an https remote without .git" '[ "$(prfn owner_repo "https://github.com/owner/repo")" = "owner/repo" ]'
# Only a `.git` suffix is trimmed; a trailing slash is NOT stripped, so a
# caller passing a remote URL ending in "/" gets a slug that does too.
check "owner_repo does not strip a trailing slash (documents the edge case)" \
  '[ "$(prfn owner_repo "https://github.com/owner/repo/")" = "owner/repo/" ]'
check "owner_repo refuses a url with no owner/repo slash" '! prfn owner_repo "not-a-remote" >/dev/null 2>&1'

check "pr_number_from_url parses a canonical pull url" '[ "$(prfn pr_number_from_url "https://github.com/owner/repo/pull/42")" = "42" ]'
check "pr_number_from_url refuses a non-canonical url"  '! prfn pr_number_from_url "https://github.com/owner/repo/pulls/42" >/dev/null 2>&1'

check "pr_repo_slug_from_url strips /pull/<n> down to owner/repo" \
  '[ "$(prfn pr_repo_slug_from_url "https://github.com/owner/repo/pull/42")" = "owner/repo" ]'

echo "== pr-adopt: url/repo validation fails closed before any GitHub tool is needed (#52) =="
# All three checks below (url format, task existence, repo-match) run BEFORE
# `dm_need gh` in `adopt`, so they are deterministic offline even with `gh`
# installed (no network call is ever reached).
b dm-task.sh new adopt-probe --kind ship --repo demo >/dev/null 2>&1 || true
check "adopt refuses a non-canonical PR url"     '! b dm-pr.sh adopt adopt-probe "not-a-url" >/dev/null 2>&1'
ADOPTBAD="$(b dm-pr.sh adopt adopt-probe "not-a-url" 2>&1 || true)"
check "adopt names the canonical-url reason"     'grep -q "canonical PR url" <<<"$ADOPTBAD"'
check "adopt refuses an unrecorded task id"       '! b dm-pr.sh adopt no-such-adopt-task "https://github.com/owner/repo/pull/1" >/dev/null 2>&1'
ADOPTNOTASK="$(b dm-pr.sh adopt no-such-adopt-task "https://github.com/owner/repo/pull/1" 2>&1 || true)"
check "adopt names the no-such-task reason"       'grep -q "no such task" <<<"$ADOPTNOTASK"'
# demo's origin is a local fixture path, not github.com/owner/repo, so ANY
# canonical PR url mismatches it — exercising the cross-repo refusal.
check "adopt refuses a PR that does not belong to the task's repo" \
  '! b dm-pr.sh adopt adopt-probe "https://github.com/someone/other-repo/pull/7" >/dev/null 2>&1'
ADOPTMISMATCH="$(b dm-pr.sh adopt adopt-probe "https://github.com/someone/other-repo/pull/7" 2>&1 || true)"
check "adopt names the repo-mismatch reason" \
  'grep -q "refusing to adopt a PR from a different repo" <<<"$ADOPTMISMATCH"'

# rollup_rank / worst_rollup worst-wins precedence, confirmed from the source:
# failing(4) > unknown(3) > pending(2) > passing(1) > none(0). `unknown`
# outranks `pending` so an API error is never silently treated as more
# mergeable than an in-flight check; `none` (no signal at all) ranks lowest.
check "rollup_rank: failing outranks unknown" '[ "$(prfn rollup_rank failing)" -gt "$(prfn rollup_rank unknown)" ]'
check "rollup_rank: unknown outranks pending" '[ "$(prfn rollup_rank unknown)" -gt "$(prfn rollup_rank pending)" ]'
check "rollup_rank: pending outranks passing" '[ "$(prfn rollup_rank pending)" -gt "$(prfn rollup_rank passing)" ]'
check "rollup_rank: passing outranks none"    '[ "$(prfn rollup_rank passing)" -gt "$(prfn rollup_rank none)" ]'

check "worst_rollup: failing beats passing regardless of arg order" \
  '[ "$(prfn worst_rollup failing passing)" = failing ] && [ "$(prfn worst_rollup passing failing)" = failing ]'
check "worst_rollup: unknown beats pending regardless of arg order" \
  '[ "$(prfn worst_rollup unknown pending)" = unknown ] && [ "$(prfn worst_rollup pending unknown)" = unknown ]'
check "worst_rollup: pending beats passing regardless of arg order" \
  '[ "$(prfn worst_rollup pending passing)" = pending ] && [ "$(prfn worst_rollup passing pending)" = pending ]'
# The worst-wins rollup must never let a bad state be masked by a good one.
check "worst_rollup: none can never mask a failing rollup"    \
  '[ "$(prfn worst_rollup none failing)" = failing ] && [ "$(prfn worst_rollup failing none)" = failing ]'
check "worst_rollup: passing can never mask a failing rollup" \
  '[ "$(prfn worst_rollup passing failing)" = failing ] && [ "$(prfn worst_rollup failing passing)" = failing ]'

echo "== merge-authority: pure gate, field validation, legacy yolo mapping =="
# The gate is a pure function (like dm_merge_gate): never is an absolute refusal,
# ask/yolo allow the mechanics, and an unrecognized authority fails closed.
mauth()  { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_authority_gate "$1" ); }
mauthr() { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_authority "$1" ); }
check "authority gate allows yolo"             '[ "$(mauth yolo)"    = "allow" ]'
check "authority gate allows ask"              '[ "$(mauth ask)"     = "allow" ]'
check "authority gate refuses never"           '[ "$(mauth never)"   = "refuse-never" ]'
check "authority gate fails closed on invalid" '[ "$(mauth invalid)" = "refuse-invalid" ]'
check "authority gate fails closed on garbage" '[ "$(mauth bogus)"   = "refuse-invalid" ]'

# New repos default to ask; the settable field validates and rejects garbage.
b dm-repo.sh add mauth "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
check "new repo defaults to merge_authority=ask" '[ "$(b dm-repo.sh get mauth merge_authority)" = "ask" ]'
check "set merge_authority never works"          'b dm-repo.sh set mauth merge_authority never >/dev/null 2>&1'
check "get reflects merge_authority never"       '[ "$(b dm-repo.sh get mauth merge_authority)" = "never" ]'
check "set merge_authority rejects garbage"      '! b dm-repo.sh set mauth merge_authority bogus >/dev/null 2>&1'
# list surfaces the AUTH column so the operator can audit merge authority at a glance.
MAUTHLIST="$(b dm-repo.sh list)"
check "list shows the AUTH column header"     'grep -q "AUTH" <<<"$MAUTHLIST"'
check "list shows the repo's never authority" 'grep -E "mauth +never" <<<"$MAUTHLIST" >/dev/null'

# The yolo alias maps to merge_authority (single source of truth) and retires the
# legacy boolean in the same write, so the two representations never drift.
b dm-repo.sh set mauth yolo true >/dev/null
check "yolo=true alias maps to merge_authority yolo" '[ "$(b dm-repo.sh get mauth merge_authority)" = "yolo" ]'
check "yolo alias drops the legacy yolo key"         '[ -z "$(b dm-repo.sh get mauth yolo)" ]'
b dm-repo.sh set mauth yolo false >/dev/null
check "yolo=false alias maps to merge_authority ask" '[ "$(b dm-repo.sh get mauth merge_authority)" = "ask" ]'
check "yolo alias rejects a non-bool value"          '! b dm-repo.sh set mauth yolo maybe >/dev/null 2>&1'

# Legacy registry (a yolo bool, no merge_authority) maps on read: true->yolo,
# false/absent->ask. Simulate one by rewriting the throwaway registry directly.
# The list AUTH column must show the DERIVED authority for such an entry, not
# just after an explicit set (the display path goes through the same resolver).
REG="$DM_HOME/state/repos.json"
jq '.repos["mauth"] |= (del(.merge_authority) + {yolo:true})'  "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "legacy yolo:true reads as yolo"       '[ "$(mauthr mauth)" = "yolo" ]'
check "list shows legacy yolo:true as yolo"  'grep -E "mauth +yolo" <<<"$(b dm-repo.sh list)" >/dev/null'
jq '.repos["mauth"] |= (del(.merge_authority) + {yolo:false})' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "legacy yolo:false reads as ask"       '[ "$(mauthr mauth)" = "ask" ]'
jq '.repos["mauth"] |= (del(.yolo) | del(.merge_authority))'   "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "absent authority reads as ask"        '[ "$(mauthr mauth)" = "ask" ]'
check "list shows a legacy absent entry as ask" 'grep -E "mauth +ask" <<<"$(b dm-repo.sh list)" >/dev/null'

# A corrupt/hand-broken merge_authority must FAIL CLOSED, not silently downgrade
# to a permissive posture: the resolver returns `invalid` and list renders it
# visibly (one bad row must not kill the whole listing).
jq '.repos["mauth"] |= (.merge_authority = "nevr")' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "corrupt merge_authority resolves to invalid" '[ "$(mauthr mauth)" = "invalid" ]'
MAUTHINV="$(b dm-repo.sh list)"
check "list renders a corrupt entry as invalid, not fatal" 'grep -E "mauth +invalid" <<<"$MAUTHINV" >/dev/null'
check "list still shows other repos alongside a corrupt row" 'grep -q "demo" <<<"$MAUTHINV"'
# The WHOLE stored value is validated: a value that merely STARTS with a valid
# token but embeds a delimiter (tab/newline) must not truncate to a passing
# prefix — it resolves to invalid and fails closed.
jq '.repos["mauth"] |= (.merge_authority = "yolo\tx")' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "embedded-tab \"yolo\\tx\" resolves to invalid" '[ "$(mauthr mauth)" = "invalid" ]'
jq '.repos["mauth"] |= (.merge_authority = "ask\tx")'  "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "embedded-tab \"ask\\tx\" resolves to invalid"  '[ "$(mauthr mauth)" = "invalid" ]'
jq '.repos["mauth"] |= (.merge_authority = "yolo\nx")' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "embedded-newline \"yolo\\nx\" resolves to invalid" '[ "$(mauthr mauth)" = "invalid" ]'
jq '.repos["mauth"] |= (del(.merge_authority) | del(.yolo))' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"

echo "== merge-authority: dm-merge.sh local hard-refuses a never repo =="
b dm-repo.sh set mauth merge_authority never >/dev/null
b dm-task.sh new mauth-land --kind ship --repo mauth --mode local-only >/dev/null
MAWT="$(b dm-worktree.sh create mauth-land mauth | tail -n1)"
git -C "$MAWT" checkout -q -b feat/x/mauth-land
printf 'x\n' > "$MAWT/mauth.txt"
git -C "$MAWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$MAWT" -c user.email=c@c.co -c user.name=c commit -qm "mauth work" >/dev/null
DEFBEFORE="$(git -C "$DM_HOME/repos/mauth" rev-parse main)"
check "local land refuses a never repo"           '! b dm-merge.sh local mauth-land >/dev/null 2>&1'
LANDOUT="$(b dm-merge.sh local mauth-land 2>&1 || true)"
check "local refusal names merge_authority=never" 'grep -q "merge_authority=never" <<<"$LANDOUT"'
check "local refusal did not advance the clone"   '[ "$(git -C "$DM_HOME/repos/mauth" rev-parse main)" = "$DEFBEFORE" ]'
# Flipping authority to ask (the only change) lets the very same land succeed AND
# actually advance the clone past where it was before the refusal.
b dm-repo.sh set mauth merge_authority ask >/dev/null
check "local land proceeds once authority is ask" 'b dm-merge.sh local mauth-land >/dev/null 2>&1'
check "ask-path land actually advanced the clone"  '[ "$(git -C "$DM_HOME/repos/mauth" rev-parse main)" != "$DEFBEFORE" ]'
b dm-worktree.sh remove mauth-land >/dev/null 2>&1

echo "== merge-authority: dm-pr.sh merge hard-refuses a never repo before any GitHub call =="
# The authority gate runs before `dm_need gh` and before any gh call, so this is
# deterministic offline (no network, no gh required). Seed a PR via the same
# owner path dm-pr.sh check uses (`set` refuses to hand-write pr).
b dm-repo.sh set mauth merge_authority never >/dev/null
b dm-task.sh new mauth-pr --kind ship --repo mauth >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set mauth-pr pr "https://github.com/o/r/pull/1" ) >/dev/null 2>&1
check "pr merge refuses a never repo"                '! b dm-pr.sh merge mauth-pr >/dev/null 2>&1'
PRMERGEOUT="$(b dm-pr.sh merge mauth-pr 2>&1 || true)"
check "pr merge refusal names merge_authority=never" 'grep -q "merge_authority=never" <<<"$PRMERGEOUT"'
check "pr merge refusal points at operator merging"  'grep -qi "operator merges" <<<"$PRMERGEOUT"'

echo "== merge-authority: a corrupt stored value fails closed on both landing paths (composed) =="
# Hand-break the stored value directly in the throwaway registry (as a bad edit
# would), then drive both landing paths offline. Each must refuse — naming the
# bad value — and the clone must not advance. The pure-gate tests above cover
# this in isolation; this exercises the composed script path end to end.
b dm-repo.sh set mauth merge_authority ask >/dev/null   # valid posture for the setup below
b dm-task.sh new mauth-corrupt --kind ship --repo mauth --mode local-only >/dev/null
MCWT="$(b dm-worktree.sh create mauth-corrupt mauth | tail -n1)"
git -C "$MCWT" checkout -q -b feat/x/mauth-corrupt
printf 'y\n' > "$MCWT/corrupt.txt"
git -C "$MCWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$MCWT" -c user.email=c@c.co -c user.name=c commit -qm "corrupt-path work" >/dev/null
# Break the value only AFTER the worktree/commit setup (which needs a valid one).
jq '.repos["mauth"] |= (.merge_authority = "nevr")' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
CORRUPT_BEFORE="$(git -C "$DM_HOME/repos/mauth" rev-parse main)"
check "local land refuses a corrupt authority"           '! b dm-merge.sh local mauth-corrupt >/dev/null 2>&1'
CORRUPTLAND="$(b dm-merge.sh local mauth-corrupt 2>&1 || true)"
check "local corrupt refusal names the bad value"        'grep -q "nevr" <<<"$CORRUPTLAND" && grep -qi "invalid merge_authority" <<<"$CORRUPTLAND"'
check "local corrupt refusal did not advance the clone"  '[ "$(git -C "$DM_HOME/repos/mauth" rev-parse main)" = "$CORRUPT_BEFORE" ]'
b dm-task.sh new mauth-corrupt-pr --kind ship --repo mauth >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set mauth-corrupt-pr pr "https://github.com/o/r/pull/2" ) >/dev/null 2>&1
check "pr merge refuses a corrupt authority"             '! b dm-pr.sh merge mauth-corrupt-pr >/dev/null 2>&1'
CORRUPTPR="$(b dm-pr.sh merge mauth-corrupt-pr 2>&1 || true)"
check "pr corrupt refusal names the bad value"           'grep -q "nevr" <<<"$CORRUPTPR" && grep -qi "invalid merge_authority" <<<"$CORRUPTPR"'
# A value starting with a valid token but embedding a tab must also refuse on a
# real landing path (not just the resolver) — the whole value is validated.
jq '.repos["mauth"] |= (.merge_authority = "yolo\tx")' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
EMBED_BEFORE="$(git -C "$DM_HOME/repos/mauth" rev-parse main)"
check "local land refuses an embedded-tab \"yolo\\tx\" value" '! b dm-merge.sh local mauth-corrupt >/dev/null 2>&1'
check "embedded-tab refusal did not advance the clone"        '[ "$(git -C "$DM_HOME/repos/mauth" rev-parse main)" = "$EMBED_BEFORE" ]'
b dm-worktree.sh remove mauth-corrupt --force >/dev/null 2>&1

echo "== merge-base exception: pure gate (never-repo branch carve-out) =="
# Pure like dm_merge_gate: allow ONLY on never + a non-empty, whitespace-free,
# non-default base that full-string matches a listed branch; everything else
# refuses (fail closed).
mbase() { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_base_exception "$1" "$2" "$3" "$4" ); }
MBALLOWED=$'feature/x/overhaul\nintegration'
check "exception allows an exact match under never"   '[ "$(mbase never integration main "$MBALLOWED")" = "allow" ]'
check "exception allows the other listed base"        '[ "$(mbase never feature/x/overhaul main "$MBALLOWED")" = "allow" ]'
check "exception refuses under ask"                   '[ "$(mbase ask integration main "$MBALLOWED")" = "refuse" ]'
check "exception refuses under yolo"                  '[ "$(mbase yolo integration main "$MBALLOWED")" = "refuse" ]'
check "exception refuses under invalid"               '[ "$(mbase invalid integration main "$MBALLOWED")" = "refuse" ]'
check "exception refuses the default branch even when listed" '[ "$(mbase never main main "$(printf "main\nintegration")")" = "refuse" ]'
check "exception refuses an empty base"               '[ "$(mbase never "" main "$MBALLOWED")" = "refuse" ]'
check "exception refuses an empty list"               '[ "$(mbase never integration main "")" = "refuse" ]'
check "exception refuses a prefix of a listed base"   '[ "$(mbase never feature/x main "$MBALLOWED")" = "refuse" ]'
check "exception refuses a superstring of a listed base" '[ "$(mbase never feature/x/overhaul-2 main "$MBALLOWED")" = "refuse" ]'
check "exception refuses a whitespace base even when listed" '[ "$(mbase never "integration x" main "integration x")" = "refuse" ]'
check "exception refuses an empty default branch"     '[ "$(mbase never integration "" "$MBALLOWED")" = "refuse" ]'

echo "== merge-base exception: merge_allowed_bases registry field =="
mbread() { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_allowed_bases "$1" ); }
b dm-repo.sh set mauth merge_authority never >/dev/null
check "reader prints nothing when the field is absent" '[ -z "$(mbread mauth)" ]'
check "set merge_allowed_bases stores a csv as an array" 'b dm-repo.sh set mauth merge_allowed_bases "integration,feature/x/overhaul" >/dev/null 2>&1'
check "get prints the stored list" 'OUT="$(b dm-repo.sh get mauth merge_allowed_bases)"; grep -q "integration" <<<"$OUT" && grep -q "feature/x/overhaul" <<<"$OUT"'
check "reader prints one branch per line" '[ "$(mbread mauth)" = "$(printf "integration\nfeature/x/overhaul")" ]'
check "set rejects the default branch"           '! b dm-repo.sh set mauth merge_allowed_bases "main" >/dev/null 2>&1'
check "set rejects the default branch in a list" '! b dm-repo.sh set mauth merge_allowed_bases "integration,main" >/dev/null 2>&1'
check "set rejects a whitespace name"            '! b dm-repo.sh set mauth merge_allowed_bases "feature x" >/dev/null 2>&1'
check "set rejects an empty element"             '! b dm-repo.sh set mauth merge_allowed_bases "integration,,x" >/dev/null 2>&1'
# Pin the CSV space-after-comma behavior: " feature/x" is a whitespace-bearing
# name and is refused as such (no silent trimming).
check "csv space-after-comma is refused as whitespace" 'OUT="$(b dm-repo.sh set mauth merge_allowed_bases "integration, feature/x" 2>&1 || true)"; grep -q "whitespace" <<<"$OUT"'
check "a rejected set leaves the stored list intact" '[ "$(mbread mauth)" = "$(printf "integration\nfeature/x/overhaul")" ]'
# A hand-corrupted array grants nothing for its non-string entries: only the
# string ones survive the reader.
jq '.repos["mauth"].merge_allowed_bases = [123,"integration",null]' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "reader drops non-string entries in a corrupt array" '[ "$(mbread mauth)" = "integration" ]'
b dm-repo.sh set mauth merge_allowed_bases "integration,feature/x/overhaul" >/dev/null
# Reverse-direction write guard: a listed name can never become the default.
check "set default_branch refuses a listed name" '! b dm-repo.sh set mauth default_branch integration >/dev/null 2>&1'
MBDEFOUT="$(b dm-repo.sh set mauth default_branch integration 2>&1 || true)"
check "the reverse-guard refusal names merge_allowed_bases" 'grep -q "merge_allowed_bases" <<<"$MBDEFOUT"'
# An unset default_branch makes the default-exclusion guard a no-op, so the set
# is refused entirely (fail closed) with a pointer to set default_branch first.
cp "$REG" "$REG.bak"
jq 'del(.repos["mauth"].default_branch)' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
MBNODEF="$(b dm-repo.sh set mauth merge_allowed_bases "anything" 2>&1 || true)"
check "set refuses when default_branch is unset"            '! b dm-repo.sh set mauth merge_allowed_bases "anything" >/dev/null 2>&1'
check "the unset-default refusal points at default_branch"  'grep -q "default_branch" <<<"$MBNODEF"'
mv "$REG.bak" "$REG"
check "an empty value clears the field entirely" 'b dm-repo.sh set mauth merge_allowed_bases "" >/dev/null 2>&1 && jq -e ".repos[\"mauth\"] | has(\"merge_allowed_bases\") | not" "$REG" >/dev/null'
check "reader prints nothing after the clear"    '[ -z "$(mbread mauth)" ]'

echo "== merge-base exception: dm-pr.sh merge honors the LIVE PR base on a never repo =="
# Give this local fixture a GitHub-shaped, still-local origin: repo_slug resolves
# to o/r while fetches remain hermetic for post-merge sync.
mkdir -p "$DM_HOME/repos/mauth/o"
ln -s "$TMP/origin.git" "$DM_HOME/repos/mauth/o/r.git"
git -C "$DM_HOME/repos/mauth" remote set-url origin o/r.git
# Stub gh so the live-base read is deterministic and offline: PR-detail calls
# answer with pr.json (or pr2.json after the first read when "retarget" is
# armed, simulating a mid-merge base/head change), check-runs/status/ref calls
# answer with their matching fixture, and a "fail" marker makes gh exit non-zero.
# gh-axi records the attempted atomic mutation, then fails loudly, so reaching
# (or not reaching) the mutation is observable.
b dm-repo.sh set mauth merge_authority never >/dev/null
b dm-repo.sh set mauth merge_allowed_bases "integration" >/dev/null
b dm-task.sh new mauth-exc --kind ship --repo mauth >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set mauth-exc pr "https://github.com/o/r/pull/9" ) >/dev/null 2>&1
GHSTUB="$TMP/ghstub"; mkdir -p "$GHSTUB"
cat > "$GHSTUB/gh" <<STUB
#!/bin/sh
D="$GHSTUB"
printf '%s\n' "\$*" >> "\$D/gh-calls"
case "\$*" in
  *check-runs*) cat "\$D/runs.json"; exit 0 ;;
  *commits*status*) cat "\$D/status.json"; exit 0 ;;
  *git/ref/heads/*)
    [ -f "\$D/ref-fail" ] && exit 1
    [ -f "\$D/ref-invalid" ] && { printf 'not json\n'; exit 0; }
    cat "\$D/ref.json"; exit 0 ;;
esac
[ -f "\$D/fail" ] && exit 1
if [ -f "\$D/retarget" ]; then
  if [ -f "\$D/seen" ]; then cat "\$D/pr2.json"; exit 0; fi
  : > "\$D/seen"
fi
cat "\$D/pr.json"
STUB
printf '#!/bin/sh\n: > "%s/ghaxi-called"\nexit 1\n' "$GHSTUB" > "$GHSTUB/gh-axi"
chmod +x "$GHSTUB/gh" "$GHSTUB/gh-axi"
printf '{"total_count":0,"check_runs":[]}\n' > "$GHSTUB/runs.json"
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
printf '{"object":{"sha":"abc123"}}\n' > "$GHSTUB/ref.json"
printf '{"state":"open","merged":false,"base":{"ref":"integration","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}\n' > "$GHSTUB/pr.json"
EXCOUT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a listed live base passes the authority gate"        'grep -q "operator-granted merge base" <<<"$EXCOUT"'
check "downstream never-merge-red gate still applies"       'grep -qi "no checks reported" <<<"$EXCOUT"'
printf '{"state":"open","merged":false,"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}\n' > "$GHSTUB/pr.json"
check "a default-branch live base still hard-refuses"       '! PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc >/dev/null 2>&1'
DEFOUT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "the default-branch refusal names the unallowed base" 'grep -q "not an operator-granted merge base" <<<"$DEFOUT" && grep -q "main" <<<"$DEFOUT"'
printf '{"state":"open","merged":false,"base":{"ref":"integration-2","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}\n' > "$GHSTUB/pr.json"
check "an unlisted live base still hard-refuses"            '! PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc >/dev/null 2>&1'
printf 'not json\n' > "$GHSTUB/pr.json"
UNVEROUT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "an unverifiable live base fails closed"              'grep -q "could not be verified" <<<"$UNVEROUT"'
# gh itself failing (non-zero exit, no output) is distinct from garbage output;
# both refuse fail-closed.
: > "$GHSTUB/fail"
GHFAILOUT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a failing gh call fails closed"                      'grep -q "could not be verified" <<<"$GHFAILOUT"'
rm -f "$GHSTUB/fail"
# A response missing the live default branch refuses fail-closed too.
printf '{"state":"open","merged":false,"base":{"ref":"integration","repo":{}},"mergeable_state":"unknown"}\n' > "$GHSTUB/pr.json"
NOLIVEDEF="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a missing live default branch fails closed"          'grep -qi "live default branch could not be verified" <<<"$NOLIVEDEF"'

echo "== merge-base exception: live default anchor + pre-merge TOCTOU re-check =="
# Live-anchor belt-and-braces: the registry default is main, so "trunk" is
# listable — but when GitHub reports trunk as the repository's LIVE default, a
# trunk-based PR must still refuse (the live anchor wins over a drifted
# registry default).
b dm-repo.sh set mauth merge_allowed_bases "integration,trunk" >/dev/null
printf '{"state":"open","merged":false,"base":{"ref":"trunk","repo":{"default_branch":"trunk"}},"mergeable_state":"unknown"}\n' > "$GHSTUB/pr.json"
LIVEDEF="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a listed base that IS the live default still refuses" 'grep -q "not an operator-granted merge base" <<<"$LIVEDEF"'
# Full green path: passing checks + clean mergeable_state. The merge must clear
# every gate INCLUDING the pre-mutation re-verify, reach the gh-axi mutation
# (observable via the stub's marker), and fail only on the stub's exit 1.
b dm-repo.sh set mauth merge_allowed_bases "integration,integration2" >/dev/null
printf '{"total_count":1,"check_runs":[{"head_sha":"abc123","status":"completed","conclusion":"success"}]}\n' > "$GHSTUB/runs.json"
printf '{"state":"open","merged":false,"head":{"sha":"abc123","ref":"fix/head","repo":{"full_name":"o/r"}},"base":{"ref":"integration","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$GHSTUB/pr.json"
rm -f "$GHSTUB/ghaxi-called" "$GHSTUB/seen"
GREENOUT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a green listed-base merge reaches the merge mutation" '[ -f "$GHSTUB/ghaxi-called" ] && grep -q "atomic merge failed" <<<"$GREENOUT"'
# TOCTOU: the base is retargeted to the DEFAULT after the first verification —
# the pre-mutation re-check refuses and the mutation is never invoked.
rm -f "$GHSTUB/ghaxi-called" "$GHSTUB/seen"
printf '{"state":"open","merged":false,"head":{"sha":"abc123","ref":"fix/head","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$GHSTUB/pr2.json"
: > "$GHSTUB/retarget"
TOCTOU1="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a mid-merge retarget to the default refuses"           'grep -q "not an operator-granted merge base" <<<"$TOCTOU1"'
check "the retargeted merge never reaches the mutation"       '[ ! -f "$GHSTUB/ghaxi-called" ]'
# TOCTOU: retargeted to ANOTHER allowed branch — still refused (the base
# changed since verification), mutation never invoked.
rm -f "$GHSTUB/seen"
printf '{"state":"open","merged":false,"head":{"sha":"abc123","ref":"fix/head","repo":{"full_name":"o/r"}},"base":{"ref":"integration2","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$GHSTUB/pr2.json"
TOCTOU2="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "a retarget to another ALLOWED base still refuses"      'grep -q "base changed" <<<"$TOCTOU2"'
check "the allowed-retarget merge never reaches the mutation" '[ ! -f "$GHSTUB/ghaxi-called" ]'
rm -f "$GHSTUB/retarget" "$GHSTUB/seen"

echo "== merge-base exception: dm-merge.sh local has NO exception =="
# A never repo WITH allowed bases configured still hard-refuses a local land:
# local always targets the clone's default branch.
b dm-repo.sh set mauth merge_allowed_bases "integration" >/dev/null
b dm-task.sh new mauth-exc-local --kind ship --repo mauth --mode local-only >/dev/null
MELWT="$(b dm-worktree.sh create mauth-exc-local mauth | tail -n1)"
git -C "$MELWT" checkout -q -b feat/x/mauth-exc-local
printf 'z\n' > "$MELWT/excl.txt"
git -C "$MELWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$MELWT" -c user.email=c@c.co -c user.name=c commit -qm "excl work" >/dev/null
MELBEFORE="$(git -C "$DM_HOME/repos/mauth" rev-parse main)"
check "local land still refuses a never repo with allowed bases" '! b dm-merge.sh local mauth-exc-local >/dev/null 2>&1'
MELOUT="$(b dm-merge.sh local mauth-exc-local 2>&1 || true)"
check "the local refusal still names merge_authority=never"      'grep -q "merge_authority=never" <<<"$MELOUT"'
check "the local refusal did not advance the clone"              '[ "$(git -C "$DM_HOME/repos/mauth" rev-parse main)" = "$MELBEFORE" ]'
b dm-worktree.sh remove mauth-exc-local --force >/dev/null 2>&1

# With NO merge_allowed_bases configured the refusal is unchanged from today:
# offline, before any GitHub tool, naming merge_authority=never — no carve-out
# mentioned.
b dm-repo.sh set mauth merge_allowed_bases "" >/dev/null
NOEXC="$(b dm-pr.sh merge mauth-exc 2>&1 || true)"
check "the no-list never refusal is unchanged"              'grep -q "merge_authority=never" <<<"$NOEXC" && grep -qi "operator merges" <<<"$NOEXC"'
check "the no-list refusal does not mention the carve-out"  '! grep -q "merge_allowed_bases" <<<"$NOEXC"'

echo "== discarded terminal state (operator discard, issue #69) =="
b dm-repo.sh add disctest "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new disc-1 --kind ship --repo disctest >/dev/null
DWT="$(b dm-worktree.sh create disc-1 disctest | tail -n1)"
git -C "$DWT" checkout -q -b feat/x/disc-1
printf 'w\n' > "$DWT/disc.txt"
git -C "$DWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$DWT" -c user.email=c@c.co -c user.name=c commit -qm "disc work" >/dev/null
check "event refuses to forge 'discarded'"       '! b dm-task.sh event disc-1 discarded x >/dev/null 2>&1'
check "plain remove still refuses unlanded"      '! b dm-worktree.sh remove disc-1 >/dev/null 2>&1'
check "archive refuses while work is live"       '! b dm-task.sh archive disc-1 >/dev/null 2>&1'
b dm-worktree.sh remove disc-1 --force >/dev/null 2>&1
check "force-remove records terminal discarded"  'OUT="$(b dm-task.sh state disc-1)"; grep -q "^state: discarded" <<<"$OUT"'
check "archive accepts a discarded task"         'b dm-task.sh archive disc-1 >/dev/null'
check "repo remove passes over a discarded task" 'b dm-repo.sh remove disctest >/dev/null 2>&1'
# A scout worktree is scratch: force-removing it must NOT brand the task discarded.
b dm-task.sh new disc-sc --kind scout --repo demo >/dev/null
b dm-worktree.sh create disc-sc demo >/dev/null
b dm-worktree.sh remove disc-sc --force >/dev/null 2>&1
check "scout force-remove records no discard"    'OUT="$(b dm-task.sh state disc-sc)"; ! grep -q discarded <<<"$OUT"'

echo
echo "== await-checks head-race guards (#75) =="
b dm-task.sh new await-75 --kind ship --repo mauth >/dev/null
AWT="$(b dm-worktree.sh create await-75 mauth | tail -n1)"
git -C "$AWT" checkout -q -b fix/await-75
AWHEAD="$(git -C "$AWT" rev-parse HEAD)"
OLDHEAD="1111111111111111111111111111111111111111"
CHANGEDHEAD="2222222222222222222222222222222222222222"
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set await-75 pr "https://github.com/o/r/pull/75" ) >/dev/null 2>&1
mkdir -p "$DM_HOME/repos/mauth/.github/workflows"
printf '{"object":{"sha":"%s"}}\n' "$AWHEAD" > "$GHSTUB/ref.json"
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"dirty"}\n' "$AWHEAD" > "$GHSTUB/pr.json"
printf '{"total_count":0,"check_runs":[]}\n' > "$GHSTUB/runs.json"
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
AWDIRTY="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 120 --interval-secs 1 2>&1 || true)"
check "dirty PR fails fast, no timeout wait"   'grep -q "DIRTY" <<<"$AWDIRTY" && grep -q "after 0s" <<<"$AWDIRTY"'
check "dirty fast-fail is non-zero"            '! PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 >/dev/null 2>&1'

# A stale PR response can still name the previous head and its real terminal
# run. The independent worktree head must keep that rollup non-terminal.
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}\n' "$OLDHEAD" > "$GHSTUB/pr.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$OLDHEAD" > "$GHSTUB/runs.json"
AWSTALE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "old-head green is not trusted as terminal" 'grep -q "has not reached expected head" <<<"$AWSTALE" && grep -q "last rollup: pending" <<<"$AWSTALE"'

# A real not-yet-registered response has both count zero and an empty array.
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}\n' "$AWHEAD" > "$GHSTUB/pr.json"
printf '{"total_count":0,"check_runs":[]}\n' > "$GHSTUB/runs.json"
AWNONE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "consistent zero-run response remains non-terminal" 'grep -q "last rollup: none" <<<"$AWNONE" && ! grep -q "passing" <<<"$AWNONE"'

# One maximal page is bounded, but it is trusted only when total_count proves
# the returned array is complete.
printf '{"total_count":2,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$AWHEAD" > "$GHSTUB/runs.json"
AWTRUNCATED="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "truncated check-runs cannot produce green" 'grep -q "last rollup: unknown" <<<"$AWTRUNCATED" && ! grep -q "passing after" <<<"$AWTRUNCATED"'
check "check-runs requests the bounded maximum page" 'grep -q "check-runs?per_page=100" "$GHSTUB/gh-calls"'

# Passing is allowlist-based. Every documented failure class fails, while a
# completed null/future conclusion is unknown rather than accidental green.
printf '{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"neutral"},{"status":"completed","conclusion":"skipped"}]}\n' > "$GHSTUB/runs.json"
AWALLOWED="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1)"
check "only allowlisted completed conclusions pass" 'grep -q "passing after 0s" <<<"$AWALLOWED"'
printf '{"total_count":5,"check_runs":[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"cancelled"},{"status":"completed","conclusion":"timed_out"},{"status":"completed","conclusion":"action_required"},{"status":"completed","conclusion":"startup_failure"}]}\n' > "$GHSTUB/runs.json"
AWFAILURES="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "all documented failure conclusions fail" 'grep -q "FAILING after 0s" <<<"$AWFAILURES"'
printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":null}]}\n' > "$GHSTUB/runs.json"
AWNULL="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "completed null conclusion is unknown" 'grep -q "last rollup: unknown" <<<"$AWNULL" && ! grep -q "passing after" <<<"$AWNULL"'
printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"future_result"}]}\n' > "$GHSTUB/runs.json"
AWFUTURE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "future conclusion is unknown" 'grep -q "last rollup: unknown" <<<"$AWFUTURE" && ! grep -q "passing after" <<<"$AWFUTURE"'
printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"stale"}]}\n' > "$GHSTUB/runs.json"
AWSTALERUN="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "stale conclusion remains pending" 'grep -q "last rollup: pending" <<<"$AWSTALERUN"'

# Legacy commit statuses remain first-class CI signals even when there are no
# check-runs and the repository also has workflow configuration.
printf '{"total_count":0,"check_runs":[]}\n' > "$GHSTUB/runs.json"
printf '{"total_count":1,"state":"success"}\n' > "$GHSTUB/status.json"
AWSTATUSOK="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1)"
check "status-only success passes immediately" 'grep -q "passing after 0s" <<<"$AWSTATUSOK"'
printf '{"total_count":1,"state":"failure"}\n' > "$GHSTUB/status.json"
AWSTATUSBAD="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "status-only failure fails immediately" 'grep -q "FAILING after 0s" <<<"$AWSTATUSBAD" && ! grep -q "TIMED OUT" <<<"$AWSTATUSBAD"'

# Terminal state requires both local HEAD and the live head ref. Stale PR/check
# data matching local HEAD is still unsafe when another actor pushed the ref.
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$AWHEAD" > "$GHSTUB/runs.json"
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
printf '{"object":{"sha":"%s"}}\n' "$CHANGEDHEAD" > "$GHSTUB/ref.json"
AWDIVERGED="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "remote advance defeats stale local-and-PR green" 'grep -q "could not reconcile" <<<"$AWDIVERGED" && grep -q "last rollup: unknown" <<<"$AWDIVERGED" && ! grep -q "passing after" <<<"$AWDIVERGED"'

printf '{"object":{"sha":"%s"}}\n' "$AWHEAD" > "$GHSTUB/ref.json"
: > "$GHSTUB/ref-fail"
AWREFFAIL="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "ref API failure keeps terminal CI unknown" 'grep -q "could not reconcile" <<<"$AWREFFAIL" && grep -q "last rollup: unknown" <<<"$AWREFFAIL"'
rm -f "$GHSTUB/ref-fail"
: > "$GHSTUB/ref-invalid"
AWREFJSON="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "invalid ref JSON keeps terminal CI unknown" 'grep -q "could not reconcile" <<<"$AWREFJSON" && grep -q "last rollup: unknown" <<<"$AWREFJSON"'
rm -f "$GHSTUB/ref-invalid"

# A failed refresh after a previously-dirty result must be reported as unknown,
# never by reusing the cached dirty state.
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"dirty"}\n' "$AWHEAD" > "$GHSTUB/pr.json"
PATH="$GHSTUB:$PATH" b dm-pr.sh check await-75 >/dev/null
: > "$GHSTUB/fail"
AWFAIL="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "refresh API failure stays visible and unknown" 'grep -q "refresh failed" <<<"$AWFAIL" && grep -q "last rollup: unknown" <<<"$AWFAIL" && ! grep -q "DIRTY" <<<"$AWFAIL"'
rm -f "$GHSTUB/fail"
printf 'not json\n' > "$GHSTUB/pr.json"
AWPARSE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
check "refresh parse failure stays visible and unknown" 'grep -q "refresh failed" <<<"$AWPARSE" && grep -q "last rollup: unknown" <<<"$AWPARSE"'

# A merge requires a positively-confirmed OPEN state; UNKNOWN is not a softer
# form of open and must stop before mutation.
b dm-repo.sh set mauth merge_authority ask >/dev/null
printf '{"object":{"sha":"%s"}}\n' "$AWHEAD" > "$GHSTUB/ref.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$AWHEAD" > "$GHSTUB/runs.json"
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
printf '{"state":"unknown","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' "$AWHEAD" > "$GHSTUB/pr.json"
rm -f "$GHSTUB/ghaxi-called"
AWUNKNOWN="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge await-75 2>&1 || true)"
check "UNKNOWN PR state refuses before mutation" 'grep -q "not confirmed OPEN (UNKNOWN)" <<<"$AWUNKNOWN" && [ ! -f "$GHSTUB/ghaxi-called" ]'

echo "== check snapshot is bound to its invoking refresh =="
cp "$GHSTUB/gh" "$GHSTUB/gh-normal"
cat > "$GHSTUB/old-pr.json" <<EOF
{"state":"open","merged":false,"head":{"sha":"$OLDHEAD","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"unknown"}
EOF
cat > "$GHSTUB/new-pr.json" <<EOF
{"state":"open","merged":false,"head":{"sha":"$AWHEAD","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}
EOF
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$OLDHEAD" > "$GHSTUB/old-runs.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$AWHEAD" > "$GHSTUB/new-runs.json"
cat > "$GHSTUB/gh" <<STUB
#!/bin/sh
D="$GHSTUB"
case "\$*" in
  *pulls/75*)
    if mkdir "\$D/old-claim" 2>/dev/null; then cat "\$D/old-pr.json"; else cat "\$D/new-pr.json"; fi
    ;;
  *commits/$OLDHEAD/check-runs*)
    : > "\$D/old-runs-entered"
    i=0
    while [ ! -f "\$D/release-old" ] && [ "\$i" -lt 200 ]; do sleep 0.01; i=\$((i + 1)); done
    [ -f "\$D/release-old" ] || exit 1
    cat "\$D/old-runs.json"
    ;;
  *commits/$AWHEAD/check-runs*) cat "\$D/new-runs.json" ;;
  *commits*status*) cat "\$D/status.json" ;;
  *git/ref/heads/*) cat "\$D/ref.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHSTUB/gh"
rm -rf "$GHSTUB/old-claim" "$GHSTUB/old-runs-entered" "$GHSTUB/release-old"
PATH="$GHSTUB:$PATH" b dm-pr.sh check await-75 --snapshot > "$GHSTUB/old-snapshot" 2> "$GHSTUB/old-error" &
OLD_CHECK_PID=$!
for _ in $(seq 1 200); do [ -f "$GHSTUB/old-runs-entered" ] && break; sleep 0.01; done
check "older refresh is paused after reading old PR data" '[ -f "$GHSTUB/old-runs-entered" ]'
AWCONCURRENT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1 || true)"
: > "$GHSTUB/release-old"
OLD_CHECK_STATUS=0
wait "$OLD_CHECK_PID" || OLD_CHECK_STATUS=$?
check "newer caller uses its own green snapshot" 'grep -q "passing after 0s" <<<"$AWCONCURRENT"'
check "older refresh completed after the newer caller" '[ "$OLD_CHECK_STATUS" -eq 0 ]'
check "older cache overwrite did not contaminate newer caller" '[ "$(b dm-task.sh get await-75 pr_check_snapshot | jq -r .head)" = "$OLDHEAD" ]'
mv "$GHSTUB/gh-normal" "$GHSTUB/gh"
chmod +x "$GHSTUB/gh"

echo "== atomic SHA-conditioned merge and safe branch cleanup =="
cat > "$GHSTUB/gh-axi" <<STUB
#!/bin/sh
D="$GHSTUB"
printf '%s\n' "\$*" >> "\$D/axi-calls"
if [ "\${1:-}" = api ] && [ "\${2:-}" = PUT ]; then
  printf 'merge\n' >> "\$D/axi-events"
  if [ -f "\$D/conflict" ]; then printf 'HTTP 409 Conflict\n' >&2; exit 1; fi
  [ -f "\$D/advance-on-merge" ] && : > "\$D/remote-advanced"
  printf 'merged: true\n'
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "\$*" >&2
exit 1
STUB
chmod +x "$GHSTUB/gh-axi"
REAL_GIT="$(command -v git)"
cat > "$GHSTUB/git" <<STUB
#!/bin/sh
D="$GHSTUB"
if [ "\${1:-}" = -C ] && [ "\${3:-}" = push ]; then
  printf '%s|%s|%s\n' "\${4:-}" "\${5:-}" "\${6:-}" >> "\$D/git-push-calls"
  if [ -f "\$D/remote-advanced" ]; then
    printf 'lease-rejected\n' >> "\$D/axi-events"
    printf 'rejected: stale info\n' >&2
    exit 1
  fi
  printf 'lease-delete\n' >> "\$D/axi-events"
  exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$GHSTUB/git"
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/await-75","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"has_hooks"}\n' "$AWHEAD" > "$GHSTUB/pr.json"
printf '{"object":{"sha":"%s"}}\n' "$AWHEAD" > "$GHSTUB/ref.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$AWHEAD" > "$GHSTUB/runs.json"
printf '{"total_count":0}\n' > "$GHSTUB/status.json"
HASHOOKSCHECK="$(PATH="$GHSTUB:$PATH" b dm-pr.sh check await-75 2>&1)"
check "has_hooks is accepted by check" 'grep -q "merge_state: has_hooks" <<<"$HASHOOKSCHECK"'
HASHOOKSAWAIT="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks await-75 --timeout-secs 0 --interval-secs 1 2>&1)"
check "has_hooks permits green await-checks" 'grep -q "passing after 0s" <<<"$HASHOOKSAWAIT"'
rm -f "$GHSTUB/axi-calls" "$GHSTUB/axi-events" "$GHSTUB/git-push-calls"
: > "$GHSTUB/conflict"
AW409="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge await-75 --method rebase --delete-branch 2>&1 || true)"
check "has_hooks merge reaches SHA-conditioned mutation" 'grep -Fx "api PUT /repos/o/r/pulls/75/merge --field sha=$AWHEAD --field merge_method=rebase" "$GHSTUB/axi-calls" >/dev/null'
check "atomic 409 remains a visible refusal" 'grep -q "atomic merge failed" <<<"$AW409" && grep -q "409 Conflict" <<<"$AW409"'
check "409 records no merged state or event" '[ "$(b dm-task.sh get await-75 pr_state)" = "OPEN" ] && ! grep -q " merged: https://github.com/o/r/pull/75" "$DM_HOME/state/tasks/await-75.status"'
check "409 performs no branch deletion" '[ ! -s "$GHSTUB/git-push-calls" ]'

rm -f "$GHSTUB/conflict" "$GHSTUB/axi-calls" "$GHSTUB/axi-events" "$GHSTUB/git-push-calls"
AWSUCCESS="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge await-75 --method rebase --delete-branch 2>&1)"
check "successful atomic merge records landed state" '[ "$(b dm-task.sh get await-75 pr_state)" = "MERGED" ] && grep -q " merged: https://github.com/o/r/pull/75" "$DM_HOME/state/tasks/await-75.status"'
check "same-repo cleanup happens only after merge" '[ "$(sed -n "1p" "$GHSTUB/axi-events")" = merge ] && [ "$(sed -n "2p" "$GHSTUB/axi-events")" = lease-delete ]'
check "slash branch deletion uses exact conditional lease" 'grep -Fx "origin|--force-with-lease=refs/heads/fix/await-75:$AWHEAD|:refs/heads/fix/await-75" "$GHSTUB/git-push-calls" >/dev/null'
check "successful cleanup is reported" 'grep -q "deleted merged branch: fix/await-75" <<<"$AWSUCCESS"'

echo "== branch advance after merge is rejected by server lease =="
RACEHEAD="4444444444444444444444444444444444444444"
b dm-task.sh new cleanup-race --kind ship --repo mauth >/dev/null
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"fix/race","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' "$RACEHEAD" > "$GHSTUB/pr.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$RACEHEAD" > "$GHSTUB/runs.json"
printf '{"object":{"sha":"%s"}}\n' "$RACEHEAD" > "$GHSTUB/ref.json"
PATH="$GHSTUB:$PATH" b dm-pr.sh adopt cleanup-race "https://github.com/o/r/pull/77" >/dev/null
rm -f "$GHSTUB/axi-calls" "$GHSTUB/axi-events" "$GHSTUB/git-push-calls" "$GHSTUB/remote-advanced"
: > "$GHSTUB/advance-on-merge"
RACEMERGE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge cleanup-race --delete-branch 2>&1)"
check "advanced branch lease rejects deletion" 'grep -q "lease-rejected" "$GHSTUB/axi-events" && grep -q "stale info" <<<"$RACEMERGE"'
check "lease rejection preserves successful merge" '[ "$(b dm-task.sh get cleanup-race pr_state)" = "MERGED" ] && grep -q " merged: https://github.com/o/r/pull/77" "$DM_HOME/state/tasks/cleanup-race.status"'
check "advanced branch uses checked SHA as exact lease" 'grep -Fx "origin|--force-with-lease=refs/heads/fix/race:$RACEHEAD|:refs/heads/fix/race" "$GHSTUB/git-push-calls" >/dev/null'
check "lease failure is a visible post-merge warning" 'grep -q "warning: branch cleanup failed after merge" <<<"$RACEMERGE"'
rm -f "$GHSTUB/advance-on-merge" "$GHSTUB/remote-advanced"

echo "== adopted fork PR resolves live fork ref and never deletes it =="
FORKHEAD="3333333333333333333333333333333333333333"
b dm-task.sh new adopted-fork --kind ship --repo mauth >/dev/null
printf '{"state":"open","merged":false,"head":{"sha":"%s","ref":"feature/nested/head","repo":{"full_name":"forker/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' "$FORKHEAD" > "$GHSTUB/pr.json"
printf '{"total_count":1,"check_runs":[{"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$FORKHEAD" > "$GHSTUB/runs.json"
printf '{"object":{"sha":"%s"}}\n' "$FORKHEAD" > "$GHSTUB/ref.json"
PATH="$GHSTUB:$PATH" b dm-pr.sh adopt adopted-fork "https://github.com/o/r/pull/76" >/dev/null
check "adopted PR has no worktree dependency" '[ -z "$(b dm-task.sh get adopted-fork worktree)" ]'
rm -f "$GHSTUB/axi-calls" "$GHSTUB/axi-events" "$GHSTUB/gh-calls" "$GHSTUB/git-push-calls"
FORKMERGE="$(PATH="$GHSTUB:$PATH" b dm-pr.sh merge adopted-fork --method squash --delete-branch 2>&1)"
check "adopted PR merges through base-repo endpoint" 'grep -Fx "api PUT /repos/o/r/pulls/76/merge --field sha=$FORKHEAD --field merge_method=squash" "$GHSTUB/axi-calls" >/dev/null'
check "fork head ref with slashes is resolved encoded" 'grep -q "repos/forker/r/git/ref/heads/feature%2Fnested%2Fhead" "$GHSTUB/gh-calls"'
check "fork branch is never deleted" '[ ! -s "$GHSTUB/git-push-calls" ] && grep -q "head belongs to fork forker/r" <<<"$FORKMERGE"'
rm -rf "$DM_HOME/repos/mauth/.github"

echo "== runtime parity + performance guards =="
check "runtime parity suite passes" 'node "$ROOT/tests/check-runtime-parity.js" >/dev/null'
EVIDENCE_PARENT="$TMP/evidence-parent"
mkdir -m 700 "$EVIDENCE_PARENT"
printf 'untouched\n' > "$TMP/evidence-victim"
ln -s "$TMP/evidence-victim" "$EVIDENCE_PARENT/codex-version.txt"
EVIDENCE_ONE="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_PARENT")"
EVIDENCE_TWO="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_PARENT")"
check "runtime evidence uses unique private children" '[ "$EVIDENCE_ONE" != "$EVIDENCE_TWO" ] && [ ! -L "$EVIDENCE_ONE" ] && [ "$(file_mode "$EVIDENCE_ONE")" = 700 ]'
SAFE_EVIDENCE="$("$ROOT/tests/runtime-evidence-dir.sh" reserve "$EVIDENCE_ONE" codex-version.txt)"
check "runtime evidence files are private regular files" '[ -f "$SAFE_EVIDENCE" ] && [ ! -L "$SAFE_EVIDENCE" ] && [ "$(file_mode "$SAFE_EVIDENCE")" = 600 ]'
ln -s "$TMP/evidence-victim" "$EVIDENCE_ONE/attacker.json"
check "runtime evidence refuses fixed-file symlinks" '! "$ROOT/tests/runtime-evidence-dir.sh" reserve "$EVIDENCE_ONE" attacker.json >/dev/null 2>&1 && grep -Fx untouched "$TMP/evidence-victim" >/dev/null'
ln -s "$EVIDENCE_PARENT" "$TMP/evidence-root-link"
check "runtime evidence refuses symlink roots" '! "$ROOT/tests/runtime-evidence-dir.sh" create "$TMP/evidence-root-link" >/dev/null 2>&1'
RETENTION_PARENT="$TMP/runtime-retention"
mkdir -m 700 "$RETENTION_PARENT"
RETENTION_OUT="$(DM_RUNTIME_EVIDENCE_DIR="$RETENTION_PARENT" DM_RUNTIME_SMOKE_TEST_ONLY=1 DM_RUNTIME_SMOKE_FIXTURE_SECRET=super-secret bash "$ROOT/tests/runtime-smoke.sh")"
check "non-live runtime smoke cleans evidence by default" 'grep -q "evidence cleaned" <<<"$RETENTION_OUT" && [ -z "$(find "$RETENTION_PARENT" -mindepth 1 -maxdepth 1 -print -quit)" ]'
KEEP_OUT="$(DM_RUNTIME_EVIDENCE_DIR="$RETENTION_PARENT" DM_RUNTIME_SMOKE_TEST_ONLY=1 DM_RUNTIME_SMOKE_FIXTURE_SECRET=super-secret bash "$ROOT/tests/runtime-smoke.sh" --keep-evidence)"
KEEP_DIR="${KEEP_OUT##*evidence retained: }"
check "explicit keep reports private retained location" '[ -d "$KEEP_DIR" ] && [ "$(file_mode "$KEEP_DIR")" = 700 ] && grep -q "evidence retained:" <<<"$KEEP_OUT"'
KEEP_BAD_MODE=0
while IFS= read -r evidence_path; do
  [ "$(file_mode "$evidence_path")" = 600 ] || KEEP_BAD_MODE=$((KEEP_BAD_MODE + 1))
done < <(find "$KEEP_DIR" -type f)
check "retained evidence is sanitized and mode 600" '! grep -R "super-secret" "$KEEP_DIR" >/dev/null 2>&1 && [ "$KEEP_BAD_MODE" = 0 ]'
rm -rf "$KEEP_DIR"
check "early runtime-smoke failure cleans by default" '! DM_RUNTIME_EVIDENCE_DIR="$RETENTION_PARENT" DM_RUNTIME_SMOKE_TEST_ONLY=1 DM_RUNTIME_SMOKE_FAIL_AFTER_EVIDENCE=1 bash "$ROOT/tests/runtime-smoke.sh" >/dev/null 2>&1 && [ -z "$(find "$RETENTION_PARENT" -mindepth 1 -maxdepth 1 -print -quit)" ]'
FAIL_KEEP_OUT="$(DM_RUNTIME_EVIDENCE_DIR="$RETENTION_PARENT" DM_RUNTIME_SMOKE_TEST_ONLY=1 DM_RUNTIME_SMOKE_FAIL_AFTER_EVIDENCE=1 bash "$ROOT/tests/runtime-smoke.sh" --keep-evidence 2>&1 || true)"
FAIL_KEEP_DIR="${FAIL_KEEP_OUT##*evidence retained: }"
check "explicit keep is required to retain failed-run evidence" '[ -d "$FAIL_KEEP_DIR" ] && grep -q "evidence retained:" <<<"$FAIL_KEEP_OUT"'
check "failed retained evidence removes raw secrets" '! grep -R "session-secret" "$FAIL_KEEP_DIR" >/dev/null 2>&1 && ! find "$FAIL_KEEP_DIR" -type f -name "*.raw*" | grep -q .'
rm -rf "$FAIL_KEEP_DIR"
check "runtime performance guard passes" 'node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
PARITY_FIXTURE="$TMP/runtime-parity"
mkdir -p "$PARITY_FIXTURE"
copy_parity_input() {
  local relative="$1"
  mkdir -p "$PARITY_FIXTURE/$(dirname "$relative")"
  cp "$ROOT/$relative" "$PARITY_FIXTURE/$relative"
}
for relative in AGENTS.md CLAUDE.md config/runtime-capabilities.json \
  config/runtime-performance-baseline.json docs/runtime-capabilities.md \
  .codex/config.toml .claude/settings.json; do
  copy_parity_input "$relative"
done
while IFS= read -r relative; do copy_parity_input "$relative"; done < <(
  jq -r '.capabilities[].evidence[]' "$ROOT/config/runtime-capabilities.json" | sort -u
)
while IFS= read -r skill; do
  copy_parity_input ".claude/skills/$skill/SKILL.md"
  copy_parity_input ".agents/skills/$skill/SKILL.md"
done < <(jq -r '.skills[]' "$ROOT/config/runtime-capabilities.json")
check "runtime fixture excludes repository and private state" \
  '[ ! -e "$PARITY_FIXTURE/.git" ] && [ ! -e "$PARITY_FIXTURE/state" ] && [ ! -e "$PARITY_FIXTURE/repos" ] && [ ! -e "$PARITY_FIXTURE/data" ] && [ ! -e "$PARITY_FIXTURE/.env" ]'
rm "$PARITY_FIXTURE/.agents/skills/rollback/SKILL.md"
check "runtime parity fails on a missing Codex skill" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/check-runtime-parity.js" >/dev/null 2>&1'
cp "$ROOT/.agents/skills/rollback/SKILL.md" "$PARITY_FIXTURE/.agents/skills/rollback/SKILL.md"
WAKE_SKILL="$PARITY_FIXTURE/.agents/skills/change-review/SKILL.md"
sed 's/spawn_agent/command_session/g' "$WAKE_SKILL" > "$WAKE_SKILL.tmp"
mv "$WAKE_SKILL.tmp" "$WAKE_SKILL"
check "runtime parity fails when Codex Lavish loses its mailbox wake" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/check-runtime-parity.js" >/dev/null 2>&1'
cp "$ROOT/.agents/skills/change-review/SKILL.md" "$WAKE_SKILL"
DISPATCH_SKILL="$PARITY_FIXTURE/.agents/skills/task-lifecycle/SKILL.md"
sed 's/at most three/at most four/' "$DISPATCH_SKILL" > "$DISPATCH_SKILL.tmp"
mv "$DISPATCH_SKILL.tmp" "$DISPATCH_SKILL"
check "runtime parity fails a capability-specific dispatch mutation" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/check-runtime-parity.js" >/dev/null 2>&1'
cp "$ROOT/.agents/skills/task-lifecycle/SKILL.md" "$DISPATCH_SKILL"
CLAUDE_TASK="$PARITY_FIXTURE/.claude/skills/task-lifecycle/SKILL.md"
sed 's/run in background/run on background/' "$CLAUDE_TASK" > "$CLAUDE_TASK.tmp"
check "same-size Claude mutation preserves byte count" \
  '[ "$(wc -c < "$CLAUDE_TASK")" -eq "$(wc -c < "$CLAUDE_TASK.tmp")" ]'
mv "$CLAUDE_TASK.tmp" "$CLAUDE_TASK"
check "runtime performance guard fails on same-size Claude mutation" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
cp "$ROOT/.claude/skills/task-lifecycle/SKILL.md" "$CLAUDE_TASK"
printf '%03000d\n' 0 >> "$PARITY_FIXTURE/AGENTS.md"
check "runtime performance guard fails on instruction bloat" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

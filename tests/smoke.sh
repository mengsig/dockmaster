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

SELF="${BASH_SOURCE[0]}"
# SMOKE_ROOT is set only by the slicer below, whose sliced copy lives outside the
# repo and so cannot derive the repo root from its own path.
ROOT="${SMOKE_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"

# --- shards -------------------------------------------------------------------
# The suite is one linear script over one $DM_HOME: later sections assert on
# state earlier ones built. So a shard is a CONTIGUOUS group of sections,
# delimited by the `# shard:split` marker lines further down, and `--shard k/n`
# SLICES the file rather than skipping at runtime — a check's body is where the
# subprocess spawns are, so skipping the assertion alone buys almost nothing.
# Sections marked `# shard:bootstrap` build fixtures LATER groups need: they run
# again in every shard after their own, but only the shard that owns them counts
# their checks, so the shards' pass counts sum to the sequential total.
# Adding a section needs no bookkeeping — it joins whichever group encloses it.
#
#   --shards          how many shards this file has
#   --shard k/n       run group k
#   --shard-plan k/n  print that slice instead of running it
#   --shard-plan      prove the groups PARTITION the suite (the `fast` CI job)
shard_usage() { echo "usage: smoke.sh --shard|--shard-plan <k>/<n>" >&2; exit 2; }

# shard_slice <k> -- group k's sections on stdout, wrapped in the prelude and the
# `# shard:epilogue` tail. `shard_owned_sections` is emitted as a CONSTANT rather
# than counted at run time: sections inside a conditional skip (the node-less
# verify block) are still owned, and the partition check has to stay exact.
shard_slice() {
  awk -v K="$1" '
    /^# shard:epilogue$/ { epi = 1; printf "shard_owned_sections=%d\n", owned }
    epi { print; next }
    /^# shard:split$/ { group++; next }
    /^# shard:bootstrap$/ { boot = 1; next }
    /^echo "== / {
      insec = 1; keep = (group == K || (boot && K > group)); own = (group == K); boot = 0
      if (own) owned++
      if (keep) printf "_shard_sec %d\n", own
    }
    { if (!insec || keep) print }
    BEGIN { group = 1 }
  ' "$SELF"
}

case "${1:-}" in
  --shards|--shard|--shard-plan)
    SHARD_TOTAL=$(grep -c '^# shard:split$' "$SELF" || true)
    SHARD_TOTAL=$((SHARD_TOTAL + 1))
    # Everything after that marker is in EVERY slice, and it is what carries the
    # verdict (`[ "$fail" -eq 0 ]`). Lose the marker and a red shard exits 0.
    grep -q '^# shard:epilogue$' "$SELF" \
      || { echo "smoke.sh: no '# shard:epilogue' marker; the slices would carry no verdict" >&2; exit 2; }
    ;;
  # No args is the sequential run. A MISSPELLED flag is not: without this it
  # would fall through and quietly run all 168 sections as if nothing was asked.
  --*) echo "smoke.sh: unknown flag: $1" >&2; shard_usage ;;
esac

if [ "${1:-}" = "--shards" ]; then printf '%s\n' "$SHARD_TOTAL"; exit 0; fi

# The groups must PARTITION the suite: every section owned by exactly one shard.
# A marker moved so a group is orphaned costs nothing at run time — those
# sections simply never run, and every shard is green.
if [ "${1:-}" = "--shard-plan" ] && [ -z "${2:-}" ]; then
  SHARD_ALL_SECTIONS=$(grep -c '^echo "== ' "$SELF" || true)
  shard_seen=0
  shard_k=1
  while [ "$shard_k" -le "$SHARD_TOTAL" ]; do
    shard_plan="$(shard_slice "$shard_k")"
    printf '%s\n' "$shard_plan" | grep -qxF '[ "$fail" -eq 0 ]' \
      || { echo "smoke.sh: shard $shard_k/$SHARD_TOTAL carries no verdict line" >&2; exit 1; }
    shard_seen=$((shard_seen + $(printf '%s\n' "$shard_plan" | grep -c '^_shard_sec 1$' || true)))
    shard_k=$((shard_k + 1))
  done
  [ "$shard_seen" -eq "$SHARD_ALL_SECTIONS" ] \
    || { echo "smoke.sh: the $SHARD_TOTAL shards own $shard_seen sections, the suite has $SHARD_ALL_SECTIONS" >&2; exit 1; }
  echo "ok   $SHARD_TOTAL shards partition all $SHARD_ALL_SECTIONS sections, each carrying its verdict"
  exit 0
fi

if [ "${1:-}" = "--shard" ] || [ "${1:-}" = "--shard-plan" ]; then
  SHARD_SPEC="${2:-}"
  case "$SHARD_SPEC" in */*) ;; *) shard_usage ;; esac
  SHARD_K="${SHARD_SPEC%%/*}"; SHARD_N="${SHARD_SPEC#*/}"
  # Each half on its own, so `1/2/6` (n = "2/6") and `/6` (k = "") are refused
  # here instead of reaching the range test as a bare-word integer error.
  case "$SHARD_K" in ''|*[!0-9]*) shard_usage ;; esac
  case "$SHARD_N" in ''|*[!0-9]*) shard_usage ;; esac
  # The split count is a property of the FILE, so a stale caller (a CI matrix
  # that was not updated with the markers) must fail loudly, not silently run
  # the wrong slice or drop sections on the floor.
  [ "$SHARD_N" = "$SHARD_TOTAL" ] || { echo "smoke.sh: this suite has $SHARD_TOTAL shards, not $SHARD_N" >&2; exit 2; }
  [ "$SHARD_K" -le "$SHARD_TOTAL" ] && [ "$SHARD_K" -ge 1 ] || { echo "smoke.sh: shard $SHARD_K is outside 1..$SHARD_TOTAL" >&2; exit 2; }
  if [ "${1:-}" = "--shard-plan" ]; then shard_slice "$SHARD_K"; exit 0; fi
  SMOKE_SLICE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dm-smoke-slice.XXXXXX")"
  # Own it from the moment it exists, or a failed slice write leaks it. `exec`
  # replaces this shell without running EXIT traps, so the trap does not follow
  # the slice into its own run — the slice re-arms it from $SMOKE_SLICE_DIR.
  trap 'rm -rf "$SMOKE_SLICE_DIR"' EXIT
  shard_slice "$SHARD_K" > "$SMOKE_SLICE_DIR/smoke.sh"
  export SMOKE_ROOT="$ROOT" SMOKE_SLICE_DIR SMOKE_SHARD="$SHARD_K/$SHARD_TOTAL"
  # $BASH, not a PATH lookup: on macOS the caller is /bin/bash 3.2 while `bash`
  # resolves to Homebrew 5, so the slice would silently stop testing 3.2.
  exec "${BASH:-bash}" "$SMOKE_SLICE_DIR/smoke.sh"
fi

# Canonicalize the temp root so DM_HOME and every path derived from it are
# PHYSICAL. dm-lib canonicalizes DM_HOME (pwd -P) and git records worktree paths
# physically, so a symlinked TMPDIR (macOS /var -> /private/var) would make
# resolver output (canonical) miss expectations built from a verbatim $TMP. This
# is the "already-canonical temp dir" the dm-100-cleanup-safety note prescribes;
# scout-cleanup.sh keeps its OWN symlinked root to exercise the canonicalization.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dm-smoke.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"; [ -z "${SMOKE_SLICE_DIR:-}" ] || rm -rf "$SMOKE_SLICE_DIR"' EXIT
export DM_HOME="$TMP/home"
pass=0; fail=0
# A shard runs the bootstrap sections it does not own for their side effects
# only: their passes belong to the owning shard's count, but a FAILURE there is
# real and is reported by whichever shard hits it.
# shard_owned_sections is overwritten by a constant the slicer emits; 0 here is
# the sequential run, which prints a summary that does not mention sections.
shard_owned=1; shard_owned_sections=0
_shard_sec() { shard_owned="$1"; }
ok()   { [ "$shard_owned" = 1 ] || return 0; pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
REG="$DM_HOME/state/repos.json"

# --- shared fixtures ---------------------------------------------------------
# Named forms in, one refusal named on failure. Used by every section that
# asserts on the command guard, which is why they live here and not beside the
# first one.
all_blocked() {
  local c
  for c in "$@"; do
    if "$ROOT/bin/dm-command-guard.sh" check "$c" >/dev/null 2>&1; then
      printf '       still allowed: %s\n' "$c" >&2; return 1
    fi
  done
}
all_allowed() {
  local c
  for c in "$@"; do
    if ! "$ROOT/bin/dm-command-guard.sh" check "$c" >/dev/null 2>&1; then
      printf '       wrongly blocked: %s\n' "$c" >&2; return 1
    fi
  done
}

# Hermetic authenticated runtime snapshot. Production doctor still probes real
# auth; smoke must not inherit developer login state or hosted-CI anonymity.
RUNTIME_OK="$TMP/runtime-ok"
mkdir -p "$RUNTIME_OK"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNTIME_OK/claude"
chmod +x "$RUNTIME_OK/claude"
export PATH="$RUNTIME_OK:$PATH"

# A "plain gh only" run must be deterministic on an operator machine that HAS
# the wrapper installed, so drop every PATH entry providing gh-axi. Prepending a
# stub cannot do this — command -v would still find the real wrapper.
path_without_ghaxi() {
  local out="" d tool real shim="$TMP/noaxi-shims"
  mkdir -p "$shim"
  while IFS= read -r d; do
    if [ -n "$d" ] && [ ! -x "$d/gh-axi" ]; then out="$out:$d"; fi
  done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"
  out="${out#:}"
  # Dropping a directory takes its unrelated tools with it — gh-axi ships in an
  # nvm bin that also holds node and claude. Re-provide anything that vanished so
  # the filter removes exactly the wrapper, even on a nvm-only machine.
  for tool in git jq node claude; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    if ! ( PATH="$out"; command -v "$tool" >/dev/null 2>&1 ); then ln -sf "$real" "$shim/$tool"; fi
  done
  printf '%s\n' "$shim:$out"
}
NOAXI_PATH="$(path_without_ghaxi)"

# dm-pr.sh is a script with a dispatch `case` at the bottom, not a pure library
# like dm-lib.sh, so sourcing it runs that case. An empty $1 falls to the usage
# branch and exits before any function below could be called. `url` with a
# harmless task id resolves through dm_meta_get, which returns cleanly (empty)
# for a nonexistent task and never exits, so sourcing completes and the
# functions become callable in the same subshell.
prfn() { ( . "$ROOT/bin/dm-pr.sh" url _smoke_helper_probe_ >/dev/null 2>&1; "$@" ); }

# --- host-port fixtures (#199) ------------------------------------------------
# The verify gate derives its starting port from $DM_HOME and the task id, so two
# suites on one host no longer aim at the same port. This mirrors that formula
# (dm-verify.sh always dispatches, so there is nothing to source) — $DM_HOME
# comes from dm-lib so the CANONICALIZED value is hashed, and the base/span are
# pinned by the "port is in the per-task range" check below.
derived_app_port() { ( . "$ROOT/bin/dm-lib.sh"; printf '%s\n%s' "$DM_HOME" "$1" | cksum | awk '{print 8600 + ($1 % 400)}' ); }
# squat_port <port> <hold-secs> [delay-secs] -- take <port> from a background
# node that touches $SQUAT_MARK once the bind actually succeeds. Every caller
# asserts that premise with squat_bound: a listener that lost the bind used to
# leave the assertion below it judging a world that was never set up (#199).
export SQUAT_MARK="$TMP/squat-bound"
squat_port() {
  rm -f "$SQUAT_MARK"
  node -e "setTimeout(function(){require('net').createServer().listen($1,'127.0.0.1',function(){require('fs').writeFileSync(process.env.SQUAT_MARK,'');setTimeout(function(){process.exit(0)},${2}000)})},${3:-0}000)" &
  SQUAT_PID=$!
}
squat_bound() {
  local waited=0
  while [ "$waited" -lt 100 ]; do
    [ ! -f "$SQUAT_MARK" ] || return 0
    waited=$((waited + 1)); sleep 0.1
  done
  return 1
}

# Stub gh so the live-base read is deterministic and offline: PR-detail calls
# answer with pr.json (or pr2.json after the first read when "retarget" is
# armed, simulating a mid-merge base/head change), check-runs/status/ref calls
# answer with their matching fixture, and a "fail" marker makes gh exit non-zero.
# gh-axi records the attempted atomic mutation, then fails loudly, so reaching
# (or not reaching) the mutation is observable.
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

# --- fixtures ----------------------------------------------------------------
git init -q --bare -b main "$TMP/origin.git"
git init -q -b main "$TMP/seed"
( cd "$TMP/seed"; git config user.email t@t.co; git config user.name t
  mkdir src; printf 'def add(a,b):\n    return a+b\n' > src/calc.py
  git add .; git commit -qm init; git remote add origin "$TMP/origin.git"; git push -q origin main ) >/dev/null 2>&1

cd "$ROOT"
b() { "$ROOT/bin/$@"; }

echo "== agent thread identity + command guard =="
THREAD_A="$(b dm-thread-name.sh fix-login-412 worker)"
THREAD_B="$(b dm-thread-name.sh fix.login-412 worker)"
THREAD_C="$(b dm-thread-name.sh fix_login_412 worker)"
LONG_THREAD="$(b dm-thread-name.sh task-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-12345 review_waiter)"
ROLE_THREAD="$(b dm-thread-name.sh fix-login-412 verify)"
MAX_ID="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
MAX_THREAD="$(b dm-thread-name.sh "$MAX_ID" secondmate)"
check "thread name is stable" '[ "$THREAD_A" = "$(b dm-thread-name.sh fix-login-412 worker)" ]'
check "thread name matches the label grammar" 'grep -Eq "^[a-z0-9_]{1,64}$" <<<"$THREAD_A"'
check "normalized collisions retain distinct identities" '[ "$THREAD_A" != "$THREAD_B" ] && [ "$THREAD_A" != "$THREAD_C" ] && [ "$THREAD_B" != "$THREAD_C" ]'
check "role participates in identity" '[ "$THREAD_A" != "$ROLE_THREAD" ]'
check "long and max-length ids stay bounded" '[ "${#LONG_THREAD}" -le 64 ] && [ "${#MAX_THREAD}" -le 64 ]'
check "invalid durable id and role are rejected separately" '! b dm-thread-name.sh "bad id" worker >/dev/null 2>&1 && ! b dm-thread-name.sh valid-id "bad-role" >/dev/null 2>&1'
check "guard blocks git -C reset flag permutation" '! b dm-command-guard.sh check "git -C /tmp reset HEAD --hard" >/dev/null 2>&1'
check "guard blocks absolute git clean flag permutation" '! b dm-command-guard.sh check "/usr/bin/git --no-pager -C /tmp clean -d -f" >/dev/null 2>&1'
check "guard blocks non-hard reset and dry-run clean bypasses" '! b dm-command-guard.sh check "/usr/bin/git -C /tmp reset --merge HEAD" >/dev/null 2>&1 && ! b dm-command-guard.sh check "/usr/bin/git -C /tmp clean -n" >/dev/null 2>&1'
# `git restore <path>` became permitted with #89's scoped carve-out; the
# whole-tree form it was standing in for is what must stay refused.
check "guard blocks restore and destructive switch" '! b dm-command-guard.sh check "git restore ." >/dev/null 2>&1 && ! b dm-command-guard.sh check "git switch --discard-changes main" >/dev/null 2>&1'
check "guard blocks checkout and combined switch flags" '! b dm-command-guard.sh check "git checkout feature" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git switch -fq main" >/dev/null 2>&1'
check "guard blocks quoted spaced-path destructive Git" '! b dm-command-guard.sh check "git -C \"/tmp/path with spaces\" reset --hard" >/dev/null 2>&1'
check "guard blocks nested, indirect, and alias destructive Git" '! b dm-command-guard.sh check "bash -c \"git clean -fd\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env bash -c \"git reset --hard\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "\$GIT restore file" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git -c alias.nuke=\"!git reset --hard\" nuke" >/dev/null 2>&1'
check "guard blocks dynamic Git executable and subcommands" '! b dm-command-guard.sh check "op=reset; git \"\$op\" --hard" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git \"\$(printf reset)\" --hard" >/dev/null 2>&1 && ! b dm-command-guard.sh check "\$(printf git) reset --hard" >/dev/null 2>&1'
ESCAPED_RESET=$'git re\\\nset --hard'
check "guard blocks escaped-newline destructive Git" '! b dm-command-guard.sh check "$ESCAPED_RESET" >/dev/null 2>&1'
check "guard blocks shell-fed and alternate-shell destructive content" '! b dm-command-guard.sh check "printf \"git reset --hard\" | bash" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env dash -c \"git restore .\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "bash <<< \"git clean -fd\"" >/dev/null 2>&1'
check "guard propagates piped stdin through shell wrappers" '! b dm-command-guard.sh check "printf \"git reset --hard\" | env bash" >/dev/null 2>&1 && ! b dm-command-guard.sh check "printf \"git reset --hard\" | command bash" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env command bash -s" >/dev/null 2>&1'
check "guard rejects unresolved command positions" '! b dm-command-guard.sh check "\$SHELL -c \"git reset --hard\"" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git \"\$OP\" --hard" >/dev/null 2>&1'
check "guard blocks invoked environment Git aliases" '! b dm-command-guard.sh check "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.nuke GIT_CONFIG_VALUE_0=\"!git reset --hard\" git nuke" >/dev/null 2>&1 && ! b dm-command-guard.sh check "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.nuke GIT_CONFIG_VALUE_0=\"\$ALIAS\" git nuke" >/dev/null 2>&1'
check "guard blocks invoked option Git aliases" '! b dm-command-guard.sh check "git -c alias.nuke=\"\$ALIAS\" nuke" >/dev/null 2>&1 && ! b dm-command-guard.sh check "git --config-env=alias.nuke=NUKE_ALIAS nuke" >/dev/null 2>&1'
check "guard permits read-only Git" 'b dm-command-guard.sh check "git -C /tmp status" >/dev/null'
check "guard permits quoted spaced-path read-only Git" 'b dm-command-guard.sh check "git -C \"/tmp/path with spaces\" status" >/dev/null'
check "guard ignores harmless Git words in argv text" 'b dm-command-guard.sh check "echo git reset --hard" >/dev/null && b dm-command-guard.sh check "printf %s \"git restore file\"" >/dev/null && b dm-command-guard.sh check "bash -c \"echo git clean -fd\"" >/dev/null'
check "guard ignores uninvoked harmless alias text" 'b dm-command-guard.sh check "git -c alias.cleanup=\"!printf harmless\" status" >/dev/null'

# --- guard is an allowlist, and wrappers do not bypass it (#105/#121) --------
# Every form in the "blocks" checks below was ALLOWED before the inversion; the
# "permits" checks pin what is deliberately left through so a later reader can
# tell a decision from an oversight. Names the forms, unlike the old block.
ALIAS_SHADOW='git -c alias.status="!git reset --hard" status'
CONFIG_ALIAS='git config alias.status "!git reset --hard"'
check "guard blocks force/delete/prune push (#105)" \
  'all_blocked "git push --force origin main" "git push -f origin main" "git push origin +main" "git push origin --delete main" "git push -d origin x" "git push --mirror origin" "git push --prune origin"'
check "guard blocks history and ref destruction" \
  'all_blocked "git stash" "git branch -D feature" "git branch -M main" "git tag -d v1" "git update-ref -d refs/heads/main" "git reflog expire --expire=now --all" "git gc --prune=now" "git filter-branch --force" "git worktree remove --force /tmp/x" "git rm -rf ." "git sparse-checkout set x" "git submodule deinit --force x"'
check "guard fails closed on unknown and future subcommands" \
  'all_blocked "git nosuchsubcommand --wat" "git remote set-url origin http://evil"'
check "guard blocks an alias shadowing a permitted subcommand" \
  'all_blocked "$ALIAS_SHADOW" "$CONFIG_ALIAS"'
check "guard blocks destructive Git behind every wrapper (#121)" \
  'all_blocked "timeout 5 git reset --hard" "nohup git reset --hard" "nice git reset --hard" "nice -n 5 git push --force" "xargs git reset --hard" "find . -exec git reset --hard {} +" "stdbuf -o0 git clean -fd" "setsid git reset --hard" "parallel git push --force" "env timeout 5 git reset --hard" "./wrapper.sh git reset --hard"'
check "guard permits the crew workflow it must not break" \
  'all_allowed "git status" "git add ." "git commit -m msg" "git push origin main" "git fetch origin" "git rebase origin/main" "git merge main" "git branch feature" "git branch -m old new" "git worktree add /tmp/x" "git switch main" "git switch -c feat" "timeout 60 git status" "nice -n 5 git log"'
check "guard permits lease-pinned force push BY DECISION (#89)" \
  'all_allowed "git push --force-with-lease origin feature" "git push --force-if-includes origin feature"'
check "guard permits git tokens as text for tools that cannot execute them" \
  'all_allowed "grep -rn git ." "echo git reset --hard"'

# The allowlist is pre-populated from git's real subcommand list, so ordinary
# work does not discover each refusal as an incident. Both directions are
# pinned: the safe form stays permitted, the destructive form stays refused.
check "guard permits plainly non-destructive subcommands" \
  'all_allowed "git reflog" "git reflog show HEAD" "git stash list" "git remote -v" "git remote show origin" "git submodule status" "git notes show" "git bisect start" "git archive HEAD" "git fsck" "git show-ref" "git bundle create /tmp/b HEAD" "git worktree list" "git worktree prune" "git sparse-checkout list" "git config --get user.email" "git blame f" "git var GIT_AUTHOR_IDENT" "git difftool" "git mergetool"'
check "guard permits the safe form where a subcommand splits" \
  'all_allowed "git remote add up http://x" "git submodule update --init" "git notes add -m x" "git rm --cached f" "git rm -r --cached dir" "git branch -m old new"'
check "guard refuses the destructive form of the same subcommand" \
  'all_blocked "git reflog expire --all" "git reflog delete HEAD@{0}" "git stash" "git stash pop" "git stash drop" "git remote remove origin" "git remote set-url origin http://evil" "git submodule deinit --force x" "git notes prune" "git notes remove" "git bisect reset" "git rm -rf ." "git rm -r dir" "git sparse-checkout set x"'
check "guard fails closed on an unknown verb of a permitted subcommand" \
  'all_blocked "git remote nosuchverb" "git notes nosuchverb" "git bisect nosuchverb"'

# A subcommand that RUNS a command it is handed would smuggle any refused form
# past the allowlist as an opaque string. Same class as an alias shadowing.
GIT_EXEC_PAGER="git -c core.pager=\"git reset --hard\" log"
GIT_EXEC_EDITOR="GIT_EDITOR=\"git reset --hard\" git rebase -i"
GIT_EXEC_REBASE="git rebase -x \"git reset --hard\" main"
check "guard refuses Git forms that execute a command they are handed" \
  'all_blocked "git bisect run git reset --hard" "git submodule foreach git reset --hard" "$GIT_EXEC_REBASE" "git rebase --exec x main" "git difftool -x x"'
check "guard refuses config keys whose value Git executes" \
  'all_blocked "$GIT_EXEC_PAGER" "git -c core.editor=evil rebase -i" "git -c diff.external=evil diff" "git -c credential.helper=evil fetch"'
check "guard refuses Git environment variables whose value Git executes" \
  'all_blocked "$GIT_EXEC_EDITOR" "GIT_SSH_COMMAND=evil git fetch" "GIT_EXTERNAL_DIFF=evil git diff"'

# Merge-gate bypasses. Each reached a permit by matching a rule the guard
# modelled too narrowly; several were verified against a real remote.
# `&` inside a redirection used to END the segment, stranding every later flag
# in a phantom segment whose executable was `1`.
check "guard keeps a redirection in the segment instead of splitting on &" \
  'all_blocked "git push origin main 2>&1 --force" "git branch feature 2>&1 -D other" "git rm . 2>&1 -rf" "git push origin HEAD:topic 2>&1 --force" "git push origin main >log 2>&1 --force" "git push origin main &>log --force" "git worktree remove /x 2>&1 --force" "git tag v1 2>&1 -d"'
check "guard still segments on && and background &" \
  'all_blocked "git status && git reset --hard" "git status & git reset --hard" "git status; git clean -fd" "git status | git reset --hard"'
check "guard permits ordinary redirection" \
  'all_allowed "git commit -m x 2>&1" "git log --oneline > out.txt" "git status 2>/dev/null" "git diff >/dev/null 2>&1"'
# git accepts --opt=value and --opt; testing only one spelling left the other open.
check "guard matches =-joined option values, not just detached ones" \
  'all_blocked "git rebase --exec=evil main" "git difftool --extcmd=evil" "git push --force=x origin main"'
check "guard still permits the lease form against the =-joined matcher" \
  'all_allowed "git push --force-with-lease=main origin main" "git push --force-with-lease origin f"'
# Git config names are case-insensitive; the exact-name list was neither.
GUARD_CFG_CASE="git -c core.PAGER=evil log"
GUARD_CFG_SUBUP="git -c submodule.x.update=\"!evil\" submodule update"
check "guard lowercases config keys and matches the executing ones by pattern" \
  'all_blocked "$GUARD_CFG_CASE" "git -c pager.log=evil log" "git -c core.askPass=evil fetch" "git -c gpg.program=evil log" "git -c core.alternateRefsCommand=evil log" "git -c trailer.x.command=evil commit" "git -c merge.x.driver=evil merge" "git -c diff.x.textconv=evil diff" "git -c browser.x.cmd=evil help" "$GUARD_CFG_SUBUP" "git -c init.templateDir=/evil init" "git -c protocol.ext.allow=always fetch"'
check "guard refuses git config WRITING the keys -c may not set" \
  'all_blocked "git config core.hooksPath /evil" "git config core.pager evil" "git config --global credential.helper evil"'
check "guard refuses the env channels that carry any config key" \
  'all_blocked "GIT_CONFIG_PARAMETERS=x git log" "GIT_ASKPASS=evil git fetch" "GIT_EXEC_PATH=/evil git status" "GIT_CONFIG_GLOBAL=/evil git log"'
# A refspec destroys with no flag at all: `+ref` forces, `:ref` deletes.
check "guard refuses a deleting refspec, not only a forcing one" \
  'all_blocked "git push origin :branch" "git push origin +main" "git push origin :refs/heads/main"'
# A dynamic subcommand and executable were refused; a dynamic FLAG was not.
GUARD_DYN_FLAG="git push \$(printf -- --force) origin main"
check "guard refuses an unreadable argument to a flag-conditional subcommand" \
  'all_blocked "$GUARD_DYN_FLAG" "git push \$FLAG origin main" "git branch \$OPT feature"'
check "guard still permits unreadable arguments where no flag changes the verdict" \
  'all_allowed "git commit -m \"\$MSG\"" "git log --grep \"\$PATTERN\"" "git add \"\$FILE\""'
# An unlisted wrapper is normally handed a quoted command string, not a bare token.
GUARD_PARALLEL="parallel \"git push --force origin main\""
check "guard refuses a quoted git command string, not just a bare git token" \
  'all_blocked "$GUARD_PARALLEL" "flock /tmp/l \"git reset --hard\"" "foobarwrapper git push --force origin main"'
check "guard refuses xargs-fed git, whose real argv comes from stdin" \
  'all_blocked "echo --force | xargs git push origin main" "xargs git status" "xargs -n1 git reset --hard"'
# Skipping an option without its value handed the value back as the verb.
check "guard reads a verb past an option that consumes its value" \
  'all_blocked "git notes --ref show remove HEAD" "git notes --ref=x remove HEAD" "git bisect --term-old start run evil"'
check "guard permits a verb behind an option it can classify" \
  'all_allowed "git notes --ref=x show" "git notes --ref x show" "git remote -v" "git submodule --quiet status"'

# A comment ends at end of LINE. The lexer ended it at end of INPUT, so a bare
# `#` discarded every later newline-separated command, unguarded.
GUARD_HASH_LEAD='#
git push --force origin main'
GUARD_HASH_TRAIL='true #
git reset --hard HEAD~5'
GUARD_HASH_INLINE='git status # note
git clean -fd'
check "guard resumes at the next line instead of ending at a comment" \
  'all_blocked "$GUARD_HASH_LEAD" "$GUARD_HASH_TRAIL" "$GUARD_HASH_INLINE"'
check "guard still permits a comment and a literal hash" \
  'all_allowed "git status # just a note" "echo a#b" "git commit -m \"fix #121\""'
# Redirecting the git process is refused in BOTH spellings: guarding only the
# detached one left `--exec-path=DIR`, the twin of the refused GIT_EXEC_PATH.
check "guard refuses process redirection in joined and detached spellings" \
  'all_blocked "git --exec-path=/tmp/evil status" "git --exec-path /tmp/evil status" "git --exec-path=/tmp/evil mergetool" "git --git-dir=/tmp/x status" "git --git-dir /tmp/x status" "git --work-tree=/tmp/x status"'
check "guard fails closed on an unknown pre-subcommand option" \
  'all_blocked "git --nosuchfutureopt=x status" "git --nosuchfutureopt x status"'
check "guard still permits the pre-subcommand options it can classify" \
  'all_allowed "git --no-pager -C /tmp status" "git --exec-path" "git --version" "git -c user.name=x commit -m y"'
# PATH/LD_PRELOAD pick which binary runs as git and what loads into it -- a more
# direct redirect than GIT_TEMPLATE_DIR, which was already refused.
check "guard refuses env prefixes that redirect the git process" \
  'all_blocked "PATH=/tmp/evil git status" "LD_PRELOAD=/tmp/e.so git status" "LD_AUDIT=/e.so git status" "DYLD_INSERT_LIBRARIES=/e git status" "env PATH=/evil git status" "GIT_DIR=/tmp/x git status" "GIT_INDEX_FILE=/tmp/x git status" "GIT_ALTERNATE_OBJECT_DIRECTORIES=/x git log"'
# Over-blocking is what gets a guard switched off. A quoted string is classified,
# not refused for starting with the word "git".
GUARD_PR_BODY='bin/dm-pr.sh open 121 --title "t" --body "git config write path now routed"'
check "guard permits prose that merely starts with the word git" \
  'all_allowed "$GUARD_PR_BODY" "gh pr create --body \"git log shows the bug\"" "git remote --help" "git worktree --help" "git push --help"'
check "guard still refuses a quoted string that IS a destructive command" \
  'all_blocked "parallel \"git push --force origin main\"" "flock /tmp/l \"git reset --hard\"" "mywrap \"git status && git push --force origin main\""'
# Git falls back to the PLAIN-spelled env vars, so guarding only the GIT_*
# spelling left the same execution open. All four verified against git 2.54.
check "guard refuses the unprefixed env fallbacks Git executes" \
  'all_blocked "PAGER=/tmp/evil git log" "EDITOR=/tmp/evil git commit -a" "VISUAL=/tmp/evil git commit -a" "SSH_ASKPASS=/tmp/evil git fetch" "MANPAGER=/tmp/evil git help git" "GIT_MAN_VIEWER=/tmp/evil git help git" "env PAGER=/tmp/evil git log"'
# The re-entry check tested only the literal first word, so anything sh skips
# before the command -- whitespace, an env assignment, a wrapper -- walked past.
TAB=$'\t'
GUARD_REENTER_TAB="parallel \"git${TAB}push${TAB}--force origin main\""
GUARD_REENTER_SH="parallel \"sh -c 'git push --force'\""
check "guard re-enters a quoted command past whitespace, wrappers and shells" \
  'all_blocked "parallel \" git push --force origin main\"" "$GUARD_REENTER_TAB" "$GUARD_REENTER_SH" "parallel \"env git push --force\"" "parallel \"timeout 5 git push --force\"" "parallel \"VAR=x git push --force\"" "parallel \"  nohup nice git reset --hard\""'
check "guard still permits prose that merely mentions git mid-sentence" \
  'all_allowed "gh pr create --body \"the git repo is broken\"" "gh pr create --body \"git log shows the bug\""'
# The merge-tool family runs `<tool>.path` as an executable, and include.path
# injects a whole config file. `*.cmd` was covered; `*.path` was not.
GUARD_TOOLPATH="git -c difftool.vimdiff.path=/tmp/evil difftool --tool=vimdiff -y HEAD~1 HEAD"
GUARD_TOOLPATH_ENV="GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=difftool.vimdiff.path GIT_CONFIG_VALUE_0=/tmp/evil git difftool"
check "guard refuses config keys whose .path Git executes" \
  'all_blocked "$GUARD_TOOLPATH" "$GUARD_TOOLPATH_ENV" "git -c mergetool.x.path=/tmp/evil mergetool" "git -c browser.x.path=/tmp/evil help" "git -c man.x.path=/tmp/evil help" "git config difftool.vimdiff.path /tmp/evil" "git -c DIFFTOOL.X.PATH=/evil difftool" "git -c include.path=/tmp/evil.cfg log"'
# is_command_runner gates re-entry ONLY. These must never join is_command_wrapper:
# unwrapping them would classify git on an argv the guard cannot see.
check "guard re-enters a quoted string led by a non-unwrappable command runner" \
  'all_blocked "parallel \"exec git push --force origin main\"" "parallel \"time git push --force origin main\"" "parallel \"xargs git push --force origin main\"" "parallel \"watch git push --force origin main\"" "parallel \"script git push --force origin main\"" "parallel \"unbuffer git push --force origin main\"" "parallel \"strace git push --force origin main\"" "parallel \"proot git push --force origin main\"" "parallel \"flock git push --force origin main\""'
check "guard keeps unwrapping precision for the wrappers it does model" \
  'all_allowed "timeout 5 git status" "nice -n 5 git log" "env git status" "stdbuf -o0 git status"'

# --- dm_lock: a leaked reclaim marker must not wedge recovery (#122) ---------
# Before the fix the marker was unstamped and untrapped, so ONE reclaimer killed
# mid-reclaim made every later dead-PID lock hard-fail at ~30s, forever.
LOCKFIX="$TMP/lockfix"; mkdir -p "$LOCKFIX"
# Stage a lock held by a dead PID, plus a reclaim marker owned by <pid> ("" = none).
stage_wedged_lock() {
  local d="$LOCKFIX/$1" owner="$2"
  rm -rf "$d"; mkdir -p "$d"; : > "$d/lk.meta"
  mkdir "$d/lk.meta.lock"; printf '999999\n' > "$d/lk.meta.lock/pid"
  mkdir "$d/lk.meta.lock.reclaim"
  [ -z "$owner" ] || printf '%s\n' "$owner" > "$d/lk.meta.lock.reclaim/pid"
  printf '%s\n' "$d"
}
# Exercise the marker rule directly so a live-owner case costs no 30s spin.
reclaim_rc() { # <marker-dir> <stalled-spins> -> "rc=<n> marker=<present|cleared>"
  local rc=0
  bash -c '. "$1/bin/dm-lib.sh"; dm_lock_acquire_reclaim "$2" "$3"' _ "$ROOT" "$1" "$2" >/dev/null 2>&1 || rc=$?
  printf 'rc=%s marker=%s\n' "$rc" "$([ -d "$1" ] && echo present || echo cleared)"
}
WEDGE_DEAD="$(stage_wedged_lock dead 999998)"
WEDGE_LIVE="$(stage_wedged_lock live $$)"
WEDGE_BARE="$(stage_wedged_lock bare '')"
check "marker owned by a dead reclaimer is cleared" \
  '[ "$(reclaim_rc "$WEDGE_DEAD/lk.meta.lock.reclaim" 0)" = "rc=1 marker=cleared" ]'
check "marker owned by a LIVE reclaimer is never stolen" \
  '[ "$(reclaim_rc "$WEDGE_LIVE/lk.meta.lock.reclaim" 999)" = "rc=1 marker=present" ]'
check "unstamped marker is kept while a reclaim could still be in flight" \
  '[ "$(reclaim_rc "$WEDGE_BARE/lk.meta.lock.reclaim" 0)" = "rc=1 marker=present" ]'
check "unstamped marker is cleared once it has blocked far past any real reclaim" \
  '[ "$(reclaim_rc "$WEDGE_BARE/lk.meta.lock.reclaim" 50)" = "rc=1 marker=cleared" ]'
# End to end: the exact #122 reproduction must now heal instead of hard-failing.
WEDGE_E2E="$(stage_wedged_lock e2e '')"
LOCK_E2E="$(bash -c '. "$1/bin/dm-lib.sh"; dm_lock "$2" >/dev/null 2>&1 && { printf ACQUIRED; dm_unlock "$2"; }' _ "$ROOT" "$WEDGE_E2E/lk.meta" 2>/dev/null || true)"
check "a leaked reclaim marker no longer wedges dead-lock recovery" '[ "$LOCK_E2E" = ACQUIRED ]'
# A live-owned marker is correctly never stolen, so this reaches the timeout.
# Stubbing sleep collapses the 300 spins to ~0s without weakening the path.
LOCK_MSG="$(bash -c 'sleep() { :; }; . "$1/bin/dm-lib.sh"; dm_lock "$2"' _ "$ROOT" "$WEDGE_LIVE/lk.meta" 2>&1 || true)"
check "the timeout message names the reclaim marker, not just the lock" \
  "grep -q \"lk.meta.lock.reclaim'\" <<<\"\$LOCK_MSG\" && grep -q \"lk.meta.lock' \" <<<\"\$LOCK_MSG\""
check "dm-lib documents no knob it does not implement" \
  '! grep -q "DM_LOCK_STALE_SECS" "$ROOT/bin/dm-lib.sh"'

# --- managed-worktree guard hook (#83) ---------------------------------------
# The PreToolUse hook classifies by the command alone: cwd inside a managed
# clone/worktree must not change the verdict, with or without DM_HOME.
GUARD_DISTRO="$TMP/guard-distro"
mkdir -p "$GUARD_DISTRO/bin" "$GUARD_DISTRO/repos/veriflow/src" "$GUARD_DISTRO/state/worktrees/dm-fake/src"
cp "$ROOT/bin/dm-command-guard.sh" "$GUARD_DISTRO/bin/dm-command-guard.sh"
chmod +x "$GUARD_DISTRO/bin/dm-command-guard.sh"
GUARD_HOOK="$GUARD_DISTRO/bin/dm-command-guard.sh"
GUARD_WT="$GUARD_DISTRO/state/worktrees/dm-fake/src"
GUARD_CLONE="$GUARD_DISTRO/repos/veriflow/src"
guard_from() { ( cd "$1" && printf '%s' "$2" | env -u DM_HOME "$GUARD_HOOK" hook ); }
guard_dmhome() { ( cd "$TMP" && printf '%s' "$1" | DM_HOME="$GUARD_DISTRO" "$GUARD_HOOK" hook ); }
GUARD_RESET='{"tool_input":{"command":"git reset --hard"}}'
GUARD_CHECKOUT='{"tool_input":{"command":"git checkout -- ."}}'
GUARD_CLEAN='{"tool_input":{"command":"git clean -fdx"}}'
GUARD_STATUS='{"tool_input":{"command":"git status"}}'
check "hook blocks destructive git from a managed worktree (no DM_HOME)" '! guard_from "$GUARD_WT" "$GUARD_RESET" >/dev/null 2>&1'
check "hook blocks destructive git from a managed clone (no DM_HOME)" '! guard_from "$GUARD_CLONE" "$GUARD_CHECKOUT" >/dev/null 2>&1'
check "hook permits read-only git from a managed worktree" 'guard_from "$GUARD_WT" "$GUARD_STATUS" >/dev/null 2>&1'
check "hook blocks destructive git with DM_HOME set" '! guard_dmhome "$GUARD_CLEAN" >/dev/null 2>&1'

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

# shard:bootstrap
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
printf '#!/usr/bin/env bash\nexit 1\n' > "$RUNTIME_BAD/claude"
chmod +x "$RUNTIME_BAD/claude"
check "doctor fails an unauthenticated Claude runtime" '! PATH="$RUNTIME_BAD:$PATH" b dm-doctor.sh check >/dev/null 2>&1'
CLEAN_DOCTOR_HOME="$TMP/clean-doctor-home"
check "doctor passes CI-like environment only through explicit authenticated stub" \
  'env -i HOME="$HOME" DM_HOME="$CLEAN_DOCTOR_HOME" PATH="$RUNTIME_OK:$PATH" "$ROOT/bin/dm-doctor.sh" check >/dev/null'
STATEFUL_RUNTIME="$TMP/runtime-stateful"
STATEFUL_COUNT="$TMP/runtime-stateful-count"
mkdir -p "$STATEFUL_RUNTIME"
printf '%s\n' '#!/usr/bin/env bash' 'n=0; [ ! -f "$STATEFUL_COUNT" ] || n="$(cat "$STATEFUL_COUNT")"' 'n=$((n + 1)); printf "%s\n" "$n" > "$STATEFUL_COUNT"' '[ "$n" -eq 1 ]' > "$STATEFUL_RUNTIME/claude"
chmod +x "$STATEFUL_RUNTIME/claude"
STATEFUL_OUT="$(STATEFUL_COUNT="$STATEFUL_COUNT" PATH="$STATEFUL_RUNTIME:$PATH" b dm-doctor.sh check)"
check "doctor probes the runtime exactly once" '[ "$(cat "$STATEFUL_COUNT")" = 1 ]'
check "doctor reports and exits from the same immutable snapshot" 'grep -qE "ok +claude-runtime" <<<"$STATEFUL_OUT" && ! grep -q "MISSING.*claude-runtime" <<<"$STATEFUL_OUT"'

# shard:bootstrap
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

# shard:bootstrap
echo "== task + worktree + brief =="
b dm-task.sh new demo-1 --kind ship --repo demo --title "add multiply" >/dev/null
WT="$(b dm-worktree.sh create demo-1 demo | tail -n1)"
check "worktree created"        '[ -d "$WT" ]'
check "isolation asserts"       'b dm-worktree.sh assert "$WT" demo >/dev/null'
b dm-brief.sh demo-1 >/dev/null
check "brief bakes commandments" 'grep -q "The Ten Commandments" "$DM_HOME/data/demo-1/brief.md"'
check "brief has review-ready"    'grep -q "review-ready" "$DM_HOME/data/demo-1/brief.md"'
check "brief labels the private-notes boundary" 'grep -q "never copy or paraphrase them" "$DM_HOME/data/demo-1/brief.md"'
# Sizing is judgment, not a computed default (#166-#187, reverted): the brief
# names the dial without a value, and nothing is recorded until the dockmaster
# actually chooses.
check "brief notes sizing is the dockmaster's call"   'grep -q "Sized by the dockmaster" "$DM_HOME/data/demo-1/brief.md"'
check "brief records no model until one is chosen"    '[ -z "$(b dm-task.sh get demo-1 model)" ]'

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

# shard:bootstrap
echo "== state reconciliation =="
check "state pending pre-work" 'OUT="$(b dm-task.sh state demo-1)"; grep -q pending <<<"$OUT"'
git -C "$WT" checkout -q -b feat/x/add-multiply
printf 'def multiply(a,b):\n    return a*b\n' >> "$WT/src/calc.py"
git -C "$WT" -c user.email=c@c.co -c user.name=c commit -qam "add multiply" >/dev/null
check "state working post-commit" 'OUT="$(b dm-task.sh state demo-1)"; grep -q working <<<"$OUT"'
# DM_NO_FETCH (used by dm-status) must reconcile from local refs only and still
# report the committed-but-unlanded case correctly.
check "no-fetch landed: reports unlanded" '! DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 >/dev/null 2>&1'
# The same answer, machine-readable: exit 0 because "not landed" is an ANSWER,
# and a consumer that reads the bare form's exit 1 as failure loses it (#196).
LANDEDJ_UNLANDED="$(DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 --json)"
check "landed --json exits 0 for unlanded work" 'DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 --json >/dev/null'
check "landed --json state is unlanded"         '[ "$(jq -r ".state" <<<"$LANDEDJ_UNLANDED")" = "unlanded" ]'
check "landed --json carries the reason"        '[ -n "$(jq -r ".detail" <<<"$LANDEDJ_UNLANDED")" ]'
check "landed --json refuses an unknown flag"   '! b dm-worktree.sh landed demo-1 --wat >/dev/null 2>&1'
# Deliberate TIGHTENING, not additive: the flag loop rejects stray positional
# args the old single-argument form silently ignored. It fails closed, and no
# in-tree caller passes a second argument.
check "landed refuses a stray positional arg"  '! b dm-worktree.sh landed demo-1 EXTRA >/dev/null 2>&1'

echo "== state reconcile: 'merged:' in a note must not fake done (anchored verb) =="
b dm-task.sh new fix1 --kind ship --repo demo >/dev/null
b dm-task.sh event fix1 working "waiting on upstream PR merged: #123" >/dev/null
check "note text 'merged:' does not reconcile to done" 'OUT="$(b dm-task.sh state fix1)"; ! grep -q done <<<"$OUT"'
# The sanctioned landing paths (dm-merge/dm-pr) append the 'merged' event
# directly via the status-append helper; `dm-task.sh event` can no longer forge
# it (see the state-gate-integrity block at the end). Simulate the sanctioned
# append through the same helper those paths use.
( . "$ROOT/bin/dm-lib.sh"; dm_status_append fix1 merged "landed via local ff" ) >/dev/null
check "a real merge event reconciles to done"          'OUT="$(b dm-task.sh state fix1)"; grep -q done <<<"$OUT"'

# shard:bootstrap
echo "== test gate =="
check "tests pass (registered cmd)" 'b dm-test.sh demo-1 >/dev/null'
check "tests recorded pass"         '[ "$(b dm-task.sh get demo-1 tests)" = "pass" ]'

# shard:bootstrap
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
# --json exits 0 for BOTH answers. The bare form's exit 1 for "no signals" is
# good news reported as failure, which a strict consumer reads as a broken scan.
SCANJ="$(b dm-pr.sh security-scan sec-scan --json)"
BENIGNJ="$(b dm-pr.sh security-scan demo-1 --json)"
check "security-scan --json exits 0 on a security surface" 'b dm-pr.sh security-scan sec-scan --json >/dev/null'
check "security-scan --json reports surface true"   '[ "$(jq -r ".surface" <<<"$SCANJ")" = "true" ]'
check "security-scan --json lists the signals"      '[ "$(jq -r ".signals | length" <<<"$SCANJ")" -gt 0 ]'
check "security-scan --json exits 0 with no signals" 'b dm-pr.sh security-scan demo-1 --json >/dev/null'
check "security-scan --json reports surface false"  '[ "$(jq -r ".surface" <<<"$BENIGNJ")" = "false" ]'
check "security-scan --json lists no signals"       '[ "$(jq -r ".signals | length" <<<"$BENIGNJ")" = 0 ]'
check "security-scan --json refuses an unknown flag" '! b dm-pr.sh security-scan sec-scan --wat >/dev/null 2>&1'
check "security-scan refuses a stray positional arg" '! b dm-pr.sh security-scan sec-scan EXTRA >/dev/null 2>&1'
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

# A create failure past the push must surface gh-axi's real stderr, not a bare
# "pr create failed" (#74) — the failure was previously discarded by $(...).
GHAXI_FAIL_STUB="$TMP/pr-open-ghaxi-fail-stub"
mkdir -p "$GHAXI_FAIL_STUB"
printf '#!/bin/sh\necho "gh-axi: HTTP 422: a pull request already exists for demo:feat/x/pr-ghaxi-fail" >&2\nexit 1\n' > "$GHAXI_FAIL_STUB/gh-axi"
chmod +x "$GHAXI_FAIL_STUB/gh-axi"
b dm-task.sh new pr-ghaxi-fail --kind ship --repo demo --mode pipeline >/dev/null
PR_GHAXI_WT="$(b dm-worktree.sh create pr-ghaxi-fail demo | tail -n1)"
git -C "$PR_GHAXI_WT" checkout -q -b feat/x/pr-ghaxi-fail
printf 'x = 1\n' > "$PR_GHAXI_WT/ghaxi_fail.py"
git -C "$PR_GHAXI_WT" add -A >/dev/null
git -C "$PR_GHAXI_WT" commit -qm "add ghaxi_fail" >/dev/null
check "pr open fails when gh-axi fails" \
  '! PATH="$GHAXI_FAIL_STUB:$PATH" b dm-pr.sh open pr-ghaxi-fail --title x >/dev/null 2>&1'
GHAXI_FAIL_OUT="$(PATH="$GHAXI_FAIL_STUB:$PATH" b dm-pr.sh open pr-ghaxi-fail --title x 2>&1 || true)"
check "pr open surfaces gh-axi's real stderr on create failure" \
  'grep -q "HTTP 422: a pull request already exists" <<<"$GHAXI_FAIL_OUT"'
check "no leftover temp file after the failure" '[ -z "$(find "$DM_HOME/state" -maxdepth 1 -name ".pr-open.*")" ]'
b dm-worktree.sh remove pr-ghaxi-fail --force >/dev/null 2>&1

echo "== GitHub CLI resolution: plain gh is the baseline, gh-axi only preferred (#104) =="
# The resolver is pure and PATH-driven, and uses only builtins (command -v,
# printf), so a stub-only PATH exercises every combination hermetically.
ghcli() { ( . "$ROOT/bin/dm-lib.sh"; PATH="$1"; dm_github_cli ); }
ghreq() { ( . "$ROOT/bin/dm-lib.sh"; PATH="$1"; dm_require_github_cli ); }
prgate() { ( . "$ROOT/bin/dm-lib.sh"; dm_pr_delivery_gate "$1" "$2" ); }
CLI_BOTH="$TMP/cli-both"; CLI_GH="$TMP/cli-gh"; CLI_AXI="$TMP/cli-axi"; CLI_NONE="$TMP/cli-none"
mkdir -p "$CLI_BOTH" "$CLI_GH" "$CLI_AXI" "$CLI_NONE"
printf '#!/bin/sh\nexit 0\n' > "$CLI_BOTH/gh"
cp "$CLI_BOTH/gh" "$CLI_BOTH/gh-axi"; cp "$CLI_BOTH/gh" "$CLI_GH/gh"; cp "$CLI_BOTH/gh" "$CLI_AXI/gh-axi"
chmod +x "$CLI_BOTH/gh" "$CLI_BOTH/gh-axi" "$CLI_GH/gh" "$CLI_AXI/gh-axi"
check "both installed prefers the gh-axi wrapper" '[ "$(ghcli "$CLI_BOTH")" = "gh-axi" ]'
check "plain gh alone resolves to gh"             '[ "$(ghcli "$CLI_GH")" = "gh" ]'
check "gh-axi alone still resolves"               '[ "$(ghcli "$CLI_AXI")" = "gh-axi" ]'
check "neither installed fails, never defaults"   '! ghcli "$CLI_NONE" >/dev/null 2>&1'
CLI_NONE_OUT="$(ghreq "$CLI_NONE" 2>&1 || true)"
check "the missing-CLI error points at installable gh" 'grep -q "cli.github.com" <<<"$CLI_NONE_OUT"'
check "the missing-CLI error never demands the private wrapper" '! grep -q "gh-axi" <<<"$CLI_NONE_OUT"'
check "dm_pr_delivery_gate: gh installed + authenticated is ready" '[ "$(prgate 1 1)" = "ready" ]'
check "dm_pr_delivery_gate: no gh is no-cli"                       '[ "$(prgate 0 1)" = "no-cli" ]'
check "dm_pr_delivery_gate: unauthenticated gh is no-auth"         '[ "$(prgate 1 0)" = "no-auth" ]'
check "dm_pr_delivery_gate: neither is no-cli"                     '[ "$(prgate 0 0)" = "no-cli" ]'
check "dm_pr_delivery_gate fails closed on a garbage probe"        '[ "$(prgate yes yes)" = "no-cli" ]'

check "the no-wrapper PATH really resolves no gh-axi" '( PATH="$NOAXI_PATH"; ! command -v gh-axi >/dev/null 2>&1 )'
check "the no-wrapper PATH keeps every tool the filter is not aiming at" \
  '( PATH="$NOAXI_PATH"; for t in git jq node; do command -v "$t" >/dev/null 2>&1 || exit 1; done )'

echo "== pr open success path: plain gh alone, and gh-axi preferred (#104) =="
# The success path was previously untested: it pushes and creates (both
# irreversible) before parsing a url out of stdout. Both binaries print the url
# the same way, so the stubs differ only in which name gets invoked.
open_task() {
  # open_task <id> <branch> -> commit a file on a fresh branch in a new worktree
  local id="$1" branch="$2" wt
  b dm-task.sh new "$id" --kind ship --repo demo --mode pipeline >/dev/null
  wt="$(b dm-worktree.sh create "$id" demo | tail -n1)"
  git -C "$wt" checkout -q -b "$branch"
  printf 'x = 1\n' > "$wt/$id.py"
  git -C "$wt" add -A >/dev/null
  git -C "$wt" commit -qm "work for $id" >/dev/null
}
PR_GH_STUB="$TMP/pr-open-gh"; mkdir -p "$PR_GH_STUB"
cat > "$PR_GH_STUB/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$PR_GH_STUB/gh-calls"
printf 'https://github.com/o/r/pull/321\n'
STUB
chmod +x "$PR_GH_STUB/gh"
open_task pr-gh-only feat/x/pr-gh-only
PR_GH_OUT="$(PATH="$PR_GH_STUB:$NOAXI_PATH" b dm-pr.sh open pr-gh-only --title "plain gh" --body body 2>&1 || true)"
check "pr open succeeds with only plain gh installed" 'grep -q "https://github.com/o/r/pull/321" <<<"$PR_GH_OUT"'
check "plain gh received the pr create call"          'grep -q "^pr create -R " "$PR_GH_STUB/gh-calls"'
check "pr open records the PR url on the task"        '[ "$(b dm-task.sh get pr-gh-only pr)" = "https://github.com/o/r/pull/321" ]'
check "pr open records the branch on the task"        '[ "$(b dm-task.sh get pr-gh-only branch)" = "feat/x/pr-gh-only" ]'
check "pr open appends the done event"                'grep -q "done: PR https://github.com/o/r/pull/321" "$DM_HOME/state/tasks/pr-gh-only.status"'
check "pr open really pushed the branch to origin"    'git -C "$TMP/origin.git" rev-parse --verify --quiet refs/heads/feat/x/pr-gh-only >/dev/null'

# Wrapper present: it must be preferred, and plain gh must not be used for the
# create — the task record that results is otherwise identical.
PR_AXI_STUB="$TMP/pr-open-axi"; mkdir -p "$PR_AXI_STUB"
cat > "$PR_AXI_STUB/gh-axi" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$PR_AXI_STUB/axi-calls"
printf 'https://github.com/o/r/pull/321\n'
STUB
cat > "$PR_AXI_STUB/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$PR_AXI_STUB/gh-calls"
printf 'https://github.com/o/r/pull/999\n'
STUB
chmod +x "$PR_AXI_STUB/gh-axi" "$PR_AXI_STUB/gh"
open_task pr-axi-pref feat/x/pr-axi-pref
PATH="$PR_AXI_STUB:$NOAXI_PATH" b dm-pr.sh open pr-axi-pref --title "wrapper" --body body >/dev/null 2>&1 || true
check "the wrapper handled the create when installed" 'grep -q "^pr create -R " "$PR_AXI_STUB/axi-calls"'
check "plain gh was not used for the create"          '[ ! -f "$PR_AXI_STUB/gh-calls" ]'
check "both CLIs record the same PR url"       '[ "$(b dm-task.sh get pr-axi-pref pr)" = "$(b dm-task.sh get pr-gh-only pr)" ]'
check "both CLIs record their own branch"      '[ "$(b dm-task.sh get pr-axi-pref branch)" = "feat/x/pr-axi-pref" ]'
check "both CLIs append the same done event"   'grep -q "done: PR https://github.com/o/r/pull/321" "$DM_HOME/state/tasks/pr-axi-pref.status"'

# A create that SUCCEEDS but prints no url leaves a pushed branch and a real PR
# the task record knows nothing about. The only recovery is `adopt`, so the
# failure has to name it.
PR_NOURL_STUB="$TMP/pr-open-nourl"; mkdir -p "$PR_NOURL_STUB"
printf '#!/bin/sh\nprintf "created something\\n"\n' > "$PR_NOURL_STUB/gh"
chmod +x "$PR_NOURL_STUB/gh"
open_task pr-nourl feat/x/pr-nourl
check "an unparseable create url fails visibly" \
  '! PATH="$PR_NOURL_STUB:$NOAXI_PATH" b dm-pr.sh open pr-nourl --title x >/dev/null 2>&1'
PR_NOURL_OUT="$(PATH="$PR_NOURL_STUB:$NOAXI_PATH" b dm-pr.sh open pr-nourl --title x 2>&1 || true)"
check "the unparseable-url failure names adopt as the remedy" 'grep -q "dm-pr.sh adopt pr-nourl" <<<"$PR_NOURL_OUT"'
check "the failure says the branch is already pushed"         'grep -q "IS pushed" <<<"$PR_NOURL_OUT"'
check "the push really did happen before the parse"           'git -C "$TMP/origin.git" rev-parse --verify --quiet refs/heads/feat/x/pr-nourl >/dev/null'
check "no PR url is recorded after the failed parse"          '[ -z "$(b dm-task.sh get pr-nourl pr)" ]'
check "no leftover temp file after the parse failure"         '[ -z "$(find "$DM_HOME/state" -maxdepth 1 -name ".pr-open.*")" ]'
b dm-worktree.sh remove pr-gh-only --force >/dev/null 2>&1
b dm-worktree.sh remove pr-axi-pref --force >/dev/null 2>&1
b dm-worktree.sh remove pr-nourl --force >/dev/null 2>&1

echo "== repo create reaches plain gh instead of demanding the wrapper (#104) =="
# The remote-creating branch of `create` needs network past this point, so stop
# at the gh call: what regressed was the hard `dm_need gh-axi` before it.
RC_STUB="$TMP/repo-create-gh"; mkdir -p "$RC_STUB"
cat > "$RC_STUB/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$RC_STUB/gh-calls"
printf 'gh: repository creation refused (smoke stub)\n' >&2
exit 1
STUB
chmod +x "$RC_STUB/gh"
RC_OUT="$(PATH="$RC_STUB:$NOAXI_PATH" b dm-repo.sh create ghonlynew --mode local-only --no-memory 2>&1 || true)"
check "repo create invokes plain gh when no wrapper exists" 'grep -q "^repo create ghonlynew --private" "$RC_STUB/gh-calls"'
check "repo create no longer hard-requires gh-axi"          '! grep -q "required tool not found: gh-axi" <<<"$RC_OUT"'
check "repo create still surfaces the real gh failure"       'grep -q "gh repo create failed" <<<"$RC_OUT"'
check "the failed create registered nothing"                 '! jq -e ".repos[\"ghonlynew\"]" "$DM_HOME/state/repos.json" >/dev/null 2>&1'

# The stub above makes gh FAIL, so it never reaches the url parse. That parse
# had the same set -e abort as dm-pr.sh open, and worse consequences: the GitHub
# repo is really created first, then the script died with no message at all.
RC_NOURL="$TMP/repo-create-nourl"; mkdir -p "$RC_NOURL"
printf '#!/bin/sh\nprintf "Created repository somewhere\\n"\n' > "$RC_NOURL/gh"
chmod +x "$RC_NOURL/gh"
RC_NOURL_OUT="$(PATH="$RC_NOURL:$NOAXI_PATH" b dm-repo.sh create ghnourl --mode local-only --no-memory 2>&1 || true)"
check "an unparseable create url fails visibly, not silently" 'grep -q "printed no url to parse" <<<"$RC_NOURL_OUT"'
check "the failure warns the remote now really exists"        'grep -q "now EXISTS" <<<"$RC_NOURL_OUT"'
check "the failure names both recoveries"                     'grep -q "dm-repo.sh create ghnourl <remote>" <<<"$RC_NOURL_OUT" && grep -q "gh repo delete" <<<"$RC_NOURL_OUT"'
check "the unparseable create registered nothing"             '! jq -e ".repos[\"ghnourl\"]" "$DM_HOME/state/repos.json" >/dev/null 2>&1'
# Multi-match: a cheap regression guard on first-match selection, NOT a repro of
# the SIGPIPE mode. Measured: two matches never SIGPIPE (grep finishes before
# head exits); it takes ~50k matches to hit 141, which is buffer-size dependent
# and too flaky to assert. Removing the pipe entirely is what kills that class.
RC_MULTI="$TMP/repo-create-multi"; mkdir -p "$RC_MULTI"
printf '#!/bin/sh\nprintf "https://github.com/o/ghmulti\\nsee also https://github.com/o/other\\n"\n' > "$RC_MULTI/gh"
chmod +x "$RC_MULTI/gh"
RC_MULTI_OUT="$(PATH="$RC_MULTI:$NOAXI_PATH" b dm-repo.sh create ghmulti --mode local-only --no-memory 2>&1 || true)"
check "multi-match parses and reaches the push" 'grep -q "publishing initial commit" <<<"$RC_MULTI_OUT"'
check "multi-match takes the first url"         'grep -q "o/ghmulti" <<<"$RC_MULTI_OUT" && ! grep -q "printed no url to parse" <<<"$RC_MULTI_OUT"'
rm -rf "$DM_HOME/repos/ghnourl" "$DM_HOME/repos/ghmulti"

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
b dm-task.sh new metatest --kind ship --repo demo >/dev/null
b dm-task.sh set metatest re '.*[x]^$ +(a|b)' >/dev/null
check "meta round-trips regex metachars" '[ "$(b dm-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
b dm-task.sh set metatest eq 'k=v=x' >/dev/null
check "meta round-trips value with ="   '[ "$(b dm-task.sh get metatest eq)" = "k=v=x" ]'
check "meta update leaves sibling key"   '[ "$(b dm-task.sh get metatest re)" = ".*[x]^$ +(a|b)" ]'
# KEY-side regression: the old sed/grep treated the key as a regex, so "a.c"
# also matched "abc". awk matches the key as a fixed string. Set abc first, then
# a.c: the old grep -v "^a.c=" would drop the abc line too (. matches b).
b dm-task.sh new keytest --kind ship --repo demo >/dev/null
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

echo "== task record integrity: complete mutations + atomic creation (#101) =="
check "set rejects a missing task without creating files" \
  '! b dm-task.sh set task-typo model opus >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-typo.meta" ] && [ ! -e "$DM_HOME/state/tasks/task-typo.status" ]'
check "event rejects a missing task without creating files" \
  '! b dm-task.sh event task-event-typo done finished >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-event-typo.meta" ] && [ ! -e "$DM_HOME/state/tasks/task-event-typo.status" ]'

b dm-task.sh new task-stale --kind scout --repo demo >/dev/null
mkdir -p "$DM_HOME/data/task-stale"
printf 'complete\n' > "$DM_HOME/data/task-stale/report.md"
b dm-task.sh archive task-stale >/dev/null
check "set rejects an archived task without resurrecting it" \
  '! b dm-task.sh set task-stale agent_id wrong >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-stale.meta" ] && [ -f "$DM_HOME/state/archive/task-stale.meta" ]'
check "event rejects an archived task without resurrecting it" \
  '! b dm-task.sh event task-stale done wrong >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-stale.status" ] && [ -f "$DM_HOME/state/archive/task-stale.status" ]'

archive_under_lock_refused() {
  # <id> <mutator-cmd...>: hold the task lock, block the mutator on it, archive
  # underneath, release. Passes only if the mutator refuses and writes nothing.
  # Determinism needs dm_lock to have NO age-based stale reclaim: a real
  # DM_LOCK_STALE_SECS (documented but absent; #122) under 2s would make this flaky.
  local id="$1"; shift
  local lockdir="$DM_HOME/state/tasks/$id.meta.lock" mutator_pid
  mkdir "$lockdir" || return 1
  printf '%s\n' "$$" > "$lockdir/pid"
  "$@" >/dev/null 2>&1 &
  mutator_pid=$!
  sleep 2
  # Still running == genuinely parked on the lock. A mutator that finished here
  # never took the lock at all, so the ordering it claims to honor is not there.
  if ! kill -0 "$mutator_pid" 2>/dev/null; then rm -rf "$lockdir"; wait "$mutator_pid" || true; return 1; fi
  mkdir -p "$DM_HOME/state/archive"
  mv -f "$DM_HOME/state/tasks/$id.meta" "$DM_HOME/state/archive/$id.meta" || { rm -rf "$lockdir"; return 1; }
  mv -f "$DM_HOME/state/tasks/$id.status" "$DM_HOME/state/archive/$id.status" || { rm -rf "$lockdir"; return 1; }
  rm -rf "$lockdir"
  if wait "$mutator_pid"; then return 1; fi
  [ ! -e "$DM_HOME/state/tasks/$id.meta" ] && [ ! -e "$DM_HOME/state/tasks/$id.status" ]
}
b dm-task.sh new task-lock-set --kind scout --repo demo >/dev/null
check "set parked on the task lock cannot resurrect a task archived underneath it" \
  'archive_under_lock_refused task-lock-set b dm-task.sh set task-lock-set model sonnet'
b dm-task.sh new task-lock-event --kind scout --repo demo >/dev/null
check "event parked on the task lock cannot resurrect a task archived underneath it" \
  'archive_under_lock_refused task-lock-event b dm-task.sh event task-lock-event working racing'

printf 'kind=ship\n' > "$DM_HOME/state/tasks/task-malformed.meta"
cp "$DM_HOME/state/tasks/task-malformed.meta" "$TMP/task-malformed.before"
check "set rejects an incomplete active record unchanged" \
  '! b dm-task.sh set task-malformed model opus >/dev/null 2>&1 && cmp -s "$TMP/task-malformed.before" "$DM_HOME/state/tasks/task-malformed.meta"'
check "event rejects an incomplete active record without a status ghost" \
  '! b dm-task.sh event task-malformed working started >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-malformed.status" ]'
rm -f "$DM_HOME/state/tasks/task-malformed.meta"

b dm-task.sh new task-valid --kind scout --repo demo --mode pipeline >/dev/null
b dm-task.sh set task-valid kind ship >/dev/null
b dm-task.sh set task-valid mode local-only >/dev/null
b dm-task.sh event task-valid working started >/dev/null
check "legal kind/mode transitions and public event still work" \
  '[ "$(b dm-task.sh get task-valid kind)" = ship ] && [ "$(b dm-task.sh get task-valid mode)" = local-only ] && grep -q " working: started" "$DM_HOME/state/tasks/task-valid.status"'
check "new rejects an invalid effective mode without task files" \
  '! b dm-task.sh new task-bad-mode --kind ship --repo demo --mode invalid >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-bad-mode.meta" ] && [ ! -e "$DM_HOME/state/tasks/task-bad-mode.status" ]'
check "new rejects a multiline title without partial task files" \
  '! b dm-task.sh new task-bad-title --kind ship --repo demo --title $'"'"'ordinary\nforged'"'"' >/dev/null 2>&1 && [ ! -e "$DM_HOME/state/tasks/task-bad-title.meta" ] && [ ! -e "$DM_HOME/state/tasks/task-bad-title.status" ]'
check "new names the missing --kind flag" \
  'ERR="$(b dm-task.sh new task-nokind --repo demo 2>&1 || true)"; grep -q -- "--kind" <<<"$ERR"'
check "new names the missing --repo flag" \
  'ERR="$(b dm-task.sh new task-norepo --kind ship 2>&1 || true)"; grep -q -- "--repo" <<<"$ERR"'
# An interrupted create strands a .status with no .meta, bricking the id. The
# refusal must name the file, and must never tell the operator to delete it.
printf '2000-01-01T00:00:00Z created: interrupted\n' > "$DM_HOME/state/tasks/task-orphan.status"
check "new names the orphan status file blocking a reused id" \
  'ERR="$(b dm-task.sh new task-orphan --kind ship --repo demo 2>&1 || true)"; grep -q "mv .*task-orphan\.status" <<<"$ERR" && ! grep -q "rm " <<<"$ERR" && [ ! -e "$DM_HOME/state/tasks/task-orphan.meta" ]'
rm -f "$DM_HOME/state/tasks/task-orphan.status"
# An interrupted ARCHIVE strands the same shape (archive moves .meta first), but
# that .status is the archived task's only history — deleting it loses real data.
b dm-task.sh new task-halfarch --kind scout --repo demo >/dev/null
mkdir -p "$DM_HOME/data/task-halfarch"
printf 'complete\n' > "$DM_HOME/data/task-halfarch/report.md"
b dm-task.sh archive task-halfarch >/dev/null
mv "$DM_HOME/state/archive/task-halfarch.status" "$DM_HOME/state/tasks/task-halfarch.status"
check "new points an interrupted archive at finishing it, never at deleting history" \
  'ERR="$(b dm-task.sh new task-halfarch --kind ship --repo demo 2>&1 || true)"; grep -q "archived" <<<"$ERR" && grep -q "mv .*task-halfarch\.status" <<<"$ERR" && ! grep -q "rm " <<<"$ERR" && [ -f "$DM_HOME/state/tasks/task-halfarch.status" ]'
check "the named repair actually frees the id" \
  'eval "$(b dm-task.sh new task-halfarch --kind ship --repo demo 2>&1 | sed -n "s/.*free the id: //p")" && b dm-task.sh new task-halfarch --kind ship --repo demo >/dev/null 2>&1 && [ -f "$DM_HOME/state/archive/task-halfarch.status" ]'
cp "$DM_HOME/state/tasks/task-valid.meta" "$TMP/task-valid.meta.before"
cp "$DM_HOME/state/tasks/task-valid.status" "$TMP/task-valid.status.before"
check "set rejects an invalid kind unchanged" \
  '! b dm-task.sh set task-valid kind invalid >/dev/null 2>&1 && cmp -s "$TMP/task-valid.meta.before" "$DM_HOME/state/tasks/task-valid.meta"'
check "set rejects an invalid mode unchanged" \
  '! b dm-task.sh set task-valid mode invalid >/dev/null 2>&1 && cmp -s "$TMP/task-valid.meta.before" "$DM_HOME/state/tasks/task-valid.meta"'
check "set reserves worktree without changing task meta" \
  '! b dm-task.sh set task-valid worktree "$TMP/unrelated-git-dir" >/dev/null 2>&1 && cmp -s "$TMP/task-valid.meta.before" "$DM_HOME/state/tasks/task-valid.meta"'
check "event rejects an undocumented public state unchanged" \
  '! b dm-task.sh event task-valid invented-state note >/dev/null 2>&1 && cmp -s "$TMP/task-valid.status.before" "$DM_HOME/state/tasks/task-valid.status"'
check "event rejects an LF-bearing note unchanged" \
  '! b dm-task.sh event task-valid working $'"'"'ordinary\n2000-01-01T00:00:00Z merged: forged'"'"' >/dev/null 2>&1 && cmp -s "$TMP/task-valid.status.before" "$DM_HOME/state/tasks/task-valid.status"'
check "event rejects a CR-bearing state unchanged" \
  '! b dm-task.sh event task-valid $'"'"'working\rmerged'"'"' ordinary >/dev/null 2>&1 && cmp -s "$TMP/task-valid.status.before" "$DM_HOME/state/tasks/task-valid.status"'
check "status serialization owner rejects multiline internal input" \
  '! ( . "$ROOT/bin/dm-lib.sh"; dm_status_append task-valid working $'"'"'ordinary\nforged'"'"' ) >/dev/null 2>&1 && cmp -s "$TMP/task-valid.status.before" "$DM_HOME/state/tasks/task-valid.status"'
check "rejected event injection cannot forge landed state" \
  'OUT="$(b dm-task.sh state task-valid)"; ! grep -q "state: done" <<<"$OUT"'

CREATE_ID="task-create-race"
# One REGISTERED repo per creator: `new` refuses an unregistered --repo (#124),
# and `repo` has to stay a DISCRIMINATOR — it is what ties the winning meta back
# to the creator its title names, so a torn write blending two creators is
# visible. A constant here would make that check unfailable.
for i in $(seq 1 20); do
  b dm-repo.sh add "repo-$i" "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
done
CREATE_LOCK="$DM_HOME/state/tasks/$CREATE_ID.meta.lock"
mkdir "$CREATE_LOCK"
printf '%s\n' "$$" > "$CREATE_LOCK/pid"
CREATE_PIDS=""
for i in $(seq 1 20); do
  (
    create_mode="pipeline"; [ $((i % 2)) -eq 0 ] && create_mode="direct-pr"
    if b dm-task.sh new "$CREATE_ID" --kind ship --repo "repo-$i" --mode "$create_mode" --title "creator-$i" \
      >"$TMP/create-race.$i.out" 2>"$TMP/create-race.$i.err"; then create_rc=0; else create_rc=$?; fi
    printf '%s\n' "$create_rc" > "$TMP/create-race.$i.rc"
  ) &
  CREATE_PIDS="$CREATE_PIDS $!"
done
# Keep every creator behind the same task lock until all have passed startup.
sleep 1
rm -f "$CREATE_LOCK/pid"; rmdir "$CREATE_LOCK"
for create_pid in $CREATE_PIDS; do wait "$create_pid" || true; done
CREATE_SUCCESSES=0; CREATE_BAD_ERRORS=0
for i in $(seq 1 20); do
  create_rc="$(cat "$TMP/create-race.$i.rc")"
  if [ "$create_rc" -eq 0 ]; then
    CREATE_SUCCESSES=$((CREATE_SUCCESSES + 1))
  elif ! grep -q "already exists" "$TMP/create-race.$i.err"; then
    CREATE_BAD_ERRORS=$((CREATE_BAD_ERRORS + 1))
  fi
done
CREATE_TITLE="$(b dm-task.sh get "$CREATE_ID" title)"
CREATE_WINNER="${CREATE_TITLE#creator-}"
case "$CREATE_WINNER" in
  ''|*[!0-9]*) CREATE_EXPECTED_MODE="invalid" ;;
  *) CREATE_EXPECTED_MODE="pipeline"; [ $((CREATE_WINNER % 2)) -eq 0 ] && CREATE_EXPECTED_MODE="direct-pr" ;;
esac
check "same-id concurrent creation has exactly one visible winner" \
  '[ "$CREATE_SUCCESSES" -eq 1 ] && [ "$CREATE_BAD_ERRORS" -eq 0 ]'
check "concurrent creation meta belongs to one creator" \
  '[ "$(b dm-task.sh get "$CREATE_ID" repo)" = "repo-$CREATE_WINNER" ] && [ "$(b dm-task.sh get "$CREATE_ID" mode)" = "$CREATE_EXPECTED_MODE" ]'
check "concurrent creation writes exactly the winner status" \
  '[ "$(wc -l < "$DM_HOME/state/tasks/$CREATE_ID.status")" -eq 1 ] && grep -q " created: creator-$CREATE_WINNER$" "$DM_HOME/state/tasks/$CREATE_ID.status"'

echo "== concurrent meta writes (locking; no lost update) =="
b dm-task.sh new conc --kind ship --repo demo >/dev/null
for i in $(seq 1 20); do b dm-task.sh set conc "k$i" "v$i" & done
wait
missing=0
for i in $(seq 1 20); do [ "$(b dm-task.sh get conc "k$i")" = "v$i" ] || missing=$((missing+1)); done
check "all 20 concurrent keys survived" '[ "$missing" -eq 0 ]'

echo "== gitignore =="
check "gitignore ignores settings.local.json" 'git -C "$ROOT" check-ignore .claude/settings.local.json >/dev/null'

# shard:bootstrap
echo "== guarded land + teardown =="
check "local land ff"    'b dm-merge.sh local demo-1 >/dev/null'
check "no-fetch landed: reports landed" 'DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 >/dev/null 2>&1'
LANDEDJ_LANDED="$(DM_NO_FETCH=1 b dm-worktree.sh landed demo-1 --json)"
check "landed --json state is landed"   '[ "$(jq -r ".state" <<<"$LANDEDJ_LANDED")" = "landed" ]'
check "state done"       'OUT="$(b dm-task.sh state demo-1)"; grep -q done <<<"$OUT"'
# demo-1's task state is now `done` (landed above). Even with the backlog moved
# back to inflight (NOT done), `ready` unblocks demo-2 from the reconciled task
# state — the "landed but never marked done" case the old status-only check missed.
b dm-backlog.sh move demo-1 inflight >/dev/null
check "ready unblocks from real task state, not backlog status" 'OUT="$(b dm-backlog.sh ready)"; grep -q demo-2 <<<"$OUT"'
check "teardown ok"      'b dm-worktree.sh remove demo-1 >/dev/null'
check "origin has commit" 'OUT="$(git -C "$DM_HOME/repos/demo" log --oneline)"; grep -q "add multiply" <<<"$OUT"'

# shard:bootstrap
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

echo "== teardown tolerates disposable tool cruft, not real work (#84) =="
# A worktree venv/test run drops predictable regenerable cruft (uv.lock,
# __pycache__, coverage, htmlcov) the managed repo may not gitignore. Teardown
# must not force reflexive --force past it, yet must still fail closed on any
# real untracked file. Dedicated clone with global excludes neutralized so the
# classifier is exercised deterministically regardless of the runner's ~/.gitconfig.
b dm-repo.sh add cruft "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/cruft" config core.excludesFile /dev/null
# (a) disposable-only cruft on a LANDED worktree -> teardown succeeds w/o --force.
b dm-task.sh new cruft-ok --kind ship --repo cruft --mode local-only >/dev/null
COK="$(b dm-worktree.sh create cruft-ok cruft | tail -n1)"
git -C "$COK" checkout -q -b feat/x/cruft-ok
printf 'def sub(a,b):\n    return a-b\n' >> "$COK/src/calc.py"
git -C "$COK" -c user.email=c@c.co -c user.name=c commit -qam "add subtract" >/dev/null
b dm-merge.sh local cruft-ok >/dev/null
printf 'lock\n' > "$COK/uv.lock"; printf 'lock\n' > "$COK/src/uv.lock"
mkdir -p "$COK/src/__pycache__"; printf '\n' > "$COK/src/__pycache__/calc.cpython-311.pyc"
mkdir -p "$COK/htmlcov"; printf '<html></html>\n' > "$COK/htmlcov/index.html"
printf '1\n' > "$COK/.coverage"
check "disposable cruft is genuinely untracked" '[ -n "$(git -C "$COK" ls-files --others --exclude-standard)" ]'
check "teardown accepts disposable-only cruft without --force" 'b dm-worktree.sh remove cruft-ok >/dev/null 2>&1'
check "cruft-only worktree is gone" '[ ! -d "$COK" ]'
# (b) a real untracked source file amid cruft -> teardown still REFUSES w/o
# --force, and the message names the real file, never the disposable cruft.
b dm-task.sh new cruft-bad --kind ship --repo cruft --mode local-only >/dev/null
CBAD="$(b dm-worktree.sh create cruft-bad cruft | tail -n1)"
git -C "$CBAD" checkout -q -b feat/x/cruft-bad
printf 'def sub(a,b):\n    return a-b\n' >> "$CBAD/src/calc.py"
git -C "$CBAD" -c user.email=c@c.co -c user.name=c commit -qam "add subtract" >/dev/null
b dm-merge.sh local cruft-bad >/dev/null
printf 'lock\n' > "$CBAD/uv.lock"; printf 'scratch\n' > "$CBAD/notes.py"
CBAD_OUT="$(b dm-worktree.sh remove cruft-bad 2>&1 || true)"
check "teardown refuses a real untracked file amid cruft" '! b dm-worktree.sh remove cruft-bad >/dev/null 2>&1'
check "refusal names the real file, not the cruft" 'grep -q "notes.py" <<<"$CBAD_OUT" && ! grep -q "uv.lock" <<<"$CBAD_OUT"'
b dm-worktree.sh remove cruft-bad --force >/dev/null 2>&1

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
STATUS_BAD="$(b dm-status.sh 2>&1 || true)"
check "status fails malformed secondmate identity state" '! b dm-status.sh >/dev/null 2>&1 && grep -q "FAIL supervisor state" <<<"$STATUS_BAD" && ! grep -q "(none registered)" <<<"$STATUS_BAD"'
SESSION_BAD="$(b dm-session-start.sh --no-sync 2>&1 || true)"
check "session start fails malformed supervisor section" '! b dm-session-start.sh --no-sync >/dev/null 2>&1 && grep -q "DOMAIN SUPERVISORS" <<<"$SESSION_BAD" && grep -q "FAIL supervisor state" <<<"$SESSION_BAD" && grep -q "NOT READY" <<<"$SESSION_BAD"'
cp "$TMP/secondmates.bak" "$DM_HOME/state/secondmates.json"

# shard:split
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
# --json answers the same question but EXITS 0, because a reader cannot tell the
# human form's "exit 1 = tangled" from the script having failed - which is how a
# tangled clone came to render as "On main" in the console.
TANGLEJ="$(b dm-worktree.sh tangle demo --json)"
check "tangle --json exits 0 on a tangled clone" 'b dm-worktree.sh tangle demo --json >/dev/null'
check "tangle --json says it is tangled"    '[ "$(jq -r ".tangled" <<<"$TANGLEJ")" = "true" ]'
check "tangle --json names the branch it is on" '[ "$(jq -r ".on" <<<"$TANGLEJ")" = "sidebranch" ]'
check "tangle --json names the one expected"    '[ "$(jq -r ".expected" <<<"$TANGLEJ")" = "main" ]'
check "tangle --json carries no path or command" '! grep -qE "/|checkout" <<<"$TANGLEJ"'
git -C "$DM_HOME/repos/demo" checkout -q main
git -C "$DM_HOME/repos/demo" branch -q -D sidebranch
check "tangle: clears after return to default" 'b dm-worktree.sh tangle demo >/dev/null 2>&1'
check "tangle --json says tangled false on the default branch" \
  '[ "$(b dm-worktree.sh tangle demo --json | jq -r ".tangled")" = "false" ]'

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

echo "== worktree cleanup safety matrix (#100/#117/#120/#127) =="
SC_RC=0; SC_OUT="$(bash "$ROOT/tests/scout-cleanup.sh" 2>&1)" || SC_RC=$?
SC_N="$(grep -cE '^  (ok|FAIL) ' <<<"$SC_OUT" || true)"
check "cleanup safety matrix passes" '[ "$SC_RC" -eq 0 ]'
# A matrix that ABORTS mid-run still reports a single red line while silently
# skipping everything after it — #130 reserving `worktree` voided 21 checks
# exactly that way. A floor on the executed count makes the loss visible.
check "cleanup safety matrix runs every case" '[ "${SC_N:-0}" -ge 98 ]'
printf '    matrix checks executed: %s\n' "$SC_N"
# Surface which sub-suite cases moved; one pass/fail line hides the whole matrix.
[ "$SC_RC" -eq 0 ] || printf '%s\n' "$SC_OUT" | sed 's/^/    /'

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
RBCLEANOUT="$(b dm-merge.sh rebase rb-clean 2>&1 || true)"   # already up to date: a no-op rebase that still names the base
check "non-stacked rebase message names the default branch" 'grep -q "onto main" <<<"$RBCLEANOUT"'
git -C "$DM_HOME/repos/demo" checkout -q main   # leave the demo clone on default for later sections

echo "== merge rebase honors a stacked task's recorded parent, not default (#72) =="
# A worktree created with --base <parent> records the parent in task meta
# (dm_pr_base_for). Rebase must restack onto that PARENT tip, not silently
# no-op onto main, or a stacked child never picks up its parent's new commits.
b dm-repo.sh add stackreb "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/stackreb" checkout -q -b parent-branch
printf 'parent v1\n' > "$DM_HOME/repos/stackreb/parent.txt"
git -C "$DM_HOME/repos/stackreb" -c user.email=c@c.co -c user.name=c add parent.txt >/dev/null
git -C "$DM_HOME/repos/stackreb" -c user.email=c@c.co -c user.name=c commit -qm "parent v1"
git -C "$DM_HOME/repos/stackreb" push -q origin parent-branch >/dev/null 2>&1
git -C "$DM_HOME/repos/stackreb" checkout -q main

b dm-task.sh new stack-child --kind ship --repo stackreb >/dev/null
SRWT="$(b dm-worktree.sh create stack-child stackreb feat/x/stack-child --base parent-branch | tail -n1)"
printf 'child feature\n' > "$SRWT/child.txt"
git -C "$SRWT" -c user.email=c@c.co -c user.name=c add child.txt >/dev/null
git -C "$SRWT" -c user.email=c@c.co -c user.name=c commit -qm "child feature"
check "stacked worktree records the parent as base" '[ "$(b dm-task.sh get stack-child base)" = "parent-branch" ]'

# Advance the parent branch on ORIGIN via an independent clone (as another
# crewmate pushing to the parent PR would), past what the child branched from
# and past what main has, WITHOUT touching the stackreb clone's own checkout.
git clone -q "$TMP/origin.git" "$TMP/stackreb-seed" >/dev/null 2>&1
( cd "$TMP/stackreb-seed"; git config user.email c@c.co; git config user.name c
  git checkout -q parent-branch
  printf 'parent v2\n' >> parent.txt
  git commit -qam "parent v2"
  git push -q origin parent-branch ) >/dev/null 2>&1
PARENT_V2_SHA="$(git -C "$TMP/stackreb-seed" rev-parse parent-branch)"
check "main lacks the parent's newer commit" \
  '! git -C "$TMP/stackreb-seed" merge-base --is-ancestor "$PARENT_V2_SHA" origin/main'

if SR_OUT="$(b dm-merge.sh rebase stack-child 2>&1)"; then SR_RC=0; else SR_RC=$?; fi
check "stacked rebase succeeds"                              '[ "$SR_RC" -eq 0 ]'
check "stacked rebase message names the PARENT, not main"    'grep -q "onto parent-branch" <<<"$SR_OUT"'
check "stacked rebase lands onto the parent's newer commit, not just its v1" \
  'git -C "$SRWT" merge-base --is-ancestor "$PARENT_V2_SHA" HEAD'
check "stacked rebase keeps the child feature"               '[ -f "$SRWT/child.txt" ]'
check "stacked rebase stays on its branch"                   '[ "$(git -C "$SRWT" rev-parse --abbrev-ref HEAD)" = "feat/x/stack-child" ]'

# shard:bootstrap
echo "== dm-memory (native plain-markdown context) =="
# seed scaffolds only the git-excluded private store; it never touches the clone's
# AGENTS.md, so the clone stays pristine (landable and fast-forward-syncable).
b dm-memory.sh seed demo >/dev/null
check "seed creates the private notes store"          '[ -f "$DM_HOME/repos/demo/.dm/notes.md" ]'
check "seed git-excludes the private store"           'grep -qxF ".dm/" "$DM_HOME/repos/demo/.git/info/exclude"'
check "seed leaves the clone pristine"                '[ -z "$(git -C "$DM_HOME/repos/demo" status --porcelain)" ]'
check "seed is idempotent"                            'b dm-memory.sh seed demo >/dev/null 2>&1'
# A committed LEGACY dm:knowledge block in AGENTS.md must still surface in recall
# (back-compat / migration); simulate one and assert recall surfaces + filters it.
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
check "remember with no store selector is refused" '! b dm-memory.sh remember demo --kind command "x" >/dev/null 2>&1'
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

echo "== dm-memory: shared knowledge via committed per-task files (#81) =="
# SHARED knowledge is one committed file per note under .dm-knowledge/, written into
# a worktree by `remember <id> --shared`. Two concurrent tasks write DIFFERENT files
# (named by task id) so recording knowledge never collides on a hot AGENTS.md block.
b dm-repo.sh add shknow "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new shk-a --kind ship --repo shknow >/dev/null
b dm-task.sh new shk-b --kind ship --repo shknow >/dev/null
SKWA="$(b dm-worktree.sh create shk-a shknow | tail -n1)"
SKWB="$(b dm-worktree.sh create shk-b shknow | tail -n1)"
git -C "$SKWA" checkout -q -b feat/x/shk-a
git -C "$SKWB" checkout -q -b feat/x/shk-b
b dm-memory.sh remember shk-a --shared --kind convention "note ALPHA from shk-a" >/dev/null
b dm-memory.sh remember shk-b --shared --kind convention "note BETA from shk-b" >/dev/null
check "shared note A lands in task A's own worktree file" '[ -f "$SKWA/.dm-knowledge/shk-a.md" ] && grep -q "note ALPHA from shk-a" "$SKWA/.dm-knowledge/shk-a.md"'
check "shared note B lands in task B's own worktree file" '[ -f "$SKWB/.dm-knowledge/shk-b.md" ] && grep -q "note BETA from shk-b" "$SKWB/.dm-knowledge/shk-b.md"'
check "the two tasks write different note files"          '[ "$SKWA/.dm-knowledge/shk-a.md" != "$SKWB/.dm-knowledge/shk-b.md" ] && ! grep -q "BETA" "$SKWA/.dm-knowledge/shk-a.md"'
check "shared remember refuses a task with no worktree"   '! b dm-memory.sh remember no-such-task --shared --kind command "x" >/dev/null 2>&1'
check "shared remember rejects an invalid kind"           '! b dm-memory.sh remember shk-a --shared --kind bogus "x" >/dev/null 2>&1'
git -C "$SKWA" add .dm-knowledge/shk-a.md && git -C "$SKWA" -c user.email=c@c.co -c user.name=c commit -qm "knowledge A" >/dev/null
git -C "$SKWB" add .dm-knowledge/shk-b.md && git -C "$SKWB" -c user.email=c@c.co -c user.name=c commit -qm "knowledge B" >/dev/null
# Land A, then B. B is behind after A lands; a rebase must replay CLEANLY because
# each task touched a DIFFERENT file — the exact conflict the old hot AGENTS.md
# block manufactured on nearly every PR (#81).
check "first shared note lands"                       'b dm-merge.sh local shk-a >/dev/null'
check "second note rebases without a notes collision" 'b dm-merge.sh rebase shk-b >/dev/null 2>&1'
check "second shared note lands"                      'b dm-merge.sh local shk-b >/dev/null'
check "both notes are committed in the clone" 'LS="$(git -C "$DM_HOME/repos/shknow" ls-files .dm-knowledge)"; grep -q "shk-a.md" <<<"$LS" && grep -q "shk-b.md" <<<"$LS"'
SKREC="$(b dm-memory.sh recall shknow)"
check "recall surfaces both landed shared notes" 'grep -q "note ALPHA from shk-a" <<<"$SKREC" && grep -q "note BETA from shk-b" <<<"$SKREC"'
# The brief must point crewmates at the new mechanism AND relay the landed notes.
b dm-task.sh new shk-brief --kind ship --repo shknow >/dev/null
b dm-worktree.sh create shk-brief shknow >/dev/null 2>&1
b dm-brief.sh shk-brief >/dev/null 2>/dev/null
check "brief surfaces landed shared notes"     'grep -q "note ALPHA from shk-a" "$DM_HOME/data/shk-brief/brief.md"'
check "brief points crewmates at remember --shared" 'grep -q -- "--shared" "$DM_HOME/data/shk-brief/brief.md"'

echo "== dm-memory: recall assembles directory notes + legacy AGENTS.md block (migration) =="
# demo carries a legacy committed dm:knowledge block in AGENTS.md (above). A
# .dm-knowledge/ note must surface ALONGSIDE it, so pre-existing inline knowledge is
# never stranded by the move to per-file notes.
mkdir -p "$DM_HOME/repos/demo/.dm-knowledge"
printf -- '- **[convention]** use ruff for lint\n' > "$DM_HOME/repos/demo/.dm-knowledge/mig-note.md"
MIGREC="$(b dm-memory.sh recall demo)"
check "recall surfaces a .dm-knowledge note"             'grep -q "use ruff for lint" <<<"$MIGREC"'
check "recall still surfaces the legacy AGENTS.md block" 'grep -q "pytest -q" <<<"$MIGREC"'
rm -rf "$DM_HOME/repos/demo/.dm-knowledge"

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
# === docs-doctor tests (#24, #104) ===
echo "== doctor tool tiers and honest verdict (#24, #104) =="
# gh presence/auth now qualifies the verdict, so stub gh rather than inheriting
# the developer's (or a CI runner's) real login state. NOAXI_PATH additionally
# makes "no axi tooling installed" true rather than machine-dependent.
DOC_GH_OK="$TMP/doctor-gh-ok"; DOC_GH_NOAUTH="$TMP/doctor-gh-noauth"
mkdir -p "$DOC_GH_OK" "$DOC_GH_NOAUTH"
printf '#!/bin/sh\nexit 0\n' > "$DOC_GH_OK/gh"
printf '#!/bin/sh\ncase "$1" in auth) exit 1 ;; esac\nexit 0\n' > "$DOC_GH_NOAUTH/gh"
chmod +x "$DOC_GH_OK/gh" "$DOC_GH_NOAUTH/gh"
DOCF="$(PATH="$DOC_GH_OK:$NOAXI_PATH" b dm-doctor.sh 2>&1 || true)"   # capture once (grep -q + pipefail)
check "doctor verdict is a plain READY when the PR path works" 'grep -q "^  READY: " <<<"$DOCF"'
check "doctor lists chrome-devtools-axi"                       'grep -q "chrome-devtools-axi" <<<"$DOCF"'
# The axi wrappers must never read as required: a fresh clone without them still
# gets a green verdict, matching the README contract.
AXILINES="$(grep -E 'gh-axi|lavish-axi|chrome-devtools-axi' <<<"$DOCF" || true)"
check "doctor does not mark axi tools required"           '! grep -qi "required" <<<"$AXILINES"'
check "doctor names what each axi tool degrades"          'grep -q "plain gh does the same work" <<<"$AXILINES" && grep -q "review the change directly" <<<"$AXILINES"'
# Tiering is the operator-visible half of the #104 contract, and it drifted once
# already: gh-axi sat in the PR-FLOW tier while the README called it optional.
# Assert the tier LABEL doctor prints against gh-axi, not just its presence.
check "gh-axi sits in the optional tier, not PR-flow" \
  'CTX="$(grep -A1 "^  warn     gh-axi" <<<"$DOCF")"; grep -q "\^ optional —" <<<"$CTX" && ! grep -q "needed for the PR flow" <<<"$CTX"'
check "the gh line claims the whole PR flow, reads and mutations" \
  'grep -qE "^  ok       gh .*reads and mutations" <<<"$DOCF"'
# The README sentence the parity suite pins must actually be there; parity
# catches rewording, this catches the two drifting apart.
check "the README states the plain-gh baseline parity pins" \
  'grep -q "Every GitHub call the toolbelt makes runs" "$ROOT/README.md"'
check "check mode still exits 0 without axi tools"        'PATH="$DOC_GH_OK:$NOAXI_PATH" b dm-doctor.sh check >/dev/null'
# The honesty defect (#104): doctor used to print a bare READY in a home where
# delivery could not work, so an adopter learned it at their first PR.
DOC_NOAUTH="$(PATH="$DOC_GH_NOAUTH:$NOAXI_PATH" b dm-doctor.sh 2>&1 || true)"
check "an unauthenticated gh never gets a plain READY"    '! grep -q "^  READY: " <<<"$DOC_NOAUTH"'
check "the qualified verdict names the local-only reality" 'grep -q "READY (LOCAL-ONLY)" <<<"$DOC_NOAUTH"'
check "the qualified verdict names the unreachable path"   'grep -q "PR DELIVERY UNAVAILABLE" <<<"$DOC_NOAUTH"'
check "the qualified verdict names the fix"                'grep -q "gh auth login" <<<"$DOC_NOAUTH"'
check "the qualified verdict still exits 0 (local-only is real)" \
  'PATH="$DOC_GH_NOAUTH:$NOAXI_PATH" b dm-doctor.sh >/dev/null 2>&1'
check "the tooling section flags pr-delivery in both modes" \
  'OUT="$(PATH="$DOC_GH_NOAUTH:$NOAXI_PATH" b dm-doctor.sh check 2>&1 || true)"; grep -q "pr-delivery.*UNAVAILABLE" <<<"$OUT"'
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

echo "== await-checks: pure head-terminality predicate + poll gate (#75) =="
# Pure like dm_merge_gate, testable offline. dm_await_needs_head answers "is this
# rollup terminal for the current head SHA?" — i.e. must the caller verify the
# rolled-up head before trusting it. dm_await_gate maps a head-reconciled
# observation to pass/fail/dirty/wait; the caller downgrades a stale/mismatched
# head to a non-terminal rollup BEFORE the gate, so a DIFFERENT-sha rollup can
# never be terminal (the end-to-end stale-head path is covered under #75 below).
needshead() { ( . "$ROOT/bin/dm-lib.sh"; if dm_await_needs_head "$1" "$2" "$3"; then echo yes; else echo no; fi ); }
awgate()    { ( . "$ROOT/bin/dm-lib.sh"; dm_await_gate "$1" "$2" "$3" ); }
check "needs-head verifies a passing rollup"            '[ "$(needshead passing clean 1)" = yes ]'
check "needs-head verifies a failing rollup"            '[ "$(needshead failing clean 1)" = yes ]'
check "needs-head verifies dirty over any rollup"       '[ "$(needshead pending dirty 1)" = yes ] && [ "$(needshead unknown dirty 0)" = yes ]'
check "needs-head verifies none only on a CI-less repo" '[ "$(needshead none clean 0)" = yes ] && [ "$(needshead none clean 1)" = no ]'
check "needs-head skips pending/unknown"                '[ "$(needshead pending clean 1)" = no ] && [ "$(needshead unknown clean 1)" = no ]'
check "gate passes a matching-head green"               '[ "$(awgate passing clean 1)" = pass ]'
check "gate fails a matching-head red"                  '[ "$(awgate failing clean 1)" = fail ]'
check "gate short-circuits dirty over any rollup"       '[ "$(awgate passing dirty 1)" = dirty ] && [ "$(awgate failing dirty 0)" = dirty ]'
check "gate keeps a downgraded stale-head rollup non-terminal" '[ "$(awgate pending unknown 1)" = wait ]'
check "gate waits on a CI repo reporting none"          '[ "$(awgate none clean 1)" = wait ]'
check "gate passes none only on a confirmed CI-less repo" '[ "$(awgate none clean 0)" = pass ]'
check "gate waits on pending and unknown"               '[ "$(awgate pending clean 1)" = wait ] && [ "$(awgate unknown clean 1)" = wait ]'

echo "== dispatch right-sizing: dm-status flags an unsized dispatch (#77, #166) =="
# A live `working` task missing EITHER dial is an unsized dispatch; the hint
# names how to fix it and clears only once both are recorded.
b dm-task.sh new unsized-1 --kind ship --repo demo --title "add a widget" >/dev/null
b dm-task.sh event unsized-1 working "started" >/dev/null
UNSIZED_STATUS="$(b dm-status.sh)"   # capture once (grep -q + pipefail)
check "status flags a working task with no model as UNSIZED" 'grep -q "UNSIZED.*unsized-1" <<<"$UNSIZED_STATUS"'
check "UNSIZED hint names how to fix it"                     'grep -q "UNSIZED.*unsized-1.*record both: dm-task.sh set unsized-1 model <tier>; dm-task.sh set unsized-1 effort <level>" <<<"$UNSIZED_STATUS"'
b dm-task.sh set unsized-1 model sonnet >/dev/null
HALF_SIZED_STATUS="$(b dm-status.sh)"
check "a model alone does NOT clear UNSIZED"                 'grep -q "UNSIZED.*unsized-1.*no effort recorded" <<<"$HALF_SIZED_STATUS"'
b dm-task.sh set unsized-1 effort low >/dev/null
SIZED_STATUS="$(b dm-status.sh)"
check "recording both dials clears the UNSIZED flag"         '! grep -q "UNSIZED.*unsized-1" <<<"$SIZED_STATUS"'

echo "== state-gate-integrity: pr_state cannot be forged via 'set' (#20 F6) =="
b dm-task.sh new sgi-forge --kind ship --repo sgi >/dev/null 2>&1 || true
for protected_field in pr pr_state merge_state pr_check_snapshot base worktree; do
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
# A missing clone must be surfaced per-line, not abort the sweep. The repo is
# REGISTERED and its clone then deleted: `new` refuses an unregistered --repo
# (#124), so "no clone" is now the only way to reach this branch.
b dm-repo.sh add sweepnoclone "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
rm -rf "$DM_HOME/repos/sweepnoclone"
b dm-task.sh new sweep-noclone --kind ship --repo sweepnoclone >/dev/null 2>&1 || true
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set sweep-noclone pr "https://github.com/o/r/pull/9" ) >/dev/null 2>&1
SWEEP2="$(DM_NO_FETCH=1 b dm-pr.sh sweep 2>&1 || true)"
check "sweep flags a missing clone, keeps going" 'grep -q "clone missing" <<<"$SWEEP2" && grep -q "sweep-open" <<<"$SWEEP2"'
# The sweep's HUMAN lines, pinned byte for byte. Other callers and tests read
# them, and adding `sweep --json` (#192) edited every one of these printfs -
# "it still contains the id" would not have caught a changed separator or a
# dropped `?` placeholder. -x -F: whole line, literal, no regex.
check "the cached sweep line is unchanged, to the byte" \
  'grep -qxF "  sweep-open  state: ?  checks: ? (cached)  reviews: (no fetch)  https://github.com/o/r/pull/1" <<<"$SWEEP2"'
check "the missing-clone sweep line is unchanged, to the byte" \
  'grep -qxF "  sweep-noclone  (repo unregistered or clone missing: sweepnoclone — skipped)  https://github.com/o/r/pull/9" <<<"$SWEEP2"'

echo "== pr-sweep: the cache write-back never clobbers, never aborts =="
# The ONLINE write-back is where two races meet, and both were untested: between
# the enumeration and the write, (1) another command can establish a TERMINAL PR
# state that this pre-close snapshot would overwrite, and (2) the task can be
# archived out from under it, which used to abort the whole sweep — a live path,
# since the console refresh runs it. The stub creates each race deterministically
# by acting on the record WHILE it answers.
b dm-repo.sh add sweepguard "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/sweepguard" remote set-url origin o/r.git
b dm-task.sh new sweep-race-closed  --kind ship --repo sweepguard >/dev/null
b dm-task.sh new sweep-race-archive --kind ship --repo sweepguard >/dev/null
( . "$ROOT/bin/dm-lib.sh"
  dm_meta_set sweep-race-closed  pr "https://github.com/o/r/pull/51"
  dm_meta_set sweep-race-closed  pr_state OPEN
  dm_meta_set sweep-race-archive pr "https://github.com/o/r/pull/52"
  dm_meta_set sweep-race-archive pr_state OPEN ) >/dev/null 2>&1
SWGSTUB="$TMP/sweep-guard-stub"; mkdir -p "$SWGSTUB"
cat > "$SWGSTUB/gh" <<STUB
#!/usr/bin/env bash
# Answers OPEN for both PRs, but first does what a concurrent command would:
# pull/51's task gets closed, pull/52's task gets archived.
case "\$*" in
  *number=51*)
    ( . "$ROOT/bin/dm-lib.sh"; dm_meta_set sweep-race-closed pr_state CLOSED ) >/dev/null 2>&1 ;;
  *number=52*)
    mkdir -p "$DM_HOME/state/archive"
    mv "$DM_HOME/state/tasks/sweep-race-archive.meta" "$DM_HOME/state/archive/sweep-race-archive.meta"
    mv "$DM_HOME/state/tasks/sweep-race-archive.status" "$DM_HOME/state/archive/sweep-race-archive.status" ;;
esac
cat <<'JSON'
{"data":{"repository":{"pullRequest":{"merged":false,"state":"OPEN",
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]},
 "reviews":{"nodes":[],"pageInfo":{"hasNextPage":false}},
 "headRefOid":"abc123","title":"race","createdAt":"2026-01-01T00:00:00Z"}}}}
JSON
STUB
chmod +x "$SWGSTUB/gh"
SWGRC=0
SWGOUT="$(PATH="$SWGSTUB:$NOAXI_PATH" b dm-pr.sh sweep 2>&1)" || SWGRC=$?
check "the sweep survives a task archived mid-walk"   '[ "$SWGRC" -eq 0 ]'
check "and still reports the rest of the fleet"       'grep -q "open PR(s)" <<<"$SWGOUT"'
check "a terminal CLOSED is not downgraded to OPEN" \
  '[ "$(b dm-task.sh get sweep-race-closed pr_state)" = "CLOSED" ]'
check "the vanished task's write-back is named, not swallowed" \
  'grep -q "could not cache sweep-race-archive" <<<"$SWGOUT"'
check "no archived record was resurrected as active" \
  '[ ! -f "$DM_HOME/state/tasks/sweep-race-archive.meta" ]'

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

# shard:bootstrap
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

# shard:bootstrap
echo "== merge-base exception: dm-pr.sh merge honors the LIVE PR base on a never repo =="
# Give this local fixture a GitHub-shaped, still-local origin: repo_slug resolves
# to o/r while fetches remain hermetic for post-merge sync.
mkdir -p "$DM_HOME/repos/mauth/o"
ln -s "$TMP/origin.git" "$DM_HOME/repos/mauth/o/r.git"
git -C "$DM_HOME/repos/mauth" remote set-url origin o/r.git
b dm-repo.sh set mauth merge_authority never >/dev/null
b dm-repo.sh set mauth merge_allowed_bases "integration" >/dev/null
b dm-task.sh new mauth-exc --kind ship --repo mauth >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set mauth-exc pr "https://github.com/o/r/pull/9" ) >/dev/null 2>&1
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

echo "== merge mutation runs on plain gh, and on gh-axi, with the same outcome (#104) =="
# The two binaries take the SAME request differently (gh-axi puts the method
# positionally; gh needs --method and --raw-field), so the argv is asserted
# per binary — a blind name swap would send a malformed request. A GitHub-shaped
# but still-local origin keeps repo_slug resolvable and the post-merge sync
# hermetic.
b dm-repo.sh add ghfb "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
mkdir -p "$DM_HOME/repos/ghfb/o"
ln -s "$TMP/origin.git" "$DM_HOME/repos/ghfb/o/r.git"
git -C "$DM_HOME/repos/ghfb" remote set-url origin o/r.git
# One stub dir per case: gh answers every parsed read from a fixture file, and
# whichever binary receives the merge PUT records its exact argv.
merge_fixtures() {
  local d="$1" n="$2"
  printf '{"total_count":1,"check_runs":[{"head_sha":"abc123","status":"completed","conclusion":"success"}]}\n' > "$d/runs.json"
  printf '{"total_count":0}\n' > "$d/status.json"
  printf '{"object":{"sha":"abc123"}}\n' > "$d/ref.json"
  printf '{"state":"open","merged":false,"head":{"sha":"abc123","ref":"fix/ghfb-%s","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' "$n" > "$d/pr.json"
}
gh_read_stub() {
  cat <<STUB
D="$1"
case "\$*" in
  *check-runs*) cat "\$D/runs.json"; exit 0 ;;
  *commits*status*) cat "\$D/status.json"; exit 0 ;;
  *git/ref/heads/*) cat "\$D/ref.json"; exit 0 ;;
esac
STUB
}
MFB_GH="$TMP/merge-fallback-gh"; mkdir -p "$MFB_GH"
{ printf '#!/bin/sh\n'; gh_read_stub "$MFB_GH"
  printf 'if [ "$1" = api ] && [ "$2" = --method ]; then printf "%%s\\n" "$*" >> "%s/mutations"; printf "{\\"merged\\":true}\\n"; exit 0; fi\n' "$MFB_GH"
  printf 'cat "%s/pr.json"\n' "$MFB_GH"; } > "$MFB_GH/gh"
chmod +x "$MFB_GH/gh"
merge_fixtures "$MFB_GH" plain
b dm-task.sh new ghfb-plain --kind ship --repo ghfb >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set ghfb-plain pr "https://github.com/o/r/pull/7" ) >/dev/null 2>&1
MFB_GH_OUT="$(PATH="$MFB_GH:$NOAXI_PATH" b dm-pr.sh merge ghfb-plain 2>&1 || true)"
check "merge completes with only plain gh installed" 'grep -q "^merged: https://github.com/o/r/pull/7$" <<<"$MFB_GH_OUT"'
check "the plain-gh mutation uses gh's own argv shape" \
  'grep -Fx "api --method PUT /repos/o/r/pulls/7/merge --raw-field sha=abc123 --raw-field merge_method=squash" "$MFB_GH/mutations" >/dev/null'
check "plain gh records the landed task state"        '[ "$(b dm-task.sh get ghfb-plain pr_state)" = "MERGED" ]'
check "plain gh appends the merged event"             'grep -q " merged: https://github.com/o/r/pull/7" "$DM_HOME/state/tasks/ghfb-plain.status"'

MFB_AXI="$TMP/merge-fallback-axi"; mkdir -p "$MFB_AXI"
{ printf '#!/bin/sh\n'; gh_read_stub "$MFB_AXI"
  printf 'if [ "$1" = api ] && [ "$2" = --method ]; then printf "%%s\\n" "$*" >> "%s/gh-mutations"; exit 1; fi\n' "$MFB_AXI"
  printf 'cat "%s/pr.json"\n' "$MFB_AXI"; } > "$MFB_AXI/gh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/mutations"\nprintf "merged: true\\n"\n' "$MFB_AXI" > "$MFB_AXI/gh-axi"
chmod +x "$MFB_AXI/gh" "$MFB_AXI/gh-axi"
merge_fixtures "$MFB_AXI" wrapper
b dm-task.sh new ghfb-axi --kind ship --repo ghfb >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set ghfb-axi pr "https://github.com/o/r/pull/8" ) >/dev/null 2>&1
MFB_AXI_OUT="$(PATH="$MFB_AXI:$NOAXI_PATH" b dm-pr.sh merge ghfb-axi 2>&1 || true)"
check "merge completes with the wrapper installed"    'grep -q "^merged: https://github.com/o/r/pull/8$" <<<"$MFB_AXI_OUT"'
check "the wrapper mutation keeps its positional-method shape" \
  'grep -Fx "api PUT /repos/o/r/pulls/8/merge --field sha=abc123 --field merge_method=squash" "$MFB_AXI/mutations" >/dev/null'
check "the wrapper path never sent the mutation through plain gh" '[ ! -f "$MFB_AXI/gh-mutations" ]'
check "both CLIs reach the same landed task record" \
  '[ "$(b dm-task.sh get ghfb-axi pr_state)" = "$(b dm-task.sh get ghfb-plain pr_state)" ] && grep -q " merged: https://github.com/o/r/pull/8" "$DM_HOME/state/tasks/ghfb-axi.status"'
echo "== repo resolver: an unregistered repo never resolves to a directory (#119) =="
# Before the fix, `"$DM_HOME/$(dm_registry_get <unknown> path)"` composed to
# $DM_HOME and the `.git` probe passed there (the distro root is a git repo), so
# a typo'd name silently targeted the operator's own control plane. No test in
# the suite drove a script with an unregistered name, which is why it survived.
rdir()  { ( . "$ROOT/bin/dm-lib.sh"; dm_repo_dir "$1" ); }
rdirn() { ( . "$ROOT/bin/dm-lib.sh"; dm_repo_dir_or_none "$1" ); }
check "dm_repo_dir_or_none yields nothing for an unregistered repo" '[ -z "$(rdirn nosuchrepo 2>/dev/null || true)" ] && ! rdirn nosuchrepo >/dev/null 2>&1'
check "dm_repo_dir_or_none yields nothing for an empty name"        '! rdirn "" >/dev/null 2>&1'
check "dm_repo_dir_or_none still resolves a registered repo"        '[ "$(rdirn demo)" = "$DM_HOME/repos/demo" ]'
check "dm_repo_dir dies on an unregistered repo"                    '! rdir nosuchrepo >/dev/null 2>&1'
RESOLVEOUT="$(rdir nosuchrepo 2>&1 || true)"
check "the resolver refusal names the repo and the fix"             'grep -q "nosuchrepo" <<<"$RESOLVEOUT" && grep -q "not registered" <<<"$RESOLVEOUT"'
check "the resolver refusal never prints DM_HOME as the answer"     '! grep -qx "$DM_HOME" <<<"$RESOLVEOUT"'
check "dm_repo_dir still resolves a registered repo"                '[ "$(rdir demo)" = "$DM_HOME/repos/demo" ]'

# Every mutating entry point refuses an unregistered repo BY NAME. The record
# itself is created against a REGISTERED repo: `new` now refuses an unregistered
# --repo outright (#124), so an unregistered name reaches the resolver only as an
# argument, which is exactly how `dm-worktree.sh create` takes it.
b dm-task.sh new unreg-1 --kind ship --repo demo --mode local-only >/dev/null
UNREGWT="$(b dm-worktree.sh create unreg-1 nosuchrepo 2>&1 || true)"
check "worktree create refuses an unregistered repo"      '! b dm-worktree.sh create unreg-1 nosuchrepo >/dev/null 2>&1'
check "the worktree refusal names the repo"               'grep -q "nosuchrepo" <<<"$UNREGWT"'
check "no worktree was created for the unregistered repo" '[ ! -e "$DM_HOME/state/worktrees/unreg-1" ]'
UNREGSYNC="$(b dm-sync.sh one nosuchrepo)"
check "sync reports an unregistered repo, never syncs it" 'grep -q "SKIP: nosuchrepo (not a registered repo)" <<<"$UNREGSYNC" && ! grep -q "fast-forwarded" <<<"$UNREGSYNC"'
# dm-merge.sh local: the authority gate fires first, and an unknown repo must not
# inherit the permissive `ask` default.
mauthr2() { ( . "$ROOT/bin/dm-lib.sh"; dm_merge_authority "$1" ); }
check "merge authority of an unregistered repo is invalid, not ask" '[ "$(mauthr2 nosuchrepo)" = "invalid" ]'
check "merge authority of an empty repo name is invalid"            '[ "$(mauthr2 "")" = "invalid" ]'
check "merge authority of a registered repo is unchanged"           '[ "$(mauthr2 demo)" = "ask" ]'
# A registry entry explicitly set to null is as unknown as an absent one.
jq '.repos["nulled"] = null' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "merge authority of a null registry entry is invalid" '[ "$(mauthr2 nulled)" = "invalid" ]'
jq 'del(.repos["nulled"])' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "new refuses a task against an unregistered repo" '! b dm-task.sh new unreg-2 --kind ship --repo nosuchrepo >/dev/null 2>&1'
# A worktree can no longer exist for an unregistered repo, so reach dm-merge's
# authority gate the way reality would: real work on a registered repo whose
# registry entry then disappears (a removed/renamed repo, a typo'd rename).
b dm-repo.sh add gonerepo "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new gone-1 --kind ship --repo gonerepo --mode local-only >/dev/null
GWT="$(b dm-worktree.sh create gone-1 gonerepo 2>/dev/null | tail -n1)"
git -C "$GWT" checkout -q -b feat/x/gone-1
printf 'g\n' > "$GWT/gone.txt"
git -C "$GWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$GWT" -c user.email=c@c.co -c user.name=c commit -qm "work" >/dev/null
GONE_BEFORE="$(git -C "$DM_HOME/repos/gonerepo" rev-parse main)"
GONE_ENTRY="$(jq -c '.repos["gonerepo"]' "$REG")"
jq 'del(.repos["gonerepo"])' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
UNREGLAND="$(b dm-merge.sh local gone-1 2>&1 || true)"
check "local land refuses once the repo is unregistered" '! b dm-merge.sh local gone-1 >/dev/null 2>&1'
check "the land refusal names the repo and the fix"      'grep -q "gonerepo" <<<"$UNREGLAND" && grep -qi "unregistered" <<<"$UNREGLAND"'
check "the refused land did not advance the clone"       '[ "$(git -C "$DM_HOME/repos/gonerepo" rev-parse main)" = "$GONE_BEFORE" ]'
# Re-registering restores the very same land, proving the refusal was about the
# registry entry and nothing else.
jq --argjson e "$GONE_ENTRY" '.repos["gonerepo"] = $e' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
check "the same land succeeds once the repo is registered again" 'b dm-merge.sh local gone-1 >/dev/null 2>&1'
check "the restored land actually advanced the clone"            '[ "$(git -C "$DM_HOME/repos/gonerepo" rev-parse main)" != "$GONE_BEFORE" ]'
b dm-worktree.sh remove gone-1 >/dev/null 2>&1

echo "== distro guard: the distro's own lifecycle works, its mutation never does (#119) =="
# THE PRODUCTION SHAPE. The real state/repos.json has no `dockmaster` entry, yet
# many task records carry repo=dockmaster and live worktrees sit under
# state/worktrees/ — the distro ships changes to ITSELF through these scripts,
# unregistered. So the fixture is a distro-shaped DM_HOME (a git repo at the
# root) driven by the RESERVED, UNREGISTERED name, exactly as production does.
# Its origin is deliberately AHEAD, so a pre-fix sync genuinely fast-forwards it.
DISTRO_ORIGIN="$TMP/distro-origin.git"
DISTRO_HOME="$TMP/distro-home"
git init -q --bare -b main "$DISTRO_ORIGIN"
git init -q -b main "$DISTRO_HOME"
( cd "$DISTRO_HOME"; git config user.email d@d.co; git config user.name d
  printf 'contract\n' > AGENTS.md; git add -A; git commit -qm "distro init"
  git remote add origin "$DISTRO_ORIGIN"; git push -q origin main ) >/dev/null 2>&1
git clone -q "$DISTRO_ORIGIN" "$TMP/distro-upstream"
( cd "$TMP/distro-upstream"; git config user.email d@d.co; git config user.name d
  printf 'ahead\n' > upstream.txt; git add -A; git commit -qm "upstream advance"
  git push -q origin main ) >/dev/null 2>&1
d() { DM_HOME="$DISTRO_HOME" "$ROOT/bin/$@"; }
dlib() { ( export DM_HOME="$DISTRO_HOME"; . "$ROOT/bin/dm-lib.sh"; "$@" ); }
d dm-doctor.sh >/dev/null
DISTRO_HEAD="$(git -C "$DISTRO_HOME" rev-parse main)"
check "the distro fixture has no registry entry (as production has none)" \
  '[ "$(jq -r ".repos | keys | length" "$DISTRO_HOME/state/repos.json")" = 0 ]'
check "the distro fixture is genuinely behind its origin" \
  'git -C "$DISTRO_HOME" fetch -q origin main && [ "$(git -C "$DISTRO_HOME" rev-parse origin/main)" != "$DISTRO_HEAD" ]'

# A typo must still die at the resolver — the #119 fix, unchanged.
check "a typo'd name does not resolve to the distro root" '! dlib dm_repo_dir dockmastr >/dev/null 2>&1'
check "a typo'd name is not the reserved name"            '! dlib dm_repo_dir_or_none dockmastr >/dev/null 2>&1'
TYPOSYNC="$(d dm-sync.sh one dockmastr)"
check "sync of a typo'd name leaves the distro untouched" \
  '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ] && ! grep -q "fast-forwarded" <<<"$TYPOSYNC"'

# THE EXEMPTION, by reserved name: the distro resolves so its own PR-path
# lifecycle works. No environment variable, nothing a typo could reach.
check "the reserved distro name resolves to DM_HOME"  '[ "$(dlib dm_repo_dir dockmaster)" = "$DISTRO_HOME" ]'
check "the reserved name is refused as a new repo"    '! d dm-repo.sh add dockmaster "$DISTRO_ORIGIN" --no-memory >/dev/null 2>&1'
RESERVEOUT="$(d dm-repo.sh add dockmaster "$DISTRO_ORIGIN" --no-memory 2>&1 || true)"
check "the reserved-name refusal says why"            'grep -q "reserved for the dockmaster distro" <<<"$RESERVEOUT"'
d dm-task.sh new self-1 --kind ship --repo dockmaster --mode local-only >/dev/null
check "worktree create works for the distro's own task" 'd dm-worktree.sh create self-1 dockmaster feat/x/self-1 >/dev/null 2>&1'
SELFDIR="$DISTRO_HOME/state/worktrees/self-1"
check "the distro worktree is real and isolated" \
  '[ -d "$SELFDIR" ] && [ "$(git -C "$SELFDIR" rev-parse --show-toplevel)" = "$SELFDIR" ] && [ "$(git -C "$SELFDIR" rev-parse --abbrev-ref HEAD)" = "feat/x/self-1" ]'
check "assert accepts the distro worktree as isolated" 'd dm-worktree.sh assert "$SELFDIR" dockmaster >/dev/null 2>&1'
printf 'self work\n' > "$SELFDIR/self.txt"
git -C "$SELFDIR" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$SELFDIR" -c user.email=c@c.co -c user.name=c commit -qm "self work" >/dev/null
check "the distro worktree commits without touching the distro head" '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ]'
check "landed answers honestly for the distro (unlanded, not a resolver death)" \
  'OUT="$(d dm-worktree.sh landed self-1 2>&1 || true)"; grep -q "^unlanded" <<<"$OUT"'

# What the exemption does NOT buy: mutating the distro. Both refuse.
SELFSYNC="$(d dm-sync.sh one dockmaster)"
check "sync refuses the distro"                     'grep -q "refusing to sync the control plane" <<<"$SELFSYNC"'
check "the refused sync did not advance the distro" '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ]'
check "sync all skips the distro without dying"     'd dm-sync.sh all >/dev/null 2>&1'
check "the distro merge authority is never, not ask"    '[ "$(dlib dm_merge_authority dockmaster)" = "never" ]'
SELFLAND="$(d dm-merge.sh local self-1 2>&1 || true)"
check "local land refuses the distro"                   '! d dm-merge.sh local self-1 >/dev/null 2>&1'
check "the land refusal names the never posture"        'grep -q "merge_authority=never" <<<"$SELFLAND"'
check "the land refusal points at the operator merging" 'grep -qi "operator merges" <<<"$SELFLAND"'
check "the refused land did not advance the distro"     '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ]'

# Teardown completes the lifecycle: the distro worktree can be cleaned up.
check "teardown of an unlanded distro worktree still refuses" '! d dm-worktree.sh remove self-1 >/dev/null 2>&1'
check "forced teardown of a distro worktree succeeds"         'd dm-worktree.sh remove self-1 --force >/dev/null 2>&1'
check "the distro worktree is gone"                           '[ ! -d "$SELFDIR" ]'
check "the distro tree is unchanged by the whole sequence" \
  '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ] && [ -z "$(git -C "$DISTRO_HOME" status --porcelain -- AGENTS.md)" ] && [ ! -e "$DISTRO_HOME/upstream.txt" ] && [ ! -e "$DISTRO_HOME/self.txt" ]'

# The CLASS guard, separate from the reserved name: a hand-edited registry path
# that resolves to the distro root is caught by the assertion, not the resolver.
# (dm-repo.sh can never write such a path — it hardcodes "repos/<name>" — so this
# shape only ever arises from a hand edit, which is exactly what it guards.)
DREG="$DISTRO_HOME/state/repos.json"
jq '.repos["handedited"] = {remote:"none", path:".", default_branch:"main", mode:"local-only", merge_authority:"ask"}' \
  "$DREG" > "$DREG.tmp" && mv "$DREG.tmp" "$DREG"
check "a hand-edited distro-resolving path still resolves"   '[ "$(dlib dm_repo_dir handedited)" = "$DISTRO_HOME/." ]'
check "dm_is_distro_dir recognizes a non-canonical root"      'dlib dm_is_distro_dir "$DISTRO_HOME/."'
check "dm_is_distro_dir rejects a real managed clone"         '! ( . "$ROOT/bin/dm-lib.sh"; dm_is_distro_dir "$DM_HOME/repos/demo" )'
check "sync refuses the hand-edited distro path"              'grep -q "refusing to sync the control plane" <<<"$(d dm-sync.sh one handedited)"'
d dm-task.sh new hand-1 --kind ship --repo handedited --mode local-only >/dev/null
HANDOUT="$(d dm-worktree.sh create hand-1 handedited feat/x/hand-1 2>&1 || true)"
check "worktree create refuses a hand-edited distro path"     '! d dm-worktree.sh create hand-1 handedited feat/x/hand-1 >/dev/null 2>&1'
check "that refusal names the distro, not the reserved name"  'grep -q "dockmaster distro itself" <<<"$HANDOUT"'
check "no worktree was cut off the distro"                    '[ ! -e "$DISTRO_HOME/state/worktrees/hand-1" ]'
check "the distro head survived the class-guard sequence"     '[ "$(git -C "$DISTRO_HOME" rev-parse main)" = "$DISTRO_HEAD" ]'

# shard:split
echo "== teardown honesty: 'could not determine' is not 'unlanded' (#119) =="
# A failed landed-check used to read as "not landed", so teardown refused with a
# statement about the operator's WORK that was simply false. Distinguish them:
# landed exits 2 for undeterminable, and --force must still be able to clean up.
b dm-repo.sh add vanish "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new vanish-1 --kind ship --repo vanish --mode local-only >/dev/null
VWT="$(b dm-worktree.sh create vanish-1 vanish 2>/dev/null | tail -n1)"
git -C "$VWT" checkout -q -b feat/x/vanish-1
printf 'v\n' > "$VWT/v.txt"
git -C "$VWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$VWT" -c user.email=c@c.co -c user.name=c commit -qm "work" >/dev/null
check "landed reports unlanded (exit 1) while the repo resolves" \
  'b dm-worktree.sh landed vanish-1 >/dev/null 2>&1; [ "$?" = 1 ]'
jq 'del(.repos["vanish"])' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
VLANDED="$(b dm-worktree.sh landed vanish-1 2>&1 || true)"
check "landed exits 2 (undetermined) when the repo cannot resolve" \
  'b dm-worktree.sh landed vanish-1 >/dev/null 2>&1; [ "$?" = 2 ]'
check "landed says undetermined, never 'unlanded'" \
  'grep -q "^undetermined" <<<"$VLANDED" && ! grep -q "^unlanded" <<<"$VLANDED"'
# The third answer, machine-readable. The object carries `state` and NO derived
# boolean on purpose: a `landed:false` field would let "undetermined" be read as
# "not landed", which is the exact confusion exit 2 exists to prevent.
VLANDEDJ="$(b dm-worktree.sh landed vanish-1 --json)"
check "landed --json exits 0 when it cannot determine" 'b dm-worktree.sh landed vanish-1 --json >/dev/null'
check "landed --json state is undetermined"     '[ "$(jq -r ".state" <<<"$VLANDEDJ")" = "undetermined" ]'
check "landed --json exposes no landed boolean" '[ "$(jq -r "has(\"landed\")" <<<"$VLANDEDJ")" = "false" ]'
VREMOVE="$(b dm-worktree.sh remove vanish-1 2>&1 || true)"
check "teardown refuses without claiming the work is unlanded" \
  'grep -qi "cannot determine" <<<"$VREMOVE" && ! grep -q "has unlanded work" <<<"$VREMOVE"'
check "the refusal names the real reason"    'grep -q "vanish" <<<"$VREMOVE" && grep -qi "unregistered" <<<"$VREMOVE"'
VFORCE="$(b dm-worktree.sh remove vanish-1 --force 2>&1 || true)"
check "forced teardown still cleans up an unresolvable repo" '[ ! -d "$VWT" ]'
# Merged with #148's discard machinery: an orphan (no clone) cannot park its
# head, so the removal must SAY the commit could not be preserved, not imply it
# was kept. And it must still record a discarded event (else the task pins).
check "orphan force-removal warns the head could not be preserved" \
  'grep -qi "could not be preserved" <<<"$VFORCE"'
check "orphan force-removal records a discarded event" \
  'grep -qE "^[^ ]+ discarded: " "$DM_HOME/state/tasks/vanish-1.status"'

# The exit-2 contract binds EVERY consumer of `landed`, not just teardown. A
# consumer that folds 2 onto 1 states "unlanded work" about a task whose repo
# never resolved — the same false claim, one layer up.
b dm-repo.sh add vanish2 "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new vanish-2 --kind ship --repo vanish2 --mode local-only >/dev/null
V2WT="$(b dm-worktree.sh create vanish-2 vanish2 2>/dev/null | tail -n1)"
git -C "$V2WT" checkout -q -b feat/x/vanish-2
printf 'v\n' > "$V2WT/v.txt"
git -C "$V2WT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$V2WT" -c user.email=c@c.co -c user.name=c commit -qm "work" >/dev/null
b dm-backlog.sh add vanish-2 "vanish two" --repo vanish2 --status done >/dev/null
check "the backlog entry needed by the drift check exists" \
  '[ "$(jq -r ".items[] | select(.id==\"vanish-2\") | .status" "$DM_HOME/state/backlog.json")" = done ]'
V2_STATE_OK="$(b dm-task.sh state vanish-2 2>&1 || true)"
check "task state reports unlanded work while the repo resolves" \
  'grep -q "not yet landed" <<<"$V2_STATE_OK"'
jq 'del(.repos["vanish2"])' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
V2_STATE="$(b dm-task.sh state vanish-2 2>&1 || true)"
check "task state does not claim unlanded work it could not determine" \
  '! grep -q "committed work not yet landed" <<<"$V2_STATE"'
check "task state names the undetermined reason instead" \
  'grep -qi "could not determine" <<<"$V2_STATE"'
V2_STATUS="$(DM_NO_FETCH=1 b dm-status.sh 2>&1 || true)"
check "status drift does not claim unlanded work it could not determine" \
  '! grep -q "vanish-2 is done but its local copy holds unlanded work" <<<"$V2_STATUS"'
check "status drift names the undetermined reason instead" \
  'grep -q "vanish-2 is done but whether its local copy landed could not be determined" <<<"$V2_STATUS"'
jq --argjson e "$(printf '{"remote":"%s","path":"repos/vanish2","default_branch":"main","mode":"local-only","merge_authority":"ask"}' "$TMP/origin.git")" \
  '.repos["vanish2"] = $e' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
b dm-worktree.sh remove vanish-2 --force >/dev/null 2>&1

echo "== distro guard is not fail-open on empty input (#119) =="
# Both call sites currently pass a dying dm_repo_dir result, so an empty dir is
# unreachable today — but a guard whose empty-input default is "allow" points the
# wrong way, and empty is exactly what a swallowed resolver failure produces.
check "dm_assert_not_distro refuses an empty directory" \
  '! ( . "$ROOT/bin/dm-lib.sh"; dm_assert_not_distro "" "test action" ) >/dev/null 2>&1'
check "the empty-input refusal names it as a caller bug" \
  'OUT="$( ( . "$ROOT/bin/dm-lib.sh"; dm_assert_not_distro "" "test action" ) 2>&1 || true)"; grep -qi "empty directory" <<<"$OUT"'
check "dm_assert_not_distro still passes a real managed clone" \
  '( . "$ROOT/bin/dm-lib.sh"; dm_assert_not_distro "$DM_HOME/repos/demo" "test action" )'
check "dm_assert_not_distro still refuses the distro root" \
  '! ( export DM_HOME="$DISTRO_HOME"; . "$ROOT/bin/dm-lib.sh"; dm_assert_not_distro "$DISTRO_HOME" "test action" ) >/dev/null 2>&1'

echo "== resolver exit codes: a broken registry is never laundered into 'unknown repo' (#119) =="
# dm_repo_dir_or_none exit 2 = no such repo (benign); anything else = the lookup
# FAILED. Callers must not rewrite the latter into a reassuring skip — that is
# how registry corruption would read as a healthy fleet.
# Capture the resolver's rc through `|| rc=$?`, never `cmd; echo $?`: sourcing
# dm-lib.sh turns on `set -e` inside this subshell, so a bare nonzero return
# aborts it before `echo` runs — and WHETHER bash aborts there is version-
# dependent (green locally, red in CI). `|| rc=$?` makes the exit code the tested
# value on every bash.
rdc() { ( . "$ROOT/bin/dm-lib.sh"; rc=0; dm_repo_dir_or_none "$1" >/dev/null 2>&1 || rc=$?; echo "$rc" ); }
check "a resolvable repo exits 0"          '[ "$(rdc demo)" = 0 ]'
check "an unknown repo exits 2, not 1"     '[ "$(rdc nosuchrepo)" = 2 ]'
check "an empty name exits 2"              '[ "$(rdc "")" = 2 ]'
check "the reserved distro name exits 0"   '[ "$(rdc dockmaster)" = 0 ]'
# Guard the guard: the helper must actually SEE a nonzero code, not swallow it.
# A resolver stubbed to always return 2 must make rdc echo 2, proving the capture
# survives set -e rather than aborting to empty.
check "rdc reports a nonzero rc rather than aborting to empty (guard the guard)" \
  '[ "$( ( set -euo pipefail; f() { return 2; }; rc=0; f >/dev/null 2>&1 || rc=$?; echo "$rc" ) )" = 2 ]'
# A registry that cannot be read must surface as a failure, not as "unknown repo".
BROKEN_HOME="$TMP/broken-home"
mkdir -p "$BROKEN_HOME/state"
printf 'not json at all\n' > "$BROKEN_HOME/state/repos.json"
# Same robust capture: a broken registry must read as lookup-FAILED (nonzero and
# NOT 2), never accidental-empty. Before the `|| rc=$?` fix this passed for the
# wrong reason — set -e aborted to empty, and "" != 2 is trivially true.
check "an unreadable registry reads as lookup-failed, not 'no such repo'" \
  'BRC="$( ( export DM_HOME="$BROKEN_HOME"; . "$ROOT/bin/dm-lib.sh"; rc=0; dm_repo_dir_or_none demo >/dev/null 2>&1 || rc=$?; echo "$rc" ) )"; [ "$BRC" != 2 ] && [ "$BRC" != 0 ]'
check "dm_repo_dir names a broken registry, not a missing repo" \
  'OUT="$( ( export DM_HOME="$BROKEN_HOME"; . "$ROOT/bin/dm-lib.sh"; dm_repo_dir demo ) 2>&1 || true)"; grep -qi "registry" <<<"$OUT" && ! grep -q "is not registered" <<<"$OUT"'
# Composition, not luck: sync's SKIP branch must fire ONLY on exit 2. A dm_die
# raised inside the resolver (registry corruption, e.g. #112's integrity check)
# must propagate, never be rewritten into a reassuring "not a registered repo".
BROKENSYNC="$(DM_HOME="$BROKEN_HOME" "$ROOT/bin/dm-sync.sh" one demo 2>&1 || true)"
check "sync does not report a corrupt registry as an unknown repo" \
  '! grep -q "not a registered repo" <<<"$BROKENSYNC"'
check "sync fails loudly on a corrupt registry" \
  '! DM_HOME="$BROKEN_HOME" "$ROOT/bin/dm-sync.sh" one demo >/dev/null 2>&1'
# The resolver must DIE, not return a composed path, when its inner lookup fails
# (#112 interlock). set -e does NOT propagate out of a `[ ]` argument, a `case`
# word, or a nested substitution — verified below — so every resolver call site
# assigns to a variable first and checks it, rather than nesting the call.
# All four masking contexts, each verified real rather than assumed.
check "set -e does not propagate out of a [ ] argument" \
  '( set -e; f() { exit 1; }; if [ -d "$(f)/x" ]; then echo y; else echo n; fi ) 2>/dev/null | grep -q n'
check "set -e does not propagate out of a case word" \
  '( set -e; f() { exit 1; }; case "$(f)" in "") echo empty ;; *) echo other ;; esac ) 2>/dev/null | grep -q empty'
check "local masks a failing substitution (rc 0, empty value)" \
  '( set -e; f() { exit 1; }; g() { local x="$(f)"; printf "rc=%s val=[%s]" "$?" "$x"; }; g ) 2>/dev/null | grep -q "rc=0 val=\[\]"'
# The pattern MUST live in a single-quoted variable: written inline inside the
# double-quoted grep argument, `\$\(` collapses to `$(`, and ERE `$` is an
# end-of-line anchor — the check then matches nothing and can never fail.
# The `local` branch must not cross a `;` — otherwise `local dir; dir="$(...)"`,
# the SAFE split this fix introduces everywhere, matches its own lint.
NEST_PAT='\[[^]]*\$\(dm_repo_dir|\$\([^)]*\$\(dm_repo_dir|case[^)]*\$\(dm_repo_dir|local [^=;]*=[^=]*\$\(dm_repo_dir'
# One planted line per hazard the comment claims to cover, so the lint can never
# again cover fewer contexts than it advertises.
NEST_SHAPES="$(printf '%s\n' \
  '  [ -d "$(dm_repo_dir "$repo")/.github/workflows" ]' \
  '  primary="$(cd "$(dm_repo_dir "$repo")" && pwd -P)"' \
  '  case "$(dm_repo_dir "$repo")" in *) : ;; esac' \
  '  local dir="$(dm_repo_dir "$repo")"')"
check "the anti-nesting pattern matches all four masking contexts (guard the guard)" \
  '[ "$(grep -cE "$NEST_PAT" <<<"$NEST_SHAPES")" = 4 ]'
check "the anti-nesting pattern does not flag the safe split (guard the guard)" \
  '! grep -qE "$NEST_PAT" <<<'"'"'  local dir; dir="$(dm_repo_dir "$repo")" || dm_die x'"'"''
# Glob covers the extensionless dispatcher too — it is a bin/ script like any other.
check "no resolver call is nested in a [ ] argument, case word, substitution, or local" \
  '! grep -nE "$NEST_PAT" "$ROOT"/bin/dm-*.sh "$ROOT"/bin/dm'
check "a broken registry never yields a composed path" \
  '[ -z "$( ( export DM_HOME="$BROKEN_HOME"; . "$ROOT/bin/dm-lib.sh"; dm_repo_dir_or_none demo ) 2>/dev/null )" ]'
# A decoy git repo with a recognizable origin, used as the CWD by the two tests
# below. Pre-fix, a failed resolve left `git -C ""` reading whatever repo the
# CWD happened to be — so the wrong-repo access only becomes observable when the
# CWD IS a git repo with a distinguishable remote.
DECOY="$TMP/decoy-repo"
git init -q -b main "$DECOY"
git -C "$DECOY" remote add origin "https://github.com/decoy-owner/decoy-repo.git"

# task_has_ci must REFUSE rather than answer "no CI" — that answer is what
# --allow-no-checks consumes (dm_merge_gate none 1 0 -> allow), so a failed
# lookup could unlock the bypass. Drive `await-checks`: it reaches task_has_ci
# directly, with no repo_slug resolution before it, so this exercises the real
# code rather than dying at an earlier gate.
b dm-repo.sh add hasci "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new hasci-1 --kind ship --repo hasci >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set hasci-1 pr "https://github.com/o/r/pull/9" ) >/dev/null 2>&1
HASCI_OK="$(PATH="$GHSTUB:$PATH" b dm-pr.sh await-checks hasci-1 --timeout-secs 0 2>&1 || true)"
check "await-checks reaches CI detection while the clone resolves" \
  '! grep -qi "cannot determine CI" <<<"$HASCI_OK"'
rm -rf "$DM_HOME/repos/hasci"
# The resolver's own "no clone" message goes to stderr in BOTH versions, so
# matching it proves nothing. The discriminator is whether execution CONTINUED:
# pre-fix, has_ci silently became 0 and await-checks went on to poll (calling
# gh); post-fix it refuses before any poll.
: > "$GHSTUB/gh-calls"
HASCI_BAD="$(cd "$DECOY" && PATH="$GHSTUB:$PATH" DM_HOME="$DM_HOME" "$ROOT/bin/dm-pr.sh" await-checks hasci-1 --timeout-secs 2 --interval-secs 1 2>&1 || true)"
check "CI detection refuses rather than answering 'no CI'" \
  'grep -qi "cannot determine CI configuration" <<<"$HASCI_BAD"'
check "the refusal stops the poll instead of proceeding with has_ci=0" \
  '! grep -q "decoy" "$GHSTUB/gh-calls"'

# repo_slug: nested in `git -C`, a failed resolve left `git -C ""` reading the
# CWD repo — in production the distro — so `check` wrote real landing fields
# (pr_state, checks, pr_check_snapshot) sourced from the WRONG repository.
b dm-repo.sh add slugtest "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new slug-1 --kind ship --repo slugtest >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set slug-1 pr "https://github.com/o/r/pull/7" ) >/dev/null 2>&1
rm -rf "$DM_HOME/repos/slugtest"
# Run from the decoy repo: pre-fix, `git -C ""` read THAT repo and check queried
# it, so the wrong-repo access shows up in the stub's call log — the defect
# itself, not just its error text (the resolver's own message goes to stderr in
# BOTH versions, so matching on it proves nothing).
: > "$GHSTUB/gh-calls"
SLUGOUT="$(cd "$DECOY" && PATH="$GHSTUB:$PATH" DM_HOME="$DM_HOME" "$ROOT/bin/dm-pr.sh" check slug-1 2>&1 || true)"
check "check never queries the CWD repo when the slug cannot be derived" \
  '! grep -q "decoy" "$GHSTUB/gh-calls"'
check "check reports no PR verdict when the slug cannot be derived" \
  '! grep -q "^pr: " <<<"$SLUGOUT"'
check "the slug refusal names the repo and refuses the CWD fallback" \
  'grep -q "slugtest" <<<"$SLUGOUT" && grep -qi "current directory" <<<"$SLUGOUT"'
check "no landing field was written from the wrong repo" \
  '[ -z "$(b dm-task.sh get slug-1 pr_state)" ] && [ -z "$(b dm-task.sh get slug-1 pr_check_snapshot)" ] && [ -z "$(b dm-task.sh get slug-1 checks)" ]'

echo "== reserved distro name: a pre-existing registry entry is surfaced, not silently shadowed (#119) =="
# dm-repo.sh blocks NEW registrations, but dm_repo_dir_or_none short-circuits
# before the registry read — so an entry that predates the reserved name would
# resolve to $DM_HOME with authority `never`, silently. doctor must say so.
DOCHOME="$TMP/doctor-reserved"
mkdir -p "$DOCHOME"
DM_HOME="$DOCHOME" b dm-doctor.sh >/dev/null 2>&1
DOCREG="$DOCHOME/state/repos.json"
check "doctor is clean before the shadowed entry exists" 'DM_HOME="$DOCHOME" b dm-doctor.sh check >/dev/null 2>&1'
jq '.repos["dockmaster"] = {remote:"none", path:"repos/dockmaster", default_branch:"main", mode:"local-only", merge_authority:"ask"}' \
  "$DOCREG" > "$DOCREG.tmp" && mv "$DOCREG.tmp" "$DOCREG"
DOCOUT="$(DM_HOME="$DOCHOME" b dm-doctor.sh check 2>&1 || true)"
check "doctor fails on a registry entry under the reserved name" \
  '! DM_HOME="$DOCHOME" b dm-doctor.sh check >/dev/null 2>&1'
check "doctor names the shadowing and the remedy" \
  'grep -q "reserved distro name" <<<"$DOCOUT" && grep -qi "shadowed" <<<"$DOCOUT"'

echo "== single owner: no script re-composes \$DM_HOME/<registry path> (#119) =="
# The duplicated concatenation is what produced this issue; dm_repo_dir_or_none
# is the only place allowed to build it.
# Guard the FIELD ACCESS, not the composition shape. Matching `$DM_HOME/$(...)`
# only catches the inline form: main's dm-memory.sh built the same path with
# `printf '%s/%s\n' "$DM_HOME" "$p"`, and `${DM_HOME}/$(...)` and a two-step
# variable are equally invisible to a shape pattern. Every one of those must
# first READ the registry `path` field — so that read is the chokepoint, and
# dm_repo_dir_or_none is its only legitimate site.
COMPOSE_PAT='dm_registry_get[^)]*[" ]path\b'
check "only dm-lib.sh reads the registry path field" \
  '[ -z "$(grep -lE "$COMPOSE_PAT" "$ROOT"/bin/dm-*.sh "$ROOT"/bin/dm 2>/dev/null | grep -v "dm-lib\.sh$" || true)" ]'
check "dm-lib.sh reads it exactly once (inside dm_repo_dir_or_none)" \
  '[ "$(grep -cE "$COMPOSE_PAT" "$ROOT/bin/dm-lib.sh")" = 1 ]'
# The lint is a partial proxy — it cannot see a field passed as a variable. So the
# other half is closing routes at the source: `get <unknown> <field>` used to
# return empty-SUCCESS, the same "empty means here" shape as #119 itself
# (`p="$(dm-repo.sh get "$n" path)"; dir="$DM_HOME/$p"` -> $DM_HOME).
check "get <unregistered> <field> fails like its no-field sibling" \
  '! b dm-repo.sh get nosuchrepo path >/dev/null 2>&1'
check "the field refusal names the repo"  'OUT="$(b dm-repo.sh get nosuchrepo path 2>&1 || true)"; grep -q "no such repo: nosuchrepo" <<<"$OUT"'
check "it prints nothing on refusal"      '[ -z "$(b dm-repo.sh get nosuchrepo path 2>/dev/null || true)" ]'
check "a registered repo still returns its field" '[ "$(b dm-repo.sh get demo path)" = "repos/demo" ]'
# An ABSENT FIELD on a REGISTERED repo stays an empty success — a real answer
# about a known subject, not a missing subject. (Relied on by the yolo-alias tests.)
check "an absent field on a registered repo is still empty-success" \
  'b dm-repo.sh get demo no_such_field >/dev/null 2>&1 && [ -z "$(b dm-repo.sh get demo no_such_field)" ]'
COMPOSE_SHAPES="$(printf '%s\n' \
  'dir="$DM_HOME/$(dm_registry_get "$name" path)"' \
  'dir="${DM_HOME}/$(dm_registry_get "$repo" path)"' \
  '  local p; p="$(dm_registry_get "$1" path)"' \
  '  printf "%s/%s\n" "$DM_HOME" "$(dm_registry_get "$1" path)"')"
check "the field guard catches every historic composition shape (guard the guard)" \
  '[ "$(grep -cE "$COMPOSE_PAT" <<<"$COMPOSE_SHAPES")" = 4 ]'
check "the composition pattern would catch the original form (guard the guard)" \
  'grep -qE "$COMPOSE_PAT" <<<'"'"'dir="$DM_HOME/$(dm_registry_get "$name" path)"'"'"''
check "dm-memory still resolves a registered repo through the shared owner" \
  '[ -n "$(b dm-memory.sh recall demo 2>/dev/null || true)" ] || b dm-memory.sh recall demo >/dev/null 2>&1'

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
# Forced scout cleanup also needs a terminal record when no report exists.
b dm-task.sh new disc-sc --kind scout --repo demo >/dev/null
b dm-worktree.sh create disc-sc demo >/dev/null
b dm-worktree.sh remove disc-sc --force >/dev/null 2>&1
check "scout force-remove records terminal discarded" 'OUT="$(b dm-task.sh state disc-sc)"; grep -q "^state: discarded" <<<"$OUT"'

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

echo "== registry integrity: corruption never reads as an empty registry (#112, #114) =="
# Everything here runs against its OWN throwaway DM_HOME: these cases deliberately
# corrupt state/repos.json, which must never touch the suite's main home.
REGINT="$TMP/regint"
rg() { local s="$1"; shift; DM_HOME="$REGINT" "$ROOT/bin/$s" "$@"; }
# DM_HOME must itself be a git repo with commits, exactly as the real distro root
# is. That is load-bearing, not incidental: dm_repo_dir composes
# "$DM_HOME/<path>", so a swallowed lookup degrades to DM_HOME, and the `.git`
# probe meant to catch it PASSES there. A plain-directory fixture would hide the
# whole failure mode.
mkdir -p "$REGINT"
git init -q "$REGINT"
( cd "$REGINT"; printf 'distro\n' > README.md; git add README.md; git commit -qm "distro root" ) >/dev/null 2>&1
git init -q --bare -b main "$TMP/regint-origin.git"
git -C "$TMP/seed" push -q "$TMP/regint-origin.git" main
rg dm-repo.sh add gadget "$TMP/regint-origin.git" --mode local-only --no-memory >/dev/null 2>&1
rg dm-repo.sh set gadget merge_authority never >/dev/null
check "fixture: healthy registry resolves the repo and its authority" \
  '[ "$(rg dm-repo.sh get gadget mode)" = local-only ] && grep -q "never" <<<"$(rg dm-repo.sh list)"'
# Task records and a real worktree, created while the registry is still healthy,
# so the consumers below reach their registry read instead of dying earlier on a
# missing task/worktree (which would make the enumeration prove nothing).
rg dm-task.sh new regint-task --kind ship --repo gadget >/dev/null
rg dm-task.sh new regint-wt --kind ship --repo gadget >/dev/null
DM_HOME="$REGINT" DM_NO_FETCH=1 "$ROOT/bin/dm-worktree.sh" create regint-task gadget >/dev/null 2>&1
# Resolve both sides physically (cd into the worktree first so a RELATIVE
# --git-common-dir resolves, then pwd -P) so a macOS /var->/private/var symlink
# or a git that prints a relative common-dir cannot make this pass or fail
# spuriously (#148 canonicalizes DM_HOME).
REGINT_WT_COMMON="$(cd "$REGINT/state/worktrees/regint-task" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
REGINT_CLONE_GIT="$(cd "$REGINT/repos/gadget/.git" && pwd -P)"
check "fixture: the worktree is attached to the managed clone, not the home root" \
  '[ "$REGINT_WT_COMMON" = "$REGINT_CLONE_GIT" ]'

# Missing and empty are legitimate FIRST-RUN states, not corruption.
check "a missing registry is a first-run state" \
  'DM_HOME="$TMP/regint-missing" "$ROOT/bin/dm-repo.sh" list >/dev/null 2>&1'
mkdir -p "$TMP/regint-empty/state"; : > "$TMP/regint-empty/state/repos.json"
check "a zero-length registry is a first-run state and is re-seeded" \
  'DM_HOME="$TMP/regint-empty" "$ROOT/bin/dm-repo.sh" list >/dev/null 2>&1 &&
   [ "$(jq -c . "$TMP/regint-empty/state/repos.json")" = "{\"repos\":{}}" ]'
# An object with no `.repos` is NOT an empty registry: dm_ensure_dirs always
# seeds `{"repos":{}}`, so a document missing the key is hand-damaged, and
# `{"other":1}` must not read as a healthy empty fleet.
mkdir -p "$TMP/regint-norepos/state"; printf '{}\n' > "$TMP/regint-norepos/state/repos.json"
check "an object with no .repos key is corruption, not an empty fleet" \
  '! DM_HOME="$TMP/regint-norepos" "$ROOT/bin/dm-repo.sh" list >/dev/null 2>&1'

printf '{"repos": {broken\n' > "$REGINT/state/repos.json"

# ENUMERATED consumers. A corrupt registry must stop EVERY one of them: the bug
# was a whole class (`jq -e ... && dm_die` short-circuits on a parse error), so
# spot-checking two would let an unfixed consumer keep the class alive.
REGINT_FAILED=""
while IFS= read -r consumer; do
  [ -n "$consumer" ] || continue
  # shellcheck disable=SC2086
  if DM_HOME="$REGINT" "$ROOT/bin/"$consumer >/dev/null 2>"$TMP/regint-err"; then
    REGINT_FAILED="$REGINT_FAILED [exited 0: $consumer]"
  elif [ ! -s "$TMP/regint-err" ]; then
    REGINT_FAILED="$REGINT_FAILED [silent: $consumer]"
  elif ! grep -q 'does not parse' "$TMP/regint-err"; then
    REGINT_FAILED="$REGINT_FAILED [unnamed: $consumer]"
  fi
done <<EOF
dm-repo.sh add gadget $TMP/regint-origin.git
dm-repo.sh create fresh $TMP/regint-origin.git
dm-repo.sh list
dm-repo.sh get gadget
dm-repo.sh get gadget mode
dm-repo.sh set gadget mode local-only
dm-repo.sh remove gadget
dm-repo.sh seed gadget
dm-status.sh
dm-sync.sh all
dm-sync.sh one gadget
dm-memory.sh recall gadget
dm-memory.sh seed gadget
dm-task.sh new regint-1 --kind ship --repo gadget
dm-worktree.sh create regint-wt gadget
dm-worktree.sh tangle gadget
dm-merge.sh rebase regint-task
dm-merge.sh local regint-task
dm-pr.sh check regint-task
dm-test.sh regint-task
EOF
check "every registry consumer refuses a corrupt registry, by name$REGINT_FAILED" '[ -z "$REGINT_FAILED" ]'

# The dm-lib accessors are the choke point every other script inherits. Two
# fail-closed contracts: the REGISTRY accessors DIE on a corrupt read (they own
# dm_registry_require_valid); the MERGE accessors fail closed to a SAFE value
# per #119 — dm_merge_authority to `invalid` (the gate refuses) and
# dm_merge_allowed_bases to empty (grants no exception) — so an unregistered
# repo and a corrupt registry both fail the merge gate closed, and #119 stays
# the single owner of that mapping (a die there would break its unknown-repo case).
REGINT_LIB_FAILED=""
for fn in "dm_registry_get gadget" "dm_registry_get gadget mode" "dm_registry_has gadget" \
          "dm_registry_keys"; do
  if DM_HOME="$REGINT" bash -c ". \"$ROOT/bin/dm-lib.sh\"; $fn" >/dev/null 2>&1; then
    REGINT_LIB_FAILED="$REGINT_LIB_FAILED [$fn]"
  fi
done
check "every registry accessor DIES on a corrupt registry$REGINT_LIB_FAILED" '[ -z "$REGINT_LIB_FAILED" ]'

# The merge accessors must fail closed to a safe value, never a permissive one.
# Safe rc capture (rc=0; cmd || rc=$?): a nonzero return under dm-lib's set -e
# would abort a `cmd; echo $?` subshell before the read.
REGINT_MAUTH="$(DM_HOME="$REGINT" bash -c ". \"$ROOT/bin/dm-lib.sh\"; dm_merge_authority gadget" 2>/dev/null || true)"
REGINT_MBASES="$(DM_HOME="$REGINT" bash -c ". \"$ROOT/bin/dm-lib.sh\"; dm_merge_allowed_bases gadget" 2>/dev/null || true)"
check "corrupt registry: merge authority fails closed to invalid, not ask/yolo" \
  '[ "$REGINT_MAUTH" = invalid ]'
check "corrupt registry: merge allowed-bases fails closed to empty (no exception)" \
  '[ -z "$REGINT_MBASES" ]'
# Validation is memoized per process, so it can only vouch for the file as of
# that check. dm_merge_authority maps a corrupt read to `invalid` (#119)
# regardless of the memo, so an external write AFTER a warm memo still fails
# closed for a `never` repo rather than the permissive legacy default.
REGINT_WARM="$TMP/regint-warm"; mkdir -p "$REGINT_WARM/state"
printf '{"repos":{"gadget":{"merge_authority":"never","path":"repos/gadget"}}}\n' > "$REGINT_WARM/state/repos.json"
REGINT_WARM_OUT="$(DM_HOME="$REGINT_WARM" bash -c ". \"$ROOT/bin/dm-lib.sh\"
  dm_registry_require_valid
  printf '{\"repos\": {broken\n' > \"\$DM_REGISTRY\"
  dm_merge_authority gadget" 2>/dev/null || true)"
check "a warm validation memo does not let a later corruption fail open to ask" \
  '! grep -qE "^(ask|yolo)$" <<<"$REGINT_WARM_OUT"'

REGINT_STATUS_OUT="$TMP/regint-status-out"; REGINT_STATUS_ERR="$TMP/regint-status-err"
DM_HOME="$REGINT" "$ROOT/bin/dm-status.sh" >"$REGINT_STATUS_OUT" 2>"$REGINT_STATUS_ERR" && REGINT_STATUS_RC=0 || REGINT_STATUS_RC=$?
check "dm-status on a corrupt registry exits non-zero with stderr, not an empty table (#114)" \
  '[ "$REGINT_STATUS_RC" -ne 0 ] && [ -s "$REGINT_STATUS_ERR" ] && ! grep -q "MANAGED REPOS" "$REGINT_STATUS_OUT"'

# The highest-consequence swallow: dm_repo_dir builds its path in a NESTED
# command substitution, where bash does not propagate set -e. The refusal was
# printed but discarded and the path fell back to DM_HOME — itself a git repo —
# so a worker's copy attached to the distro root and `rebase` rebased against
# the distro's own history. Assert on the filesystem, not just the exit code.
# DM_NO_FETCH=1 is the load-bearing part: on the default path the pre-create
# FF-sync shell-out happens to fail first and masks this, but offline mode (and
# the --base stacked-child path) skips it and reaches the resolver directly.
DM_HOME="$REGINT" DM_NO_FETCH=1 "$ROOT/bin/dm-worktree.sh" create regint-wt gadget >/dev/null 2>&1 || true
DM_HOME="$REGINT" DM_NO_FETCH=1 "$ROOT/bin/dm-worktree.sh" create regint-wt2 gadget --base main >/dev/null 2>&1 || true
REGINT_HOMEROOT_WT="$(git -C "$REGINT" worktree list 2>/dev/null | tail -n +2 || true)"
check "a corrupt registry never attaches a worker copy to the home root" \
  '[ -z "$REGINT_HOMEROOT_WT" ] && [ ! -e "$REGINT/state/worktrees/regint-wt" ]'
check "a corrupt registry never leaves the pre-existing worktree half-rebased" \
  '[ ! -d "$REGINT/state/worktrees/regint-task/.git/rebase-merge" ] &&
   [ ! -d "$REGINT/state/worktrees/regint-task/.git/rebase-apply" ]'
REGINT_CONCAT="$TMP/regint-concat"; mkdir -p "$REGINT_CONCAT/state"
printf '{"other":1}\n{"repos":{}}\n' > "$REGINT_CONCAT/state/repos.json"
check "concatenated JSON documents are corruption, not a healthy tail" \
  '! DM_HOME="$REGINT_CONCAT" "$ROOT/bin/dm-repo.sh" list >/dev/null 2>&1'

REGINT_ERR="$(DM_HOME="$REGINT" "$ROOT/bin/dm-repo.sh" add gadget "$TMP/regint-origin.git" 2>&1 || true)"
check "the corrupt-registry refusal is actionable and names no destructive command" \
  '! grep -qE "rm -rf|rm -r " <<<"$REGINT_ERR" && grep -q "CORRUPTION" <<<"$REGINT_ERR" &&
   grep -q "repos.json" <<<"$REGINT_ERR" && grep -q "dm-doctor.sh check" <<<"$REGINT_ERR"'
# A free repo name would otherwise clone to completion (network + disk) and only
# then fail at registration, leaving a genuine orphan that blocks the retry.
DM_HOME="$REGINT" "$ROOT/bin/dm-repo.sh" add newthing "$TMP/regint-origin.git" --no-memory >/dev/null 2>&1 || true
check "a corrupt registry stops add BEFORE it spends a clone (no orphan left)" \
  '[ ! -e "$REGINT/repos/newthing" ]'
check "doctor still DIAGNOSES a corrupt registry instead of refusing to run" \
  '! DM_HOME="$REGINT" "$ROOT/bin/dm-doctor.sh" check >"$TMP/regint-doc" 2>&1;
   grep -q "state/repos.json is not valid JSON" "$TMP/regint-doc"'

# Shapes that parse as JSON but are not a registry are corruption too.
REGINT_SHAPE=""
for shape in '{"repos": []}' '[1,2,3]' '"nope"'; do
  mkdir -p "$TMP/regint-shape/state"; printf '%s\n' "$shape" > "$TMP/regint-shape/state/repos.json"
  DM_HOME="$TMP/regint-shape" "$ROOT/bin/dm-repo.sh" list >/dev/null 2>&1 &&
    REGINT_SHAPE="$REGINT_SHAPE [$shape]" || true
done
check "a well-formed JSON document of the wrong shape is corruption$REGINT_SHAPE" '[ -z "$REGINT_SHAPE" ]'

echo "== registry integrity: add never advises destroying what it has not vetted (#112) =="
# The `add` slot guard used to print a blanket `rm -rf '<dir>'` for ANY existing
# path. With a corrupt registry that path was a LIVE managed clone.
REGADV="$TMP/regadv"; mkdir -p "$REGADV/state" "$REGADV/repos"
printf '{"repos":{}}\n' > "$REGADV/state/repos.json"
mkdir -p "$REGADV/repos/emptydir"
git init -q "$REGADV/repos/liveclone"
( cd "$REGADV/repos/liveclone"; printf 'unlanded\n' > work.txt; git add .; git commit -qm work ) >/dev/null 2>&1
mkdir -p "$REGADV/repos/notempty"; printf 'data\n' > "$REGADV/repos/notempty/file.txt"
adv() { DM_HOME="$REGADV" "$ROOT/bin/dm-repo.sh" add "$1" "$TMP/regint-origin.git" 2>&1 || true; }
ADV_EMPTY="$(adv emptydir)"; ADV_CLONE="$(adv liveclone)"; ADV_JUNK="$(adv notempty)"
check "a git repo in the slot is never proposed for deletion" \
  '! grep -qE "rm -rf|rm -r |rmdir" <<<"$ADV_CLONE" && grep -q "GIT REPOSITORY" <<<"$ADV_CLONE" &&
   grep -q "mv " <<<"$ADV_CLONE" && grep -q "git -C" <<<"$ADV_CLONE"'
check "an unvetted non-empty directory is never proposed for deletion" \
  '! grep -qE "rm -rf|rm -r |rmdir" <<<"$ADV_JUNK" && grep -q "mv " <<<"$ADV_JUNK"'
check "only a provably empty directory earns a removal suggestion, and it is rmdir" \
  'grep -q "rmdir " <<<"$ADV_EMPTY" && ! grep -q "rm -rf" <<<"$ADV_EMPTY"'
check "the live clone and its unlanded work are still on disk after every refusal" \
  '[ -f "$REGADV/repos/liveclone/work.txt" ] && [ -f "$REGADV/repos/notempty/file.txt" ]'

echo "== registry integrity: drift guards (a new consumer cannot reopen the class) =="
# dm-lib owns the registry read path; dm-doctor deliberately reads it raw because
# it is the diagnostic that REPORTS corruption and must not refuse to run.
REGINT_RAW="$(grep -n 'jq .*DM_REGISTRY' "$ROOT"/bin/*.sh |
  grep -v '/bin/dm-lib\.sh:' | grep -v '/bin/dm-doctor\.sh:' || true)"
check "no consumer swallows a registry read failure into a silent answer" \
  '! grep -qE "2>/dev/null \|\| true|&& dm_die|\|\| true\)" <<<"$REGINT_RAW"'
# DERIVED, not hardcoded: the set is "every script that touches a registry
# accessor", computed from the tree, so a NEW consumer added tomorrow is covered
# without editing this test. dm-lib defines the accessors; dm-doctor reads the
# registry raw on purpose (it diagnoses corruption and must still run).
# Capture, then match: `check` evals its argument in THIS shell, so a bare
# `exit 1` would kill the suite instead of failing one case; and piping a
# producer into `grep -q` SIGPIPEs it, which pipefail reports as failure.
REGINT_UNVALIDATED=""
REGINT_ACCESSORS='dm_registry_get|dm_registry_has|dm_registry_keys|dm_merge_authority|dm_merge_allowed_bases|dm_repo_dir'
for f in "$ROOT"/bin/dm-*.sh; do
  s="$(basename "$f")"
  case "$s" in dm-lib.sh|dm-doctor.sh) continue ;; esac
  grep -qE "$REGINT_ACCESSORS" "$f" || continue
  grep -q '^dm_registry_require_valid' "$f" || REGINT_UNVALIDATED="$REGINT_UNVALIDATED [$s]"
done
check "every registry-enumerating entry point validates in its own main shell$REGINT_UNVALIDATED" \
  '[ -z "$REGINT_UNVALIDATED" ]'
REGINT_RAWKEYS="$(grep -n 'repos | keys' "$ROOT"/bin/*.sh | grep -v '/bin/dm-lib\.sh:' || true)"
check "the registry is never enumerated by a raw jq keys call outside dm-lib" \
  '[ -z "$REGINT_RAWKEYS" ]'

echo "== skill trigger + performance guards =="
check "skill trigger suite passes" 'node "$ROOT/tests/check-skill-triggers.js" >/dev/null'
EVIDENCE_PARENT="$TMP/evidence-parent"
mkdir -m 700 "$EVIDENCE_PARENT"
printf 'untouched\n' > "$TMP/evidence-victim"
ln -s "$TMP/evidence-victim" "$EVIDENCE_PARENT/runtime-version.txt"
EVIDENCE_ONE="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_PARENT")"
EVIDENCE_TWO="$("$ROOT/tests/runtime-evidence-dir.sh" create "$EVIDENCE_PARENT")"
check "runtime evidence uses unique private children" '[ "$EVIDENCE_ONE" != "$EVIDENCE_TWO" ] && [ ! -L "$EVIDENCE_ONE" ] && [ "$(file_mode "$EVIDENCE_ONE")" = 700 ]'
SAFE_EVIDENCE="$("$ROOT/tests/runtime-evidence-dir.sh" reserve "$EVIDENCE_ONE" runtime-version.txt)"
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
CHECK_FIXTURE="$TMP/runtime-check"
mkdir -p "$CHECK_FIXTURE"
copy_check_input() {
  local relative="$1"
  mkdir -p "$CHECK_FIXTURE/$(dirname "$relative")"
  cp "$ROOT/$relative" "$CHECK_FIXTURE/$relative"
}
for relative in AGENTS.md CLAUDE.md config/runtime-performance-baseline.json \
  .claude/settings.json; do
  copy_check_input "$relative"
done
while IFS= read -r skill; do
  copy_check_input ".claude/skills/$(basename "$skill")/SKILL.md"
done < <(find "$ROOT/.claude/skills" -mindepth 1 -maxdepth 1 -type d)
check "runtime fixture excludes repository and private state" \
  '[ ! -e "$CHECK_FIXTURE/.git" ] && [ ! -e "$CHECK_FIXTURE/state" ] && [ ! -e "$CHECK_FIXTURE/repos" ] && [ ! -e "$CHECK_FIXTURE/data" ] && [ ! -e "$CHECK_FIXTURE/.env" ]'
FLEET_SKILL="$CHECK_FIXTURE/.claude/skills/fleet-change/SKILL.md"
sed 's/--status queued/--status inflight/' "$FLEET_SKILL" > "$FLEET_SKILL.tmp"
mv "$FLEET_SKILL.tmp" "$FLEET_SKILL"
check "trigger check fails when a fleet child claims ownership before spawn" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/check-skill-triggers.js" >/dev/null 2>&1'
cp "$ROOT/.claude/skills/fleet-change/SKILL.md" "$FLEET_SKILL"
mkdir -p "$CHECK_FIXTURE/.claude/skills/added-runtime"
printf '%s\n' '---' 'name: added-runtime' 'description: mutation fixture' '---' > "$CHECK_FIXTURE/.claude/skills/added-runtime/SKILL.md"
check "trigger check fails on a skill with no AGENTS.md trigger" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/check-skill-triggers.js" >/dev/null 2>&1'
check "runtime performance guard fails on added Claude skill" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
rm -rf "$CHECK_FIXTURE/.claude/skills/added-runtime"
mkdir -p "$CHECK_FIXTURE/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$CHECK_FIXTURE/.claude/hooks/added.sh"
check "runtime performance guard rejects unclassified Claude files" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
rm -rf "$CHECK_FIXTURE/.claude/hooks"
CLAUDE_TASK="$CHECK_FIXTURE/.claude/skills/task-lifecycle/SKILL.md"
sed 's/run in background/run on background/' "$CLAUDE_TASK" > "$CLAUDE_TASK.tmp"
check "same-size Claude mutation preserves byte count" \
  '[ "$(wc -c < "$CLAUDE_TASK")" -eq "$(wc -c < "$CLAUDE_TASK.tmp")" ]'
mv "$CLAUDE_TASK.tmp" "$CLAUDE_TASK"
check "runtime performance guard fails on same-size Claude mutation" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
cp "$ROOT/.claude/skills/task-lifecycle/SKILL.md" "$CLAUDE_TASK"
printf '%03000d\n' 0 >> "$CHECK_FIXTURE/AGENTS.md"
check "runtime performance guard fails on instruction bloat" \
  '! DM_CHECK_ROOT="$CHECK_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'

echo "== dm-state (export/import: state portability, #106) =="
SP="$TMP/state-portability"
RESTORE="$TMP/restore-home"
mkdir -p "$SP"
# Content fingerprint of everything dm-state may read, to prove export is read-only.
state_fingerprint() {
  { find "$DM_HOME/state" -type f | grep -v "/state/worktrees/" || true
    find "$DM_HOME/repos" -type f -path "*/.dm/*" || true
  } | LC_ALL=C sort | while IFS= read -r f; do cksum < "$f"; done | cksum
}
# A top-level entry the record set does not know about: reported, never carried.
mkdir -p "$DM_HOME/state/unknown-extra"; printf 'junk\n' > "$DM_HOME/state/unknown-extra/x.txt"
# The same, one level INTO the dirs that hold records: a future record type must
# surface as unrecognized rather than vanish from every backup.
printf 'r\n' > "$DM_HOME/state/tasks/t1.report"
mkdir -p "$DM_HOME/state/tasks/subdir"; printf 'y\n' > "$DM_HOME/state/tasks/subdir/y.md"
printf 'z\n' > "$DM_HOME/state/archive/stray.json"
printf 'k\n' > "$DM_HOME/repos/demo/.dm/keys.txt"
# A third memory store must be carried by the .dm/*.md glob, not silently dropped.
printf '# extra\n' > "$DM_HOME/repos/demo/.dm/extra.md"
# Symlinks under data/ are real: npm/playwright leave node_modules/.bin/ entries
# behind. verify refuses a non-regular member, so an export that copied them
# produced an archive its own verify rejected - success at backup time, hard
# refusal at restore time. Cycle + broken + out-of-tree cover the copy hazards.
mkdir -p "$DM_HOME/data/sp-artifacts/node_modules/.bin"
printf 'real artifact\n' > "$DM_HOME/data/sp-artifacts/node_modules/pw.js"
ln -s ../pw.js "$DM_HOME/data/sp-artifacts/node_modules/.bin/playwright"
ln -s /etc/passwd "$DM_HOME/data/sp-artifacts/outside-link"
ln -s /nonexistent-sp-target "$DM_HOME/data/sp-artifacts/broken-link"
ln -s ../node_modules "$DM_HOME/data/sp-artifacts/node_modules/.bin/cycle-link"
# The dockmaster-only store exists precisely so it is never relayed; an export
# still has to carry it, so make sure the fixture has one.
b dm-memory.sh remember demo --dockmaster-only --kind routing "dm-state round-trip probe" >/dev/null
SP_BEFORE="$(state_fingerprint)"
SP_EXPORT="$(b dm-state.sh export --out "$SP/full.tar.gz" --with-artifacts)"
SP_AFTER="$(state_fingerprint)"
check "export writes an archive"                   '[ -f "$SP/full.tar.gz" ]'
check "export does not mutate the state root"      '[ "$SP_BEFORE" = "$SP_AFTER" ]'
check "archive is written private (mode 600)"      '[ "$(file_mode "$SP/full.tar.gz")" = 600 ]'
check "export names the unrecognized entry"        'grep -q "unrecognized, NOT carried: state/unknown-extra" <<<"$SP_EXPORT"'
check "export names uncarried local copies"        'grep -q "local copy/copies under state/worktrees/" <<<"$SP_EXPORT"'
check "export warns the archive holds secrets"     'grep -q "treat it as a secret" <<<"$SP_EXPORT"'
check "verify accepts a good archive"              'b dm-state.sh verify "$SP/full.tar.gz" >/dev/null'
# The invariant that makes the above non-negotiable: export self-verifies, so it
# can never report success for an archive verify would reject.
SP_NONREG="$(tar -xzOf "$SP/full.tar.gz" ./manifest.json | jq -r '.omitted_non_regular[]')"
check "export skips a symlink under data/"         'grep -qx "data/sp-artifacts/node_modules/.bin/playwright" <<<"$SP_NONREG"'
check "export names every non-regular member"      'grep -qx "data/sp-artifacts/outside-link" <<<"$SP_NONREG" && grep -qx "data/sp-artifacts/broken-link" <<<"$SP_NONREG" && grep -qx "data/sp-artifacts/node_modules/.bin/cycle-link" <<<"$SP_NONREG"'
check "export reports the skipped symlink"         'grep -q "symlink/non-regular, NOT carried: data/sp-artifacts" <<<"$SP_EXPORT"'
# Dereferencing instead of skipping would suck /etc/passwd into the backup.
check "an out-of-tree symlink is not followed"     '! tar -xzOf "$SP/full.tar.gz" 2>/dev/null | grep -q "root:x:0:0"'

# What the archive deliberately omits.
SP_PATHS="$(tar -xzOf "$SP/full.tar.gz" ./manifest.json | jq -r '.files[].path')"
check "archive omits live worktrees"               '! grep -q "^state/worktrees/" <<<"$SP_PATHS"'
check "archive omits managed clone content"        '[ -z "$(grep "^repos/" <<<"$SP_PATHS" | grep -v "/\.dm/" || true)" ]'
check "archive omits the unrecognized entry"       '! grep -q "unknown-extra" <<<"$SP_PATHS"'
check "archive carries the registry"               'grep -qx "state/repos.json" <<<"$SP_PATHS"'
check "archive carries archived task records"      'grep -qx "state/archive/demo-1.meta" <<<"$SP_PATHS"'
check "archive carries dockmaster-only memory"     'grep -q "repos/demo/.dm/private.md" <<<"$SP_PATHS"'
check "manifest records the omission"              'tar -xzOf "$SP/full.tar.gz" ./manifest.json | jq -e ".omitted_unrecognized | index(\"state/unknown-extra\")" >/dev/null'
SP_OMIT="$(tar -xzOf "$SP/full.tar.gz" ./manifest.json | jq -r '.omitted_unrecognized[]')"
check "unrecognized scan reaches state/tasks/"     'grep -qx "state/tasks/t1.report" <<<"$SP_OMIT" && grep -qx "state/tasks/subdir" <<<"$SP_OMIT"'
check "unrecognized scan reaches state/archive/"   'grep -qx "state/archive/stray.json" <<<"$SP_OMIT"'
check "unrecognized scan reaches .dm/ sidecars"    'grep -qx "repos/demo/.dm/keys.txt" <<<"$SP_OMIT"'
check "nested unrecognized files are not carried"  '! grep -qE "t1.report|subdir/|stray.json|keys.txt" <<<"$SP_PATHS"'
check "archived task dirs are not 'unrecognized'"  '! grep -q "^state/archive/demo-1$" <<<"$SP_OMIT"'
check "sidecar glob carries a third memory store"  'grep -qx "repos/demo/.dm/extra.md" <<<"$SP_PATHS"'
check "no symlink reaches the payload"             '! grep -q "sp-artifacts/.*\.bin/" <<<"$SP_PATHS"'
check "the file behind the symlink still travels"  'grep -qx "data/sp-artifacts/node_modules/pw.js" <<<"$SP_PATHS"'

# Round trip into a clean state root, compared field by field (not by file hash).
SP_IMPORT="$(DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz")"
check "import into a clean root succeeds"          '[ -f "$RESTORE/state/repos.json" ]'
check "registry remote round-trips"                '[ "$(DM_HOME="$RESTORE" "$ROOT/bin/dm-repo.sh" get demo remote)" = "$(b dm-repo.sh get demo remote)" ]'
check "registry mode round-trips"                  '[ "$(DM_HOME="$RESTORE" "$ROOT/bin/dm-repo.sh" get demo mode)" = "$(b dm-repo.sh get demo mode)" ]'
check "registry test_cmd round-trips"              '[ "$(DM_HOME="$RESTORE" "$ROOT/bin/dm-repo.sh" get demo test_cmd)" = "$(b dm-repo.sh get demo test_cmd)" ]'
check "task kind round-trips"                      '[ "$(DM_HOME="$RESTORE" "$ROOT/bin/dm-task.sh" get arch-wip kind)" = "$(b dm-task.sh get arch-wip kind)" ]'
check "task repo round-trips"                      '[ "$(DM_HOME="$RESTORE" "$ROOT/bin/dm-task.sh" get arch-wip repo)" = "$(b dm-task.sh get arch-wip repo)" ]'
check "task status log round-trips"                '[ "$(wc -l < "$RESTORE/state/tasks/arch-wip.status")" = "$(wc -l < "$DM_HOME/state/tasks/arch-wip.status")" ]'
# Split three ways so a failure says WHICH stage broke: carried, installed, equal.
# The jq filter is SINGLE-quoted and evaluated outside `check`: a nested double
# quote inside "$( )" inside an eval'd string is exactly where bash 3.2 parsing
# differs, and an unquoted {a,b,c} would then brace-expand into bogus arguments.
SP_BL_SRC="$(jq -Sc '.items|map({id,title,status,repo})' "$DM_HOME/state/backlog.json" 2>/dev/null || true)"
SP_BL_DST="$(jq -Sc '.items|map({id,title,status,repo})' "$RESTORE/state/backlog.json" 2>/dev/null || true)"
check "archive carries the backlog"                'grep -qx "state/backlog.json" <<<"$SP_PATHS"'
check "backlog is installed on import"             '[ -s "$RESTORE/state/backlog.json" ]'
check "backlog items round-trip"                   '[ "$SP_BL_SRC" = "$SP_BL_DST" ]'
if [ "$SP_BL_SRC" != "$SP_BL_DST" ]; then
  echo "    backlog diag: src bytes=$(wc -c < "$DM_HOME/state/backlog.json" 2>&1 | tr -d ' ') dst bytes=$(wc -c < "$RESTORE/state/backlog.json" 2>&1 | tr -d ' ')"
  echo "    backlog diag: manifest state/ entries: $(grep "^state/" <<<"$SP_PATHS" | tr '\n' ' ')"
  echo "    backlog diag: src=$SP_BL_SRC"
  echo "    backlog diag: dst=$SP_BL_DST"
fi
check "private memory round-trips"                 'diff -q "$RESTORE/repos/demo/.dm/notes.md" "$DM_HOME/repos/demo/.dm/notes.md" >/dev/null'
check "dockmaster-only memory round-trips"         'grep -q "dm-state round-trip probe" "$RESTORE/repos/demo/.dm/private.md"'
check "fleet memory round-trips"                   'diff -q "$RESTORE/state/learnings.md" "$DM_HOME/state/learnings.md" >/dev/null'
check "import reports the clone to re-establish"   'grep -q "clone missing for .demo." <<<"$SP_IMPORT"'
check "import names the unrecognized omission"     'grep -q "unrecognized at export.: state/unknown-extra" <<<"$SP_IMPORT"'

# A populated root is never silently overwritten.
printf 'local edit\n' >> "$RESTORE/state/learnings.md"
printf 'keepme\n' > "$RESTORE/state/tasks/not-in-archive.meta"
SP_REFUSE="$(DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" 2>&1 || true)"
check "import refuses a populated root"            '! DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" >/dev/null 2>&1'
SP_NFILES="$(tar -xzOf "$SP/full.tar.gz" ./manifest.json | jq -r '.files | length')"
check "refusal counts every file it would replace" 'grep -q "refusing to overwrite $SP_NFILES existing file(s)" <<<"$SP_REFUSE"'
check "refusal lists the conflicting paths"        '[ "$(grep -cE "^  (state|repos|data)/" <<<"$SP_REFUSE")" -ge 1 ]'
check "refusal leaves the local edit intact"       'grep -q "local edit" "$RESTORE/state/learnings.md"'
# --dry-run reports the same plan and writes nothing.
SP_DRY="$(DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" --dry-run 2>&1)"
check "dry run reports what it would replace"      'grep -q "would replace $SP_NFILES existing file(s)" <<<"$SP_DRY"'
check "dry run flags the newer local file"         'grep -q "NEWER locally than the archive copy" <<<"$SP_DRY"'
check "dry run writes nothing"                     'grep -q "local edit" "$RESTORE/state/learnings.md"'
# The local edit was written AFTER the export, so the archive is stale for it and
# --force alone must refuse: replacing it would silently discard the newer state.
SP_STALE="$(DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" --force 2>&1 || true)"
check "--force refuses a newer local file"         '! DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" --force >/dev/null 2>&1'
check "the refusal names the newer file"           'grep -q "state/learnings.md" <<<"$SP_STALE"'
check "the refused import kept the local edit"     'grep -q "local edit" "$RESTORE/state/learnings.md"'
check "--overwrite-newer replaces the file"        'DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" --force --overwrite-newer >/dev/null && ! grep -q "local edit" "$RESTORE/state/learnings.md"'
# Nothing is discarded without a copy: the replaced content stays recoverable.
check "replaced files are backed up"               '[ -n "$(grep -rl "local edit" "$RESTORE/state/backups" 2>/dev/null)" ]'
check "import never deletes unarchived files"      '[ -f "$RESTORE/state/tasks/not-in-archive.meta" ]'

# Integrity and path safety: an archive is untrusted input.
SP_T="$TMP/state-tamper"; mkdir -p "$SP_T"; tar -xzf "$SP/full.tar.gz" -C "$SP_T"
printf 'corrupt\n' >> "$SP_T/payload/state/repos.json"
( cd "$SP_T" && tar -czf "$SP/tampered.tar.gz" . )
check "verify refuses a checksum mismatch"         '! b dm-state.sh verify "$SP/tampered.tar.gz" >/dev/null 2>&1'
rm -rf "$SP_T"; mkdir -p "$SP_T"; tar -xzf "$SP/full.tar.gz" -C "$SP_T"
printf 'extra\n' > "$SP_T/payload/state/sneaked.md"
( cd "$SP_T" && tar -czf "$SP/extra.tar.gz" . )
check "verify refuses an unlisted payload file"    '! b dm-state.sh verify "$SP/extra.tar.gz" >/dev/null 2>&1'
rm -rf "$SP_T"; mkdir -p "$SP_T"; tar -xzf "$SP/full.tar.gz" -C "$SP_T"
mkdir -p "$SP_T/payload/repos/demo"; printf 'pwn\n' > "$SP_T/payload/repos/demo/evil.txt"
jq '.files += [{sha256:"0",bytes:4,path:"repos/demo/evil.txt"}]' "$SP_T/manifest.json" > "$SP_T/m.json"
mv "$SP_T/m.json" "$SP_T/manifest.json"
( cd "$SP_T" && tar -czf "$SP/escape.tar.gz" . )
SP_ESCAPE="$(b dm-state.sh verify "$SP/escape.tar.gz" 2>&1 || true)"
check "verify refuses a path outside the record set" 'grep -q "refusing archive path outside" <<<"$SP_ESCAPE"'
rm -rf "$SP_T"; mkdir -p "$SP_T"; tar -xzf "$SP/full.tar.gz" -C "$SP_T"
printf 'smuggled\n' > "$SP_T/payload/state/tasks/smuggled.meta"
jq '.files += [.files[0]]' "$SP_T/manifest.json" > "$SP_T/m.json"
mv "$SP_T/m.json" "$SP_T/manifest.json"
( cd "$SP_T" && tar -czf "$SP/dup.tar.gz" . )
SP_DUP="$(b dm-state.sh verify "$SP/dup.tar.gz" 2>&1 || true)"
check "verify refuses a duplicate manifest entry"  'grep -q "duplicate path" <<<"$SP_DUP"'
check "a duplicate entry cannot smuggle a file"    '! b dm-state.sh verify "$SP/dup.tar.gz" >/dev/null 2>&1'
rm -rf "$SP_T"; mkdir -p "$SP_T"; tar -xzf "$SP/full.tar.gz" -C "$SP_T"
ln -s /etc/passwd "$SP_T/payload/state/tasks/evil.meta"
( cd "$SP_T" && tar -czf "$SP/symlink.tar.gz" . )
SP_LINK="$(b dm-state.sh verify "$SP/symlink.tar.gz" 2>&1 || true)"
check "verify refuses a symlink payload member"    'grep -q "non-regular file" <<<"$SP_LINK"'
check "verify refuses a non-archive"               '! b dm-state.sh verify "$ROOT/README.md" >/dev/null 2>&1'
check "verify refuses a missing archive"           '! b dm-state.sh verify "$SP/nope.tar.gz" >/dev/null 2>&1'
check "export refuses to clobber an existing file" '! b dm-state.sh export --out "$SP/full.tar.gz" >/dev/null 2>&1'
check "no subcommand exits 2"                      'SP_RC=0; b dm-state.sh >/dev/null 2>&1 || SP_RC=$?; [ "$SP_RC" = 2 ]'

# Records-only export: artifacts are opt-in, and their absence is stated.
SP_NOART="$(b dm-state.sh export --out "$SP/records.tar.gz")"
SP_NOART_PATHS="$(tar -xzOf "$SP/records.tar.gz" ./manifest.json | jq -r '.files[].path')"
check "records-only export omits data/"            '! grep -q "^data/" <<<"$SP_NOART_PATHS"'
check "records-only export still carries records"  'grep -qx "state/repos.json" <<<"$SP_NOART_PATHS"'
check "records-only export says artifacts are out" 'grep -q "artifacts: NOT included" <<<"$SP_NOART"'
SP_NOART_IMPORT="$(DM_HOME="$TMP/restore-records" "$ROOT/bin/dm-state.sh" import "$SP/records.tar.gz")"
check "import reports the missing artifacts"       'grep -q "under data/ were not in this archive" <<<"$SP_NOART_IMPORT"'
# A real --with-artifacts export indexes thousands of files. Linux caps a SINGLE
# argv string at 128K (MAX_ARG_STRLEN, far below total ARG_MAX), so passing the
# index to jq as --arg died with "Argument list too long" and wrote NO archive at
# all - the recommended backup command, unusable on any real state root. Long
# names reach the limit with few files, so the fixture stays fast.
SP_BIG="$TMP/state-bigindex"
mkdir -p "$SP_BIG/state" "$SP_BIG/data/big"
printf '{"repos":{}}\n' > "$SP_BIG/state/repos.json"
sp_i=0
while [ "$sp_i" -lt 700 ]; do
  printf 'x\n' > "$SP_BIG/data/big/$(printf 'f%0240d' "$sp_i")"
  sp_i=$((sp_i + 1))
done
SP_BIG_INDEX_BYTES="$(cd "$SP_BIG" && find data -type f | awk '{n += length($0) + 72} END {print n}')"
check "the big-index fixture exceeds 128K"          '[ "$SP_BIG_INDEX_BYTES" -gt 131072 ]'
check "export survives a >128K file index"          'DM_HOME="$SP_BIG" "$ROOT/bin/dm-state.sh" export --out "$SP/bigindex.tar.gz" --with-artifacts >/dev/null 2>&1'
check "the big-index archive verifies"              'DM_HOME="$SP_BIG" "$ROOT/bin/dm-state.sh" verify "$SP/bigindex.tar.gz" >/dev/null 2>&1'
# The index is not the only unbounded jq input: the NON-REGULAR list (npm and
# playwright leave symlink trees under data/) scales the same way and was still
# passed as --arg. The big-index fixture above uses only regular files, so it
# never exercised nonreg. A symlink-heavy tree pushes the non-regular list past
# MAX_ARG_STRLEN; the old --arg overflowed and wrote no archive at all.
SP_SYM="$TMP/state-symheavy"
mkdir -p "$SP_SYM/state" "$SP_SYM/data/qa/node_modules/.bin"
printf '{"repos":{}}\n' > "$SP_SYM/state/repos.json"
printf 'x\n' > "$SP_SYM/data/qa/node_modules/real.js"
sp_j=0
while [ "$sp_j" -lt 700 ]; do
  ln -s ../real.js "$SP_SYM/data/qa/node_modules/.bin/$(printf 'link%0200d' "$sp_j")"
  sp_j=$((sp_j + 1))
done
# Exactly the string list_non_regular_artifacts emits (data/<relpath>, one per line).
SP_SYM_NONREG_BYTES="$(cd "$SP_SYM" && find data -type l | LC_ALL=C sort | wc -c | tr -d ' ')"
check "the symlink fixture's non-regular list exceeds 128K" '[ "$SP_SYM_NONREG_BYTES" -gt 131072 ]'
check "export survives a >128K non-regular list"           'DM_HOME="$SP_SYM" "$ROOT/bin/dm-state.sh" export --out "$SP/symheavy.tar.gz" --with-artifacts >/dev/null 2>&1'
check "the symlink-heavy archive verifies"                 'DM_HOME="$SP_SYM" "$ROOT/bin/dm-state.sh" verify "$SP/symheavy.tar.gz" >/dev/null 2>&1'
SP_SYM_NONREG_COUNT="$(tar -xzOf "$SP/symheavy.tar.gz" ./manifest.json | jq -r '.omitted_non_regular | length')"
check "every non-regular member is still named"            '[ "$SP_SYM_NONREG_COUNT" -eq 700 ]'
# The temp list files jq reads must never ride along in the archive.
check "manifest list temp files never enter the archive"   '! tar -tzf "$SP/symheavy.tar.gz" | grep -qE "omitted.list|nonreg.list"'

# A corrupt repos.json is exactly the broken control plane an operator may want
# to BACK UP for recovery (#112): export must archive it byte-for-byte and NOT
# refuse, but neither may a restore silently enumerate zero repos. The old
# report_reestablish read the registry with `2>/dev/null || true`, so a corrupt
# restored registry printed nothing and the restore looked complete. Fixed both
# ways: export stays faithful; the import re-establish report NAMES the corruption.
SP_CORRUPT="$TMP/state-corrupt-registry"
mkdir -p "$SP_CORRUPT/state/tasks"
# Truncated JSON - valid-looking head, no closing braces, so jq refuses to parse.
printf '{"repos": {"demo": {"remote": "git@x:demo.git"\n' > "$SP_CORRUPT/state/repos.json"
printf '# ops\n' > "$SP_CORRUPT/state/operator.md"
check "the corrupt-registry fixture does not parse"  '! jq . "$SP_CORRUPT/state/repos.json" >/dev/null 2>&1'
SP_CORRUPT_EXPORT_RC=0
DM_HOME="$SP_CORRUPT" "$ROOT/bin/dm-state.sh" export --out "$SP/corrupt.tar.gz" >/dev/null 2>&1 || SP_CORRUPT_EXPORT_RC=$?
check "export does not refuse a corrupt registry"    '[ "$SP_CORRUPT_EXPORT_RC" = 0 ]'
# The assertion that guards the backup-a-broken-state capability against a future
# "just validate up front" simplification: the raw file must travel intact.
tar -xzOf "$SP/corrupt.tar.gz" ./payload/state/repos.json > "$SP/corrupt-archived.json"
check "a corrupt registry is archived byte-faithfully" 'cmp -s "$SP_CORRUPT/state/repos.json" "$SP/corrupt-archived.json"'
SP_CORRUPT_IMPORT_RC=0
SP_CORRUPT_IMPORT="$(DM_HOME="$TMP/restore-corrupt" "$ROOT/bin/dm-state.sh" import "$SP/corrupt.tar.gz" 2>&1)" || SP_CORRUPT_IMPORT_RC=$?
check "importing a corrupt registry still succeeds"   '[ "$SP_CORRUPT_IMPORT_RC" = 0 ]'
check "the re-establish report names the corruption"  'grep -q "does NOT parse" <<<"$SP_CORRUPT_IMPORT"'
check "a corrupt registry is not silently zero repos" '! grep -q "clone missing for" <<<"$SP_CORRUPT_IMPORT"'
check "a corrupt registry restores byte-faithfully"   'cmp -s "$SP_CORRUPT/state/repos.json" "$TMP/restore-corrupt/state/repos.json"'

rm -rf "$DM_HOME/state/unknown-extra" "$DM_HOME/state/tasks/subdir" "$DM_HOME/data/sp-artifacts"
rm -f "$DM_HOME/state/tasks/t1.report" "$DM_HOME/state/archive/stray.json" "$DM_HOME/repos/demo/.dm/keys.txt"

echo "== #126.2: dm-pr.sh check on an unknown task names the missing TASK, not a missing PR =="
# Before: a typo'd id was misreported as "no PR recorded" — plausible and
# wrong, since the task itself does not exist.
CHECKNOTASK="$(b dm-pr.sh check no-such-task-xyz 2>&1 || true)"
check "an unknown task id is reported as no such task"     'grep -q "no such task" <<<"$CHECKNOTASK"'
check "an unknown task id is not misreported as a missing PR" '! grep -q "no PR recorded" <<<"$CHECKNOTASK"'
# A real task with no PR yet keeps the original, correct message.
b dm-task.sh new pr126-notask --kind ship --repo demo >/dev/null 2>&1
CHECKNOPR="$(b dm-pr.sh check pr126-notask 2>&1 || true)"
check "a real task with no PR still says no PR recorded"   'grep -q "no PR recorded" <<<"$CHECKNOPR"'

echo "== #107: sweep issues ONE gh call per PR (was 4), reviews truncation fails closed =="
# A GitHub-shaped, still-local origin so repo_slug resolves to o/r while every
# fetch stays hermetic (same trick as the merge-base-exception fixtures above).
b dm-repo.sh add prswp2 "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
mkdir -p "$DM_HOME/repos/prswp2/o"
ln -s "$TMP/origin.git" "$DM_HOME/repos/prswp2/o/r.git"
git -C "$DM_HOME/repos/prswp2" remote set-url origin o/r.git
b dm-task.sh new prswp2-a --kind ship --repo prswp2 >/dev/null 2>&1
b dm-task.sh new prswp2-b --kind ship --repo prswp2 >/dev/null 2>&1
( . "$ROOT/bin/dm-lib.sh"
  dm_meta_set prswp2-a pr "https://github.com/o/r/pull/101"
  dm_meta_set prswp2-b pr "https://github.com/o/r/pull/102" ) >/dev/null 2>&1

GHSTUB107="$TMP/ghstub107"; mkdir -p "$GHSTUB107"
cat > "$GHSTUB107/gh" <<STUB
#!/bin/sh
D="$GHSTUB107"
printf '%s\n' "\$*" >> "\$D/gh-calls"
case "\$*" in
  *graphql*number=101*) cat "\$D/pr101.json"; exit 0 ;;
  *graphql*number=102*) cat "\$D/pr102.json"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$GHSTUB107/gh"
# PR 101: one real CHANGES_REQUESTED review, page complete (hasNextPage=false)
# — the ordinary case sweep must still catch.
cat > "$GHSTUB107/pr101.json" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "state":"OPEN","merged":false,"headRefOid":"aaa111",
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]},
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z","author":{"login":"carol"}}
  ]}
}}}}
JSON
# PR 102: the #107 false-green — every VISIBLE review is APPROVED, but
# hasNextPage=true says more reviews exist beyond this page (the shape a
# >30-review PR takes once the reviews call is paginated). Naively trusting
# only what came back would report "clean"; it must fail closed to "unknown".
cat > "$GHSTUB107/pr102.json" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "state":"OPEN","merged":false,"headRefOid":"bbb222",
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]},
  "reviews":{"pageInfo":{"hasNextPage":true},"nodes":[
    {"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z","author":{"login":"dave"}}
  ]}
}}}}
JSON
SWEEP107="$(PATH="$GHSTUB107:$PATH" b dm-pr.sh sweep 2>&1)"
check "sweep detects a real changes-requested review"        'grep -q "prswp2-a  state: OPEN  checks: passing  reviews: changes-requested" <<<"$SWEEP107"'
check "a truncated review page is reported unknown, not clean (#107)" 'grep -q "prswp2-b  state: OPEN  checks: passing  reviews: unknown" <<<"$SWEEP107"'
check "a truncated review page is NEVER reported clean (the false-green)" '! grep -q "prswp2-b  state: OPEN  checks: passing  reviews: clean" <<<"$SWEEP107"'
check "the summary counts only the real changes-requested PR" 'grep -q "1 with changes requested" <<<"$SWEEP107"'
check "sweep refreshes cached pr_state for an open PR"        '[ "$(b dm-task.sh get prswp2-a pr_state)" = "OPEN" ]'
check "sweep refreshes cached checks for an open PR"          '[ "$(b dm-task.sh get prswp2-a checks)" = "passing" ]'
# Round-trip count (#107): the old path cost 4 gh calls per PR (PR details,
# check-runs, commit-status, reviews); one GraphQL call per PR replaces all 4.
# Scoped to these two PR numbers specifically: the shared fixture DM_HOME this
# late in the suite still carries other open-PR tasks from earlier sections
# (e.g. mauth-exc), which this same sweep also visits and which fail closed —
# harmlessly, but a raw total line count would double-count them.
check "sweep issues exactly ONE gh call per PR, not 4 (#107)" \
  '[ "$(grep -c "number=101" "$GHSTUB107/gh-calls")" -eq 1 ] && [ "$(grep -c "number=102" "$GHSTUB107/gh-calls")" -eq 1 ]'
check "every call is a single graphql request"                '[ "$(grep -c graphql "$GHSTUB107/gh-calls")" -ge 2 ]'

echo "== #107: bounded retry/backoff on a rate-limited or transient gh failure =="
b dm-task.sh new prswp2-retry --kind ship --repo prswp2 >/dev/null 2>&1
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set prswp2-retry pr "https://github.com/o/r/pull/103" ) >/dev/null 2>&1
GHRETRY="$TMP/ghretry107"; mkdir -p "$GHRETRY"
# Every other still-open task in the shared fixture DM_HOME (mauth-exc,
# prswp2-a/b, ...) is also visited by this sweep; only number=103 (this
# section's task) gets the controlled fail/succeed behavior below — anything
# else just fails immediately and harmlessly, like an unrelated PR always has.
cat > "$GHRETRY/gh" <<STUB
#!/bin/sh
D="$GHRETRY"
printf '%s\n' "\$*" >> "\$D/gh-calls"
case "\$*" in
  *number=103*)
    N=\$(grep -c "number=103" "\$D/gh-calls")
    FAILUNTIL=\$(cat "\$D/fail-until" 2>/dev/null || echo 0)
    if [ "\$N" -le "\$FAILUNTIL" ]; then
      if [ -f "\$D/transient" ]; then
        echo "HTTP 429: API rate limit exceeded for user ID 123" >&2
      else
        echo "HTTP 404: Not Found" >&2
      fi
      exit 1
    fi
    cat "\$D/pr.json"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$GHRETRY/gh"
cat > "$GHRETRY/pr.json" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "state":"OPEN","merged":false,"headRefOid":"ccc333",
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]},
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON
# Base delay 0 so the test does not actually sleep between attempts.
rm -f "$GHRETRY/gh-calls"; printf '1\n' > "$GHRETRY/fail-until"; : > "$GHRETRY/transient"
RETRYOUT="$(DM_GH_RETRY_MAX=3 DM_GH_RETRY_BASE_SECS=0 PATH="$GHRETRY:$PATH" b dm-pr.sh sweep 2>&1)"
check "a transient failure is retried and eventually succeeds" 'grep -q "prswp2-retry  state: OPEN" <<<"$RETRYOUT"'
check "retry stopped as soon as it succeeded (2 attempts, not the 3-attempt max)" \
  '[ "$(grep -c "number=103" "$GHRETRY/gh-calls")" -eq 2 ]'

rm -f "$GHRETRY/gh-calls"; printf '99\n' > "$GHRETRY/fail-until"; : > "$GHRETRY/transient"
EXHAUSTOUT="$(DM_GH_RETRY_MAX=3 DM_GH_RETRY_BASE_SECS=0 PATH="$GHRETRY:$PATH" b dm-pr.sh sweep 2>&1)"
check "exhausted retries surface a loud refusal" 'grep -q "could not read PR" <<<"$EXHAUSTOUT"'
check "exhaustion never fakes a clean/passing result" '! grep -q "prswp2-retry  state: OPEN" <<<"$EXHAUSTOUT"'
check "exhaustion stops at the bounded retry max (3 attempts, not unbounded)" \
  '[ "$(grep -c "number=103" "$GHRETRY/gh-calls")" -eq 3 ]'

rm -f "$GHRETRY/gh-calls" "$GHRETRY/transient"; printf '99\n' > "$GHRETRY/fail-until"
PERMOUT="$(DM_GH_RETRY_MAX=3 DM_GH_RETRY_BASE_SECS=0 PATH="$GHRETRY:$PATH" b dm-pr.sh sweep 2>&1)"
check "a permanent (non-rate-limit) failure is not retried" \
  '[ "$(grep -c "number=103" "$GHRETRY/gh-calls")" -eq 1 ]'
check "a permanent failure still refuses loudly, never a false clean" 'grep -q "could not read PR" <<<"$PERMOUT" && ! grep -q "prswp2-retry  state: OPEN" <<<"$PERMOUT"'
echo "== backlog integrity: corruption never reads as 'no such item' (#152) =="
# Own throwaway DM_HOME: these deliberately corrupt state/backlog.json, which
# must never touch the suite's main home.
BLINT="$TMP/blint"
mkdir -p "$BLINT"
DM_HOME="$BLINT" "$ROOT/bin/dm-repo.sh" add gadget "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
DM_HOME="$BLINT" "$ROOT/bin/dm-task.sh" new blint-1 --kind ship --repo gadget >/dev/null
DM_HOME="$BLINT" "$ROOT/bin/dm-backlog.sh" add blint-1 "corruption fixture item" --repo gadget --status inflight >/dev/null
check "fixture: a healthy backlog resolves the item" \
  'jq -e ".items[]|select(.id==\"blint-1\")" "$BLINT/state/backlog.json" >/dev/null'

# Missing and zero-length are legitimate first-run states, not corruption.
check "a missing backlog.json is a first-run state" \
  'DM_HOME="$TMP/blint-missing" "$ROOT/bin/dm-backlog.sh" list >/dev/null 2>&1'
mkdir -p "$TMP/blint-empty/state"; : > "$TMP/blint-empty/state/backlog.json"
check "a zero-length backlog.json is a first-run state and is re-seeded" \
  'DM_HOME="$TMP/blint-empty" "$ROOT/bin/dm-backlog.sh" list >/dev/null 2>&1 &&
   [ "$(jq -c . "$TMP/blint-empty/state/backlog.json")" = "{\"items\":[],\"decisions\":[]}" ]'
# An object missing .items/.decisions is corruption, not an empty backlog.
mkdir -p "$TMP/blint-noitems/state"; printf '{}\n' > "$TMP/blint-noitems/state/backlog.json"
check "an object with no .items/.decisions keys is corruption, not an empty backlog" \
  '! DM_HOME="$TMP/blint-noitems" "$ROOT/bin/dm-backlog.sh" list >/dev/null 2>&1'

printf '{"items": [broken\n' > "$BLINT/state/backlog.json"

# ENUMERATED consumers: every dm-backlog.sh subcommand must refuse loudly on a
# corrupt file, distinctly from "id not found" — the exact class #112 closed
# for the registry, here for backlog.json.
BLINT_FAILED=""
while IFS= read -r consumer; do
  [ -n "$consumer" ] || continue
  # shellcheck disable=SC2086
  if DM_HOME="$BLINT" "$ROOT/bin/"$consumer >/dev/null 2>"$TMP/blint-err"; then
    BLINT_FAILED="$BLINT_FAILED [exited 0: $consumer]"
  elif [ ! -s "$TMP/blint-err" ]; then
    BLINT_FAILED="$BLINT_FAILED [silent: $consumer]"
  elif ! grep -q 'does not parse' "$TMP/blint-err"; then
    BLINT_FAILED="$BLINT_FAILED [unnamed: $consumer]"
  fi
done <<EOF
dm-backlog.sh list
dm-backlog.sh add blint-2 freshitem
dm-backlog.sh move blint-1 done
dm-backlog.sh done blint-1
dm-backlog.sh ready
dm-backlog.sh campaign fleet-x
dm-backlog.sh decisions
dm-backlog.sh hold hkey somequestion
dm-backlog.sh resolve hkey ananswer
dm-backlog.sh validate
EOF
check "every dm-backlog.sh consumer refuses a corrupt backlog, by name$BLINT_FAILED" '[ -z "$BLINT_FAILED" ]'

BLINT_MOVE_ERR="$(DM_HOME="$BLINT" "$ROOT/bin/dm-backlog.sh" move blint-1 done 2>&1 || true)"
check "corrupt backlog is never reported as 'no backlog item'" \
  '! grep -q "no backlog item" <<<"$BLINT_MOVE_ERR"'
check "the corruption message says CORRUPTION and how to inspect it" \
  'grep -q "CORRUPTION" <<<"$BLINT_MOVE_ERR" && grep -q "jq . " <<<"$BLINT_MOVE_ERR"'
check "the corruption message advises no destructive command" \
  '! grep -qE "rm -rf|rm -r " <<<"$BLINT_MOVE_ERR"'

BLINT_STATUS_OUT="$TMP/blint-status-out"; BLINT_STATUS_ERR="$TMP/blint-status-err"
DM_HOME="$BLINT" "$ROOT/bin/dm-status.sh" >"$BLINT_STATUS_OUT" 2>"$BLINT_STATUS_ERR" && BLINT_STATUS_RC=0 || BLINT_STATUS_RC=$?
check "dm-status on a corrupt backlog exits non-zero (found alongside #152)" \
  '[ "$BLINT_STATUS_RC" -ne 0 ]'
check "dm-status on a corrupt backlog says what is wrong, not silent" \
  '[ -s "$BLINT_STATUS_ERR" ] || grep -q "FAIL backlog" "$BLINT_STATUS_OUT"'
check "a corrupt backlog is never rendered as clean drift/ready/decisions" \
  '! grep -q "(no drift)" "$BLINT_STATUS_OUT" &&
   ! grep -q "(nothing ready)" "$BLINT_STATUS_OUT" &&
   ! grep -q "(none open)" "$BLINT_STATUS_OUT"'
check "every backlog-dependent section reports the failure, not just one" \
  '[ "$(grep -c "FAIL backlog" "$BLINT_STATUS_OUT")" -eq 4 ]'
check "dm-status still renders the sections that do not depend on the backlog" \
  'grep -q "MANAGED REPOS" "$BLINT_STATUS_OUT" && grep -q "IN-FLIGHT WORK" "$BLINT_STATUS_OUT"'

# A well-formed JSON document of the wrong shape is corruption too.
BLINT_SHAPE=""
for shape in '{"items": {}, "decisions": []}' '[1,2,3]' '"nope"'; do
  mkdir -p "$TMP/blint-shape/state"; printf '%s\n' "$shape" > "$TMP/blint-shape/state/backlog.json"
  DM_HOME="$TMP/blint-shape" "$ROOT/bin/dm-backlog.sh" list >/dev/null 2>&1 &&
    BLINT_SHAPE="$BLINT_SHAPE [$shape]" || true
done
check "a well-formed JSON document of the wrong shape is corruption$BLINT_SHAPE" '[ -z "$BLINT_SHAPE" ]'

echo "== toolbelt papercuts: unknown campaign errors, not silent success (#126.4) =="
CAMP126_OUT="$TMP/camp126-out"; CAMP126_ERR="$TMP/camp126-err"
b dm-backlog.sh campaign camp-never-created >"$CAMP126_OUT" 2>"$CAMP126_ERR" && CAMP126_RC=0 || CAMP126_RC=$?
check "unknown campaign exits non-zero"                    '[ "$CAMP126_RC" -ne 0 ]'
check "unknown campaign names itself, not a blank success" \
  '[ ! -s "$CAMP126_OUT" ] && grep -q "no such campaign: camp-never-created" "$CAMP126_ERR"'

echo "== toolbelt papercuts: add shows usage alongside an invalid id (#126.5) =="
ADD126_ERR="$(b dm-backlog.sh add "fix the flaky test" --repo gadget 2>&1 || true)"
check "title-as-id add still names the invalid id"                 'grep -q "invalid task/repo id" <<<"$ADD126_ERR"'
check "title-as-id add also prints usage, not just the bare error" 'grep -q "usage: dm-backlog.sh add" <<<"$ADD126_ERR"'

echo "== dm-status ORPHAN honesty: canonicalized paths, not raw strings (#147) =="
C147_REAL="$TMP/c147-real"; C147_LINK="$TMP/c147-link"
mkdir -p "$C147_REAL"
ln -s "$C147_REAL" "$C147_LINK"
C147_HOME="$C147_LINK/home"
C147_CANON_HOME="$C147_REAL/home"
DM_HOME="$C147_HOME" "$ROOT/bin/dm-repo.sh" add gadget "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
DM_HOME="$C147_HOME" DM_NO_FETCH=1 "$ROOT/bin/dm-task.sh" new c147-task --kind ship --repo gadget >/dev/null
DM_HOME="$C147_HOME" DM_NO_FETCH=1 "$ROOT/bin/dm-worktree.sh" create c147-task gadget >/dev/null 2>&1
C147_RECORDED="$(DM_HOME="$C147_HOME" "$ROOT/bin/dm-task.sh" get c147-task worktree)"
check "fixture: the recorded worktree starts out canonical" \
  '[ "$C147_RECORDED" = "$C147_CANON_HOME/state/worktrees/c147-task" ]'
# Rewrite the record to the pre-canonicalization (symlinked-root) form, simulating
# a task created before DM_HOME canonicalization existed. Same real directory,
# different string.
C147_LEGACY="$C147_HOME/state/worktrees/c147-task"
C147_META="$C147_CANON_HOME/state/tasks/c147-task.meta"
sed "s#^worktree=.*#worktree=$C147_LEGACY#" "$C147_META" > "$C147_META.new" && mv "$C147_META.new" "$C147_META"
check "fixture: the meta now holds the non-canonical symlinked path" \
  'grep -qx "worktree=$C147_LEGACY" "$C147_META"'
# A genuine orphan: a directory under state/worktrees/ with no task record at all.
mkdir -p "$C147_CANON_HOME/state/worktrees/c147-genuine-orphan"

C147_STATUS="$(DM_HOME="$C147_HOME" "$ROOT/bin/dm-status.sh" 2>&1)"
check "a legacy non-canonical worktree record is NOT reported ORPHAN" \
  '! grep -q "ORPHAN.*worktrees/c147-task$" <<<"$C147_STATUS"'
check "a genuine orphan is still reported ORPHAN" \
  'grep -q "ORPHAN.*worktrees/c147-genuine-orphan$" <<<"$C147_STATUS"'

echo "== #107 gate fix: gh_api_retry signals failure through its OWN return code =="
# Direct unit test of the return-code contract, via the existing prfn probe
# (sources dm-pr.sh harmlessly through its `url` command, then calls any
# function directly). Indirect sweep-level tests alone do not catch this: a
# downstream `jq -e` on empty input also happens to fail, masking a broken
# return code at the caller. This targets gh_api_retry itself.
GHRC1="$TMP/gh-retry-rc-perm"; mkdir -p "$GHRC1"
cat > "$GHRC1/gh" <<'STUB'
#!/bin/sh
echo "HTTP 404: Not Found" >&2
exit 1
STUB
chmod +x "$GHRC1/gh"
RC1=0
OUT1="$(PATH="$GHRC1:$PATH" prfn gh_api_retry "repos/o/r/pulls/1" 2>"$TMP/gh-retry-rc-perm-err")" || RC1=$?
check "gh_api_retry returns non-zero on a permanent failure"  '[ "$RC1" -ne 0 ]'
check "gh_api_retry prints no stdout on a permanent failure"  '[ -z "$OUT1" ]'
check "gh_api_retry surfaces the underlying error on stderr"  'grep -q "HTTP 404" "$TMP/gh-retry-rc-perm-err"'

GHRC2="$TMP/gh-retry-rc-exhaust"; mkdir -p "$GHRC2"
cat > "$GHRC2/gh" <<'STUB'
#!/bin/sh
echo "HTTP 429: API rate limit exceeded" >&2
exit 1
STUB
chmod +x "$GHRC2/gh"
RC2=0
OUT2="$(DM_GH_RETRY_MAX=2 DM_GH_RETRY_BASE_SECS=0 PATH="$GHRC2:$PATH" prfn gh_api_retry "repos/o/r/pulls/1" 2>/dev/null)" || RC2=$?
check "gh_api_retry returns non-zero after exhausting retries" '[ "$RC2" -ne 0 ]'
check "gh_api_retry prints no stdout after exhausting retries" '[ -z "$OUT2" ]'

echo "== #107 gate fix: sweep summary names an unknown checks/review, never blends into clean =="
b dm-repo.sh add prswp3 "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
mkdir -p "$DM_HOME/repos/prswp3/o"
ln -s "$TMP/origin.git" "$DM_HOME/repos/prswp3/o/r.git"
git -C "$DM_HOME/repos/prswp3" remote set-url origin o/r.git
b dm-task.sh new prswp3-a --kind ship --repo prswp3 >/dev/null 2>&1
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set prswp3-a pr "https://github.com/o/r/pull/201" ) >/dev/null 2>&1
GHSTUB201="$TMP/ghstub201"; mkdir -p "$GHSTUB201"
cat > "$GHSTUB201/gh" <<STUB
#!/bin/sh
case "\$*" in
  *number=201*) cat "$GHSTUB201/pr201.json"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$GHSTUB201/gh"
# hasNextPage:true -> review unknown (fails closed, #107); an unrecognized
# statusCheckRollup state similarly falls closed to checks: unknown.
cat > "$GHSTUB201/pr201.json" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "state":"OPEN","merged":false,"headRefOid":"ddd444",
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"BOGUS_UNEXPECTED_STATE"}}}]},
  "reviews":{"pageInfo":{"hasNextPage":true},"nodes":[]}
}}}}
JSON
SWEEP201="$(PATH="$GHSTUB201:$PATH" b dm-pr.sh sweep 2>&1)"
check "the per-line output shows unknown, not a silent clean/passing" \
  'grep -q "prswp3-a  state: OPEN  checks: unknown  reviews: unknown" <<<"$SWEEP201"'
check "the summary names the unverified review, not silence" \
  'grep -q "1 with an unverified review" <<<"$SWEEP201"'
check "the summary names the unknown CI, not silence" \
  'grep -q "1 with unknown CI" <<<"$SWEEP201"'

echo "== #107 gate fix: sweep's circuit breaker aborts on sustained rate limiting =="
# Reuses the GHRETRY fixture (prswp2-retry, PR 103) from the retry/backoff
# section above: fail-until=99 with the transient marker set means every
# attempt looks rate-limited, so gh_api_retry always exhausts. A breaker max
# of 1 trips on that single exhausted PR regardless of where in the fleet
# enumeration order it falls — no need to stage 5 consecutive tasks.
rm -f "$GHRETRY/gh-calls"; printf '99\n' > "$GHRETRY/fail-until"; : > "$GHRETRY/transient"
CB_RC=0
CBOUT="$(DM_GH_RETRY_MAX=2 DM_GH_RETRY_BASE_SECS=0 DM_GH_CIRCUIT_BREAKER_MAX=1 PATH="$GHRETRY:$PATH" b dm-pr.sh sweep 2>&1)" || CB_RC=$?
check "the breaker aborts the whole sweep, not just the one PR" '[ "$CB_RC" -ne 0 ]'
check "the abort names sustained rate limiting"                 'grep -qi "rate limit" <<<"$CBOUT"'
rm -f "$GHRETRY/fail-until" "$GHRETRY/transient"
echo "== record integrity: a task cannot forge its own delivery route (#127) =="
# `set <id> mode local-only` on a PIPELINE repo used to be accepted, and
# `dm-merge.sh local` trusted that field: unreviewed work fast-forwarded straight
# onto the managed clone's default branch — no PR, no review, no operator word —
# and the real `merged` event it appended reconciled the task to done. Two gates
# now, because either alone leaves the other half of the route open.
b dm-repo.sh add ripipe "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
b dm-task.sh new ri-forge --kind ship --repo ripipe >/dev/null
cp "$DM_HOME/state/tasks/ri-forge.meta" "$TMP/ri-forge.meta.before"
check "set refuses a mode the repo is not registered for" \
  '! b dm-task.sh set ri-forge mode local-only >/dev/null 2>&1 && cmp -s "$TMP/ri-forge.meta.before" "$DM_HOME/state/tasks/ri-forge.meta"'
RI_MODEOUT="$(b dm-task.sh set ri-forge mode local-only 2>&1 || true)"
check "the mode refusal points at the registry, not the task" \
  'grep -q "dm-repo.sh set ripipe mode local-only" <<<"$RI_MODEOUT"'
check "set still re-syncs a task to its repo's registered mode" \
  'b dm-task.sh set ri-forge mode pipeline >/dev/null 2>&1'
check "set reserves the repo field, unchanged" \
  '! b dm-task.sh set ri-forge repo demo >/dev/null 2>&1 && [ "$(b dm-task.sh get ri-forge repo)" = ripipe ]'
check "set still writes an ordinary field (guard the guard)" \
  'b dm-task.sh set ri-forge model sonnet >/dev/null 2>&1 && [ "$(b dm-task.sh get ri-forge model)" = sonnet ]'
# `kind` is directional: promotion is documented, demotion is the forge. Demoting
# a ship task to scout makes a fabricated report.md reconcile it to done and lets
# teardown discard its committed work as investigation scratch.
b dm-task.sh new ri-kind --kind scout --repo demo >/dev/null
check "set promotes a scout task to ship (the documented path)" \
  'b dm-task.sh set ri-kind kind ship >/dev/null 2>&1 && [ "$(b dm-task.sh get ri-kind kind)" = ship ]'
RI_KIND_RC=0
RI_KINDOUT="$(b dm-task.sh set ri-kind kind scout 2>&1)" || RI_KIND_RC=$?
check "set refuses demoting a ship task back to scout" '[ "$RI_KIND_RC" -ne 0 ]'
check "the refused demotion left the kind alone"      '[ "$(b dm-task.sh get ri-kind kind)" = ship ]'
check "the demotion refusal names the honest way out" 'grep -q "dm-task.sh close ri-kind" <<<"$RI_KINDOUT"'
mkdir -p "$DM_HOME/data/ri-kind"
printf '# fabricated\n' > "$DM_HOME/data/ri-kind/report.md"
check "so a fabricated report cannot reconcile a ship task to done" \
  '! DM_NO_FETCH=1 b dm-task.sh state ri-kind | grep -q "state: done"'
RIWT="$(b dm-worktree.sh create ri-forge ripipe | tail -n1)"
git -C "$RIWT" checkout -q -b feat/x/ri-forge
printf 'unreviewed\n' > "$RIWT/forged.txt"
git -C "$RIWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$RIWT" -c user.email=c@c.co -c user.name=c commit -qm "unreviewed work" >/dev/null
RI_BEFORE="$(git -C "$DM_HOME/repos/ripipe" rev-parse main)"
# Stand in for a writer that got past the CLI guard (a hand-edited meta file):
# the landing gate must not depend on the CLI guard holding.
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set ri-forge mode local-only ) >/dev/null
check "the forged local-only mode is really in meta"   '[ "$(b dm-task.sh get ri-forge mode)" = local-only ]'
check "local land refuses on a pipeline-registered repo" '! b dm-merge.sh local ri-forge >/dev/null 2>&1'
RI_LANDOUT="$(b dm-merge.sh local ri-forge 2>&1 || true)"
check "the land refusal names the registered mode"     'grep -q "registered for .pipeline. delivery" <<<"$RI_LANDOUT"'
check "the refused land did not advance the clone"     '[ "$(git -C "$DM_HOME/repos/ripipe" rev-parse main)" = "$RI_BEFORE" ]'
check "no merged event was appended"                   '! grep -qE "^[^ ]+ merged: " "$DM_HOME/state/tasks/ri-forge.status"'
check "the task did not launder itself to done"        '! DM_NO_FETCH=1 b dm-task.sh state ri-forge | grep -q "state: done"'
# The registry decides in BOTH directions: the very same land succeeds once the
# operator records local-only delivery where that decision belongs.
b dm-repo.sh set ripipe mode local-only >/dev/null
check "the same land succeeds once the registry says local-only" 'b dm-merge.sh local ri-forge >/dev/null 2>&1'
check "the sanctioned land actually advanced the clone"          '[ "$(git -C "$DM_HOME/repos/ripipe" rev-parse main)" != "$RI_BEFORE" ]'
b dm-worktree.sh remove ri-forge >/dev/null 2>&1 || true

# THE DOCUMENTED OPERATOR SEQUENCE, end to end, on a task whose meta was NEVER
# hand-written: dispatch on a pipeline repo, operator picks a local landing,
# record it in the registry, land. The case above cannot prove this — it leaves a
# hand-forged `mode` in ri-forge's meta, so its final land would pass even if the
# route required that forge, which is exactly the vacuity to avoid here. A task
# inherits `mode` at CREATION, so `ri-doc` still says `pipeline` throughout.
b dm-repo.sh add ridoc "$TMP/origin.git" --mode pipeline --no-memory >/dev/null 2>&1
b dm-task.sh new ri-doc --kind ship --repo ridoc >/dev/null
RIDOCWT="$(b dm-worktree.sh create ri-doc ridoc | tail -n1)"
git -C "$RIDOCWT" checkout -q -b feat/x/ri-doc
printf 'approved\n' > "$RIDOCWT/doc.txt"
git -C "$RIDOCWT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$RIDOCWT" -c user.email=c@c.co -c user.name=c commit -qm "approved work" >/dev/null
RIDOC_BEFORE="$(git -C "$DM_HOME/repos/ridoc" rev-parse main)"
check "the task's inherited mode is plain pipeline"          '[ "$(b dm-task.sh get ri-doc mode)" = pipeline ]'
check "landing refuses while the repo delivers by pipeline"  '! b dm-merge.sh local ri-doc >/dev/null 2>&1'
b dm-repo.sh set ridoc mode local-only >/dev/null
check "the documented sequence lands with no task-meta edit" 'b dm-merge.sh local ri-doc >/dev/null 2>&1'
check "the documented land advanced the clone"               '[ "$(git -C "$DM_HOME/repos/ridoc" rev-parse main)" != "$RIDOC_BEFORE" ]'
check "and the task mode was never hand-written to get there" '[ "$(b dm-task.sh get ri-doc mode)" = pipeline ]'
b dm-worktree.sh remove ri-doc >/dev/null 2>&1 || true

echo "== a task's repo cannot be re-pointed, by any command (#127) =="
# `dm-task.sh set` reserves `repo`, but `dm-worktree.sh create` wrote it
# unconditionally — one ordinary command re-pointed a task recorded against a
# `never` repo at a permissive one, and the land then succeeded.
b dm-repo.sh add rinever "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-repo.sh set rinever merge_authority never >/dev/null
b dm-repo.sh add riperm "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new ri-point --kind ship --repo rinever >/dev/null
check "set refuses re-pointing the repo" '! b dm-task.sh set ri-point repo riperm >/dev/null 2>&1'
RIPT_RC=0
RIPTOUT="$(b dm-worktree.sh create ri-point riperm 2>&1)" || RIPT_RC=$?
check "worktree create refuses the other repo too"   '[ "$RIPT_RC" -ne 0 ]'
check "the refusal names the recorded repo and the argument" \
  'grep -q "rinever" <<<"$RIPTOUT" && grep -q "riperm" <<<"$RIPTOUT"'
check "the record still points at its own repo"      '[ "$(b dm-task.sh get ri-point repo)" = rinever ]'
check "no worktree was cut against the other repo"   '[ ! -e "$DM_HOME/state/worktrees/ri-point" ]'
check "create still works for the recorded repo"     'b dm-worktree.sh create ri-point rinever >/dev/null 2>&1'
check "so the never posture still governs the land"  '! b dm-merge.sh local ri-point >/dev/null 2>&1'
b dm-worktree.sh remove ri-point >/dev/null 2>&1 || true

echo "== containment: a clone that escapes repos/ is never operated on (#141) =="
# Containment used to stop at the DISTRO root: repos/<name> symlinked at any git
# repository elsewhere on disk resolved fine, so the toolbelt cut a worktree in
# that foreign repository and a crewmate could commit to its default branch.
RI_FOREIGN="$TMP/foreign-repo"
git init -q -b main "$RI_FOREIGN"
( cd "$RI_FOREIGN"; printf 'theirs\n' > victim.txt; git add -A
  git -c user.email=f@f.co -c user.name=f commit -qm "foreign init" ) >/dev/null 2>&1
RI_FHEAD="$(git -C "$RI_FOREIGN" rev-parse main)"
b dm-repo.sh add escapee "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new esc-1 --kind ship --repo escapee --mode local-only >/dev/null
# esc-2's local copy is cut while the clone is still healthy, so the commands
# that run AFTER the swap meet a worktree whose gitdir pointer is now broken —
# the shape that leaked git's raw "fatal: not a git repository: (null)".
b dm-task.sh new esc-2 --kind ship --repo escapee --mode local-only >/dev/null
ESC2WT="$(b dm-worktree.sh create esc-2 escapee | tail -n1)"
git -C "$ESC2WT" checkout -q -b feat/x/esc-2
printf 'w\n' > "$ESC2WT/w.txt"
git -C "$ESC2WT" -c user.email=c@c.co -c user.name=c add -A >/dev/null
git -C "$ESC2WT" -c user.email=c@c.co -c user.name=c commit -qm "work" >/dev/null
rm -rf "$DM_HOME/repos/escapee"
ln -s "$RI_FOREIGN" "$DM_HOME/repos/escapee"
# ONE invocation, rc captured: re-running create to test the refusal would let a
# regression pass on "worktree already exists" from the first, successful call.
ESC_RC=0
ESCOUT="$(b dm-worktree.sh create esc-1 escapee 2>&1)" || ESC_RC=$?
check "worktree create refuses a clone symlinked outside repos/" '[ "$ESC_RC" -ne 0 ]'
check "the refusal names where the clone actually lands" 'grep -qF "$RI_FOREIGN" <<<"$ESCOUT"'
check "the refusal names the managed clone root"         'grep -qF "$DM_HOME/repos" <<<"$ESCOUT"'
check "no worktree was cut in the foreign repository" \
  '[ ! -e "$DM_HOME/state/worktrees/esc-1" ] && [ "$(git -C "$RI_FOREIGN" worktree list | wc -l)" -eq 1 ]'
check "sync never fast-forwards an escaped clone"        '! b dm-sync.sh one escapee >/dev/null 2>&1'
check "memory recall refuses an escaped clone"           '! b dm-memory.sh recall escapee >/dev/null 2>&1'
check "the foreign repository is untouched"              '[ "$(git -C "$RI_FOREIGN" rev-parse main)" = "$RI_FHEAD" ]'
ri_within() { ( . "$ROOT/bin/dm-lib.sh"; dm_within_repos "$1" ); }
check "the containment predicate accepts a real managed clone" 'ri_within "$DM_HOME/repos/demo"'
check "the containment predicate refuses the escaped clone"    '! ri_within "$DM_HOME/repos/escapee"'
check "the containment predicate exempts the distro root"      'ri_within "$DM_HOME"'
check "the assertion treats an empty directory as a caller bug" \
  '! ( . "$ROOT/bin/dm-lib.sh"; dm_assert_within_repos "" "test subject" ) >/dev/null 2>&1'
# dm-repo.sh composes $DM_REPOS/<name> directly rather than going through the
# resolver, so each of those sites needs the assert of its own. `set
# default_branch` is the one that reaches git in the escaped clone.
check "dm-repo.sh set default_branch refuses an escaped clone" \
  '! b dm-repo.sh set escapee default_branch main >/dev/null 2>&1'
check "dm-repo.sh seed refuses an escaped clone"   '! b dm-repo.sh seed escapee >/dev/null 2>&1'
check "dm-repo.sh remove refuses an escaped clone" '! b dm-repo.sh remove escapee >/dev/null 2>&1'
ln -s "$RI_FOREIGN" "$DM_HOME/repos/slotescape"
check "dm-repo.sh add refuses a clone slot symlinked outside repos/" \
  '! b dm-repo.sh add slotescape "$TMP/origin.git" --no-memory >/dev/null 2>&1'
rm -f "$DM_HOME/repos/slotescape"
# A local copy whose clone was replaced underneath it: the refusal must be the
# dockmaster's, and teardown must stay possible without a refusal on its success
# path — a task whose clone escaped would otherwise pin at `working` forever.
ESC2_RC=0
ESC2OUT="$(b dm-merge.sh local esc-2 2>&1)" || ESC2_RC=$?
check "landing through a replaced clone refuses"    '[ "$ESC2_RC" -ne 0 ]'
check "and never leaks git's raw fatal"             '! grep -q "fatal: not a git repository" <<<"$ESC2OUT"'
check "the refusal is the dockmaster's own"         'grep -q "REFUSED" <<<"$ESC2OUT"'
check "unforced teardown of that task still refuses" '! b dm-worktree.sh remove esc-2 >/dev/null 2>&1'
ESC2_TD_RC=0
ESC2TD="$(b dm-worktree.sh remove esc-2 --force 2>&1)" || ESC2_TD_RC=$?
check "forced teardown of an escaped-clone task succeeds" '[ "$ESC2_TD_RC" -eq 0 ]'
check "no REFUSED is printed on that success path"        '! grep -q "REFUSED" <<<"$ESC2TD"'
check "it still says the head could not be preserved"     'grep -q "could not be preserved" <<<"$ESC2TD"'
check "it still names the containment reason"             'grep -q "OUTSIDE the managed clone root" <<<"$ESC2TD"'
check "the managed local copy is gone"                    '[ ! -e "$ESC2WT" ]'
check "the foreign repository is still untouched" \
  '[ "$(git -C "$RI_FOREIGN" rev-parse main)" = "$RI_FHEAD" ] && [ "$(git -C "$RI_FOREIGN" worktree list | wc -l)" -eq 1 ]'
rm -f "$DM_HOME/repos/escapee"

echo "== task records: an unregistered repo is refused at the record's birth (#124) =="
# ONE invocation, rc captured: a second `new` with the same id would refuse with
# "already exists" and hide a regression that accepted the first one.
RI_NEW_RC=0
RI_NEWOUT="$(b dm-task.sh new ri-unreg --kind ship --repo definitely-not-registered 2>&1)" || RI_NEW_RC=$?
check "new refuses an unregistered repo" '[ "$RI_NEW_RC" -ne 0 ]'
check "the refusal names the unregistered repo" \
  'grep -q "definitely-not-registered. is not registered" <<<"$RI_NEWOUT"'
check "the refusal names how to register it"    'grep -q "dm-repo.sh add" <<<"$RI_NEWOUT"'
check "no half-written task record is left behind" \
  '[ ! -e "$DM_HOME/state/tasks/ri-unreg.meta" ] && [ ! -e "$DM_HOME/state/tasks/ri-unreg.status" ]'
check "the reserved distro name is still accepted (it has no entry by design)" \
  'b dm-task.sh new ri-distro --kind ship --repo dockmaster >/dev/null 2>&1'

echo "== registry integrity: duplicate keys are corruption, not an empty fleet (#151) =="
# JSON lets an object repeat a key and a parser keeps just one. A second "repos"
# key therefore PARSED, passed the shape check, and read as an empty fleet while
# every real entry sat in the same file — the #112/#114 class, one level up.
RIDUP="$TMP/dup-registry"
mkdir -p "$RIDUP/state" "$RIDUP/repos"
printf '{"repos":{"keeper":{"remote":"none","path":"repos/keeper","default_branch":"main","mode":"local-only","merge_authority":"ask"}},"repos":{}}\n' > "$RIDUP/state/repos.json"
check "the duplicate-key fixture parses (so the shape check passes it)" \
  'jq -e . "$RIDUP/state/repos.json" >/dev/null 2>&1'
check "and a parser keeps only the empty copy" \
  '[ "$(jq -r ".repos | keys | length" "$RIDUP/state/repos.json")" = 0 ]'
DUPOUT="$(DM_HOME="$RIDUP" b dm-repo.sh list 2>&1 || true)"
check "a duplicate-key registry refuses instead of listing nothing" \
  '! DM_HOME="$RIDUP" b dm-repo.sh list >/dev/null 2>&1'
check "the refusal names duplicate keys"                       'grep -q "DUPLICATE KEYS" <<<"$DUPOUT"'
check "the refusal calls it corruption, not an empty registry" 'grep -q "CORRUPTION, not an empty registry" <<<"$DUPOUT"'
check "the refusal forbids deleting anything under repos/"     'grep -q "Do NOT delete anything under repos/" <<<"$DUPOUT"'
check "every registry consumer refuses it, not just list" \
  '! DM_HOME="$RIDUP" b dm-status.sh >/dev/null 2>&1 && ! DM_HOME="$RIDUP" b dm-sync.sh all >/dev/null 2>&1'
# The same corruption one level down: a repeated repo NAME inside .repos.
printf '{"repos":{"keeper":{"path":"repos/keeper"},"keeper":{"path":"repos/other"}}}\n' > "$RIDUP/state/repos.json"
check "a duplicated repo name is caught too" '! DM_HOME="$RIDUP" b dm-repo.sh list >/dev/null 2>&1'
# Guard the guard: the same shape WITHOUT a repeat must still be usable, or the
# check would just be refusing every registry.
printf '{"repos":{"keeper":{"path":"repos/keeper"},"other":{"path":"repos/other"}}}\n' > "$RIDUP/state/repos.json"
check "a healthy two-repo registry is not flagged" 'DM_HOME="$RIDUP" b dm-repo.sh list >/dev/null 2>&1'
printf '{"repos":{}}\n' > "$RIDUP/state/repos.json"
check "an empty registry is not flagged"           'DM_HOME="$RIDUP" b dm-repo.sh list >/dev/null 2>&1'

echo "== a task that concludes 'do not build it' has a terminal state (#103) =="
# Such a task had no reachable end: `state` derives done only from positive
# landing evidence, so it reconciled to `working` forever unless it was
# laundered into looking finished. `close` ends it and says why nothing landed.
b dm-task.sh new ri-nobuild --kind ship --repo demo --title "add the widget" >/dev/null
b dm-task.sh event ri-nobuild working "investigated the request" >/dev/null
check "before closing, the task is not terminal" \
  'DM_NO_FETCH=1 b dm-task.sh state ri-nobuild | grep -q "state: working"'
check "close requires a recorded reason" '! b dm-task.sh close ri-nobuild >/dev/null 2>&1'
b dm-worktree.sh create ri-nobuild demo >/dev/null
check "close refuses while a local copy is still present" \
  '! b dm-task.sh close ri-nobuild --reason "already provided upstream" >/dev/null 2>&1'
b dm-worktree.sh remove ri-nobuild >/dev/null || true
check "close ends the task once the local copy is gone" \
  'b dm-task.sh close ri-nobuild --reason "already provided upstream" >/dev/null 2>&1'
check "the reason is on the record" \
  'grep -q "closed without landing work: already provided upstream" "$DM_HOME/state/tasks/ri-nobuild.status"'
check "the closed task reconciles to a terminal state" \
  'DM_NO_FETCH=1 b dm-task.sh state ri-nobuild | grep -q "^state: discarded"'
check "closing never claims work landed" \
  '! grep -qE "^[^ ]+ merged: " "$DM_HOME/state/tasks/ri-nobuild.status"'
check "closing an already-terminal task is refused" \
  '! b dm-task.sh close ri-nobuild --reason "again" >/dev/null 2>&1'
check "a closed task can be archived"    'b dm-task.sh archive ri-nobuild >/dev/null 2>&1'
b dm-task.sh new ri-nobuild2 --kind ship --repo demo >/dev/null
check "the discarded verb stays barred from dm-task.sh event" \
  '! b dm-task.sh event ri-nobuild2 discarded "forged" >/dev/null 2>&1'
check "close refuses a task that does not exist" \
  '! b dm-task.sh close ri-no-such-task --reason "x" >/dev/null 2>&1'
# An interrupted cleanup leaves a RECORDED worktree whose directory is already
# gone. `dm-worktree.sh remove` refuses that without --force precisely because
# nothing remains to prove the work landed, so close must not be a softer second
# route to the same `discarded` state.
b dm-task.sh new ri-ghost --kind ship --repo demo >/dev/null
RIGHOST="$(b dm-worktree.sh create ri-ghost demo | tail -n1)"
rm -rf "$RIGHOST"
RIG_RC=0
RIGOUT="$(b dm-task.sh close ri-ghost --reason "not needed after all" 2>&1)" || RIG_RC=$?
check "close refuses a recorded local copy that is already absent" '[ "$RIG_RC" -ne 0 ]'
check "the refusal routes to the discard-authority path" \
  'grep -q "dm-worktree.sh remove ri-ghost --force" <<<"$RIGOUT"'
check "the refused close recorded no terminal state" \
  '! grep -q " discarded: " "$DM_HOME/state/tasks/ri-ghost.status"'
check "the discard-authority path is what reaches discarded" \
  'b dm-worktree.sh remove ri-ghost --force >/dev/null 2>&1 && grep -q " discarded: " "$DM_HOME/state/tasks/ri-ghost.status"'

# --- command guard: precision fixes, closed holes, and the armed hook --------
# Every fixed false positive is pinned in BOTH directions: the benign form is
# ALLOWED and the destructive form it resembles is still REFUSED. A change that
# only stops blocking things is a regression, not a fix.
echo "== command guard precision and wiring (#143/#144/#139/#138/#89) =="

# #143. Each body's first word reads like a wrapper, a runner, or an assignment,
# which is what used to fire re-entry and refuse the sentence.
check "guard permits ordinary PR prose that mentions git (#143)" \
  'all_allowed "gh pr create --body \"watch the git log for changes\"" \
     "gh pr create --body \"exec path handling in git changed\"" \
     "gh pr create --body \"parallel git fetch across repos\"" \
     "gh pr create --body \"time spent on git rebase was wasted\"" \
     "gh pr create --body \"script that wraps git push\"" \
     "gh pr create --body \"xargs with git ls-files is faster\"" \
     "gh pr create --body \"strace showed git stat calls\"" \
     "gh pr create --body \"flock around git index writes\"" \
     "gh pr create --body=\"watch the git log for changes\"" \
     "git commit -m \"env=prod git deploy notes\""'
# A body that STARTS with the word git is classified on its merits wherever it
# sits -- that is what keeps `entr -s "git reset --hard"` refused, and it is
# what the guard did before option values became data. So a permitted git
# command in prose passes and a destructive one does not.
check "a git-leading body is classified, not waved through (#143)" \
  'all_allowed "gh pr create --body \"git log shows the bug\"" \
     && all_blocked "gh pr create --title \"git push --force is now refused\""'
# The same words in COMMAND position, not option-value position, still refuse.
check "guard still refuses a real command behind the same words (#143)" \
  'all_blocked "parallel \"git push --force origin main\"" \
     "parallel \" git push --force\"" \
     "parallel \"timeout 5 git push --force\"" \
     "flock -c \"git push --force\"" \
     "./wrapper.sh \"git push --force\"" \
     "xargs git push --force" \
     "find . -exec git reset --hard {} +" \
     "gh pr create --body x; git push --force origin main"'

# #144. A blanket *.path refused submodule.<name>.path, which is a tree path.
check "guard permits benign submodule.<name>.path (#144)" \
  'all_allowed "git config submodule.lib.path" "git -c submodule.lib.path=vendor/lib status"'
check "guard still refuses every .path that names an executable (#144)" \
  'all_blocked "git config difftool.x.path /bin/sh" "git config mergetool.x.path /bin/sh" \
     "git config browser.x.path /bin/sh" "git config man.x.path /bin/sh" \
     "git -c include.path=/tmp/evil status"'

# #139. GIT_TRACE=<path> was an unguarded file append through an allowed command.
check "guard permits the GIT_TRACE stderr debugging idiom (#139)" \
  'all_allowed "GIT_TRACE=1 git status" "GIT_TRACE_PACKET=true git fetch origin" "GIT_TRACE2=2 git log"'
check "guard refuses a GIT_TRACE destination that is a file (#139)" \
  'all_blocked "GIT_TRACE=/tmp/pwn git status" "GIT_TRACE2_EVENT=/tmp/pwn git status" \
     "GIT_TRACE_PERFORMANCE=/tmp/pwn git log" "GIT_TRACE=\$DEST git status" \
     "git -c trace2.eventTarget=/tmp/pwn status" "git config trace2.perfTarget /tmp/pwn"'

# #138. Substitution content was classified as the executable and in process
# substitution, but NOT in argument position, where it still ran.
check "guard classifies substitution content in argument position (#138)" \
  'all_blocked "echo \$(git push --force origin main)" \
     "git log --oneline \$(git reset --hard HEAD~5)" \
     "X=\$(git push --mirror origin)" \
     "echo \`git push --force origin main\`" \
     "echo \"\$(git push --force origin main)\"" \
     "echo \"\`git reset --hard\`\""'
check "guard leaves inert and harmless substitutions alone (#138)" \
  "all_allowed 'git commit -m \"\$(cat msg.txt)\"' 'echo \"\$(git log --oneline)\"' \
     'echo '\''\$(git push --force)'\'''"

# #89. Restoring a drifted tracked file is ordinary crew work; discarding the
# whole worktree with the same subcommand is the thing the guard exists to stop.
check "guard permits a path-scoped file restore (#89)" \
  'all_allowed "git restore package-lock.json" "git restore src/a.py src/b.py" \
     "git restore -- package-lock.json" "git restore --staged --worktree package-lock.json" \
     "git restore -s HEAD~1 package-lock.json" \
     "git checkout -- package-lock.json" "git checkout HEAD -- package-lock.json"'
check "guard still refuses an unscoped restore or a checkout that moves HEAD (#89)" \
  'all_blocked "git restore ." "git restore" "git restore :/" "git restore \"*.json\"" \
     "git restore --pathspec-from-file=list" "git restore \$FILE" \
     "git checkout ." "git checkout -- ." "git checkout feature" "git checkout -b feature" \
     "git checkout -f main" "git checkout main -b other -- file" "git checkout HEAD~5 --"'

# --- #160 review: four HIGH regressions, each pinned in both directions -------
# A quoted command reached through an ARGUMENT of an unmodelled executable: the
# shell is find's argument, not the segment's executable, so check_nested_shell
# never fires and the payload sat in option-value position.
check "guard refuses a command smuggled through argument position (#160)" \
  'all_blocked "find . -exec sh -c \"git push --force origin main\" \\;" \
     "find . -execdir bash -c \"git reset --hard\" \\;" \
     "find repos -name .git -execdir sh -c \"git reset --hard\" \\;" \
     "docker run img sh -c \"git push --force\"" \
     "entr -s \"git reset --hard\"" "rsync -e \"git push --force\""'
# Payloads that do NOT begin with `git`, so only the shell-token rule catches
# them -- without these the rule is masked by the git-leading one and a mutation
# to it passes the suite.
check "a shell token in argv classifies a payload whatever it starts with (#160)" \
  'all_blocked "find . -exec sh -c \"cd /tmp && git clean -fdx\" \\;" \
     "find . -exec sh -c \"timeout 5 git push --force\" \\;" \
     "docker run img bash -c \"env git reset --hard\""'
check "that rule does not refuse an innocent command handed to a shell (#160)" \
  'all_allowed "find . -exec sh -c \"echo hello world\" \\;" \
     "docker run img sh -c \"npm ci && npm test\"" \
     "xargs -I{} echo \"the git log\"" "parallel \"some words about git here\""'
check "the smuggle fix does not re-refuse ordinary PR prose (#160)" \
  'all_allowed "gh pr create --body \"watch the git log for changes\"" \
     "gh pr create --body \"xargs with git ls-files is faster\"" \
     "gh pr create --body \"strace showed git stat calls\"" \
     "find . -name \"*.py\" -print"'

# Naming `.` and `..` was not enough. Each of these discards the whole worktree
# from one directory down, and every one of them passed.
check "guard refuses every unscoped pathspec spelling (#160)" \
  'all_blocked "git restore ../.." "git restore ./." "git restore .//" \
     "git restore /abs/path" "git restore {.,x}" "git restore src/../.." \
     "git restore a/./.." "git checkout -- ../.." "git checkout -- ./."'
check "the pathspec fix keeps a real file restore working (#160)" \
  'all_allowed "git restore package-lock.json" "git restore src/app.py" \
     "git restore a/b/c.txt" "git checkout -- src/app.py"'

# The lexer models no shell grammar, so a keyword became the "executable" and
# the following git a stray bare token. Ordinary compound shell was refused.
check "guard permits ordinary compound shell (#160)" \
  'all_allowed "if git diff --quiet; then echo clean; fi" \
     "for r in a b; do git -C \"\$r\" status; done" \
     "while ! git fetch origin; do sleep 1; done" \
     "until git status; do sleep 1; done" \
     "! git diff --quiet && echo dirty" "time git status" "type git" \
     "{ git status; git log; }"'
check "a keyword does not hide a destructive command (#160)" \
  'all_blocked "if git push --force origin main; then echo ok; fi" \
     "for r in a b; do git -C \"\$r\" reset --hard; done" \
     "while git clean -fd; do :; done" "! git reset --hard" \
     "time git push --force origin main" "{ git reset --hard; }"'

# A heredoc body is stdin DATA. Re-lexed as commands, any line holding a bare
# git refused -- which is how a PR body is normally assembled.
HEREDOC_BODY="$(printf 'gh pr create --body "$(cat <<%sEOF%s\nFixes the thing.\ngit push --force is refused now.\nEOF\n)"' "'" "'")"
HEREDOC_PLAIN="$(printf 'cat <<EOF\ngit reset --hard\nEOF\n')"
HEREDOC_DASH="$(printf 'cat <<-EOF\n\tgit clean -fd\n\tEOF\n')"
HEREDOC_SHELL="$(printf 'bash <<EOF\ngit reset --hard\nEOF\n')"
# `<<<` is a HERESTRING. Read as a heredoc operator its delimiter would be `<`,
# which never appears, so every later line would be swallowed unclassified --
# the skip must not become a way to hide the next command.
HERESTRING_THEN_CMD="$(printf 'grep -q x <<< "$s"\ngit reset --hard\n')"
check "guard permits a heredoc body and a heredoc PR body (#160)" \
  'all_allowed "$HEREDOC_BODY" "$HEREDOC_PLAIN" "$HEREDOC_DASH"'
check "a heredoc fed to a SHELL is still refused (#160)" \
  'all_blocked "$HEREDOC_SHELL" "bash <<< \"git clean -fd\""'
check "a herestring does not swallow the commands after it (#160)" \
  'all_blocked "$HERESTRING_THEN_CMD"'
# The body skip must stop at the delimiter, not run to end of input.
HEREDOC_THEN_CMD="$(printf 'cat <<EOF\nharmless text\nEOF\ngit reset --hard\n')"
check "the heredoc skip stops at its delimiter (#160)" \
  'all_blocked "$HEREDOC_THEN_CMD"'
check "guard counts substitution parens quote-aware (#160)" \
  'all_allowed "echo \"\$(grep \\\"(\\\" file)\"" "gh pr create --body \"the fix works :) ship it\""'

# A hook that times out FAILS OPEN (measured, see SECURITY.md), so the parser
# must never be the slow thing. 32KB is the size that showed it: 23s with the
# quadratic reader, 2s with the sliding window. The bound is deliberately an
# order of magnitude above the linear time and well below the quadratic one, so
# a loaded CI runner cannot flip it either way.
GUARD_BIG="$(awk 'BEGIN{ s="gh pr create --body \""; for(i=0;i<8000;i++) s = s "a b "; print s "\"" }')"
GUARD_START="$(date +%s)"
b dm-command-guard.sh check "$GUARD_BIG" >/dev/null 2>&1 || true
GUARD_ELAPSED=$(( $(date +%s) - GUARD_START ))
check "the lexer stays linear on a 32KB command (#160)" \
  '[ "$GUARD_ELAPSED" -le 15 ]'
# Over the cap the guard REFUSES rather than parsing on: a guard that runs long
# is a guard that silently is not there.
GUARD_OVER="$(awk 'BEGIN{ s="echo "; for(i=0;i<70000;i++) s = s "a"; print s }')"
check "an oversized command is refused, not parsed until the timeout (#160)" \
  '! b dm-command-guard.sh check "$GUARD_OVER" >/dev/null 2>&1'
# Captured, not piped: `set -o pipefail` makes the pipeline carry the guard's
# exit 2 rather than grep's verdict.
GUARD_OVER_MSG="$(b dm-command-guard.sh check "$GUARD_OVER" 2>&1 || true)"
check "the refusal names the size limit rather than a git verdict" \
  'grep -q "byte limit" <<<"$GUARD_OVER_MSG"'
# Arming is #89 and is NOT done here: the guard must stay dormant until the
# fail-open behavior above is answered for.
check "no settings.json installs the guard as a hook yet (#89 stays open)" \
  '! jq -e ".hooks" "$ROOT/.claude/settings.json" >/dev/null 2>&1'
echo "== dispatch right-sizing: the effort set is closed, and each level has an agent (#166) =="
w6valid() { ( . "$ROOT/bin/dm-lib.sh"; dm_effort_is_valid "$@" ); }
check "the four levels are valid"    '( for w6l in low medium high xhigh; do w6valid "$w6l" || exit 1; done )'
check "max is refused on purpose"    '! w6valid max'
check "an empty effort is refused"   '! w6valid ""'
check "a junk effort is refused"     '! w6valid nonsense && ! w6valid LOW'
# The set must be CLOSED. A substring test against the space-joined list
# accepted any adjacent run — "low medium" stored a level with no crew-*.md
# behind it, defeating the forward drift guard through the ordinary CLI.
check "an adjacent run of levels is refused" \
  '! w6valid "low medium" && ! w6valid "medium high" && ! w6valid "high xhigh" && ! w6valid "low medium high xhigh"'
check "surrounding whitespace is refused"  '! w6valid " low" && ! w6valid "low "'
check "the CLI refuses a multi-level value and stores nothing" \
  'b dm-task.sh new w6closed --kind ship --repo demo >/dev/null 2>&1
   ! b dm-task.sh set w6closed effort "low medium" >/dev/null 2>&1 && [ -z "$(b dm-task.sh get w6closed effort)" ]'
# The drift guard that matters: an effort level the gate ACCEPTS but that names
# no agent definition on disk is a dispatch that cannot be spawned.
# `name:` is the DISPATCH KEY, not the filename: the loader reads agentType from
# frontmatter and drops a file with no `name:` entirely, so a misspelled or
# missing name resolves to nothing at runtime while every filename check passes.
check "every accepted level has a crew-<level> agent definition" \
  '( . "$ROOT/bin/dm-lib.sh"; for w6l in $DM_EFFORT_LEVELS; do
       [ -f "$ROOT/.claude/agents/crew-$w6l.md" ] || exit 1
       grep -qx "name: crew-$w6l" "$ROOT/.claude/agents/crew-$w6l.md" || exit 1
       grep -qx "effort: $w6l" "$ROOT/.claude/agents/crew-$w6l.md" || exit 1; done )'
check "there is exactly one crew definition per accepted level (guard the guard)" \
  '( . "$ROOT/bin/dm-lib.sh"
     w6n=0; for w6l in $DM_EFFORT_LEVELS; do w6n=$((w6n + 1)); done
     [ "$(ls "$ROOT"/.claude/agents/crew-*.md | wc -l)" -eq "$w6n" ] )'
# Every level pins a DEFAULT model (#177), so an omitted `model` parameter lands
# on a considered tier instead of inheriting the session's most expensive one.
# The pin must not couple the dials: the spawn parameter still overrides it, and
# each file has to say so, or the next reader reads a pin as a coupling.
check "every crew-<level> pins its default model" \
  '( . "$ROOT/bin/dm-lib.sh"
     for w6l in $DM_EFFORT_LEVELS; do
       grep -qx "model: .\+" "$ROOT/.claude/agents/crew-$w6l.md" || exit 1
     done )'
# `&&`-joined, not newline-separated: `check` evals its body, and a body of four
# separate commands reports only the LAST one's status — the medium and high
# rows were unguarded, and a deleted crew-*.md still passed.
check "the pinned defaults are the baseline table" \
  'grep -qx "model: haiku"  "$ROOT/.claude/agents/crew-low.md" &&
   grep -qx "model: sonnet" "$ROOT/.claude/agents/crew-medium.md" &&
   grep -qx "model: opus"   "$ROOT/.claude/agents/crew-high.md" &&
   grep -qx "model: opus"   "$ROOT/.claude/agents/crew-xhigh.md"'
check "the cheap level is reachable by omission alone" 'grep -qx "model: haiku" "$ROOT/.claude/agents/crew-low.md"'
check "every definition states the parameter still overrides" \
  '( for w6f in "$ROOT"/.claude/agents/crew-*.md; do
       grep -q "parameter overrides" "$w6f" || exit 1
     done )'
# The paths are asserted first: grep exits 2 on a missing operand, and `!` reads
# that as "claim absent", so renaming any one of them would have retired this
# guard while it kept reporting a pass.
W6CLAIMPATHS="$ROOT/bin $ROOT/.claude $ROOT/.dm-knowledge $ROOT/AGENTS.md $ROOT/docs $ROOT/README.md"
check "no distro text still claims nothing pins a model" \
  '( for w6p in $W6CLAIMPATHS; do [ -e "$w6p" ] || exit 1; done
     ! grep -rqE "[Nn]o ([^ ]+ )?definition pins a model" $W6CLAIMPATHS )'
# The drift guard runs BOTH ways. Forward (above): every level the gate accepts
# has a file whose `name:` and `effort:` both match. Reverse (here): every file
# DECLARES a name the gate accepts and matching its own basename — so a stray
# crew-<junk>.md, and a file whose dispatch key has drifted from its filename,
# are both caught.
check "every crew-*.md declares a name matching its basename and an accepted level" \
  '( . "$ROOT/bin/dm-lib.sh"
     for w6f in "$ROOT"/.claude/agents/crew-*.md; do
       w6b="${w6f##*/}"; w6b="${w6b%.md}"
       grep -qx "name: $w6b" "$w6f" || exit 1
       dm_effort_is_valid "${w6b#crew-}" || exit 1
     done )'
check "no crew agent exists for the excluded max tier" '[ ! -f "$ROOT/.claude/agents/crew-max.md" ]'

echo "== dispatch gate: set agent_id refuses until BOTH dials are chosen (#166) =="
b dm-task.sh new w6gate-1 --kind ship --repo demo --title "add a widget" >/dev/null
b dm-worktree.sh create w6gate-1 demo >/dev/null
b dm-brief.sh w6gate-1 >/dev/null
W6GBR="$DM_HOME/data/w6gate-1/brief.md"
sed 's/{TASK}/Add a widget./' "$W6GBR" > "$TMP/w6g-filled" && mv "$TMP/w6g-filled" "$W6GBR"
W6NOMODEL="$(b dm-task.sh set w6gate-1 agent_id agent-1 2>&1 || true)"
check "a filled brief alone does not admit a dispatch" '! b dm-task.sh set w6gate-1 agent_id agent-1 >/dev/null 2>&1'
check "the refusal names the missing model"            'grep -q "no model recorded" <<<"$W6NOMODEL"'
b dm-task.sh set w6gate-1 model haiku >/dev/null
W6NOEFF="$(b dm-task.sh set w6gate-1 agent_id agent-1 2>&1 || true)"
check "a model alone does not admit a dispatch"        '! b dm-task.sh set w6gate-1 agent_id agent-1 >/dev/null 2>&1'
check "the refusal names the missing effort"           'grep -q "no reasoning effort recorded" <<<"$W6NOEFF"'
# An invalid level is refused at the point of RECORDING, not silently stored.
W6BADEFF="$(b dm-task.sh set w6gate-1 effort max 2>&1 || true)"
check "an invalid effort is refused, not stored"       '! b dm-task.sh set w6gate-1 effort max >/dev/null 2>&1 && [ -z "$(b dm-task.sh get w6gate-1 effort)" ]'
check "the refusal names the valid set"                'grep -q "low medium high xhigh" <<<"$W6BADEFF"'
b dm-task.sh set w6gate-1 effort xhigh >/dev/null
check "both dials chosen admits the dispatch"          'b dm-task.sh set w6gate-1 agent_id agent-1 >/dev/null 2>&1'
# The gate forces a CHOICE, never a particular value: haiku+xhigh is an
# unusual pairing and overriding both is ordinary — judgment, not a formula.
check "the recorded choice is whatever was actually chosen" \
  '[ "$(b dm-task.sh get w6gate-1 model)" = haiku ] && [ "$(b dm-task.sh get w6gate-1 effort)" = xhigh ]'

echo "== dispatch tier: the distribution is inspectable without a script (#177) =="
b dm-task.sh new w7size --kind ship --repo demo --title "measure me" >/dev/null
W7SIZING="$(b dm-task.sh sizing)"
check "sizing counts the models actually dispatched" 'grep -qE "^model[[:space:]]+haiku[[:space:]]+[0-9]+" <<<"$W7SIZING"'
check "sizing counts the efforts actually dispatched" 'grep -qE "^effort[[:space:]]+xhigh[[:space:]]+[0-9]+" <<<"$W7SIZING"'
check "sizing counts the unsized dispatches"         'grep -qE "^unsized[[:space:]]+no model or no effort[[:space:]]+[0-9]+" <<<"$W7SIZING"'
check "sizing totals every task record"              'grep -qE "^total[[:space:]]+task records[[:space:]]+[0-9]+" <<<"$W7SIZING"'
# The unsized count must be REAL: w7size records neither dial, so it is in it.
check "a task with neither dial is counted unsized" \
  '[ "$(grep -E "^unsized" <<<"$W7SIZING" | awk "{print \$NF}")" -ge 1 ]'
check "sizing on an empty home says so rather than printing nothing" \
  '[ "$(DM_HOME="$TMP/sizing-empty" b dm-task.sh sizing)" = "(no tasks)" ]'

echo "== dispatch tier: the record is cross-checked against what actually ran (#177) =="
# `set agent_id` is a RECORD gate: it forces the choice to be written down and
# cannot verify the spawn. The transcript is the independent second source, so a
# record that LIES about what ran is catchable. Unreadable stays unproven.
w7sized() {   # <id> <model> <effort> <agent-id> -- a fully recorded dispatch
  b dm-task.sh new "$1" --kind ship --repo demo --title "sized dispatch" >/dev/null
  b dm-worktree.sh create "$1" demo >/dev/null
  b dm-brief.sh "$1" >/dev/null
  sed 's/{TASK}/Do the thing./' "$DM_HOME/data/$1/brief.md" > "$TMP/w7brief" \
    && mv "$TMP/w7brief" "$DM_HOME/data/$1/brief.md"
  b dm-task.sh set "$1" model "$2" >/dev/null
  b dm-task.sh set "$1" effort "$3" >/dev/null
  b dm-task.sh set "$1" agent_id "$4" >/dev/null
}
W7TX="$TMP/transcripts"; mkdir -p "$W7TX"
w7sized w7tx-ok    opus   high   agent-tx-ok
w7sized w7tx-bad   sonnet medium agent-tx-bad
w7sized w7tx-gone  haiku  low    agent-tx-gone
w7sized w7tx-blank opus   high   agent-tx-blank
# The record holds a tier alias; the runtime reports a full model id.
printf '{"type":"assistant","message":{"model":"claude-opus-5"}}\n' > "$W7TX/agent-tx-ok.output"
printf '{"type":"assistant","message":{"model":"claude-opus-5"}}\n' > "$W7TX/agent-tx-bad.output"
printf '{"type":"user","message":{"role":"user"}}\n'                > "$W7TX/agent-tx-blank.output"
# agent-tx-gone deliberately has NO transcript file.
W7TXOUT="$(b dm-task.sh sizing --transcripts "$W7TX" 2>"$TMP/w7tx.err" || true)"
check "an alias record matching a full model id counts as verified" \
  'grep -qE "^verified[[:space:]]+ran as recorded[[:space:]]+1$" <<<"$W7TXOUT"'
check "a contradicted record is a MISMATCH, not a pass" \
  'grep -qE "^verified[[:space:]]+MISMATCH[[:space:]]+1$" <<<"$W7TXOUT"'
# A missing file and a transcript with no model field must land in the SAME
# unproven bucket — neither may be counted as verified.
check "a missing or model-less transcript is unproven, never verified" \
  '[ "$(grep -E "^verified[[:space:]]+no transcript found" <<<"$W7TXOUT" | awk "{print \$NF}")" -ge 2 ]'
check "the mismatch names the task, the record and what ran" \
  'grep -q "w7tx-bad" "$TMP/w7tx.err" && grep -q "recorded model=sonnet" "$TMP/w7tx.err" && grep -q "claude-opus-5" "$TMP/w7tx.err"'
check "a mismatch exits non-zero rather than reporting a clean sweep" \
  '! b dm-task.sh sizing --transcripts "$W7TX" >/dev/null 2>&1'
check "the plain distribution still exits 0 with the same mismatch present" \
  'b dm-task.sh sizing >/dev/null 2>&1'
check "the cross-check rows appear only when transcripts are supplied" \
  '! b dm-task.sh sizing | grep -q "^verified"'
# Failure contract on the flag itself.
check "a transcript directory that does not exist is refused" \
  '! b dm-task.sh sizing --transcripts "$TMP/no-such-transcripts" >/dev/null 2>&1'
check "--transcripts with no value is refused"  '! b dm-task.sh sizing --transcripts >/dev/null 2>&1'
check "an unknown sizing flag is refused"       '! b dm-task.sh sizing --nonsense >/dev/null 2>&1'
# The matcher itself: containment against a full id, and no cross-tier match.
w7match() { ( . "$ROOT/bin/dm-lib.sh"; dm_dispatch_model_matches "$@" ); }
check "each tier alias matches only its own model id" \
  'w7match opus claude-opus-5 && w7match sonnet claude-sonnet-5 && w7match haiku claude-haiku-4-5-20251001 \
   && ! w7match opus claude-sonnet-5 && ! w7match haiku claude-opus-5 && ! w7match sonnet claude-haiku-4-5-20251001'
check "an empty side never matches"             '! w7match "" claude-opus-5 && ! w7match opus ""'
w7tm() { ( . "$ROOT/bin/dm-lib.sh"; dm_transcript_model "$@" ); }
check "an absent transcript file is refused, printing nothing" \
  '! w7tm "$W7TX/no-such-agent.output" && [ -z "$(w7tm "$W7TX/no-such-agent.output" 2>/dev/null)" ]'
check "a transcript with no model field is refused" '! w7tm "$W7TX/agent-tx-blank.output"'
check "a real transcript line yields the model id"  '[ "$(w7tm "$W7TX/agent-tx-ok.output")" = claude-opus-5 ]'

# shard:split
echo "== brief: sizing is the dockmaster's call, not a computed anchor (#166, reverted) =="
b dm-task.sh new w6eff-1 --kind ship --repo demo --title "add a multiply endpoint" >/dev/null
b dm-worktree.sh create w6eff-1 demo >/dev/null
b dm-brief.sh w6eff-1 >/dev/null
W6BR="$DM_HOME/data/w6eff-1/brief.md"
check "brief notes sizing is the dockmaster's call, with no computed value" \
  'grep -q "Sized by the dockmaster" "$W6BR" && ! grep -qE "Model tier: |Reasoning effort: " "$W6BR"'
check "brief records no model or effort until chosen"   '[ -z "$(b dm-task.sh get w6eff-1 model)" ] && [ -z "$(b dm-task.sh get w6eff-1 effort)" ]'
check "no meta field for a computed recommendation exists" \
  '[ -z "$(b dm-task.sh get w6eff-1 model_recommended)" ] && [ -z "$(b dm-task.sh get w6eff-1 effort_recommended)" ]'
# The honesty requirement: effort IS applied at spawn, so the old
# "not enforceable" disclaimer must not survive anywhere in the distro.
check "brief no longer claims effort is unenforceable" \
  '! grep -qiE "NOT ENFORCEABLE AT SPAWN|no effort parameter" "$W6BR"'
# The scan MUST cover .dm-knowledge: AGENTS.md names those notes as the
# authority a future editor opens before touching this code, and the first
# version of this guard missed the one stale claim that survived there.
check "no distro text claims effort is unenforceable" \
  '! grep -rqiE "NOT ENFORCEABLE AT SPAWN|has no effort parameter|effort is not a spawn parameter" "$ROOT/bin" "$ROOT/.claude/skills" "$ROOT/.dm-knowledge" "$ROOT/config/README.md" "$ROOT/docs" "$ROOT/AGENTS.md"'
check "no distro text still calls right-sizing advisory-only" \
  '! grep -rqiE "right-sizing is ADVISORY|never blocks dispatch" "$ROOT/bin" "$ROOT/.claude/skills" "$ROOT/.dm-knowledge" "$ROOT/config/README.md" "$ROOT/docs" "$ROOT/AGENTS.md"'
check "the lifecycle note documents the gate and both dials" \
  'grep -q "crew-<level>" "$ROOT/.dm-knowledge/lifecycle.md" && grep -q "RECORD gate, not a SPAWN gate" "$ROOT/.dm-knowledge/lifecycle.md"'
check "the task section carries the recorded title" 'grep -q "Recorded title: add a multiply endpoint" "$W6BR"'
b dm-task.sh event w6eff-1 working "started" >/dev/null
W6STATUS="$(b dm-status.sh 2>&1 || true)"   # capture once (grep -q + pipefail)
check "status flags the unsized dispatch with no computed anchor to name" \
  'grep -q "UNSIZED.*w6eff-1.*model and effort recorded" <<<"$W6STATUS"'

echo "== brief: an unfilled {TASK} placeholder is refused before dispatch (#115) =="
W6UNFILLED="$(b dm-brief.sh check w6eff-1 2>&1 || true)"
check "check refuses a brief whose task section is still the placeholder" \
  '! b dm-brief.sh check w6eff-1 >/dev/null 2>&1'
check "the refusal names the placeholder"    'grep -q "{TASK}" <<<"$W6UNFILLED"'
check "check refuses a task with no brief"   '! b dm-brief.sh check w6-no-such-brief >/dev/null 2>&1'
sed 's/{TASK}/Add a multiply endpoint to src\/calc.py, with a test./' "$W6BR" > "$TMP/w6-filled" && mv "$TMP/w6-filled" "$W6BR"
check "check passes once the placeholder is filled" 'b dm-brief.sh check w6eff-1 >/dev/null 2>&1'
# The subcommand must not shadow a task that is literally named `check`.
b dm-task.sh new check --kind ship --repo demo --title "task named check" >/dev/null
b dm-worktree.sh create check demo >/dev/null
check "a task literally named 'check' still generates" \
  'b dm-brief.sh check >/dev/null 2>&1 && [ -f "$DM_HOME/data/check/brief.md" ]'

# The guard has to FIRE, not just exist. Recording the runtime owner is the
# dispatch record (task-lifecycle and fleet-change both spawn, then persist it),
# so that is where an unfilled brief is refused.
b dm-task.sh new w6disp --kind ship --repo demo --title "add a widget" >/dev/null
b dm-worktree.sh create w6disp demo >/dev/null
b dm-brief.sh w6disp >/dev/null
W6DISPREFUSE="$(b dm-task.sh set w6disp agent_id agent-123 2>&1 || true)"
check "recording a dispatch against an unfilled brief is refused" \
  '! b dm-task.sh set w6disp agent_id agent-123 >/dev/null 2>&1'
check "the refusal names the placeholder and the check command" \
  'grep -q "{TASK}" <<<"$W6DISPREFUSE" && grep -q "dm-brief.sh check w6disp" <<<"$W6DISPREFUSE"'
check "the refused dispatch recorded no owner" '[ -z "$(b dm-task.sh get w6disp agent_id)" ]'
# dm-status catches a dispatch that never recorded an owner at all.
b dm-task.sh event w6disp working "started" >/dev/null
W6DISPSTATUS="$(b dm-status.sh 2>&1 || true)"
check "status flags a live task on an unfilled brief as UNFILLED" \
  'grep -q "UNFILLED.*w6disp" <<<"$W6DISPSTATUS"'
sed 's/{TASK}/Add a widget to src\/calc.py./' "$DM_HOME/data/w6disp/brief.md" > "$TMP/w6-disp-filled"
mv "$TMP/w6-disp-filled" "$DM_HOME/data/w6disp/brief.md"
b dm-task.sh set w6disp model sonnet >/dev/null; b dm-task.sh set w6disp effort medium >/dev/null
check "the dispatch records once the brief is filled and both dials are chosen" \
  'b dm-task.sh set w6disp agent_id agent-123 >/dev/null 2>&1 && [ "$(b dm-task.sh get w6disp agent_id)" = agent-123 ]'
check "a filled brief clears the UNFILLED flag" \
  '! grep -q "UNFILLED.*w6disp" <<<"$(b dm-status.sh 2>&1 || true)"'
# All three sites agree on all three reasons. A MISSING brief refuses too: a
# recorded dispatch with no brief is the same "crewmate with no task" #115
# exists to prevent, reached by another route.
b dm-task.sh new w6nobrief --kind ship --repo demo >/dev/null
W6NOBRIEF="$(b dm-task.sh set w6nobrief agent_id agent-456 2>&1 || true)"
check "a task with no brief is refused a dispatch record" \
  '! b dm-task.sh set w6nobrief agent_id agent-456 >/dev/null 2>&1'
check "that refusal says GENERATE, not edit in place" \
  'grep -q "dm-brief.sh w6nobrief" <<<"$W6NOBRIEF" && ! grep -q "do NOT regenerate" <<<"$W6NOBRIEF"'
check "dm-brief.sh check agrees a missing brief is not ready" \
  '! b dm-brief.sh check w6nobrief >/dev/null 2>&1'
# The skills that dispatch must name the check, or the code guard is the only
# thing standing between an empty brief and a spawned crewmate.
check "task-lifecycle names the pre-dispatch check" \
  'grep -q "dm-brief.sh check <id>" "$ROOT/.claude/skills/task-lifecycle/SKILL.md"'
check "fleet-change names it for a child too" \
  'grep -q "dm-brief.sh check <child-id>" "$ROOT/.claude/skills/fleet-change/SKILL.md"'

# The predicate is the bare {TASK} LINE, never any mention of the token. A brief
# correctly filled with text that CONTAINS "{TASK}" — issue #115's own text does
# — is filled. Refusing it would strand an already-spawned crewmate: fleet-change
# spawns first and records second, and stops the returned id when the record
# fails, so a false refusal here terminates correct work.
b dm-task.sh new w6mention --kind ship --repo demo --title "make the {TASK} guard real" >/dev/null
b dm-worktree.sh create w6mention demo >/dev/null
b dm-brief.sh w6mention >/dev/null
W6MENTBR="$DM_HOME/data/w6mention/brief.md"
cat > "$TMP/w6-mention-fill" <<'W6FILL'
Nothing verifies a dispatched brief had its {TASK} placeholder filled.
`dm-brief.sh <id>` exits 0 with a literal {TASK} in the body. Prose about
${TASK} and a fenced block are fine too:

    grep -n '{TASK}' data/gq-1/brief.md
W6FILL
awk 'BEGIN{while((getline l < ARGV[2])>0) fill=fill l "\n"; ARGC=2}
     $0 ~ /^[[:space:]]*\{TASK\}[[:space:]]*$/ { printf "%s", fill; next } { print }' \
  "$W6MENTBR" "$TMP/w6-mention-fill" > "$TMP/w6-mention-out"
mv "$TMP/w6-mention-out" "$W6MENTBR"
check "the fill really did embed the literal token (guard the guard)" \
  '[ "$(grep -c "{TASK}" "$W6MENTBR")" -ge 2 ]'
check "no bare {TASK} line survives the fill (guard the guard)" \
  '! grep -qx "[[:space:]]*{TASK}[[:space:]]*" "$W6MENTBR"'
check "a filled brief that MENTIONS {TASK} passes the check" \
  'b dm-brief.sh check w6mention >/dev/null 2>&1'
b dm-task.sh set w6mention model sonnet >/dev/null; b dm-task.sh set w6mention effort medium >/dev/null
check "and its dispatch records" \
  'b dm-task.sh set w6mention agent_id agent-789 >/dev/null 2>&1 && [ "$(b dm-task.sh get w6mention agent_id)" = agent-789 ]'
check "a title holding the token does not bake a second permanent refusal" \
  'grep -q "Recorded title: make the {TASK} guard real" "$W6MENTBR"'
b dm-task.sh event w6mention working "started" >/dev/null
check "status does not flag it as UNFILLED" \
  '! grep -q "UNFILLED.*w6mention" <<<"$(b dm-status.sh 2>&1 || true)"'
# An empty brief is not dispatch-ready either: the file is written
# truncate-then-write, so a death mid-write leaves exactly this.
b dm-task.sh new w6empty --kind ship --repo demo >/dev/null
b dm-worktree.sh create w6empty demo >/dev/null
b dm-brief.sh w6empty >/dev/null
: > "$DM_HOME/data/w6empty/brief.md"
check "an empty brief fails the check rather than passing it" \
  '! b dm-brief.sh check w6empty >/dev/null 2>&1'
check "an empty brief blocks the dispatch record" \
  '! b dm-task.sh set w6empty agent_id agent-000 >/dev/null 2>&1'
# Recovery advice is per-arm, because it INVERTS between them. An empty brief has
# nothing to preserve and regeneration is the only fix; a partly-filled one would
# be destroyed by it (dm-brief.sh <id> rewrites unconditionally).
W6EMPTYMSG="$(b dm-task.sh set w6empty agent_id agent-000 2>&1 || true)"
check "the empty-brief refusal says REGENERATE" \
  'grep -q "Regenerate it (dm-brief.sh w6empty)" <<<"$W6EMPTYMSG"'
check "and does not tell you to edit a file with no lines" \
  '! grep -q "EDIT that file in place" <<<"$W6EMPTYMSG" && ! grep -q "do NOT regenerate" <<<"$W6EMPTYMSG"'
W6EMPTYCHK="$(b dm-brief.sh check w6empty 2>&1 || true)"
check "dm-brief.sh check gives the same empty-arm advice" \
  'grep -q "Regenerate it: dm-brief.sh w6empty" <<<"$W6EMPTYCHK" && ! grep -q "still has its bare" <<<"$W6EMPTYCHK"'
# The unreplaced-placeholder arm is where "do not regenerate" belongs; w6disp
# still holds its scaffold placeholder.
check "the placeholder refusal says edit in place, not regenerate" \
  'grep -q "EDIT that file in place" <<<"$W6DISPREFUSE" && grep -q "would overwrite what is already written" <<<"$W6DISPREFUSE"'
check "and does not tell you to regenerate over a partial fill" \
  '! grep -q "Regenerate it" <<<"$W6DISPREFUSE"'

echo "== dispatch docs: the skill teaches both dials and the mandatory gate (#166) =="
W6TLSKILL="$ROOT/.claude/skills/task-lifecycle/SKILL.md"
check "the skill states the combined ladder, not a computed recommendation" \
  'grep -q "sonnet·low" "$W6TLSKILL" && ! grep -qE "model_recommended|effort_recommended" "$W6TLSKILL"'
check "the skill names the crew-<level> subagent types" \
  'grep -q "crew-low" "$W6TLSKILL" && grep -q "crew-xhigh" "$W6TLSKILL"'
check "the skill says choosing both dials is mandatory" \
  'grep -q "REFUSES until the task" "$W6TLSKILL"'
check "the skill states the model default is a pin, not a coupling" \
  'grep -q "parameter still overrides" "$W6TLSKILL"'
# Anchored on a phrase that lives on ONE line: grep is line-based, and the
# earlier "haiku.*silently ignored" spanned a wrap, so it could never match and
# the check collapsed to "the word `ignored` appears somewhere".
check "the skill warns that haiku ignores effort" \
  'grep -q "ignores effort" "$W6TLSKILL"'
check "the skill does not overclaim per-model effort support" \
  'grep -q "support is per-build" "$W6TLSKILL"'

echo "== DM_HOME override: a relocated state root still points at real scripts (#116) =="
# DM_HOME relocates STATE. The scripts stay where they are, so every command the
# brief hands a crewmate must follow bin/, not the state root.
W6HOME="$TMP/alt-home"
w6alt() { ( export DM_HOME="$W6HOME"; "$ROOT/bin/$@" ); }
w6alt dm-repo.sh add demo "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
w6alt dm-task.sh new w6alt-1 --kind ship --repo demo --title "add a widget" >/dev/null
w6alt dm-worktree.sh create w6alt-1 demo >/dev/null 2>&1
w6alt dm-brief.sh w6alt-1 >/dev/null 2>&1
W6ALTBR="$W6HOME/data/w6alt-1/brief.md"
check "the relocated brief is generated"     '[ -f "$W6ALTBR" ]'
check "state did relocate to the override"   '[ -f "$W6HOME/state/tasks/w6alt-1.meta" ] && [ ! -d "$W6HOME/bin" ]'
check "no brief command points into the nonexistent relocated bin/" \
  '! grep -q "$W6HOME/bin/" "$W6ALTBR"'
check "every toolbelt command in the brief resolves to a real script" \
  '( W6N=0; for w6p in $(grep -oE "/[^ \`]*/bin/dm-[a-z-]*\.sh" "$W6ALTBR" | sort -u); do
       [ -x "$w6p" ] || exit 1; W6N=$((W6N+1)); done; [ "$W6N" -ge 3 ] )'

echo "== tangle: an unborn HEAD is not reported as a doubled branch name (#123) =="
# `git rev-parse --abbrev-ref HEAD` on an unborn HEAD prints "HEAD" to STDOUT and
# exits 128, so an `|| echo HEAD` fallback captured both and corrupted the
# diagnostic in exactly the case that needs a clear one.
b dm-repo.sh add w6unborn "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/w6unborn" checkout -q --orphan w6-unborn-branch
W6UNBORN="$(b dm-worktree.sh tangle w6unborn 2>&1 || true)"
check "an unborn HEAD reports no tangle at all"  '[ -z "$W6UNBORN" ]'
check "no output line is a bare doubled HEAD"    '! grep -qx "HEAD" <<<"$W6UNBORN"'
# A clone whose HEAD is CORRUPT is a different thing from an unborn one: the
# resolver still finds the clone (.git is present), so tangle_check is what has
# to fail closed rather than report a tangle onto an empty branch name.
cp "$DM_HOME/repos/w6unborn/.git/HEAD" "$TMP/w6-head-backup"
printf 'garbage\n' > "$DM_HOME/repos/w6unborn/.git/HEAD"
W6BADRC=0
W6BADHEAD="$(b dm-worktree.sh tangle w6unborn 2>&1)" || W6BADRC=$?
cp "$TMP/w6-head-backup" "$DM_HOME/repos/w6unborn/.git/HEAD"
check "a corrupt HEAD refuses instead of naming an empty branch" \
  'grep -q "cannot read the current branch" <<<"$W6BADHEAD"'
check "that refusal is a nonzero result, not a clean clone" '[ "$W6BADRC" -ne 0 ]'
git -C "$DM_HOME/repos/w6unborn" checkout -q main

echo "== worktree cleanup: a legacy flat discard ref no longer blocks parking (#145) =="
# refs/dm-discarded/<id> (an earlier build's flat layout) is a git directory/file
# conflict: nothing can be created beneath it, so parking failed outright.
b dm-task.sh new w6dfl --kind ship --repo demo >/dev/null
W6DFLWT="$(b dm-worktree.sh create w6dfl demo | tail -n1)"
( cd "$W6DFLWT"; printf 'unlanded\n' > w6dfl.txt; git add w6dfl.txt; git commit -qm "unlanded work" ) >/dev/null 2>&1
W6DFLHEAD="$(git -C "$W6DFLWT" rev-parse HEAD)"
W6LEGACY="$(git -C "$DM_HOME/repos/demo" rev-parse HEAD)"
git -C "$DM_HOME/repos/demo" update-ref "refs/dm-discarded/w6dfl" "$W6LEGACY"
b dm-worktree.sh remove w6dfl --force >/dev/null 2>&1
check "the discarded head is parked despite the legacy flat ref" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/w6dfl/$W6DFLHEAD" || true)" = "$W6DFLHEAD" ]'
check "the legacy head is migrated into the nested layout, not dropped" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/w6dfl/$W6LEGACY" || true)" = "$W6LEGACY" ]'
check "the record claims preservation only because it happened" \
  'grep -q "kept at refs/dm-discarded/w6dfl/$W6DFLHEAD" "$DM_HOME/state/tasks/w6dfl.status"'

echo "== dm_untracked: a failed read names its cause, and cannot race to empty (#146) =="
# The error was re-read by a SECOND git run. A second run that succeeds leaves
# the refusal with nothing to name. This git fails once, then succeeds — exactly
# the race — so the cause survives only if it was captured from the first run.
W6GITSTUB="$TMP/w6-git-stub"; mkdir -p "$W6GITSTUB"
cat > "$W6GITSTUB/git" <<'W6STUB'
#!/usr/bin/env bash
if [ ! -f "$W6_STUB_MARKER" ]; then
  : > "$W6_STUB_MARKER"
  echo "fatal: unable to read index file (simulated)" >&2
  exit 128
fi
exit 0
W6STUB
chmod +x "$W6GITSTUB/git"
cat > "$TMP/w6-untracked.sh" <<'W6DRV'
. "$1/bin/dm-lib.sh"
dm_untracked "$2" || true
W6DRV
W6UNTR="$(PATH="$W6GITSTUB:$PATH" W6_STUB_MARKER="$TMP/w6-stub-fired" bash "$TMP/w6-untracked.sh" "$ROOT" "$TMP" 2>&1)"
check "the refusal carries git's actual message"  'grep -q "unable to read index file" <<<"$W6UNTR"'
check "it does not degrade to 'no detail from git'" '! grep -q "no detail from git" <<<"$W6UNTR"'
check "it still names the exit code and directory" 'grep -q "exit 128" <<<"$W6UNTR" && grep -q "$TMP" <<<"$W6UNTR"'
# The success path is unchanged, and the error temp never lands in the inspected
# tree (a scratch file written there would itself read as untracked work).
W6CLEANREPO="$TMP/w6-clean-repo"; git init -q -b main "$W6CLEANREPO"
check "a clean tree still reports nothing" \
  '[ -z "$( ( . "$ROOT/bin/dm-lib.sh"; dm_untracked "$W6CLEANREPO" ) | tr -d "\n" )" ]'
: > "$W6CLEANREPO/stray.txt"
check "an untracked file is still reported" \
  '[ "$( ( . "$ROOT/bin/dm-lib.sh"; dm_untracked "$W6CLEANREPO" ) )" = stray.txt ]'

echo "== local landing: a second land reports the truth instead of a second merge (#126.1) =="
# Its own clone: by this point in the suite the shared `demo` clone is dirty from
# earlier sections, and a dirty clone refuses to land before this gate is reached.
b dm-repo.sh add w6merge "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
b dm-task.sh new w6land --kind ship --repo w6merge >/dev/null
W6LANDWT="$(b dm-worktree.sh create w6land w6merge | tail -n1)"
git -C "$W6LANDWT" checkout -q -b fix/x/w6-land
( cd "$W6LANDWT"; printf 'landed\n' > w6land.txt; git add w6land.txt; git commit -qm "w6 land" ) >/dev/null 2>&1
W6LAND1RC=0
W6LAND1="$(b dm-merge.sh local w6land 2>&1)" || W6LAND1RC=$?
[ "$W6LAND1RC" -eq 0 ] || printf '       first land said: %s\n' "$W6LAND1" >&2
check "the first land succeeds"  '[ "$W6LAND1RC" -eq 0 ]'
W6RELAND="$(b dm-merge.sh local w6land 2>&1 || true)"
check "a second land reports already-landed"  'grep -qi "already landed" <<<"$W6RELAND"'
check "it does not claim a new landing"       '! grep -qE "^landed w6land" <<<"$W6RELAND"'
check "exactly one merged event is on the record" \
  '[ "$(grep -c "merged: local" "$DM_HOME/state/tasks/w6land.status")" = 1 ]'

echo "== docs: every DM_* override bin/ reads is documented (#113) =="
# Derived from the code, not a hand-kept list: `${DM_X:-default}` in bin/ is
# exactly the set of knobs an adopter can turn.
W6ENVVARS="$(grep -rhoE '\$\{DM_[A-Z_]+:-' "$ROOT"/bin/*.sh "$ROOT"/bin/dm | sed 's/^\${//; s/:-$//' | sort -u)"
check "the derived override list is not empty (guard the guard)" '[ "$(grep -c . <<<"$W6ENVVARS")" -ge 5 ]'
check "README documents every one of them" \
  'W6MISS=""; for w6v in $W6ENVVARS; do grep -q "\`$w6v\`" "$ROOT/README.md" || W6MISS="$W6MISS $w6v"; done
   [ -z "$W6MISS" ] || { printf "       undocumented:%s\n" "$W6MISS" >&2; false; }'
check "the phantom lock-staleness knob stays gone" '! grep -rq "DM_LOCK_STALE_SECS" "$ROOT/bin/"'

echo "== refusal-swallow lint: generalized to every refusing function (#137) =="
# A function that refuses with dm_die/exit does not stop its CALLER when invoked
# inside $( ) — the exit kills only the subshell. The lint used to know one name
# (dm_repo_dir); three bugs of this class shipped in functions it had never heard
# of. Derive the refusing set from the code instead.
w6_refusing_in() {
  awk '
    /^[ \t]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ { n=$0; sub(/\(\).*/, "", n); inf=1; ref=0; next }
    inf && (/dm_die/ || /(^|[;&| \t])exit([ \t]|$)/) { ref=1 }
    inf && /^\}/ { if (ref) print n; inf=0 }
  ' "$1"
}
# Per-file: a script can call only its own functions plus dm-lib's, so a
# same-named helper in an unrelated script is not a call site here.
w6_swallowed_refusals() {
  local lib="$1" f alt; shift
  for f in "$@"; do
    alt="$( { w6_refusing_in "$f"; w6_refusing_in "$lib"; } | sort -u | tr '\n' '|' | sed 's/|$//' )"
    [ -n "$alt" ] || continue
    grep -nE '\[[^]]*\$\(('"$alt"')[ )]|\$\([^)]*\$\(('"$alt"')[ )]|case[^)]*\$\(('"$alt"')[ )]|local [^=;]*=[^=]*\$\(('"$alt"')[ )]|="?\$\(('"$alt"')[ )][^;]*(\|\||&&)[ ]*(return 0|true|:|continue)' "$f" \
      | sed "s|^|${f##*/}:|" || true
  done
}
W6REFUSERS="$(w6_refusing_in "$ROOT/bin/dm-lib.sh")"
check "the enumerator finds the known refusing helpers (guard the guard)" \
  '( for w6f in dm_repo_dir dm_require_worktree dm_meta_set dm_registry_require_valid dm_require_id; do
       grep -qx "$w6f" <<<"$W6REFUSERS" || exit 1; done )'
check "the enumerator does not flag a non-refusing helper (guard the guard)" \
  '! grep -qx "dm_first_line" <<<"$W6REFUSERS" && ! grep -qx "dm_default_branch" <<<"$W6REFUSERS"'
check "the lint knows far more than the one hardcoded resolver" \
  '[ "$(grep -c . <<<"$W6REFUSERS")" -ge 20 ]'
W6SWALLOWED="$(w6_swallowed_refusals "$ROOT/bin/dm-lib.sh" "$ROOT"/bin/dm-*.sh "$ROOT"/bin/dm)"
[ -z "$W6SWALLOWED" ] || printf '%s\n' "$W6SWALLOWED" >&2
check "no refusing function's status is swallowed anywhere in bin/" '[ -z "$W6SWALLOWED" ]'
# Guard the guard, on code the old lint was blind to: five real instances of the
# class, none of them dm_repo_dir.
W6PLANT="$TMP/w6-plant"; mkdir -p "$W6PLANT"
cp "$ROOT/bin/dm-lib.sh" "$W6PLANT/dm-lib.sh"
cat > "$W6PLANT/dm-planted.sh" <<'W6PLANTED'
#!/usr/bin/env bash
p_bracket() { if [ -n "$(dm_require_worktree "$1")" ]; then :; fi; }
p_nested()  { local top; top="$(cd "$(dm_require_worktree "$1")" && pwd -P)"; echo "$top"; }
p_case()    { case "$(dm_require_worktree "$1")" in *) : ;; esac; }
p_local()   { local wt="$(dm_require_worktree "$1")"; echo "$wt"; }
p_permit()  { local ok; ok="$(dm_registry_has "$1")" || return 0; echo "$ok"; }
W6PLANTED
cat > "$W6PLANT/dm-safe.sh" <<'W6SAFE'
#!/usr/bin/env bash
s_split() { local wt; wt="$(dm_require_worktree "$1")" || dm_die "no worktree"; echo "$wt"; }
s_guard() { local dir; dir="$(dm_repo_dir "$1")" || return 1; echo "$dir"; }
W6SAFE
W6PLANTHITS="$(w6_swallowed_refusals "$W6PLANT/dm-lib.sh" "$W6PLANT/dm-planted.sh")"
check "the generalized lint catches all five planted instances" \
  '[ "$(grep -c . <<<"$W6PLANTHITS")" = 5 ]'
# The pattern MUST live in a single-quoted variable: written inline in a
# double-quoted grep argument, `\$\(` collapses to `$(` and ERE `$` anchors the
# line, so the check would match nothing and could never fail.
W6OLDPAT='\[[^]]*\$\(dm_repo_dir|\$\([^)]*\$\(dm_repo_dir|case[^)]*\$\(dm_repo_dir|local [^=;]*=[^=]*\$\(dm_repo_dir'
check "the old dm_repo_dir-only pattern was blind to every one of them" \
  '! grep -qE "$W6OLDPAT" "$W6PLANT/dm-planted.sh"'
check "the old pattern is still a live regex (guard the guard)" \
  'grep -qE "$W6OLDPAT" <<<'"'"'  local dir="$(dm_repo_dir "$repo")"'"'"''
check "the lint does not flag the safe split or a refusing handler" \
  '[ -z "$(w6_swallowed_refusals "$W6PLANT/dm-lib.sh" "$W6PLANT/dm-safe.sh")" ]'


echo "== command guard: a heredoc OPERATOR, not a string that looks like one (#163) =="
# note_heredoc_operator ran on every token AFTER quote stripping, so `echo
# "<<EOF"` and a real `<<EOF` arrived identical. Believing the lookalike put the
# lexer into heredoc state and skipped to a delimiter line that never comes --
# and an unterminated heredoc is accepted, so every later command rode through
# unclassified. Same swallow-the-next-command shape #160 closed for `<<<`, one
# spelling over.
HD_LOOKALIKE=$'echo "<<EOF"\ngit push --force'
HD_LOOKALIKE_GREP=$'grep "<<EOF" README.md\ngit push --force'
HD_LOOKALIKE_BARE=$'echo "<<" marker\ngit push --force'
HD_LOOKALIKE_DASH=$'echo "<<-EOF"\ngit push --force'
# Unlike HD_LOOKALIKE_DASH (delimiter attached), this bare form isolates the
# `<<-` gate itself rather than an unrelated internal assertion (#167).
HD_LOOKALIKE_DASH_BARE=$'echo "<<-" marker\ngit push --force'
HD_LOOKALIKE_ESCAPED=$'echo \\<\\<EOF\ngit push --force'
check "a quoted heredoc lookalike no longer swallows the next command (#163)" \
  'all_blocked "$HD_LOOKALIKE" "$HD_LOOKALIKE_GREP" "$HD_LOOKALIKE_BARE" \
     "$HD_LOOKALIKE_DASH" "$HD_LOOKALIKE_DASH_BARE" "$HD_LOOKALIKE_ESCAPED"'
# The other half of the same bit, or the fix is just the old over-blocking: a
# REAL operator must still skip its body, in every spelling.
HD_REAL_PROSE=$'cat <<EOF\ngit push --force is what broke it\nEOF'
HD_REAL_QUOTED=$'cat <<\'EOF\'\ngit reset --hard everywhere\nEOF'
HD_REAL_DASH=$'cat <<-EOF\n\tgit clean -fdx in the notes\n\tEOF'
HD_REAL_SPACED=$'cat << EOF\ngit push --force in prose\nEOF'
check "a real heredoc still skips its body as data (#163)" \
  'all_allowed "$HD_REAL_PROSE" "$HD_REAL_QUOTED" "$HD_REAL_DASH" "$HD_REAL_SPACED"'

echo "== command guard: an unquoted heredoc delimiter EXPANDS its body (#163) =="
# `<<'EOF'` is literal; `<<EOF` is interpolated, so a `$( )` in its body is a
# command bash really runs. The lexer skipped both bodies identically, which
# made the interpolated one a clean channel for anything.
HD_EXPAND=$'cat <<EOF\n$(git push --force)\nEOF'
HD_EXPAND_TICK=$'cat <<EOF\n`git clean -fdx`\nEOF'
HD_EXPAND_DASH=$'cat <<-EOF\n\t$(git reset --hard)\n\tEOF'
HD_EXPAND_SPACED=$'cat << EOF\n$(git reset --hard)\nEOF'
HD_EXPAND_NESTED=$'cat <<EOF\nbefore $(git -C "$(pwd)" push --force) after\nEOF'
check "a substitution in an expanded heredoc body is classified (#163)" \
  'all_blocked "$HD_EXPAND" "$HD_EXPAND_TICK" "$HD_EXPAND_DASH" "$HD_EXPAND_SPACED" "$HD_EXPAND_NESTED"'
# Paired the other way. bash does NOT expand a quoted delimiter, so the same
# text there is inert and refusing it is over-blocking. `<<"EO"F` counts as
# quoted too: ANY quoted character in the delimiter word makes the body literal
# (verified against bash), as does a backslash in the body itself.
HD_INERT=$'cat <<\'EOF\'\n$(git push --force)\nEOF'
HD_INERT_DQ=$'cat <<"EOF"\n$(git push --force)\nEOF'
HD_INERT_PARTIAL=$'cat <<"EO"F\n$(git push --force)\nEOF'
HD_INERT_ESCAPED=$'cat <<EOF\n\\$(git push --force)\nEOF'
HD_INERT_PR=$'gh pr create --body "$(cat <<\'EOF\'\nthe git reset --hard path is fixed\nEOF\n)"'
check "a quoted delimiter keeps its body inert (#163)" \
  'all_allowed "$HD_INERT" "$HD_INERT_DQ" "$HD_INERT_PARTIAL" "$HD_INERT_ESCAPED" "$HD_INERT_PR"'
# A heredoc fed to a SHELL is a separate rule and must survive both fixes.
HD_SHELL_EXPAND=$'bash <<EOF\ngit push --force\nEOF'
HD_SHELL_LITERAL=$'bash <<\'EOF\'\ngit clean -fdx\nEOF'
check "a heredoc fed to a shell is still refused either way (#163)" \
  'all_blocked "$HD_SHELL_EXPAND" "$HD_SHELL_LITERAL"'
# The same class one spelling over: `0<file` redirects the very stdin `<file`
# does, and only the bare form was guarded.
check "the fd-numbered stdin redirect into a shell is refused (#163)" \
  'all_blocked "bash 0<payload.sh" "bash 0<&3" && all_allowed "echo 0<x" "git -C /tmp status"'
# Multi-zero spellings (`00<file`, `000<file`) alias fd 0 too; only the
# single-digit form was guarded (#167). A non-zero leading digit stays allowed.
check "any-zeros fd-numbered stdin redirect is refused, non-fd0 digits are not (#167)" \
  'all_blocked "bash 00<payload.sh" "bash 000<payload.sh" \
     && all_allowed "bash 01<payload.sh" "bash 10<payload.sh"'

echo "== bin/ must PARSE under bash 3.2: no bare esac in a pattern list (#164) =="
# bash 3.2 reads a bare `esac` ANYWHERE in a case pattern list as the reserved
# word and the file stops parsing; bash >= 4 accepts it. So a construct that is
# fine on every dev machine, and on every CI leg that resolves `bash` through
# PATH, makes the file unloadable on a stock macOS shell -- which is how #160
# shipped a dm-command-guard.sh that did not parse at all. Measured: only `esac`
# behaves this way; case/do/done/in/time/function are all fine unquoted.
esac_in_pattern_list() {
  grep -nE '(\|[[:space:]]*esac[[:space:]]*[|)])|((^|[[:space:]])esac[[:space:]]*\|)' "$@" || true
}
BARE_ESAC="$(esac_in_pattern_list "$ROOT"/bin/*.sh)"
[ -z "$BARE_ESAC" ] || printf '%s\n' "$BARE_ESAC" >&2
check "no bin/*.sh puts a bare esac in a case pattern list (#164)" '[ -z "$BARE_ESAC" ]'
# Guard the guard, in both spellings the construct actually takes.
ESAC_LINT="$TMP/esac-lint"; mkdir -p "$ESAC_LINT"
cat > "$ESAC_LINT/bad.sh" <<'ESACBAD'
#!/usr/bin/env bash
one_line() { case "$1" in for|esac|while) return 0 ;; esac; return 1; }
continued() { case "$1" in for|while|\
esac|until) return 0 ;; esac; return 1; }
ESACBAD
cat > "$ESAC_LINT/good.sh" <<'ESACGOOD'
#!/usr/bin/env bash
quoted() { case "$1" in for|'esac'|while) return 0 ;; esac; return 1; }
plain()  { case "$1" in for) return 0 ;; esac; return 1; }
ESACGOOD
check "the lint catches both spellings of the planted construct (#164)" \
  '[ "$(grep -c . <<<"$(esac_in_pattern_list "$ESAC_LINT/bad.sh")")" = 2 ]'
check "the lint clears a quoted esac and an ordinary terminator (#164)" \
  '[ -z "$(esac_in_pattern_list "$ESAC_LINT/good.sh")" ]'
# The lint is the portable half. CI's own `bash -n` over bin/*.sh runs PATH
# bash, which on the macOS runner is Homebrew 5 -- so nothing ever parsed the
# toolbelt with the 3.2 the invariant is about. Pin the explicit step, and pin
# that it stays behind the assertion that the runner still ships 3.2.
CI_YML="$ROOT/.github/workflows/ci.yml"
check "CI parses bin/*.sh with the macOS system bash 3.2 (#164)" \
  'grep -q "/bin/bash -n" "$CI_YML"'
check "that step stays behind the system-bash-is-v3 assertion (#164)" \
  '[ "$(grep -n "no longer version 3" "$CI_YML" | cut -d: -f1)" -lt "$(grep -n "/bin/bash -n" "$CI_YML" | cut -d: -f1)" ]'

# shard:split
echo "== verify gate: registry fields =="
V="$ROOT/bin/dm-verify.sh"
# Bounded readiness for every boot in this section: the 300s default can outlive
# a whole CI job, and a hang reports as a timeout instead of a failing check.
vup() { DM_VERIFY_READY_TIMEOUT=25 "$V" up "$@"; } || true
check "app fields are settable"        'b dm-repo.sh set demo app_url "http://localhost:\$DM_VERIFY_PORT" >/dev/null'
check "app_url is stored verbatim"     '[ "$(b dm-repo.sh get demo app_url)" = "http://localhost:\$DM_VERIFY_PORT" ]'
# Every app command is eval'd or matched as ONE line; a multi-line value would
# run only its first line, so it must be refused rather than silently truncated.
MULTILINE="$(printf 'one\ntwo')"
check "a multi-line app command is refused" '! b dm-repo.sh set demo app_start_cmd "$MULTILINE" >/dev/null 2>&1'
b dm-repo.sh set demo app_ready_cmd "true" >/dev/null
b dm-repo.sh set demo app_ready_cmd "" >/dev/null
check "an empty value clears the field"     '[ -z "$(b dm-repo.sh get demo app_ready_cmd)" ]'
check "an unknown field is still refused"   '! b dm-repo.sh set demo app_nonsense x >/dev/null 2>&1'

echo "== verify gate: does the gate fire? =="
b dm-task.sh new vrf1 --kind ship --repo demo --title "verify gate" >/dev/null
VWT="$(b dm-worktree.sh create vrf1 demo)"
mkdir -p "$VWT/frontend"; printf 'console.log(1)\n' > "$VWT/frontend/app.js"
# A user-facing surface moved but the repo cannot be booted. That is UNAVAILABLE
# (exit 3) and must never read as a pass or a quiet skip.
GATE_UNAVAIL="$("$V" gate vrf1 2>&1 || true)"; GATE_UNAVAIL_RC=0
"$V" gate vrf1 >/dev/null 2>&1 || GATE_UNAVAIL_RC=$?
check "no app config exits 3, not 0"        '[ "$GATE_UNAVAIL_RC" = 3 ]'
check "the unavailable refusal says so"     'grep -q "UNAVAILABLE" <<<"$GATE_UNAVAIL"'
check "it names the missing app_start_cmd"  'grep -q "app_start_cmd" <<<"$GATE_UNAVAIL"'
# All four gate decisions are ANSWERS; --json exits 0 for every one of them, so a
# machine caller reads `decision` instead of narrating exit codes (#196).
GATE_UNAVAIL_J="$("$V" gate vrf1 --json)"
check "gate --json exits 0 with no app config" '"$V" gate vrf1 --json >/dev/null'
check "gate --json decision is unavailable"    '[ "$(jq -r ".decision" <<<"$GATE_UNAVAIL_J")" = "unavailable" ]'
check "gate --json still names the surface"    '[ "$(jq -r ".files | length" <<<"$GATE_UNAVAIL_J")" -gt 0 ]'
check "gate --json refuses an unknown flag"    '! "$V" gate vrf1 --wat >/dev/null 2>&1'
check "gate refuses a stray positional arg"   '! "$V" gate vrf1 EXTRA >/dev/null 2>&1'
# The UNAVAILABLE sentence has ONE owner: a machine reader must not get a
# shortened paraphrase that drops how to fix it.
check "gate --json keeps the remediation hint" \
  '"$V" gate vrf1 --json | jq -e ".detail | contains(\"Register one: dm-repo.sh set demo app_start_cmd\")" >/dev/null'
check "gate --json keeps the bare wording"     \
  '"$V" gate vrf1 --json | jq -e ".detail | contains(\"NOTHING was verified\")" >/dev/null'
# "could not determine" must never be reported as "nothing to verify": a task
# whose worktree is gone exits 2, distinct from the no-surface 1.
b dm-task.sh new vrfx --kind ship --repo demo --title "no worktree" >/dev/null
GATE_ERR_RC=0; "$V" gate vrfx >/dev/null 2>&1 || GATE_ERR_RC=$?
check "an unresolvable worktree exits 2, not 1" '[ "$GATE_ERR_RC" = 2 ]'
GATE_ERR_J="$("$V" gate vrfx --json)"
check "gate --json exits 0 when it cannot decide" '"$V" gate vrfx --json >/dev/null'
check "gate --json decision is undetermined"      '[ "$(jq -r ".decision" <<<"$GATE_ERR_J")" = "undetermined" ]'
check "gate --json never calls that no surface"   '[ "$(jq -r ".decision" <<<"$GATE_ERR_J")" != "not-applicable" ]'

# A fake app that really LISTENS, so the port, readiness and ownership checks are
# exercised end to end without a network or a container.
# The connection error handler is load-bearing: port_busy probes by opening a TCP
# connection and dropping it, which arrives as ECONNRESET and killed this server
# outright on macOS. A real app tolerates a reset; a two-line fixture must too.
# nohup + closed stdio: a backgrounded server that stays attached to the calling
# shell's terminal and descriptors does not reliably outlive it (macOS kills this
# fixture the moment `up` returns). Any real app_start_cmd that backgrounds a
# server needs the same detachment.
VAPP_START='rm -f "$DM_VERIFY_DIR/app.pid"; ( nohup node -e "require(\"net\").createServer(function(c){c.on(\"error\",function(){});c.end(\"ok\\n\")}).listen(process.env.DM_VERIFY_PORT,\"127.0.0.1\")" >"$DM_VERIFY_DIR/app.log" 2>&1 </dev/null & printf "%s" "$!" > "$DM_VERIFY_DIR/app.pid" ); printf "port=%s cwd=%s\n" "$DM_VERIFY_PORT" "$PWD" > "$DM_VERIFY_DIR/app.state"'
# A genuine ownership probe: the listener must be the process THIS start command
# spawned, and only then is the boot token echoed back.
# The url assertion makes this probe DISCRIMINATING: if a re-probe ever read
# app_url live instead of the value pinned at boot, a concurrent edit to the
# shared registry would hand it a different DM_VERIFY_URL and this would fail.
VAPP_READY='[ "$DM_VERIFY_URL" = "http://localhost:$DM_VERIFY_PORT" ] && kill -0 "$(cat "$DM_VERIFY_DIR/app.pid")" 2>/dev/null && cp "$DM_VERIFY_DIR/token" "$DM_VERIFY_DIR/ready-proof"'
VAPP_STOP='if [ -f "$DM_VERIFY_DIR/app.pid" ]; then kill "$(cat "$DM_VERIFY_DIR/app.pid")" 2>/dev/null || true; fi; rm -f "$DM_VERIFY_DIR/app.pid" "$DM_VERIFY_DIR/app.state"'
vapp_register() {
  b dm-repo.sh set demo app_start_cmd "$VAPP_START" >/dev/null
  b dm-repo.sh set demo app_ready_cmd "$VAPP_READY" >/dev/null
  b dm-repo.sh set demo app_stop_cmd "$VAPP_STOP" >/dev/null
  b dm-repo.sh set demo app_seed_cmd 'printf seeded > "$DM_VERIFY_DIR/app.seed"' >/dev/null
}
vapp_register || true
check "a touched surface with app config is required" '"$V" gate vrf1 >/dev/null 2>&1'
check "the required line names the changed file"      'GOUT="$("$V" gate vrf1 2>&1)"; grep -q "frontend/app.js" <<<"$GOUT"'
GATE_REQ_J="$("$V" gate vrf1 --json)"
check "gate --json decision is required"              '[ "$(jq -r ".decision" <<<"$GATE_REQ_J")" = "required" ]'
check "gate --json lists the changed surface"         '[ "$(jq -r ".files[0]" <<<"$GATE_REQ_J")" = "frontend/app.js" ]'
# UNDER-FIRING is the failure mode this gate cannot afford, so with no registered
# verify_surfaces every non-doc path counts - including the layouts a hand-written
# glob list missed (a page component, a template, a top-level entrypoint).
rm -f "$VWT/frontend/app.js"
for vp in src/pages/Home.tsx app/views/home.erb app.py lib/widget.svelte; do
  mkdir -p "$VWT/$(dirname "$vp")"; printf 'x\n' > "$VWT/$vp"
  check "an unregistered repo still fires on $vp" '"$V" gate vrf1 >/dev/null 2>&1'
  rm -f "$VWT/$vp"
done
mkdir -p "$VWT/docs"; printf 'x\n' > "$VWT/docs/notes.md"; printf 'x\n' > "$VWT/README.md"
GATE_NA_RC=0; "$V" gate vrf1 >/dev/null 2>&1 || GATE_NA_RC=$?
check "a docs-only diff exits 1 (no surface)"  '[ "$GATE_NA_RC" = 1 ]'
GATE_NA_J="$("$V" gate vrf1 --json)"
check "gate --json exits 0 on a docs-only diff" '"$V" gate vrf1 --json >/dev/null'
check "gate --json decision is not-applicable"  '[ "$(jq -r ".decision" <<<"$GATE_NA_J")" = "not-applicable" ]'
check "gate --json lists no surface files"      '[ "$(jq -r ".files | length" <<<"$GATE_NA_J")" = 0 ]'
# verify_surfaces NARROWS the default, it does not widen it.
printf 'x\n' > "$VWT/app.py"
b dm-repo.sh set demo verify_surfaces 'frontend/**' >/dev/null
GATE_NARROW_RC=0; "$V" gate vrf1 >/dev/null 2>&1 || GATE_NARROW_RC=$?
check "verify_surfaces narrows what fires"     '[ "$GATE_NARROW_RC" = 1 ]'
b dm-repo.sh set demo verify_surfaces '' >/dev/null
check "clearing it restores the broad default" '"$V" gate vrf1 >/dev/null 2>&1'
rm -f "$VWT/app.py"
# A surface moved AND a non-surface path sorts after it. surface_hits' status is
# its last iteration's, so a trailing non-match left it 1 and set -e aborted the
# gate at exit 1 — the "no user-facing surface" code, returned with a surface
# already found. Only stdout answers this question; the status must not.
mkdir -p "$VWT/frontend"; printf 'x\n' > "$VWT/frontend/app.js"; printf 'x\n' > "$VWT/zzz.txt"
b dm-repo.sh set demo verify_surfaces 'frontend/**' >/dev/null
GATE_MIXED="$("$V" gate vrf1 2>&1 || true)"; GATE_MIXED_RC=0
"$V" gate vrf1 >/dev/null 2>&1 || GATE_MIXED_RC=$?
check "a surface trailed by a non-surface still fires" '[ "$GATE_MIXED_RC" = 0 ]'
check "and the required line names the surface"        'grep -q "frontend/app.js" <<<"$GATE_MIXED"'
b dm-repo.sh set demo verify_surfaces '' >/dev/null
rm -f "$VWT/frontend/app.js" "$VWT/zzz.txt"

if ! command -v node >/dev/null 2>&1; then
  echo "  skip verify-gate lifecycle checks (node absent; the fixture app needs it)"
else

echo "== verify gate: the app under test must be the one we started =="
# app_start_cmd that starts nothing + no listener: readiness must never pass.
b dm-repo.sh set demo app_start_cmd 'true' >/dev/null
check "a start that binds nothing fails the gate" '! DM_VERIFY_READY_TIMEOUT=2 "$V" up vrf1 >/dev/null 2>&1'
# The TOCTOU that the port-silence check alone cannot close: something else binds
# the port DURING the readiness window. Without the ownership proof the gate
# adopted it; the proof is what makes the foreign listener unverifiable.
VSQUAT_PORT="$(derived_app_port vrf1)"
squat_port "$VSQUAT_PORT" 25 2
VADOPT_RC=0; DM_VERIFY_READY_TIMEOUT=12 "$V" up vrf1 >/dev/null 2>&1 || VADOPT_RC=$?
check "the foreign listener really took the port"      'squat_bound'
check "a foreign listener is never adopted as the app" '[ "$VADOPT_RC" != 0 ]'
check "no app state is recorded for it"                '[ "$(b dm-task.sh get vrf1 verify_app_state)" != "up" ]'
kill "$SQUAT_PID" 2>/dev/null || true
vapp_register || true
# A repo whose probe never proves ownership cannot verify anything.
b dm-repo.sh set demo app_ready_cmd 'true' >/dev/null
VNOPROOF="$(DM_VERIFY_READY_TIMEOUT=4 "$V" up vrf1 2>&1 || true)"
check "a probe that proves nothing fails the boot" 'grep -q "never proved it is this task" <<<"$VNOPROOF"'
b dm-repo.sh set demo app_ready_cmd '' >/dev/null
check "no ownership probe at all is refused"       '! vup vrf1 >/dev/null 2>&1'
vapp_register || true

echo "== verify gate: app lifecycle =="
check "up boots the app"                 'vup vrf1 >/dev/null 2>&1'
VPORT="$(b dm-task.sh get vrf1 verify_port)"
VDIR="$DM_HOME/data/vrf1/verify"
check "the port is in the per-task range" '[ "$VPORT" -ge 8600 ] && [ "$VPORT" -le 8999 ]'
# derived_app_port mirrors dm-verify.sh's formula and the squatter checks below
# hang on it, so the mirror has to be pinned to the real thing. Nothing else was
# listening in that range here, so the boot got its derived port outright.
check "the boot used the derived port"    '[ "$VPORT" = "$(derived_app_port vrf1)" ]'
check "app state is recorded up"          '[ "$(b dm-task.sh get vrf1 verify_app_state)" = "up" ]'
[ -s "$VDIR/app.log" ] && printf '       fixture app.log: %s\n' "$(head -c 300 "$VDIR/app.log" | tr '\n' ' ')"
check "the app really listens"            'node -e "require(\"net\").connect($VPORT,\"127.0.0.1\").on(\"connect\",function(){process.exit(0)}).on(\"error\",function(){process.exit(1)})"'
check "DM_VERIFY_PORT reached the app"    'grep -q "port=$VPORT" "$VDIR/app.state"'
check "the app ran in the task worktree"  'grep -q "cwd=$VWT" "$VDIR/app.state"'
check "the seed command ran"              '[ -f "$VDIR/app.seed" ]'
check "app_url resolved the port token"   '[ "$(b dm-task.sh get vrf1 verify_url)" = "http://localhost:$VPORT" ]'
check "the boot pinned the code under test" '[ -n "$(b dm-task.sh get vrf1 verify_head)" ]'
check "a second up refuses while it is up" '! vup vrf1 >/dev/null 2>&1'
check "down stops the app"                '"$V" down vrf1 >/dev/null 2>&1'
check "the app is really gone"            '! node -e "require(\"net\").connect($VPORT,\"127.0.0.1\").on(\"connect\",function(){process.exit(0)}).on(\"error\",function(){process.exit(1)})"'
check "app state is recorded down"        '[ "$(b dm-task.sh get vrf1 verify_app_state)" = "down" ]'
check "down is idempotent"                '"$V" down vrf1 >/dev/null 2>&1'

echo "== verify gate: down never reports success over a live app =="
vup vrf1 >/dev/null 2>&1 || true
# A stop command that does not stop anything. `down` used to record 'down' and
# exit 0 anyway, leaving an app nothing could ever stop again.
b dm-repo.sh set demo app_stop_cmd 'true' >/dev/null
VLEAK_RC=0; VLEAK="$(DM_VERIFY_STOP_SETTLE=2 "$V" down vrf1 2>&1)" || VLEAK_RC=$?
check "a stop that stops nothing fails"       '[ "$VLEAK_RC" != 0 ]'
check "the refusal names the live port"       'grep -q "STILL listening on port $VPORT" <<<"$VLEAK"'
check "the state records the leak, not down"  '[ "$(b dm-task.sh get vrf1 verify_app_state)" = "leaked" ]'
b dm-repo.sh set demo app_stop_cmd "$VAPP_STOP" >/dev/null
check "a real stop then clears it"            '"$V" down vrf1 >/dev/null 2>&1 && [ "$(b dm-task.sh get vrf1 verify_app_state)" = "down" ]'

echo "== verify gate: a failed boot always tears down =="
# The start command half-starts (leaves a live listener) and then fails. Without
# the cleanup trap that listener - a real app or container - would leak.
b dm-repo.sh set demo app_start_cmd "$VAPP_START; false" >/dev/null
check "a failing start fails the gate"    '! vup vrf1 >/dev/null 2>&1'
check "the half-started app was stopped"  '[ ! -f "$VDIR/app.pid" ]'
check "state is recorded down after failure" '[ "$(b dm-task.sh get vrf1 verify_app_state)" = "down" ]'
b dm-repo.sh set demo app_start_cmd "$VAPP_START" >/dev/null
b dm-repo.sh set demo app_ready_cmd 'false' >/dev/null
check "a never-ready app fails the gate"  '! DM_VERIFY_READY_TIMEOUT=2 "$V" up vrf1 >/dev/null 2>&1'
check "the unready app was stopped"       '[ ! -f "$VDIR/app.pid" ]'
vapp_register || true

echo "== verify gate: the operator's own instance is never adopted =="
# The derived port is occupied by something that is NOT this task's app. The gate
# must move to a free one; attaching to whatever answers would be a fabricated pass.
DERIVED="$(derived_app_port vrf1)"
squat_port "$DERIVED" 25
check "the derived port really is occupied"     'squat_bound'
vup vrf1 >/dev/null 2>&1 || true
BUSY_PORT="$(b dm-task.sh get vrf1 verify_port)"
check "the occupied derived port is not reused" '[ "$BUSY_PORT" != "$DERIVED" ]'
check "the app still booted on a free port"     '[ "$(b dm-task.sh get vrf1 verify_app_state)" = "up" ]'
kill "$SQUAT_PID" 2>/dev/null || true
"$V" down vrf1 >/dev/null 2>&1

echo "== verify gate: a pass needs evidence, not an assertion =="
# A stub browser: `shot` must reject what it produces unless it is a real PNG.
VB="$TMP/verify-bin"; mkdir -p "$VB"
cat > "$VB/chrome-devtools-axi" <<'AXI'
#!/usr/bin/env bash
# Stub driver. `screenshot <path>` writes whatever DM_SMOKE_SHOT says to write.
if [ "${1:-}" = "start" ]; then printf 'status: ready\nport: %s\n' "${CHROME_DEVTOOLS_AXI_PORT:-9224}"; exit 0; fi
if [ "${1:-}" = "screenshot" ]; then
  case "${DM_SMOKE_SHOT:-png}" in
    none) : ;;
    stub) printf 'X' > "$2" ;;
    *)    { printf '\211PNG\r\n\032\n'; dd if=/dev/zero bs=1024 count=1 2>/dev/null; } > "$2" ;;
  esac
  printf 'screenshot: %s\n' "$2"; exit 0
fi
exit 0
AXI
chmod +x "$VB/chrome-devtools-axi"
vsh() { PATH="$VB:$PATH" DM_VERIFY_BROWSER_SHARED=1 DM_VERIFY_LEASE_TIMEOUT=1 "$V" "$@"; } || true
vup vrf1 >/dev/null 2>&1 || true
# THE FORGERY: one command used to mint a green gate with no app, no browser and
# no screenshot. Each refusal below is one leg of that forgery closed.
FORGE1="$("$V" flow vrf1 login pass "signed in fine" 2>&1 || true)"
check "pass is refused without a browser"     'grep -q "no live browser" <<<"$FORGE1"'
vsh session vrf1 >/dev/null 2>&1 || true
FORGE2="$("$V" flow vrf1 login pass "signed in fine" 2>&1 || true)"
check "pass is refused without a screenshot"  'grep -q "no screenshot of .login. was taken during THIS run" <<<"$FORGE2"'
check "a fail may still be recorded with none" '"$V" flow vrf1 login fail "could not sign in" >/dev/null 2>&1'
check "the forged run reports FAIL"           '! "$V" report vrf1 >/dev/null 2>&1'
# shot itself refuses anything that is not a real PNG.
check "shot refuses a file the driver never wrote" '! DM_SMOKE_SHOT=none vsh shot vrf1 login >/dev/null 2>&1'
check "shot refuses a stub that is not a PNG"      '! DM_SMOKE_SHOT=stub vsh shot vrf1 login >/dev/null 2>&1'
check "shot accepts a real PNG"                    'DM_SMOKE_SHOT=png vsh shot vrf1 login >/dev/null 2>&1'
check "the screenshot landed under the task"       '[ -s "$VDIR/shots/login.png" ]'
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1; vsh session vrf1 >/dev/null 2>&1
DM_SMOKE_SHOT=png vsh shot vrf1 login >/dev/null 2>&1
check "pass is accepted with app, browser and PNG" '"$V" flow vrf1 login pass "signed in" >/dev/null 2>&1'
check "an all-pass run passes the gate"            '"$V" report vrf1 >/dev/null 2>&1'
check "the pass is recorded in meta"               '[ "$(b dm-task.sh get vrf1 verify)" = "pass" ]'
# The evidence must still exist at report time, not just at record time.
mv "$VDIR/shots/login.png" "$VDIR/shots/login.png.bak"
VGONE="$("$V" report vrf1 2>&1 || true)"
check "report refuses a pass whose screenshot vanished" 'grep -q "evidence for this verdict does not exist" <<<"$VGONE"'
mv "$VDIR/shots/login.png.bak" "$VDIR/shots/login.png"

echo "== verify gate: evidence must come from THIS run, not just look like a PNG =="
# shot_is_real checks PNG shape, which is not provenance. Each route below
# produced a green verdict when shape was the only test.
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1; vsh session vrf1 >/dev/null 2>&1
DM_SMOKE_SHOT=png vsh shot vrf1 realflow >/dev/null 2>&1
check "a genuinely captured shot still passes"  '"$V" flow vrf1 realflow pass "driven" >/dev/null 2>&1'
# Route 1: copy any PNG in under a flow name nobody captured.
cp "$VDIR/shots/realflow.png" "$VDIR/shots/copied.png"
VCOPY="$("$V" flow vrf1 copied pass "never driven" 2>&1 || true)"
check "a copied PNG is not evidence"            'grep -q "no screenshot of .copied. was taken during THIS run" <<<"$VCOPY"'
# Route 2: one image satisfying a second flow.
cp "$VDIR/shots/realflow.png" "$VDIR/shots/reused.png"
VREUSE_RC=0; "$V" flow vrf1 reused pass "same image" >/dev/null 2>&1 || VREUSE_RC=$?
check "one image cannot satisfy a second flow"  '[ "$VREUSE_RC" != 0 ]'
# Route 3: a symlink into a previous run's shots.
mkdir -p "$VDIR/runs/faked/shots"; cp "$VDIR/shots/realflow.png" "$VDIR/runs/faked/shots/linked.png"
ln -s "$VDIR/runs/faked/shots/linked.png" "$VDIR/shots/linked.png"
VLINK_RC=0; "$V" flow vrf1 linked pass "symlinked" >/dev/null 2>&1 || VLINK_RC=$?
check "a symlinked screenshot is not evidence"  '[ "$VLINK_RC" != 0 ]'
rm -f "$VDIR/shots/linked.png" "$VDIR/shots/copied.png" "$VDIR/shots/reused.png"
# Route 4 - the one that reversed the archiving fix with two `cp`s: restore a
# whole prior run's shots and flows over the current ones.
"$V" report vrf1 >/dev/null 2>&1
cp "$VDIR/flows.tsv" "$TMP/prior-flows.tsv"; cp -a "$VDIR/shots" "$TMP/prior-shots"
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1
cp -a "$TMP/prior-shots/." "$VDIR/shots/"; cp "$TMP/prior-flows.tsv" "$VDIR/flows.tsv"
VRESTORE_RC=0; VRESTORE="$("$V" report vrf1 2>&1)" || VRESTORE_RC=$?
check "a restored prior run is not this run's verdict" '[ "$VRESTORE_RC" != 0 ]'
check "the refusal says the evidence is not this run's" \
  'grep -q "not this run.s own" <<<"$VRESTORE"'
rm -f "$VDIR/flows.tsv"; rm -rf "$VDIR/runs/faked"
# A shots path in the record that escapes the run directory must never be
# rendered into report.html as an <img src>.
vsh session vrf1 >/dev/null 2>&1; DM_SMOKE_SHOT=png vsh shot vrf1 escflow >/dev/null 2>&1 || true
"$V" flow vrf1 escflow pass "driven" >/dev/null 2>&1
sed 's#shots/escflow.png#../../../../etc/passwd.png#' "$VDIR/flows.tsv" > "$TMP/esc.tsv"
cp "$TMP/esc.tsv" "$VDIR/flows.tsv"
VESC_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VESC_RC=$?
check "an escaping screenshot path is refused"  '[ "$VESC_RC" != 0 ]'
check "no traversal path reaches report.html"   '! grep -q "\.\./\.\./" "$VDIR/report.html" 2>/dev/null'
# A `fail` row renders into report.html exactly like a pass one, so the path
# check cannot sit behind the pass filter, and every field must be escaped.
"$V" down vrf1 >/dev/null 2>&1 || true; vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
"$V" flow vrf1 badrow fail "broken" >/dev/null 2>&1 || true
awk -F'\t' 'BEGIN{OFS="\t"} {$5="../../../../etc/passwd.png"; print}' "$VDIR/flows.tsv" > "$TMP/failesc.tsv"
cp "$TMP/failesc.tsv" "$VDIR/flows.tsv"
VFESC_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VFESC_RC=$?
check "a FAIL row's escaping path is refused too" '[ "$VFESC_RC" != 0 ]'
check "it never reached report.html"              '! grep -q "etc/passwd.png" "$VDIR/report.html" 2>/dev/null'
# A field that tries to close the src attribute must be escaped, not rendered.
printf '%s\tinject\tfail\t-\tshots/inject.png\t<script>alert(1)</script>\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VDIR/flows.tsv"
"$V" report vrf1 >/dev/null 2>&1 || true
check "no script tag is ever emitted"             '! grep -q "<script>" "$VDIR/report.html" 2>/dev/null'
# The attribute context, which injecting into the NOTE never exercised: `$shot`
# and `$name` land inside src="..."/alt="...", where a bare quote closes the
# attribute. A matching name/shot pair passes the path filter, so the escaper is
# the only thing standing between a crafted row and a live event handler.
VINJ='x" onerror="alert(1)'
printf '%s\t%s\tfail\t-\tshots/%s.png\tnote\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VINJ" "$VINJ" > "$VDIR/flows.tsv"
"$V" report vrf1 >/dev/null 2>&1 || true
check "a crafted name/shot pair is refused"      'grep -q "malformed-flow-name" <<<"$("$V" report vrf1 2>&1 || true)"'
check "no onerror handler reaches report.html"   '! grep -q "onerror=" "$VDIR/report.html" 2>/dev/null'
# And the escaper itself must close attributes, not only text.
check "html_escape escapes double quotes"        '[ -z "$(bash -c "$(sed -n "/^html_escape() {/,/^}/p" "$ROOT/bin/dm-verify.sh")"'"'"'; html_escape "a\"b"'"'"' | grep -F "\"")" ]'
check "html_escape escapes single quotes"        '[ -z "$(bash -c "$(sed -n "/^html_escape() {/,/^}/p" "$ROOT/bin/dm-verify.sh")"'"'"'; html_escape "a'"'"'"'"'"'"'"'"'b"'"'"' | grep -F "'"'"'")" ]'
rm -f "$VDIR/flows.tsv"
rm -f "$VDIR/flows.tsv"

echo "== verify gate: an ownership probe that proves nothing is refused (MED-4) =="
# A probe registered as the bare trailing `cp` passes with nothing running, so it
# would adopt any process that binds the port during the readiness window. `up`
# runs the probe once BEFORE starting anything: a real one cannot pass then.
"$V" down vrf1 >/dev/null 2>&1
b dm-repo.sh set demo app_ready_cmd 'cp "$DM_VERIFY_DIR/token" "$DM_VERIFY_DIR/ready-proof"' >/dev/null
VLAZY_RC=0; VLAZY="$(vup vrf1 2>&1)" || VLAZY_RC=$?
check "a probe that always passes fails the boot" '[ "$VLAZY_RC" != 0 ]'
check "the refusal says it proves nothing"        'grep -q "proves nothing" <<<"$VLAZY"'
check "nothing was recorded up"                   '[ "$(b dm-task.sh get vrf1 verify_app_state)" != "up" ]'
vapp_register || true
# The honest-probe boot IS the canonical state the sections below assume (app up,
# browser live, one flow driven this run), so it is not torn down and rebuilt.
# Setup lines are `|| true`: a bare failing command here aborts the whole suite
# under `set -e`, losing every later section's coverage. The abort itself is
# loud (non-zero exit, no summary line), but silence is not the point — the
# sections below are.
check "the honest probe still boots"              'vup vrf1 >/dev/null 2>&1'
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 login >/dev/null 2>&1 || true
"$V" flow vrf1 login pass "signed in" >/dev/null 2>&1 || true

echo "== verify gate: the verdict is bound to the code it verified =="
# A green run must not survive the edit that breaks the app.
printf 'changed after the boot\n' > "$VWT/frontend/app.js"
VMOVED="$("$V" report vrf1 2>&1 || true)"; VMOVED_RC=0
"$V" report vrf1 >/dev/null 2>&1 || VMOVED_RC=$?
check "report refuses once the worktree moved" 'grep -q "worktree changed since the app was booted" <<<"$VMOVED"'
# Exit 2, not 1: a run whose code moved is not a failing verdict, it is none.
check "the refusal exits 2, not a plain fail"  '[ "$VMOVED_RC" = 2 ]'
check "it says the working tree was edited"    'grep -q "working tree was edited" <<<"$VMOVED"'
VMOVEDF="$("$V" flow vrf1 login pass "still fine" 2>&1 || true)"
check "flow refuses a pass on moved code"      'grep -q "worktree changed since the app was booted" <<<"$VMOVEDF"'
rm -f "$VWT/frontend/app.js"
check "reverting the edit restores the verdict" '"$V" report vrf1 >/dev/null 2>&1'
# The case the porcelain checksum was BLIND to, and the one that actually
# happens: the file is ALREADY dirty, so every further edit produces the same
# status line and the same cksum. Only content moves the pin. The test above
# creates a file (absent -> present), which adds a line and hides this.
printf 'first edit\n' >> "$VWT/src/calc.py"
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1; vsh session vrf1 >/dev/null 2>&1
DM_SMOKE_SHOT=png vsh shot vrf1 dirtyflow >/dev/null 2>&1
check "a pass on an already-dirty tree is fine"  '"$V" flow vrf1 dirtyflow pass "verified" >/dev/null 2>&1'
check "and it reports green"                     '"$V" report vrf1 >/dev/null 2>&1'
printf 'second edit, same already-dirty file\n' >> "$VWT/src/calc.py"
VDIRTY_RC=0; VDIRTY="$("$V" report vrf1 2>&1)" || VDIRTY_RC=$?
check "editing an already-dirty file moves the pin" '[ "$VDIRTY_RC" = 2 ]'
check "the green verdict does not survive it"       'grep -q "worktree changed since the app was booted" <<<"$VDIRTY"'
VDIRTYF_RC=0; "$V" flow vrf1 newflow pass "after break" >/dev/null 2>&1 || VDIRTYF_RC=$?
check "no new pass can be minted on it"             '[ "$VDIRTYF_RC" != 0 ]'
git -C "$VWT" checkout -q -- src/calc.py 2>/dev/null || true
# The mirror blind spot of the porcelain checksum: hashing untracked CONTENT and
# not untracked PATHS. A route rename of new uncommitted work moved the app while
# the bytes stayed identical, so the pin sat still and a green verdict survived.
"$V" down vrf1 >/dev/null 2>&1 || true
mkdir -p "$VWT/frontend"; printf 'about page\n' > "$VWT/frontend/about.js"
vup vrf1 >/dev/null 2>&1 || true; vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 routed >/dev/null 2>&1 || true
"$V" flow vrf1 routed pass "route verified" >/dev/null 2>&1 || true
check "a green run on new untracked work"         '"$V" report vrf1 >/dev/null 2>&1'
mv "$VWT/frontend/about.js" "$VWT/frontend/contact.js"
VREN_RC=0; VREN="$("$V" report vrf1 2>&1)" || VREN_RC=$?
check "renaming an untracked file moves the pin"  '[ "$VREN_RC" = 2 ]'
check "the rename refusal names the edit"         'grep -q "worktree changed since the app was booted" <<<"$VREN"'
mv "$VWT/frontend/contact.js" "$VWT/frontend/about.js"
check "renaming it back restores the verdict"     '"$V" report vrf1 >/dev/null 2>&1'
# Same family: two untracked files merged into one, identical bytes overall.
printf 'a\n' > "$VWT/frontend/x1.js"; printf 'b\n' > "$VWT/frontend/x2.js"
"$V" down vrf1 >/dev/null 2>&1 || true; vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 split >/dev/null 2>&1 || true
"$V" flow vrf1 split pass "both routes" >/dev/null 2>&1 || true
check "a green run across two untracked files"    '"$V" report vrf1 >/dev/null 2>&1'
rm -f "$VWT/frontend/x1.js" "$VWT/frontend/x2.js"; printf 'a\nb\n' > "$VWT/frontend/merged.js"
VSPLIT_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VSPLIT_RC=$?
check "merging them moves the pin too"            '[ "$VSPLIT_RC" = 2 ]'
rm -f "$VWT/frontend/merged.js" "$VWT/frontend/about.js"
# The pin must not be JUMPY either, or it refuses every honest run.
"$V" down vrf1 >/dev/null 2>&1 || true; vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 steady >/dev/null 2>&1 || true
"$V" flow vrf1 steady pass "steady" >/dev/null 2>&1 || true
touch "$VWT/src/calc.py"
check "a no-op touch does not move the pin"       '"$V" report vrf1 >/dev/null 2>&1'
# The third blindness of the same pin: hashing the three streams FLAT. Moving a
# line from one untracked file to another leaves the path list and the total
# bytes identical, so only a per-file digest — path bound to its own content —
# moves it. The routes moved; the checksum must too.
"$V" down vrf1 >/dev/null 2>&1 || true
printf 'routeA\nrouteB\n' > "$VWT/frontend/a.js"; printf 'routeC\n' > "$VWT/frontend/b.js"
vup vrf1 >/dev/null 2>&1 || true; vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 moved >/dev/null 2>&1 || true
"$V" flow vrf1 moved pass "routes verified" >/dev/null 2>&1 || true
check "a green run across two untracked routes"  '"$V" report vrf1 >/dev/null 2>&1'
printf 'routeA\n' > "$VWT/frontend/a.js"; printf 'routeB\nrouteC\n' > "$VWT/frontend/b.js"
VMOVE_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VMOVE_RC=$?
check "a byte-neutral move still moves the pin"  '[ "$VMOVE_RC" = 2 ]'
rm -f "$VWT/frontend/a.js" "$VWT/frontend/b.js"
# An untracked file whose NAME looks like an option is handed to the digest tool
# as a bare argument: it was read as one, the tool printed usage and hashed
# NOTHING, and the untracked half of the pin became a constant. Assert the pin
# still moves with such a file present AND that the file itself is hashed.
"$V" down vrf1 >/dev/null 2>&1 || true
printf 'route\n' > "$VWT/frontend/opt.js"; : > "$VWT/--help"
vup vrf1 >/dev/null 2>&1 || true; vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 optname >/dev/null 2>&1 || true
"$V" flow vrf1 optname pass "driven" >/dev/null 2>&1 || true
check "a green run with an option-named file"    '"$V" report vrf1 >/dev/null 2>&1'
printf 'route CHANGED\n' > "$VWT/frontend/opt.js"
VOPT_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VOPT_RC=$?
check "an option-named file cannot blind the pin" '[ "$VOPT_RC" = 2 ]'
printf 'route\n' > "$VWT/frontend/opt.js"
check "restoring the edit restores the verdict"   '"$V" report vrf1 >/dev/null 2>&1'
printf 'now has content\n' > "$VWT/--help"
VOPT2_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VOPT2_RC=$?
check "the option-named file is itself hashed"    '[ "$VOPT2_RC" = 2 ]'
rm -f "$VWT/--help" "$VWT/frontend/opt.js"

echo "== verify gate: a dead app is never a green verdict (probe, not stamp) =="
# verify_app_state is a stamp `up` wrote; nothing re-checked it, so an app killed
# mid-run left it reading `up` forever and both flow-pass and report went green.
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1; vsh session vrf1 >/dev/null 2>&1
DM_SMOKE_SHOT=png vsh shot vrf1 liveflow >/dev/null 2>&1
check "a pass while the app serves is fine"    '"$V" flow vrf1 liveflow pass "seen live" >/dev/null 2>&1'
kill -9 "$(cat "$VDIR/app.pid")" 2>/dev/null || true
VDEADWAIT=0; while [ "$VDEADWAIT" -lt 10 ] && node -e "require('net').connect($(b dm-task.sh get vrf1 verify_port),'127.0.0.1').on('connect',function(){process.exit(0)}).on('error',function(){process.exit(1)})" 2>/dev/null; do VDEADWAIT=$((VDEADWAIT+1)); sleep 1; done
DM_SMOKE_SHOT=png vsh shot vrf1 deadflow >/dev/null 2>&1 || true
VDEADF="$("$V" flow vrf1 deadflow pass "app was killed" 2>&1 || true)"
check "a pass is refused once the app is dead" 'grep -q "nothing is listening on port" <<<"$VDEADF"'
VDEADR_RC=0; VDEADR="$("$V" report vrf1 2>&1)" || VDEADR_RC=$?
check "report refuses over a dead app"         '[ "$VDEADR_RC" = 2 ]'
check "the refusal names the dead port"        'grep -q "nothing is listening on port" <<<"$VDEADR"'
# Leave the canonical state the sections below assume: app up, browser live, and
# one flow (`login`) driven and recorded from THIS run. Every line is `|| true`:
# these are SETUP, not assertions, and a bare failing command here aborts the
# whole suite under `set -e`, taking every later section with it. The abort is
# loud; the lost coverage is the cost.
"$V" down vrf1 >/dev/null 2>&1 || true
vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 login >/dev/null 2>&1 || true
"$V" flow vrf1 login pass "signed in" >/dev/null 2>&1 || true

echo "== verify gate: a concurrent registry edit cannot repoint a live run =="
# Two crewmates share one state/repos.json. The liveness re-probe pins the app
# url at boot; reading it live would hand the pinned probe a DM_VERIFY_URL for a
# different instance, and a probe whose ownership test is local would pass there.
"$V" down vrf1 >/dev/null 2>&1 || true; vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 pinnedurl >/dev/null 2>&1 || true
"$V" flow vrf1 pinnedurl pass "driven" >/dev/null 2>&1 || true
b dm-repo.sh set demo app_url 'http://elsewhere.invalid:$DM_VERIFY_PORT' >/dev/null
check "the run uses the url pinned at boot"     '"$V" report vrf1 >/dev/null 2>&1'
b dm-repo.sh set demo app_url 'http://localhost:$DM_VERIFY_PORT' >/dev/null

echo "== verify gate: its trust fields are not hand-settable (fix 3's own hole) =="
# verify_ready_cmd is eval'd and validated only at boot, so a CLI write would
# bypass the boot check entirely. The pins that say what a verdict MEANS are
# protected with it.
# Every field any precondition of a `pass` reads. session_is_live reads only
# verify_browser_mode + verify_browser_pid, so leaving those settable made the
# browser leg forgeable with two ordinary CLI calls - and setting verify_axi_home
# + verify_browser_port re-points drive/shot at the operator's own default bridge,
# which is #80 reopened with their browser supplying this run's evidence.
for vkey in verify_ready_cmd verify_token verify_head verify_port verify_url verify_cwd \
            verify_app_state verify_browser_mode verify_browser_pid verify_browser_port \
            verify_cdp_port verify_axi_home verify_browser_profile verify; do
  check "dm-task.sh refuses to set $vkey" "! b dm-task.sh set vrf1 $vkey x >/dev/null 2>&1"
done
check "the refusal explains why"                'grep -q "verify-gate trust field" <<<"$(b dm-task.sh set vrf1 verify_ready_cmd x 2>&1 || true)"'
# Fields the gate does NOT trust stay writable - the browser lease is authoritative
# in its own directory, which the #80 section proves.
check "an untrusted verify field is still settable" 'b dm-task.sh set vrf1 verify_browser_lease released >/dev/null 2>&1'
# `kill 0` signals the caller's WHOLE PROCESS GROUP and SUCCEEDS, so `|| true`
# never fires and 2>/dev/null hides it - and browser_stop runs from `down`, which
# every crewmate arms in an EXIT trap. `0` passes a bare numeric guard; so do
# `00` and `000`. Bound to the real source: both functions must carry the
# all-zero exclusion, and the guard itself must never route one to `kill`.
check "browser_stop excludes all-zero pids"   'sed -n "/^browser_stop() {/,/^}/p" "$ROOT/bin/dm-verify.sh" | grep -q "\[!0\]"'
check "session_is_live excludes them too"     'sed -n "/^session_is_live() {/,/^}/p" "$ROOT/bin/dm-verify.sh" | grep -q "\[!0\]"'
cat > "$TMP/pidguard.sh" <<'PIDGUARD'
# The same two-step guard both functions use, exercised without sending signals.
verdict() {
  case "$1" in ''|*[!0-9]*) printf 'skip'; return ;; esac
  case "$1" in *[!0]*) printf 'kill' ;; *) printf 'skip' ;; esac
}
for p in EMPTY 0 00 000 abc 123 0123; do
  [ "$p" = EMPTY ] && p=''
  printf '%s=%s\n' "${p:-EMPTY}" "$(verdict "$p")"
done
PIDGUARD
VZERO="$(bash "$TMP/pidguard.sh")"
check "an empty pid never reaches kill"       'grep -qx "EMPTY=skip" <<<"$VZERO"'
check "pid 0 never reaches kill"              'grep -qx "0=skip" <<<"$VZERO"'
check "pid 00 never reaches kill"             'grep -qx "00=skip" <<<"$VZERO"'
check "pid 000 never reaches kill"            'grep -qx "000=skip" <<<"$VZERO"'
check "a non-numeric pid never reaches kill"  'grep -qx "abc=skip" <<<"$VZERO"'
check "a real pid still does"                 'grep -qx "123=kill" <<<"$VZERO"'
check "a zero-prefixed real pid still does"   'grep -qx "0123=kill" <<<"$VZERO"'

echo "== verify gate: clearing the probe mid-run cannot re-open the fail-open =="
# Two crewmates share one registry. Clearing app_ready_cmd used to turn the
# liveness re-probe into `return 0`, so a foreign listener passed as the app.
"$V" down vrf1 >/dev/null 2>&1 || true; vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 pinned >/dev/null 2>&1 || true
"$V" flow vrf1 pinned pass "driven" >/dev/null 2>&1 || true
b dm-repo.sh set demo app_ready_cmd '' >/dev/null
check "the boot-pinned probe still runs"        '"$V" report vrf1 >/dev/null 2>&1'
VCLRPORT="$(b dm-task.sh get vrf1 verify_port)"
kill -9 "$(cat "$VDIR/app.pid")" 2>/dev/null || true
VCLRWAIT=0
while [ "$VCLRWAIT" -lt 10 ] && node -e "require('net').connect($VCLRPORT,'127.0.0.1').on('connect',function(){process.exit(0)}).on('error',function(){process.exit(1)})" 2>/dev/null; do
  VCLRWAIT=$((VCLRWAIT+1)); sleep 1
done
squat_port "$VCLRPORT" 20
check "the squatter really took the app's old port" 'squat_bound'
VCLR_RC=0; VCLR="$("$V" report vrf1 2>&1)" || VCLR_RC=$?
check "a foreign listener is not the app"       '[ "$VCLR_RC" = 2 ]'
check "the refusal names the ownership proof"   'grep -q "no longer proves it is the instance" <<<"$VCLR"'
kill "$SQUAT_PID" 2>/dev/null || true
vapp_register
# Restore the canonical state the next section reads: a live app and a valid run.
"$V" down vrf1 >/dev/null 2>&1 || true
vup vrf1 >/dev/null 2>&1 || true
vsh session vrf1 >/dev/null 2>&1 || true
DM_SMOKE_SHOT=png vsh shot vrf1 login >/dev/null 2>&1 || true
"$V" flow vrf1 login pass "signed in" >/dev/null 2>&1 || true

echo "== verify gate: a truncated or malformed record is never a verdict =="
VFLOWS="$VDIR/flows.tsv"
cp "$VFLOWS" "$TMP/flows.good"
printf 'x\ty\tpass\tz' >> "$VFLOWS"   # no trailing newline
VTRUNC="$("$V" report vrf1 2>&1 || true)"
check "an unterminated final row is refused"   'grep -q "truncated mid-write" <<<"$VTRUNC"'
printf 'not-a-row\n' > "$VFLOWS"
VMAL="$("$V" report vrf1 2>&1 || true)"
check "a malformed row is refused"             'grep -q "malformed row" <<<"$VMAL"'
: > "$VFLOWS"
VEMPTY_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VEMPTY_RC=$?
check "an empty record exits 3, never 0"       '[ "$VEMPTY_RC" = 3 ]'
cp "$TMP/flows.good" "$VFLOWS"
check "the good record still verdicts"         '"$V" report vrf1 >/dev/null 2>&1'
check "a bad flow result is refused"           '! "$V" flow vrf1 login green >/dev/null 2>&1'
check "a bad flow name is refused"             '! "$V" flow vrf1 "bad name" pass >/dev/null 2>&1'
# A flake is not a pass (testing-policy's stance), and a new boot files the
# previous run away instead of carrying its verdict forward.
"$V" flow vrf1 retry flake "passed only on retry" >/dev/null
check "a flake does not pass the gate"         '! "$V" report vrf1 >/dev/null 2>&1'
"$V" down vrf1 >/dev/null 2>&1; vup vrf1 >/dev/null 2>&1
check "the previous run's flows are kept"      '[ -n "$(ls -A "$VDIR/runs" 2>/dev/null)" ]'
VFRESH_RC=0; "$V" report vrf1 >/dev/null 2>&1 || VFRESH_RC=$?
check "a fresh run starts with no verdict"     '[ "$VFRESH_RC" = 3 ]'
# A boot must archive the SCREENSHOTS too. Leaving last run's PNGs in place let a
# flow that was never driven this run satisfy the evidence check.
check "the previous run's screenshots go with it" '[ -z "$(ls -A "$VDIR/shots" 2>/dev/null)" ]'
vsh session vrf1 >/dev/null 2>&1 || true
VSTALE="$("$V" flow vrf1 login pass "never driven this run" 2>&1 || true)"
check "a stale screenshot cannot satisfy a pass"  'grep -q "no screenshot of .login. was taken during THIS run" <<<"$VSTALE"'

echo "== verify gate: two crewmates never drive one browser (#80) =="
# DM_VERIFY_BROWSER_SHARED forces the degraded path: no per-task browser, so the
# one shared browser is held under an exclusive lease instead of being shared.
check "session degrades to the shared browser" 'vsh session vrf1 >/dev/null 2>&1'
check "the shared mode is recorded"            '[ "$(b dm-task.sh get vrf1 verify_browser_mode)" = "shared" ]'
check "the lease names this task as holder"    '[ "$(cat "$DM_HOME/state/browser.lease/owner")" = "vrf1" ]'
b dm-task.sh new vrf2 --kind ship --repo demo --title "second driver" >/dev/null
b dm-worktree.sh create vrf2 demo >/dev/null
vup vrf2 >/dev/null 2>&1 || true
CONTEND="$(vsh session vrf2 2>&1 || true)"; CONTEND_RC=0
vsh session vrf2 >/dev/null 2>&1 || CONTEND_RC=$?
check "a second crewmate cannot take the browser" '[ "$CONTEND_RC" != 0 ]'
check "the refusal names the holder"              'grep -q "vrf1" <<<"$CONTEND"'
# The holder's liveness comes from the lease dir, not a meta stamp written after
# the lock was dropped: hand-clearing the stamp must NOT hand the browser over.
b dm-task.sh set vrf1 verify_browser_lease released >/dev/null
STEAL_RC=0; vsh session vrf2 >/dev/null 2>&1 || STEAL_RC=$?
check "a stale meta stamp cannot steal the lease" '[ "$STEAL_RC" != 0 ]'
check "the lease still names the real holder"     '[ "$(cat "$DM_HOME/state/browser.lease/owner")" = "vrf1" ]'
check "a non-holder has no live session"          '! PATH="$VB:$PATH" "$V" drive vrf2 snapshot >/dev/null 2>&1'
check "down releases the lease"                   '"$V" down vrf1 >/dev/null 2>&1; [ ! -d "$DM_HOME/state/browser.lease" ]'
check "the browser is then available"             'vsh session vrf2 >/dev/null 2>&1'
"$V" down vrf2 >/dev/null 2>&1
check "no lease is left behind"                   '[ ! -d "$DM_HOME/state/browser.lease" ]'
# The profile holds cookies and saved logins for the app just signed into, and
# data/ is copied wholesale into a state export.
check "down purges the browser profile"           '[ ! -d "$VDIR/chrome-profile" ] && [ ! -d "$VDIR/axi-home" ]'

echo "== verify gate: teardown stops the app even after the worktree is gone =="
vup vrf2 >/dev/null 2>&1 || true
VPORT2="$(b dm-task.sh get vrf2 verify_port)"
b dm-worktree.sh remove vrf2 --force >/dev/null 2>&1
check "worktree removal stopped the app"   '! node -e "require(\"net\").connect($VPORT2,\"127.0.0.1\").on(\"connect\",function(){process.exit(0)}).on(\"error\",function(){process.exit(1)})"'
check "the task records it as stopped"     '[ "$(b dm-task.sh get vrf2 verify_app_state)" = "down" ]'

fi

# shard:split
echo "== gate evidence: a PR carries what its gates saw (#175) =="
# The defect class this exists for is a check that APPEARS to run and does not,
# so the negatives matter more than the happy path: no test command registered,
# the verify gate UNAVAILABLE, a producer that errors, and a docs-only PR that
# must stay clean.
E="$ROOT/bin/dm-evidence.sh"
b dm-repo.sh add evrepo "$TMP/origin.git" --mode pipeline >/dev/null 2>&1
ev_task() {   # ev_task <id> <repo> <relpath> -> worktree with one committed file
  local id="$1" repo="$2" rel="$3" wt
  b dm-task.sh new "$id" --kind ship --repo "$repo" --mode pipeline >/dev/null
  wt="$(b dm-worktree.sh create "$id" "$repo" | tail -n1)"
  git -C "$wt" checkout -q -b "feat/x/$id"
  mkdir -p "$wt/$(dirname "$rel")"; printf 'x\n' >> "$wt/$rel"
  git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm "$id" >/dev/null
  printf '%s\n' "$wt"
}

# 1. No test command, and a surface the repo cannot boot. Both must be VISIBLE.
ev_task ev-bare evrepo src/thing.py >/dev/null
b dm-test.sh ev-bare >/dev/null
EV_BARE="$("$E" block ev-bare)"
check "an unregistered test command is reported on the PR" \
  'grep -q "no test command is registered" <<<"$EV_BARE"'
check "the tests block says NOT RUN, never a pass"  'grep -q "tests\*\* — NOT RUN" <<<"$EV_BARE"'
check "an UNAVAILABLE verify gate is reported"      'grep -q "verify (e2e)\*\* — NOT VERIFIED" <<<"$EV_BARE"'
check "the unavailable line names the missing app config" 'grep -q "has no app config" <<<"$EV_BARE"'

# 2. A docs-only task with no gate run at all contributes NOTHING — not even the
# separator. This is the "docs-only PRs stay clean" property.
ev_task ev-clean evrepo docs/notes.md >/dev/null
check "no gate run means no section at all"    '[ -z "$("$E" block ev-clean)" ]'
check "collecting an empty section still exits 0" '"$E" block ev-clean >/dev/null'
# ... and once the tests gate HAS run, its result appears while verify, which
# never ran, still contributes nothing.
b dm-test.sh ev-clean >/dev/null
EV_DOCS="$("$E" block ev-clean)"
check "a docs-only diff keeps the verify gate silent" '! grep -q "verify (e2e)" <<<"$EV_DOCS"'
check "the tests gate that did run is still reported" 'grep -q "tests\*\* — NOT RUN" <<<"$EV_DOCS"'

# 3. A producer that errors, and one that is gone, degrade to a stated line —
# never a silently dropped gate, and never a failed collection.
EV_BROKEN="$TMP/ev-broken-bin"; mkdir -p "$EV_BROKEN"
cp "$ROOT"/bin/dm-*.sh "$EV_BROKEN/"; chmod +x "$EV_BROKEN"/dm-*.sh
printf '#!/usr/bin/env bash\nexit 9\n' > "$EV_BROKEN/dm-verify.sh"; chmod +x "$EV_BROKEN/dm-verify.sh"
EV_ERR="$("$EV_BROKEN/dm-evidence.sh" block ev-bare)"
check "a producer that errors is reported, not dropped" 'grep -q "verify\*\* — evidence unavailable" <<<"$EV_ERR"'
check "a broken producer never fails the collection"    '"$EV_BROKEN/dm-evidence.sh" block ev-bare >/dev/null'
check "the surviving producer still contributes"        'grep -q "tests\*\* —" <<<"$EV_ERR"'
rm -f "$EV_BROKEN/dm-verify.sh"
EV_GONE="$("$EV_BROKEN/dm-evidence.sh" block ev-bare)"
check "a missing producer is reported, not dropped" 'grep -q "is missing or not executable" <<<"$EV_GONE"'

# 4. The verify block renders the recorded run. A real green run needs a browser,
# so the run's own artifacts (the verdict meta dm-verify.sh writes and its flow
# record) are placed directly — this asserts the RENDERING, not the verdict.
ev_task ev-run demo src/ui.js >/dev/null
b dm-test.sh ev-run >/dev/null
b dm-repo.sh set demo app_start_cmd 'true' >/dev/null
b dm-repo.sh set demo app_stop_cmd 'true' >/dev/null
b dm-repo.sh set demo verify_surfaces '' >/dev/null
EV_FLOWS="$DM_HOME/data/ev-run/verify"; mkdir -p "$EV_FLOWS"
printf '2026-01-01T00:00:00Z\tlogin\tpass\tsha1/1\tshots/login.png\tlanded | ok\n' > "$EV_FLOWS/flows.tsv"
printf 'verify=pass\nverify_head=sha1/1\n' >> "$DM_HOME/state/tasks/ev-run.meta"
EV_RUN="$("$E" block ev-run)"
check "a recorded verdict is reported with its flows" 'grep -q "verify (e2e)\*\* — pass · 1/1 flow" <<<"$EV_RUN"'
check "the verified code state is named"              'grep -q "sha1/1" <<<"$EV_RUN"'
check "each flow lands in the table"                  'grep -q "^| login | pass |" <<<"$EV_RUN"'
# The note is crew-written text on a rendered page. Every row must have exactly
# the 3 cells the header declares, whatever the note contains: `\|` was the
# escape that ate itself, `<` opens raw HTML.
check "a pipe in a note cannot split the row" 'grep -q "^| login | pass | landed &#124; ok |$" <<<"$EV_RUN"'
printf '2026-01-01T00:00:01Z\tlogout\tfail\tsha1/1\t-\tsaw a\\| pipe <img src=x> & more\n' >> "$EV_FLOWS/flows.tsv"
EV_HOSTILE="$("$E" block ev-run)"
check "an already-escaped pipe cannot split the row either" \
  'grep -q "^| logout | fail | saw a&#92;&#124; pipe &lt;img src=x&gt; &amp; more |$" <<<"$EV_HOSTILE"'
check "every rendered row has exactly three cells" \
  '[ -z "$(grep "^| " <<<"$EV_HOSTILE" | awk -F"|" "NF != 5")" ]'
printf '2026-01-01T00:00:00Z\tlogin\tpass\tsha1/1\tshots/login.png\tlanded | ok\n' > "$EV_FLOWS/flows.tsv"
# A verdict whose evidence is truncated must not be restated as a verdict.
printf 'x' >> "$EV_FLOWS/flows.tsv"
EV_TRUNC="$("$E" block ev-run)"
check "a truncated flow record reads unavailable, not pass" \
  'grep -q "verify (e2e)\*\* — evidence unavailable" <<<"$EV_TRUNC" && ! grep -q "verify (e2e)\*\* — pass" <<<"$EV_TRUNC"'
rm -rf "$EV_FLOWS"
EV_NOEV="$("$E" block ev-run)"
check "a verdict with no flow record reads unavailable" 'grep -q "evidence unavailable" <<<"$EV_NOEV"'

# 5. strip is what makes re-composing idempotent.
EV_BODY="$TMP/ev-body.md"
printf 'add multiply\n\nRisk: low.\n' > "$EV_BODY"
check "strip leaves a body with no section as written" \
  'cmp -s "$EV_BODY" <("$E" strip < "$EV_BODY")'
{ cat "$EV_BODY"; printf '\n'; "$E" block ev-bare; } > "$TMP/ev-body-with.md"
check "strip removes an appended section and its separator" \
  'cmp -s "$EV_BODY" <("$E" strip < "$TMP/ev-body-with.md")'
# A body round-tripped through GitHub comes back CRLF. Matching must ignore it,
# or the section is not recognized and a re-open stacks a second one.
sed 's/$/\r/' "$TMP/ev-body-with.md" > "$TMP/ev-body-crlf.md"
check "a CRLF body's section is still recognized" \
  '[ "$("$E" strip < "$TMP/ev-body-crlf.md" | wc -l)" = "$(wc -l < "$EV_BODY")" ]'

# strip must never TRUNCATE. Its anchor is a marker, and a marker is just text:
# a PR description about this very machinery quotes it. Removing from the first
# occurrence silently ate the rest of the operator's description, so only a
# COMPLETE begin..end region ending the body is removed.
EV_MARK="$(printf '%s' '<!-- dm:gate-evidence -->')"
printf 'anchored by a comment:\n\n%s\n\nand everything below it is regenerated.\n\nRisk: low.\n' \
  "$EV_MARK" > "$TMP/ev-quoted.md"
check "a body that quotes the marker keeps every byte" \
  'cmp -s "$TMP/ev-quoted.md" <("$E" strip < "$TMP/ev-quoted.md")'
printf '%s\nthe whole description\n\nRisk: low.\n' "$EV_MARK" > "$TMP/ev-leading.md"
check "a marker on the first line does not empty the body" \
  'cmp -s "$TMP/ev-leading.md" <("$E" strip < "$TMP/ev-leading.md")'
printf 'the anchor:\n\n```\n%s\n```\n\nRisk: low.\n' "$EV_MARK" > "$TMP/ev-fenced.md"
check "a marker inside a fenced block is not an anchor" \
  'cmp -s "$TMP/ev-fenced.md" <("$E" strip < "$TMP/ev-fenced.md")'
# ... and a quoted marker ABOVE a real section still leaves the quote alone.
{ cat "$TMP/ev-quoted.md"; printf '\n'; "$E" block ev-bare; } > "$TMP/ev-quoted-with.md"
check "a real section is removed without touching a quoted marker" \
  'cmp -s "$TMP/ev-quoted.md" <("$E" strip < "$TMP/ev-quoted-with.md")'

# 6. dm-pr.sh open composes the real body: operator text first, evidence below,
# and re-running over an already-composed body never stacks a second section.
EV_STUB="$TMP/ev-pr-stub"; mkdir -p "$EV_STUB"
cat > "$EV_STUB/gh" <<STUB
#!/bin/sh
next=0
for a in "\$@"; do
  [ "\$next" = 1 ] && { cp "\$a" "$EV_STUB/last-body"; next=0; }
  [ "\$a" = "--body-file" ] && next=1
done
printf 'https://github.com/o/r/pull/175\n'
STUB
chmod +x "$EV_STUB/gh"
PATH="$EV_STUB:$NOAXI_PATH" b dm-pr.sh open ev-bare --title T --body-file "$EV_BODY" >/dev/null 2>&1
EV_SENT="$(cat "$EV_STUB/last-body" 2>/dev/null || true)"
check "the operator's body stays first and intact" '[ "$(head -n3 "$EV_STUB/last-body")" = "$(cat "$EV_BODY")" ]'
check "the evidence is appended below a separator" 'grep -q "### Gate evidence" <<<"$EV_SENT"'
check "the composed body carries the tests gate"   'grep -q "no test command is registered" <<<"$EV_SENT"'
check "no composed-body temp file is left behind"  '[ -z "$(find "$DM_HOME/state" -maxdepth 1 -name ".pr-body.*")" ]'
cp "$EV_STUB/last-body" "$TMP/ev-recompose.md"
ev_task ev-again evrepo src/again.py >/dev/null
b dm-test.sh ev-again >/dev/null
PATH="$EV_STUB:$NOAXI_PATH" b dm-pr.sh open ev-again --title T --body-file "$TMP/ev-recompose.md" >/dev/null 2>&1
check "re-composing replaces the section, never stacks it" \
  '[ "$(grep -c "^<!-- dm:gate-evidence -->$" "$EV_STUB/last-body")" = 1 ]'
check "the replaced section is properly closed" \
  '[ "$(grep -c "^<!-- /dm:gate-evidence -->$" "$EV_STUB/last-body")" = 1 ]'
# Composing happens BEFORE the push, so an unreadable body fails with nothing
# pushed and nothing left behind.
ev_task ev-badbody evrepo src/bad.py >/dev/null
b dm-test.sh ev-badbody >/dev/null
check "an unreadable body file fails the open" \
  '! PATH="$EV_STUB:$NOAXI_PATH" b dm-pr.sh open ev-badbody --title T --body-file "$TMP/no-such-body.md" >/dev/null 2>&1'
check "a failed compose pushes nothing" \
  '! git -C "$TMP/origin.git" rev-parse --verify --quiet refs/heads/feat/x/ev-badbody >/dev/null'
check "a failed compose leaves no temp behind" \
  '[ -z "$(find "$DM_HOME/state" -maxdepth 1 -name ".pr-body.*")" ]'

# A task no gate has touched must reach gh with the caller's body untouched.
ev_task ev-untouched evrepo docs/more.md >/dev/null
rm -f "$EV_STUB/last-body"
PATH="$EV_STUB:$NOAXI_PATH" b dm-pr.sh open ev-untouched --title T --body-file "$EV_BODY" >/dev/null 2>&1
check "a PR with no gate evidence sends the caller's file unchanged" \
  'cmp -s "$EV_BODY" "$EV_STUB/last-body"'

# 7. The COLLECTOR itself failing must be visible ON THE PR. A warning on stderr
# lands in a log nobody opens, and a PR carrying nothing is indistinguishable
# from a PR whose gates all legitimately stayed out — precisely the false green
# this section exists to prevent.
EV_BIN2="$TMP/ev-bin2"; mkdir -p "$EV_BIN2"
cp "$ROOT"/bin/dm-*.sh "$EV_BIN2/"; chmod +x "$EV_BIN2"/dm-*.sh
ev_open() {   # ev_open <task> -> body the stub gh received
  rm -f "$EV_STUB/last-body"
  PATH="$EV_STUB:$NOAXI_PATH" "$EV_BIN2/dm-pr.sh" open "$1" --title T --body-file "$EV_BODY" >/dev/null 2>&1
  cat "$EV_STUB/last-body" 2>/dev/null || true
}
ev_task ev-nocoll evrepo src/nocoll.py >/dev/null; b dm-test.sh ev-nocoll >/dev/null
mv "$EV_BIN2/dm-evidence.sh" "$TMP/ev-collector.bak"
EV_NOCOLL="$(ev_open ev-nocoll)"
check "a missing collector is stated on the PR, not swallowed" \
  'grep -q "gate evidence\*\* — UNAVAILABLE" <<<"$EV_NOCOLL"'
check "the unavailable section still carries the operator's body" \
  '[ "$(head -n3 <<<"$EV_NOCOLL")" = "$(cat "$EV_BODY")" ]'
mv "$TMP/ev-collector.bak" "$EV_BIN2/dm-evidence.sh"
ev_task ev-noexec evrepo src/noexec.py >/dev/null; b dm-test.sh ev-noexec >/dev/null
chmod -x "$EV_BIN2/dm-evidence.sh"
check "a non-executable collector is stated too" \
  'grep -q "gate evidence\*\* — UNAVAILABLE" <<<"$(ev_open ev-noexec)"'
chmod +x "$EV_BIN2/dm-evidence.sh"
# The composed body holds PR text, so no failure may strand it in state/. A
# refused mktemp is the path that reached `gh` with the body already written.
ev_task ev-leak evrepo src/leak.py >/dev/null; b dm-test.sh ev-leak >/dev/null
printf '#!/bin/sh\ncase "$*" in *.pr-open.*) exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v mktemp)" > "$EV_STUB/mktemp"; chmod +x "$EV_STUB/mktemp"
check "a later failure still fails the open" \
  '! PATH="$EV_STUB:$NOAXI_PATH" b dm-pr.sh open ev-leak --title T --body-file "$EV_BODY" >/dev/null 2>&1'
check "no PR text is stranded in state/ by a later failure" \
  '[ -z "$(find "$DM_HOME/state" -maxdepth 1 -name ".pr-body.*")" ]'
rm -f "$EV_STUB/mktemp"

# 8. The published fields are not hand-settable: evidence a reviewer trusts must
# come from the gate that produced it.
check "tests result cannot be hand-set"  '! b dm-task.sh set ev-bare tests pass >/dev/null 2>&1'
check "tests command cannot be hand-set" '! b dm-task.sh set ev-bare tests_cmd "true" >/dev/null 2>&1'
check "the tests gate records what it ran" \
  '[ "$(b dm-task.sh get ev-clean tests)" = "skip" ] && [ "$(b dm-task.sh get ev-run tests_cmd)" = "test -f src/calc.py" ]'

echo "== the console: refusals, the chat queue, and machine-readable state (#192) =="
# The console reads the fleet ONLY through these scripts, so the JSON they emit
# is a contract: a panel is only as honest as the output behind it.
check "console prints its loopback url"        '[ "$(b dm-ui.sh url)" = "http://127.0.0.1:4877/" ]'
check "console honors DM_UI_PORT"              '[ "$(DM_UI_PORT=4999 b dm-ui.sh url)" = "http://127.0.0.1:4999/" ]'
check "console is not running in a fresh home" '! b dm-ui.sh status >/dev/null 2>&1'
# An invalid source must fail BEFORE a process is spawned. This is the #119 shape:
# a dm_die inside $( ) kills only the subshell, and the caller carried on with an
# empty value - which used to start the console on the demo fleet silently.
check "an invalid --source is refused"         '! b dm-ui.sh start --source bogus >/dev/null 2>&1'
check "an invalid --source starts nothing"     '! b dm-ui.sh status >/dev/null 2>&1'
check "an unexpected console argument is refused" '! b dm-ui.sh start --wat >/dev/null 2>&1'
check "a non-numeric poll timeout is refused"  '! b dm-ui.sh poll --timeout soon >/dev/null 2>&1'
check "an empty message is refused"            '! b dm-ui.sh say "" >/dev/null 2>&1'

# The chat queue is files, not the server: `say` and `poll` round-trip with
# nothing listening. Claiming is a rename, so a killed poll loses nothing.
check "poll times out with nothing queued" \
  'rc=0; b dm-ui.sh poll --timeout 1 >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 3 ]'
b dm-ui.sh say "the dockmaster speaks" >/dev/null
check "a reply lands in the transcript" \
  'grep -q "the dockmaster speaks" "$DM_HOME/state/ui/chat.jsonl"'
check "a reply is NOT queued for the dockmaster" \
  '[ -z "$(find "$DM_HOME/state/ui/inbox" -name "*.json" 2>/dev/null)" ]'
# An operator message is what poll waits on; post one the way the page does.
DM_UI_CHAT="$ROOT/ui/chat.js" node -e 'require(process.env.DM_UI_CHAT).append(process.env.DM_HOME, "operator", "ship the console")' \
  >/dev/null 2>&1
check "an operator message is queued"          '[ -n "$(find "$DM_HOME/state/ui/inbox" -name "*.json")" ]'
UI_POLLED="$(b dm-ui.sh poll --timeout 5 2>/dev/null || true)"
check "poll returns the operator's message"    'grep -q "ship the console" <<<"$UI_POLLED"'
check "poll claims it, so it is delivered once" \
  '[ -z "$(find "$DM_HOME/state/ui/inbox" -name "*.json")" ]'
check "a claimed message is kept, not deleted" \
  '[ -n "$(find "$DM_HOME/state/ui/claimed" -name "*.json")" ]'

# An unreadable queue entry must NOT kill the poll. `take` runs from an fs.watch
# and a timer, where a throw is unhandled and exits the process - and nothing
# restarts a poll, so that silently ends the dockmaster's wake mechanism while
# the message sits in the inbox exactly as promised. A 0-byte file is what a
# crashed writeFileSync leaves; the second is valid JSON of the wrong shape.
: > "$DM_HOME/state/ui/inbox/1000000000000-0-torn.json"
printf '{"at":"2026-01-01T00:00:00Z"}\n' > "$DM_HOME/state/ui/inbox/1000000000001-0-shape.json"
DM_UI_CHAT="$ROOT/ui/chat.js" node -e 'require(process.env.DM_UI_CHAT).append(process.env.DM_HOME, "operator", "delivered past the torn ones")' \
  >/dev/null 2>&1
UI_PAST_TORN="$(b dm-ui.sh poll --timeout 8 2>/dev/null || true)"
check "a torn queue entry does not end the poll" \
  'grep -q "delivered past the torn ones" <<<"$UI_PAST_TORN"'
check "and the unreadable entries are set aside, not left to retry" \
  '[ -z "$(find "$DM_HOME/state/ui/inbox" -name "*.json")" ]'
check "the set-aside entries are kept for inspection" \
  '[ -n "$(find "$DM_HOME/state/ui/claimed" -name "*torn.json")" ]'

# One read takes EVERYTHING queued: a session that was away should not have to
# poll once per backlogged message. Each claim is still its own atomic rename,
# and the acknowledgement only happens once the text is written out, so a poll
# killed mid-drain re-delivers rather than losing what it took.
for UI_N in one two three; do
  DM_UI_CHAT="$ROOT/ui/chat.js" node -e 'require(process.env.DM_UI_CHAT).append(process.env.DM_HOME, "operator", "backlog-" + process.argv[1])' "$UI_N" >/dev/null 2>&1
done
UI_DRAINED="$(b dm-ui.sh poll --timeout 8 2>/dev/null || true)"
check "one poll drains the whole backlog" \
  'grep -q "backlog-one" <<<"$UI_DRAINED" && grep -q "backlog-two" <<<"$UI_DRAINED" && grep -q "backlog-three" <<<"$UI_DRAINED"'
check "and says how many records it handed over" \
  'grep -q "^3 messages from the operator, oldest first\.$" <<<"$UI_DRAINED"'
check "each record is numbered and stamped" 'grep -q "\[2/3\] .* operator:" <<<"$UI_DRAINED"'
check "the drain empties the queue"          '[ -z "$(find "$DM_HOME/state/ui/inbox" -name "*.json")" ]'
check "and leaves no claim in flight"        '[ -z "$(find "$DM_HOME/state/ui/claiming" -name "*.json")" ]'

# tangle --json answers in the object and exits 0; the human form exits 1 to
# report a tangle, which a machine reader cannot tell from the script failing.
check "tangle emits json"          'b dm-worktree.sh tangle demo --json | jq -e "has(\"on\") and has(\"tangled\")" >/dev/null'
check "tangle --json exits 0 on a readable clone" 'b dm-worktree.sh tangle demo --json >/dev/null'
check "tangle --json reports the branch it found" \
  '[ "$(b dm-worktree.sh tangle demo --json | jq -r ".on")" = "$(b dm-worktree.sh tangle demo --json | jq -r ".expected")" ]'
check "tangle keeps its human form"  'b dm-worktree.sh tangle demo'
check "an unexpected tangle argument is refused" '! b dm-worktree.sh tangle demo --wat >/dev/null 2>&1'
check "tangle --json refuses an unregistered repo" '! b dm-worktree.sh tangle nosuchrepo --json >/dev/null 2>&1'

# A pid file naming a LIVE process that is not the console must never be deleted
# or killed. Deleting it orphans whatever holds the port, and the next `start`
# then fails with a bare address-in-use naming no cause. $$ is this shell: alive,
# and demonstrably not the server.
printf '%s\n' "$$" > "$DM_HOME/state/ui/server.pid"
check "stop refuses a pid file that is not the console" '! b dm-ui.sh stop >/dev/null 2>&1'
check "stop leaves that pid file alone"        '[ -f "$DM_HOME/state/ui/server.pid" ]'
check "status refuses it too, rather than reporting not-running" \
  '! b dm-ui.sh status >/dev/null 2>&1'
check "start refuses to race it"               '! b dm-ui.sh start >/dev/null 2>&1'
check "and this shell was not killed"          'kill -0 $$'
# A pid file naming a DEAD process is ordinary staleness: cleared, not refused.
printf '%s\n' "999999999" > "$DM_HOME/state/ui/server.pid"
check "stop clears a pid file naming a dead process" 'b dm-ui.sh stop >/dev/null 2>&1'
check "and the stale file is gone"             '[ ! -f "$DM_HOME/state/ui/server.pid" ]'

# Every --json emitter: valid JSON, and the human output it sits beside is
# untouched. A second parser in the page is what these exist to prevent.
UI_HUMAN_REPOS="$(b dm-repo.sh list)"
check "repos emit json"      'b dm-repo.sh list --json | jq -e "type==\"array\"" >/dev/null'
check "repos human output is unchanged"  '[ "$(b dm-repo.sh list)" = "$UI_HUMAN_REPOS" ]'
check "tasks emit json"      'b dm-task.sh list --json | jq -e "type==\"array\"" >/dev/null'
check "tasks never emit a local-copy path" \
  '! b dm-task.sh list --json | jq -e "any(.[]; has(\"worktree\"))" >/dev/null'
check "the backlog emits json" 'b dm-backlog.sh list --json | jq -e "has(\"items\") and has(\"decisions\")" >/dev/null'
check "decisions emit json"  'b dm-backlog.sh decisions --json | jq -e "type==\"array\"" >/dev/null'
check "local copies emit json" 'b dm-worktree.sh list --json | jq -e "type==\"array\"" >/dev/null'
check "review pages emit json" 'b dm-lavish.sh list --json | jq -e "type==\"array\"" >/dev/null'
check "health emits json"    'b dm-doctor.sh check --json | jq -e "has(\"verdict\") and (.checks|type==\"array\")" >/dev/null'
check "the gate track emits json" \
  'b dm-pr.sh pipeline smokerepo --json | jq -e "(.gates|length) > 0" >/dev/null'
check "the gate track has a human form too" \
  '[ -n "$(b dm-pr.sh pipeline smokerepo)" ]'
# The repo name composes a config filename, so it is validated before it can
# walk out of config/.
check "a traversing repo name is refused"      '! b dm-pr.sh pipeline ../../etc >/dev/null 2>&1'
check "the offline sweep emits json"           'DM_NO_FETCH=1 b dm-pr.sh sweep --json | jq -e "type==\"array\"" >/dev/null'
check "an unexpected sweep argument is refused" '! b dm-pr.sh sweep --wat >/dev/null 2>&1'
# A PR the sweep could not read stays in the list with a TOKEN the console
# words. A sentence here would put "clone missing" on the operator's screen.
check "an unreadable swept PR carries a token, not a sentence" \
  'DM_NO_FETCH=1 b dm-pr.sh sweep --json | jq -e "all(.[]; .unreadable == null or (.unreadable | test(\"^[a-z_]+$\")))" >/dev/null'

# The whole live collector, once, against this fixture home - the only place the
# real shell-out path is exercised end to end. It reads memory the way a
# CREWMATE does (recall --crew), so the dockmaster-only store, which exists
# precisely never to be relayed, must not reach the page either. DMONLY-crew-
# must-not-see was recorded in the memory-context block far above.
UI_COLLECTED="$(DM_UI_ROOT="$ROOT" node -e '
  const live = require(process.env.DM_UI_ROOT + "/ui/live.js")
  live.collectLocal(process.env.DM_UI_ROOT + "/bin")
    .then((d) => { console.log(JSON.stringify(d)) }, (e) => { console.error(e.message); process.exit(1) })
' 2>/dev/null)" || UI_COLLECTED=""
check "the live collector runs against a real home" \
  '[ -n "$UI_COLLECTED" ] && jq -e "has(\"repos\") and has(\"work\") and has(\"degraded\")" <<<"$UI_COLLECTED" >/dev/null'
check "the dockmaster-only store never reaches the page" \
  '! grep -q "DMONLY-crew-must-not-see" <<<"$UI_COLLECTED"'
# A degradation carries a source TOKEN and the panel that lost it - never a
# script name, its argv, or its stderr.
check "a degradation carries tokens, not script output" \
  'jq -e "all(.degraded[]; (has(\"error\")|not) and (.source|test(\"^[a-z_]+$\")) and (.panel|length > 0))" <<<"$UI_COLLECTED" >/dev/null'

# The page's own promises, pinned separately (track honesty + vocabulary), and
# the server's refusals over real HTTP (cross-site writes, bad input, traversal).
check "console checks pass"      'node "$ROOT/tests/check-console.js" >/dev/null 2>&1'
check "console http checks pass" 'node "$ROOT/tests/check-console-http.js" >/dev/null 2>&1'
check "console queue checks pass" 'node "$ROOT/tests/check-console-queue.js" >/dev/null 2>&1'

echo "== trash: an operator-authorized discard with recoverable backend cleanup =="
# The THIRD terminal path, and the one that was missing. Teardown is for work
# that LANDED; `dm-task.sh close` is for a task where nothing was BUILT (it
# refuses on any recorded local copy). Trash is built-but-discarded on the
# operator's word: the authority is recorded BEFORE anything is destroyed, the
# forced removal happens INSIDE the flow, and the recovery ref is VERIFIED
# rather than claimed.

# trash_task <id> [dirty] -> a task on its own branch with one commit. `dirty`
# also leaves an uncommitted tracked edit and one untracked file — the two
# things a discard genuinely cannot keep.
trash_task() {
  local id="$1" extra="${2:-}" wt
  b dm-task.sh new "$id" --kind ship --repo demo --title "trash probe $id" >/dev/null
  wt="$(b dm-worktree.sh create "$id" demo | tail -n1)"
  # -B and unique content: a REUSED id must survive the earlier discard's
  # leftover branch, and two same-second discards must not hash to one commit.
  git -C "$wt" checkout -q -B "work/$id"
  printf 'committed %s\n' "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" > "$wt/$id.txt"
  git -C "$wt" add -A >/dev/null
  git -C "$wt" commit -qm "work for $id" >/dev/null
  if [ "$extra" = dirty ]; then
    printf 'uncommitted\n' >> "$wt/src/calc.py"
    printf 'stray\n' > "$wt/$id-stray.txt"
  fi
  printf '%s\n' "$wt"
}

# --- the refusal matrix: every one of these must destroy nothing --------------
TRWT="$(trash_task tr-refuse)"
check "trash refuses without a reason"          '! b dm-trash.sh tr-refuse >/dev/null 2>&1'
check "trash refuses an empty reason"           '! b dm-trash.sh tr-refuse --reason "" >/dev/null 2>&1'
check "trash refuses a multi-line reason"       '! b dm-trash.sh tr-refuse --reason "$(printf "a\nb")" >/dev/null 2>&1'
check "trash refuses an unknown id"             '! b dm-trash.sh tr-no-such-task --reason "x" >/dev/null 2>&1'
check "trash refuses an unknown flag"           '! b dm-trash.sh tr-refuse --reason x --wat >/dev/null 2>&1'
check "trash refuses a second positional id"    '! b dm-trash.sh tr-refuse tr-other --reason x >/dev/null 2>&1'
check "no refusal touched the local copy"       '[ -d "$TRWT" ]'
check "no refusal recorded any authority"       '! grep -q "^trashed_" "$DM_HOME/state/tasks/tr-refuse.meta"'

b dm-task.sh new tr-terminal --kind ship --repo demo >/dev/null
b dm-task.sh close tr-terminal --reason "nothing to build" >/dev/null
TRTERM="$(b dm-trash.sh tr-terminal --reason "again" 2>&1 || true)"
check "trash refuses an already-terminal task"  'grep -q "already terminal" <<<"$TRTERM"'
check "that refusal names what does end such a task" \
  'grep -q "dm-task.sh archive tr-terminal" <<<"$TRTERM"'

# --- the open-PR guard: fail closed on anything not provably closed -----------
TRPRWT="$(trash_task tr-openpr)"
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-openpr pr "https://github.com/o/r/pull/41"
  dm_meta_set tr-openpr pr_state OPEN ) >/dev/null 2>&1
TROPEN="$(DM_NO_FETCH=1 b dm-trash.sh tr-openpr --reason "superseded" 2>&1 || true)"
check "trash refuses an open PR without --close-pr" 'grep -q "not closed" <<<"$TROPEN"'
check "that refusal names the flag that would close it" 'grep -q -- "--close-pr" <<<"$TROPEN"'
check "the open-PR refusal destroyed nothing"       '[ -d "$TRPRWT" ]'
check "the open-PR refusal recorded no authority"   '! grep -q "^trashed_" "$DM_HOME/state/tasks/tr-openpr.meta"'
# A CLOSED RECORD is not a closed PR: the refresh is best-effort, so a PR reopened
# since the last check would be trusted as closed and left open behind a discarded
# task. Only a live confirmation counts (offline here, so there is none).
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-openpr pr_state CLOSED ) >/dev/null 2>&1
TRCLOSED="$(DM_NO_FETCH=1 b dm-trash.sh tr-openpr --reason "superseded" 2>&1 || true)"
check "an unconfirmable CLOSED record still refuses" \
  'grep -q "could not be confirmed against GitHub" <<<"$TRCLOSED"'
check "that refusal also destroyed nothing"         '[ -d "$TRPRWT" ]'

# --- the full flow: cleanup, verified recovery, honest loss ------------------
TRFULLWT="$(trash_task tr-full dirty)"
TRHEAD="$(git -C "$TRFULLWT" rev-parse HEAD)"
TRREF="refs/dm-discarded/tr-full/$TRHEAD"
b dm-backlog.sh add tr-full "trash probe" --repo demo --status inflight >/dev/null
TROUT="$(b dm-trash.sh tr-full --reason "plan superseded" 2>/dev/null)"
check "trash removes the local copy"            '[ ! -d "$TRFULLWT" ]'
check "the discarded head is parked in the clone" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "$TRREF" || true)" = "$TRHEAD" ]'
check "the summary names the VERIFIED recovery ref" 'grep -qx "committed_work=$TRREF" <<<"$TROUT"'
TRRECOVER="$(sed -n 's/^recover_cmd=//p' <<<"$TROUT")"
[ -z "$TRRECOVER" ] || eval "$TRRECOVER" >/dev/null 2>&1 || true
check "the printed recovery command really recovers the commit" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet recovered-tr-full || true)" = "$TRHEAD" ]'
git -C "$DM_HOME/repos/demo" branch -D recovered-tr-full >/dev/null 2>&1 || true
check "uncommitted and untracked work is reported LOST, not kept" \
  'grep -qx "uncommitted_tracked=dirty" <<<"$TROUT" && grep -qx "untracked_paths=1" <<<"$TROUT" \
   && grep -qx "uncommitted=DISCARDED" <<<"$TROUT"'
check "every summary line is key=value, so a session can relay it" \
  '! grep -qvE "^[a-z_]+=" <<<"$TROUT"'
check "the records are archived, not left active" \
  '[ -f "$DM_HOME/state/archive/tr-full.meta" ] && [ ! -f "$DM_HOME/state/tasks/tr-full.meta" ]'
check "the archived record carries who, when and why" \
  'grep -q "^trashed_reason=plan superseded$" "$DM_HOME/state/archive/tr-full.meta" \
   && grep -q "^trashed_by=." "$DM_HOME/state/archive/tr-full.meta" \
   && grep -q "^trashed_at=20" "$DM_HOME/state/archive/tr-full.meta"'
check "the archived record carries the recovery snapshot" \
  'grep -q "^trashed_head=$TRHEAD$" "$DM_HOME/state/archive/tr-full.meta" \
   && grep -q "^trashed_branch=work/tr-full$" "$DM_HOME/state/archive/tr-full.meta" \
   && grep -q "^trashed_tracked=dirty$" "$DM_HOME/state/archive/tr-full.meta" \
   && grep -q "^trashed_untracked=1$" "$DM_HOME/state/archive/tr-full.meta"'
check "the authority is logged BEFORE the discard, not after" \
  '[ "$(grep -n " trashed: " "$DM_HOME/state/archive/tr-full.status" | head -1 | cut -d: -f1)" -lt \
     "$(grep -n " discarded: " "$DM_HOME/state/archive/tr-full.status" | head -1 | cut -d: -f1)" ]'
check "trash never claims the work landed" \
  '! grep -qE "^[^ ]+ merged: " "$DM_HOME/state/archive/tr-full.status"'
check "the backlog row is resolved with the reason" \
  'b dm-backlog.sh list --json \
   | jq -e --arg id tr-full "any(.items[]; .id==\$id and .status==\"done\" and (.note|startswith(\"trashed: plan superseded\")))" >/dev/null'
# The verdict is READ OUT of the ref namespace, so every ref that exists for the
# id is reported whatever the verdict says.
check "every recovery ref that exists is listed" \
  'grep -qx "parked_ref=$TRHEAD $TRREF" <<<"$TROUT"'

# A clean local copy must not raise the alarm the dirty one does.
TRCLEANWT="$(trash_task tr-clean)"
TRCLEAN="$(b dm-trash.sh tr-clean --reason "clean discard" 2>/dev/null)"
check "a clean discard reports nothing lost, not a false alarm" \
  'grep -qx "uncommitted=none" <<<"$TRCLEAN" && grep -qx "untracked_paths=0" <<<"$TRCLEAN" \
   && grep -qx "uncommitted_tracked=clean" <<<"$TRCLEAN"'

# Commits already in the base need no parked ref, and must not be alarmed about.
b dm-task.sh new tr-inbase --kind ship --repo demo >/dev/null
b dm-worktree.sh create tr-inbase demo >/dev/null
TRINBASE="$(b dm-trash.sh tr-inbase --reason "nothing to keep" 2>"$TMP/tr-inbase.err")"
check "work already in the base is said so, not alarmed about" \
  'grep -qx "committed_work=already-in-base" <<<"$TRINBASE"'
check "and no NOT-PRESERVED alarm is raised for it" \
  '! grep -q "NOT on a recovery ref" "$TMP/tr-inbase.err"'

# An id git cannot spell verbatim: the ref path, the printed rescue branch name
# and the ref that really exists must all agree, or the operator's only route
# back is a command that fails.
TRODDWT="$(trash_task tr.odd.id)"
TRODDHEAD="$(git -C "$TRODDWT" rev-parse HEAD)"
TRODD="$(b dm-trash.sh tr.odd.id --reason "odd id" 2>/dev/null)"
check "an odd id parks under a sanitized ref path" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/tr_odd_id/$TRODDHEAD" || true)" = "$TRODDHEAD" ]'
check "the summary names that same sanitized ref" \
  'grep -qx "committed_work=refs/dm-discarded/tr_odd_id/$TRODDHEAD" <<<"$TRODD"'
check "the printed rescue command is a legal branch name" \
  'TRODDCMD="$(sed -n "s/^recover_cmd=//p" <<<"$TRODD")"; eval "$TRODDCMD" >/dev/null 2>&1 \
   && [ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet recovered-tr_odd_id || true)" = "$TRODDHEAD" ]'
git -C "$DM_HOME/repos/demo" branch -D recovered-tr_odd_id >/dev/null 2>&1 || true
check "the emitted path is quoted, so a spaced path survives it" \
  'grep -q "^recover_cmd=git -C .[^ ]*repos/demo. branch " <<<"$TRODD"'

# A local copy whose head cannot be read ANYWHERE is never an all-clear:
# nothing-committed is reserved for a task that never had one.
TRUNWT="$(trash_task tr-undet)"
rm -f "$TRUNWT/.git"
rm -rf "$DM_HOME/repos/demo/.git/worktrees/tr-undet"
TRUNDET="$(b dm-trash.sh tr-undet --reason "dropped" 2>"$TMP/tr-undet.err")"
check "an undeterminable head is UNDETERMINED, never nothing-committed" \
  'grep -qx "committed_work=UNDETERMINED" <<<"$TRUNDET" \
   && ! grep -q "nothing-committed" <<<"$TRUNDET"'
check "and it says so on stderr too" \
  'grep -q "head could not be determined" "$TMP/tr-undet.err"'

# A broken `.git` file in the local copy is NOT "no commit": git's own admin
# record still names the head, and the commit must still be preserved.
TRADMWT="$(trash_task tr-admin)"
TRADMHEAD="$(git -C "$TRADMWT" rev-parse HEAD)"
rm -f "$TRADMWT/.git"
TRADM="$(b dm-trash.sh tr-admin --reason "dropped" 2>"$TMP/tr-admin.err")"
check "an unreadable local HEAD falls back to git's admin record" \
  'grep -qx "head=$TRADMHEAD" <<<"$TRADM"'
check "and the commit is really parked, not written off" \
  'grep -qx "committed_work=refs/dm-discarded/tr-admin/$TRADMHEAD" <<<"$TRADM" \
   && [ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/tr-admin/$TRADMHEAD" || true)" = "$TRADMHEAD" ]'
check "the commit survives an aggressive gc" \
  'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; \
   git -C "$DM_HOME/repos/demo" cat-file -e "$TRADMHEAD^{commit}"'

# --- a REUSED id must never inherit an earlier discard's commit --------------
# refs/dm-discarded/* is keyed by sha exactly so reusing an id cannot clobber the
# first discard. That means the namespace can hold refs from a PREVIOUS task of
# the same name, and with no head to tie a ref to this run, naming one would hand
# the operator someone else's commit while the one actually at risk goes
# unmentioned. Both shapes below were reproduced.
TRRWT="$(trash_task tr-reuse)"
TRRSHA1="$(git -C "$TRRWT" rev-parse HEAD)"
b dm-trash.sh tr-reuse --reason "first discard" >/dev/null 2>&1
check "the first discard of a reusable id is parked" \
  '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/tr-reuse/$TRRSHA1" || true)" = "$TRRSHA1" ]'
# Second task, same id, never dispatched: nothing was built, so nothing can be
# recoverable — least of all the previous task's commit.
b dm-task.sh new tr-reuse --kind ship --repo demo --title "reused id" >/dev/null
TRREUSE="$(b dm-trash.sh tr-reuse --reason "nothing built this time" 2>/dev/null)"
check "a reused id with nothing built reports nothing-committed" \
  'grep -qx "committed_work=nothing-committed" <<<"$TRREUSE"'
check "it never names the earlier discard as this task's work" \
  '! grep -q "committed_work=refs/dm-discarded/tr-reuse/$TRRSHA1" <<<"$TRREUSE" \
   && ! grep -q "^recover_cmd=" <<<"$TRREUSE"'
check "the inherited ref is still LISTED, just not claimed" \
  'grep -qx "parked_ref=$TRRSHA1 refs/dm-discarded/tr-reuse/$TRRSHA1" <<<"$TRREUSE"'

# Same reuse, but the second task DID build and its head cannot be read: the
# verdict must be UNDETERMINED and must not offer the earlier sha as the rescue.
TRR2WT="$(trash_task tr-reuse2)"
TRR2SHA1="$(git -C "$TRR2WT" rev-parse HEAD)"
b dm-trash.sh tr-reuse2 --reason "first discard" >/dev/null 2>&1
TRR2WT2="$(trash_task tr-reuse2)"
TRR2SHA2="$(git -C "$TRR2WT2" rev-parse HEAD)"
rm -f "$TRR2WT2/.git"
rm -rf "$DM_HOME/repos/demo/.git/worktrees/tr-reuse2"
TRREUSE2="$(b dm-trash.sh tr-reuse2 --reason "second discard" 2>"$TMP/tr-reuse2.err")"
check "a reused id with an unreadable head is UNDETERMINED" \
  'grep -qx "committed_work=UNDETERMINED" <<<"$TRREUSE2"'
check "it offers no rescue command at all" '! grep -q "^recover_cmd=" <<<"$TRREUSE2"'
check "and never presents the earlier sha as this run's work" \
  '! grep -q "committed_work=.*$TRR2SHA1" <<<"$TRREUSE2"'
check "the warning says the refs found are an earlier discard's" \
  'grep -q "EARLIER discard of this reusable id" "$TMP/tr-reuse2.err"'
check "the two discards are genuinely different commits" '[ "$TRR2SHA1" != "$TRR2SHA2" ]'

# --- a directory this run never saw is not a clean bill of health ------------
# The vanished-local-copy branch can read nothing about the TREE, so reporting
# uncommitted=none there would be a definite all-clear over work that may well
# have been dirty.
TRGDWT="$(trash_task tr-ghost-dirty dirty)"
rm -rf "$TRGDWT"
TRGDIRTY="$(b dm-trash.sh tr-ghost-dirty --reason "worker died" 2>/dev/null)"
check "a vanished local copy never reports uncommitted=none" \
  '! grep -qx "uncommitted=none" <<<"$TRGDIRTY"'
check "it reports the tree as undetermined, in every field" \
  'grep -qx "uncommitted=undetermined" <<<"$TRGDIRTY" \
   && grep -qx "uncommitted_tracked=undetermined" <<<"$TRGDIRTY" \
   && grep -qx "untracked_paths=undetermined" <<<"$TRGDIRTY"'

# The worker signal is reported, never acted on: stopping an agent is the
# session's job, and this command cannot do it.
TRWKWT="$(trash_task tr-worker)"
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-worker agent_id agent-smoke-1 ) >/dev/null 2>&1
TRWORKER="$(b dm-trash.sh tr-worker --reason "dropped" 2>"$TMP/tr-worker.err")"
check "a recorded worker is reported in the summary"  'grep -qx "worker=RUNNING" <<<"$TRWORKER"'
check "and warned about on stderr"                    'grep -q "STOP THE WORKER FIRST" "$TMP/tr-worker.err"'
check "but it never blocks the discard"               'grep -qx "records=archived" <<<"$TRWORKER"'
TRWK2WT="$(trash_task tr-worker-failed)"
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-worker-failed agent_id agent-smoke-2 ) >/dev/null 2>&1
b dm-task.sh event tr-worker-failed failed "gave up" >/dev/null
TRWORKER2="$(b dm-trash.sh tr-worker-failed --reason "dropped" 2>/dev/null)"
check "a worker that reported failure is not called running" \
  '! grep -q "^worker=" <<<"$TRWORKER2"'

# A task nobody ever dispatched has nothing built; trash still ends it, and says
# so rather than implying a commit was preserved.
b dm-task.sh new tr-nowt --kind ship --repo demo --title "never dispatched" >/dev/null
TRNOWT="$(b dm-trash.sh tr-nowt --reason "intent deprecated" 2>/dev/null)"
check "a task with no local copy still reaches terminal" \
  'grep -qx "state=discarded" <<<"$TRNOWT" && grep -qx "local_copy=absent" <<<"$TRNOWT"'
check "nothing committed is said plainly, never as recoverable" \
  'grep -qx "committed_work=nothing-committed" <<<"$TRNOWT" && grep -qx "uncommitted=none" <<<"$TRNOWT"'

# The interrupted-cleanup shape: the directory is already gone, so the head can
# only come from git's own admin record. Reading it there is what lets the
# summary report the work recoverable instead of silently under-claiming.
TRGWT="$(trash_task tr-ghost)"
TRGHEAD="$(git -C "$TRGWT" rev-parse HEAD)"
rm -rf "$TRGWT"
TRGOUT="$(b dm-trash.sh tr-ghost --reason "worker died, plan dropped" 2>/dev/null)"
check "a vanished local copy's head still comes from git's own record" \
  'grep -qx "head=$TRGHEAD" <<<"$TRGOUT"'
check "and it is parked, so the recovery claim is true" \
  'grep -qx "committed_work=refs/dm-discarded/tr-ghost/$TRGHEAD" <<<"$TRGOUT" \
   && [ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/tr-ghost/$TRGHEAD" || true)" = "$TRGHEAD" ]'

# --- a step that fails mid-flow must stop it, and stay readable --------------
# The removal is made to refuse the root-proof way: point the record at a copy
# outside the managed path, which dm-worktree.sh refuses before deleting.
TRHALTWT="$(trash_task tr-halt)"
TRHALTHEAD="$(git -C "$TRHALTWT" rev-parse HEAD)"
cp -R "$TRHALTWT" "$TMP/tr-halt-elsewhere"
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-halt worktree "$TMP/tr-halt-elsewhere" ) >/dev/null 2>&1
TRHALT="$(b dm-trash.sh tr-halt --reason "dropped" 2>&1 || true)"
check "a removal that cannot proceed stops the whole flow" 'grep -q "could not remove" <<<"$TRHALT"'
check "the halted trash archived nothing" \
  '[ ! -f "$DM_HOME/state/archive/tr-halt.meta" ] && [ -f "$DM_HOME/state/tasks/tr-halt.meta" ]'
check "the halted trash reconciles as LIVE, never as finished" \
  'grep -q "^state: working" <<<"$(DM_NO_FETCH=1 b dm-task.sh state tr-halt)"'
check "the halted trash still recorded its authority and snapshot" \
  'grep -q "^trashed_reason=dropped$" "$DM_HOME/state/tasks/tr-halt.meta" \
   && grep -q "^trashed_head=$TRHALTHEAD$" "$DM_HOME/state/tasks/tr-halt.meta"'
# Retry with the record restored, but the worktree's git link broken: the head is
# now unreadable, so the snapshot from the first attempt is what must be reported
# — and recoverability must be reported as NOT preserved, loudly, not assumed.
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set tr-halt worktree "$TRHALTWT" ) >/dev/null 2>&1
# Both routes to the head are destroyed — the in-worktree `.git` AND the clone's
# admin record — because either one alone is now enough to preserve the commit.
rm -f "$TRHALTWT/.git"
rm -rf "$DM_HOME/repos/demo/.git/worktrees/tr-halt"
TRHALT2="$(b dm-trash.sh tr-halt --reason "dropped" 2>"$TMP/tr-halt2.err")" || true
check "a retry completes the trash"            'grep -qx "records=archived" <<<"$TRHALT2"'
check "the retry reports the head the first attempt recorded" \
  'grep -qx "head=$TRHALTHEAD" <<<"$TRHALT2"'
check "an unparkable head is reported NOT PRESERVED, never as recoverable" \
  'grep -qx "committed_work=NOT-PRESERVED" <<<"$TRHALT2" && ! grep -q "^recover_cmd=" <<<"$TRHALT2"'
check "the warning names the commit and how to save it now" \
  'grep -q "NOT on a recovery ref" "$TMP/tr-halt2.err" \
   && grep -q "branch recovered-tr-halt $TRHALTHEAD" "$TMP/tr-halt2.err"'
rm -rf "$TMP/tr-halt-elsewhere"

# A bookkeeping step failing AFTER the deletion cannot be hidden: the task is
# terminal (so reconcile is truthful) and the refusal names what is left to do.
TRAWT="$(trash_task tr-archfail)"
mkdir -p "$DM_HOME/state/archive"
mv "$DM_HOME/state/archive" "$TMP/tr-archive-aside"
printf 'not a directory\n' > "$DM_HOME/state/archive"
TRARCH="$(b dm-trash.sh tr-archfail --reason "dropped" 2>&1 || true)"
rm -f "$DM_HOME/state/archive"
mv "$TMP/tr-archive-aside" "$DM_HOME/state/archive"
check "a failed archive is never swallowed"     'grep -q "could not archive" <<<"$TRARCH"'
check "it names the two commands that finish the job" \
  'grep -q "dm-backlog.sh done tr-archfail" <<<"$TRARCH" \
   && grep -q "dm-task.sh archive tr-archfail" <<<"$TRARCH"'
check "the half-finished trash is terminal, not healthy-looking" \
  'grep -q "^state: discarded" <<<"$(DM_NO_FETCH=1 b dm-task.sh state tr-archfail)"'
check "and its local copy really is gone"       '[ ! -d "$TRAWT" ]'
b dm-task.sh archive tr-archfail >/dev/null
check "the commands it named do finish the job"  '[ -f "$DM_HOME/state/archive/tr-archfail.meta" ]'

# The other route out of that state: re-running the command. A trash killed after
# the discard but before the bookkeeping would otherwise leave a task every
# command refuses as terminal — so it RESUMES its own unfinished work, and only
# the tail is left to run.
TRRESWT="$(trash_task tr-resume)"
TRRESHEAD="$(git -C "$TRRESWT" rev-parse HEAD)"
mkdir -p "$DM_HOME/state/archive"
mv "$DM_HOME/state/archive" "$TMP/tr-resume-aside"
printf 'not a directory\n' > "$DM_HOME/state/archive"
b dm-trash.sh tr-resume --reason "first attempt" >/dev/null 2>&1 || true
rm -f "$DM_HOME/state/archive"
mv "$TMP/tr-resume-aside" "$DM_HOME/state/archive"
check "the killed trash left the task terminal with its authority recorded" \
  'grep -q "^state: discarded" <<<"$(DM_NO_FETCH=1 b dm-task.sh state tr-resume)" \
   && grep -q "^trashed_reason=first attempt$" "$DM_HOME/state/tasks/tr-resume.meta"'
TRRESUME="$(b dm-trash.sh tr-resume --reason "second attempt" 2>"$TMP/tr-resume.err")"
check "re-running it resumes instead of refusing as terminal" \
  'grep -qx "records=archived" <<<"$TRRESUME" && [ -f "$DM_HOME/state/archive/tr-resume.meta" ]'
check "the resumed run keeps the ORIGINAL recorded authority" \
  'grep -qx "reason=first attempt" <<<"$TRRESUME" \
   && grep -q "already discarded on the recorded authority" "$TMP/tr-resume.err"'
check "it says the local copy went earlier, not that there never was one" \
  'grep -qx "local_copy=removed-earlier" <<<"$TRRESUME" \
   && ! grep -q "committed_work=nothing-committed" <<<"$TRRESUME"'
check "and it still reports the verified recovery ref" \
  'grep -qx "committed_work=refs/dm-discarded/tr-resume/$TRRESHEAD" <<<"$TRRESUME"'
check "the resumed run appended no second authority line" \
  '[ "$(grep -c " trashed: " "$DM_HOME/state/archive/tr-resume.status")" = 1 ]'
# A task that is terminal but was NOT discarded by this flow has nothing to
# resume, so it stays refused.
b dm-task.sh new tr-notmine --kind ship --repo demo >/dev/null
b dm-task.sh close tr-notmine --reason "nothing to build" >/dev/null
TRNOTMINE="$(b dm-trash.sh tr-notmine --reason "x" 2>&1 || true)"
check "a terminal task this flow did not discard stays refused" \
  'grep -q "was not discarded by this flow" <<<"$TRNOTMINE"'

# The same shape one step earlier, and fail-CLOSED: a backlog that cannot be read
# must never pass for "no row to resolve" and let the flow report a clean finish.
TRBWT="$(trash_task tr-backlogfail)"
cp "$DM_HOME/state/backlog.json" "$TMP/tr-backlog-good.json"
printf 'not json\n' > "$DM_HOME/state/backlog.json"
TRBOUT="$(b dm-trash.sh tr-backlogfail --reason "dropped" 2>&1 || true)"
cp "$TMP/tr-backlog-good.json" "$DM_HOME/state/backlog.json"
check "an unreadable backlog is never read as an absent row" \
  'grep -q "backlog could not be read" <<<"$TRBOUT"'
check "it says the records were NOT archived" \
  'grep -q "records were not archived" <<<"$TRBOUT" && [ ! -f "$DM_HOME/state/archive/tr-backlogfail.meta" ]'
check "and that task is terminal too, never live-looking" \
  'grep -q "^state: discarded" <<<"$(DM_NO_FETCH=1 b dm-task.sh state tr-backlogfail)"'
check "its local copy is gone as well"          '[ ! -d "$TRBWT" ]'
b dm-task.sh archive tr-backlogfail >/dev/null

b dm-task.sh new tr-verb --kind ship --repo demo >/dev/null
check "a crewmate cannot log a trash itself" \
  '! b dm-task.sh event tr-verb trashed "forged" >/dev/null 2>&1'
# A flag with nothing to do says so — on stderr, because stdout is the relayable
# record and every line of it is key=value.
TRNOPRWT="$(trash_task tr-nopr)"
TRNOPR="$(b dm-trash.sh tr-nopr --reason "dropped" --close-pr 2>"$TMP/tr-nopr.err")"
check "--close-pr with no PR is noted, not silently ignored" \
  'grep -q "close-pr had nothing to do" "$TMP/tr-nopr.err" && grep -qx "pr=none" <<<"$TRNOPR"'
check "that note never lands on the relayable stdout" \
  '! grep -qvE "^[a-z_]+=" <<<"$TRNOPR"'
check "the dispatcher lists trash with a purpose" \
  'grep -qE "^  trash +[A-Za-z]" <<<"$(b dm help)"'

# --- trashing a task must resolve the decision holds IT raised ---------------
# The operator's real complaint: dm-trash discarded work but "needs you" kept
# showing decisions filed against it. Both filing conventions from the
# decision-hold skill are covered: key-prefixed (<id>-decision-<key>) and
# origin-referenced (an origin path under data/<id>/).
TRHOLDWT="$(trash_task tr-holds)"
b dm-backlog.sh hold tr-holds-decision-angle "pick an angle" --options "A | B" >/dev/null
b dm-backlog.sh hold review-tr-holds "approve the change" --origin "data/tr-holds/report.md" >/dev/null
b dm-backlog.sh hold other-task-decision-unrelated "not this task" >/dev/null
TRHOLDOUT="$(b dm-trash.sh tr-holds --reason "plan dropped" 2>/dev/null)"
check "trash resolves the key-prefixed hold"      'grep -qx "resolved_hold=tr-holds-decision-angle" <<<"$TRHOLDOUT"'
check "trash resolves the origin-referenced hold" 'grep -qx "resolved_hold=review-tr-holds" <<<"$TRHOLDOUT"'
check "trash leaves an unrelated hold alone"       '! grep -q "resolved_hold=other-task-decision-unrelated" <<<"$TRHOLDOUT"'
check "the resolution is recorded as DROPPED, not answered" \
  'b dm-backlog.sh decisions --json \
   | jq -e "any(.[]; .key==\"tr-holds-decision-angle\" and .status==\"resolved\" and (.answer|startswith(\"trashed: plan dropped\")))" >/dev/null \
   && b dm-backlog.sh decisions --json \
   | jq -e "any(.[]; .key==\"review-tr-holds\" and .status==\"resolved\" and (.answer|startswith(\"trashed:\")))" >/dev/null'
check "the unrelated hold is untouched, still open" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; .key==\"other-task-decision-unrelated\" and .status==\"open\")" >/dev/null'

# The "no holds" case, on a run that actually went through this trash and this
# section — not a reuse of an unrelated earlier $TROUT capture (that task never
# had a hold filed against it at all, so its absence of resolved_hold lines
# would hold even with resolve_decision_holds deleted outright).
TRNONEWT="$(trash_task tr-holds-none)"
TRNONEOUT="$(b dm-trash.sh tr-holds-none --reason "plan dropped" 2>/dev/null)"
check "a task with no holds emits no resolved_hold noise" \
  '! grep -q "^resolved_hold=" <<<"$TRNONEOUT"'
check "a task with no holds emits no unresolved_hold noise either" \
  '! grep -q "^unresolved_hold=" <<<"$TRNONEOUT"'

# --- the matcher's own boundaries: near-misses must stay open, not caught ----
# The matcher is deliberately stricter than a bare substring: a hold keyed
# "<id>-decisionfoo" (no separating hyphen after "decision") does not match the
# <id>-decision- prefix, and an origin under a SIBLING path ("<id>-other")
# does not contain "data/<id>/". Both are known gaps (documented in
# .dm-knowledge/dm-trash-hold-cleanup.md), not bugs — pin them so a widened
# matcher would be a deliberate, reviewed change, not an accidental drift.
TRBOUNDWT="$(trash_task tr-boundary)"
b dm-backlog.sh hold tr-boundary-decisionfoo "near miss on the key" >/dev/null
b dm-backlog.sh hold boundary-review "near miss on the origin" --origin "data/tr-boundary-other/x.md" >/dev/null
TRBOUNDOUT="$(b dm-trash.sh tr-boundary --reason "plan dropped" 2>/dev/null)"
check "a key-near-miss (no separating hyphen) is not touched" \
  '! grep -q "resolved_hold=tr-boundary-decisionfoo" <<<"$TRBOUNDOUT"'
check "an origin-near-miss (sibling path) is not touched" \
  '! grep -q "resolved_hold=boundary-review" <<<"$TRBOUNDOUT"'
check "the key-near-miss hold is still open after trashing" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; .key==\"tr-boundary-decisionfoo\" and .status==\"open\")" >/dev/null'
check "the origin-near-miss hold is still open after trashing" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; .key==\"boundary-review\" and .status==\"open\")" >/dev/null'

# --- a newline-bearing key must not smuggle a second, unrelated key ---------
# hold never validates its key argument, so a caller (or a bug upstream) can
# hand it a key with an embedded newline. jq -r would emit that as two lines,
# and the naive `while read` loop would treat the second line as its own key
# — silently resolving an unrelated open hold while leaving the malformed one
# (and the real task hold) untouched. The fix excludes any key containing a
# newline before the match; it must stay open, and so must the victim.
TRNLWT="$(trash_task tr-nlkey)"
b dm-backlog.sh hold "victim-decision-key" "an unrelated hold that must not be touched" >/dev/null
b dm-backlog.sh hold "$(printf 'tr-nlkey-decision-p\nvictim-decision-key')" "malformed multi-line key" >/dev/null
TRNLOUT="$(b dm-trash.sh tr-nlkey --reason "plan dropped" 2>/dev/null)"
check "the unrelated victim hold is not reported resolved" \
  '! grep -q "resolved_hold=victim-decision-key" <<<"$TRNLOUT"'
check "the unrelated victim hold is still open after trashing" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; .key==\"victim-decision-key\" and .status==\"open\")" >/dev/null'
check "the malformed multi-line hold is still open after trashing" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; (.key|contains(\"tr-nlkey-decision-p\")) and .status==\"open\")" >/dev/null'

# --- a hold that fails to resolve must still surface on stdout --------------
# stdout is THE relayable key=value record; a resolve failure must not be
# stderr-only. Force exactly one resolve call to fail with a throwaway copy of
# the toolbelt whose dm-backlog.sh refuses one specific key and delegates
# every other command, unmodified, to the real script — no shared file is
# touched, so this cannot race a concurrent shard.
TRFAILBIN="$TMP/tr-fail-bin"
mkdir -p "$TRFAILBIN"
for f in "$ROOT"/bin/*.sh; do ln -sf "$f" "$TRFAILBIN/$(basename "$f")"; done
[ -f "$ROOT/bin/dm" ] && ln -sf "$ROOT/bin/dm" "$TRFAILBIN/dm"
rm -f "$TRFAILBIN/dm-backlog.sh"
cat > "$TRFAILBIN/dm-backlog.sh" <<TRFAILWRAP
#!/usr/bin/env bash
# test-only stub: fail exactly one resolve call, delegate everything else
if [ "\${1:-}" = "resolve" ] && [ "\${2:-}" = "tr-holdfail-decision-x" ]; then
  echo "simulated resolve failure for tr-holdfail-decision-x" >&2
  exit 1
fi
exec "$ROOT/bin/dm-backlog.sh" "\$@"
TRFAILWRAP
chmod +x "$TRFAILBIN/dm-backlog.sh"
TRHOLDFAILWT="$(trash_task tr-holdfail)"
b dm-backlog.sh hold tr-holdfail-decision-x "pick one" >/dev/null
TRHOLDFAILOUT="$("$TRFAILBIN/dm-trash.sh" tr-holdfail --reason "dropped" 2>"$TMP/tr-holdfail.err")"
check "a resolve failure is reported on stdout, not only stderr" \
  'grep -qx "unresolved_hold=tr-holdfail-decision-x" <<<"$TRHOLDFAILOUT"'
check "a resolve failure is also warned on stderr, with the fix-by-hand command" \
  'grep -q "could not resolve.*tr-holdfail-decision-x" "$TMP/tr-holdfail.err" \
   && grep -q "dm-backlog.sh resolve tr-holdfail-decision-x" "$TMP/tr-holdfail.err"'
check "the failed hold is never also reported resolved" \
  '! grep -q "^resolved_hold=tr-holdfail-decision-x" <<<"$TRHOLDFAILOUT"'
check "bookkeeping still finishes (records archived) despite the resolve failure" \
  'grep -qx "records=archived" <<<"$TRHOLDFAILOUT"'

# A resume must not re-touch a hold this flow already resolved: kill the flow
# after bookkeeping resolves the hold but before it archives (same trick as
# tr-resume above), then re-run and confirm no duplicate and no error.
TRHOLD2WT="$(trash_task tr-holds2)"
b dm-backlog.sh hold tr-holds2-decision-x "pick one" >/dev/null
mkdir -p "$DM_HOME/state/archive"
mv "$DM_HOME/state/archive" "$TMP/tr-holds2-archive-aside"
printf 'not a directory\n' > "$DM_HOME/state/archive"
b dm-trash.sh tr-holds2 --reason "first attempt" >/dev/null 2>&1 || true
rm -f "$DM_HOME/state/archive"
mv "$TMP/tr-holds2-archive-aside" "$DM_HOME/state/archive"
check "the interrupted trash already resolved the hold" \
  'b dm-backlog.sh decisions --json | jq -e "any(.[]; .key==\"tr-holds2-decision-x\" and .status==\"resolved\")" >/dev/null'
TRHOLD2RESUME="$(b dm-trash.sh tr-holds2 --reason "second attempt" 2>"$TMP/tr-holds2.err")"
check "the resumed run does not re-report an already-resolved hold" \
  '! grep -q "^resolved_hold=" <<<"$TRHOLD2RESUME"'
check "and resuming raises no resolve failure"  '! grep -qi "could not resolve" "$TMP/tr-holds2.err"'

echo "== trash with a PR: closed unmerged, never merged, branch left alone =="
# The PR half needs GitHub, so it runs against a stub gh and a clone whose origin
# looks like a GitHub slug. gh-axi is filtered off PATH so the argv shape under
# test is the one plain gh gets.
# Its own bare origin: this block rewrites the clone's origin url to a
# GitHub-looking slug and pushes branches, neither of which should reach the
# shared fixture origin every other case reads.
git init -q --bare -b main "$TMP/trashpr-origin.git"
git -C "$TMP/seed" push -q "$TMP/trashpr-origin.git" main
b dm-repo.sh add trashpr "$TMP/trashpr-origin.git" --mode pipeline --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/trashpr" remote set-url origin o/r.git
TRSTUB="$TMP/trash-ghstub"; mkdir -p "$TRSTUB"
# The stub is per-PR and MODELS the close: a real refresh after a close reports
# `closed`, and `remove --force` does refresh on its way through, so a stub stuck
# on "open" would overwrite the recorded state and hide it from the assertion.
cat > "$TRSTUB/gh" <<STUB
#!/bin/sh
D="$TRSTUB"
printf '%s\n' "\$*" >> "\$D/calls"
n="\$(printf '%s' "\$*" | sed -n 's#.*pulls/\([0-9][0-9]*\).*#\1#p')"
case "\$*" in
  *check-runs*) printf '{"total_count":0,"check_runs":[]}\n'; exit 0 ;;
  *commits*status*) printf '{"total_count":0}\n'; exit 0 ;;
  *"--method POST"*) [ -f "\$D/comment-fail" ] && exit 1; exit 0 ;;
  *"--method PATCH"*)
    sed 's/"state":"open"/"state":"closed"/' "\$D/pr-\$n.json" > "\$D/pr-\$n.tmp" \
      && mv "\$D/pr-\$n.tmp" "\$D/pr-\$n.json"
    exit 0 ;;
esac
cat "\$D/pr-\$n.json"
STUB
chmod +x "$TRSTUB/gh"
tr_stub_pr() {
  printf '{"state":"open","merged":false,"head":{"sha":"abc123","ref":"work/%s","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' \
    "$2" > "$TRSTUB/pr-$1.json"
}
tr_stub_pr 41 tr-pr
tr_stub_pr 42 tr-pr-silent

# pr_trash_task <id> <pr-number> -> a task with a pushed branch and a recorded
# PR whose state is DELIBERATELY unrecorded: "not provably closed" must be
# treated as open.
pr_trash_task() {
  local id="$1" n="$2" wt
  b dm-task.sh new "$id" --kind ship --repo trashpr >/dev/null
  wt="$(b dm-worktree.sh create "$id" trashpr | tail -n1)"
  git -C "$wt" checkout -q -b "work/$id"
  printf 'x\n' > "$wt/$id.txt"
  git -C "$wt" add -A >/dev/null
  git -C "$wt" commit -qm "work for $id" >/dev/null
  git -C "$wt" push -q "$TMP/trashpr-origin.git" "work/$id"
  ( . "$ROOT/bin/dm-lib.sh"; dm_meta_set "$id" pr "https://github.com/o/r/pull/$n" ) >/dev/null 2>&1
  printf '%s\n' "$wt"
}
TRPRWT2="$(pr_trash_task tr-pr 41)"
check "close refuses without a reason" \
  '! PATH="$TRSTUB:$NOAXI_PATH" b dm-pr.sh close tr-pr >/dev/null 2>&1'
check "close refuses a task with no PR recorded" \
  '! PATH="$TRSTUB:$NOAXI_PATH" b dm-pr.sh close tr-verb --reason x >/dev/null 2>&1'
check "trash refuses a PR whose state it could not confirm closed" \
  '! DM_NO_FETCH=1 b dm-trash.sh tr-pr --reason "x" >/dev/null 2>&1'
TRPROUT="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr --reason "plan superseded" --close-pr 2>&1)"
check "the PR is closed as part of the flow"    'grep -qx "pr=closed" <<<"$TRPROUT"'
check "the reason was commented BEFORE the close" \
  '[ "$(grep -n "issues/41/comments" "$TRSTUB/calls" | head -1 | cut -d: -f1)" -lt \
     "$(grep -n "PATCH /repos/o/r/pulls/41" "$TRSTUB/calls" | head -1 | cut -d: -f1)" ]'
check "the comment carries the reason"          'grep -q "plan superseded" "$TRSTUB/calls"'
check "closing never merges"                    '! grep -q "pulls/41/merge" "$TRSTUB/calls"'
check "the PR branch is left at origin, never deleted" \
  'git -C "$TMP/trashpr-origin.git" rev-parse --verify --quiet refs/heads/work/tr-pr >/dev/null'
check "the closed state is recorded on the task" \
  'grep -q "^pr_state=CLOSED$" "$DM_HOME/state/archive/tr-pr.meta"'
check "the local copy went with it"             '[ ! -d "$TRPRWT2" ]'
# A comment that cannot be posted must leave the PR OPEN and stop the flow: a PR
# closed with no stated reason is the artifact the comment-first order prevents.
: > "$TRSTUB/comment-fail"
TRPRWT3="$(pr_trash_task tr-pr-silent 42)"
TRPRFAIL="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-silent --reason "dropped" --close-pr 2>&1 || true)"
rm -f "$TRSTUB/comment-fail"
check "a failed comment leaves the PR open and halts the trash" \
  'grep -q "could not comment" <<<"$TRPRFAIL" && grep -q "leaving it OPEN" <<<"$TRPRFAIL"'
check "no PATCH closed it anyway"               '! grep -q "PATCH /repos/o/r/pulls/42" "$TRSTUB/calls"'
check "and the local copy survived the halt"    '[ -d "$TRPRWT3" ]'
PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-silent --reason "dropped" --close-pr >/dev/null 2>&1 || true
check "the retry closes it once commenting works" 'grep -q "PATCH /repos/o/r/pulls/42" "$TRSTUB/calls"'
# Closing is not a way to walk back a merge: GitHub accepts state=closed on a
# merged PR without complaint, which would record abandoned work over a change
# that landed.
pr_trash_task tr-pr-merged 43 >/dev/null
printf '{"state":"closed","merged":true,"head":{"sha":"abc123","ref":"work/tr-pr-merged","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$TRSTUB/pr-43.json"
: > "$TRSTUB/calls"
TRMERGED="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-pr.sh close tr-pr-merged --reason "trashed" 2>&1 || true)"
check "close refuses a merged PR"                'grep -q "already MERGED" <<<"$TRMERGED"'
check "it routes the caller to rollback"         'grep -q "rollback skill" <<<"$TRMERGED"'
check "and issues no close mutation at all"      '! grep -q "PATCH /repos/o/r/pulls/43" "$TRSTUB/calls"'
check "the merged state stays on the record"     '[ "$(b dm-task.sh get tr-pr-merged pr_state)" = "MERGED" ]'
check "trash refuses that task too, naming rollback" \
  'TRM2="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-merged --reason x --close-pr 2>&1 || true)"; \
   grep -q "rollback skill" <<<"$TRM2"'
# A second close is not an error: the flow may run over a PR someone already
# closed, and that must not fail the trash. (A fresh task — the ones above are
# archived by their own trash.)
pr_trash_task tr-pr-again 44 >/dev/null
printf '{"state":"closed","merged":false,"head":{"sha":"abc123","ref":"work/tr-pr-again","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$TRSTUB/pr-44.json"
: > "$TRSTUB/calls"
check "closing an already-closed PR exits 0 and says so" \
  'TRRE="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-pr.sh close tr-pr-again --reason "again" 2>&1)"; grep -q "already closed" <<<"$TRRE"'
check "and it issues no close mutation for it"     '! grep -q "PATCH" "$TRSTUB/calls"'
check "close refuses a reason that would be read as a file" \
  '! PATH="$TRSTUB:$NOAXI_PATH" b dm-pr.sh close tr-pr-again --reason "@/etc/passwd" >/dev/null 2>&1'
# A PR can be REOPENED (or even merged) between the discard and a resume, so the
# resume re-checks rather than filing the recorded state. It still never closes
# anything: that authority belonged to the run that discarded the work.
tr_stub_pr 45 tr-pr-resume
pr_trash_task tr-pr-resume 45 >/dev/null
mkdir -p "$DM_HOME/state/archive"
mv "$DM_HOME/state/archive" "$TMP/tr-pr-resume-aside"
printf 'not a directory\n' > "$DM_HOME/state/archive"
PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-resume --reason "superseded" --close-pr >/dev/null 2>&1 || true
rm -f "$DM_HOME/state/archive"
mv "$TMP/tr-pr-resume-aside" "$DM_HOME/state/archive"
check "the killed trash had closed the PR before it died" \
  '[ "$(b dm-task.sh get tr-pr-resume pr_state)" = "CLOSED" ]'
tr_stub_pr 45 tr-pr-resume            # reopened on GitHub
: > "$TRSTUB/calls"
TRPRRES="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-resume --reason "superseded" 2>"$TMP/tr-pr-resume.err")"
check "a resume re-checks the PR instead of trusting the record" \
  'grep -qx "pr=STILL-OPEN" <<<"$TRPRRES" && ! grep -q "already-closed" <<<"$TRPRRES"'
check "it names the command that closes it, and closes nothing itself" \
  'grep -q "dm-pr.sh close tr-pr-resume" "$TMP/tr-pr-resume.err" \
   && ! grep -q "PATCH /repos/o/r/pulls/45" "$TRSTUB/calls"'
check "the resume still finishes the bookkeeping"  'grep -qx "records=archived" <<<"$TRPRRES"'
# The same window can end in a MERGE, which must be labelled as one rather than
# read as just "not closed".
tr_stub_pr 46 tr-pr-landed
pr_trash_task tr-pr-landed 46 >/dev/null
mkdir -p "$DM_HOME/state/archive"
mv "$DM_HOME/state/archive" "$TMP/tr-pr-landed-aside"
printf 'not a directory\n' > "$DM_HOME/state/archive"
PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-landed --reason "superseded" --close-pr >/dev/null 2>&1 || true
rm -f "$DM_HOME/state/archive"
mv "$TMP/tr-pr-landed-aside" "$DM_HOME/state/archive"
printf '{"state":"closed","merged":true,"head":{"sha":"abc123","ref":"work/tr-pr-landed","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"default_branch":"main"}},"mergeable_state":"clean"}\n' > "$TRSTUB/pr-46.json"
TRPRLANDED="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-landed --reason "superseded" 2>"$TMP/tr-pr-landed.err")"
check "a PR merged after the discard is labelled MERGED" \
  'grep -qx "pr=MERGED" <<<"$TRPRLANDED"'
check "and the resume says the landed change is rollback territory" \
  'grep -q "rollback skill" "$TMP/tr-pr-landed.err"'

# The confirmed-CLOSED path: with the live check succeeding, no --close-pr needed.
TRCONF="$(PATH="$TRSTUB:$NOAXI_PATH" b dm-trash.sh tr-pr-again --reason "already closed upstream" 2>/dev/null)"
check "a CONFIRMED closed PR needs no --close-pr"  'grep -qx "pr=already-closed" <<<"$TRCONF"'

# shard:epilogue
echo
if [ -n "${SMOKE_SHARD:-}" ]; then
  # How many sections this slice OWNS, so tests/smoke-parallel.sh can check the
  # shards partition the suite. Reaching this line at all is the separate proof
  # the shard ran to the end: a shard that dies earlier prints no summary.
  echo "smoke[$SMOKE_SHARD]: $pass passed, $fail failed, $shard_owned_sections sections"
else
  echo "smoke: $pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]

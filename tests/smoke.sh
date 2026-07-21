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
# Canonicalize the temp root so DM_HOME and every path derived from it are
# PHYSICAL. dm-lib canonicalizes DM_HOME (pwd -P) and git records worktree paths
# physically, so a symlinked TMPDIR (macOS /var -> /private/var) would make
# resolver output (canonical) miss expectations built from a verbatim $TMP. This
# is the "already-canonical temp dir" the dm-100-cleanup-safety note prescribes;
# scout-cleanup.sh keeps its OWN symlinked root to exercise the canonicalization.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dm-smoke.XXXXXX")" && pwd -P)"
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

# --- managed-worktree guard wiring (#83) -------------------------------------
# The shipped Codex PreToolUse hook must resolve dm-command-guard.sh from the
# distro root even when cwd is a managed clone/worktree, whose git-toplevel has
# no guard script. Exercise the EXACT resolver string from .codex/config.toml.
GUARD_HOOK_CMD="$(sed -n "s/^command = '\(.*\)'\$/\1/p" "$ROOT/.codex/config.toml")"
GUARD_DISTRO="$TMP/guard-distro"
mkdir -p "$GUARD_DISTRO/bin" "$GUARD_DISTRO/repos/veriflow/src" "$GUARD_DISTRO/state/worktrees/dm-fake/src"
cp "$ROOT/bin/dm-command-guard.sh" "$GUARD_DISTRO/bin/dm-command-guard.sh"
chmod +x "$GUARD_DISTRO/bin/dm-command-guard.sh"
GUARD_WT="$GUARD_DISTRO/state/worktrees/dm-fake/src"
GUARD_CLONE="$GUARD_DISTRO/repos/veriflow/src"
# Walk-up resolution: DM_HOME unset, cwd inside a managed worktree/clone.
guard_walkup() { ( cd "$1" && printf '%s' "$2" | env -u DM_HOME sh -c "$GUARD_HOOK_CMD" ); }
# DM_HOME fast path: cwd unrelated to the distro, DM_HOME names its root.
guard_dmhome() { ( cd "$TMP" && printf '%s' "$1" | DM_HOME="$GUARD_DISTRO" sh -c "$GUARD_HOOK_CMD" ); }
GUARD_RESET='{"tool_input":{"command":"git reset --hard"}}'
GUARD_CHECKOUT='{"tool_input":{"command":"git checkout -- package-lock.json"}}'
GUARD_CLEAN='{"tool_input":{"command":"git clean -fdx"}}'
GUARD_STATUS='{"tool_input":{"command":"git status"}}'
check "wiring resolves guard extracted from .codex/config.toml" '[ -n "$GUARD_HOOK_CMD" ]'
check "wiring blocks destructive git from a managed worktree (walk-up, no DM_HOME)" '! guard_walkup "$GUARD_WT" "$GUARD_RESET" >/dev/null 2>&1'
check "wiring blocks destructive git from a managed clone (walk-up, no DM_HOME)" '! guard_walkup "$GUARD_CLONE" "$GUARD_CHECKOUT" >/dev/null 2>&1'
check "wiring permits read-only git from a managed worktree" 'guard_walkup "$GUARD_WT" "$GUARD_STATUS" >/dev/null 2>&1'
check "wiring blocks destructive git via DM_HOME fast path" '! guard_dmhome "$GUARD_CLEAN" >/dev/null 2>&1'

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
# Advisory dispatch right-sizing (#77): the recommended tier is surfaced in the
# header and the same value is recorded in task meta. "add multiply" is ordinary
# implementation work -> sonnet.
check "brief surfaces the recommended model tier"     'grep -q "Recommended model tier: sonnet" "$DM_HOME/data/demo-1/brief.md"'
check "brief records model_recommended in task meta"  '[ "$(b dm-task.sh get demo-1 model_recommended)" = sonnet ]'

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
b dm-task.sh event fix1 working "waiting on upstream PR merged: #123" >/dev/null
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
  # nvm bin that also holds node and codex. Re-provide anything that vanished so
  # the filter removes exactly the wrapper, even on a nvm-only machine.
  for tool in git jq node claude codex; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    if ! ( PATH="$out"; command -v "$tool" >/dev/null 2>&1 ); then ln -sf "$real" "$shim/$tool"; fi
  done
  printf '%s\n' "$shim:$out"
}
NOAXI_PATH="$(path_without_ghaxi)"
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

echo "== dispatch right-sizing: dm_recommended_model is a pure advisory tier (#77) =="
# Pure like dm_merge_gate: risk signals -> opus, scout/mechanical -> haiku, else
# sonnet. Case-insensitive substring match; risk dominates the scout kind.
rec() { ( . "$ROOT/bin/dm-lib.sh"; dm_recommended_model "$1" "$2" ); }
check "recommend opus for auth/security work"      '[ "$(rec ship "harden auth token security")" = opus ]'
check "recommend opus for a migration"             '[ "$(rec ship "add Alembic migration")" = opus ]'
check "recommend opus for a concurrency/lock fix"  '[ "$(rec ship "fix mutex lock race")" = opus ]'
check "recommend haiku for a scout"                '[ "$(rec scout "look into the page layout")" = haiku ]'
check "recommend haiku for a docs/typo fix"        '[ "$(rec ship "fix docs typo")" = haiku ]'
check "recommend sonnet for ordinary impl"         '[ "$(rec ship "add a multiply endpoint")" = sonnet ]'
check "risk signals dominate the scout kind"       '[ "$(rec scout "security audit of auth flow")" = opus ]'

echo "== dispatch right-sizing: dm-status flags an unsized dispatch (#77) =="
# A live `working` task with no `model` recorded is an unsized dispatch; the
# advisory hint names a recommended tier and clears once a model is recorded.
b dm-task.sh new unsized-1 --kind ship --repo demo --title "add a widget" >/dev/null
b dm-task.sh event unsized-1 working "started" >/dev/null
UNSIZED_STATUS="$(b dm-status.sh)"   # capture once (grep -q + pipefail)
check "status flags a working task with no model as UNSIZED" 'grep -q "UNSIZED.*unsized-1" <<<"$UNSIZED_STATUS"'
check "UNSIZED hint names a recommended tier"                'grep -qE "recommended: (haiku|sonnet|opus)" <<<"$UNSIZED_STATUS"'
b dm-task.sh set unsized-1 model sonnet >/dev/null
SIZED_STATUS="$(b dm-status.sh)"
check "recording a model clears the UNSIZED flag"            '! grep -q "UNSIZED.*unsized-1" <<<"$SIZED_STATUS"'

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

# Every mutating entry point refuses an unregistered repo BY NAME.
b dm-task.sh new unreg-1 --kind ship --repo nosuchrepo --mode local-only >/dev/null
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
check "local land refuses a task whose repo is unregistered" '! b dm-merge.sh local unreg-1 >/dev/null 2>&1'
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
mkdir -p "$PARITY_FIXTURE/.claude/skills/added-runtime"
printf '%s\n' '---' 'name: added-runtime' 'description: mutation fixture' '---' > "$PARITY_FIXTURE/.claude/skills/added-runtime/SKILL.md"
check "runtime performance guard fails on added Claude skill" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
rm -rf "$PARITY_FIXTURE/.claude/skills/added-runtime"
mkdir -p "$PARITY_FIXTURE/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$PARITY_FIXTURE/.claude/hooks/added.sh"
check "runtime performance guard rejects unclassified Claude files" \
  '! DM_PARITY_ROOT="$PARITY_FIXTURE" node "$ROOT/tests/runtime-performance.js" >/dev/null 2>&1'
rm -rf "$PARITY_FIXTURE/.claude/hooks"
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
check "--force replaces the conflicting file"      'DM_HOME="$RESTORE" "$ROOT/bin/dm-state.sh" import "$SP/full.tar.gz" --force >/dev/null && ! grep -q "local edit" "$RESTORE/state/learnings.md"'
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
rm -rf "$DM_HOME/state/unknown-extra" "$DM_HOME/state/tasks/subdir"
rm -f "$DM_HOME/state/tasks/t1.report" "$DM_HOME/state/archive/stray.json" "$DM_HOME/repos/demo/.dm/keys.txt"

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

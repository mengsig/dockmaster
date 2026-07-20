#!/usr/bin/env bash
# Focused regression matrix for scout cleanup safety (#100).

set -euo pipefail

export GIT_AUTHOR_NAME="scout cleanup test" GIT_AUTHOR_EMAIL="scout-cleanup@dockmaster.test"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-scout-cleanup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DM_HOME="$TMP/home" DM_NO_FETCH=1

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
b() { "$ROOT/bin/$@"; }

new_scout() {
  local id="$1"
  b dm-task.sh new "$id" --kind scout --repo demo >/dev/null
  b dm-worktree.sh create "$id" demo | tail -n1
}

write_report() {
  mkdir -p "$DM_HOME/data/$1"
  printf '# findings\n' > "$DM_HOME/data/$1/report.md"
}

expect_refusal() {
  local label="$1" id="$2" pattern="$3" out rc
  shift 3
  set +e
  out="$(b dm-worktree.sh remove "$id" "$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q "$pattern" <<<"$out"; then
    ok "$label"
  else
    bad "$label"
    printf '       rc=%s output=%s\n' "$rc" "${out//$'\n'/ | }"
  fi
}

git init -q --bare -b main "$TMP/origin.git"
git init -q -b main "$TMP/seed"
mkdir -p "$TMP/seed/src"
printf 'base\n' > "$TMP/seed/src/evidence.txt"
git -C "$TMP/seed" add src/evidence.txt
git -C "$TMP/seed" commit -qm init
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" push -q origin main
b dm-repo.sh add demo "$TMP/origin.git" --mode local-only --no-memory >/dev/null 2>&1
git -C "$DM_HOME/repos/demo" config core.excludesFile /dev/null

echo "== report prerequisite and tracked evidence =="
PRE_CLEAN="$(new_scout pre-clean)"
expect_refusal "clean pre-report scout is preserved" pre-clean "has no report"
check "clean pre-report directory remains" '[ -d "$PRE_CLEAN" ] && [ "$(b dm-task.sh get pre-clean worktree)" = "$PRE_CLEAN" ]'
b dm-worktree.sh remove pre-clean --force >/dev/null
check "forced pre-report cleanup records discard" 'b dm-task.sh state pre-clean | grep -q "^state: discarded"'

PRE_DIRTY="$(new_scout pre-dirty)"
printf 'unstaged evidence\n' >> "$PRE_DIRTY/src/evidence.txt"
expect_refusal "dirty pre-report scout is preserved" pre-dirty "has no report"
check "pre-report evidence and metadata remain" 'grep -q "unstaged evidence" "$PRE_DIRTY/src/evidence.txt" && [ "$(b dm-task.sh get pre-dirty worktree)" = "$PRE_DIRTY" ]'
b dm-worktree.sh remove pre-dirty --force >/dev/null

POST_CLEAN="$(new_scout post-clean)"
write_report post-clean
check "clean reported scout is removed" 'b dm-worktree.sh remove post-clean >/dev/null && [ ! -d "$POST_CLEAN" ] && [ -z "$(b dm-task.sh get post-clean worktree)" ]'

POST_DIRTY="$(new_scout post-dirty)"
write_report post-dirty
printf 'unstaged evidence\n' >> "$POST_DIRTY/src/evidence.txt"
expect_refusal "reported unstaged evidence is preserved" post-dirty "uncommitted changes"
check "unstaged evidence and metadata remain" 'grep -q "unstaged evidence" "$POST_DIRTY/src/evidence.txt" && [ "$(b dm-task.sh get post-dirty worktree)" = "$POST_DIRTY" ]'
b dm-worktree.sh remove post-dirty --force >/dev/null

POST_STAGED="$(new_scout post-staged)"
write_report post-staged
printf 'staged evidence\n' >> "$POST_STAGED/src/evidence.txt"
git -C "$POST_STAGED" add src/evidence.txt
expect_refusal "reported staged evidence is preserved" post-staged "uncommitted changes"
check "staged evidence remains staged" '! git -C "$POST_STAGED" diff --cached --quiet --exit-code'
b dm-worktree.sh remove post-staged --force >/dev/null

POST_COMMIT="$(new_scout post-commit)"
write_report post-commit
printf 'committed evidence\n' >> "$POST_COMMIT/src/evidence.txt"
git -C "$POST_COMMIT" add src/evidence.txt
git -C "$POST_COMMIT" commit -qm "scratch evidence"
COMMIT_HEAD="$(git -C "$POST_COMMIT" rev-parse HEAD)"
expect_refusal "reported committed-ahead evidence is preserved" post-commit "commits not in main"
check "scratch commit and metadata remain" '[ "$(git -C "$POST_COMMIT" rev-parse HEAD)" = "$COMMIT_HEAD" ] && [ "$(b dm-task.sh get post-commit worktree)" = "$POST_COMMIT" ]'
b dm-worktree.sh remove post-commit --force >/dev/null

echo "== narrow untracked handling =="
PRE_CRUFT="$(new_scout pre-cruft)"
printf 'lock\n' > "$PRE_CRUFT/uv.lock"
expect_refusal "disposable cruft cannot bypass missing report" pre-cruft "has no report"
check "pre-report disposable artifact remains" '[ -f "$PRE_CRUFT/uv.lock" ]'
b dm-worktree.sh remove pre-cruft --force >/dev/null

POST_CRUFT="$(new_scout post-cruft)"
write_report post-cruft
mkdir -p "$POST_CRUFT/.pytest_cache"
printf 'cache\n' > "$POST_CRUFT/.pytest_cache/state"
printf 'lock\n' > "$POST_CRUFT/uv.lock"
check "disposable artifacts are genuinely untracked" '[ -n "$(git -C "$POST_CRUFT" ls-files --others --exclude-standard)" ]'
check "reported disposable-only scout is removed" 'b dm-worktree.sh remove post-cruft >/dev/null && [ ! -d "$POST_CRUFT" ]'

POST_REAL="$(new_scout post-real-untracked)"
write_report post-real-untracked
printf 'lock\n' > "$POST_REAL/uv.lock"
printf 'investigation notes\n' > "$POST_REAL/notes.txt"
expect_refusal "real untracked evidence amid cruft is preserved" post-real-untracked "notes.txt"
check "real untracked refusal hides disposable noise" 'OUT="$(b dm-worktree.sh remove post-real-untracked 2>&1 || true)"; ! grep -q "uv.lock" <<<"$OUT"'
check "real untracked evidence and metadata remain" '[ -f "$POST_REAL/notes.txt" ] && [ "$(b dm-task.sh get post-real-untracked worktree)" = "$POST_REAL" ]'
b dm-worktree.sh remove post-real-untracked --force >/dev/null

echo "== deletion boundary failures =="
PATH_WT="$(new_scout path-mismatch)"
write_report path-mismatch
VICTIM="$TMP/unrelated-repo"
git init -q -b main "$VICTIM"
printf 'must survive\n' > "$VICTIM/evidence.txt"
git -C "$VICTIM" add evidence.txt
git -C "$VICTIM" commit -qm "unrelated evidence"
b dm-task.sh set path-mismatch worktree "$VICTIM"
expect_refusal "force refuses an unrelated recorded path" path-mismatch "does not match managed path" --force
check "unrelated and legitimate directories remain" '[ -f "$VICTIM/evidence.txt" ] && [ -d "$PATH_WT" ]'
check "path refusal preserves recorded metadata" '[ "$(b dm-task.sh get path-mismatch worktree)" = "$VICTIM" ]'
b dm-task.sh set path-mismatch worktree "$PATH_WT"
b dm-worktree.sh remove path-mismatch --force >/dev/null

INSPECT_WT="$(new_scout inspect-failure)"
write_report inspect-failure
REAL_GIT="$(command -v git)"
FAIL_GIT="$TMP/fail-git"
mkdir -p "$FAIL_GIT"
printf '%s\n' '#!/bin/sh' 'case " $* " in *" ls-files --others --exclude-standard "*) exit 42 ;; esac' "exec \"$REAL_GIT\" \"\$@\"" > "$FAIL_GIT/git"
chmod +x "$FAIL_GIT/git"
set +e
INSPECT_OUT="$(PATH="$FAIL_GIT:$PATH" b dm-worktree.sh remove inspect-failure 2>&1)"
INSPECT_RC=$?
set -e
check "Git inspection failure is visible" '[ "$INSPECT_RC" -ne 0 ] && grep -q "cannot inspect untracked" <<<"$INSPECT_OUT"'
check "inspection failure preserves directory and metadata" '[ -d "$INSPECT_WT" ] && [ "$(b dm-task.sh get inspect-failure worktree)" = "$INSPECT_WT" ]'
b dm-worktree.sh remove inspect-failure >/dev/null

LOCKED_WT="$(new_scout locked-worktree)"
write_report locked-worktree
git -C "$DM_HOME/repos/demo" worktree lock "$LOCKED_WT" --reason "cleanup safety test"
expect_refusal "Git locked-worktree refusal stays visible" locked-worktree "git worktree remove failed"
check "locked refusal preserves directory and metadata" '[ -d "$LOCKED_WT" ] && [ "$(b dm-task.sh get locked-worktree worktree)" = "$LOCKED_WT" ]'
check "locked refusal preserves Git administrative record" 'git -C "$DM_HOME/repos/demo" worktree list --porcelain | grep -q "locked cleanup safety test"'
git -C "$DM_HOME/repos/demo" worktree unlock "$LOCKED_WT"
b dm-worktree.sh remove locked-worktree >/dev/null

echo
echo "scout cleanup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

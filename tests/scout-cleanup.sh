#!/usr/bin/env bash
# Focused regression matrix for worktree cleanup safety: the scout report
# prerequisite and tracked-evidence guard (#100), force recoverability and
# refusal attribution (#84), the merged-head containment check (#120), the
# kind-independence of the unlanded gate (#127), and the managed-path
# confinement of every deletion (#117).

set -euo pipefail

export GIT_AUTHOR_NAME="scout cleanup test" GIT_AUTHOR_EMAIL="scout-cleanup@dockmaster.test"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-scout-cleanup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# The WHOLE matrix runs through a symlinked root on purpose. git records worktree
# paths physically, so anything comparing a recorded path against git's own
# record must survive a non-canonical DM_HOME — macOS TMPDIR (/var ->
# /private/var) is exactly this. A canonical-only suite passed 88/88 while the
# admin-record lookup silently matched nothing and reported the loss as safe.
mkdir -p "$TMP/real"
ln -s "$TMP/real" "$TMP/link"
export DM_HOME="$TMP/link/home" DM_NO_FETCH=1

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
b() { "$ROOT/bin/$@"; }

# Scaffolding teardown: reported as a failure but never aborts the run, so a
# regression that breaks cleanup cannot hide which other cases moved.
cleanup() {
  local id="$1"; shift
  local out
  if ! out="$(b dm-worktree.sh remove "$id" "$@" 2>&1)"; then
    bad "cleanup of $id"
    printf '       %s\n' "${out//$'\n'/ | }"
  fi
}

new_task() {
  local id="$1" kind="$2"
  b dm-task.sh new "$id" --kind "$kind" --repo demo >/dev/null
  b dm-worktree.sh create "$id" demo | tail -n1
}
new_scout() { new_task "$1" scout; }
new_ship() { new_task "$1" ship; }

write_report() {
  mkdir -p "$DM_HOME/data/$1"
  printf '# findings\n' > "$DM_HOME/data/$1/report.md"
}

commit_in() {
  local wt="$1" text="$2"
  printf '%s\n' "$text" >> "$wt/src/evidence.txt"
  git -C "$wt" add src/evidence.txt
  git -C "$wt" commit -qm "$text"
  git -C "$wt" rev-parse HEAD
}

# Stand in for the sanctioned writer (dm-pr.sh merge): pr_state/pr_head are
# write-protected from dm-task.sh set, so record them through dm-lib directly.
record_merged() {
  ( . "$ROOT/bin/dm-lib.sh"; dm_meta_set "$1" pr_state MERGED; dm_meta_set "$1" pr_head "$2" ) >/dev/null
}

# Same for `worktree` (#130 reserved it to dm-worktree.sh). The #117 attack is
# precisely a hostile recorded path, so the test must be able to plant one.
record_worktree() {
  ( . "$ROOT/bin/dm-lib.sh"; dm_meta_set "$1" worktree "$2" ) >/dev/null
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
cleanup pre-clean --force
check "forced pre-report cleanup records discard" 'b dm-task.sh state pre-clean | grep -q "^state: discarded"'

PRE_DIRTY="$(new_scout pre-dirty)"
printf 'unstaged evidence\n' >> "$PRE_DIRTY/src/evidence.txt"
expect_refusal "dirty pre-report scout is preserved" pre-dirty "has no report"
check "pre-report evidence and metadata remain" 'grep -q "unstaged evidence" "$PRE_DIRTY/src/evidence.txt" && [ "$(b dm-task.sh get pre-dirty worktree)" = "$PRE_DIRTY" ]'
cleanup pre-dirty --force

POST_CLEAN="$(new_scout post-clean)"
write_report post-clean
check "clean reported scout is removed" 'b dm-worktree.sh remove post-clean >/dev/null && [ ! -d "$POST_CLEAN" ] && [ -z "$(b dm-task.sh get post-clean worktree)" ]'

POST_DIRTY="$(new_scout post-dirty)"
write_report post-dirty
printf 'unstaged evidence\n' >> "$POST_DIRTY/src/evidence.txt"
expect_refusal "reported unstaged evidence is preserved" post-dirty "uncommitted changes"
check "unstaged evidence and metadata remain" 'grep -q "unstaged evidence" "$POST_DIRTY/src/evidence.txt" && [ "$(b dm-task.sh get post-dirty worktree)" = "$POST_DIRTY" ]'
# #84: a scout's tracked edits ARE the reproduction; calling that "unlanded
# work" reads as an unfinished task and invites a reflexive --force.
check "scout refusal names scratch, not unlanded work" 'OUT="$(b dm-worktree.sh remove post-dirty 2>&1 || true)"; grep -q "investigation scratch" <<<"$OUT" && ! grep -q "has unlanded work" <<<"$OUT"'
check "scout refusal points at the report" 'OUT="$(b dm-worktree.sh remove post-dirty 2>&1 || true)"; grep -q "data/post-dirty/report.md captures the findings" <<<"$OUT"'
cleanup post-dirty --force

POST_STAGED="$(new_scout post-staged)"
write_report post-staged
printf 'staged evidence\n' >> "$POST_STAGED/src/evidence.txt"
git -C "$POST_STAGED" add src/evidence.txt
expect_refusal "reported staged evidence is preserved" post-staged "uncommitted changes"
check "staged evidence remains staged" '! git -C "$POST_STAGED" diff --cached --quiet --exit-code'
cleanup post-staged --force

POST_COMMIT="$(new_scout post-commit)"
write_report post-commit
COMMIT_HEAD="$(commit_in "$POST_COMMIT" "committed evidence")"
expect_refusal "reported committed-ahead evidence is preserved" post-commit "commits not in main"
check "scratch commit and metadata remain" '[ "$(git -C "$POST_COMMIT" rev-parse HEAD)" = "$COMMIT_HEAD" ] && [ "$(b dm-task.sh get post-commit worktree)" = "$POST_COMMIT" ]'
cleanup post-commit --force

SHIP_UNLANDED="$(new_ship ship-unlanded)"
commit_in "$SHIP_UNLANDED" "ship work" >/dev/null
expect_refusal "ship refusal still says unlanded work" ship-unlanded "has unlanded work"
check "ship refusal avoids the scout wording" 'OUT="$(b dm-worktree.sh remove ship-unlanded 2>&1 || true)"; ! grep -q "investigation scratch" <<<"$OUT"'
cleanup ship-unlanded --force

echo "== the unlanded gate does not rest on the mutable kind field (#127) =="
RECLASS="$(new_ship reclassified)"
commit_in "$RECLASS" "work that must not vanish" >/dev/null
write_report reclassified
b dm-task.sh set reclassified kind scout >/dev/null
expect_refusal "reclassifying ship->scout does not switch the gate off" reclassified "not in git history"
check "reclassified work and metadata remain" 'grep -q "work that must not vanish" "$RECLASS/src/evidence.txt" && [ "$(b dm-task.sh get reclassified worktree)" = "$RECLASS" ]'
cleanup reclassified --force

echo "== merged means THIS worktree's work merged (#120) =="
MERGED_EXACT="$(new_ship merged-exact)"
MERGED_SHA="$(commit_in "$MERGED_EXACT" "the merged work")"
record_merged merged-exact "$MERGED_SHA"
check "a merged head at the merged sha is landed" 'b dm-worktree.sh landed merged-exact >/dev/null'
check "cleanly merged worktree is removed" 'b dm-worktree.sh remove merged-exact >/dev/null && [ ! -d "$MERGED_EXACT" ]'

MERGED_AHEAD="$(new_ship merged-ahead)"
AHEAD_SHA="$(commit_in "$MERGED_AHEAD" "the merged work")"
record_merged merged-ahead "$AHEAD_SHA"
FOLLOWUP_SHA="$(commit_in "$MERGED_AHEAD" "follow-up after the merge")"
check "worktree is detached, so no ref holds the follow-up" '[ "$(git -C "$MERGED_AHEAD" symbolic-ref -q HEAD || echo detached)" = detached ]'
expect_refusal "post-merge commits are not treated as landed" merged-ahead "not contained in the merged PR head"
check "post-merge commit and metadata remain" '[ "$(git -C "$MERGED_AHEAD" rev-parse HEAD)" = "$FOLLOWUP_SHA" ] && [ "$(b dm-task.sh get merged-ahead worktree)" = "$MERGED_AHEAD" ]'
check "pr_head cannot be hand-set to launder the follow-up" '! b dm-task.sh set merged-ahead pr_head "$FOLLOWUP_SHA" >/dev/null 2>&1'
check "pr_head survives the rejected write" '[ "$(b dm-task.sh get merged-ahead pr_head)" = "$AHEAD_SHA" ]'
cleanup merged-ahead --force
check "discarding post-merge work leaves a record" 'grep -q "discarded: .*work not proven landed" "$DM_HOME/state/tasks/merged-ahead.status"'

MERGED_BEHIND="$(new_ship merged-behind)"
BEHIND_BASE="$(git -C "$MERGED_BEHIND" rev-parse HEAD)"
BEHIND_SHA="$(commit_in "$MERGED_BEHIND" "merged work")"
record_merged merged-behind "$BEHIND_SHA"
git -C "$MERGED_BEHIND" reset -q --hard "$BEHIND_BASE"
check "a head contained in the merged result is landed" 'b dm-worktree.sh landed merged-behind >/dev/null'
cleanup merged-behind

MERGED_NOHEAD="$(new_ship merged-nohead)"
commit_in "$MERGED_NOHEAD" "work with no recorded merged head" >/dev/null
( . "$ROOT/bin/dm-lib.sh"; dm_meta_set merged-nohead pr_state MERGED ) >/dev/null
expect_refusal "MERGED without a recorded head is undetermined, not landed" merged-nohead "cannot determine whether"
check "undetermined merge preserves the worktree" '[ -d "$MERGED_NOHEAD" ]'
cleanup merged-nohead --force

echo "== narrow untracked handling =="
PRE_CRUFT="$(new_scout pre-cruft)"
printf 'lock\n' > "$PRE_CRUFT/uv.lock"
expect_refusal "disposable cruft cannot bypass missing report" pre-cruft "has no report"
check "pre-report disposable artifact remains" '[ -f "$PRE_CRUFT/uv.lock" ]'
cleanup pre-cruft --force

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
cleanup post-real-untracked --force

echo "== every deletion is confined to the managed path (#117) =="
PATH_WT="$(new_scout path-mismatch)"
write_report path-mismatch
VICTIM="$TMP/unrelated-repo"
git init -q -b main "$VICTIM"
printf 'must survive\n' > "$VICTIM/evidence.txt"
git -C "$VICTIM" add evidence.txt
git -C "$VICTIM" commit -qm "unrelated evidence"
record_worktree path-mismatch "$VICTIM"
expect_refusal "force refuses an unrelated recorded path" path-mismatch "does not match managed path" --force
check "unrelated and legitimate directories remain" '[ -f "$VICTIM/evidence.txt" ] && [ -d "$PATH_WT" ]'
check "path refusal preserves recorded metadata" '[ "$(b dm-task.sh get path-mismatch worktree)" = "$VICTIM" ]'
# The reproduced #117 attack: point a task at a managed clone, then force-remove.
record_worktree path-mismatch "$DM_HOME/repos/demo"
expect_refusal "force refuses a recorded path inside repos/" path-mismatch "does not match managed path" --force
check "the managed clone survives" '[ -d "$DM_HOME/repos/demo/.git" ] && [ -f "$DM_HOME/repos/demo/src/evidence.txt" ]'
record_worktree path-mismatch "$PATH_WT"
cleanup path-mismatch --force

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
cleanup inspect-failure

LOCKED_WT="$(new_scout locked-worktree)"
write_report locked-worktree
git -C "$DM_HOME/repos/demo" worktree lock "$LOCKED_WT" --reason "cleanup safety test"
expect_refusal "Git locked-worktree refusal stays visible" locked-worktree "git could not remove"
check "locked refusal names the --force remedy" 'OUT="$(b dm-worktree.sh remove locked-worktree 2>&1 || true)"; grep -q -- "--force" <<<"$OUT"'
check "locked refusal preserves directory and metadata" '[ -d "$LOCKED_WT" ] && [ "$(b dm-task.sh get locked-worktree worktree)" = "$LOCKED_WT" ]'
check "locked refusal preserves Git administrative record" 'git -C "$DM_HOME/repos/demo" worktree list --porcelain | grep -q "locked cleanup safety test"'
git -C "$DM_HOME/repos/demo" worktree unlock "$LOCKED_WT"
cleanup locked-worktree

echo "== --force recovers a broken git worktree record (#100 major 1) =="
# Reachable through documented paths: the AGENTS.md re-adopt pitfall, or
# `git worktree prune` run while the worktree sat on an unmounted path.
BROKEN="$(new_scout broken-record)"
write_report broken-record
rm -rf "$DM_HOME/repos/demo/.git/worktrees/broken-record"
expect_refusal "a destroyed git record is not blamed on dirtiness" broken-record "cannot determine whether"
check "broken-record refusal avoids the dirtiness wording" 'OUT="$(b dm-worktree.sh remove broken-record 2>&1 || true)"; ! grep -q "uncommitted changes" <<<"$OUT"'
check "broken-record refusal names the --force remedy" 'OUT="$(b dm-worktree.sh remove broken-record 2>&1 || true)"; grep -q -- "--force" <<<"$OUT"'
check "broken-record refusal preserves the directory" '[ -d "$BROKEN" ]'
check "force recovers a broken record" 'b dm-worktree.sh remove broken-record --force >/dev/null 2>&1'
check "force leaves no directory and no recorded worktree" '[ ! -d "$BROKEN" ] && [ -z "$(b dm-task.sh get broken-record worktree)" ]'
# The stuck-forever symptom: state pinned at `working`, archive refused forever.
check "recovered task is no longer pinned working" '! b dm-task.sh state broken-record | grep -q "^state: working"'
check "recovered scout can be archived" 'b dm-task.sh archive broken-record >/dev/null'

BROKEN_SHIP="$(new_ship broken-ship)"
commit_in "$BROKEN_SHIP" "ship work behind a broken record" >/dev/null
rm -rf "$DM_HOME/repos/demo/.git/worktrees/broken-ship"
check "force recovers a broken record for a ship task" 'b dm-worktree.sh remove broken-ship --force >/dev/null 2>&1 && [ ! -d "$BROKEN_SHIP" ]'
check "recovered ship task can be archived" 'b dm-task.sh archive broken-ship >/dev/null'

echo "== --force recovers an interrupted cleanup (directory already gone) =="
# A crash between the rm and the meta clear. The directory is gone, so the old
# code refused on the MISSING path before --force was ever consulted: the task
# pinned at working and its whole clone pinned with it.
GONE="$(new_scout cleanup-crashed)"
write_report cleanup-crashed
rm -rf "$GONE"
expect_refusal "a vanished directory is refused without --force" cleanup-crashed "already absent"
check "vanished-directory refusal names the unmount case" 'OUT="$(b dm-worktree.sh remove cleanup-crashed 2>&1 || true)"; grep -q "unmounted volume" <<<"$OUT"'
check "vanished-directory refusal keeps the record for --force" '[ "$(b dm-task.sh get cleanup-crashed worktree)" = "$GONE" ]'
check "force clears a vanished directory" 'b dm-worktree.sh remove cleanup-crashed --force >/dev/null 2>&1'
check "force clears the recorded worktree" '[ -z "$(b dm-task.sh get cleanup-crashed worktree)" ]'
check "recovering the crash records the discard and the lost path" 'grep -q "discarded: stale worktree record cleared.*cleanup-crashed" "$DM_HOME/state/tasks/cleanup-crashed.status"'
check "crashed task is no longer pinned working" '! b dm-task.sh state cleanup-crashed | grep -q "^state: working"'
# The clone-pinning half: dm-repo.sh remove counts git's worktree entries, so
# the stale admin record must be pruned or the whole repo stays unremovable.
check "the clone no longer holds the crashed worktree" 'LIST="$(git -C "$DM_HOME/repos/demo" worktree list --porcelain)"; ! grep -q "cleanup-crashed" <<<"$LIST"'
check "recovered crashed task can be archived" 'b dm-task.sh archive cleanup-crashed >/dev/null'

# The HIGH from gate round 2: the vanished DIRECTORY does not take the commit
# with it — git's admin record still holds the sha, and `worktree prune` drops
# that last reference. Recovering the crash must not destroy the work it unpins.
CRASH_COMMIT="$(new_ship crash-commit)"
CRASH_SHA="$(commit_in "$CRASH_COMMIT" "committed before the cleanup crashed")"
check "git's admin record still holds the head after the directory dies" 'rm -rf "$CRASH_COMMIT"; LIST="$(git -C "$DM_HOME/repos/demo" worktree list --porcelain)"; grep -q "$CRASH_SHA" <<<"$LIST"'
check "recovering a crash with commits succeeds" 'b dm-worktree.sh remove crash-commit --force >/dev/null 2>&1'
check "the crashed commit is parked before the prune" '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/crash-commit/$CRASH_SHA")" = "$CRASH_SHA" ]'
check "the crash note names the preserved sha" 'grep -q "head $CRASH_SHA kept at refs/dm-discarded/crash-commit/$CRASH_SHA" "$DM_HOME/state/tasks/crash-commit.status"'
check "the crashed commit survives an aggressive gc" 'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; git -C "$DM_HOME/repos/demo" cat-file -e "$CRASH_SHA^{commit}"'
check "the crashed worktree is still unpinned from the clone" 'LIST="$(git -C "$DM_HOME/repos/demo" worktree list --porcelain)"; ! grep -q "crash-commit$" <<<"$LIST"'

echo "== a forced discard of unlanded work keeps the commit reachable =="
# Detached worktree: its reflog dies with the directory, so without a ref in the
# clone the commit is unreachable and the next gc destroys it permanently.
DISCARD_WT="$(new_ship discarded-head)"
DISCARD_SHA="$(commit_in "$DISCARD_WT" "work discarded under force")"
check "forced discard of unlanded work succeeds" 'b dm-worktree.sh remove discarded-head --force >/dev/null 2>&1 && [ ! -d "$DISCARD_WT" ]'
check "the discarded head is parked on a ref in the clone" '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/discarded-head/$DISCARD_SHA")" = "$DISCARD_SHA" ]'
check "the discard note names the recovery ref and sha" 'grep -q "head $DISCARD_SHA kept at refs/dm-discarded/discarded-head" "$DM_HOME/state/tasks/discarded-head.status"'
check "the parked commit survives an aggressive gc" 'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; git -C "$DM_HOME/repos/demo" cat-file -e "$DISCARD_SHA^{commit}"'
check "the parked commit is reachable, not merely unpruned" 'REACH="$(git -C "$DM_HOME/repos/demo" for-each-ref --contains "$DISCARD_SHA" --format="%(refname)")"; grep -q "refs/dm-discarded/discarded-head" <<<"$REACH"'

echo "== a pre-upgrade non-canonical record still preserves its work =="
# Records written before DM_HOME was canonicalized hold a symlinked path that
# never string-matches git's physical entry. Every record this suite creates is
# already canonical, so the stale shape has to be planted directly.
LEGACY_WT="$(new_ship legacy-rec)"
LEGACY_SHA="$(commit_in "$LEGACY_WT" "work behind a pre-upgrade record")"
# Planted through the suite's own symlink alias, not DM_HOME, so the record is
# non-canonical under a canonical root too — the condition, not the root, is
# what this case is about.
ln -s "$DM_HOME/state/worktrees" "$TMP/wt-alias"
record_worktree legacy-rec "$TMP/wt-alias/legacy-rec"
check "the planted record is genuinely non-canonical" '[ "$(b dm-task.sh get legacy-rec worktree)" != "$LEGACY_WT" ]'
check "the planted record still resolves to the same directory" '[ "$(cd "$(b dm-task.sh get legacy-rec worktree)" && pwd -P)" = "$LEGACY_WT" ]'
rm -rf "$LEGACY_WT"
check "a pre-upgrade record still clears" 'b dm-worktree.sh remove legacy-rec --force >/dev/null 2>&1'
check "a pre-upgrade record still parks its commit" '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/legacy-rec/$LEGACY_SHA")" = "$LEGACY_SHA" ]'
check "a pre-upgrade record never claims nothing was at risk" '! grep -q "no git record held a head" "$DM_HOME/state/tasks/legacy-rec.status"'
check "the pre-upgrade commit survives an aggressive gc" 'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; git -C "$DM_HOME/repos/demo" cat-file -e "$LEGACY_SHA^{commit}"'

echo "== an unresolvable head is reported unpreserved, never as parked =="
# Porcelain reports an unborn/corrupt HEAD as all-zeros. update-ref reads zeros
# as DELETE and exits 0, so an unguarded park creates nothing while reporting
# success — a note naming a ref that does not exist.
ZERO_WT="$(new_ship zero-head)"
commit_in "$ZERO_WT" "work behind a head git cannot resolve" >/dev/null
printf '0000000000000000000000000000000000000000\n' > "$DM_HOME/repos/demo/.git/worktrees/zero-head/HEAD"
rm -rf "$ZERO_WT"
check "an unresolvable head still clears the stale record" 'b dm-worktree.sh remove zero-head --force >/dev/null 2>&1'
check "a zero head is never claimed as parked" '! grep -q "kept at refs/dm-discarded" "$DM_HOME/state/tasks/zero-head.status"'
check "a zero head is reported as not preserved" 'grep -q "could NOT be preserved" "$DM_HOME/state/tasks/zero-head.status"'
check "no ref is created for a zero head" '[ -z "$(git -C "$DM_HOME/repos/demo" for-each-ref "refs/dm-discarded/zero-head/**" --format="%(refname)")" ]'

echo "== reusing a task id does not destroy the earlier discarded commit =="
# refs/dm-discarded/* gets no reflog (git auto-logs only heads/remotes/notes/
# HEAD), so a per-id ref would clobber the first discard into unreachability.
REUSE_ONE="$(new_ship reuse)"
REUSE_SHA1="$(commit_in "$REUSE_ONE" "first discarded work")"
cleanup reuse --force
b dm-task.sh archive reuse >/dev/null
REUSE_TWO="$(new_ship reuse)"
REUSE_SHA2="$(commit_in "$REUSE_TWO" "second discarded work")"
cleanup reuse --force
check "the two discards produced different commits" '[ "$REUSE_SHA1" != "$REUSE_SHA2" ]'
check "the second discard is parked" '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/reuse/$REUSE_SHA2")" = "$REUSE_SHA2" ]'
check "the first discard is still parked after the id is reused" '[ "$(git -C "$DM_HOME/repos/demo" rev-parse --verify --quiet "refs/dm-discarded/reuse/$REUSE_SHA1")" = "$REUSE_SHA1" ]'
check "both reused-id commits survive an aggressive gc" 'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; git -C "$DM_HOME/repos/demo" cat-file -e "$REUSE_SHA1^{commit}" && git -C "$DM_HOME/repos/demo" cat-file -e "$REUSE_SHA2^{commit}"'

echo "== a task id that is an illegal ref component still preserves its work =="
# dm_valid_id allows `.`, so these are legal tasks but rejected verbatim by
# check-ref-format. Sanitizing the component preserves the commit for free.
ODD_WT="$(new_ship odd..id)"
ODD_SHA="$(commit_in "$ODD_WT" "work under an id git cannot spell")"
cleanup 'odd..id' --force
check "an illegal-ref id still parks its discarded commit" 'REACH="$(git -C "$DM_HOME/repos/demo" for-each-ref --contains "$ODD_SHA" --format="%(refname)")"; grep -q "refs/dm-discarded/odd__id/$ODD_SHA" <<<"$REACH"'
check "the illegal-ref id records preservation, not a loss" 'grep -q "head $ODD_SHA kept at" "$DM_HOME/state/tasks/odd..id.status"'
check "the illegal-ref commit survives an aggressive gc" 'git -C "$DM_HOME/repos/demo" gc --prune=now --quiet 2>/dev/null; git -C "$DM_HOME/repos/demo" cat-file -e "$ODD_SHA^{commit}"'

echo "== a refusal names the failure, not git's manual =="
# git diff on a non-repo path exits 129 after ~130 lines of usage text. Pasting
# that into the refusal buries the one line that says what is at risk.
NOISY="$(new_scout noisy-refusal)"
write_report noisy-refusal
rm -f "$NOISY/.git"
set +e
NOISY_OUT="$(b dm-worktree.sh remove noisy-refusal 2>&1)"
NOISY_RC=$?
set -e
check "a broken repo refusal is still visible" '[ "$NOISY_RC" -ne 0 ] && grep -q "cannot determine whether" <<<"$NOISY_OUT"'
check "the refusal does not paste git's usage text" '! grep -q "usage: git diff" <<<"$NOISY_OUT"'
check "the refusal stays short enough to read" '[ "$(wc -l <<<"$NOISY_OUT")" -le 6 ]'
check "the broken-repo worktree is preserved" '[ -d "$NOISY" ]'
cleanup noisy-refusal --force

echo
echo "scout cleanup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# dm-task.sh - durable per-task records and on-demand current-state reconciliation.
#
# Design split (the part worth keeping):
#   - state/tasks/<id>.meta   durable record: kind, repo, worktree, branch,
#                             mode, agent_id, pr, pr_state, ... Written only
#                             through dm-lib's single owner path.
#   - state/tasks/<id>.status APPEND-ONLY event log. A line is a wake EVENT, not
#                             current-state truth.
#   - `state <id>`            reconciles authoritative current state on demand
#                             from real signals (worktree landed? PR merged?
#                             agent alive?), never from the last status line.
#
# The active runtime's task/thread list is the in-session working mirror; these
# files are the cross-session source of truth.
#
# Commands:
#   new <id> --kind ship|scout --repo R [--mode M] [--title T]
#   set <id> <key> <value>
#   approve <id> <fast|default|rigorous>
#   pipeline-check <id> <open|merge> <repo> <base-ref> <base-sha> <head-sha>
#   gate <id> claim <gate> <thread>
#   gate <id> start <gate> <epoch> <thread> <agent-id>
#   gate <id> release <gate> <epoch> <thread> <reason>
#   gate <id> block <gate> <blocker-id> <reason>
#   gate <id> ready <gate>
#   gate <id> complete <gate> <epoch> <agent-id> <evidence>
#   ready-gates            list approved gates waiting for a runtime owner
#   waiter <id> <prepare|active|idle|terminal|cancel|recover> [...]
#   get <id> [<key>]
#   event <id> <state> [<note>]
#   state <id>            reconcile and print current state
#   archive <id>          move a terminal (done/discarded) task's records +
#                         artifacts to state/archive/ (fails closed otherwise)
#   list

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# `new` inherits a task's mode from the repo registry; a corrupt registry must
# not silently record an empty mode.
dm_registry_require_valid

valid_pipeline_tier() { case "${1:-}" in fast|default|rigorous) return 0 ;; *) return 1 ;; esac; }
valid_pipeline_gate() {
  case "${1:-}" in
    ''|[!a-z]*|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}
pipeline_config() {
  local repo="$1" tier="$2" file legacy
  file="$DM_CONFIG/pr-pipeline.repos/$repo.json"
  if [ ! -f "$file" ]; then
    legacy="$DM_CONFIG/pr-pipeline.$repo.json"
    case "$repo" in
      fast|default|rigorous) ;;
      *)
        if [ -f "$legacy" ]; then
          dm_warn "legacy pipeline override '$legacy' is deprecated; move it to '$DM_CONFIG/pr-pipeline.repos/$repo.json'"
          file="$legacy"
        fi
        ;;
    esac
  fi
  [ -f "$file" ] || file="$DM_CONFIG/pr-pipeline.$tier.json"
  [ -f "$file" ] || dm_die "missing pipeline definition: $file"
  printf '%s\n' "$file"
}
pipeline_plan_from_file() {
  jq -cer '
    .gates as $g
    | if ($g | type) != "array" or ($g | length) == 0 then error("gates must be a non-empty array") else . end
    | [$g[].id] as $ids
    | if ($ids | all(type == "string" and test("^[a-z][a-z0-9-]{0,63}$")))
         and (($ids | unique | length) == ($ids | length))
         and ($g | all(.gate | type == "string" and length > 0))
      then $g else error("gate ids/types are invalid or duplicated") end
  ' "$1" || dm_die "invalid pipeline definition: $1"
}
pipeline_plan_hash() {
  printf '%s' "$1" | git -c extensions.objectFormat=sha1 hash-object --stdin
}
pipeline_plan_locked() {
  local id="$1" plan expected actual
  pipeline_require_binding_locked "$id"
  plan="$(dm_meta_get "$id" pipeline_plan)"
  expected="$(dm_meta_get "$id" pipeline_plan_hash)"
  [ -n "$plan" ] && [ -n "$expected" ] \
    || dm_die "task '$id' has no immutable pipeline plan snapshot"
  actual="$(pipeline_plan_hash "$plan")"
  [ "$actual" = "$expected" ] \
    || dm_die "task '$id' pipeline plan snapshot hash mismatch; refusing live-config fallback"
  printf '%s\n' "$plan"
}
pipeline_require_binding_locked() {
  local id="$1" repo pipeline_repo base_ref
  repo="$(dm_meta_get "$id" repo)"
  pipeline_repo="$(dm_meta_get "$id" pipeline_repo)"
  [ -n "$pipeline_repo" ] && [ "$repo" = "$pipeline_repo" ] \
    || dm_die "task '$id' repo does not match its immutable pipeline binding"
  base_ref="$(dm_meta_get "$id" pipeline_base_ref)"
  [ -n "$base_ref" ] \
    || dm_die "task '$id' has no immutable pipeline base binding"
  [ "$(dm_task_base_ref "$id")" = "$base_ref" ] \
    || dm_die "task '$id' base does not match its immutable pipeline binding"
}
pipeline_first_gate_locked() {
  pipeline_plan_locked "$1" | jq -er '.[0].id'
}
pipeline_next_gate_locked() {
  local plan
  plan="$(pipeline_plan_locked "$1")"
  jq -r --arg gate "$2" '
    [.[].id] as $ids
    | ($ids | index($gate)) as $i
    | if $i == null then error("unknown gate") else ($ids[$i + 1] // "") end
  ' <<<"$plan"
}
pipeline_gate_kind_locked() {
  local plan
  plan="$(pipeline_plan_locked "$1")"
  jq -er --arg gate "$2" '
    ([.[] | select(.id == $gate) | .gate][0] // error("unknown gate"))
  ' <<<"$plan"
}
next_generation() {
  case "${1:-}" in ''|*[!0-9]*) printf '1\n' ;; *) printf '%s\n' "$(( $1 + 1 ))" ;; esac
}
require_nonterminal_locked() {
  local id="$1"
  dm_task_terminal_locked "$id" && dm_die "task '$id' is terminal; no new pipeline or waiter work may be scheduled"
  return 0
}
gate_next_locked() {
  local id="$1" gate="$2" recovery
  recovery="$(dm_meta_get "$id" pipeline_recovery_resume_gate)"
  if [ -n "$recovery" ]; then
    case "$gate" in
      rebase) printf 'merge-gate-review\n' ;;
      merge-gate-review) printf 'final-tests\n' ;;
      final-tests) printf '%s\n' "$recovery" ;;
      *) dm_die "task '$id' has malformed recovery sequence at gate '$gate'" ;;
    esac
  else
    pipeline_next_gate_locked "$id" "$gate"
  fi
}
valid_thread_name() {
  case "${1:-}" in ''|*[!a-z0-9_]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}
valid_integration_gate() {
  case "${1:-}" in
    rebase|merge-gate-review|final-tests|verify|security|pr|land) return 0 ;;
    *) return 1 ;;
  esac
}

pipeline_snapshot_locked() {
  local snapshot
  snapshot="$(dm_task_git_snapshot "$1")"
  PIPELINE_BASE_REF="$(dm_task_base_ref "$1")"
  PIPELINE_BASE_SHA="${snapshot%%$'\t'*}"
  PIPELINE_HEAD_SHA="${snapshot#*$'\t'}"
  [ -n "$PIPELINE_BASE_SHA" ] && [ -n "$PIPELINE_HEAD_SHA" ] \
    || dm_die "could not capture exact pipeline git snapshot for '$1'"
}

pipeline_clear_proofs_locked() {
  dm_meta_set_fields_locked "$1" \
    tests "" tests_base_sha "" tests_head_sha "" \
    security_scan "" security_scan_base_sha "" security_scan_head_sha "" \
    security_review "" security_review_base_sha "" security_review_head_sha "" \
    pr_head "" pr_base_ref "" pr_base_sha ""
}

pipeline_rewind_canonical_locked() {
  local id="$1" reason="$2" first
  first="$(pipeline_first_gate_locked "$id")"
  dm_task_transition_locked "$id" working "$reason; proofs invalidated and '$first' ready" \
    pipeline_gate "$first" pipeline_state ready pipeline_epoch "" \
    pipeline_owner_thread "" pipeline_owner_agent "" gate_started_at "" \
    pipeline_claim_base_sha "" pipeline_claim_head_sha "" \
    pipeline_blocked_by "" pipeline_blocked_reason "" pipeline_recovery_resume_gate "" \
    pipeline_last_gate "" pipeline_last_evidence "" \
    pipeline_last_base_sha "$PIPELINE_BASE_SHA" pipeline_last_head_sha "$PIPELINE_HEAD_SHA"
  pipeline_clear_proofs_locked "$id"
}

pipeline_recover_base_locked() {
  local id="$1" reason="$2" resume
  resume="$(dm_meta_get "$id" pipeline_recovery_resume_gate)"
  [ -n "$resume" ] || resume="$(dm_meta_get "$id" pipeline_gate)"
  dm_task_transition_locked "$id" working "$reason; rebase recovery required" \
    pipeline_gate rebase pipeline_state ready pipeline_epoch "" \
    pipeline_owner_thread "" pipeline_owner_agent "" gate_started_at "" \
    pipeline_claim_base_sha "" pipeline_claim_head_sha "" \
    pipeline_blocked_by "" pipeline_blocked_reason "" \
    pipeline_recovery_resume_gate "$resume" \
    pipeline_last_gate "" pipeline_last_evidence "" \
    pipeline_last_base_sha "$PIPELINE_BASE_SHA" pipeline_last_head_sha "$PIPELINE_HEAD_SHA"
  pipeline_clear_proofs_locked "$id"
}

pipeline_invalidate_changed_locked() {
  local id="$1" anchor_base="$2" anchor_head="$3" reason="$4"
  if [ "$PIPELINE_HEAD_SHA" != "$anchor_head" ]; then
    pipeline_rewind_canonical_locked "$id" "$reason: HEAD changed"
  elif [ "$PIPELINE_BASE_SHA" != "$anchor_base" ] && [ -n "$(dm_meta_get "$id" pipeline_last_gate)" ]; then
    pipeline_recover_base_locked "$id" "$reason: base advanced"
  else
    pipeline_rewind_canonical_locked "$id" "$reason: base changed before reviewed proof"
  fi
}

pipeline_rewind_if_changed_locked() {
  local id="$1" state anchor_base anchor_head
  state="$(dm_meta_get "$id" pipeline_state)"
  case "$state" in ready|complete) ;; *) return 0 ;; esac
  anchor_base="$(dm_meta_get "$id" pipeline_last_base_sha)"
  anchor_head="$(dm_meta_get "$id" pipeline_last_head_sha)"
  [ -n "$anchor_base" ] && [ -n "$anchor_head" ] || return 0
  pipeline_snapshot_locked "$id"
  [ "$PIPELINE_BASE_SHA" = "$anchor_base" ] && [ "$PIPELINE_HEAD_SHA" = "$anchor_head" ] \
    && return 0
  pipeline_invalidate_changed_locked "$id" "$anchor_base" "$anchor_head" \
    "git snapshot changed after gate completion"
}

pipeline_final_gate_locked() {
  pipeline_plan_locked "$1" | jq -er '.[-1].id'
}

pipeline_check_open_locked() {
  local id="$1" final claim_base claim_head last_base last_head
  final="$(pipeline_final_gate_locked "$id")"
  [ "$(pipeline_gate_kind_locked "$id" "$final")" = "pr" ] \
    || dm_die "approved pipeline does not end in a PR proof gate"
  [ "$(dm_meta_get "$id" pipeline_state)" = "running" ] \
    && [ "$(dm_meta_get "$id" pipeline_gate)" = "$final" ] \
    || dm_die "PR open requires the approved pipeline's final PR gate to be running"
  claim_base="$(dm_meta_get "$id" pipeline_claim_base_sha)"
  claim_head="$(dm_meta_get "$id" pipeline_claim_head_sha)"
  last_base="$(dm_meta_get "$id" pipeline_last_base_sha)"
  last_head="$(dm_meta_get "$id" pipeline_last_head_sha)"
  if [ "$PIPELINE_BASE_SHA" != "$claim_base" ] || [ "$PIPELINE_HEAD_SHA" != "$claim_head" ]; then
    pipeline_invalidate_changed_locked "$id" "$claim_base" "$claim_head" \
      "git snapshot changed before PR open"
    dm_die "PR open proof became stale; required gates were rescheduled"
  fi
  [ -n "$(dm_meta_get "$id" pipeline_last_gate)" ] \
    && [ "$PIPELINE_BASE_SHA" = "$last_base" ] \
    && [ "$PIPELINE_HEAD_SHA" = "$last_head" ] \
    || dm_die "PR open requires a current completed proof snapshot before the final PR gate"
}

pipeline_check_merge_locked() {
  local id="$1" final url anchor_base anchor_head
  final="$(pipeline_final_gate_locked "$id")"
  anchor_base="$(dm_meta_get "$id" pipeline_last_base_sha)"
  anchor_head="$(dm_meta_get "$id" pipeline_last_head_sha)"
  if [ -n "$anchor_base" ] && [ -n "$anchor_head" ] \
    && { [ "$PIPELINE_BASE_SHA" != "$anchor_base" ] || [ "$PIPELINE_HEAD_SHA" != "$anchor_head" ]; }; then
    pipeline_invalidate_changed_locked "$id" "$anchor_base" "$anchor_head" \
      "git snapshot changed after pipeline completion"
    dm_die "merge proof became stale; required gates were rescheduled"
  fi
  [ "$(pipeline_gate_kind_locked "$id" "$final")" = "pr" ] \
    && [ "$(dm_meta_get "$id" pipeline_state)" = "complete" ] \
    && [ "$(dm_meta_get "$id" pipeline_gate)" = "$final" ] \
    && [ "$(dm_meta_get "$id" pipeline_last_gate)" = "$final" ] \
    || dm_die "merge requires a complete approved pipeline ending in its PR proof gate"
  url="$(dm_meta_get "$id" pr)"
  [ "$(dm_meta_get "$id" pipeline_last_evidence)" = "pr:$url" ] \
    && [ "$(dm_meta_get "$id" pr_head)" = "$PIPELINE_HEAD_SHA" ] \
    && [ "$(dm_meta_get "$id" pr_base_ref)" = "$PIPELINE_BASE_REF" ] \
    && [ "$(dm_meta_get "$id" pr_base_sha)" = "$PIPELINE_BASE_SHA" ] \
    || dm_die "merge requires the sanctioned PR proof for the exact current base and HEAD"
}

pipeline_validate_evidence_locked() {
  local id="$1" gate="$2" base_sha="$3" head_sha="$4" supplied="$5"
  local kind result scan review tier url pr_head pr_base_ref pr_base_sha
  case "$gate" in
    rebase) kind=rebase ;;
    merge-gate-review) kind=review ;;
    final-tests) kind=tests ;;
    *) kind="$(pipeline_gate_kind_locked "$id" "$gate")" ;;
  esac
  case "$kind" in
    tests)
      result="$(dm_meta_get "$id" tests)"
      case "$result" in pass|skip) ;; *) dm_die "cannot complete '$gate': no sanctioned tests pass/skip signal" ;; esac
      [ "$(dm_meta_get "$id" tests_base_sha)" = "$base_sha" ] \
        && [ "$(dm_meta_get "$id" tests_head_sha)" = "$head_sha" ] \
        || dm_die "cannot complete '$gate': tests signal is stale for the current base/HEAD"
      PIPELINE_VALIDATED_EVIDENCE="tests:$result"
      ;;
    security)
      scan="$(dm_meta_get "$id" security_scan)"
      case "$scan" in clear|hit) ;; *) dm_die "cannot complete '$gate': run sanctioned dm-pr.sh security-scan first" ;; esac
      [ "$(dm_meta_get "$id" security_scan_base_sha)" = "$base_sha" ] \
        && [ "$(dm_meta_get "$id" security_scan_head_sha)" = "$head_sha" ] \
        || dm_die "cannot complete '$gate': security scan is stale for the current base/HEAD"
      tier="$(dm_meta_get "$id" pipeline_tier)"
      if [ "$scan" = "hit" ] || [ "$tier" = "rigorous" ]; then
        [ "$supplied" = "security-review-pass" ] \
          || dm_die "cannot complete '$gate': this pipeline requires 'security-review-pass'"
        review="$(dm_meta_get "$id" security_review)"
        [ "$review" = "pass" ] \
          || dm_die "cannot complete '$gate': no sanctioned focused security-review PASS evidence"
        [ "$(dm_meta_get "$id" security_review_base_sha)" = "$base_sha" ] \
          && [ "$(dm_meta_get "$id" security_review_head_sha)" = "$head_sha" ] \
          || dm_die "cannot complete '$gate': security review is stale for the current base/HEAD"
      fi
      PIPELINE_VALIDATED_EVIDENCE="security:$scan:$supplied"
      ;;
    pr)
      url="$(dm_meta_get "$id" pr)"
      pr_head="$(dm_meta_get "$id" pr_head)"
      pr_base_ref="$(dm_meta_get "$id" pr_base_ref)"
      pr_base_sha="$(dm_meta_get "$id" pr_base_sha)"
      [ -n "$url" ] && [ "$pr_head" = "$head_sha" ] \
        && [ "$pr_base_ref" = "$(dm_meta_get "$id" pipeline_base_ref)" ] \
        && [ "$pr_base_sha" = "$base_sha" ] \
        || dm_die "cannot complete '$gate': sanctioned PR signal is missing or stale for current base/HEAD"
      PIPELINE_VALIDATED_EVIDENCE="pr:$url"
      ;;
    *)
      # Runtime identities are correlation, not OS authentication. Git snapshots
      # and sanctioned tool signals are enforced; reviewer assertions remain in
      # the same-user scheduler trust boundary.
      PIPELINE_VALIDATED_EVIDENCE="$supplied"
      ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-task.sh new <id> --kind ship|scout --repo R [--mode M] [--title T]"
    dm_require_id "$id"
    kind=""; repo=""; mode=""; title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) kind="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --mode) mode="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    # Name the flag the operator actually typed; dm_task_create re-checks both as
    # the library-side boundary. Also keeps an empty repo out of the registry read.
    dm_valid_task_kind "$kind" || dm_die "--kind must be ship|scout"
    [ -n "$repo" ] || dm_die "--repo is required"
    # inherit mode from the repo registry unless overridden
    [ -n "$mode" ] || mode="$(dm_registry_get "$repo" mode)"
    [ -n "$mode" ] || mode="pipeline"
    dm_task_create "$id" "$kind" "$repo" "$mode" "$title"
    dm_info "created task $id (kind=$kind repo=$repo mode=$mode)"
    ;;

  set)
    id="${1:-}"; key="${2:-}"; value="${3:-}"
    [ -n "$id" ] && [ -n "$key" ] || dm_die "usage: dm-task.sh set <id> <key> <value>"
    # The PR-tracking fields are DERIVED from GitHub by dm-pr.sh (check/open/
    # merge) and are the trusted landing signal `dm-task.sh state` reads. Refuse
    # to hand-set them here: `set pr_state MERGED` would otherwise forge a
    # terminal landing over unlanded work (the same forge the `event merged`
    # reservation blocks). The sanctioned writer uses dm_meta_set directly.
    # `pr_head` too: dm-worktree.sh landed compares HEAD against it, so a
    # hand-set value would make post-merge commits look landed and removable.
    # `base` gets the same protection: it feeds `gh pr create --base` (via
    # dm_pr_base_for), so a hand-forged value would silently retarget a sub-PR.
    # It is recorded only by `dm-worktree.sh create --base`, which also writes
    # directly via dm_meta_set and so is unaffected by this CLI-only guard.
    case "$key" in
      repo) dm_die "'repo' is immutable after task creation" ;;
      pr|pr_state|merge_state|pr_check_snapshot|pr_head|pr_base_ref|pr_base_sha|pr_live_head|pr_live_base_ref|pr_live_base_sha) dm_die "'$key' is a PR-tracking field maintained by dm-pr.sh (check/open/merge); it must not be set by hand" ;;
      base) dm_die "'base' is recorded by dm-worktree.sh create --base; it must not be set by hand" ;;
      worktree) dm_die "'worktree' is maintained by dm-worktree.sh create/remove; it must not be set by hand" ;;
      approved_at|pipeline_repo|pipeline_base_ref|pipeline_base_sha|pipeline_tier|pipeline_plan|pipeline_plan_hash|pipeline_plan_source|pipeline_gate|pipeline_state|pipeline_generation|pipeline_epoch|pipeline_owner_thread|pipeline_owner_agent|gate_started_at|pipeline_blocked_by|pipeline_blocked_reason|pipeline_recovery_resume_gate|pipeline_claim_base_sha|pipeline_claim_head_sha|pipeline_last_base_sha|pipeline_last_head_sha|pipeline_last_gate|pipeline_last_evidence)
        dm_die "'$key' is pipeline state maintained by dm-task.sh approve/gate; it must not be set by hand" ;;
      tests|tests_base_sha|tests_head_sha)
        dm_die "'$key' is test evidence maintained by dm-test.sh; it must not be set by hand" ;;
      security_scan|security_scan_base_sha|security_scan_head_sha|security_review|security_review_base_sha|security_review_head_sha)
        dm_die "'$key' is security evidence maintained by dm-pr.sh security-scan/security-review; it must not be set by hand" ;;
      waiter_thread_name|waiter_agent_id|waiter_state|waiter_generation|waiter_epoch)
        dm_die "'$key' is review-waiter state maintained by dm-task.sh waiter; it must not be set by hand" ;;
      review_protocol|review_session_state|review_session_started_at|review_session_generation|review_session_epoch|review_session_mode)
        dm_die "'$key' is review-session state maintained by dm-lavish.sh; it must not be set by hand" ;;
      transition_seq|transition_state|transition_note|transition_at|transition_audited_seq)
        dm_die "'$key' is a transition journal field maintained internally; it must not be set by hand" ;;
    esac
    dm_meta_set "$id" "$key" "$value"
    ;;

  approve)
    id="${1:-}"; tier="${2:-}"
    [ "$#" -eq 2 ] && [ -n "$id" ] && [ -n "$tier" ] \
      || dm_die "usage: dm-task.sh approve <id> <fast|default|rigorous>"
    dm_require_id "$id"
    valid_pipeline_tier "$tier" || dm_die "pipeline tier must be fast|default|rigorous"
    repo="$(dm_meta_get "$id" repo)"
    dm_require_id "$repo"
    config="$(pipeline_config "$repo" "$tier")"
    plan="$(pipeline_plan_from_file "$config")"
    plan_hash="$(pipeline_plan_hash "$plan")"
    gate="$(jq -er '.[0].id' <<<"$plan")"
    plan_source="${config#"$DM_CONFIG"/}"
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    require_nonterminal_locked "$id"
    [ "$(dm_meta_get "$id" kind)" = "ship" ] || dm_die "only ship tasks enter a delivery pipeline"
    [ "$(dm_meta_get "$id" mode)" != "local-only" ] || dm_die "local-only tasks do not enter a PR pipeline"
    approved_at="$(dm_meta_get "$id" approved_at)"
    [ -z "$approved_at" ] || dm_die "task '$id' is already approved at $approved_at"
    review_protocol="$(dm_meta_get "$id" review_protocol)"
    case "$review_protocol" in
      "")
        ;;
      "$DM_CODEX_REVIEW_PROTOCOL")
        [ "$(dm_meta_get "$id" review_session_state)" = "terminal" ] \
          || dm_die "task '$id' has not completed its guarded Codex review"
        dm_review_active "$id" \
          && dm_die "task '$id' guarded Codex review still has a live session or notification waiter"
        ;;
      *)
        dm_die "task '$id' has unknown review protocol '$review_protocol'; refusing approval"
        ;;
    esac
    pipeline_snapshot_locked "$id"
    approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dm_task_transition_locked "$id" working "approved; snapshotted $plan_source ($plan_hash); gate '$gate' ready to schedule" \
      approved_at "$approved_at" pipeline_repo "$repo" \
      pipeline_base_ref "$PIPELINE_BASE_REF" pipeline_base_sha "$PIPELINE_BASE_SHA" \
      pipeline_tier "$tier" pipeline_plan "$plan" \
      pipeline_plan_hash "$plan_hash" pipeline_plan_source "$plan_source" pipeline_gate "$gate" \
      pipeline_state ready pipeline_generation 0 pipeline_epoch "" \
      pipeline_owner_thread "" pipeline_owner_agent "" gate_started_at "" \
      pipeline_blocked_by "" pipeline_blocked_reason "" pipeline_recovery_resume_gate "" \
      pipeline_claim_base_sha "" pipeline_claim_head_sha "" \
      pipeline_last_base_sha "$PIPELINE_BASE_SHA" pipeline_last_head_sha "$PIPELINE_HEAD_SHA"
    dm_unlock "$meta"
    ;;

  pipeline-check)
    id="${1:-}"; purpose="${2:-}"; repo="${3:-}"; base_ref="${4:-}"
    base_sha="${5:-}"; head_sha="${6:-}"
    [ "$#" -eq 6 ] && [ -n "$id" ] && [ -n "$repo" ] \
      && [ -n "$base_ref" ] && [ -n "$base_sha" ] && [ -n "$head_sha" ] \
      || dm_die "usage: dm-task.sh pipeline-check <id> <open|merge> <repo> <base-ref> <base-sha> <head-sha>"
    case "$purpose" in open|merge) ;; *) dm_die "pipeline-check purpose must be open|merge" ;; esac
    dm_require_id "$id"; dm_require_id "$repo"
    git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 \
      || dm_die "invalid pipeline-check base ref '$base_ref'"
    case "$base_sha$head_sha" in *[!0-9A-Fa-f]*) dm_die "pipeline-check SHAs must be Git object ids" ;; esac
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    pipeline_require_binding_locked "$id"
    [ "$(dm_meta_get "$id" pipeline_repo)" = "$repo" ] \
      || { dm_unlock "$meta"; dm_die "pipeline repo binding does not match '$repo'"; }
    [ "$(dm_meta_get "$id" pipeline_base_ref)" = "$base_ref" ] \
      || { dm_unlock "$meta"; dm_die "PR base '$base_ref' does not match approved pipeline base"; }
    pipeline_snapshot_locked "$id"
    [ "$PIPELINE_BASE_SHA" = "$base_sha" ] && [ "$PIPELINE_HEAD_SHA" = "$head_sha" ] \
      || { dm_unlock "$meta"; dm_die "live PR base/HEAD does not match the exact local task snapshot"; }
    case "$purpose" in
      open) pipeline_check_open_locked "$id" ;;
      merge) pipeline_check_merge_locked "$id" ;;
    esac
    dm_unlock "$meta"
    ;;

  gate)
    id="${1:-}"; action="${2:-}"; gate="${3:-}"; shift 3 2>/dev/null || true
    [ -n "$id" ] && [ -n "$action" ] && [ -n "$gate" ] \
      || dm_die "usage: dm-task.sh gate <id> <claim|start|release|block|ready|complete> <gate> ..."
    dm_require_id "$id"
    valid_pipeline_gate "$gate" || dm_die "invalid pipeline gate: '$gate'"
    case "$action" in
      ready)
        [ "$#" -eq 0 ] || dm_die "usage: dm-task.sh gate <id> ready <gate>"
        ;;
      claim)
        thread="${1:-}"
        [ "$#" -eq 1 ] && valid_thread_name "$thread" \
          || dm_die "usage: dm-task.sh gate <id> claim <gate> <thread-name matching [a-z0-9_]+>"
        ;;
      start)
        epoch="${1:-}"; thread="${2:-}"; agent="${3:-}"
        [ "$#" -eq 3 ] && [ -n "$epoch" ] && valid_thread_name "$thread" && [ -n "$agent" ] \
          || dm_die "usage: dm-task.sh gate <id> start <gate> <epoch> <thread-name> <agent-id>"
        dm_require_single_line "pipeline owner agent id" "$agent"
        ;;
      release)
        epoch="${1:-}"; thread="${2:-}"; reason="${3:-}"
        [ "$#" -eq 3 ] && [ -n "$epoch" ] && valid_thread_name "$thread" && [ -n "$reason" ] \
          || dm_die "usage: dm-task.sh gate <id> release <gate> <epoch> <thread-name> <reason>"
        dm_require_single_line "pipeline claim release reason" "$reason"
        ;;
      block)
        blocker="${1:-}"; reason="${2:-}"
        [ "$#" -eq 2 ] && [ -n "$blocker" ] && [ -n "$reason" ] \
          || dm_die "usage: dm-task.sh gate <id> block <integration-gate> <blocker-id> <reason>"
        valid_integration_gate "$gate" \
          || dm_die "overlap may block only integration/finalization gates: rebase|merge-gate-review|final-tests|verify|security|pr|land"
        dm_require_id "$blocker"
        [ "$blocker" != "$id" ] || dm_die "a task cannot block its own pipeline"
        [ -f "$(dm_meta_path "$blocker")" ] || dm_die "no active blocker task: $blocker"
        dm_require_single_line "pipeline blocker reason" "$reason"
        ;;
      complete)
        epoch="${1:-}"; agent="${2:-}"; evidence="${3:-}"
        [ "$#" -eq 3 ] && [ -n "$epoch" ] && [ -n "$agent" ] && [ -n "$evidence" ] \
          || dm_die "usage: dm-task.sh gate <id> complete <gate> <epoch> <agent-id> <evidence>"
        dm_require_single_line "pipeline owner agent id" "$agent"
        dm_require_single_line "pipeline gate evidence" "$evidence"
        ;;
      *) dm_die "gate action must be claim|start|release|block|ready|complete" ;;
    esac
    meta="$(dm_meta_path "$id")"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    require_nonterminal_locked "$id"
    [ -n "$(dm_meta_get "$id" approved_at)" ] \
      || dm_die "task '$id' has no recorded approval; run dm-task.sh approve first"
    current_gate="$(dm_meta_get "$id" pipeline_gate)"
    current_state="$(dm_meta_get "$id" pipeline_state)"
    current_epoch="$(dm_meta_get "$id" pipeline_epoch)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$action" in
      ready)
        [ "$current_state" = "blocked" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot ready '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        blocker="$(dm_meta_get "$id" pipeline_blocked_by)"
        if [ -f "$(dm_meta_path "$blocker")" ]; then
          dm_task_terminal_locked "$blocker" \
            || dm_die "integration blocker '$blocker' is not terminal; gate remains blocked"
        elif [ ! -f "$DM_STATE/archive/$blocker.meta" ]; then
          dm_die "integration blocker '$blocker' has no active or archived task record"
        fi
        recovery_resume="$(dm_meta_get "$id" pipeline_recovery_resume_gate)"
        [ -n "$recovery_resume" ] || recovery_resume="$gate"
        dm_task_transition_locked "$id" working "blocker cleared; recovery rebase ready to schedule" \
          pipeline_gate rebase pipeline_state ready pipeline_epoch "" \
          pipeline_owner_thread "" pipeline_owner_agent "" gate_started_at "" \
          pipeline_blocked_by "" pipeline_blocked_reason "" \
          pipeline_recovery_resume_gate "$recovery_resume"
        ;;
      claim)
        pipeline_rewind_if_changed_locked "$id"
        current_gate="$(dm_meta_get "$id" pipeline_gate)"
        current_state="$(dm_meta_get "$id" pipeline_state)"
        [ "$current_state" = "ready" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot claim '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        pipeline_snapshot_locked "$id"
        generation="$(next_generation "$(dm_meta_get "$id" pipeline_generation)")"
        dm_task_transition_locked "$id" working "pipeline gate '$gate' claimed by '$thread' (epoch $generation)" \
          pipeline_state claimed pipeline_generation "$generation" pipeline_epoch "$generation" \
          pipeline_owner_thread "$thread" pipeline_owner_agent "" gate_started_at "" \
          pipeline_claim_base_sha "$PIPELINE_BASE_SHA" pipeline_claim_head_sha "$PIPELINE_HEAD_SHA"
        dm_unlock "$meta"
        printf '%s\n' "$generation"
        exit 0
        ;;
      start)
        [ "$current_state" = "claimed" ] && [ "$current_gate" = "$gate" ] && [ "$current_epoch" = "$epoch" ] \
          || dm_die "cannot start '$gate' epoch '$epoch': current gate is '${current_gate:-unset}' in state '${current_state:-unset}' epoch '${current_epoch:-unset}'"
        [ "$(dm_meta_get "$id" pipeline_owner_thread)" = "$thread" ] \
          || dm_die "cannot start '$gate': claim owner thread does not match '$thread'"
        pipeline_snapshot_locked "$id"
        [ "$PIPELINE_BASE_SHA" = "$(dm_meta_get "$id" pipeline_claim_base_sha)" ] \
          && [ "$PIPELINE_HEAD_SHA" = "$(dm_meta_get "$id" pipeline_claim_head_sha)" ] \
          || dm_die "cannot start '$gate': base/HEAD changed after claim"
        dm_task_transition_locked "$id" working "pipeline gate '$gate' started by '$agent' (epoch $epoch)" \
          pipeline_state running pipeline_owner_agent "$agent" gate_started_at "$now"
        ;;
      release)
        [ "$current_state" = "claimed" ] && [ "$current_gate" = "$gate" ] && [ "$current_epoch" = "$epoch" ] \
          || dm_die "cannot release '$gate' epoch '$epoch': claim no longer matches"
        [ "$(dm_meta_get "$id" pipeline_owner_thread)" = "$thread" ] \
          || dm_die "cannot release '$gate': claim owner thread does not match '$thread'"
        dm_task_transition_locked "$id" working "pipeline gate '$gate' claim released: $reason" \
          pipeline_state ready pipeline_epoch "" pipeline_owner_thread "" \
          pipeline_owner_agent "" gate_started_at "" \
          pipeline_claim_base_sha "" pipeline_claim_head_sha ""
        ;;
      block)
        [ "$current_state" = "ready" ] && [ "$current_gate" = "$gate" ] \
          || dm_die "cannot block '$gate': current gate is '${current_gate:-unset}' in state '${current_state:-unset}'"
        dm_task_transition_locked "$id" paused "integration gate '$gate' waits for '$blocker': $reason" \
          pipeline_state blocked gate_started_at "" \
          pipeline_blocked_by "$blocker" pipeline_blocked_reason "$reason"
        ;;
      complete)
        [ "$current_state" = "running" ] && [ "$current_gate" = "$gate" ] && [ "$current_epoch" = "$epoch" ] \
          || dm_die "cannot complete '$gate' epoch '$epoch': current gate is '${current_gate:-unset}' in state '${current_state:-unset}' epoch '${current_epoch:-unset}'"
        [ "$(dm_meta_get "$id" pipeline_owner_agent)" = "$agent" ] \
          || dm_die "cannot complete '$gate': runtime owner does not match '$agent'"
        claim_base="$(dm_meta_get "$id" pipeline_claim_base_sha)"
        claim_head="$(dm_meta_get "$id" pipeline_claim_head_sha)"
        [ -n "$claim_base" ] && [ -n "$claim_head" ] \
          || dm_die "cannot complete '$gate': claim has no exact git snapshot"
        pipeline_snapshot_locked "$id"
        kind="$gate"
        case "$gate" in
          rebase) kind=rebase ;;
          merge-gate-review) kind=review ;;
          final-tests) kind=tests ;;
          *) kind="$(pipeline_gate_kind_locked "$id" "$gate")" ;;
        esac
        case "$kind" in
          rebase) ;;
          fix)
            [ "$PIPELINE_BASE_SHA" = "$claim_base" ] \
              || dm_die "cannot complete '$gate': base changed during a fix gate"
            ;;
          *)
            [ "$PIPELINE_BASE_SHA" = "$claim_base" ] && [ "$PIPELINE_HEAD_SHA" = "$claim_head" ] \
              || dm_die "cannot complete '$gate': exact base/HEAD changed during a non-mutating gate"
            ;;
        esac
        pipeline_validate_evidence_locked "$id" "$gate" "$PIPELINE_BASE_SHA" "$PIPELINE_HEAD_SHA" "$evidence"
        next_gate="$(gate_next_locked "$id" "$gate")"
        if [ -n "$next_gate" ]; then
          if [ "$gate" = "final-tests" ] && [ -n "$(dm_meta_get "$id" pipeline_recovery_resume_gate)" ]; then
            recovery_resume=""
          else
            recovery_resume="$(dm_meta_get "$id" pipeline_recovery_resume_gate)"
          fi
          dm_task_transition_locked "$id" working "pipeline gate '$gate' complete ($evidence); '$next_gate' ready" \
            pipeline_gate "$next_gate" pipeline_state ready gate_started_at "" \
            pipeline_epoch "" pipeline_owner_thread "" pipeline_owner_agent "" \
            pipeline_claim_base_sha "" pipeline_claim_head_sha "" \
            pipeline_blocked_by "" pipeline_blocked_reason "" \
            pipeline_recovery_resume_gate "$recovery_resume" \
            pipeline_last_gate "$gate" pipeline_last_evidence "$PIPELINE_VALIDATED_EVIDENCE" \
            pipeline_last_base_sha "$PIPELINE_BASE_SHA" pipeline_last_head_sha "$PIPELINE_HEAD_SHA"
        else
          dm_task_transition_locked "$id" working "pipeline gate '$gate' complete ($evidence); pipeline complete" \
            pipeline_state complete pipeline_epoch "" pipeline_owner_thread "" \
            pipeline_owner_agent "" gate_started_at "" \
            pipeline_claim_base_sha "" pipeline_claim_head_sha "" \
            pipeline_blocked_by "" pipeline_blocked_reason "" pipeline_recovery_resume_gate "" \
            pipeline_last_gate "$gate" pipeline_last_evidence "$PIPELINE_VALIDATED_EVIDENCE" \
            pipeline_last_base_sha "$PIPELINE_BASE_SHA" pipeline_last_head_sha "$PIPELINE_HEAD_SHA"
        fi
        ;;
    esac
    dm_unlock "$meta"
    ;;

  ready-gates)
    rows="$(mktemp "${TMPDIR:-/tmp}/dm-ready-gates.XXXXXX")"
    trap 'rm -f "$rows"' EXIT
    printf 'ID\tTIER\tGATE\tAPPROVED\n' >"$rows"
    while IFS= read -r id; do
      case "$(dm_meta_get "$id" pipeline_state)" in ready|complete) ;; *) continue ;; esac
      meta="$(dm_meta_path "$id")"
      dm_lock "$meta"
      dm_transition_reconcile_locked "$id"
      if ! dm_task_terminal_locked "$id"; then
        pipeline_rewind_if_changed_locked "$id"
      fi
      if [ "$(dm_meta_get "$id" pipeline_state)" = "ready" ] && ! dm_task_terminal_locked "$id"; then
        printf '%s\t%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" pipeline_tier)" \
          "$(dm_meta_get "$id" pipeline_gate)" "$(dm_meta_get "$id" approved_at)" >>"$rows"
      fi
      dm_unlock "$meta"
    done < <(dm_all_task_ids)
    header="$(sed -n '1p' "$rows")"
    body="$(sed '1d' "$rows" | sort -t$'\t' -k4,4)"
    { printf '%s\n' "$header"; [ -z "$body" ] || printf '%s\n' "$body"; } >"$rows"
    if command -v column >/dev/null 2>&1; then column -t -s$'\t' <"$rows"; else cat "$rows"; fi
    rm -f "$rows"
    trap - EXIT
    ;;

  waiter)
    id="${1:-}"; action="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$id" ] && [ -n "$action" ] \
      || dm_die "usage: dm-task.sh waiter <id> <prepare|active|idle|terminal|cancel|recover> [...]"
    dm_require_id "$id"
    case "$action" in
      prepare)
        thread="${1:-}"
        [ "$#" -eq 1 ] && [ -n "$thread" ] \
          || dm_die "usage: dm-task.sh waiter <id> prepare <thread-name>"
        valid_thread_name "$thread" || dm_die "waiter thread name must match [a-z0-9_]+ and be <= 64 characters"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        require_nonterminal_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        old_thread="$(dm_meta_get "$id" waiter_thread_name)"
        old_agent="$(dm_meta_get "$id" waiter_agent_id)"
        case "$old_state" in
          prepared) dm_die "task '$id' already has a prepared waiter; duplicate launch refused" ;;
          ''|terminal)
            [ -z "$old_thread" ] && [ -z "$old_agent" ] \
              || dm_die "task '$id' has legacy waiter identity without a live state; reconcile it before launch"
            ;;
          idle)
            dm_die "task '$id' has idle waiter '$old_agent'; reuse that exact identity instead of preparing another"
            ;;
          active)
            dm_die "task '$id' already has an active waiter; reconcile it before preparing another"
            ;;
          *)
            dm_die "task '$id' has unknown waiter state '$old_state'; reconcile it before launch"
            ;;
        esac
        epoch="$(next_generation "$(dm_meta_get "$id" waiter_generation)")"
        dm_task_transition_locked "$id" working "notification waiter '$thread' reserved (epoch $epoch)" \
          waiter_thread_name "$thread" waiter_agent_id "" waiter_state prepared \
          waiter_generation "$epoch" waiter_epoch "$epoch"
        dm_unlock "$meta"
        printf '%s\n' "$epoch"
        ;;
      active)
        thread="${1:-}"; epoch="${2:-}"; agent="${3:-}"
        [ "$#" -eq 3 ] && [ -n "$thread" ] && [ -n "$epoch" ] && [ -n "$agent" ] \
          || dm_die "usage: dm-task.sh waiter <id> active <thread-name> <epoch> <agent-id>"
        valid_thread_name "$thread" || dm_die "invalid waiter thread name"
        dm_require_single_line "waiter agent id" "$agent"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        require_nonterminal_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        old_thread="$(dm_meta_get "$id" waiter_thread_name)"
        old_agent="$(dm_meta_get "$id" waiter_agent_id)"
        case "$old_state" in
          prepared)
            [ "$old_thread" = "$thread" ] && [ -z "$old_agent" ] && [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ] \
              || dm_die "task '$id' prepared waiter '$old_thread'; refusing mismatched or malformed activation"
            ;;
          idle|active)
            [ "$old_thread" = "$thread" ] && [ "$old_agent" = "$agent" ] && [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ] \
              || dm_die "task '$id' already records waiter '${old_agent:-missing}'; refusing ambiguous replacement"
            ;;
          *)
            dm_die "task '$id' has no prepared or reusable waiter; prepare its identity before activation"
            ;;
        esac
        dm_task_transition_locked "$id" working "notification waiter '$agent' active (epoch $epoch)" \
          waiter_thread_name "$thread" waiter_agent_id "$agent" waiter_state active
        dm_unlock "$meta"
        ;;
      idle)
        epoch="${1:-}"; agent="${2:-}"
        [ "$#" -eq 2 ] && [ -n "$epoch" ] && [ -n "$agent" ] \
          || dm_die "usage: dm-task.sh waiter <id> idle <epoch> <agent-id>"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        old_state="$(dm_meta_get "$id" waiter_state)"
        [ "$old_state" = "active" ] || [ "$old_state" = "idle" ] \
          || dm_die "task '$id' has no active waiter to keep idle"
        [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ] \
          && [ "$(dm_meta_get "$id" waiter_agent_id)" = "$agent" ] \
          || dm_die "stale waiter idle transition refused"
        dm_task_transition_locked "$id" working "notification waiter '$agent' idle (epoch $epoch)" waiter_state idle
        dm_unlock "$meta"
        ;;
      terminal)
        epoch="${1:-}"; agent="${2:-}"
        [ "$#" -eq 2 ] && [ -n "$epoch" ] && [ -n "$agent" ] \
          || dm_die "usage: dm-task.sh waiter <id> terminal <epoch> <agent-id>"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ] \
          && [ "$(dm_meta_get "$id" waiter_agent_id)" = "$agent" ] \
          || dm_die "stale waiter terminal transition refused"
        dm_task_transition_locked "$id" working "notification waiter '$agent' terminal (epoch $epoch)" \
          waiter_thread_name "" waiter_agent_id "" waiter_state terminal waiter_epoch ""
        dm_unlock "$meta"
        ;;
      cancel)
        epoch="${1:-}"
        [ "$#" -eq 1 ] && [ -n "$epoch" ] || dm_die "usage: dm-task.sh waiter <id> cancel <epoch>"
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        [ "$(dm_meta_get "$id" waiter_state)" = "prepared" ] \
          && [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ] \
          || dm_die "stale waiter cancellation refused"
        dm_task_transition_locked "$id" working "notification waiter reservation cancelled (epoch $epoch)" \
          waiter_thread_name "" waiter_agent_id "" waiter_state terminal waiter_epoch ""
        dm_unlock "$meta"
        ;;
      recover)
        expected_state="${1:-}"; epoch="${2:-}"; agent="${3:-}"; reason="${4:-}"
        [ "$#" -eq 4 ] && [ -n "$expected_state" ] && [ -n "$reason" ] \
          || dm_die "usage: dm-task.sh waiter <id> recover <expected-state> <epoch-or--> <agent-or--> <reason>"
        dm_require_single_line "waiter recovery reason" "$reason"
        [ "$expected_state" != "-" ] || expected_state=""
        meta="$(dm_meta_path "$id")"
        dm_lock "$meta"
        dm_require_complete_task_locked "$id"
        [ "$(dm_meta_get "$id" waiter_state)" = "$expected_state" ] \
          && { [ "$epoch" = "-" ] && [ -z "$(dm_meta_get "$id" waiter_epoch)" ] || [ "$(dm_meta_get "$id" waiter_epoch)" = "$epoch" ]; } \
          && { [ "$agent" = "-" ] && [ -z "$(dm_meta_get "$id" waiter_agent_id)" ] || [ "$(dm_meta_get "$id" waiter_agent_id)" = "$agent" ]; } \
          || dm_die "waiter recovery snapshot changed; stale recovery refused"
        dm_task_transition_locked "$id" working "notification waiter recovered: $reason" \
          waiter_thread_name "" waiter_agent_id "" waiter_state terminal waiter_epoch ""
        dm_unlock "$meta"
        ;;
      *) dm_die "waiter state must be prepare|active|idle|terminal|cancel|recover" ;;
    esac
    ;;

  get)
    id="${1:-}"; key="${2:-}"
    [ -n "$id" ] || dm_die "usage: dm-task.sh get <id> [<key>]"
    dm_require_id "$id"
    if [ -n "$key" ]; then dm_meta_get "$id" "$key"
    else cat "$(dm_meta_path "$id")" 2>/dev/null || dm_die "no such task: $id"; fi
    ;;

  event)
    id="${1:-}"; st="${2:-}"; note="${3:-}"
    [ -n "$id" ] && [ -n "$st" ] || dm_die "usage: dm-task.sh event <id> <state> [<note>]"
    # 'merged' is a LANDING signal: `state` treats a `merged` status line as
    # terminal-done. It is appended ONLY by the sanctioned landing paths
    # (dm-merge.sh local / dm-pr.sh merge), which write it directly via
    # dm_status_append. Reject it here so a crewmate cannot forge a done/landed
    # signal over unlanded work (which would mis-report done and let a repo be
    # unregistered over a live worktree).
    case "$st" in
      merged) dm_die "'merged' is a landing signal appended only by dm-merge/dm-pr; dm-task.sh event must not forge it" ;;
      # Appended only by dm-worktree.sh remove --force, so a crewmate cannot
      # flip its own live task terminal.
      discarded) dm_die "'discarded' is appended only by dm-worktree.sh remove --force (operator discard); dm-task.sh event must not forge it" ;;
      working|review-ready|ready|done|blocked|needs-decision|failed|paused) ;;
      *) dm_die "state must be working|review-ready|ready|done|blocked|needs-decision|failed|paused" ;;
    esac
    dm_status_append "$id" "$st" "$note"
    ;;

  state)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh state <id>"
    dm_require_id "$id"
    [ -f "$(dm_meta_path "$id")" ] || { echo "state: unknown · source: none · no such task"; exit 0; }
    transition_seq="$(dm_meta_get "$id" transition_seq)"
    if [ -n "$transition_seq" ] && [ "$(dm_meta_get "$id" transition_audited_seq)" != "$transition_seq" ]; then
      meta="$(dm_meta_path "$id")"
      dm_lock "$meta"
      dm_transition_reconcile_locked "$id"
      dm_unlock "$meta"
    fi
    kind="$(dm_meta_get "$id" kind)"
    wt="$(dm_meta_get "$id" worktree)"
    # Refresh pr_state from GitHub first so an out-of-band merge (operator merged
    # in the web UI) is seen, not reported as `working` forever. Best-effort: a
    # failed check must not abort this decision. No-op offline or when there is
    # no PR / it is already MERGED (dm_should_refresh_pr_state).
    if dm_should_refresh_pr_state "$id"; then
      "$(dirname "${BASH_SOURCE[0]}")/dm-pr.sh" check "$id" >/dev/null 2>&1 || true
    fi
    pr="$(dm_meta_get "$id" pr)"
    # 1) PR merged is terminal-done for a ship task.
    if [ -n "$pr" ]; then
      st="$(dm_meta_get "$id" pr_state)"
      [ "$st" = "MERGED" ] && { echo "state: done · source: pr · $pr merged"; exit 0; }
    fi
    # 2) Scout: done once its report exists.
    if [ "$kind" = "scout" ] && [ -f "$DM_DATA/$id/report.md" ]; then
      echo "state: done · source: report · data/$id/report.md"; exit 0
    fi
    # 3) Ship: done only on POSITIVE landing evidence (a merge event), never on
    #    the mere absence of unlanded commits (that also matches an unstarted task).
    #    Anchor to the VERB field: a status line is "TIMESTAMP verb: note" and the
    #    timestamp has no spaces, so `^[^ ]+ merged: ` matches only a real `merged`
    #    event — not a note whose text happens to contain "merged: " (e.g. a
    #    crewmate note about an upstream PR), which would falsely flip a live,
    #    unlanded task to done.
    if [ "$kind" = "ship" ] && grep -qE '^[^ ]+ merged: ' "$(dm_status_path "$id")" 2>/dev/null; then
      echo "state: done · source: status-log · landed"; exit 0
    fi
    # 3b) Ship with committed work not yet landed is at least "working", even if
    #     the crewmate never emitted an event.
    # `landed` distinguishes 1 (not landed) from 2 (could not determine). Collapsing
    # them would assert "committed work not yet landed" about a task whose repo did
    # not even resolve — a statement we cannot make (#119).
    has_work=0; work_unknown=0
    if [ "$kind" = "ship" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
      landed_rc=0
      "$(dirname "${BASH_SOURCE[0]}")/dm-worktree.sh" landed "$id" >/dev/null 2>&1 || landed_rc=$?
      case "$landed_rc" in
        0) : ;;
        1) has_work=1 ;;
        *) work_unknown=1 ;;
      esac
    fi
    # 4) Otherwise fall back to the last event verb that maps to a real state.
    last="$(tail -n1 "$(dm_status_path "$id")" 2>/dev/null | sed -n 's/^[0-9TZ:-]* //p')"
    verb="${last%%:*}"
    case "$verb" in
      blocked)                echo "state: blocked · source: status-log · $last" ;;
      # A distinct token from 'blocked': an operator CHOICE is required, not just
      # unblocking action. decision-hold/supervision key off this exact string to
      # open a durable backlog hold before the task can be torn down.
      needs-decision)         echo "state: needs-decision · source: status-log · $last" ;;
      paused)                 echo "state: paused · source: status-log · $last" ;;
      failed)                 echo "state: failed · source: status-log · $last" ;;
      # Terminal only once the worktree is gone; a lingering local copy keeps
      # the task live so archive/remove stay refused.
      discarded)
        if [ -n "$wt" ] && [ -d "$wt" ]; then
          echo "state: working · source: worktree · discard recorded but local copy still present"
        else
          echo "state: discarded · source: status-log · $last"
        fi ;;
      review-ready)           echo "state: awaiting-review · source: status-log · lavish artifact ready for the operator: $last" ;;
      ready|done)             echo "state: working · source: status-log · reported ready but not yet landed: $last" ;;
      ''|created)
        if [ "$has_work" -eq 1 ]; then echo "state: working · source: worktree · committed work not yet landed"
        elif [ "$work_unknown" -eq 1 ]; then echo "state: working · source: worktree · could not determine whether its work landed (repo unresolvable)"
        else echo "state: pending · source: status-log · not yet dispatched"; fi ;;
      *)                      echo "state: working · source: status-log · $last" ;;
    esac
    ;;

  archive)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh archive <id>"
    dm_require_id "$id"
    meta="$(dm_meta_path "$id")"
    [ -f "$meta" ] || dm_die "no such task: $id"
    dm_lock "$meta"
    dm_require_complete_task_locked "$id"
    dm_transition_reconcile_locked "$id"
    dm_review_active "$id" \
      && dm_die "refusing to archive '$id': Lavish review session or notification waiter is active"
    dm_task_terminal_locked "$id" \
      || dm_die "refusing to archive '$id': no positive terminal evidence"
    # A worktree still on disk is a live local copy that teardown never removed.
    # Its (possibly unlanded) work must not be swept away behind the operator's
    # back — require teardown first.
    wt="$(dm_meta_get "$id" worktree)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      dm_die "refusing to archive '$id': local copy still present at $wt (tear it down first)"
    fi
    archdir="$DM_STATE/archive"
    mkdir -p "$archdir"
    status="$(dm_status_path "$id")"
    mv -f "$meta" "$archdir/$id.meta" || { dm_unlock "$meta"; dm_die "failed archiving meta for '$id'"; }
    if [ -f "$status" ]; then
      mv -f "$status" "$archdir/$id.status" || { dm_unlock "$meta"; dm_die "failed archiving status log for '$id'"; }
    fi
    if [ -d "$DM_DATA/$id" ]; then
      rm -rf "$archdir/$id"   # replace any stale archive of a reused id
      mv -f "$DM_DATA/$id" "$archdir/$id" || { dm_unlock "$meta"; dm_die "failed archiving data dir for '$id'"; }
    fi
    dm_unlock "$meta"
    dm_info "archived task $id -> state/archive/"
    ;;

  list)
    rows="$(
      printf 'ID\tKIND\tREPO\tSTATE\n'
      while IFS= read -r id; do
        # Bulk overview: reconcile each row OFFLINE (DM_NO_FETCH=1). A per-task live
        # PR refresh here would turn `list` (and the session-start digest that calls
        # it) into N sequential GitHub round-trips on the hottest command. A single
        # `state <id>` still refreshes live; `list` favors a fast local snapshot.
        printf '%s\t%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" kind)" "$(dm_meta_get "$id" repo)" "$(DM_NO_FETCH=1 "$0" state "$id" | sed 's/ · .*//; s/^state: //')"
      done < <(dm_all_task_ids)
    )"
    dm_print_tsv "$rows"
    ;;

  *)
    echo "usage: dm-task.sh {new|set|approve|gate|ready-gates|waiter|get|event|state|archive|list} ..." >&2; exit 2 ;;
esac

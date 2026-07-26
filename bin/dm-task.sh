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
# The runtime's task list is the in-session working mirror; these files are the
# cross-session source of truth.
#
# Commands:
#   new <id> --kind ship|scout --repo R [--mode M] [--title T]
#   set <id> <key> <value>
#   get <id> [<key>]
#   event <id> <state> [<note>]
#   state <id>            reconcile and print current state
#   close <id> --reason R end a task that concluded WITHOUT landing work (the
#                         answer was "do not build it"), recording why
#   archive <id>          move a terminal (done/discarded) task's records +
#                         artifacts to state/archive/ (fails closed otherwise)
#   list [--json]
#   recommend <role> <id> size a spawn for this task from real signals (role,
#                         kind, measured diff) — a recommendation, not a record
#   sizing [--transcripts <dir>]
#                         the dispatch distribution over every task record:
#                         counts by model, by effort, and how many are unsized
#                         (split: predates the recommender, not yet dispatched,
#                         or a real gate bypass). With --transcripts, also
#                         cross-checks each record against what its crewmate
#                         actually ran (exit 3 on a mismatch)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/dm-lib.sh"
dm_ensure_dirs
# `new` inherits a task's mode from the repo registry; a corrupt registry must
# not silently record an empty mode.
dm_registry_require_valid

# --- `list --json` row parts -------------------------------------------------
# Both helpers publish into globals instead of printing a delimited record: a
# state detail or a status note may itself contain any delimiter we could pick.

# split_state_line <line> - the three ` · ` parts of a `state <id>` line, with
# their `state: ` / `source: ` labels stripped. Everything after the SECOND
# separator is the detail (it may contain more of them). Missing parts are "".
STATE_ST=""; STATE_SRC=""; STATE_DETAIL=""
split_state_line() {
  local line="$1" rest
  STATE_ST="$line"; STATE_SRC=""; STATE_DETAIL=""
  case "$line" in
    *' · '*)
      STATE_ST="${line%%' · '*}"; rest="${line#*' · '}"
      case "$rest" in
        *' · '*) STATE_SRC="${rest%%' · '*}"; STATE_DETAIL="${rest#*' · '}" ;;
        *) STATE_SRC="$rest" ;;
      esac ;;
  esac
  STATE_ST="${STATE_ST#state: }"; STATE_SRC="${STATE_SRC#source: }"
}

# parse_last_event <status-log-line> - a status line is "TIMESTAMP verb: note",
# and the timestamp has no spaces. A line missing either part yields "", so a
# malformed log never reports a note fragment as the event verb.
LAST_EVENT=""; LAST_EVENT_AT=""
parse_last_event() {
  local line="$1" rest
  LAST_EVENT=""; LAST_EVENT_AT=""
  case "$line" in
    *' '*) LAST_EVENT_AT="${line%% *}"; rest="${line#* }" ;;
    *) return 0 ;;
  esac
  case "$rest" in *:*) LAST_EVENT="${rest%%:*}" ;; esac
}

# task_list_json - one compact JSON array over every task record. Reconciles each
# row OFFLINE (DM_NO_FETCH=1), exactly as the human `list` does: a live PR refresh
# per task would make this N sequential GitHub round-trips. The worktree PATH is
# deliberately not emitted — only whether one is present.
task_list_json() {
  local id wt has_wt rows
  rows="$(while IFS= read -r id; do
    [ -n "$id" ] || continue
    split_state_line "$(DM_NO_FETCH=1 "$0" state "$id")"
    parse_last_event "$(tail -n1 "$(dm_status_path "$id")" 2>/dev/null || true)"
    wt="$(dm_meta_get "$id" worktree)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then has_wt=true; else has_wt=false; fi
    jq -c -n \
      --arg id "$id" \
      --arg kind "$(dm_meta_get "$id" kind)" \
      --arg repo "$(dm_meta_get "$id" repo)" \
      --arg title "$(dm_meta_get "$id" title)" \
      --arg mode "$(dm_meta_get "$id" mode)" \
      --arg created "$(dm_meta_get "$id" created)" \
      --arg state "$STATE_ST" --arg state_source "$STATE_SRC" --arg state_detail "$STATE_DETAIL" \
      --arg last_event "$LAST_EVENT" --arg last_event_at "$LAST_EVENT_AT" \
      --arg pr "$(dm_meta_get "$id" pr)" \
      --arg pr_state "$(dm_meta_get "$id" pr_state)" \
      --arg checks "$(dm_meta_get "$id" checks)" \
      --arg tests "$(dm_meta_get "$id" tests)" \
      --arg tests_cmd "$(dm_meta_get "$id" tests_cmd)" \
      --arg verify "$(dm_meta_get "$id" verify)" \
      --arg branch "$(dm_meta_get "$id" branch)" \
      --argjson has_worktree "$has_wt" \
      '{id:$id,kind:$kind,repo:$repo,title:$title,mode:$mode,created:$created,
        state:$state,state_source:$state_source,state_detail:$state_detail,
        last_event:$last_event,last_event_at:$last_event_at,
        pr:$pr,pr_state:$pr_state,checks:$checks,tests:$tests,tests_cmd:$tests_cmd,
        verify:$verify,branch:$branch,has_worktree:$has_worktree}'
  done < <(dm_all_task_ids))"
  printf '%s' "$rows" | jq -c -s '.'
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
    # An unregistered repo used to be accepted here and only failed much later,
    # at worktree-create, with an error about a missing clone (#124). The
    # registry is the authority for what the fleet contains, so refuse at the
    # record's birth and name the repo. The reserved distro name has no registry
    # entry BY DESIGN (it resolves to $DM_HOME), so it is the one accepted
    # non-registry name — the distro ships changes to itself through these tasks.
    if [ "$repo" != "$DM_DISTRO_REPO" ] && ! dm_registry_has "$repo"; then
      dm_die "repo '$repo' is not registered, so no task can be created against it; check the name with dm-repo.sh list, or register it with dm-repo.sh add $repo <remote>"
    fi
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
      pr|pr_state|merge_state|pr_check_snapshot|pr_head) dm_die "'$key' is a PR-tracking field maintained by dm-pr.sh (check/open/merge); it must not be set by hand" ;;
      base) dm_die "'base' is recorded by dm-worktree.sh create --base; it must not be set by hand" ;;
      # The tests gate's result and the command that produced it. Both are
      # published on the PR as evidence (#175), so a hand-set value would put a
      # pass a reviewer trusts behind a suite that never ran. dm-test.sh writes
      # them through dm_meta_set directly.
      tests|tests_cmd) dm_die "'$key' is recorded by dm-test.sh when the tests gate runs; hand-setting it would publish a test result nothing ran" ;;
      worktree) dm_die "'worktree' is maintained by dm-worktree.sh create/remove; it must not be set by hand" ;;
      # The verify gate's TRUST inputs. `verify_ready_cmd` is eval'd, and
      # dm-verify.sh validates it at boot (it must prove ownership, and a probe
      # that passes with nothing started is refused) — validation this CLI would
      # bypass entirely. The rest pin what a verdict means: the port and url the
      # app was reached on, the boot token evidence is matched against, and the
      # code state the run verified. Hand-setting any of them re-points a verdict
      # at something else. dm-verify.sh writes them through dm_meta_set directly.
      verify_ready_cmd|verify_token|verify_head|verify_port|verify_url|verify_cwd\
      |verify_app_state|verify_browser_mode|verify_browser_pid|verify_browser_port\
      |verify_cdp_port|verify_axi_home|verify_browser_profile|verify)
        dm_die "'$key' is a verify-gate trust field recorded by dm-verify.sh; setting it by hand would re-point a verdict at code, an app, a browser, or evidence the run never checked" ;;
      # A task's repo decides which clone its work lands in and whose merge
      # authority gates it. Re-pointing a live record at another repo would carry
      # both decisions over to a repo that never consented to them, so the repo is
      # fixed at creation (`new --repo`) and recorded by dm-worktree.sh create.
      repo) dm_die "'repo' is fixed when the task is created (dm-task.sh new --repo) and recorded by dm-worktree.sh create; re-pointing a task at another repo would land its work in the wrong clone, under the wrong merge authority" ;;
      # `kind` is DIRECTIONAL, not free. scout -> ship is the documented
      # promotion (task-lifecycle). ship -> scout is the forge: kind selects how
      # `state` reconciles, so a fabricated data/<id>/report.md turns the task
      # terminal-done, and teardown then reads real committed work as
      # investigation scratch. A ship task that should not be built ends with
      # `close --reason`, not by pretending it was an investigation.
      kind)
        dm_require_id "$id"
        current_kind="$(dm_meta_get "$id" kind)"
        if [ "$current_kind" = "ship" ] && [ "$value" = "scout" ]; then
          dm_die "REFUSED: task '$id' is a ship task; demoting it to scout would let a report file reconcile it to done and let teardown discard its committed work as scratch. If it must not be built, end it honestly: dm-task.sh close $id --reason \"<why>\""
        fi
        ;;
      # The REGISTRY owns a repo's delivery mode; the task field is a per-task
      # copy of it. Setting `mode local-only` on a pipeline repo made
      # `dm-merge.sh local` fast-forward unreviewed work straight onto that
      # clone's default branch — no PR, no review, no operator word (#127). So a
      # task's mode may only be re-synced to what its repo is REGISTERED as;
      # changing how a repo delivers is dm-repo.sh set <repo> mode, an operator
      # decision recorded in the registry. dm-merge.sh local re-checks the
      # registry itself, so a meta value forged past this guard still cannot land.
      mode)
        dm_require_id "$id"
        task_repo="$(dm_meta_get "$id" repo)"
        [ -n "$task_repo" ] || dm_die "task '$id' records no repo, so its delivery mode cannot be checked against the registry"
        registry_mode="$(dm_registry_get "$task_repo" mode)"
        [ -n "$registry_mode" ] || dm_die "repo '$task_repo' has no registered delivery mode (is it registered? dm-repo.sh list); refusing to set a mode that nothing vouches for"
        [ "$value" = "$registry_mode" ] || dm_die "REFUSED: repo '$task_repo' is registered for '$registry_mode' delivery, not '$value'. A task cannot opt itself out of its repo's delivery route. If the operator wants '$value' for this repo, record it where it belongs: dm-repo.sh set $task_repo mode $value"
        ;;
      # Recording the runtime owner IS the dispatch record — task-lifecycle and
      # fleet-change both spawn, then persist it here. So this is where the
      # brief's "{TASK} is a safety contract" claim becomes one: a crewmate
      # dispatched against an unfilled placeholder has no task at all, and every
      # other section of the brief looks complete on a skim (#115).
      # A recorded effort selects a real `crew-<level>` subagent definition, so a
      # value outside the set is a dispatch that cannot be spawned, not a
      # harmless string. Model is deliberately NOT validated against a list: the
      # runtime gains models on its own schedule, and an allowlist here would
      # silently refuse a newly-released one.
      effort)
        dm_require_id "$id"
        dm_effort_is_valid "$value" || dm_die "REFUSED: '$value' is not a reasoning-effort level. Use one of: $DM_EFFORT_LEVELS. ('max' is excluded on purpose — a cost ceiling, not an oversight.)"
        ;;
      agent_id)
        dm_require_id "$id"
        brief="$DM_DATA/$id/brief.md"
        # A crewmate is already spawned by the time this runs (fleet-change
        # terminates the returned id on a persistence failure), so the predicate
        # must be exact: the placeholder arm matches the bare {TASK} LINE, not
        # any mention of it. A MISSING brief refuses for the same reason the
        # other two do — a recorded dispatch with no brief is the same crewmate
        # with no task, reached by another route — so all three sites agree.
        if reason="$(dm_brief_unready_reason "$brief")"; then
          case "$reason" in
            missing) dm_die "REFUSED: $id has no brief at $brief, so the crewmate you just spawned has no task record behind it. Generate it (dm-brief.sh $id), fill its {TASK} line, then record the owner." ;;
            empty)   dm_die "REFUSED: $id's brief is empty ($brief) — a write died part-way, so the crewmate you just spawned has no task. Regenerate it (dm-brief.sh $id), fill its {TASK} line, then record the owner." ;;
            *)       dm_die "REFUSED: $id's brief still has its bare {TASK} line unreplaced ($brief), so the crewmate you just spawned has no task. EDIT that file in place — do NOT regenerate, dm-brief.sh $id would overwrite what is already written. Confirm with 'dm-brief.sh check $id', then record the owner." ;;
          esac
        fi
        # Both sizing dials must be a deliberate CHOICE before a dispatch counts.
        # Not the RECOMMENDED value — overriding the anchor is the point — but
        # neither may be left unset, or one axis silently defaults forever.
        # A RECORD gate, not a spawn gate: the agent is already running, and
        # nothing checks the recorded effort against the subagent_type actually
        # passed. It forces the choice to be written down, it does not verify it.
        dispatch_model="$(dm_meta_get "$id" model)"
        [ -n "$dispatch_model" ] || dm_die "REFUSED: $id has no model recorded, so its dispatch was never sized. Choose a model tier for THIS task and record it (dm-task.sh set $id model <tier>), then record the owner."
        dispatch_effort="$(dm_meta_get "$id" effort)"
        [ -n "$dispatch_effort" ] || dm_die "REFUSED: $id has no reasoning effort recorded, so its dispatch was never sized. Choose a level for THIS task ($DM_EFFORT_LEVELS), record it (dm-task.sh set $id effort <level>), and spawn with the matching subagent_type crew-<level>."
        dm_effort_is_valid "$dispatch_effort" || dm_die "REFUSED: $id records effort '$dispatch_effort', which is not a valid level. Re-record one of: $DM_EFFORT_LEVELS."
        # The computed recommendation is the DEFAULT dispatch (#166 calibration).
        # Going above it on either dial is allowed but must be a NAMED decision —
        # a missing or unranked recommendation cannot prove an upsize, so it never
        # forces a reason. Downsizing below the recommendation needs none.
        rec_model="$(dm_meta_get "$id" model_recommended)"
        rec_effort="$(dm_meta_get "$id" effort_recommended)"
        if dm_dispatch_is_upsized "$dispatch_model" "$dispatch_effort" "$rec_model" "$rec_effort"; then
          [ -n "$(dm_meta_get "$id" sizing_reason)" ] \
            || dm_die "REFUSED: $id dispatches above its computed recommendation (recommended ${rec_model:-?}/${rec_effort:-?}, recording $dispatch_model/$dispatch_effort) with no reason. Name it: dm-task.sh set $id sizing_reason \"<why this needs more>\", then record the owner. Downsizing never needs a reason."
        fi
        ;;
    esac
    dm_meta_set "$id" "$key" "$value"
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
      # Appended only by the two guarded terminal paths — dm-worktree.sh remove
      # --force (operator discard) and `dm-task.sh close` (nothing was built) —
      # so a crewmate cannot flip its own live task terminal here.
      discarded) dm_die "'discarded' is appended only by dm-worktree.sh remove --force (operator discard) or dm-task.sh close --reason (the task ends with nothing landed); dm-task.sh event must not forge it" ;;
      working|review-ready|ready|done|blocked|needs-decision|failed|paused) ;;
      *) dm_die "state must be working|review-ready|ready|done|blocked|needs-decision|failed|paused" ;;
    esac
    dm_status_append "$id" "$st" "$note"
    ;;

  state)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh state <id>"
    dm_require_id "$id"
    [ -f "$(dm_meta_path "$id")" ] || { echo "state: unknown · source: none · no such task"; exit 0; }
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

  close)
    # The terminal state for a task whose honest answer is "do not build it"
    # (#103). Without it such a task had NO reachable end: `state` derives done
    # only from positive landing evidence, so it reconciled to `working` forever
    # unless it was laundered — flipped to a scout with a report, or its mode
    # forged so a local land could append a `merged` event. Both of those claim
    # something happened that did not. This claims exactly what did: nothing
    # landed, and here is why.
    #
    # It records the existing `discarded` verb rather than inventing a state:
    # `state`, `archive`, and `dm-repo.sh remove` already treat that as terminal,
    # and a new token would read as non-terminal to every one of them. The verb
    # stays barred from `dm-task.sh event`, so this command — with its own
    # guards — remains the only hand-driven route to it.
    id="${1:-}"; shift || true
    [ -n "$id" ] || dm_die "usage: dm-task.sh close <id> --reason \"<why nothing was built>\""
    dm_require_id "$id"
    reason=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) [ "$#" -ge 2 ] || dm_die "--reason requires a value"; reason="$2"; shift 2 ;;
        *) dm_die "unknown flag: $1" ;;
      esac
    done
    [ -n "$reason" ] || dm_die "--reason is required: the record must say WHY this task ends with nothing landed"
    [ -f "$(dm_meta_path "$id")" ] || dm_die "no such task: $id"
    # ANY recorded worktree refuses, present or absent. A present one may hold
    # work nobody has looked at, and teardown is what inspects it. An ABSENT one
    # is the interrupted-cleanup shape that `dm-worktree.sh remove` refuses
    # without --force precisely because nothing remains to prove the work landed
    # — closing there would reach `discarded` with none of that discard
    # authority, making this a weaker second writer of the same state.
    wt="$(dm_meta_get "$id" worktree)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      dm_die "refusing to close '$id': its local copy is still present at $wt. Tear it down first (dm-worktree.sh remove $id) — that is what checks whether it holds work nobody has landed."
    fi
    if [ -n "$wt" ]; then
      dm_die "refusing to close '$id': it still records a local copy at $wt whose directory is already absent, so nothing here can prove its work landed. Clear it where that costs explicit discard authority: dm-worktree.sh remove $id --force"
    fi
    st="$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    case "$st" in
      done|discarded) dm_die "refusing to close '$id': it is already terminal ('$st')" ;;
    esac
    dm_status_append "$id" discarded "closed without landing work: $reason"
    dm_info "closed $id — nothing landed: $reason"
    ;;

  archive)
    id="${1:-}"; [ -n "$id" ] || dm_die "usage: dm-task.sh archive <id>"
    dm_require_id "$id"
    meta="$(dm_meta_path "$id")"
    [ -f "$meta" ] || dm_die "no such task: $id"
    # Fail closed: only a task that reconciles to terminal 'done' may be archived.
    # `state` derives 'done' solely from positive landing/report evidence, so a
    # ship task with unlanded work reconciles to 'working' and is refused here —
    # archival must never bury unfinished work.
    st="$("$0" state "$id" | sed 's/ · .*//; s/^state: //')"
    case "$st" in
      done|discarded) ;;
      *) dm_die "refusing to archive '$id': current state is '$st', not done/discarded" ;;
    esac
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
    # Lock the meta path so the move cannot race a concurrent meta writer.
    dm_lock "$meta"
    mv -f "$meta" "$archdir/$id.meta" || { dm_unlock "$meta"; dm_die "failed archiving meta for '$id'"; }
    if [ -f "$status" ]; then
      mv -f "$status" "$archdir/$id.status" || { dm_unlock "$meta"; dm_die "failed archiving status log for '$id'"; }
    fi
    dm_unlock "$meta"
    if [ -d "$DM_DATA/$id" ]; then
      rm -rf "$archdir/$id"   # replace any stale archive of a reused id
      mv -f "$DM_DATA/$id" "$archdir/$id" || dm_die "failed archiving data dir for '$id'"
    fi
    dm_info "archived task $id -> state/archive/"
    ;;

  list)
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        *) dm_die "unknown flag: $1 (usage: dm-task.sh list [--json])" ;;
      esac
    done
    if [ "$json" -eq 1 ]; then dm_need jq; task_list_json; exit 0; fi
    # `| column ... || cat` bound `||` to the whole pipeline: a missing column
    # fell back to `cat` on the SCRIPT's stdin (consumed -> empty; a tty -> hangs).
    out="$(printf 'ID\tKIND\tREPO\tSTATE\n'
      while IFS= read -r id; do
        # Bulk overview: reconcile each row OFFLINE (DM_NO_FETCH=1). A per-task live
        # PR refresh here would turn `list` (and the session-start digest that calls
        # it) into N sequential GitHub round-trips on the hottest command. A single
        # `state <id>` still refreshes live; `list` favors a fast local snapshot.
        printf '%s\t%s\t%s\t%s\n' "$id" "$(dm_meta_get "$id" kind)" "$(dm_meta_get "$id" repo)" "$(DM_NO_FETCH=1 "$0" state "$id" | sed 's/ · .*//; s/^state: //')"
      done < <(dm_all_task_ids))"
    printf '%s\n' "$out" | column -t -s$'\t' 2>/dev/null || printf '%s\n' "$out"
    ;;

  recommend)
    # What THIS spawn is worth, computed from what exists at dispatch: the pass
    # being run, the task kind, and the branch's real diff. Not a record — the
    # orchestrator still chooses and records with `set model` / `set effort`.
    role="${1:-}"; id="${2:-}"
    [ -n "$role" ] && [ -n "$id" ] || dm_die "usage: dm-task.sh recommend <$(printf '%s' "$DM_DISPATCH_ROLES" | tr ' ' '|')> <id>"
    dm_role_is_valid "$role" || dm_die "role must be one of: $DM_DISPATCH_ROLES (it is the PASS being dispatched, not the task's kind)"
    dm_require_id "$id"
    [ -f "$(dm_meta_path "$id")" ] || dm_die "no such task: $id"
    kind="$(dm_meta_get "$id" kind)"
    # An unmeasurable branch is a MISSING signal, not a zero one, and the
    # recommendation falls back to the anchor. Measurement refuses SILENTLY by
    # contract; stderr is dropped so a missing clone cannot spam an advisory.
    size=""; size="$(dm_task_diff_size "$id" 2>/dev/null)" || size=""
    # Unquoted on purpose: "<files> <lines>" splits into the two count args.
    pair="$(dm_recommended_dispatch "$role" "$kind" $size)" \
      || dm_die "could not size a '$role' dispatch for $id"
    class="$(dm_diff_size_class $size)"
    if [ "$class" = "unknown" ]; then
      evidence="none measurable"
    else
      evidence="files=${size%% *} lines=${size##* }"
    fi
    printf 'model=%s\n' "${pair%% *}"
    printf 'effort=%s\n' "${pair##* }"
    printf 'subagent_type=crew-%s\n' "${pair##* }"
    printf 'signals=role:%s kind:%s diff:%s (%s)\n' "$role" "${kind:-unknown}" "$class" "$evidence"
    ;;

  sizing)
    # "Was our spend proportionate?" answered from the records themselves, so it
    # never needs a bespoke grep (#177). Reads meta only: no network, no
    # reconcile, no mutation. Covers every non-archived task.
    #
    # --transcripts <dir> additionally CROSS-CHECKS the record against what each
    # crewmate actually ran, closing the gap `set agent_id` admits to: that gate
    # records a choice, it cannot verify the spawn. The directory holds one
    # `<agent_id>.output` per spawn (the runtime's own layout, so the caller
    # passes the path — nothing here hardcodes it). A file that is missing or
    # carries no model is UNPROVEN, never a pass; a contradiction is a MISMATCH
    # and exits 3, because a record that lies about what ran is worse than none.
    transcripts=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --transcripts) [ "$#" -ge 2 ] || dm_die "--transcripts requires a directory"; transcripts="$2"; shift 2 ;;
        *) dm_die "unknown flag: $1 (usage: dm-task.sh sizing [--transcripts <dir>])" ;;
      esac
    done
    [ -z "$transcripts" ] || [ -d "$transcripts" ] || dm_die "no such transcript directory: $transcripts"
    models=""; efforts=""; total=0; unsized=0
    unsized_predates=0; unsized_pending=0; unsized_gate=0
    matched=0; unproven=0; mismatched=0; mismatches=""
    # Runs in THIS shell (the loop below reads a process substitution), so the
    # counters it updates are the ones printed.
    cross_check() {
      local tid="$1" recorded="$2" agent ran
      agent="$(dm_meta_get "$tid" agent_id)"
      [ -n "$agent" ] || return 0
      ran="$(dm_transcript_model "$transcripts/$agent.output")" || ran=""
      if [ -z "$ran" ]; then unproven=$((unproven + 1)); return 0; fi
      if dm_dispatch_model_matches "$recorded" "$ran"; then
        matched=$((matched + 1)); return 0
      fi
      mismatched=$((mismatched + 1))
      mismatches="$mismatches  MISMATCH: $tid recorded model=$recorded but its transcript ran $ran"$'\n'
    }
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      total=$((total + 1))
      m="$(dm_meta_get "$tid" model)"; e="$(dm_meta_get "$tid" effort)"
      [ -n "$m" ] && models="$models$m"$'\n'
      [ -n "$e" ] && efforts="$efforts$e"$'\n'
      if [ -z "$m" ] || [ -z "$e" ]; then
        unsized=$((unsized + 1))
        # A record with no model_recommended predates the recommender entirely
        # (dm-brief.sh has stamped it on every ship task since #177) — nothing
        # was skipped, there was nothing to choose from yet. One WITH a
        # recommendation but no agent_id is just not dispatched yet. Only a
        # recommendation plus an agent_id with no dial recorded is a real gate
        # bypass: `set agent_id` refuses that shape, so seeing it here means the
        # record was written some other way (a hand-edit, or code predating the
        # guard) — worth naming differently from ordinary pending debt.
        if [ -z "$(dm_meta_get "$tid" model_recommended)" ]; then
          unsized_predates=$((unsized_predates + 1))
        elif [ -z "$(dm_meta_get "$tid" agent_id)" ]; then
          unsized_pending=$((unsized_pending + 1))
        else
          unsized_gate=$((unsized_gate + 1))
        fi
      fi
      if [ -n "$transcripts" ] && [ -n "$m" ]; then cross_check "$tid" "$m"; fi
    done < <(dm_all_task_ids)
    [ "$total" -gt 0 ] || { dm_info "(no tasks)"; exit 0; }
    tally() {
      local label="$1" values="$2"
      [ -n "$values" ] || return 0
      printf '%s' "$values" | sort | uniq -c | sort -k1,1nr -k2,2 \
        | while read -r n v; do printf '%s\t%s\t%s\n' "$label" "$v" "$n"; done
    }
    out="$( tally model "$models"; tally effort "$efforts"
            printf 'unsized\tno model or no effort\t%s\n' "$unsized"
            printf 'unsized\tpredates sizing (no recommendation recorded)\t%s\n' "$unsized_predates"
            printf 'unsized\tnot yet dispatched (recommended, no agent_id)\t%s\n' "$unsized_pending"
            printf 'unsized\tdispatched with no dial recorded (gate bypass)\t%s\n' "$unsized_gate"
            printf 'total\ttask records\t%s\n' "$total"
            if [ -n "$transcripts" ]; then
              printf 'verified\tran as recorded\t%s\n' "$matched"
              printf 'verified\tno transcript found\t%s\n' "$unproven"
              printf 'verified\tMISMATCH\t%s\n' "$mismatched"
            fi )"
    printf '%s\n' "$out" | column -t -s$'\t' 2>/dev/null || printf '%s\n' "$out"
    [ -z "$mismatches" ] || { printf '%s' "$mismatches" >&2; exit 3; }
    ;;

  *)
    echo "usage: dm-task.sh {new|set|get|event|state|close|archive|list|recommend|sizing} ..." >&2; exit 2 ;;
esac

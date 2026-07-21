#!/usr/bin/env bash
# dm-command-guard.sh - classify a shell command before execution and refuse the
# Git forms that can lose work. PreToolUse hook; wired from .codex/config.toml.
#
# SHAPE: allowlist, not denylist (#121). A denylist has to enumerate every
# destructive Git form and every wrapper that reaches one, and loses that race
# by construction — it silently permitted force-push, stash, reflog expire, gc
# --prune, filter-branch, branch -D and update-ref -d, and `timeout git ...`
# walked past every rule it did have. So: a Git subcommand is refused unless it
# is named permitted below, and an unknown/future subcommand fails closed.
#
# THREE CLASSES OF GIT SUBCOMMAND (check_git_subcommand is the single owner):
#   permitted    read-only inspection + additive/history-preserving workflow
#   conditional  permitted, minus a destructive FLAG (push --force, rm -rf) or a
#                destructive VERB (remote remove, stash pop, bisect reset)
#   refused      everything else, named or not
# The permitted set is walked against git's real subcommand list, not a
# shortlist: fail-closed is only tolerable if ordinary work does not keep
# hitting it. A refusal names the subcommand, so widening it is a one-liner.
#
# EXECUTION VECTORS, refused because they would carry a refused form past the
# allowlist as an opaque string: rebase -x, bisect run, submodule foreach,
# difftool --extcmd, for-each-repo, an alias shadowing the invoked subcommand,
# and any -c/GIT_* setting of a config key whose value Git executes.
#
# WRAPPERS: env/sudo/timeout/nohup/nice/xargs/... are unwrapped to the command
# they run. That table is a PRECISION aid, not the safety boundary — an
# unrecognized executable holding a bare `git` token is refused outright
# (check_stray_git_tokens), so an unlisted wrapper fails closed rather than
# bypassing. Text tools that provably never execute their argv are exempt so
# `grep git .` still works; sed/awk/find/perl are deliberately NOT exempt.
#
# DELIBERATELY PERMITTED, each with a test that says so:
#   - `git push --force-with-lease` / `--force-if-includes`: the toolbelt itself
#     uses lease-pinned force (dm-pr.sh) and #89 records it as intentional.
#   - a Git alias that is defined but never invoked.
#   - `git rebase` / `merge` / `pull`: they refuse to run on a dirty tree.
#
# NOT A SANDBOX. It parses one shell command; a tool that emits no Bash hook
# event is not covered. See SECURITY.md for the coverage statement.

set -euo pipefail
DM_GUARD_DEPTH="${DM_GUARD_DEPTH:-0}"

deny() {
  printf 'BLOCKED: destructive Git command refused: %s\n' "$1" >&2
  exit 2
}

append_token() {
  TOKENS+=("$token")
  DYNAMIC+=("$dynamic")
  token=""; dynamic=0; started=0
}

lex_shell_command() {
  local input="$1" i=0 char next state="plain" escaped=0 depth
  TOKENS=(); DYNAMIC=(); token=""; dynamic=0; started=0
  while [ "$i" -lt "${#input}" ]; do
    char="${input:$i:1}"; next="${input:$((i + 1)):1}"
    if [ "$escaped" -eq 1 ]; then
      [ "$char" = $'\n' ] || { token+="$char"; started=1; }
      escaped=0; i=$((i + 1)); continue
    fi
    case "$state" in
      single)
        if [ "$char" = "'" ]; then state="plain"; else token+="$char"; fi
        started=1
        ;;
      double)
        case "$char" in
          '"') state="plain" ;;
          \\) escaped=1 ;;
          '$'|'`') token+="$char"; dynamic=1 ;;
          *) token+="$char" ;;
        esac
        started=1
        ;;
      plain)
        case "$char" in
          "'") state="single"; started=1 ;;
          '"') state="double"; started=1 ;;
          \\) escaped=1; started=1 ;;
          '$')
            if [ "$next" = "(" ]; then
              token+='$('; dynamic=1; started=1; depth=1; i=$((i + 2))
              while [ "$i" -lt "${#input}" ] && [ "$depth" -gt 0 ]; do
                char="${input:$i:1}"; token+="$char"
                case "$char" in '(') depth=$((depth + 1)) ;; ')') depth=$((depth - 1)) ;; esac
                i=$((i + 1))
              done
              [ "$depth" -eq 0 ] || deny "unterminated command substitution"
              i=$((i - 1))
            else
              token+="$char"; dynamic=1; started=1
            fi
            ;;
          '`') token+="$char"; dynamic=1; started=1 ;;
          '#')
            if [ "$started" -eq 0 ]; then break; else token+="$char"; fi
            ;;
          ' '|$'\t')
            [ "$started" -eq 0 ] || append_token
            ;;
          $'\n')
            [ "$started" -eq 0 ] || append_token
            TOKENS+=(";"); DYNAMIC+=(0)
            ;;
          ';'|'&'|'|'|'('|')')
            [ "$started" -eq 0 ] || append_token
            if { [ "$char" = "&" ] || [ "$char" = "|" ]; } && [ "$next" = "$char" ]; then
              TOKENS+=("$char$char"); DYNAMIC+=(0); i=$((i + 1))
            else
              TOKENS+=("$char"); DYNAMIC+=(0)
            fi
            ;;
          *) token+="$char"; started=1 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  [ "$escaped" -eq 0 ] || deny "unterminated shell escape"
  [ "$state" = "plain" ] || deny "unterminated shell quote"
  [ "$started" -eq 0 ] || append_token
}

is_segment_end() {
  case "$1" in ';'|'&&'|'||'|'|'|'&'|'('|')') return 0 ;; esac
  return 1
}

git_subcommand_index() {
  local start="$1" end="$2" i token
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    case "$token" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) i=$((i + 2)) ;;
      -C*|-c*|--git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--config-env=*) i=$((i + 1)) ;;
      --) i=$((i + 1)) ;;
      -*) i=$((i + 1)) ;;
      *) printf '%s\n' "$i"; return 0 ;;
    esac
  done
  return 1
}

has_arg() {
  local start="$1" end="$2" wanted="$3" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    [ "${TOKENS[$i]}" = "$wanted" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# Bundled short flags, e.g. -fq. Long options are skipped: --force-with-lease
# must never satisfy a `-f` query, since the lease form stays permitted.
has_short_flag() {
  local start="$1" end="$2" wanted="$3" i flags
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in
      --*) : ;;
      -?*) flags="${TOKENS[$i]#-}"; case "$flags" in *"$wanted"*) return 0 ;; esac ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# `git push origin +main` forces without any flag.
has_force_refspec() {
  local start="$1" end="$2" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in +*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

# First non-flag token after the subcommand -- the verb of a two-level command
# such as `remote remove` or `bisect run`. Empty when the subcommand is bare.
subcommand_verb() {
  local start="$1" end="$2" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in
      -*) : ;;
      *) printf '%s\n' "${TOKENS[$i]}"; return 0 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Permit <subcommand> only for the listed verbs. Same inversion as the top-level
# allowlist: an unknown, new, or absent verb fails closed. `<none>` in the list
# permits the bare form (e.g. `git remote` listing remotes).
require_verb() {
  local subcommand="$1" verb="$2" permitted=" $3 "
  case "$permitted" in
    *" ${verb:-<none>} "*) return 0 ;;
  esac
  deny "git $subcommand ${verb:-(bare)} is not on the permitted-subcommand list"
}

# Config keys whose VALUE Git executes as a command. Setting one on the command
# line turns ANY permitted subcommand into arbitrary execution, so the allowlist
# means nothing without this.
config_key_executes() {
  case "$1" in
    core.pager|core.editor|core.sshCommand|core.hooksPath|core.fsmonitor|\
    diff.external|sequence.editor|credential.helper|\
    uploadpack.packObjectsHook|filter.*) return 0 ;;
  esac
  return 1
}

# An inline config entry is refused when it either executes its value, or is an
# alias SHADOWING the invoked subcommand -- which makes that subcommand
# something other than what it reads as. An uninvoked alias is untouched.
check_config_entry() {
  local entry="$1" dynamic="$2" subcommand="$3" key name
  case "$entry" in *=*) ;; *) return 0 ;; esac
  key="${entry%%=*}"
  config_key_executes "$key" && deny "Git config key '$key' has a value Git executes"
  case "$key" in alias.*) ;; *) return 0 ;; esac
  name="${key#alias.}"
  [ "$name" = "$subcommand" ] || return 0
  [ "$dynamic" -eq 0 ] || deny "invoked Git alias has a dynamic definition"
  deny "invoked Git subcommand is redefined by an inline alias"
}

check_environment_aliases() {
  local start="$1" git_index="$2" subcommand="$3" i j token suffix value found
  i="$start"
  while [ "$i" -lt "$git_index" ]; do
    token="${TOKENS[$i]}"
    case "$token" in
      # Env equivalents of the executing config keys, same reasoning.
      GIT_EDITOR=*|GIT_PAGER=*|GIT_EXTERNAL_DIFF=*|GIT_SEQUENCE_EDITOR=*|\
      GIT_SSH=*|GIT_SSH_COMMAND=*|GIT_PROXY_COMMAND=*)
        deny "Git environment variable '${token%%=*}' has a value Git executes"
        ;;
      GIT_CONFIG_COUNT=*)
        [ "${DYNAMIC[$i]}" -eq 0 ] || deny "dynamic Git config count cannot be safety-classified"
        ;;
      GIT_CONFIG_KEY_*=*)
        [ "${DYNAMIC[$i]}" -eq 0 ] || deny "dynamic Git config key cannot be safety-classified"
        suffix="${token%%=*}"; suffix="${suffix#GIT_CONFIG_KEY_}"
        value=""; found=0; j="$start"
        while [ "$j" -lt "$git_index" ]; do
          case "${TOKENS[$j]}" in
            GIT_CONFIG_VALUE_"$suffix"=*) value="${TOKENS[$j]#*=}"; found=1; break ;;
          esac
          j=$((j + 1))
        done
        if [ "$found" -eq 0 ]; then
          check_config_entry "${token#*=}=" 1 "$subcommand"
        else
          check_config_entry "${token#*=}=$value" "${DYNAMIC[$j]}" "$subcommand"
        fi
        ;;
    esac
    i=$((i + 1))
  done
}

check_git_segment() {
  local start="$1" git_index="$2" end="$3" sub_index subcommand i token config
  sub_index="$(git_subcommand_index "$git_index" "$end")" || return 0
  [ "${DYNAMIC[$sub_index]}" -eq 0 ] || deny "dynamic Git subcommand cannot be safety-classified"
  subcommand="${TOKENS[$sub_index]}"
  check_environment_aliases "$start" "$git_index" "$subcommand"
  i=$((git_index + 1))
  while [ "$i" -lt "$sub_index" ]; do
    token="${TOKENS[$i]}"
    case "$token" in
      -c|--config-env)
        i=$((i + 1)); [ "$i" -lt "$sub_index" ] || deny "Git config option is missing a value"
        config="${TOKENS[$i]}"
        if [ "$token" = "--config-env" ]; then
          check_config_entry "$config" 1 "$subcommand"
        else
          check_config_entry "$config" "${DYNAMIC[$i]}" "$subcommand"
        fi
        ;;
      -c?*) check_config_entry "${token#-c}" "${DYNAMIC[$i]}" "$subcommand" ;;
      --config-env=?*) check_config_entry "${token#--config-env=}" 1 "$subcommand" ;;
    esac
    i=$((i + 1))
  done
  check_git_subcommand "$sub_index" "$end" "$subcommand"
}

# Push may not force, delete, or prune a remote ref. --force-with-lease and
# --force-if-includes stay permitted (see header); both are long options, so
# the -f query cannot match them.
check_git_push() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force \
      || has_arg "$start" "$end" --mirror \
      || has_short_flag "$start" "$end" d || has_arg "$start" "$end" --delete \
      || has_arg "$start" "$end" --prune \
      || has_force_refspec "$start" "$end"; then
    deny "git push force/delete/prune form"
  fi
}

# Deleting or force-moving a branch drops commits that may be unlanded. A plain
# rename (-m/--move) and a plain copy (-c) lose nothing and stay permitted.
check_git_branch() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" d || has_short_flag "$start" "$end" D \
      || has_arg "$start" "$end" --delete \
      || has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force \
      || has_short_flag "$start" "$end" M || has_short_flag "$start" "$end" C; then
    deny "git branch delete/force form"
  fi
}

# A plain `worktree remove` refuses a dirty worktree; forcing discards it.
check_git_worktree() {
  local start="$1" end="$2" verb
  verb="$(subcommand_verb "$start" "$end")"
  require_verb worktree "$verb" "add list lock unlock move prune repair remove"
  [ "$verb" = "remove" ] || return 0
  if has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force; then
    deny "git worktree remove --force"
  fi
}

# `git rm -rf .` wipes tracked files, and the commands that would restore them
# are themselves refused. Recursive is permitted only with --cached, which
# untracks while leaving the files on disk.
check_git_rm() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force; then
    deny "git rm --force"
  fi
  if has_short_flag "$start" "$end" r || has_short_flag "$start" "$end" R; then
    has_arg "$start" "$end" --cached || deny "git rm -r without --cached"
  fi
}

# `rebase -x` runs a command per commit, so it would smuggle any refused Git
# form past the allowlist as an opaque string.
check_git_rebase() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" x || has_arg "$start" "$end" --exec; then
    deny "git rebase --exec runs an unclassifiable command"
  fi
}

# Same class as rebase --exec: difftool's external command is never inspected.
check_git_difftool() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" x || has_arg "$start" "$end" --extcmd; then
    deny "git difftool --extcmd runs an unclassifiable command"
  fi
}

check_git_tag() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" d || has_arg "$start" "$end" --delete \
      || has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force; then
    deny "git tag delete/force form"
  fi
}

# Writing an alias.* key would let a later command shadow a permitted
# subcommand, so config may not touch aliases at all.
check_git_config() {
  local start="$1" end="$2" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in
      alias.*|*=alias.*) deny "git config touching an alias" ;;
    esac
    i=$((i + 1))
  done
}

check_git_switch() {
  local start="$1" end="$2"
  if has_short_flag "$start" "$end" f || has_short_flag "$start" "$end" C \
      || has_arg "$start" "$end" --force || has_arg "$start" "$end" --discard-changes \
      || has_arg "$start" "$end" -C || has_arg "$start" "$end" --force-create \
      || has_arg "$start" "$end" --orphan; then
    deny "git switch with discard/force"
  fi
}

# The allowlist, walked against git's actual subcommand list rather than a
# shortlist, so ordinary work does not have to discover each refusal as an
# incident. Unknown and future subcommands land in the default case and are
# refused: that is the point of the inversion (#121).
#
# REFUSED WITH NO CLEAN SPLIT, recorded so it reads as a decision:
#   reset, clean, restore, checkout      discard worktree/index state
#   gc, prune, prune-packed, repack      destroy the dangling-commit recovery net
#   filter-branch, replay, fast-import   rewrite history
#   update-ref, symbolic-ref, pack-refs, read-tree, update-index
#                                        write refs/index directly
#   replace, rerere, maintenance         plumbing with no safe-form boundary
#   credential, daemon, send-email, imap-send, http-*, send-pack, receive-pack
#                                        expose secrets or reach the network
#   for-each-repo                        runs a command per repo (see rebase -x)
check_git_subcommand() {
  local sub_index="$1" end="$2" subcommand="$3" verb
  case "$subcommand" in
    # Read-only inspection.
    status|log|show|diff|diff-files|diff-index|diff-tree|diff-pairs|\
    blame|annotate|describe|shortlog|whatchanged|grep|cherry|range-diff|\
    ls-files|ls-tree|ls-remote|cat-file|rev-parse|rev-list|name-rev|\
    for-each-ref|show-ref|show-branch|show-index|merge-base|merge-tree|\
    count-objects|check-ignore|check-attr|check-mailmap|check-ref-format|\
    verify-commit|verify-tag|verify-pack|fsck|fsck-objects|patch-id|\
    request-pull|fast-export|archive|bundle|bugreport|diagnose|\
    get-tar-commit-id|stripspace|interpret-trailers|mailinfo|mailsplit|\
    fmt-merge-msg|column|var|version|help) return 0 ;;
    # Additive or history-preserving workflow.
    add|stage|commit|commit-tree|write-tree|mktree|mktag|hash-object|\
    fetch|pull|merge|merge-file|mergetool|cherry-pick|revert|am|apply|\
    format-patch|mv|init|init-db|clone) return 0 ;;
    # Safe in the ordinary form, destructive in a specific one.
    push) check_git_push "$sub_index" "$end" ;;
    branch) check_git_branch "$sub_index" "$end" ;;
    tag) check_git_tag "$sub_index" "$end" ;;
    worktree) check_git_worktree "$sub_index" "$end" ;;
    config) check_git_config "$sub_index" "$end" ;;
    switch) check_git_switch "$sub_index" "$end" ;;
    rm) check_git_rm "$sub_index" "$end" ;;
    rebase) check_git_rebase "$sub_index" "$end" ;;
    difftool) check_git_difftool "$sub_index" "$end" ;;
    # Safe or destructive by verb. `bisect run` and `submodule foreach` execute
    # a command they are handed, so both are refused for the rebase -x reason.
    remote)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb remote "$verb" "<none> show get-url add rename set-head set-branches update" ;;
    submodule)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb submodule "$verb" "<none> status init update sync summary add absorbgitdirs set-branch" ;;
    notes)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb notes "$verb" "<none> list show add append edit copy merge get-ref" ;;
    bisect)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb bisect "$verb" "start good bad new old skip log view terms replay" ;;
    reflog)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb reflog "$verb" "<none> show exists" ;;
    stash)
      # AGENTS.md forbids stashing; reading the list destroys nothing.
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb stash "$verb" "list show" ;;
    sparse-checkout)
      verb="$(subcommand_verb "$sub_index" "$end")"
      require_verb sparse-checkout "$verb" "list" ;;
    *) deny "git $subcommand is not on the permitted-subcommand list" ;;
  esac
}

check_nested_shell() {
  local start="$1" end="$2" executable="$3" i option
  case "$executable" in sh|bash|dash|zsh|ash|ksh|mksh|eval) ;; *) return 0 ;; esac
  if [ "$executable" = "eval" ]; then
    i=$((start + 1))
  else
    i=$((start + 1))
    while [ "$i" -lt "$end" ]; do
      option="${TOKENS[$i]}"
      case "$option" in
        -s|-*s*) deny "shell reads unresolved stdin" ;;
        -*c*) i=$((i + 1)); break ;;
        -*) i=$((i + 1)) ;;
        *) return 0 ;;
      esac
    done
  fi
  [ "$i" -lt "$end" ] || return 0
  DM_GUARD_DEPTH=$((DM_GUARD_DEPTH + 1)) "$0" check "${TOKENS[$i]}"
}

is_shell_executable() {
  case "$1" in sh|bash|dash|zsh|ash|ksh|mksh) return 0 ;; *) return 1 ;; esac
}

check_shell_input() {
  local segment_start="$1" command_index="$2" end="$3" executable="$4" i
  is_shell_executable "$executable" || return 0
  if [ "$segment_start" -gt 0 ] && [ "${TOKENS[$((segment_start - 1))]}" = "|" ]; then
    deny "shell executes unresolved piped stdin"
  fi
  i=$((command_index + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in '<'*) deny "shell executes unresolved redirected stdin" ;; esac
    i=$((i + 1))
  done
}

# Commands that execute another command taken from their own argv. See the
# header: this table buys precision (so `timeout 5 git status` still passes),
# NOT safety -- an omission falls through to check_stray_git_tokens and is
# refused rather than allowed.
is_command_wrapper() {
  case "$1" in
    env|sudo|doas|command|timeout|nohup|setsid|nice|ionice|stdbuf|xargs) return 0 ;;
  esac
  return 1
}

# Does <wrapper>'s <option> consume the NEXT token as its value?
wrapper_option_takes_value() {
  local wrapper="$1" option="$2"
  case "$option" in *=*) return 1 ;; esac
  case "$wrapper" in
    env) case "$option" in -u|--unset) return 0 ;; esac ;;
    sudo|doas) case "$option" in -u|-g|-h|-p|-C|-T|-R) return 0 ;; esac ;;
    timeout) case "$option" in -s|--signal|-k|--kill-after) return 0 ;; esac ;;
    nice|ionice) case "$option" in -n|-c|-p|--adjustment|--class|--classdata) return 0 ;; esac ;;
    stdbuf) case "$option" in -i|-o|-e|--input|--output|--error) return 0 ;; esac ;;
    xargs) case "$option" in
             -I|-i|-n|-L|-P|-s|-E|-d|-a|--replace|--max-args|--max-lines|--max-procs|--delimiter|--arg-file) return 0 ;;
           esac ;;
  esac
  return 1
}

# Index of the command <wrapper> will run, skipping its options and any fixed
# operand of its own (timeout's DURATION).
skip_wrapper_args() {
  local wrapper="$1" i="$2" end="$3" operands=0 token
  case "$wrapper" in timeout) operands=1 ;; esac
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    if [ "$token" = "--" ]; then i=$((i + 1)); break; fi
    case "$token" in
      -?*)
        if wrapper_option_takes_value "$wrapper" "$token"; then i=$((i + 2)); else i=$((i + 1)); fi
        ;;
      *=*)
        if [ "$wrapper" = "env" ]; then i=$((i + 1)); else break; fi
        ;;
      *) break ;;
    esac
  done
  while [ "$operands" -gt 0 ] && [ "$i" -lt "$end" ]; do
    i=$((i + 1)); operands=$((operands - 1))
  done
  printf '%s\n' "$i"
}

segment_command_index() {
  local i="$1" end="$2" wrapper token
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    case "$token" in *=*) i=$((i + 1)); continue ;; esac
    wrapper="${token##*/}"
    if ! is_command_wrapper "$wrapper"; then printf '%s\n' "$i"; return 0; fi
    i="$(skip_wrapper_args "$wrapper" $((i + 1)) "$end")"
  done
  return 1
}

# Commands that provably do not execute their arguments, so a `git` token is
# just text to them. Deliberately short: sed (GNU `e`), awk (system()), find
# (-exec), perl and python all CAN execute and are excluded.
argument_inert() {
  case "$1" in
    echo|printf|cat|grep|egrep|fgrep|rg|head|tail|wc|ls|man|which|jq) return 0 ;;
  esac
  return 1
}

# Fail closed: an unrecognized executable holding a bare `git` token may be a
# wrapper we do not model (find -exec, parallel, a local script), which would
# otherwise walk every rule past the guard (#121).
check_stray_git_tokens() {
  local start="$1" end="$2" executable="$3" i
  argument_inert "$executable" && return 0
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]##*/}" in
      git) deny "'$executable' may execute the git command in its arguments" ;;
    esac
    i=$((i + 1))
  done
}

check_indirect_segment() {
  local start="$1" end="$2" i
  i="$(segment_command_index "$start" "$end")" || return 0
  if [ "${DYNAMIC[$i]}" -eq 1 ]; then
    deny "dynamic executable cannot be safety-classified"
  fi
}

check_shell_command() {
  local command="$1" i=0 end command_index token executable
  [ "$DM_GUARD_DEPTH" -le 4 ] || deny "excessively nested shell command"
  lex_shell_command "$command"
  while [ "$i" -lt "${#TOKENS[@]}" ]; do
    if is_segment_end "${TOKENS[$i]}"; then i=$((i + 1)); continue; fi
    end="$i"
    while [ "$end" -lt "${#TOKENS[@]}" ] && ! is_segment_end "${TOKENS[$end]}"; do end=$((end + 1)); done
    check_indirect_segment "$i" "$end"
    if command_index="$(segment_command_index "$i" "$end")"; then
      token="${TOKENS[$command_index]}"; executable="${token##*/}"
      check_shell_input "$i" "$command_index" "$end" "$executable"
      check_nested_shell "$command_index" "$end" "$executable"
      if [ "$executable" = "busybox" ] && [ $((command_index + 1)) -lt "$end" ]; then
        command_index=$((command_index + 1))
        token="${TOKENS[$command_index]}"; executable="${token##*/}"
        check_shell_input "$i" "$command_index" "$end" "$executable"
        check_nested_shell "$command_index" "$end" "$executable"
      fi
      if [ "$executable" = "git" ]; then
        check_git_segment "$i" "$command_index" "$end"
      else
        check_stray_git_tokens "$command_index" "$end" "$executable"
      fi
    fi
    i=$((end + 1))
  done
}

hook_command() {
  local payload command
  payload="$(cat)"
  if ! command="$(printf '%s' "$payload" | jq -er '
    (.tool_input // .toolInput // {}) as $input |
    if ($input | type) == "string" then $input
    elif ($input.cmd? | type) == "string" then $input.cmd
    elif ($input.command? | type) == "string" then $input.command
    else error("missing shell command") end
  ')"; then
    deny "unparseable PreToolUse payload"
  fi
  check_shell_command "$command"
}

case "${1:-}" in
  hook) hook_command ;;
  check) shift; [ "$#" -gt 0 ] || deny "empty shell command"; check_shell_command "$*" ;;
  *) printf 'usage: dm-command-guard.sh {hook|check <shell-command>}\n' >&2; exit 2 ;;
esac

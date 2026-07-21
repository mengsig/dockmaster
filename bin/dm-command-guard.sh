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
#   conditional  permitted, minus specific destructive flag forms
#                (push, branch, tag, worktree, switch, config)
#   refused      everything else, named or not
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

# An inline alias that SHADOWS the invoked subcommand makes that subcommand
# something other than what it reads as, defeating the allowlist -- refuse
# regardless of the alias body. An alias that is never invoked is untouched.
check_alias_entry() {
  local entry="$1" dynamic="$2" subcommand="$3" name
  case "$entry" in alias.*=*) ;; *) return 0 ;; esac
  name="${entry#alias.}"; name="${name%%=*}"
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
      GIT_CONFIG_COUNT=*)
        [ "${DYNAMIC[$i]}" -eq 0 ] || deny "dynamic Git config count cannot be safety-classified"
        ;;
      GIT_CONFIG_KEY_*=*)
        [ "${DYNAMIC[$i]}" -eq 0 ] || deny "dynamic Git config key cannot be safety-classified"
        case "${token#*=}" in
          alias.*)
            suffix="${token%%=*}"; suffix="${suffix#GIT_CONFIG_KEY_}"
            value=""; found=0; j="$start"
            while [ "$j" -lt "$git_index" ]; do
              case "${TOKENS[$j]}" in
                GIT_CONFIG_VALUE_"$suffix"=*) value="${TOKENS[$j]#*=}"; found=1; break ;;
              esac
              j=$((j + 1))
            done
            if [ "$found" -eq 0 ]; then
              check_alias_entry "${token#*=}=" 1 "$subcommand"
            else
              check_alias_entry "${token#*=}=$value" "${DYNAMIC[$j]}" "$subcommand"
            fi
            ;;
        esac
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
          check_alias_entry "$config" 1 "$subcommand"
        else
          check_alias_entry "$config" "${DYNAMIC[$i]}" "$subcommand"
        fi
        ;;
      -calias.*=*) check_alias_entry "${token#-c}" "${DYNAMIC[$i]}" "$subcommand" ;;
      --config-env=alias.*=*) check_alias_entry "${token#--config-env=}" 1 "$subcommand" ;;
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
  local start="$1" end="$2"
  has_arg "$start" "$end" remove || return 0
  if has_short_flag "$start" "$end" f || has_arg "$start" "$end" --force; then
    deny "git worktree remove --force"
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

# The allowlist. Unknown and future subcommands land in the default case and are
# refused: that is the point of the inversion (#121). Named refusals worth
# recording: reset/clean/restore/checkout (discard worktree or index state),
# stash (forbidden by AGENTS.md), reflog/gc/prune/repack (destroy the
# dangling-commit recovery net), filter-branch/filter-repo (rewrite history),
# update-ref/symbolic-ref/pack-refs (write refs directly), sparse-checkout and
# submodule (remove working-tree files), rm (removes tracked files, and the
# recovery commands are themselves refused), remote (repoints push targets).
check_git_subcommand() {
  local sub_index="$1" end="$2" subcommand="$3"
  case "$subcommand" in
    status|log|diff|show|describe|blame|shortlog|grep|cherry|range-diff|\
    ls-files|ls-tree|ls-remote|cat-file|rev-parse|rev-list|name-rev|\
    for-each-ref|merge-base|diff-tree|diff-index|count-objects|\
    check-ignore|check-attr|version|help) return 0 ;;
    add|commit|fetch|pull|merge|rebase|cherry-pick|revert|am|apply|\
    format-patch|mv|init|clone) return 0 ;;
    push) check_git_push "$sub_index" "$end" ;;
    branch) check_git_branch "$sub_index" "$end" ;;
    tag) check_git_tag "$sub_index" "$end" ;;
    worktree) check_git_worktree "$sub_index" "$end" ;;
    config) check_git_config "$sub_index" "$end" ;;
    switch) check_git_switch "$sub_index" "$end" ;;
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

#!/usr/bin/env bash
# dm-command-guard.sh - block destructive Git shell commands before execution.

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

has_short_flag() {
  local start="$1" end="$2" wanted="$3" i flags
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in
      -?*) flags="${TOKENS[$i]#-}"; case "$flags" in *"$wanted"*) return 0 ;; esac ;;
    esac
    i=$((i + 1))
  done
  return 1
}

alias_value_is_destructive() {
  local value=" $1 "
  case "$value" in
    *' reset '*|*' clean '*|*' restore '*|*' checkout '*) return 0 ;;
  esac
  return 1
}

check_alias_entry() {
  local entry="$1" dynamic="$2" subcommand="$3" name value
  case "$entry" in alias.*=*) ;; *) return 0 ;; esac
  name="${entry#alias.}"; name="${name%%=*}"
  [ "$name" = "$subcommand" ] || return 0
  [ "$dynamic" -eq 0 ] || deny "invoked Git alias has a dynamic definition"
  value="${entry#*=}"
  alias_value_is_destructive "$value" && deny "Git alias invokes a destructive command"
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
  case "$subcommand" in
    reset) deny "git reset" ;;
    clean) deny "git clean" ;;
    restore) deny "git restore" ;;
    switch)
      if has_short_flag "$sub_index" "$end" f || has_arg "$sub_index" "$end" --force \
          || has_arg "$sub_index" "$end" --discard-changes \
          || has_arg "$sub_index" "$end" -C || has_arg "$sub_index" "$end" --force-create \
          || has_arg "$sub_index" "$end" --orphan; then
        deny "git switch with discard/force"
      fi ;;
    checkout) deny "git checkout" ;;
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

segment_command_index() {
  local i="$1" end="$2" wrapper token
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    case "$token" in *=*) i=$((i + 1)); continue ;; esac
    wrapper="${token##*/}"
    case "$wrapper" in
      env)
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          case "${TOKENS[$i]}" in -u|--unset) i=$((i + 2)) ;; -*|*=*) i=$((i + 1)) ;; *) break ;; esac
        done
        ;;
      sudo)
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          case "${TOKENS[$i]}" in -u|-g|-h|-p|-C|-T|-R) i=$((i + 2)) ;; -*) i=$((i + 1)) ;; *) break ;; esac
        done
        ;;
      command)
        i=$((i + 1)); while [ "$i" -lt "$end" ] && [[ "${TOKENS[$i]}" = -* ]]; do i=$((i + 1)); done
        ;;
      *) printf '%s\n' "$i"; return 0 ;;
    esac
  done
  return 1
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
        token="${TOKENS[$((command_index + 1))]}"; executable="${token##*/}"
        check_shell_input "$i" $((command_index + 1)) "$end" "$executable"
        check_nested_shell $((command_index + 1)) "$end" "$executable"
      fi
      [ "$executable" != "git" ] || check_git_segment "$i" "$command_index" "$end"
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

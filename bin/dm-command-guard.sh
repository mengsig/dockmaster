#!/usr/bin/env bash
# dm-command-guard.sh - block destructive Git shell commands before execution.

set -euo pipefail

deny() {
  printf 'BLOCKED: destructive Git command refused: %s\n' "$1" >&2
  exit 2
}

clean_token() {
  local token="$1"
  token="${token#\"}"; token="${token%\"}"
  token="${token#\'}"; token="${token%\'}"
  printf '%s\n' "$token"
}

is_segment_end() {
  case "$1" in ';'|'&&'|'||'|'|'|'&'|'('|')') return 0 ;; esac
  return 1
}

git_subcommand_index() {
  local start="$1" end="$2" i token
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="$(clean_token "${TOKENS[$i]}")"
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
  local start="$1" end="$2" wanted="$3" i token
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="$(clean_token "${TOKENS[$i]}")"
    [ "$token" = "$wanted" ] && return 0
    i=$((i + 1))
  done
  return 1
}

has_short_flag() {
  local start="$1" end="$2" wanted="$3" i token flags
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="$(clean_token "${TOKENS[$i]}")"
    case "$token" in
      -?*) flags="${token#-}"; case "$flags" in *"$wanted"*) return 0 ;; esac ;;
    esac
    i=$((i + 1))
  done
  return 1
}

check_git_segment() {
  local git_index="$1" end="$2" sub_index subcommand
  sub_index="$(git_subcommand_index "$git_index" "$end")" || return 0
  subcommand="$(clean_token "${TOKENS[$sub_index]}")"
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

check_shell_command() {
  local command="$1" normalized i end token executable
  normalized="$(printf '%s' "$command" | tr '\n' ' ' | sed 's/[;&|()]/ & /g')"
  read -r -a TOKENS <<< "$normalized"
  i=0
  while [ "$i" -lt "${#TOKENS[@]}" ]; do
    token="$(clean_token "${TOKENS[$i]}")"; executable="${token##*/}"
    if [ "$executable" = "git" ]; then
      end=$((i + 1))
      while [ "$end" -lt "${#TOKENS[@]}" ] && ! is_segment_end "${TOKENS[$end]}"; do end=$((end + 1)); done
      check_git_segment "$i" "$end"
      i="$end"
    else
      i=$((i + 1))
    fi
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

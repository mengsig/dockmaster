#!/usr/bin/env bash
# dm-command-guard.sh - classify a shell command before execution and refuse the
# Git forms that can lose work. Runs as `check <command>` or as a PreToolUse
# hook reading the tool JSON on stdin.
#
# STILL UNWIRED — do not read this file as an active control. Its only caller
# was the Codex PreToolUse hook, removed with that runtime; no Claude
# `settings.json` installs it. #89 owns the wiring and is deliberately NOT done
# here: arming was tried and reverted because the guard refused ordinary
# compound shell (`for r in a b; do git -C "$r" status; done`) and it fails open
# by construction — a PreToolUse hook that exits non-zero-non-2, or is killed at
# its timeout, is a NON-BLOCKING error and the tool runs anyway. Until then the
# logic is exercised only by the tests.
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
# EXECUTION VECTORS: a permitted subcommand that RUNS a string handed to it
# carries any refused form straight past the allowlist. The known ones are
# refused -- rebase --exec, bisect run, submodule foreach, difftool --extcmd,
# for-each-repo, an alias shadowing the invoked subcommand, and -c/git
# config/GIT_* settings of keys whose value Git executes.
#
# That class is NARROWED, NOT CLOSED, and the code must not be read as claiming
# otherwise. Git keeps adding executing config keys; config_key_executes matches
# a moving target by pattern; a subcommand that grows a new command-running
# option gains it silently. These rules remove the easy paths.
#
# PROCESS REDIRECTION: pointing Git at another repository, exec dir, or binary
# is its own vector -- the target supplies config and hooks. Refused in BOTH
# spellings (an option guarded in only one form is a bypass): --exec-path,
# --git-dir, --work-tree (git_option_class) and the env twins GIT_EXEC_PATH,
# GIT_DIR, GIT_WORK_TREE, PATH, LD_PRELOAD, DYLD_* (check_environment_prefixes).
# An unrecognized pre-subcommand option fails closed, like the subcommand list.
#
# `-C <dir>` is a DELIBERATE EXCEPTION, not coverage: it reaches another
# repository (hence another config and hooks) exactly as --git-dir does, but the
# toolbelt uses it constantly, so refusing it is not viable. The class is
# narrowed here too, not closed.
#
# ENV FALLBACKS: guarding only the GIT_* spelling is the same bug in a second
# place -- Git falls back to plain PAGER/EDITOR/VISUAL/SSH_ASKPASS, all verified
# executing. Adding a GIT_* rule means checking for an unprefixed fallback.
#
# WHAT THIS GUARD IS FOR: raising the cost of an ACCIDENTAL destructive command
# and catching the forms an agent actually emits -- which is most of the real
# risk, since the usual failure is a confused agent, not a hostile one. It does
# NOT resist someone who knows it is here. It parses ONE command; it does not
# interpret a shell, and expansion/substitution resolve after it has decided.
#
# WRAPPERS: env/sudo/timeout/nohup/nice/xargs/... are unwrapped to the command
# they run. That table is a PRECISION aid, not the safety boundary — an
# unrecognized executable holding a bare `git` token is refused outright
# (check_stray_git_tokens), so an unlisted wrapper fails closed rather than
# bypassing. A quoted MULTI-WORD string starting with git is re-entered into the
# guard and classified instead, so `--body "git log shows the bug"` is not
# collateral. Text tools that provably never execute their argv are exempt so
# `grep git .` still works; sed/awk/find/perl are deliberately NOT exempt.
#
# COMMAND POSITION vs ARGUMENT POSITION: an option, or the VALUE of the option
# before it, is data the executable was handed, so a quoted sentence there is
# prose and is not re-entered (#143). Three things keep that from becoming a
# hole, each with a test: a string whose own first word is `git` is classified
# WHEREVER it sits; a bare shell or runner token in the arguments makes the rest
# of the scan strict (`find . -exec sh -c "git push --force"`); and a command
# RUNNER keeps all of its arguments strict from the start.
# The NARROWING that remains, stated plainly: an unmodelled executable that runs
# its own option value where that value does NOT start with `git` -- say
# `./deploy.sh --cmd "timeout 5 git push --force"` -- is not classified.
#
# DELIBERATELY PERMITTED, each with a test that says so:
#   - `git push --force-with-lease` / `--force-if-includes`: the toolbelt itself
#     uses lease-pinned force (dm-pr.sh) and #89 records it as intentional.
#   - a Git alias that is defined but never invoked.
#   - `git rebase` / `merge` / `pull`: they refuse to run on a dirty tree.
#   - `git <sub> --help`: renders documentation, executes nothing.
#   - `git config` on a key Git does not execute, read or write.
#   - `git restore <path>` and `git checkout [<tree-ish>] -- <path>`: restoring
#     a drifted tracked file is ordinary work (#89). Scoped to literal paths
#     only — no pathspec, `.`, a glob or `:` magic is a whole-tree discard.
#
# NOT A SANDBOX. A tool that emits no Bash hook event is never seen at all.
# See SECURITY.md for the coverage statement and the known limits.

set -euo pipefail
DM_GUARD_DEPTH="${DM_GUARD_DEPTH:-0}"
DM_GUARD_MAX_COMMAND="${DM_GUARD_MAX_COMMAND:-65536}"

deny() {
  printf 'BLOCKED: destructive Git command refused: %s\n' "$1" >&2
  exit 2
}

# bash rescans a string from its start for every `${var:offset:1}`, so a
# per-character loop is QUADRATIC in the command length: 32KB took 21s against a
# 10s PreToolUse timeout, and a guard that times out is a guard that is not
# there. Read through a bounded sliding window instead -- the refill is the only
# O(offset) operation and it happens once per LEX_WINDOW characters.
LEX_WINDOW=512

lex_char() {
  local offset="$1"
  if [ "$offset" -ge "$LEX_LENGTH" ] || [ "$offset" -lt 0 ]; then LEX_CHAR=""; return 0; fi
  if [ "$offset" -lt "$LEX_BASE" ] || [ "$offset" -ge $((LEX_BASE + ${#LEX_CHUNK})) ]; then
    LEX_BASE="$offset"; LEX_CHUNK="${LEX_INPUT:$offset:$LEX_WINDOW}"
  fi
  LEX_CHAR="${LEX_CHUNK:$((offset - LEX_BASE)):1}"
}

# A heredoc body is stdin DATA, not commands. Left in the token stream,
# `--body "$(cat <<'EOF' ... EOF)"` re-lexed ordinary prose as commands and any
# line holding a bare `git` refused. `<<<` is a HERESTRING, not a heredoc: it
# must keep reaching check_shell_input, which refuses a shell fed unresolved
# stdin. Only ONE pending delimiter is tracked; a second `<<` on the same line
# overwrites it, so the rarer multi-heredoc form degrades to lexing the first
# body as text rather than skipping both.
#
# OPERATOR POSITION IS THE WHOLE GATE. This runs on every token AFTER quote
# stripping, so `echo "<<EOF"` and a real `<<EOF` arrive identical -- and
# believing the lookalike put the lexer into heredoc state and skipped the REST
# OF THE INPUT, so `echo "<<EOF"` + newline + `git push --force` PASSED (#163).
# A redirection operator is by definition unquoted, so the leading `<<` must
# come from plain, unquoted, unescaped text: TOKEN_LITERAL counts exactly those
# leading characters and a lookalike scores 0.
note_heredoc_operator() {
  local word="$1" literal="$2"
  if [ "$HEREDOC_WANT_DELIMITER" -eq 1 ]; then
    HEREDOC_WANT_DELIMITER=0
    set_heredoc_delimiter "$word" "$literal"
    return 0
  fi
  case "$word" in '<<<'*) return 0 ;; esac
  # `<<-` needs three literal characters, `<<` two: a quoted `-` is part of the
  # delimiter, not the tab-stripping operator.
  case "$word" in
    '<<-')   if [ "$literal" -ge 3 ]; then HEREDOC_WANT_DELIMITER=1; fi ;;
    '<<')    if [ "$literal" -ge 2 ]; then HEREDOC_WANT_DELIMITER=1; fi ;;
    '<<-'?*) if [ "$literal" -ge 3 ]; then set_heredoc_delimiter "${word#<<-}" $((literal - 3)); fi ;;
    '<<'?*)  if [ "$literal" -ge 2 ]; then set_heredoc_delimiter "${word#<<}" $((literal - 2)); fi ;;
  esac
  return 0
}

# `<<'EOF'` is LITERAL, `<<EOF` is INTERPOLATED -- bash really runs a `$(...)`
# in the body of the second one. The lexer treated both the same and skipped
# the body wholesale, so `cat <<EOF` + `$(git push --force)` + `EOF` PASSED
# (#163). The delimiter counts as quoted when any of its characters did not
# come from plain literal text, which is what bash itself keys expansion on.
set_heredoc_delimiter() {
  local delimiter="$1" literal="$2"
  [ "$literal" -ge 0 ] || deny "internal: heredoc delimiter literal count went negative"
  HEREDOC_DELIMITER="$delimiter"
  # Every character literal => nothing was quoted => bash expands the body.
  if [ "$literal" -ge "${#delimiter}" ]; then HEREDOC_QUOTED=0; else HEREDOC_QUOTED=1; fi
  heredoc_substitution_reset
}

heredoc_substitution_reset() {
  HEREDOC_SUB_KIND=""; HEREDOC_SUB_DEPTH=0
  HEREDOC_SUB_INNER=""; HEREDOC_SUB_QUOTE=""
}

# Walk an INTERPOLATED heredoc body one character at a time, recording the
# `$( ... )` and backtick spans that bash would actually execute. Character-wise
# rather than jumping the index, so the delimiter line still ends the body
# exactly as before -- and the literal prose around a substitution never enters
# the token stream, which is the over-blocking the skip exists to prevent.
# Paren counting is quote-aware for the same reason consume_command_substitution
# is: `$(grep "(" f)` is balanced to a real shell.
scan_heredoc_body() {
  local char="$1" next="$2"
  case "$HEREDOC_SUB_KIND" in
    # A backslash in an interpolated body quotes the next character, so
    # `\$(...)` is prose, not a substitution.
    escape) HEREDOC_SUB_KIND="" ;;
    "")
      case "$char" in
        \\) HEREDOC_SUB_KIND="escape" ;;
        '$') if [ "$next" = "(" ]; then HEREDOC_SUB_KIND="paren"; HEREDOC_SUB_DEPTH=0; fi ;;
        '`') HEREDOC_SUB_KIND="backtick" ;;
      esac
      ;;
    paren)
      if [ -n "$HEREDOC_SUB_QUOTE" ]; then
        if [ "$char" = "$HEREDOC_SUB_QUOTE" ]; then HEREDOC_SUB_QUOTE=""; fi
        HEREDOC_SUB_INNER+="$char"
        return 0
      fi
      case "$char" in
        "'"|'"') HEREDOC_SUB_QUOTE="$char" ;;
        '(')
          HEREDOC_SUB_DEPTH=$((HEREDOC_SUB_DEPTH + 1))
          if [ "$HEREDOC_SUB_DEPTH" -eq 1 ]; then return 0; fi
          ;;
        ')')
          HEREDOC_SUB_DEPTH=$((HEREDOC_SUB_DEPTH - 1))
          if [ "$HEREDOC_SUB_DEPTH" -eq 0 ]; then
            SUBSTITUTIONS+=("$HEREDOC_SUB_INNER"); heredoc_substitution_reset; return 0
          fi
          ;;
      esac
      HEREDOC_SUB_INNER+="$char"
      ;;
    backtick)
      if [ "$char" = '`' ]; then
        SUBSTITUTIONS+=("$HEREDOC_SUB_INNER"); heredoc_substitution_reset; return 0
      fi
      HEREDOC_SUB_INNER+="$char"
      ;;
  esac
  return 0
}

# `<<-` strips leading tabs from its delimiter line, so compare trimmed. Called
# once per heredoc LINE, not per character.
heredoc_line_ends_body() {
  local line="$1"
  while [ "${line# }" != "$line" ] || [ "${line#$'\t'}" != "$line" ]; do
    line="${line# }"; line="${line#$'\t'}"
  done
  [ "$line" = "$HEREDOC_DELIMITER" ]
}

# How many LEADING characters of the token came from plain, unquoted, unescaped
# text -- the one fact that separates a real `<<` redirection operator from a
# quoted lookalike (#163). Only note_heredoc_operator reads it.
# The plain-state lexer increments TOKEN_LITERAL unconditionally and the first
# quote/escape/substitution SNAPSHOTS the count, rather than each character
# testing a frozen flag: the test cost 40% of the lexer's runtime on a 32KB
# command, and the guard's whole safety story rests on it staying fast.
# TOKEN_LITERAL_FROZEN is -1 until the snapshot is taken.
freeze_token_literal() {
  [ "$TOKEN_LITERAL_FROZEN" -ge 0 ] || TOKEN_LITERAL_FROZEN="$TOKEN_LITERAL"
}

append_token() {
  local literal="$TOKEN_LITERAL"
  [ "$TOKEN_LITERAL_FROZEN" -lt 0 ] || literal="$TOKEN_LITERAL_FROZEN"
  TOKENS+=("$token")
  DYNAMIC+=("$dynamic")
  note_heredoc_operator "$token" "$literal"
  token=""; dynamic=0; started=0
  TOKEN_LITERAL=0; TOKEN_LITERAL_FROZEN=-1
}

# Consume the balanced `$( ... )` that starts at index $1, append the raw text
# to the token being built, RECORD the inner command, and leave the index of the
# closing paren in SUBSTITUTION_END. Sets a global rather than printing it: a
# command substitution would run this in a subshell and lose both the token text
# and the recorded command.
# Paren counting is QUOTE-AWARE: `$(grep "(" file)` is balanced to a real shell,
# and counting the quoted paren ran the scan off the end and refused it.
consume_command_substitution() {
  local i="$1" depth=1 inner="" char quote=""
  token+='$('; dynamic=1; started=1; freeze_token_literal
  i=$((i + 2))
  while [ "$i" -lt "$LEX_LENGTH" ] && [ "$depth" -gt 0 ]; do
    lex_char "$i"; char="$LEX_CHAR"
    if [ -n "$quote" ]; then
      if [ "$char" = "$quote" ]; then quote=""; fi
    else
      case "$char" in
        "'"|'"') quote="$char" ;;
        '(') depth=$((depth + 1)) ;;
        ')') depth=$((depth - 1)) ;;
      esac
    fi
    token+="$char"
    [ "$depth" -eq 0 ] || inner+="$char"
    i=$((i + 1))
  done
  # Genuinely unbalanced: a real shell FAILS TO PARSE this and runs nothing, so
  # refusing it is over-blocking a command that cannot execute. Leave it as one
  # opaque DYNAMIC token -- still refused in executable position, never read as
  # prose -- rather than denying.
  if [ "$depth" -gt 0 ]; then SUBSTITUTION_END=$((LEX_LENGTH - 1)); return 0; fi
  SUBSTITUTIONS+=("$inner")
  SUBSTITUTION_END=$((i - 1))
}

# Same for the backtick spelling. An escape inside backticks is passed through
# verbatim: the content is re-classified by a fresh lexer, which applies its own
# escape rules to it.
consume_backtick_substitution() {
  local i="$1" inner="" char closed=0
  token+='`'; dynamic=1; started=1; freeze_token_literal
  i=$((i + 1))
  while [ "$i" -lt "$LEX_LENGTH" ]; do
    lex_char "$i"; char="$LEX_CHAR"
    token+="$char"
    if [ "$char" = '`' ]; then closed=1; i=$((i + 1)); break; fi
    inner+="$char"
    i=$((i + 1))
  done
  if [ "$closed" -eq 0 ]; then SUBSTITUTION_END=$((LEX_LENGTH - 1)); return 0; fi
  SUBSTITUTIONS+=("$inner")
  SUBSTITUTION_END=$((i - 1))
}

lex_shell_command() {
  local i=0 char next state="plain" escaped=0 heredoc_line=""
  LEX_INPUT="$1"; LEX_LENGTH="${#LEX_INPUT}"; LEX_CHUNK=""; LEX_BASE=0
  HEREDOC_DELIMITER=""; HEREDOC_WANT_DELIMITER=0; HEREDOC_QUOTED=0
  heredoc_substitution_reset
  TOKENS=(); DYNAMIC=(); SUBSTITUTIONS=(); token=""; dynamic=0; started=0
  TOKEN_LITERAL=0; TOKEN_LITERAL_FROZEN=-1
  while [ "$i" -lt "$LEX_LENGTH" ]; do
    lex_char "$i"; char="$LEX_CHAR"
    lex_char $((i + 1)); next="$LEX_CHAR"
    if [ "$escaped" -eq 1 ]; then
      [ "$char" = $'\n' ] || { token+="$char"; started=1; }
      escaped=0; i=$((i + 1)); continue
    fi
    case "$state" in
      heredoc)
        # Body text stays out of the token stream; only the delimiter line ends
        # it. An UNQUOTED delimiter means bash expands the body, so the
        # substitutions in it are recorded and classified even though the
        # surrounding prose is not (#163).
        # Filtered inline rather than calling per character: an ordinary body
        # character outside a substitution needs no work at all, and paying a
        # function call for each one cost 2.3x on a 32KB body -- against a hook
        # timeout that FAILS OPEN, which is the one budget that cannot slip.
        if [ "$HEREDOC_QUOTED" -eq 0 ]; then
          case "$char" in
            '$'|'`'|\\) scan_heredoc_body "$char" "$next" ;;
            *) [ -z "$HEREDOC_SUB_KIND" ] || scan_heredoc_body "$char" "$next" ;;
          esac
        fi
        if [ "$char" != $'\n' ]; then
          heredoc_line+="$char"
        else
          if heredoc_line_ends_body "$heredoc_line"; then
            state="plain"; HEREDOC_DELIMITER=""; heredoc_substitution_reset
          fi
          heredoc_line=""
        fi
        ;;
      single)
        if [ "$char" = "'" ]; then state="plain"; else token+="$char"; fi
        started=1
        ;;
      double)
        case "$char" in
          '"') state="plain" ;;
          \\) escaped=1 ;;
          '$')
            if [ "$next" = "(" ]; then
              consume_command_substitution "$i"; i="$SUBSTITUTION_END"
            else
              token+="$char"; dynamic=1
            fi
            ;;
          '`') consume_backtick_substitution "$i"; i="$SUBSTITUTION_END" ;;
          *) token+="$char" ;;
        esac
        started=1
        ;;
      plain)
        case "$char" in
          # A quote or an escape ends the token's LITERAL prefix: past here it
          # can no longer be a redirection operator (#163).
          "'") state="single"; started=1; freeze_token_literal ;;
          '"') state="double"; started=1; freeze_token_literal ;;
          \\) escaped=1; started=1; freeze_token_literal ;;
          '$')
            if [ "$next" = "(" ]; then
              consume_command_substitution "$i"; i="$SUBSTITUTION_END"
            else
              token+="$char"; TOKEN_LITERAL=$((TOKEN_LITERAL + 1)); dynamic=1; started=1
            fi
            ;;
          '`') consume_backtick_substitution "$i"; i="$SUBSTITUTION_END" ;;
          '#')
            # A comment ends at end of LINE, not end of input. `break` here
            # discarded every later newline-separated command, unguarded (#121).
            if [ "$started" -ne 0 ]; then
              token+="$char"; TOKEN_LITERAL=$((TOKEN_LITERAL + 1))
            else
              while [ "$i" -lt "$LEX_LENGTH" ]; do
                lex_char "$i"; [ "$LEX_CHAR" != $'\n' ] || break
                i=$((i + 1))
              done
              TOKENS+=(";"); DYNAMIC+=(0)
            fi
            ;;
          ' '|$'\t')
            [ "$started" -eq 0 ] || append_token
            ;;
          $'\n')
            [ "$started" -eq 0 ] || append_token
            TOKENS+=(";"); DYNAMIC+=(0)
            if [ -n "$HEREDOC_DELIMITER" ]; then state="heredoc"; heredoc_line=""; fi
            ;;
          '&')
            # `&` inside a redirection (2>&1, >&2, &>log) belongs to the
            # operator, NOT to a segment break. Splitting there stranded every
            # later flag in a segment whose executable was `1` (#121).
            if [ "$next" = "&" ]; then
              [ "$started" -eq 0 ] || append_token
              TOKENS+=("&&"); DYNAMIC+=(0); i=$((i + 1))
            elif [ "$started" -eq 1 ] && { [ "${token%>}" != "$token" ] || [ "${token%<}" != "$token" ]; }; then
              token+="$char"; TOKEN_LITERAL=$((TOKEN_LITERAL + 1))
            elif [ "$started" -eq 0 ] && [ "$next" = ">" ]; then
              token+="$char"; TOKEN_LITERAL=$((TOKEN_LITERAL + 1)); started=1
            else
              [ "$started" -eq 0 ] || append_token
              TOKENS+=("&"); DYNAMIC+=(0)
            fi
            ;;
          ';'|'|'|'('|')')
            [ "$started" -eq 0 ] || append_token
            if [ "$char" = "|" ] && [ "$next" = "$char" ]; then
              TOKENS+=("$char$char"); DYNAMIC+=(0); i=$((i + 1))
            else
              TOKENS+=("$char"); DYNAMIC+=(0)
            fi
            ;;
          *) token+="$char"; TOKEN_LITERAL=$((TOKEN_LITERAL + 1)); started=1 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  [ "$escaped" -eq 0 ] || deny "unterminated shell escape"
  # An unterminated HEREDOC is accepted because bash reads the body to END OF
  # INPUT too (it warns and runs), so the guard skipped exactly the text bash
  # treats as data -- the command holding the operator was already classified.
  # That only holds now that a quoted lookalike can no longer open a heredoc
  # (#163); it is NOT the "a syntax error runs nothing" this once claimed,
  # which is false: `cat <<EOF` with no delimiter line still runs `cat`.
  # An unterminated QUOTE stays a refusal -- it can be a mis-segmented command.
  case "$state" in
    plain|heredoc) ;;
    *) deny "unterminated shell quote" ;;
  esac
  [ "$started" -eq 0 ] || append_token
}

is_segment_end() {
  case "$1" in ';'|'&&'|'||'|'|'|'&'|'('|')') return 0 ;; esac
  return 1
}

# How a PRE-subcommand git option consumes tokens, same fail-closed shape as
# verb_option_class. The old `-*` catch-all skipped every option it did not
# name, so `--exec-path=DIR` -- the flag spelling of the refused GIT_EXEC_PATH
# env var -- walked straight past the guard (#121).
git_option_class() {
  case "$1" in
    # Refused in BOTH spellings, matching the env twins GIT_EXEC_PATH / GIT_DIR
    # / GIT_WORK_TREE: an option that only appears in one spelling is a bypass.
    # Bare `--exec-path` merely PRINTS the path, so it stays a flag below.
    --exec-path=*|--git-dir|--git-dir=*|--work-tree|--work-tree=*)
      printf 'refused\n' ;;
    -C|-c|--namespace|--super-prefix|--config-env|--attr-source)
      printf 'value\n' ;;
    -C?*|-c?*|--namespace=*|--super-prefix=*|--config-env=*|--attr-source=*)
      printf 'flag\n' ;;
    -h|--help|--version|--exec-path|--html-path|--man-path|--info-path|\
    -p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--no-lazy-fetch|\
    --literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|\
    --no-optional-locks|--no-advice) printf 'flag\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Sets GIT_SUBCOMMAND_INDEX rather than printing it: the caller reads the result
# with `|| return 0`, which in a command substitution would swallow a deny's
# exit and turn a refusal into a pass.
git_subcommand_index() {
  local start="$1" end="$2" i token class
  GIT_SUBCOMMAND_INDEX=""
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    if [ "$token" = "--" ]; then i=$((i + 1)); continue; fi
    case "$token" in
      -?*)
        class="$(git_option_class "$token")"
        case "$class" in
          value) i=$((i + 2)) ;;
          flag) i=$((i + 1)) ;;
          refused) deny "git option '${token%%=*}' repoints Git at another repository or binary" ;;
          *) deny "git has a pre-subcommand option the guard cannot classify: $token" ;;
        esac
        ;;
      *) GIT_SUBCOMMAND_INDEX="$i"; return 0 ;;
    esac
  done
  return 1
}

# Matches `--opt` AND `--opt=value`: git accepts both spellings, so testing only
# the detached one let --exec=/--extcmd= execute (#121). `--force` still does not
# match `--force-with-lease`, which stays permitted.
has_arg() {
  local start="$1" end="$2" wanted="$3" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in
      "$wanted"|"$wanted"=*) return 0 ;;
    esac
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

# Refspecs that destroy without a flag: `+ref` forces, `:ref` (empty source)
# DELETES the remote ref.
has_destructive_refspec() {
  local start="$1" end="$2" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    case "${TOKENS[$i]}" in +*|:*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

# A conditional subcommand's verdict depends on its flags, so a token the guard
# cannot read (expansion, substitution) makes it unclassifiable -- a dynamic
# subcommand and executable were already refused, a dynamic FLAG was not.
# Unconditional subcommands are unaffected: no flag changes their verdict, so
# `git commit -m "$MSG"` stays fine.
require_static_args() {
  local start="$1" end="$2" subcommand="$3" i
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    [ "${DYNAMIC[$i]}" -eq 0 ] \
      || deny "git $subcommand has an argument the guard cannot read"
    i=$((i + 1))
  done
}

# How an option preceding a verb consumes tokens: "value" takes the next token,
# "flag" takes none, "unknown" cannot be modelled. Skipping an option WITHOUT
# its value hands back the value as the verb -- `git notes --ref show remove`
# read the verb as `show` and removed a note.
verb_option_class() {
  local subcommand="$1" option="$2"
  case "$option" in *=*) printf 'flag\n'; return 0 ;; esac
  case "$subcommand" in
    notes) case "$option" in --ref) printf 'value\n'; return 0 ;; esac ;;
    bisect) case "$option" in
              --term-old|--term-new|--term-good|--term-bad) printf 'value\n'; return 0 ;;
              --no-checkout|--first-parent) printf 'flag\n'; return 0 ;;
            esac ;;
    remote) case "$option" in -v|--verbose) printf 'flag\n'; return 0 ;; esac ;;
    submodule) case "$option" in -q|--quiet|--cached) printf 'flag\n'; return 0 ;; esac ;;
    stash) case "$option" in -q|--quiet) printf 'flag\n'; return 0 ;; esac ;;
  esac
  printf 'unknown\n'
}

# The verb of a two-level command such as `remote remove` or `bisect run`.
# Empty when the subcommand is bare. An option the table cannot classify fails
# closed rather than guessing how many tokens it eats.
subcommand_verb() {
  local subcommand="$1" start="$2" end="$3" i token class
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    if [ "$token" = "--" ]; then i=$((i + 1)); continue; fi
    case "$token" in
      -?*)
        class="$(verb_option_class "$subcommand" "$token")"
        case "$class" in
          value) i=$((i + 2)) ;;
          flag) i=$((i + 1)) ;;
          *) deny "git $subcommand has an option the guard cannot classify: $token" ;;
        esac
        ;;
      *) printf '%s\n' "$token"; return 0 ;;
    esac
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

# Config keys whose VALUE Git executes, or that redirect Git at attacker-chosen
# code. Git config names are CASE-INSENSITIVE, so compare lowercased (bash 3.2
# has no ${var,,}); match by pattern because the exact-name list was both
# case-sensitive and materially incomplete. Known-incomplete by nature: Git
# keeps adding executing keys, so this narrows the class, never closes it.
config_key_executes() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$key" in
    core.pager|core.editor|core.sshcommand|core.hookspath|core.fsmonitor|\
    core.askpass|core.alternaterefscommand|core.gitproxy|\
    diff.external|sequence.editor|credential.helper|\
    uploadpack.packobjectshook|init.templatedir|protocol.ext.allow|\
    pager.*|filter.*|submodule.*.update|\
    *.command|*.driver|*.textconv|*.askpass|*.cmd|*.program|*.helper) return 0 ;;
    # The tool families whose `.path` names an EXECUTABLE, plus include.path,
    # which injects config. Enumerated rather than a blanket `*.path`: that
    # blanket also refused `submodule.<name>.path`, which is a tree path and
    # executes nothing (#144). A new tool family must be added here.
    difftool.*.path|mergetool.*.path|browser.*.path|man.*.path|guitool.*.path|\
    include.path|includeif.*.path) return 0 ;;
  esac
  return 1
}

# Config keys whose value is a FILE GIT APPENDS TO. Not execution, but an
# unguarded write through an allowed command, so it is refused alongside its
# environment twin GIT_TRACE* (#139).
config_key_writes_file() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$key" in trace2.*target) return 0 ;; esac
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
  config_key_writes_file "$key" && deny "Git config key '$key' names a file Git writes"
  case "$key" in alias.*) ;; *) return 0 ;; esac
  name="${key#alias.}"
  [ "$name" = "$subcommand" ] || return 0
  [ "$dynamic" -eq 0 ] || deny "invoked Git alias has a dynamic definition"
  deny "invoked Git subcommand is redefined by an inline alias"
}

check_environment_prefixes() {
  local start="$1" git_index="$2" subcommand="$3" i j token suffix value found
  i="$start"
  while [ "$i" -lt "$git_index" ]; do
    token="${TOKENS[$i]}"
    case "$token" in
      # Not Git-specific, but they pick WHICH binary runs as `git` and what code
      # is loaded into it -- a more direct redirect than GIT_TEMPLATE_DIR.
      PATH=*|LD_PRELOAD=*|LD_LIBRARY_PATH=*|LD_AUDIT=*|\
      DYLD_INSERT_LIBRARIES=*|DYLD_LIBRARY_PATH=*)
        deny "environment variable '${token%%=*}' can redirect Git at other code"
        ;;
      # Another repository supplies its own config and hooks, so repointing Git
      # at one makes an ordinary commit run that repo's code.
      GIT_DIR=*|GIT_WORK_TREE=*|GIT_COMMON_DIR=*|GIT_INDEX_FILE=*|\
      GIT_OBJECT_DIRECTORY=*|GIT_ALTERNATE_OBJECT_DIRECTORIES=*)
        deny "Git environment variable '${token%%=*}' repoints Git at another repository"
        ;;
      # Env equivalents of the executing config keys. GIT_CONFIG_PARAMETERS is
      # the generic -c channel and carries ANY key; GIT_EXEC_PATH repoints every
      # subcommand at other binaries.
      GIT_EDITOR=*|GIT_PAGER=*|GIT_EXTERNAL_DIFF=*|GIT_SEQUENCE_EDITOR=*|\
      GIT_SSH=*|GIT_SSH_COMMAND=*|GIT_PROXY_COMMAND=*|GIT_ASKPASS=*|\
      GIT_CONFIG_PARAMETERS=*|GIT_EXEC_PATH=*|GIT_CONFIG=*|\
      GIT_CONFIG_GLOBAL=*|GIT_CONFIG_SYSTEM=*|GIT_TEMPLATE_DIR=*|\
      GIT_MAN_VIEWER=*)
        deny "Git environment variable '${token%%=*}' can redirect Git at other code"
        ;;
      # Git falls back to the PLAIN-spelled variable when the GIT_* one is
      # unset, so guarding only the prefixed spelling left the same execution
      # open. PAGER/EDITOR/VISUAL/SSH_ASKPASS each verified executing a payload
      # against git 2.54; MANPAGER is the same family, unproven here.
      PAGER=*|EDITOR=*|VISUAL=*|SSH_ASKPASS=*|MANPAGER=*)
        deny "environment variable '${token%%=*}' is a Git fallback whose value Git executes"
        ;;
      # The whole GIT_TRACE* family takes a destination: `1`/`2`/`true` writes
      # to stderr, but any other value names a file Git APPENDS trace output to
      # (or a socket, `af_unix:...`). That is an unguarded filesystem write
      # through an allowed command (#139), so only the stderr spellings pass --
      # `GIT_TRACE=1 git status` is the debugging idiom worth keeping.
      GIT_TRACE*=*)
        [ "${DYNAMIC[$i]}" -eq 0 ] || deny "dynamic Git trace destination cannot be safety-classified"
        case "${token#*=}" in
          0|1|2|true|false) ;;
          *) deny "Git environment variable '${token%%=*}' names a file Git writes trace output to" ;;
        esac
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
  git_subcommand_index "$git_index" "$end" || return 0
  sub_index="$GIT_SUBCOMMAND_INDEX"
  [ "${DYNAMIC[$sub_index]}" -eq 0 ] || deny "dynamic Git subcommand cannot be safety-classified"
  subcommand="${TOKENS[$sub_index]}"
  check_environment_prefixes "$start" "$git_index" "$subcommand"
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
      || has_destructive_refspec "$start" "$end"; then
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
  verb="$(subcommand_verb worktree "$start" "$end")"
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

# `git config` can WRITE the very keys -c is refused from setting -- planting
# core.hooksPath makes the next ordinary `git commit` run attacker code. Routed
# through the same predicate, so the two channels cannot drift apart.
# For an executing key the READ is refused alongside the write: `git config
# <key>` is itself a read, so splitting the two means counting operands. Keys
# Git does not execute stay readable and writable (`git config --get user.email`).
check_git_config() {
  local start="$1" end="$2" i token
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    token="${token#*=}"
    case "$token" in
      alias.*) deny "git config touching an alias" ;;
    esac
    if config_key_executes "$token"; then
      deny "git config touching a key whose value Git executes: $token"
    fi
    if config_key_writes_file "$token"; then
      deny "git config touching a key that names a file Git writes: $token"
    fi
    i=$((i + 1))
  done
}

# A pathspec naming ONE literal path, so a restore scoped to it cannot widen
# into a whole-tree discard. `.`, `/` and a glob reach every tracked file, and
# `:` opens Git's pathspec magic (`:/` IS the whole repository).
# Naming `..` was not enough: `../..`, `./.`, `.//`, `src/../..` and any
# absolute path all reach the whole tree, and a crewmate one `cd` deep into its
# own worktree wiped it (#160 review). Test every path COMPONENT instead of the
# whole string, and refuse brace expansion alongside globs.
is_scoped_pathspec() {
  case "$1" in
    ""|/*|:*) return 1 ;;
    *"*"*|*"?"*|*"["*|*"{"*) return 1 ;;
  esac
  case "/$1/" in *"/./"*|*"/../"*) return 1 ;; esac
  return 0
}

restore_option_class() {
  case "$1" in
    -s|--source) printf 'value\n' ;;
    --source=*|--staged|-S|--worktree|-W|--ours|--theirs|--overlay|\
    --no-overlay|--ignore-unmerged|--progress|--no-progress|-q|--quiet)
      printf 'flag\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Restoring a drifted tracked file (the regenerated-lockfile case) is a
# legitimate crewmate operation, so the subcommand cannot be refused outright
# (#89) -- but `git restore .` discards the entire working tree, which is the
# prime-directive violation the guard exists to prevent. Permitted ONLY when
# every operand is a scoped literal path, and refused with none: no pathspec
# means the whole tree. An unmodelled option fails closed like everywhere else.
check_git_restore() {
  local start="$1" end="$2" i token class paths=0 operands_only=0
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    if [ "$operands_only" -eq 0 ]; then
      if [ "$token" = "--" ]; then operands_only=1; i=$((i + 1)); continue; fi
      case "$token" in
        -?*)
          class="$(restore_option_class "$token")"
          case "$class" in
            value) i=$((i + 2)) ;;
            flag) i=$((i + 1)) ;;
            *) deny "git restore has an option the guard cannot classify: $token" ;;
          esac
          continue
          ;;
      esac
    fi
    is_scoped_pathspec "$token" || deny "git restore pathspec is not one scoped path: $token"
    paths=$((paths + 1)); i=$((i + 1))
  done
  [ "$paths" -gt 0 ] || deny "git restore without a pathspec discards the whole worktree"
}

# Only the file-restore spelling, `git checkout [<tree-ish>] -- <path>...`.
# Every other form switches branches, detaches HEAD, creates (-b/-B) or forces,
# and the required `--` is what stops this reopening `git checkout .`.
check_git_checkout() {
  local start="$1" end="$2" i separator=-1 paths=0 token
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    if [ "${TOKENS[$i]}" = "--" ]; then separator="$i"; break; fi
    i=$((i + 1))
  done
  [ "$separator" -ge 0 ] || deny "git checkout without '-- <path>' changes what the worktree points at"
  [ $((separator - start)) -le 2 ] || deny "git checkout takes at most one tree-ish before '--'"
  if [ $((separator - start)) -eq 2 ]; then
    token="${TOKENS[$((start + 1))]}"
    case "$token" in -*) deny "git checkout option before '--' is not the file-restore form: $token" ;; esac
  fi
  i=$((separator + 1))
  while [ "$i" -lt "$end" ]; do
    is_scoped_pathspec "${TOKENS[$i]}" || deny "git checkout pathspec is not one scoped path: ${TOKENS[$i]}"
    paths=$((paths + 1)); i=$((i + 1))
  done
  [ "$paths" -gt 0 ] || deny "git checkout -- without a pathspec discards the whole worktree"
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
#   reset, clean                         discard worktree/index state
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
  # `git <sub> --help` renders documentation and executes nothing. Checked
  # ahead of the verb tables, which classified it as unknown and refused
  # `git remote --help`.
  if [ $((sub_index + 1)) -lt "$end" ]; then
    case "${TOKENS[$((sub_index + 1))]}" in -h|--help) return 0 ;; esac
  fi
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
  esac
  # Past here the verdict turns on a flag or a verb, so an argument the guard
  # cannot read is not classifiable. Unknown subcommands reach the deny below.
  require_static_args "$sub_index" "$end" "$subcommand"
  case "$subcommand" in
    # Safe in the ordinary form, destructive in a specific one.
    push) check_git_push "$sub_index" "$end" ;;
    branch) check_git_branch "$sub_index" "$end" ;;
    tag) check_git_tag "$sub_index" "$end" ;;
    worktree) check_git_worktree "$sub_index" "$end" ;;
    config) check_git_config "$sub_index" "$end" ;;
    switch) check_git_switch "$sub_index" "$end" ;;
    restore) check_git_restore "$sub_index" "$end" ;;
    checkout) check_git_checkout "$sub_index" "$end" ;;
    rm) check_git_rm "$sub_index" "$end" ;;
    rebase) check_git_rebase "$sub_index" "$end" ;;
    difftool) check_git_difftool "$sub_index" "$end" ;;
    # Safe or destructive by verb. `bisect run` and `submodule foreach` execute
    # a command they are handed, so both are refused for the rebase -x reason.
    remote)
      verb="$(subcommand_verb remote "$sub_index" "$end")"
      require_verb remote "$verb" "<none> show get-url add rename set-head set-branches update" ;;
    submodule)
      verb="$(subcommand_verb submodule "$sub_index" "$end")"
      require_verb submodule "$verb" "<none> status init update sync summary add absorbgitdirs set-branch" ;;
    notes)
      verb="$(subcommand_verb notes "$sub_index" "$end")"
      require_verb notes "$verb" "<none> list show add append edit copy merge get-ref" ;;
    bisect)
      verb="$(subcommand_verb bisect "$sub_index" "$end")"
      require_verb bisect "$verb" "start good bad new old skip log view terms replay" ;;
    reflog)
      verb="$(subcommand_verb reflog "$sub_index" "$end")"
      require_verb reflog "$verb" "<none> show exists" ;;
    stash)
      # AGENTS.md forbids stashing; reading the list destroys nothing.
      verb="$(subcommand_verb stash "$sub_index" "$end")"
      require_verb stash "$verb" "list show" ;;
    sparse-checkout)
      verb="$(subcommand_verb sparse-checkout "$sub_index" "$end")"
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
    # `0<file` is the fd-numbered spelling of `<file` and redirects the SAME
    # stdin the shell then executes. Guarding only the bare form left the
    # identical hole one spelling over, which is how #163's heredoc pair got
    # here -- close the class, not the example.
    case "${TOKENS[$i]}" in
      '<'*|0'<'*) deny "shell executes unresolved redirected stdin" ;;
    esac
    i=$((i + 1))
  done
}

# Commands safe to UNWRAP to the command they run. This table buys precision (so
# `timeout 5 git status` still passes), NOT safety -- an omission falls through
# to check_stray_git_tokens and is refused rather than allowed.
# NOTE: xargs is deliberately ABSENT. It appends arguments read from stdin, so
# the argument list the guard sees is never the one git runs
# (`echo --force | xargs git push ...`). Unwrapped it would be classified on
# incomplete input; left unlisted it falls to check_stray_git_tokens and is
# refused, which is the correct verdict for an unknowable argv.
is_command_wrapper() {
  case "$1" in
    env|sudo|doas|command|timeout|nohup|setsid|nice|ionice|stdbuf) return 0 ;;
  esac
  return 1
}

# Runs a command from its argv but must NOT be unwrapped -- either the real argv
# is unknowable (xargs reads stdin) or unwrapping buys nothing. SEPARATE from
# is_command_wrapper because the two lists fail in OPPOSITE directions: adding a
# name here only widens what gets re-classified, while adding it above would
# make segment_command_index trust an argv it cannot see.
# At top level these already fail closed -- check_stray_git_tokens refuses the
# bare `git` token they hold. That reasoning does NOT carry inside a quoted
# string, where the token IS the whole command and nothing inspects it unless
# re-entry fires, so the re-entry trigger must consult this list too.
is_command_runner() {
  case "$1" in
    xargs|exec|time|watch|script|unbuffer|strace|ltrace|proot|parallel|flock) return 0 ;;
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

# Shell KEYWORDS are grammar, not executables. The lexer models no grammar, so
# `for r in a b; do git -C "$r" status; done` made `do` the segment's executable
# and the following `git` a stray bare token -- ordinary compound shell refused
# (#160 review). Transparent here, so the real command behind the keyword is the
# one classified: `if git push --force; then` still refuses.
# `time` is here AND in is_command_runner: unwrapping it is exact (its argv is
# the rest of the segment), while re-entry still has to treat a quoted
# `"time git push --force"` as a command.
# `esac` MUST stay quoted: bash 3.2 reads a bare `esac` anywhere in a pattern
# list as the reserved word and the whole file stops parsing (#164). bash >= 4
# accepts it, so only a real 3.2 catches this.
is_shell_keyword() {
  case "$1" in
    if|then|elif|else|fi|while|until|for|do|done|case|'esac'|select|function|\
    time|coproc|'{'|'}'|'!') return 0 ;;
  esac
  return 1
}

segment_command_index() {
  local i="$1" end="$2" wrapper token
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    case "$token" in *=*) i=$((i + 1)); continue ;; esac
    if is_shell_keyword "$token"; then i=$((i + 1)); continue; fi
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
    echo|printf|cat|grep|egrep|fgrep|rg|head|tail|wc|ls|man|which|type|jq) return 0 ;;
  esac
  return 1
}

# Fail closed: an unrecognized executable holding a bare `git` token may be a
# wrapper we do not model (find -exec, parallel, a local script), which would
# otherwise walk every rule past the guard (#121).
# Matches a bare `git` token AND a quoted command string that STARTS with git
# (`parallel "git push --force origin main"`), which is how such a wrapper is
# normally invoked and is not a bare token.
# Does this string plausibly BEGIN a command rather than merely mention git in
# prose? sh ignores leading whitespace, and the first word may legitimately be
# an env assignment, a wrapper, or a shell -- so testing only for a literal
# leading "git" missed ` git push --force` and `timeout 5 git push --force`.
token_begins_a_command() {
  local first="$1"
  case "$first" in *=*) return 0 ;; esac
  first="${first##*/}"
  case "$first" in git|eval|busybox) return 0 ;; esac
  is_command_wrapper "$first" && return 0
  is_command_runner "$first" && return 0
  is_shell_executable "$first" && return 0
  return 1
}

# COMMAND POSITION vs ARGUMENT POSITION. A token that is an option, or the VALUE
# of the option before it, is DATA the executable was handed -- a `--body`, a
# `--title`, an `-m` message -- not a command it runs. Re-entering such a value
# classified ordinary prose as a command, so any sentence whose first word reads
# like a wrapper or a runner refused once it also said "git" (#143):
# `--body "watch the git log for changes"`. `--` is excluded: it ends the
# options, so what follows it is an operand, not a value.
token_is_option_data() {
  local i="$1" start="$2" previous
  case "${TOKENS[$i]}" in --) return 1 ;; -?*) return 0 ;; esac
  [ "$i" -gt $((start + 1)) ] || return 1
  previous="${TOKENS[$((i - 1))]}"
  case "$previous" in
    --) return 1 ;;
    *=*) return 1 ;;
    -?*) return 0 ;;
  esac
  return 1
}

# A MULTI-WORD string is classified by re-entering the guard rather than refused
# outright: refusing every token whose first word is "git" blocked ordinary prose
# (`--body "git config write path now routed"`), and over-blocking is what gets a
# guard switched off. Re-entry hands the whole string to the normal segmentation
# and wrapper handling, so a leading space, a tab, or a `sh -c`/`env`/`timeout`
# prefix cannot walk past it. A BARE git token still refuses -- the wrapper's
# real argv is the rest of the segment, which this token does not describe, and
# an option value is NOT exempted from that, so `find . -exec git reset --hard`
# stays refused.
# A command RUNNER keeps every argument strict: its options do run commands
# (`flock -c`), and its real argv is unknowable anyway, which is why it is not
# unwrapped in the first place.
check_stray_git_tokens() {
  local start="$1" end="$2" executable="$3" i token flat first
  local data_args=1 hands_to_shell=0
  argument_inert "$executable" && return 0
  if is_command_runner "$executable" || is_shell_executable "$executable"; then
    data_args=0
  fi
  i=$((start + 1))
  while [ "$i" -lt "$end" ]; do
    token="${TOKENS[$i]}"
    flat="${token//$'\t'/ }"; flat="${flat//$'\n'/ }"
    while [ "${flat# }" != "$flat" ]; do flat="${flat# }"; done
    first="${flat%% *}"
    # Past a shell/runner token in the ARGUMENTS, every quoted string is a
    # command being handed to it -- prose is not what follows `sh -c`. So
    # re-enter regardless of the first word, which is the only thing that
    # catches `find . -exec sh -c "cd /tmp && git clean -fdx" \;`.
    if [ "$hands_to_shell" -eq 1 ]; then
      case "$flat" in
        *" "*) DM_GUARD_DEPTH=$((DM_GUARD_DEPTH + 1)) "$0" check "$token"; i=$((i + 1)); continue ;;
      esac
    fi
    if token_begins_a_command "$first"; then
      case "$flat" in
        *" "*)
          # A string whose own first word is `git` is classified wherever it
          # sits: that is how `entr -s "git reset --hard"` and `rsync -e "git
          # push --force"` stay refused, and it matches what the guard did
          # before option values became data.
          if [ "$data_args" -eq 0 ] || [ "${first##*/}" = git ] \
             || ! token_is_option_data "$i" "$start"; then
            DM_GUARD_DEPTH=$((DM_GUARD_DEPTH + 1)) "$0" check "$token"
          fi
          ;;
        *) case "${first##*/}" in
             git) deny "'$executable' may execute the git command in its arguments" ;;
           esac
           # A bare shell or runner token in the ARGUMENTS means this executable
           # hands a command to one -- `find . -exec sh -c "git push --force"`,
           # `docker run img sh -c ...`. check_nested_shell never fires there,
           # because the shell is find's argument rather than the segment's
           # executable, so everything after it must be classified (#160 review).
           # Only the ARGV spelling sets this: a runner that is the segment's own
           # executable keeps the first-word gate, so `xargs -I{} echo "the git
           # log"` stays prose.
           if is_shell_executable "${first##*/}" || is_command_runner "${first##*/}"; then
             data_args=0; hands_to_shell=1
           fi ;;
      esac
    fi
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

# Substitution content executes wherever it appears, so it is classified in its
# own right BEFORE segmentation. The executable and process-substitution
# positions were already refused; argument position was not, so
# `echo $(git push --force)` ran the push (#138).
check_substitutions() {
  local i=0
  while [ "$i" -lt "${#SUBSTITUTIONS[@]}" ]; do
    DM_GUARD_DEPTH=$((DM_GUARD_DEPTH + 1)) "$0" check "${SUBSTITUTIONS[$i]}"
    i=$((i + 1))
  done
}

check_shell_command() {
  local command="$1" i=0 end command_index token executable
  [ "$DM_GUARD_DEPTH" -le 4 ] || deny "excessively nested shell command"
  # A command the parser cannot finish in time is the one failure this must not
  # have: a PreToolUse hook that exits non-zero-non-2, or is killed at its
  # timeout, is a NON-BLOCKING error and the tool runs anyway. So bound the
  # input here and refuse deterministically, rather than letting the largest
  # commands be the ones that walk through.
  [ "${#command}" -le "$DM_GUARD_MAX_COMMAND" ] \
    || deny "shell command is ${#command} bytes, over the ${DM_GUARD_MAX_COMMAND}-byte limit the guard can classify"
  lex_shell_command "$command"
  check_substitutions
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

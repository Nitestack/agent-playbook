# shellcheck shell=bash
# Shared helpers for the PreToolUse guards. Sourced by the guards, never run.
# Needs only bash, jq and coreutils (`realpath`).
#
# Contract of every guard: read the hook JSON on stdin, exit 0 to allow, or
# call `deny` (exit 2 with the reason on stderr, which Claude Code and Codex
# both feed back to the model; the JSON on stdout serves clients that read it).
# A guard that is not active for the current session must exit 0 before it
# reads anything, so ordinary interactive sessions are never disturbed.

# ── Decisions ──────────────────────────────────────────────────────────

deny() {
  jq -cn --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  printf '%s\n' "$1" >&2
  exit 2
}

# ── Registries ─────────────────────────────────────────────────────────

# registry_entry <file> <thread-id>
# Print the registry entry (a JSON object) of a thread and return 0, or return
# 1 when the file is missing, unreadable, malformed or does not list the
# thread. Accepted layouts: {"<thread-id>": {...}}, {"threads": {...}} and
# [{"thread_id": "<thread-id>", ...}] (also `threadId` / `id`).
registry_entry() {
  local file=$1 tid=$2 entry
  [ -r "$file" ] || return 1
  entry=$(jq -c --arg t "$tid" '
    def pick($t):
      if type == "array" then
        map(select(type == "object" and ((.thread_id // .threadId // .id) == $t))) | first
      elif type == "object" and ((.threads | type) as $ty | $ty == "object" or $ty == "array") then
        .threads | pick($t)
      elif type == "object" then .[$t]
      else null end;
    pick($t) // empty | if type == "object" then . else {} end
  ' "$file" 2>/dev/null) || return 1
  [ -n "$entry" ] || return 1
  printf '%s' "$entry"
}

# ── Hook input ─────────────────────────────────────────────────────────

# tool_command: the shell command of a Bash-like tool call. Codex passes
# `["bash", "-lc", "<script>"]`; that is reduced to the script.
tool_command() {
  jq -r '
    (.tool_input.command // .tool_input.cmd // "")
    | if type == "array" then
        (if length >= 3 and (.[0] | test("(^|/)(ba|z|da)?sh$")) and (.[1] | test("^-[a-z]*c$"))
         then .[2] else join(" ") end)
      else . end
  ' <<<"$HOOK_INPUT"
}

# ── Paths ──────────────────────────────────────────────────────────────

# canon_path <path> <base-dir>: absolute path with `.`/`..` and every existing
# symlink resolved; the path itself need not exist.
canon_path() {
  local p=$1 base=$2
  case $p in
    /*) ;;
    *) p="$base/$p" ;;
  esac
  realpath -m -- "$p"
}

# path_inside <canonical-path> <canonical-root>
path_inside() {
  [ "$1" = "$2" ] || [[ $1 == "${2%/}"/* ]]
}

# has_dotdot <path>: true when a path component is `..`.
has_dotdot() {
  [[ $1 == .. || $1 == ../* || $1 == */.. || $1 == */../* ]]
}

# ── Shell command parsing ──────────────────────────────────────────────
#
# parse_command <string> splits a shell command line into simple commands.
# It honours quotes, escapes, separators (; & | newline and parentheses),
# comments, here-documents, redirections and substitutions, which is enough
# to match on words without being fooled by quoted text. It is a guard, not a
# shell: anything it cannot follow is an error and callers fail closed.
#
#   PARSE_MODE=strict   (default) refuse substitutions ($( ), backticks,
#                       <( )), here-documents and any redirection except
#                       `2>&1`-style duplication and `>/dev/null`.
#   PARSE_MODE=lenient  descend into substitutions, skip here-document
#                       bodies and ignore redirections.
#
# Result: CMDS holds one element per simple command, words joined by US.
# split_cmd <element> fills the array W with its words.

US=$'\x1f'
CMDS=()
W=()
PARSE_ERR=""
PARSE_MODE=${PARSE_MODE:-strict}
_s=""
_n=0
_i=0

# The helpers below read and write the locals of parse_seq (dynamic scoping).
_flush_word() {
  if ((inword)); then words+=("$cur"); fi
  cur=""
  inword=0
}

_flush_cmd() {
  local w joined="" first=1
  if ((${#words[@]} > 0)); then
    for w in "${words[@]}"; do
      if ((first)); then
        joined=$w
        first=0
      else
        joined+="$US$w"
      fi
    done
    CMDS+=("$joined")
  fi
  words=()
}

# At "$(" or "<(": parse the nested command list; leave _i on its ")".
_subst() {
  if [ "$PARSE_MODE" = strict ]; then
    PARSE_ERR="command and process substitution are not allowed here"
    return 1
  fi
  _i=$((_i + 2))
  parse_seq 1
}

# At a backtick: parse the text up to the closing backtick as a command list.
_backtick() {
  local rest inner save_s=$_s save_n=$_n save_i=$_i
  if [ "$PARSE_MODE" = strict ]; then
    PARSE_ERR="backtick substitution is not allowed here"
    return 1
  fi
  rest=${_s:_i+1}
  if [[ $rest != *'`'* ]]; then
    PARSE_ERR="unterminated backtick substitution"
    return 1
  fi
  inner=${rest%%'`'*}
  _s=$inner
  _n=${#inner}
  _i=0
  parse_seq 0 || return 1
  _s=$save_s
  _n=$save_n
  _i=$((save_i + ${#inner} + 1))
}

parse_command() {
  _s=$1
  _n=${#_s}
  _i=0
  CMDS=()
  PARSE_ERR=""
  parse_seq 0
  [ -z "$PARSE_ERR" ]
}

parse_seq() {
  local nested=$1 depth=0 cur="" inword=0 words=() q="" c nxt rest word redir_len
  local hd_delims=() hd_strip=() k line cmp
  local re_dup='^(>&[0-9]+)($|[[:space:];|&)])'
  local re_null='^(>>?[[:space:]]*/dev/null)($|[[:space:];|&)])'
  while ((_i < _n)); do
    [ -z "$PARSE_ERR" ] || return 1
    c=${_s:_i:1}
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""; else cur+=$c; fi
    elif [ "$q" = '"' ]; then
      case $c in
        '"') q="" ;;
        '\')
          nxt=${_s:_i+1:1}
          case $nxt in
            '"' | '\' | '$' | '`')
              cur+=$nxt
              _i=$((_i + 1))
              ;;
            $'\n') _i=$((_i + 1)) ;;
            *) cur+=$c ;;
          esac
          ;;
        '$')
          if [ "${_s:_i+1:1}" = "(" ]; then
            _subst || return 1
            cur+='$(…)'
          else
            cur+=$c
          fi
          ;;
        '`')
          _backtick || return 1
          cur+='$(…)'
          ;;
        *) cur+=$c ;;
      esac
    else
      case $c in
        "'")
          q="'"
          inword=1
          ;;
        '"')
          q='"'
          inword=1
          ;;
        '\')
          nxt=${_s:_i+1:1}
          _i=$((_i + 1))
          if [ "$nxt" != $'\n' ]; then
            cur+=$nxt
            inword=1
          fi
          ;;
        '`')
          _backtick || return 1
          cur+='$(…)'
          inword=1
          ;;
        '$')
          if [ "${_s:_i+1:1}" = "(" ]; then
            _subst || return 1
            cur+='$(…)'
          else
            cur+=$c
          fi
          inword=1
          ;;
        ' ' | $'\t' | $'\r') _flush_word ;;
        $'\n')
          _flush_word
          _flush_cmd
          if ((${#hd_delims[@]} > 0)); then
            # Skip the body of every here-document opened on the line just ended.
            for k in "${!hd_delims[@]}"; do
              _i=$((_i + 1))
              while ((_i < _n)); do
                rest=${_s:_i}
                line=${rest%%$'\n'*}
                _i=$((_i + ${#line} + 1))
                cmp=$line
                if ((hd_strip[k])); then cmp=${line#"${line%%[!$'\t']*}"}; fi
                [ "$cmp" = "${hd_delims[k]}" ] && break
              done
              _i=$((_i - 1))
            done
            hd_delims=()
            hd_strip=()
          fi
          ;;
        ';' | '|' | '&' | '(')
          _flush_word
          _flush_cmd
          if [ "$c" = "(" ]; then depth=$((depth + 1)); fi
          ;;
        ')')
          _flush_word
          _flush_cmd
          if ((depth > 0)); then
            depth=$((depth - 1))
          elif ((nested)); then
            return 0
          fi
          ;;
        '#')
          if ((inword)); then
            cur+=$c
          else
            while ((_i + 1 < _n)) && [ "${_s:_i+1:1}" != $'\n' ]; do _i=$((_i + 1)); done
          fi
          ;;
        '<')
          nxt=${_s:_i+1:1}
          if [ "$PARSE_MODE" = strict ]; then
            PARSE_ERR="input redirection, here-documents and process substitution are not allowed here"
            return 1
          fi
          if [ "$nxt" = "(" ]; then
            _subst || return 1
            cur+='$(…)'
            inword=1
          elif [ "$nxt" = "<" ] && [ "${_s:_i+2:1}" != "<" ]; then
            # Here-document: remember the delimiter, skip its body at the newline.
            _i=$((_i + 2))
            if [ "${_s:_i:1}" = "-" ]; then
              hd_strip+=(1)
              _i=$((_i + 1))
            else
              hd_strip+=(0)
            fi
            while [[ ${_s:_i:1} == [[:blank:]] ]]; do _i=$((_i + 1)); done
            word=""
            while ((_i < _n)) && [[ ${_s:_i:1} != [[:space:]\;\&\|\(\)\<\>] ]]; do
              case ${_s:_i:1} in
                "'" | '"' | '\') ;;
                *) word+=${_s:_i:1} ;;
              esac
              _i=$((_i + 1))
            done
            hd_delims+=("$word")
            _i=$((_i - 1))
            _flush_word
          else
            _flush_word
            if [ "$nxt" = "<" ]; then _i=$((_i + 2)); fi
          fi
          ;;
        '>')
          rest=${_s:_i}
          if [[ $rest =~ $re_dup || $rest =~ $re_null ]]; then
            # Redirection to a descriptor or /dev/null; drop a glued `2` of `2>&1`.
            # Read BASH_REMATCH before any other [[ =~ ]] overwrites it.
            redir_len=${#BASH_REMATCH[1]}
            if [[ $cur =~ ^[0-9]+$ ]]; then
              cur=""
              inword=0
            fi
            _i=$((_i + redir_len - 1))
          elif [ "$PARSE_MODE" = strict ]; then
            PARSE_ERR="output redirection is not allowed here"
            return 1
          else
            _flush_word
            while [[ ${_s:_i+1:1} == [\>\&\|] ]]; do _i=$((_i + 1)); done
          fi
          ;;
        *)
          cur+=$c
          inword=1
          ;;
      esac
    fi
    _i=$((_i + 1))
  done
  if [ -n "$q" ]; then
    PARSE_ERR="unterminated quote"
    return 1
  fi
  if ((nested)); then
    PARSE_ERR="unterminated command substitution"
    return 1
  fi
  _flush_word
  _flush_cmd
}

# split_cmd <element of CMDS>: fill W with the words of one simple command.
split_cmd() {
  local t=$1
  W=()
  while [[ $t == *"$US"* ]]; do
    W+=("${t%%"$US"*}")
    t=${t#*"$US"}
  done
  W+=("$t")
}

# ── git ────────────────────────────────────────────────────────────────

GIT_DIRS=()
GIT_SUB=""
GIT_ARGS=()
GIT_BAD=""

# git_parse: analyse W (W[0] is git). Sets GIT_DIRS (the -C values in order),
# GIT_SUB, GIT_ARGS and GIT_BAD (non-empty when an option before the
# subcommand cannot be analysed: `-c`, `--git-dir`, `--exec-path`, ...).
git_parse() {
  local i=1 n=${#W[@]} w
  GIT_DIRS=()
  GIT_SUB=""
  GIT_ARGS=()
  GIT_BAD=""
  while ((i < n)); do
    w=${W[i]}
    case $w in
      -C)
        if ((i + 1 >= n)); then
          GIT_BAD="git -C needs a directory"
          return 0
        fi
        GIT_DIRS+=("${W[i + 1]}")
        i=$((i + 2))
        ;;
      --no-pager | --no-optional-locks | -P) i=$((i + 1)) ;;
      -*)
        # GIT_BAD is read by the guard that sources this file, not here.
        # shellcheck disable=SC2034
        GIT_BAD="git option $w before the subcommand cannot be analysed"
        return 0
        ;;
      *)
        GIT_SUB=$w
        GIT_ARGS=("${W[@]:i+1}")
        return 0
        ;;
    esac
  done
}

# git_is_readonly: true when the parsed git command (GIT_SUB, GIT_ARGS) cannot
# change the repository, its index, its config or any file.
git_is_readonly() {
  local a has_list=0 positional=0
  case $GIT_SUB in
    status | log | diff | show | rev-parse | merge-base | rev-list | ls-files | ls-tree | cat-file | \
      range-diff | patch-id | describe | for-each-ref | blame | shortlog | show-ref | ls-remote | \
      name-rev | check-ignore | diff-tree | version)
      for a in "${GIT_ARGS[@]}"; do
        case $a in
          --output | --output=*) return 1 ;;
        esac
      done
      return 0
      ;;
    branch)
      for a in "${GIT_ARGS[@]}"; do
        case $a in
          --list | -l | --show-current) has_list=1 ;;
          -a | -r | -v | -vv | --all | --remotes | --verbose | --merged | --no-merged | \
            --contains | --no-contains | --points-at | --sort=* | --format=* | --color | --no-color) ;;
          -*) return 1 ;;
          *) positional=1 ;;
        esac
      done
      ((has_list == 1 || positional == 0))
      ;;
    worktree) [ "${GIT_ARGS[0]:-}" = list ] ;;
    *) return 1 ;;
  esac
}

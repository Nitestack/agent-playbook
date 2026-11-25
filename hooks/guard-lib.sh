# shellcheck shell=bash
# PARSE_ERR, CMDS, W and the GIT_* results are read by the guards that source this file.
# shellcheck disable=SC2034
# Shared helpers for the PreToolUse guards. Sourced by the guards, never run.
# Needs bash 4 or newer, jq, git and GNU coreutils (`realpath -e` and `-m`).
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

# thread_id: the identity of the current agent thread. PLAYBOOK_THREAD_ID wins;
# T3 Code sets T3CODE_THREAD_ID for every thread it runs, which is the fallback.
thread_id() {
  printf '%s' "${PLAYBOOK_THREAD_ID:-${T3CODE_THREAD_ID:-}}"
}

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

# tool_cwd: the directory a tool call runs in, or empty when the hook input does
# not say. Codex shell calls carry `workdir`; Claude Code passes the session `cwd`.
tool_cwd() {
  jq -r '.tool_input.workdir // .tool_input.cwd // .cwd // ""' <<<"$HOOK_INPUT"
}

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
# It honors quotes, escapes, separators (; & | newline and parentheses) and
# comments, which is enough to match on words without being fooled by quoted
# text. It is a guard, not a shell: it refuses what it cannot follow, and
# callers fail closed. Refused: command and process substitution ($( ),
# backticks, <( )), input redirection and here-documents, and every output
# redirection except `2>&1`-style duplication and `>/dev/null`.
#
# Result: CMDS holds one element per simple command, words joined by US.
# split_cmd <element> fills the array W with its words.

US=$'\x1f'
CMDS=()
W=()
PARSE_ERR=""

# The helpers below read and write the locals of parse_command (dynamic scoping).
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

parse_command() {
  local s=$1 n i=0 cur="" inword=0 words=() q="" c nxt rest redir_len
  local re_dup='^(>&[0-9]+)($|[[:space:];|&)])'
  local re_null='^(>>?[[:space:]]*/dev/null)($|[[:space:];|&)])'
  n=${#s}
  CMDS=()
  PARSE_ERR=""
  while ((i < n)); do
    c=${s:i:1}
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""; else cur+=$c; fi
    elif [ "$q" = '"' ]; then
      case $c in
        '"') q="" ;;
        '\')
          nxt=${s:i+1:1}
          case $nxt in
            '"' | '\' | '$' | '`')
              cur+=$nxt
              i=$((i + 1))
              ;;
            $'\n') i=$((i + 1)) ;;
            *) cur+=$c ;;
          esac
          ;;
        '`')
          PARSE_ERR="backtick substitution is not allowed here"
          return 1
          ;;
        '$')
          if [ "${s:i+1:1}" = "(" ]; then
            PARSE_ERR="command substitution is not allowed here"
            return 1
          fi
          cur+=$c
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
          nxt=${s:i+1:1}
          i=$((i + 1))
          if [ "$nxt" != $'\n' ]; then
            cur+=$nxt
            inword=1
          fi
          ;;
        '`')
          PARSE_ERR="backtick substitution is not allowed here"
          return 1
          ;;
        '$')
          if [ "${s:i+1:1}" = "(" ]; then
            PARSE_ERR="command substitution is not allowed here"
            return 1
          fi
          cur+=$c
          inword=1
          ;;
        ' ' | $'\t' | $'\r') _flush_word ;;
        $'\n' | ';' | '|' | '&' | '(' | ')')
          _flush_word
          _flush_cmd
          ;;
        '#')
          if ((inword)); then
            cur+=$c
          else
            while ((i + 1 < n)) && [ "${s:i+1:1}" != $'\n' ]; do i=$((i + 1)); done
          fi
          ;;
        '<')
          PARSE_ERR="input redirection, here-documents and process substitution are not allowed here"
          return 1
          ;;
        '>')
          rest=${s:i}
          if [[ $rest =~ $re_dup || $rest =~ $re_null ]]; then
            # Redirection to a descriptor or /dev/null; drop a glued `2` of `2>&1`.
            # Read BASH_REMATCH before any other [[ =~ ]] overwrites it.
            redir_len=${#BASH_REMATCH[1]}
            if [[ $cur =~ ^[0-9]+$ ]]; then
              cur=""
              inword=0
            fi
            i=$((i + redir_len - 1))
          else
            PARSE_ERR="output redirection is not allowed here"
            return 1
          fi
          ;;
        *)
          cur+=$c
          inword=1
          ;;
      esac
    fi
    i=$((i + 1))
  done
  if [ -n "$q" ]; then
    PARSE_ERR="unterminated quote"
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

# git_parse: analyze W (W[0] is git). Sets GIT_DIRS (the -C values in order),
# GIT_SUB, GIT_ARGS and GIT_BAD (non-empty when an option before the
# subcommand cannot be analyzed: `-c`, `--git-dir`, `--exec-path`, ...).
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
        GIT_BAD="git option $w before the subcommand cannot be analyzed"
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
# change the repository, its index, its config or any file, and runs no
# program named on the command line.
git_is_readonly() {
  local a has_list=0 positional=0 i n=${#GIT_ARGS[@]}
  case $GIT_SUB in
    status | log | diff | show | rev-parse | merge-base | rev-list | ls-files | ls-tree | cat-file | \
      range-diff | patch-id | describe | for-each-ref | blame | shortlog | show-ref | ls-remote | \
      name-rev | check-ignore | diff-tree | version)
      for a in "${GIT_ARGS[@]}"; do
        case $a in
          --output | --output=*) return 1 ;;
          # ls-remote runs the program these options name.
          --upload-pack | --upload-pack=* | --exec | --exec=*) return 1 ;;
          # External diff and text conversion drivers run programs too.
          --ext-diff | --textconv) return 1 ;;
        esac
      done
      return 0
      ;;
    branch)
      i=0
      while ((i < n)); do
        a=${GIT_ARGS[i]}
        case $a in
          --list | -l | --show-current) has_list=1 ;;
          --merged | --no-merged | --contains | --no-contains | --points-at)
            # These take an optional commit; consume it so it is not read as a new branch name.
            if ((i + 1 < n)) && [[ ${GIT_ARGS[i + 1]} != -* ]]; then i=$((i + 1)); fi
            has_list=1
            ;;
          --merged=* | --no-merged=* | --contains=* | --no-contains=* | --points-at=*) has_list=1 ;;
          -a | -r | -v | -vv | --all | --remotes | --verbose | --sort=* | --format=* | --color | --no-color) ;;
          -*) return 1 ;;
          *) positional=1 ;;
        esac
        i=$((i + 1))
      done
      ((has_list == 1 || positional == 0))
      ;;
    worktree) [ "${GIT_ARGS[0]:-}" = list ] ;;
    *) return 1 ;;
  esac
}

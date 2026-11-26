#!/usr/bin/env bash
# Skill lint. CI and local runs use this one script, so they cannot drift:
#
#   bash hooks/tests/lint-skills.sh
#
# Checks the skills/ tree:
#   1. Layout: only skills/<name>/SKILL.md and skills/<name>/references/**/*.md
#      are allowed. No scripts, shims, symlinks, binaries or stray directories.
#   2. Frontmatter: SKILL.md starts with a --- line and closes with another one,
#      has exactly one name: line equal to the directory name, and a non-empty
#      description:.
#   3. References: every references/...md path a SKILL.md names has no ..
#      component and exists as a regular file under that skill's directory.
#   4. Uniqueness: no two skills declare the same name.
#
# Needs bash 4 or newer, GNU coreutils, grep, sed and find. Exits 0 on pass and
# 1 on fail. Under GitHub Actions (GITHUB_ACTIONS=true) each failure is also
# printed as a ::error annotation.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
cd -- "$root" || exit 1

fail=0

# escape <text>: escape the characters GitHub Actions workflow commands reserve.
escape() {
  local s=$1
  s=${s//%/%25}
  s=${s//$'\r'/%0D}
  s=${s//$'\n'/%0A}
  printf '%s' "$s"
}

# report <file> <message>: record a failure and print it where a human or CI sees it.
report() {
  fail=1
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    local file
    file=$(escape "$1")
    file=${file//:/%3A}
    file=${file//,/%2C}
    printf '::error file=%s::%s\n' "$file" "$(escape "$2")" >&2
  else
    printf 'skill lint: %s: %s\n' "$1" "$2" >&2
  fi
}

if [ ! -d skills ]; then
  report skills "missing skills/ directory"
  exit 1
fi

# 1. Layout.
while IFS= read -r -d '' path; do
  if [ -L "$path" ]; then
    report "$path" "symlink in skills/"
  elif [ -d "$path" ]; then
    [[ $path =~ ^skills/[^/]+$ || $path =~ ^skills/[^/]+/references(/.+)?$ ]] ||
      report "$path" "unexpected directory in skills/"
  elif [ -f "$path" ]; then
    [[ $path =~ ^skills/[^/]+/SKILL\.md$ || $path =~ ^skills/[^/]+/references/.+\.md$ ]] ||
      report "$path" "only SKILL.md and references/**/*.md are allowed in skills/"
  else
    report "$path" "not a regular file in skills/"
  fi
done < <(find skills -mindepth 1 -print0 | sort -z)

# 2 to 4. One pass over each skill directory.
declare -A seen=()
count=0
while IFS= read -r -d '' dir; do
  base=${dir##*/}
  file="$dir/SKILL.md"
  count=$((count + 1))

  if [ ! -f "$file" ] || [ -L "$file" ]; then
    report "$dir" "missing regular SKILL.md"
    continue
  fi

  # Frontmatter must open on line 1 and close on a later --- line.
  if [ "$(sed -n '1p' "$file")" != "---" ]; then
    report "$file" "frontmatter must start with a --- line"
    continue
  fi
  close=$(sed -n '2,${/^---$/{=;q}}' "$file")
  if [ -z "$close" ]; then
    report "$file" "frontmatter is not closed by a --- line"
    continue
  fi
  front=""
  if [ "$close" -gt 2 ]; then
    front=$(sed -n "2,$((close - 1))p" "$file")
  fi

  # Exactly one top-level name: line, equal to the directory name.
  name_lines=$(grep -c '^name:' <<<"$front")
  if [ "$name_lines" -ne 1 ]; then
    report "$file" "frontmatter needs exactly one name: line, found $name_lines"
    continue
  fi
  name=$(sed -n 's/^name:[[:space:]]*//p' <<<"$front")
  name=${name%"${name##*[![:space:]]}"}
  if [ -z "$name" ]; then
    report "$file" "frontmatter name is empty"
    continue
  fi
  if [ "$name" != "$base" ]; then
    report "$file" "frontmatter name '$name' does not match directory '$base'"
  fi

  if ! grep -q '^description:[[:space:]]*[^[:space:]]' <<<"$front"; then
    report "$file" "frontmatter has no description"
  fi

  # Unique names across the set.
  if [ -n "${seen[$name]:-}" ]; then
    report "$file" "duplicate skill name '$name' (also in ${seen[$name]})"
  else
    seen[$name]=$dir
  fi

  # Every references/...md the skill names must stay inside it and exist.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      /*) report "$file" "reference $ref is absolute"; continue ;;
    esac
    case "/$ref/" in
      */../*) report "$file" "reference $ref has a .. component"; continue ;;
    esac
    if [ ! -f "$dir/$ref" ] || [ -L "$dir/$ref" ]; then
      report "$file" "names $ref, which is not a regular file under $dir/"
    fi
  done < <(grep -oE '[A-Za-z0-9._/-]*references/[A-Za-z0-9._/-]*\.md' "$file" | sort -u)
done < <(find skills -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'skill lint: ok (%d skills)\n' "$count"

#!/usr/bin/env bash
set -uo pipefail

# The `env` block in .claude/settings.json sets git's safe.bareRepository to
# `explicit` for every command an agent runs. Without it, a bare repository
# committed as ordinary files in a checked-out branch is picked up by the
# pre-approved `git log*` and `git show*` commands when the agent's working
# directory is inside it (`cd evil`, then `git show`). The bare repository's
# own config can name a program for git to run -- here diff.x.textconv, switched
# on for every path by info/attributes -- so the program starts with no
# permission prompt. The guard hook cannot see that config, so git itself has to
# refuse the repository.
#
# This test plants exactly that repository, shows the program runs when the
# settings env is absent (so the refusal below is real, not vacuous), and shows
# it is refused when the env is applied. The checkout's own repository (.git/,
# not bare) must keep working under the same env.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/.claude/settings.json"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

check() {
  # check <description> <condition-result> [detail...]
  local desc="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then
    printf 'ok - %s\n' "${desc}"
  else
    printf 'not ok - %s\n' "${desc}${*:+: $*}" >&2
    failures=$((failures + 1))
  fi
}

# git with no user or system config and no inherited GIT_* overrides.
clean_git() {
  env -i PATH="${PATH}" HOME="${WORK_DIR}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "$@"
}

# The same, plus the env block exactly as .claude/settings.json declares it.
agent_git() {
  local -a settings_env
  mapfile -t settings_env < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "${SETTINGS}")
  env -i PATH="${PATH}" HOME="${WORK_DIR}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "${settings_env[@]}" git "$@"
}

main() {
  local actual expected
  actual="$(jq -S -c '.env' "${SETTINGS}")"
  expected='{"GIT_CONFIG_COUNT":"1","GIT_CONFIG_KEY_0":"safe.bareRepository","GIT_CONFIG_VALUE_0":"explicit"}'
  [[ "${actual}" == "${expected}" ]]
  check "settings.json sets safe.bareRepository=explicit through GIT_CONFIG_* for agent commands" "$?" \
    "got ${actual}"

  # Plant a bare repository `evil/` holding one commit, inside a repository that
  # is then cloned, as a branch carrying it would be checked out.
  local marker="${WORK_DIR}/ran" src="${WORK_DIR}/src" evil="${WORK_DIR}/src/evil"
  local blob tree commit
  clean_git init -q "${src}"
  clean_git init -q --bare "${evil}"
  blob="$(printf 'hello\n' | clean_git -C "${evil}" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tfile.txt\n' "${blob}" | clean_git -C "${evil}" mktree)"
  commit="$(clean_git -C "${evil}" -c user.name=t -c user.email=t@t commit-tree -m planted "${tree}")"
  clean_git -C "${evil}" update-ref refs/heads/main "${commit}"
  clean_git -C "${evil}" symbolic-ref HEAD refs/heads/main
  printf '* diff=x\n' >"${evil}/info/attributes"
  clean_git -C "${evil}" config diff.x.textconv "touch '${marker}'; cat"
  clean_git -C "${src}" add evil
  clean_git -C "${src}" -c user.name=t -c user.email=t@t commit -qm planted-tree
  clean_git clone -q "${src}" "${WORK_DIR}/victim"
  local victim="${WORK_DIR}/victim"

  # Precondition: without the setting the planted program does run.
  local route
  for route in "show" "log -p -1"; do
    rm -f -- "${marker}"
    # shellcheck disable=SC2086 # ${route} is a word list on purpose
    (cd "${victim}/evil" && clean_git ${route} >/dev/null 2>&1)
    [[ -e "${marker}" ]]
    check "precondition: without safe.bareRepository, git ${route} inside the planted repository runs its program" "$?"
  done

  # With the settings env, both pre-approved history commands refuse it.
  local output
  for route in "show" "log -p -1"; do
    rm -f -- "${marker}"
    # shellcheck disable=SC2086 # ${route} is a word list on purpose
    output="$(cd "${victim}/evil" && agent_git ${route} 2>&1)"
    local status=$?
    [[ "${status}" -ne 0 && "${output}" == *safe.bareRepository* && ! -e "${marker}" ]]
    check "with the settings env, git ${route} inside the planted repository is refused and runs nothing" "$?" \
      "status ${status}, marker present: $([[ -e "${marker}" ]] && echo yes || echo no), output: ${output}"
  done

  # The checkout's own repository (.git/, not bare) still works.
  output="$(cd "${victim}" && agent_git log -1 --format=%s 2>&1)"
  [[ "${output}" == "planted-tree" ]]
  check "with the settings env, git log still works in the checkout's own repository" "$?" "got ${output}"
  (cd "${victim}" && agent_git status --short >/dev/null 2>&1)
  check "with the settings env, git status still works in the checkout's own repository" "$?"

  printf '\n1..%d\n' "${tests_run}"
  if (( failures > 0 )); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

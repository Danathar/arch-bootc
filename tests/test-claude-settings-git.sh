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
#
# `explicit` refuses only a repository git discovers. Naming the directory --
# `--git-dir=evil`, or `--bare` from inside it, which is `--git-dir=.` -- is
# what makes it explicit, so those spellings still run the planted program
# with the env applied. The guard hook, .claude/hooks/gate-git-diff.sh, is what
# refuses them; the last group below shows both halves against the same
# planted repository, so neither assertion is vacuous.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/.claude/settings.json"
GATE="${REPO_ROOT}/.claude/hooks/gate-git-diff.sh"

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

# A bash command string run under the same environment, as the Bash tool runs one.
agent_shell() {
  local -a settings_env
  mapfile -t settings_env < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "${SETTINGS}")
  env -i PATH="${PATH}" HOME="${WORK_DIR}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "${settings_env[@]}" bash -c "$1"
}

main() {
  local actual expected
  actual="$(jq -S -c '.env' "${SETTINGS}")"
  expected='{"GIT_CONFIG_COUNT":"1","GIT_CONFIG_KEY_0":"safe.bareRepository","GIT_CONFIG_VALUE_0":"explicit"}'
  local ok=0
  [[ "${actual}" == "${expected}" ]] || ok=1
  check "settings.json sets safe.bareRepository=explicit through GIT_CONFIG_* for agent commands" "${ok}" \
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
    ok=0
    [[ -e "${marker}" ]] || ok=1
    check "precondition: without safe.bareRepository, git ${route} inside the planted repository runs its program" "${ok}"
  done

  # With the settings env, both pre-approved history commands refuse it.
  local output
  for route in "show" "log -p -1"; do
    rm -f -- "${marker}"
    # shellcheck disable=SC2086 # ${route} is a word list on purpose
    output="$(cd "${victim}/evil" && agent_git ${route} 2>&1)"
    local status=$?
    ok=0
    [[ "${status}" -ne 0 && "${output}" == *safe.bareRepository* && ! -e "${marker}" ]] || ok=1
    check "with the settings env, git ${route} inside the planted repository is refused and runs nothing" "${ok}" \
      "status ${status}, marker present: $([[ -e "${marker}" ]] && echo yes || echo no), output: ${output}"
  done

  # The spellings the setting allows reach the planted program, and the guard
  # hook refuses each of them.
  local spec dir args gate_err gate_status
  for spec in "victim|--git-dir=evil log -p -1" "victim|--git-dir evil show" \
    "victim/evil|--bare log -p -1"; do
    dir="${spec%%|*}"
    args="${spec#*|}"
    rm -f -- "${marker}"
    # shellcheck disable=SC2086 # ${args} is a word list on purpose
    (cd "${WORK_DIR}/${dir}" && agent_git ${args} >/dev/null 2>&1)
    ok=0
    [[ -e "${marker}" ]] || ok=1
    check "with the settings env, git ${args} still runs the planted program (so the hook refusal below is needed)" "${ok}"
    gate_err="$(jq -nc --arg c "git ${args}" '{tool_name: "Bash", tool_input: {command: $c}}' |
      CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash "${GATE}" 2>&1 >/dev/null)"
    gate_status=$?
    ok=0
    [[ "${gate_status}" -eq 2 && "${gate_err}" == *"git global option"* ]] || ok=1
    check "the guard hook refuses git ${args}" "${ok}" "exit ${gate_status}, stderr: ${gate_err}"
  done

  # A statement earlier in the same command string can take the settings env
  # away from the git after it, or point git at another global config. Each
  # spelling runs the planted program for real, and the guard hook refuses it.
  local cmd
  for cmd in "GIT_CONFIG_COUNT=0; git log -p -1" "GIT_CONFIG_VALUE_0=all; git log -p -1" \
    "unset GIT_CONFIG_COUNT; git log -p -1" "export -n GIT_CONFIG_COUNT; git log -p -1" \
    "exec -c git log -p -1" "read -r GIT_CONFIG_VALUE_0 <<< all; git log -p -1"; do
    rm -f -- "${marker}"
    (cd "${victim}/evil" && agent_shell "${cmd}" >/dev/null 2>&1)
    ok=0
    [[ -e "${marker}" ]] || ok=1
    check "with the settings env, '${cmd}' still runs the planted program (so the hook refusal below is needed)" "${ok}"
    gate_err="$(jq -nc --arg c "${cmd}" '{tool_name: "Bash", tool_input: {command: $c}}' |
      CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash "${GATE}" 2>&1 >/dev/null)"
    gate_status=$?
    ok=0
    [[ "${gate_status}" -eq 2 && "${gate_err}" == *"settings environment"* ]] || ok=1
    check "the guard hook refuses '${cmd}'" "${ok}" "exit ${gate_status}, stderr: ${gate_err}"
  done

  # The checkout's own repository (.git/, not bare) still works.
  output="$(cd "${victim}" && agent_git log -1 --format=%s 2>&1)"
  ok=0
  [[ "${output}" == "planted-tree" ]] || ok=1
  check "with the settings env, git log still works in the checkout's own repository" "${ok}" "got ${output}"
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

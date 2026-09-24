#!/usr/bin/env bash
set -uo pipefail

# Tests for the ownership guard in system_files/etc/profile.d/homebrew.sh and
# system_files/etc/fish/conf.d/homebrew.fish.
#
# Both files are sourced into every login shell, root's included, and both end
# by running a binary out of a prefix that UID 1000 owns and eval'ing what it
# prints. The guard in front of that is the only thing standing between one
# unprivileged account and code execution as everyone else, so it is worth
# executing rather than reading.
#
# The trust decision is extracted from each shipped file by name --
# `__arch_bootc_brew_trusted` -- and run. Nothing here is a copy of the guard:
# a renamed or deleted function fails the extraction loudly instead of leaving
# this file asserting nothing about a guard that is no longer there.
#
# Two groups, because two different things need saying.
#
# The first uses real files under a temporary directory and no stubs at all.
# It answers "does this work on a prefix that actually exists" -- including the
# case the fix is most likely to break, since a stock Homebrew prefix ships
# bin/brew as a symlink into ../Homebrew/bin/brew and a guard that refused
# symlinks outright would disable Homebrew rather than protect it.
#
# The second stubs `stat` and `id`, because the interesting cases are about
# uids this test cannot create. "The caller is root and bin/brew is owned by
# UID 1000" is the whole vulnerability (#205) and an unprivileged test host
# cannot produce it: it cannot make a file owned by anyone else, and it cannot
# become root. The stubs are how the test says which uid owns what and who is
# asking, the same way tests/test-prune-esp.sh stubs findmnt and lsblk so the
# mount table the script sees is entirely written by the test. The stub `stat`
# also records its argv, so the two properties that constitute the fix -- the
# guard asks about the link itself, and never asks `stat` to dereference --
# are asserted rather than assumed.
#
# No root, no network, no container runtime. The fish group needs `fish` on
# PATH and reports SKIP without it; CI installs it (see .github/workflows/
# build.yml), so there a skip means the fish half stopped being covered.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOMEBREW_SH="${REPO_ROOT}/system_files/etc/profile.d/homebrew.sh"
HOMEBREW_FISH="${REPO_ROOT}/system_files/etc/fish/conf.d/homebrew.fish"

# The one name both files agree on. Extraction is by this name, so it is also
# the thing that fails loudly when either file stops defining it.
GUARD_FN="__arch_bootc_brew_trusted"

failures=0
tests_run=0
skipped=0

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
WORK_DIR="$(mktemp -d)"
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$*"
}

skip() {
  local desc="$1" reason="$2"
  tests_run=$((tests_run + 1))
  skipped=$((skipped + 1))
  printf 'ok - %s # SKIP %s\n' "${desc}" "${reason}"
}

check() {
  local desc="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then
    pass "${desc}"
  else
    fail "${desc}${*:+: $*}"
  fi
}

assert_trusted() {
  local desc="$1" status="$2"
  if [[ "${status}" == "0" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "the guard refused a prefix it should trust (exit ${status})"
  fi
}

assert_refused() {
  local desc="$1" status="$2"
  if [[ "${status}" != "0" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "the guard trusted a prefix it should refuse"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output did not contain '${needle}'"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output unexpectedly contained '${needle}'"
  fi
}

assert_equals() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "expected '${expected}', got '${actual}'"
  fi
}

# --- extracting the shipped guard -------------------------------------------

# The POSIX-sh function, from its opening line to the closing brace in column
# zero. Both anchors are the file's own text; neither is a line number, so a
# comment added above the function does not move the extraction.
extract_sh_guard() {
  local body
  body="$(sed -n "/^${GUARD_FN}() {\$/,/^}\$/p" "${HOMEBREW_SH}")"
  if [[ -z "${body}" ]]; then
    printf 'error: %s defines no %s(); this test executes that function and cannot find it\n' \
      "${HOMEBREW_SH#"${REPO_ROOT}/"}" "${GUARD_FN}" >&2
    exit 1
  fi
  printf '%s\n' "${body}"
}

extract_fish_guard() {
  local body
  body="$(sed -n "/^function ${GUARD_FN} /,/^end\$/p" "${HOMEBREW_FISH}")"
  if [[ -z "${body}" ]]; then
    printf 'error: %s defines no "function %s"; this test executes that function and cannot find it\n' \
      "${HOMEBREW_FISH#"${REPO_ROOT}/"}" "${GUARD_FN}" >&2
    exit 1
  fi
  printf '%s\n' "${body}"
}

# --- fixtures ----------------------------------------------------------------

# A prefix laid out the way brew-setup.service leaves one. `layout` picks which
# shape bin/brew takes, because the shape is the thing under test.
#
#   regular   bin/brew is an ordinary executable
#   symlink   bin/brew -> ../Homebrew/bin/brew, which is how a stock Homebrew
#             prefix is actually laid out
#   elsewhere bin/brew -> a file outside the prefix entirely, which is the
#             shape of the attack in #205
#   dangling  bin/brew -> nothing
#   missing   no bin/brew at all
#   plain     bin/brew exists but is not executable
make_prefix() {
  local base="$1" layout="$2" outside="${3:-}"
  local bin="${base}/linuxbrew/.linuxbrew/bin"
  mkdir -p "${bin}"
  case "${layout}" in
    regular)
      printf '#!/bin/sh\nprintf "%%s\\n" "export FROM_BREW=1"\n' >"${bin}/brew"
      chmod 755 "${bin}/brew"
      ;;
    symlink)
      mkdir -p "${base}/linuxbrew/.linuxbrew/Homebrew/bin"
      printf '#!/bin/sh\nprintf "%%s\\n" "export FROM_BREW=1"\n' \
        >"${base}/linuxbrew/.linuxbrew/Homebrew/bin/brew"
      chmod 755 "${base}/linuxbrew/.linuxbrew/Homebrew/bin/brew"
      ln -s ../Homebrew/bin/brew "${bin}/brew"
      ;;
    elsewhere)
      ln -s "${outside}" "${bin}/brew"
      ;;
    dangling)
      ln -s "${base}/nothing-here" "${bin}/brew"
      ;;
    missing) ;;
    plain)
      : >"${bin}/brew"
      chmod 644 "${bin}/brew"
      ;;
    *)
      printf 'error: unknown prefix layout %s\n' "${layout}" >&2
      exit 1
      ;;
  esac
}

# Run the shipped POSIX-sh guard against `base`, with no stubs: real files,
# real stat, real id, the real caller. Prints the guard's exit status.
run_sh_guard() {
  local base="$1"
  "${BASH}" --noprofile --norc -c "$(extract_sh_guard)
${GUARD_FN} \"\$1\" >/dev/null 2>&1
printf '%s' \"\$?\"" bash "${base}"
}

# --- ownership stubs ---------------------------------------------------------

# A `stat` that answers from a table the test writes, and records what it was
# asked. It accepts only the exact invocation the guard makes: a rewrite that
# started passing `-L` would be answered with an error here rather than
# silently getting the dereferenced owner, which is the whole bug of #205.
# shellcheck disable=SC2016 # a script for /bin/sh to expand, not this shell
STAT_STUB='#!/bin/sh
printf "%s\n" "$*" >>"${STUB_STAT_CALLS}"
if [ "$1" != "-c" ] || [ "$2" != "%u" ] || [ "$3" != "--" ]; then
  printf "stub stat: unsupported invocation: %s\n" "$*" >&2
  exit 64
fi
shift 3
rc=0
for path in "$@"; do
  uid=""
  while read -r owner_path owner_uid; do
    [ "${owner_path}" = "${path}" ] || continue
    uid="${owner_uid}"
  done <"${STUB_STAT_OWNERS}"
  if [ -z "${uid}" ]; then
    printf "stub stat: no owner recorded for %s\n" "${path}" >&2
    rc=1
    continue
  fi
  printf "%s\n" "${uid}"
done
exit "${rc}"
'

# shellcheck disable=SC2016 # a script for /bin/sh to expand, not this shell
ID_STUB='#!/bin/sh
if [ "$1" != "-u" ]; then
  printf "stub id: unsupported invocation: %s\n" "$*" >&2
  exit 64
fi
printf "%s\n" "${STUB_ID_UID}"
'

# A PATH holding nothing but the stubs and the real `readlink` the guard needs.
# Anything else the guard reached for would fail to be found, rather than
# quietly getting the host's answer.
make_stub_bin() {
  local bindir="$1"
  mkdir -p "${bindir}"
  printf '%s' "${STAT_STUB}" >"${bindir}/stat"
  printf '%s' "${ID_STUB}" >"${bindir}/id"
  chmod 755 "${bindir}/stat" "${bindir}/id"
  local real_readlink
  real_readlink="$(command -v readlink)" || {
    printf 'error: no readlink on PATH; the guard needs it\n' >&2
    exit 1
  }
  ln -s "${real_readlink}" "${bindir}/readlink"
}

# Record `path uid` for every entry the guard walks. Written by the caller a
# line at a time; later records override earlier ones so a case can make one
# component untrusted after declaring the whole chain trusted.
owners_file() {
  printf '%s\n' "${WORK_DIR}/owners.$1"
}

# Run the shipped guard with ownership answered by the stubs. Prints the exit
# status; the stub's call log is left in ${WORK_DIR}/stat-calls.<tag>.
run_sh_guard_stubbed() {
  local base="$1" tag="$2" caller_uid="$3"
  local bindir="${WORK_DIR}/bin.${tag}"
  make_stub_bin "${bindir}"
  : >"${WORK_DIR}/stat-calls.${tag}"
  env -i \
    PATH="${bindir}" \
    STUB_STAT_OWNERS="$(owners_file "${tag}")" \
    STUB_STAT_CALLS="${WORK_DIR}/stat-calls.${tag}" \
    STUB_ID_UID="${caller_uid}" \
    "${BASH}" --noprofile --norc -c "$(extract_sh_guard)
${GUARD_FN} \"\$1\" >/dev/null 2>&1
printf '%s' \"\$?\"" bash "${base}"
}

# The five paths the guard is specified to ask about, in prefix order.
prefix_paths() {
  local base="$1"
  printf '%s\n' \
    "${base}/linuxbrew" \
    "${base}/linuxbrew/.linuxbrew" \
    "${base}/linuxbrew/.linuxbrew/bin" \
    "${base}/linuxbrew/.linuxbrew/bin/brew"
}

# Print each absolute path component from the filesystem root down. The guard
# resolves in exactly this direction, checking the entry before following a
# symlink, so stub tables must account for ancestors as well as the final file.
path_components() {
  local rest="${1#/}" path="" part
  while [[ -n "${rest}" ]]; do
    if [[ "${rest}" == */* ]]; then
      part="${rest%%/*}"
      rest="${rest#*/}"
    else
      part="${rest}"
      rest=""
    fi
    [[ -n "${part}" ]] || continue
    path="${path}/${part}"
    printf '%s\n' "${path}"
  done
}

# Entries reached first through the documented brew path, then through the
# symlink target when a case has one. Duplicates are harmless to the stub.
walked_paths() {
  local base="$1" target="${2:-}"
  path_components "${base}/linuxbrew/.linuxbrew/bin/brew"
  [[ -n "${target}" ]] && path_components "${target}"
}

# --- group 1: real files, no stubs -------------------------------------------

test_a_prefix_this_user_owns_is_trusted() {
  local base="${WORK_DIR}/own-regular"
  make_prefix "${base}" regular
  assert_trusted "a prefix owned by this user, with a regular bin/brew, is trusted" \
    "$(run_sh_guard "${base}")"
}

test_a_symlinked_entry_point_is_not_rejected_out_of_hand() {
  # The regression this fix had to avoid. Upstream Homebrew ships
  # bin/brew as a link into ../Homebrew/bin/brew, so a guard written as
  # "refuse every symlink" -- the obvious reading of #205 -- would leave every
  # user of a stock prefix without brew, which is a worse outcome than the bug.
  local base="${WORK_DIR}/own-symlink"
  make_prefix "${base}" symlink
  assert_trusted "bin/brew may be a symlink when the link and its target are both trusted" \
    "$(run_sh_guard "${base}")"
}

test_a_prefix_that_does_not_exist_is_refused() {
  assert_refused "a machine that never ran brew-setup.service is refused" \
    "$(run_sh_guard "${WORK_DIR}/no-such-prefix")"
}

test_a_missing_entry_point_is_refused() {
  local base="${WORK_DIR}/no-brew"
  make_prefix "${base}" missing
  assert_refused "a prefix with no bin/brew is refused" "$(run_sh_guard "${base}")"
}

test_a_non_executable_entry_point_is_refused() {
  local base="${WORK_DIR}/not-exec"
  make_prefix "${base}" plain
  assert_refused "a bin/brew that is not executable is refused" "$(run_sh_guard "${base}")"
}

test_a_dangling_entry_point_is_refused() {
  local base="${WORK_DIR}/dangling"
  make_prefix "${base}" dangling
  assert_refused "a bin/brew pointing at nothing is refused" "$(run_sh_guard "${base}")"
}

# --- group 2: stubbed ownership ----------------------------------------------

test_root_refuses_a_link_owned_by_the_prefix_owner() {
  # This is #205. UID 1000 owns the prefix, so it replaces bin/brew with a link
  # to a root-owned executable elsewhere on the system. Root then logs in.
  #
  # The guard this replaced asked `[ -O bin/brew ]`, and `-O` dereferences: it
  # saw a root-owned target and a root caller, said yes, and root's login shell
  # ran the attacker's choice of binary and eval'd its output. The link's own
  # owner -- the only thing the attacker actually controls, and the only thing
  # that identifies them -- was never consulted.
  local base="${WORK_DIR}/attack"
  local outside="${WORK_DIR}/attack-target"
  printf '#!/bin/sh\nprintf "%%s\\n" "export PWNED=1"\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"

  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 1000\n' "${path}"; done
    printf '%s 0\n' "${outside}"
  } >"$(owners_file attack)"

  assert_refused "root refuses a bin/brew link owned by the prefix owner, whatever it points at" \
    "$(run_sh_guard_stubbed "${base}" attack 0)"
}

test_the_guard_asks_about_the_link_itself_and_never_dereferences() {
  # The two properties that constitute the fix, read off the stub's call log.
  # A guard that only ever asked about the resolved target would be back to
  # answering the question #205 showed to be the wrong one, and one that passed
  # `-L` would be asking `stat` to dereference on its behalf.
  local base="${WORK_DIR}/argv"
  local outside="${WORK_DIR}/argv-target"
  printf '#!/bin/sh\nexit 0\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"

  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 4242\n' "${path}"; done
  } >"$(owners_file argv)"

  run_sh_guard_stubbed "${base}" argv 4242 >/dev/null
  local calls
  calls="$(cat "${WORK_DIR}/stat-calls.argv")"

  assert_contains "the guard asks stat about bin/brew itself" \
    "${calls}" "${base}/linuxbrew/.linuxbrew/bin/brew"
  assert_contains "the guard asks stat about what bin/brew resolves to" \
    "${calls}" "${outside}"
  assert_contains "the guard asks stat about the prefix's bin directory" \
    "${calls}" "${base}/linuxbrew/.linuxbrew/bin"
  assert_contains "the guard asks stat about the resolved target's parent" \
    "${calls}" "${outside%/*}"
  assert_not_contains "the guard never asks stat to dereference" "${calls}" "-L"
  assert_not_contains "the guard never asks stat to dereference" \
    "${calls}" "--dereference"
}

test_root_refuses_a_root_owned_file_in_a_directory_someone_else_owns() {
  # The other half of the same mistake. A file root owns today, sitting in a
  # directory UID 1000 owns, is a file UID 1000 can replace at any moment --
  # checking only the entry point would trust it in the window before they do.
  local base="${WORK_DIR}/dir-owner"
  make_prefix "${base}" regular

  {
    walked_paths "${base}" | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${base}/linuxbrew/.linuxbrew/bin"
  } >"$(owners_file dir-owner)"

  assert_refused "root refuses a root-owned brew inside a bin directory UID 1000 owns" \
    "$(run_sh_guard_stubbed "${base}" dir-owner 0)"
}

# Every directory root's, the target root's, and only bin/brew itself owned by
# UID 1000. No real filesystem reaches that state -- UID 1000 cannot write into
# a root-owned bin -- and that is the point: it leaves exactly one thing under
# test, so this case fails if and only if the guard stops consulting the entry
# point's own owner. Which is the one thing the version it replaced never did.
write_link_owner_case() {
  local base="$1" tag="$2" outside="$3"
  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${base}/linuxbrew/.linuxbrew/bin/brew"
  } >"$(owners_file "${tag}")"
}

test_root_consults_the_entry_points_own_owner() {
  local base="${WORK_DIR}/link-owner"
  local outside="${WORK_DIR}/link-owner-target"
  printf '#!/bin/sh\nexit 0\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"
  write_link_owner_case "${base}" link-owner "${outside}"
  assert_refused "root refuses a bin/brew whose own owner is UID 1000, root-owned target and all" \
    "$(run_sh_guard_stubbed "${base}" link-owner 0)"
}

test_root_refuses_a_trusted_link_into_an_untrusted_file() {
  # The link is root's, so root aimed it -- but it lands on a file UID 1000
  # owns and can rewrite at will. Checking only the link would trust the one
  # thing in the chain the attacker does not control.
  local base="${WORK_DIR}/trusted-link"
  local outside="${WORK_DIR}/trusted-link-target"
  printf '#!/bin/sh\nexit 0\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"

  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${outside}"
  } >"$(owners_file trusted-link)"

  assert_refused "root refuses a root-owned link that lands on a file UID 1000 owns" \
    "$(run_sh_guard_stubbed "${base}" trusted-link 0)"
}

test_root_refuses_an_untrusted_directory_in_the_resolved_chain() {
  # The review regression: checking the link and final file is insufficient
  # when another account owns a directory used to reach that file. They can
  # replace it after resolution and before the documented link is invoked.
  local base="${WORK_DIR}/resolved-dir"
  local outside_dir="${WORK_DIR}/resolved-dir-target"
  local outside="${outside_dir}/brew"
  mkdir -p "${outside_dir}"
  printf '#!/bin/sh\nexit 0\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"
  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${outside_dir}"
  } >"$(owners_file resolved-dir)"

  assert_refused "root refuses a trusted link through a directory UID 1000 owns" \
    "$(run_sh_guard_stubbed "${base}" resolved-dir 0)"
}

test_root_refuses_an_untrusted_homebrew_directory() {
  # Exercise the relative link shape Homebrew actually ships, so a walk that
  # checks external absolute targets but skips ../Homebrew/bin is caught too.
  local base="${WORK_DIR}/homebrew-dir"
  local target="${base}/linuxbrew/.linuxbrew/Homebrew/bin/brew"
  make_prefix "${base}" symlink
  {
    walked_paths "${base}" "${target}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${target%/*}"
  } >"$(owners_file homebrew-dir)"

  assert_refused "root refuses a stock brew link whose Homebrew/bin is owned by UID 1000" \
    "$(run_sh_guard_stubbed "${base}" homebrew-dir 0)"
}

test_root_refuses_a_prefix_directory_someone_else_owns() {
  # Every directory on the way in, not just the one holding brew. A prefix root
  # is a directory whose whole subtree its owner can rearrange, so a single
  # untrusted component anywhere makes the rest of the chain theirs to choose.
  local base="${WORK_DIR}/outer-dir"
  make_prefix "${base}" regular
  local n=0
  local untrusted
  while read -r untrusted; do
    n=$((n + 1))
    local tag="outer-dir-${n}"
    local path
    {
      walked_paths "${base}" | while read -r path; do printf '%s 0\n' "${path}"; done
      printf '%s 1000\n' "${untrusted}"
    } >"$(owners_file "${tag}")"
    assert_refused "root refuses a prefix whose ${untrusted#"${base}/"} is owned by UID 1000" \
      "$(run_sh_guard_stubbed "${base}" "${tag}" 0)"
  done < <(prefix_paths "${base}")
}

test_root_trusts_a_wholly_root_owned_prefix() {
  local base="${WORK_DIR}/root-prefix"
  make_prefix "${base}" regular
  walked_paths "${base}" | while read -r path; do printf '%s 0\n' "${path}"; done \
    >"$(owners_file root-prefix)"
  assert_trusted "root trusts a prefix owned entirely by root" \
    "$(run_sh_guard_stubbed "${base}" root-prefix 0)"
}

test_a_user_trusts_a_root_owned_prefix() {
  # A genuine system-wide install is still everyone's, which is what
  # docs/first-boot.md promises.
  local base="${WORK_DIR}/root-prefix-user"
  make_prefix "${base}" regular
  walked_paths "${base}" | while read -r path; do printf '%s 0\n' "${path}"; done \
    >"$(owners_file root-prefix-user)"
  assert_trusted "an ordinary user trusts a prefix owned entirely by root" \
    "$(run_sh_guard_stubbed "${base}" root-prefix-user 1000)"
}

test_a_user_refuses_another_users_prefix() {
  # The case #204 existed for, now checked from the other side: the second
  # human on the machine does not inherit the first one's brew.
  local base="${WORK_DIR}/other-user"
  make_prefix "${base}" regular
  walked_paths "${base}" | while read -r path; do printf '%s 1000\n' "${path}"; done \
    >"$(owners_file other-user)"
  assert_refused "UID 1001 refuses a prefix owned by UID 1000" \
    "$(run_sh_guard_stubbed "${base}" other-user 1001)"
}

test_the_prefix_owner_trusts_their_own_prefix() {
  local base="${WORK_DIR}/self"
  make_prefix "${base}" regular
  walked_paths "${base}" | while read -r path; do printf '%s 1000\n' "${path}"; done \
    >"$(owners_file self)"
  assert_trusted "UID 1000 trusts the prefix brew-setup.service extracted for it" \
    "$(run_sh_guard_stubbed "${base}" self 1000)"
}

# --- group 3: the fish variant -----------------------------------------------

# The same guard, in the other language. conf.d/homebrew.fish is sourced by
# every fish session and ends in `| source`, so it is the same exposure and
# needs the same evidence -- a fix applied to one file and not the other is
# exactly the shape of bug that reaches production.
run_fish_guard() {
  local base="$1"
  local script="${WORK_DIR}/fish-guard.fish"
  {
    extract_fish_guard
    # shellcheck disable=SC2016 # $argv and $status are fish's, expanded by fish
    printf '%s $argv[1] >/dev/null 2>&1\nprintf "%%s" $status\n' "${GUARD_FN}"
  } >"${script}"
  # fish writes history and universal variables under $HOME; point it at the
  # work directory so the test neither reads nor writes the runner's.
  env HOME="${WORK_DIR}" XDG_CONFIG_HOME="${WORK_DIR}/config" \
    XDG_DATA_HOME="${WORK_DIR}/data" \
    fish --no-config "${script}" "${base}" 2>/dev/null
}

run_fish_guard_stubbed() {
  local base="$1" tag="$2" caller_uid="$3"
  local bindir="${WORK_DIR}/bin.${tag}"
  make_stub_bin "${bindir}"
  ln -sf "$(command -v fish)" "${bindir}/fish"
  : >"${WORK_DIR}/stat-calls.${tag}"
  local script="${WORK_DIR}/fish-guard-${tag}.fish"
  {
    extract_fish_guard
    # shellcheck disable=SC2016 # $argv and $status are fish's, expanded by fish
    printf '%s $argv[1] >/dev/null 2>&1\nprintf "%%s" $status\n' "${GUARD_FN}"
  } >"${script}"
  env -i \
    PATH="${bindir}" \
    HOME="${WORK_DIR}" \
    XDG_CONFIG_HOME="${WORK_DIR}/config" \
    XDG_DATA_HOME="${WORK_DIR}/data" \
    STUB_STAT_OWNERS="$(owners_file "${tag}")" \
    STUB_STAT_CALLS="${WORK_DIR}/stat-calls.${tag}" \
    STUB_ID_UID="${caller_uid}" \
    "${bindir}/fish" --no-config "${script}" "${base}" 2>/dev/null
}

test_fish_guard_matches_the_posix_one() {
  if ! command -v fish >/dev/null 2>&1; then
    skip "the fish guard trusts a prefix this user owns" "fish is not installed"
    skip "the fish guard accepts a symlinked bin/brew" "fish is not installed"
    skip "the fish guard refuses a missing prefix" "fish is not installed"
    skip "root refuses a bin/brew link owned by the prefix owner (fish)" \
      "fish is not installed"
    skip "root refuses a bin/brew whose own owner is UID 1000 (fish)" \
      "fish is not installed"
    skip "root refuses a link through a directory UID 1000 owns (fish)" \
      "fish is not installed"
    skip "root refuses a stock link through Homebrew/bin owned by UID 1000 (fish)" \
      "fish is not installed"
    skip "UID 1001 refuses a prefix owned by UID 1000 (fish)" "fish is not installed"
    return
  fi

  local own="${WORK_DIR}/fish-own"
  make_prefix "${own}" regular
  assert_trusted "the fish guard trusts a prefix this user owns" "$(run_fish_guard "${own}")"

  local linked="${WORK_DIR}/fish-symlink"
  make_prefix "${linked}" symlink
  assert_trusted "the fish guard accepts a symlinked bin/brew" "$(run_fish_guard "${linked}")"

  assert_refused "the fish guard refuses a missing prefix" \
    "$(run_fish_guard "${WORK_DIR}/fish-no-such-prefix")"

  local base="${WORK_DIR}/fish-attack"
  local outside="${WORK_DIR}/fish-attack-target"
  printf '#!/bin/sh\nexit 0\n' >"${outside}"
  chmod 755 "${outside}"
  make_prefix "${base}" elsewhere "${outside}"
  {
    walked_paths "${base}" "${outside}" \
      | while read -r path; do printf '%s 1000\n' "${path}"; done
    printf '%s 0\n' "${outside}"
  } >"$(owners_file fish-attack)"
  assert_refused "root refuses a bin/brew link owned by the prefix owner (fish)" \
    "$(run_fish_guard_stubbed "${base}" fish-attack 0)"

  local owner="${WORK_DIR}/fish-link-owner"
  local owner_target="${WORK_DIR}/fish-link-owner-target"
  printf '#!/bin/sh\nexit 0\n' >"${owner_target}"
  chmod 755 "${owner_target}"
  make_prefix "${owner}" elsewhere "${owner_target}"
  write_link_owner_case "${owner}" fish-link-owner "${owner_target}"
  assert_refused "root refuses a bin/brew whose own owner is UID 1000 (fish)" \
    "$(run_fish_guard_stubbed "${owner}" fish-link-owner 0)"

  local resolved="${WORK_DIR}/fish-resolved-dir"
  local resolved_target_dir="${WORK_DIR}/fish-resolved-dir-target"
  local resolved_target="${resolved_target_dir}/brew"
  mkdir -p "${resolved_target_dir}"
  printf '#!/bin/sh\nexit 0\n' >"${resolved_target}"
  chmod 755 "${resolved_target}"
  make_prefix "${resolved}" elsewhere "${resolved_target}"
  {
    walked_paths "${resolved}" "${resolved_target}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${resolved_target_dir}"
  } >"$(owners_file fish-resolved-dir)"
  assert_refused "root refuses a link through a directory UID 1000 owns (fish)" \
    "$(run_fish_guard_stubbed "${resolved}" fish-resolved-dir 0)"

  local stock="${WORK_DIR}/fish-homebrew-dir"
  local stock_target="${stock}/linuxbrew/.linuxbrew/Homebrew/bin/brew"
  make_prefix "${stock}" symlink
  {
    walked_paths "${stock}" "${stock_target}" \
      | while read -r path; do printf '%s 0\n' "${path}"; done
    printf '%s 1000\n' "${stock_target%/*}"
  } >"$(owners_file fish-homebrew-dir)"
  assert_refused "root refuses a stock link through Homebrew/bin owned by UID 1000 (fish)" \
    "$(run_fish_guard_stubbed "${stock}" fish-homebrew-dir 0)"

  local other="${WORK_DIR}/fish-other-user"
  make_prefix "${other}" regular
  walked_paths "${other}" | while read -r path; do printf '%s 1000\n' "${path}"; done \
    >"$(owners_file fish-other)"
  assert_refused "UID 1001 refuses a prefix owned by UID 1000 (fish)" \
    "$(run_fish_guard_stubbed "${other}" fish-other 1001)"
}

# --- group 4: the two files have to stay in step -----------------------------

test_neither_file_uses_a_dereferencing_ownership_test() {
  # `-O` is the operator this fix removed. It is not wrong everywhere -- on a
  # path with no links left it is exactly "owned by the caller" -- but it is
  # the one that dereferences, and reintroducing it in front of an
  # attacker-controlled path is how #205 happened. The tests above say what the
  # guard decides; this says the guard is not asking the old question again.
  local sh_body fish_body
  sh_body="$(extract_sh_guard)"
  fish_body="$(extract_fish_guard)"
  assert_not_contains "the POSIX guard uses no dereferencing ownership test" "${sh_body}" "-O "
  assert_not_contains "the fish guard uses no dereferencing ownership test" "${fish_body}" "-O "
}

test_both_files_guard_the_same_prefixes() {
  # A fix applied to one file and not the other leaves the hole open for
  # whoever uses the other shell. Both files must run brew only under the
  # guard, for both prefixes.
  local sh_text fish_text
  sh_text="$(cat "${HOMEBREW_SH}")"
  fish_text="$(cat "${HOMEBREW_FISH}")"
  for base in /var/home /home; do
    assert_contains "homebrew.sh guards ${base}" "${sh_text}" "${GUARD_FN} ${base}"
    assert_contains "homebrew.fish guards ${base}" "${fish_text}" "${GUARD_FN} ${base}"
  done
}

test_neither_file_leaves_its_helper_defined() {
  # Both are sourced into the user's own shell, not run as programs, so a
  # helper left behind is a name every login shell on the machine now carries.
  assert_contains "homebrew.sh unsets its helper" \
    "$(cat "${HOMEBREW_SH}")" "unset -f ${GUARD_FN}"
  assert_contains "homebrew.fish erases its helper" \
    "$(cat "${HOMEBREW_FISH}")" "functions --erase ${GUARD_FN}"
}

# --- group 5: the CI steps that keep the groups above from skipping ----------
#
# Everything above answers "does the guard hold". This group answers the
# question the file header already raises and nothing checked: does CI still
# hand this suite the environment its cases ask for? Two steps of build.yml's
# `test` job exist for no other reason -- `Install fish`, without which every
# fish case above reports SKIP, and `Allow unprivileged user namespaces`,
# without which the cases in tests/test-ostree-pkg-diff.sh and
# tests/test-homebrew-profile.sh that run a shipped script as a program do the
# same. Both bodies are shell, and shell in a `run:` block is executed by no
# tier: tests/check-coverage.sh measures the shipped scripts, and .github/ is
# not in its manifest at all.
#
# The bodies are extracted from the workflow and run here against stubbed
# tools, rather than restated, so a step that is renamed, reindented or
# rewritten fails the extraction instead of leaving these assertions agreeing
# with a copy of text nobody runs.

BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
TEST_JOB="test"
FISH_STEP="Install fish"
NAMESPACE_STEP="Allow unprivileged user namespaces"
SUITE_STEP="Run shell tests and enforce coverage floors"
# The knob build.yml relaxes, and the path the body derives from it.
APPARMOR_KEY="kernel.apparmor_restrict_unprivileged_userns"
APPARMOR_PATH="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"

# Print the `run:` block of the named step of the named job, dedented to column
# zero. Jobs sit at two columns, steps at six, `run: |` at eight and its body at
# ten. The job has to be named because step names repeat across jobs. Same
# extractor as tests/test-prune-package-versions.sh and
# tests/test-nightly-compliance.sh, which read other steps of this workflow.
workflow_step_run() {
  local workflow="$1" job="$2" step="$3"
  awk -v want_job="${job}" -v want="${step}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_run = 0
    }
    /^      - name: / { current = substr($0, 15); in_run = 0; next }
    current_job == want_job && current == want && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 == "") { print ""; next }
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      in_run = 0
    }
  ' "${workflow}"
}

# One key of the named step's `env:` block, unexpanded. What a step hands its
# command through the environment decides as much as the body does: the suite
# step below is a bare `./tests/check-coverage.sh` and everything that makes it
# strict is in its env.
workflow_step_env() {
  local workflow="$1" job="$2" step="$3" key="$4"
  awk -v want_job="${job}" -v want="${step}" -v key="${key}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_env = 0
    }
    /^      - name: / { current = substr($0, 15); in_env = 0; next }
    current_job == want_job && current == want && /^        env:$/ { in_env = 1; next }
    in_env && substr($0, 1, 10) != "          " { in_env = 0 }
    in_env && $0 ~ ("^          " key ": ") { print substr($0, length(key) + 13); exit }
  ' "${workflow}"
}

assert_extracted() {
  local desc="$1" value="$2"
  if [[ -n "${value}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "nothing was extracted; the step was renamed, moved or reindented"
  fi
}

# Every tool these two bodies reach for, replaced by a stub that appends its own
# name and argv to one log in call order. The log is the assertion surface: a
# dropped `sudo`, a reordered pair, an extra flag and a silently different
# package name all change it.
# The stubs interpret themselves with this shell by absolute path: the body
# runs with the stub directory as the whole of PATH, so `#!/usr/bin/env bash`
# would leave every stub unexecutable and every case passing on 127.
make_step_stub_bin() {
  local bindir="$1" log="$2"
  mkdir -p "${bindir}"
  : >"${log}"

  # Records, then runs what it was asked to run, so `sudo apt-get update`
  # leaves both the privileged wrapper and the command it wrapped in the log.
  cat >"${bindir}/sudo" <<STUB
#!${BASH}
printf '%s\n' "sudo \$*" >>"\${STUB_LOG}"
exec "\$@"
STUB

  cat >"${bindir}/apt-get" <<STUB
#!${BASH}
printf '%s\n' "apt-get \$*" >>"\${STUB_LOG}"
exit "\${STUB_APT_GET_STATUS:-0}"
STUB

  cat >"${bindir}/fish" <<STUB
#!${BASH}
printf '%s\n' "fish \$*" >>"\${STUB_LOG}"
echo "fish, version 3.7.1"
STUB

  cat >"${bindir}/sysctl" <<STUB
#!${BASH}
printf '%s\n' "sysctl \$*" >>"\${STUB_LOG}"
STUB

  # The runner's answer to "may this user have a user + mount namespace", under
  # the case's control. A refusal writes to stderr, which is where the real
  # unshare(1) reports it and where the body's `2>&1` capture picks it up.
  cat >"${bindir}/unshare" <<STUB
#!${BASH}
printf '%s\n' "unshare \$*" >>"\${STUB_LOG}"
status="\${STUB_UNSHARE_STATUS:-0}"
if (( status != 0 )); then
  [[ -n "\${STUB_UNSHARE_MESSAGE:-}" ]] && printf '%s\n' "\${STUB_UNSHARE_MESSAGE}" >&2
  exit "\${status}"
fi
exit 0
STUB

  chmod 755 "${bindir}/sudo" "${bindir}/apt-get" "${bindir}/fish" \
    "${bindir}/sysctl" "${bindir}/unshare"
}

# Run one extracted body with nothing on PATH but the stubs. GitHub runs a
# `run:` block as `bash -e {0}`; both bodies open with `set -euo pipefail`
# anyway, so the interpreter is the only thing borrowed from this host.
# Writes stdout and stderr to ${WORK_DIR}/<tag>.out and .err and returns the
# body's exit status.
run_workflow_step() {
  local tag="$1" body="$2"
  shift 2
  local bindir="${WORK_DIR}/stepbin.${tag}"
  local log="${WORK_DIR}/step-calls.${tag}"
  local script="${WORK_DIR}/step.${tag}.sh"
  make_step_stub_bin "${bindir}" "${log}"
  printf '%s\n' "${body}" >"${script}"
  env -i PATH="${bindir}" HOME="${WORK_DIR}" STUB_LOG="${log}" "$@" \
    "${BASH}" "${script}" >"${WORK_DIR}/${tag}.out" 2>"${WORK_DIR}/${tag}.err"
}

step_calls() {
  cat "${WORK_DIR}/step-calls.$1"
}

test_the_steps_this_suite_depends_on_are_still_in_the_workflow() {
  assert_extracted "build.yml still has an ${FISH_STEP} step in its ${TEST_JOB} job" \
    "$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${FISH_STEP}")"
  assert_extracted "build.yml still has an ${NAMESPACE_STEP} step in its ${TEST_JOB} job" \
    "$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")"
  # Executing a body that interpolates a workflow expression would execute
  # something other than what CI runs; neither of these may grow one.
  # shellcheck disable=SC2016 # the literal '${{' is the thing being looked for
  assert_not_contains "the ${FISH_STEP} body is plain shell" \
    "$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${FISH_STEP}")" '${{'
  # shellcheck disable=SC2016
  assert_not_contains "the ${NAMESPACE_STEP} body is plain shell" \
    "$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")" '${{'
}

test_a_skip_in_ci_is_a_failure_and_both_ends_agree_on_the_name() {
  # The join that makes the two steps below load-bearing rather than
  # decorative. Without ARCH_BOOTC_NO_SKIPS the fish cases above would report
  # SKIP and the job would stay green over them, so a lost `env:` block is the
  # same defect as a lost install -- just quieter.
  assert_equals "the CI suite step sets ARCH_BOOTC_NO_SKIPS" \
    "$(workflow_step_env "${BUILD_WORKFLOW}" "${TEST_JOB}" "${SUITE_STEP}" ARCH_BOOTC_NO_SKIPS)" \
    '"1"'
  # And the name the workflow sets is the name the runner reads. Renaming it on
  # either side alone leaves a variable nothing consults.
  assert_contains "tests/run-tests.sh reads the variable build.yml sets" \
    "$(cat "${REPO_ROOT}/tests/run-tests.sh")" 'ARCH_BOOTC_NO_SKIPS'
}

test_the_fish_step_installs_the_interpreter_these_cases_need() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${FISH_STEP}")"
  run_workflow_step fish "${body}"
  local status=$?
  assert_equals "the ${FISH_STEP} step succeeds" "${status}" "0"
  # Whole log, in order, not a substring search: the index refresh has to
  # happen before the install or the install resolves against whatever the
  # runner image shipped with, both have to go through sudo, and the version
  # call afterwards is what turns a package that unpacked but cannot run into a
  # failed step rather than a suite full of skips.
  assert_equals "the step refreshes the index, installs fish under sudo, then runs it" \
    "$(step_calls fish)" \
    "sudo apt-get update
apt-get update
sudo apt-get install -y --no-install-recommends fish
apt-get install -y --no-install-recommends fish
fish --version"
}

test_the_fish_step_fails_the_job_when_the_install_fails() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${FISH_STEP}")"
  run_workflow_step fish-broken "${body}" STUB_APT_GET_STATUS=100
  local status=$?
  # `set -e` is the whole mechanism. Without it the step would go green on a
  # failed install and the fish cases would skip on a runner CI believes is
  # equipped.
  assert_equals "a failing install fails the step" "${status}" "100"
  assert_not_contains "the step stops at the failed install" \
    "$(step_calls fish-broken)" "fish --version"
}

test_the_namespace_step_accepts_a_runner_that_allows_namespaces() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")"
  run_workflow_step ns-ok "${body}"
  local status=$?
  assert_equals "the ${NAMESPACE_STEP} step succeeds when namespaces are available" \
    "${status}" "0"
  # The probe itself, argv and all. Weakening it -- dropping --mount, say --
  # would let the step pass on a runner where tests/test-ostree-pkg-diff.sh
  # still cannot run its program cases.
  assert_equals "the step proves a user + mount namespace, not merely a user one" \
    "$(step_calls ns-ok | tail -n 1)" "unshare --map-root-user --mount true"
  assert_contains "the step says so" "$(cat "${WORK_DIR}/ns-ok.out")" \
    "unprivileged user + mount namespaces are available"
}

test_the_namespace_step_fails_the_job_when_namespaces_are_refused() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")"
  run_workflow_step ns-refused "${body}" STUB_UNSHARE_STATUS=1 \
    STUB_UNSHARE_MESSAGE="unshare: write failed /proc/self/uid_map: Operation not permitted"
  local status=$?
  # This is the half issue #182 is about. A refusal that does not fail the step
  # produces a green job over a suite that skipped the cases needing root in a
  # namespace, which is indistinguishable from a job that ran them.
  assert_equals "a refused namespace fails the step" "${status}" "1"
  # The whole diagnostic, exactly: what was refused, what the kernel said about
  # it, and -- the part that is not obvious to whoever reads the failed job --
  # that the consequence is tests silently not running rather than a slow
  # runner. Losing any line leaves a failure nobody can act on.
  assert_equals "the step says what was refused, what said so, and what it costs" \
    "$(cat "${WORK_DIR}/ns-refused.err")" \
    "error: unprivileged user + mount namespaces are still refused:
  unshare: write failed /proc/self/uid_map: Operation not permitted
Tests that run a shipped script as a program would skip, and the
suite below would pass without having covered them."
  assert_not_contains "the step does not claim success as well" \
    "$(cat "${WORK_DIR}/ns-refused.out")" "are available"
}

test_the_namespace_step_explains_a_refusal_with_no_message() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")"
  run_workflow_step ns-silent "${body}" STUB_UNSHARE_STATUS=1
  local status=$?
  assert_equals "a silent refusal still fails the step" "${status}" "1"
  # An empty capture printed as-is leaves a two-space line under a heading
  # promising a reason. The fallback is what keeps the log readable.
  assert_contains "a refusal with no output still says something" \
    "$(cat "${WORK_DIR}/ns-silent.err")" "no message"
}

test_the_namespace_step_relaxes_the_sysctl_exactly_where_the_knob_exists() {
  local body
  body="$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")"
  run_workflow_step ns-sysctl "${body}"
  local calls out
  calls="$(step_calls ns-sysctl)"
  out="$(cat "${WORK_DIR}/ns-sysctl.out")"
  # Which branch runs is a property of the kernel underneath, not of anything
  # this test can arrange: /proc is the body's own input and cannot be
  # substituted without privileges the suite refuses to take. So both branches
  # are asserted, and the host decides which one is exercised -- the write on
  # the AppArmor kernels CI runs on (ubuntu-26.04 ships this knob), the
  # explanation everywhere else.
  if [[ -e "${APPARMOR_PATH}" ]]; then
    assert_equals "the step clears the AppArmor restriction under sudo" \
      "$(printf '%s\n' "${calls}" | grep '^sudo ')" \
      "sudo sysctl -w ${APPARMOR_KEY}=0"
    assert_not_contains "the step does not also call the knob missing" \
      "${out}" "does not exist on this kernel"
  else
    assert_not_contains "the step writes no sysctl where the knob is absent" \
      "${calls}" "sysctl"
    assert_contains "the step says which knob it did not find" "${out}" \
      "${APPARMOR_KEY} does not exist on this kernel; nothing to relax"
  fi
}

test_the_namespace_gate_proves_what_the_suites_own_probes_require() {
  # The gate is only worth having while it tests the same capability the
  # detectors do. Both files decide whether to run or skip on exactly this, so
  # a detector that stops asking for it -- or asks for something more -- makes
  # the CI gate a check on nothing.
  local probe="unshare --map-root-user --mount"
  assert_contains "tests/test-ostree-pkg-diff.sh probes for the capability the gate proves" \
    "$(cat "${REPO_ROOT}/tests/test-ostree-pkg-diff.sh")" "${probe}"
  assert_contains "tests/test-homebrew-profile.sh probes for the capability the gate proves" \
    "$(cat "${REPO_ROOT}/tests/test-homebrew-profile.sh")" "${probe}"
  assert_contains "the gate probes it too" \
    "$(workflow_step_run "${BUILD_WORKFLOW}" "${TEST_JOB}" "${NAMESPACE_STEP}")" "${probe}"
}

main() {
  for test_fn in \
    test_a_prefix_this_user_owns_is_trusted \
    test_a_symlinked_entry_point_is_not_rejected_out_of_hand \
    test_a_prefix_that_does_not_exist_is_refused \
    test_a_missing_entry_point_is_refused \
    test_a_non_executable_entry_point_is_refused \
    test_a_dangling_entry_point_is_refused \
    test_root_refuses_a_link_owned_by_the_prefix_owner \
    test_the_guard_asks_about_the_link_itself_and_never_dereferences \
    test_root_refuses_a_root_owned_file_in_a_directory_someone_else_owns \
    test_root_consults_the_entry_points_own_owner \
    test_root_refuses_a_trusted_link_into_an_untrusted_file \
    test_root_refuses_an_untrusted_directory_in_the_resolved_chain \
    test_root_refuses_an_untrusted_homebrew_directory \
    test_root_refuses_a_prefix_directory_someone_else_owns \
    test_root_trusts_a_wholly_root_owned_prefix \
    test_a_user_trusts_a_root_owned_prefix \
    test_a_user_refuses_another_users_prefix \
    test_the_prefix_owner_trusts_their_own_prefix \
    test_fish_guard_matches_the_posix_one \
    test_neither_file_uses_a_dereferencing_ownership_test \
    test_both_files_guard_the_same_prefixes \
    test_neither_file_leaves_its_helper_defined \
    test_the_steps_this_suite_depends_on_are_still_in_the_workflow \
    test_a_skip_in_ci_is_a_failure_and_both_ends_agree_on_the_name \
    test_the_fish_step_installs_the_interpreter_these_cases_need \
    test_the_fish_step_fails_the_job_when_the_install_fails \
    test_the_namespace_step_accepts_a_runner_that_allows_namespaces \
    test_the_namespace_step_fails_the_job_when_namespaces_are_refused \
    test_the_namespace_step_explains_a_refusal_with_no_message \
    test_the_namespace_step_relaxes_the_sysctl_exactly_where_the_knob_exists \
    test_the_namespace_gate_proves_what_the_suites_own_probes_require; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  printf '\n1..%d\n' "${tests_run}"
  if ((failures > 0)); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  if ((skipped > 0)); then
    printf 'all %d assertions passed (%d skipped: fish is not installed)\n' \
      "${tests_run}" "${skipped}"
    return 0
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

#!/usr/bin/env bash
set -uo pipefail

# Tests for system_files/etc/profile.d/homebrew.sh, run the way it is actually
# used: sourced into a login shell, with a real prefix at the real absolute
# path, and judged by what lands in the environment afterwards.
#
# Nothing executed this file before. It is ShellChecked and that is all, which
# is a weak thing to be true of a fragment that /etc/profile.d runs in every
# login shell on the machine -- root's included, via `su -`, `sudo -i`, a
# console login, and zsh through /etc/zsh/zprofile -- and that ends in
# `eval "$(.../bin/brew shellenv)"`. brew-setup.service extracts that prefix for
# UID 1000 and Homebrew requires it writable by whoever runs brew, so the
# ownership guard in front of that `eval` is a privilege boundary, and the
# `if`/`elif` around it decides which prefix the boundary is even applied to.
#
# tests/check-coverage.sh cannot report the gap: its production roots are
# scripts, system_files/usr/bin and system_files/usr/libexec, and it skips
# anything without a `#!...bash` first line. A sourced fragment has no entry
# point to run, so the floor can never see it. Hence a test file rather than a
# threshold.
#
# The obstacle is that the paths are absolute -- /var/home/linuxbrew/... and
# /home/linuxbrew/... -- and there is no environment variable to redirect them,
# deliberately: an escape hatch on a security guard is a way to bypass it. So
# the fixtures go where the fragment already looks. `unshare --map-root-user
# --mount` is how, and it is the harness tests/test-ostree-pkg-diff.sh already
# uses for the same reason: a private mount namespace whose only mapped uid is
# the unprivileged one already running the suite. A tmpfs over /var/home or
# /home is then ours to populate, and nothing outside this process tree sees
# any of it.
#
# That namespace also supplies the one thing an ordinary unprivileged test
# cannot -- a prefix the caller does not own. Inside it we are uid 0 and files
# we create read as uid 0, but a file owned by *real* root is not mapped and
# reads as 65534. Bind-mounting a root-owned binary over the fixture's
# bin/brew therefore produces exactly the case the guard exists for, with no
# privilege anywhere.
#
# The donor binary is chosen so that a guard which wrongly let it through
# leaves evidence. `tee shellenv`, run in a scratch directory, creates a file
# called `shellenv`; a refused run creates nothing. Without that, "the guard
# refused" and "the guard passed and the binary printed nothing" look the same
# from outside, and the test would pass on a fragment with no guard at all.
#
# One substitution this harness cannot catch, named here so the gap is on the
# record rather than implied: replacing `-O` with `-w`. On a real machine that
# is a genuine weakening -- root holds CAP_DAC_OVERRIDE, so `-w` is true of
# every file and the guard stops guarding. Inside a user namespace it is not,
# because the uid 0 we hold there has no capability over a file owned by an
# unmapped uid, so the fixture reads as unwritable and the mutated guard
# refuses for the wrong reason. Catching it needs a file the caller can write
# but does not own, which an unprivileged test cannot create. `-r`, `-e` and a
# deleted or inverted guard are all caught.
#
# Two further things are deliberately not asserted here.
#
# The first is which prefix wins when /var/home holds an *untrusted* one and
# /home holds a trusted one. Written `if [ -x A ]; then guard A; elif [ -x B ]`
# the answer is "neither"; written `if trusted A; then A; elif trusted B` it is
# B. Both are defensible and the file has been written both ways, so pinning
# either here would turn a design question into a test failure. The cases below
# use only fixtures where the two readings agree.
#
# The second is the fish fragment, which needs an interpreter this job does not
# have. It is a hand-maintained pair with this one and deserves the same
# treatment; see #207 and PR #209.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FRAGMENT="${REPO_ROOT}/system_files/etc/profile.d/homebrew.sh"

# An executable belonging to someone other than whoever runs the suite, to
# stand in for a prefix the caller does not own. `--map-root-user` maps exactly
# one uid -- the caller's -- so any other owner is unmapped inside the
# namespace and reads as neither 0 nor us, which is the whole requirement. It
# need not be root's: on an ostree host /usr is owned by 65534 and this works
# there unchanged.
#
# Absolute rather than resolved through PATH, because a developer machine may
# well have a Homebrew coreutils earlier on PATH -- owned by the developer,
# which is precisely the ownership this needs not to have.
DONOR="/usr/bin/tee"

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

# Report a case that could not run here for an environmental reason. Counted in
# the plan so the printed lines still add up to 1..N, and collected by
# run-tests.sh so a run that skipped its way to green cannot look like a full
# pass.
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "expected '${expected}', got '${actual}'"
  fi
}

# --- what this host can offer ------------------------------------------------

# NAMESPACE_ERROR carries what the kernel actually said. "Namespaces are
# unavailable" is not a diagnosis: a missing unshare, a refused user namespace
# and a refused mount namespace are three different problems, and the skip
# reason is the only place a CI log will show which one was hit.
NAMESPACE_ERROR=""

namespaces_available() {
  if ! command -v unshare >/dev/null 2>&1; then
    NAMESPACE_ERROR="unshare is not installed"
    return 1
  fi
  local message
  if ! message="$(unshare --map-root-user true 2>&1)"; then
    NAMESPACE_ERROR="user namespace refused: ${message:-no message}"
    return 1
  fi
  if ! message="$(unshare --map-root-user --mount true 2>&1)"; then
    NAMESPACE_ERROR="mount namespace refused: ${message:-no message}"
    return 1
  fi
  if [[ ! -x "${DONOR}" ]]; then
    NAMESPACE_ERROR="${DONOR} is missing, so there is no root-owned binary to borrow"
    return 1
  fi
  if [[ -O "${DONOR}" ]]; then
    NAMESPACE_ERROR="${DONOR} is owned by the user running the suite, so it cannot stand in for someone else's file"
    return 1
  fi
  # The fixtures and the report live here, and both must stay visible after
  # /var/home and /home are masked inside the namespace.
  case "${WORK_DIR}" in
    /var/* | /home/*)
      NAMESPACE_ERROR="the work directory ${WORK_DIR} is inside a path these cases mask"
      return 1
      ;;
  esac
  return 0
}

# /home has to be a real directory to mount a fixture over it. The bootc image
# this repo builds maps /home -> /var/home, and a developer running the suite
# on such a host cannot separate the two branches -- mounting over the symlink
# lands on /var/home and the fallback case would silently become a repeat of
# the first one. CI runs on ubuntu-24.04, where /home is a real directory.
home_is_mountable() {
  [[ -d /home && ! -L /home ]]
}

# --- running the fragment ----------------------------------------------------

# The stub Homebrew. It records that it ran and prints the shellenv assignments
# the fragment evals, working its own prefix out from where it was installed so
# one stub serves both branches. `$PATH` is left unexpanded on purpose: the
# fragment's `eval` is what expands it, which is the behaviour under test.
# shellcheck disable=SC2016 # a program for /bin/sh to expand, not this shell
BREW_STUB='#!/bin/sh
printf "%s\n" "$*" >>"${BREW_CALLS}"
prefix="$(cd -- "$(dirname -- "$0")/.." && pwd)"
printf "export HOMEBREW_PREFIX=\"%s\"\n" "${prefix}"
printf "export PATH=\"%s/bin:\$PATH\"\n" "${prefix}"
'

# The program that runs inside the namespace. It builds the fixtures, sources
# the fragment, and prints a key=value report. Kept as one string so the
# quoting is in one place; it reaches the inner shell unexpanded.
# shellcheck disable=SC2016
NS_PROGRAM='
  set -u
  fragment="$1"; work="$2"; var_home_kind="$3"; home_kind="$4"; donor="$5"
  home_mountable="$6"

  mask() {
    # A tmpfs over the directory the fragment reads, so the fixture is at the
    # absolute path with no privilege and no trace outside this process tree.
    if [ -d "$1" ]; then
      mount -t tmpfs none "$1" || exit 98
    else
      mount -t tmpfs none "$(dirname -- "$1")" || exit 98
      mkdir -p "$1" || exit 98
    fi
  }

  build() {
    base="$1"; kind="$2"
    [ "${kind}" = none ] && return 0
    bin="${base}/linuxbrew/.linuxbrew/bin"
    mkdir -p "${bin}" || exit 98
    cp -- "${work}/brew-stub" "${bin}/brew" || exit 98
    chmod 755 "${bin}/brew" || exit 98
    if [ "${kind}" = untrusted ]; then
      # Now it is root'\''s file, not ours: unmapped in this namespace, so it
      # reads as 65534 and no ownership test can call it the caller'\''s. And if
      # the guard runs it anyway, `tee shellenv` leaves a file behind saying so.
      mount --bind "${donor}" "${bin}/brew" || exit 98
    fi
  }

  mask /var/home
  [ "${home_mountable}" = yes ] && mask /home
  build /var/home "${var_home_kind}"
  build /home "${home_kind}"

  cd "${work}/cwd" || exit 98
  unset HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY
  status=
  path_before=
  funcs_before=
  vars_before=
  path_before="${PATH}"
  funcs_before="$(declare -F | sort)"
  vars_before="$(compgen -v | sort)"

  # Sourced with stdin closed: the borrowed `tee` would otherwise sit reading
  # from the terminal rather than returning and leaving its evidence.
  . "${fragment}" </dev/null 2>"${work}/stderr"
  status=$?

  printf "status=%s\n" "${status}"
  printf "prefix=%s\n" "${HOMEBREW_PREFIX:-}"
  if [ "${PATH}" = "${path_before}" ]; then
    printf "path_changed=no\n"
  else
    printf "path_changed=yes\n"
  fi
  if [ -s "${work}/brew-calls" ]; then
    printf "brew_ran=yes\n"
  else
    printf "brew_ran=no\n"
  fi
  # `tee shellenv` in this directory is the only thing that creates this file.
  if [ -e "${work}/cwd/shellenv" ]; then
    printf "donor_ran=yes\n"
  else
    printf "donor_ran=no\n"
  fi
  if [ "${var_home_kind}" = untrusted ]; then
    printf "bound_uid=%s\n" "$(stat -c %u /var/home/linuxbrew/.linuxbrew/bin/brew)"
  elif [ "${home_kind}" = untrusted ]; then
    printf "bound_uid=%s\n" "$(stat -c %u /home/linuxbrew/.linuxbrew/bin/brew)"
  fi
  if [ -s "${work}/stderr" ]; then
    printf "stderr=yes\n"
  else
    printf "stderr=no\n"
  fi
  printf "new_funcs=%s\n" "$(comm -13 <(printf "%s\n" "${funcs_before}") <(declare -F | sort) | tr "\n" " ")"
  printf "new_vars=%s\n" "$(comm -13 <(printf "%s\n" "${vars_before}") <(compgen -v | sort) | tr "\n" " ")"
'

# Source the fragment inside a namespace with the named fixtures in place, and
# print the report. `var_home_kind` and `home_kind` are each `none` (the
# directory is there but holds no prefix), `trusted` (a prefix we own) or
# `untrusted` (ours, with someone else's binary bound over bin/brew). Both
# trees are masked either way, so a Homebrew install belonging to whoever runs
# the suite can never be what a case is measuring.
run_fragment() {
  local var_home_kind="$1" home_kind="$2"
  local work
  work="$(mktemp -d -p "${WORK_DIR}")"
  mkdir -p "${work}/cwd"
  printf '%s' "${BREW_STUB}" >"${work}/brew-stub"
  chmod 755 "${work}/brew-stub"
  : >"${work}/brew-calls"
  : >"${work}/stderr"
  # A copy, because /home is masked in the fallback cases and the checkout may
  # well be under it -- on the CI runner it is. Made from the shipped file on
  # every run, so what executes is still the shipped text.
  cp -- "${FRAGMENT}" "${work}/homebrew.sh"

  unshare --map-root-user --mount \
    env "BREW_CALLS=${work}/brew-calls" \
    "${BASH}" -c "${NS_PROGRAM}" bash \
    "${work}/homebrew.sh" "${work}" "${var_home_kind}" "${home_kind}" "${DONOR}" \
    "$(home_is_mountable && printf yes || printf no)" 2>&1
}

# Pull one key out of a report. An absent key prints nothing, which no
# assertion below expects, so a report that failed to be produced fails its
# case rather than matching an empty expectation.
report() {
  local text="$1" key="$2"
  printf '%s\n' "${text}" | sed -n "s/^${key}=//p"
}

# --- the prefix the guard is meant to accept ---------------------------------

test_a_prefix_we_own_is_put_on_path() {
  if ! namespaces_available; then
    skip "a trusted /var/home prefix reaches the environment" "${NAMESPACE_ERROR}"
    return
  fi
  local out
  out="$(run_fragment trusted none)"
  assert_eq "the fragment sources cleanly for a trusted prefix" "0" "$(report "${out}" status)"
  assert_eq "brew is asked for its shellenv" "yes" "$(report "${out}" brew_ran)"
  assert_eq "what brew printed is evaluated" \
    "/var/home/linuxbrew/.linuxbrew" "$(report "${out}" prefix)"
  assert_eq "PATH is changed" "yes" "$(report "${out}" path_changed)"
}

# --- the prefix the guard exists to refuse -----------------------------------

test_a_prefix_we_do_not_own_is_never_run() {
  if ! namespaces_available; then
    skip "an untrusted /var/home prefix is refused before brew runs" "${NAMESPACE_ERROR}"
    return
  fi
  local out
  out="$(run_fragment untrusted none)"
  # Refusing is not failing: a login shell that returns non-zero here is a
  # broken login, so the fragment has to decline quietly.
  assert_eq "the fragment still sources cleanly" "0" "$(report "${out}" status)"
  assert_eq "no shellenv reaches the environment" "" "$(report "${out}" prefix)"
  assert_eq "PATH is left alone" "no" "$(report "${out}" path_changed)"
  # The positive half. Both files at that path are executable and neither
  # writes the marker above, so only this says the binary was not run.
  assert_eq "the binary at the untrusted path is never executed" \
    "no" "$(report "${out}" donor_ran)"
  # Without this the case could pass on a fixture that was never untrusted at
  # all -- a prefix the caller owns is refused by nothing, and "brew did not
  # run" would then be measuring the wrong thing.
  local bound_uid
  bound_uid="$(report "${out}" bound_uid)"
  if [[ -n "${bound_uid}" && "${bound_uid}" != "0" ]]; then
    check "the fixture really is owned by neither root nor the caller" 0
  else
    check "the fixture really is owned by neither root nor the caller" 1 \
      "bin/brew reads as uid '${bound_uid:-unknown}' inside the namespace"
  fi
  assert_eq "nothing is written to stderr" "no" "$(report "${out}" stderr)"
}

test_no_prefix_at_all_is_a_quiet_no_op() {
  if ! namespaces_available; then
    skip "a machine with no Homebrew prefix is a quiet no-op" "${NAMESPACE_ERROR}"
    return
  fi
  local out
  out="$(run_fragment none none)"
  assert_eq "the fragment sources cleanly with no prefix anywhere" "0" "$(report "${out}" status)"
  assert_eq "no shellenv reaches the environment" "" "$(report "${out}" prefix)"
  assert_eq "PATH is left alone" "no" "$(report "${out}" path_changed)"
  assert_eq "nothing is written to stderr" "no" "$(report "${out}" stderr)"
}

# --- the /home branch, which is the one a reader skims -----------------------

test_the_home_branch_is_reached_and_guarded() {
  if ! namespaces_available; then
    skip "the /home branch runs a trusted prefix" "${NAMESPACE_ERROR}"
    skip "the /home branch refuses an untrusted prefix" "${NAMESPACE_ERROR}"
    skip "/var/home wins when both prefixes are trusted" "${NAMESPACE_ERROR}"
    return
  fi
  if ! home_is_mountable; then
    local reason="/home is a symlink here, so it cannot hold a fixture of its own"
    skip "the /home branch runs a trusted prefix" "${reason}"
    skip "the /home branch refuses an untrusted prefix" "${reason}"
    skip "/var/home wins when both prefixes are trusted" "${reason}"
    return
  fi

  # The bootc image maps /home -> /var/home, so on a real machine the first
  # branch is the one that fires and this one is the one nobody exercises.
  local out
  out="$(run_fragment none trusted)"
  assert_eq "the /home branch runs a trusted prefix" \
    "/home/linuxbrew/.linuxbrew" "$(report "${out}" prefix)"

  # It carries its own guard, rather than inheriting the first branch's.
  out="$(run_fragment none untrusted)"
  assert_eq "the /home branch refuses an untrusted prefix" "" "$(report "${out}" prefix)"
  assert_eq "the /home branch refuses an untrusted prefix" \
    "no" "$(report "${out}" donor_ran)"

  # With both usable, the documented one wins.
  out="$(run_fragment trusted trusted)"
  assert_eq "/var/home wins when both prefixes are trusted" \
    "/var/home/linuxbrew/.linuxbrew" "$(report "${out}" prefix)"
}

# --- what a sourced file leaves behind ---------------------------------------

test_the_fragment_leaves_nothing_of_its_own_behind() {
  if ! namespaces_available; then
    skip "the fragment defines no lasting function" "${NAMESPACE_ERROR}"
    skip "the fragment leaves no variable but the shellenv it evaluated" \
      "${NAMESPACE_ERROR}"
    return
  fi
  # /etc/profile.d files are sourced, not run, so a helper or a scratch
  # variable left defined is one every login shell on the machine now carries,
  # under a name the user never chose. Checked by running the file rather than
  # by reading it, so an `unset` that stops covering a variable fails here.
  local out
  out="$(run_fragment trusted none)"
  assert_eq "the fragment defines no lasting function" "" "$(report "${out}" new_funcs)"
  # HOMEBREW_PREFIX is the shellenv the fragment was asked to evaluate; PATH
  # was already set. Anything else is the fragment's own workings escaping.
  local new_vars
  new_vars="$(report "${out}" new_vars)"
  new_vars="$(printf '%s\n' "${new_vars}" | tr ' ' '\n' | grep -v '^HOMEBREW_PREFIX$' | grep -v '^$' | tr '\n' ' ')"
  assert_eq "the fragment leaves no variable but the shellenv it evaluated" \
    "" "${new_vars}"
}

main() {
  for test_fn in \
    test_a_prefix_we_own_is_put_on_path \
    test_a_prefix_we_do_not_own_is_never_run \
    test_no_prefix_at_all_is_a_quiet_no_op \
    test_the_home_branch_is_reached_and_guarded \
    test_the_fragment_leaves_nothing_of_its_own_behind; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  printf '\n1..%d\n' "${tests_run}"
  if ((failures > 0)); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  if ((skipped > 0)); then
    printf 'all %d assertions passed (%d skipped)\n' "${tests_run}" "${skipped}"
    return 0
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

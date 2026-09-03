#!/usr/bin/env bash

# Unit tests for the two sourceable functions in
# system_files/usr/bin/ostree-pkg-diff that shell out to the system:
# run_db_diff (past its path guard) and cleanup.
#
# tests/test-ostree-pkg-diff.sh covers the pure parsing helpers and stops at
# run_db_diff's "path not found" guard, because everything past it runs pacman
# and everything in cleanup runs mountpoint/umount. Both are still above the
# "real program" marker, so sourcing reaches them; the system commands they
# call are supplied here as stubs earlier on PATH than the real ones. No root,
# no mounts, no loop devices, no real pacman, no network.
#
# Both functions are driven inside a subshell that prepends its stub directory
# to PATH and, for cleanup, sets the cleanup_* globals it reads. That scoping is
# the point -- one case's stubs and recorded state must not reach the next --
# so the three checks that flag exactly this pattern are off for the file:
# shellcheck disable=SC2030,SC2031,SC2034

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PKG_DIFF="${REPO_ROOT}/system_files/usr/bin/ostree-pkg-diff"

cleanup_work_dir() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
WORK_DIR="$(mktemp -d)"
trap cleanup_work_dir EXIT

# Fail-closed sudo stub, in place before the source. The script's sourcing
# guard should stop well short of the sudo re-exec; if it ever regresses, this
# stub is what stands between the suite and a real password prompt.
SOURCE_STUB_DIR="${WORK_DIR}/source-stub-bin"
mkdir -p "${SOURCE_STUB_DIR}"
printf '#!/usr/bin/env bash\necho SUDO_WAS_CALLED >&2\nexit 97\n' \
  >"${SOURCE_STUB_DIR}/sudo"
chmod +x "${SOURCE_STUB_DIR}/sudo"
PATH="${SOURCE_STUB_DIR}:${PATH}"

# shellcheck source=../system_files/usr/bin/ostree-pkg-diff disable=SC1091
source "${PKG_DIFF}"
# The script sets -e for its own use as a program. These tests deliberately run
# functions that are expected to fail, so turn it back off.
set +e

failures=0
tests_run=0

fail() {
  printf 'not ok - %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$*"
}

check() {
  # check <description> <condition-result> [detail...]
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

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "expected no output, got '${actual}'"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output did not contain '${needle}'; got: ${haystack}"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 1 "output unexpectedly contained '${needle}'; got: ${haystack}"
  else
    check "${desc}" 0
  fi
}

assert_missing() {
  local desc="$1" path="$2"
  if [[ -e "${path}" ]]; then
    check "${desc}" 1 "'${path}' still exists"
  else
    check "${desc}" 0
  fi
}

assert_exists() {
  local desc="$1" path="$2"
  if [[ -e "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "'${path}' does not exist"
  fi
}

# --- stub scaffolding ------------------------------------------------------

# Create a fresh per-test directory and print its path.
new_case_dir() {
  local dir
  dir="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
  printf '%s\n' "${dir}"
}

# Write a fake pacman DB directory whose stub `pacman -Q` output is the given
# lines, in exactly the order given. The order matters: run_db_diff pipes
# pacman through `sort` precisely so that `join` inside emit_pkg_diff sees
# ordered input, and passing deliberately unordered lines here is what proves
# that sort is still in the pipeline.
write_db() {
  local dir="$1"
  shift
  mkdir -p "${dir}"
  if (($# > 0)); then
    printf '%s\n' "$@" >"${dir}/listing"
  else
    : >"${dir}/listing"
  fi
}

# Install a `pacman` stub earlier on PATH that replays the `listing` file of
# whichever directory it was handed via --dbpath, and appends its own argv to
# ${stub_dir}/pacman.argv so the call can be asserted on. Prints the stub dir,
# which the caller prepends to PATH.
install_pacman_stub() {
  local case_dir="$1" exit_code="${2:-0}"
  local stub_dir="${case_dir}/bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/pacman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${stub_dir}/pacman.argv"
dbpath=""
while (( \$# )); do
  case "\$1" in
    --dbpath) dbpath="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\${dbpath}" ]] && cat "\${dbpath}/listing"
exit ${exit_code}
EOF
  chmod +x "${stub_dir}/pacman"
  printf '%s\n' "${stub_dir}"
}

# Install `mountpoint` and `umount` stubs. mountpoint exits with
# ${mountpoint_status} for every path; umount appends its target to
# ${stub_dir}/umount.log and exits with ${umount_status}.
install_mount_stubs() {
  local case_dir="$1" mountpoint_status="$2" umount_status="${3:-0}"
  local stub_dir="${case_dir}/bin"
  mkdir -p "${stub_dir}"
  cat >"${stub_dir}/mountpoint" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${stub_dir}/mountpoint.argv"
exit ${mountpoint_status}
EOF
  cat >"${stub_dir}/umount" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${stub_dir}/umount.log"
exit ${umount_status}
EOF
  chmod +x "${stub_dir}/mountpoint" "${stub_dir}/umount"
  printf '%s\n' "${stub_dir}"
}

# Print a log file's contents, or nothing when the stub was never called.
read_log() {
  local path="$1"
  [[ -f "${path}" ]] && cat "${path}"
  return 0
}

# --- run_db_diff success path ----------------------------------------------

test_run_db_diff_reports_each_change_kind() {
  local case_dir stub_dir output
  case_dir="$(new_case_dir)"
  # Unsorted on purpose -- see write_db.
  write_db "${case_dir}/old" "vim 9.1.0" "bash 5.2.0" "zsh 5.9"
  write_db "${case_dir}/new" "zsh 5.9" "bash 5.3.0" "nano 8.0"
  stub_dir="$(install_pacman_stub "${case_dir}")"

  output="$( PATH="${stub_dir}:${PATH}" run_db_diff "${case_dir}/old" "${case_dir}/new" 2>&1 )"

  assert_contains "removed package is reported with -" "${output}" "- vim 9.1.0"
  assert_contains "added package is reported with +" "${output}" "+ nano 8.0"
  assert_contains "changed version is reported with !" "${output}" "! bash 5.2.0 -> 5.3.0"
  assert_not_contains "unchanged package is not reported" "${output}" "zsh"
}

test_run_db_diff_identical_dbs_are_silent() {
  local case_dir stub_dir output
  case_dir="$(new_case_dir)"
  write_db "${case_dir}/old" "bash 5.2.0" "vim 9.1.0"
  write_db "${case_dir}/new" "vim 9.1.0" "bash 5.2.0"
  stub_dir="$(install_pacman_stub "${case_dir}")"

  output="$( PATH="${stub_dir}:${PATH}" run_db_diff "${case_dir}/old" "${case_dir}/new" 2>&1 )"

  assert_empty "no report for two identical package sets" "${output}"
}

test_run_db_diff_empty_old_db_is_all_additions() {
  local case_dir stub_dir output
  case_dir="$(new_case_dir)"
  write_db "${case_dir}/old"
  write_db "${case_dir}/new" "bash 5.2.0" "vim 9.1.0"
  stub_dir="$(install_pacman_stub "${case_dir}")"

  output="$( PATH="${stub_dir}:${PATH}" run_db_diff "${case_dir}/old" "${case_dir}/new" 2>&1 )"

  assert_eq "every package in the new db is an addition" \
    "+ bash 5.2.0
+ vim 9.1.0" "${output}"
}

test_run_db_diff_queries_each_dbpath_once() {
  local case_dir stub_dir argv
  case_dir="$(new_case_dir)"
  write_db "${case_dir}/old" "bash 5.2.0"
  write_db "${case_dir}/new" "bash 5.3.0"
  stub_dir="$(install_pacman_stub "${case_dir}")"

  PATH="${stub_dir}:${PATH}" run_db_diff "${case_dir}/old" "${case_dir}/new" >/dev/null 2>&1
  argv="$(read_log "${stub_dir}/pacman.argv")"

  assert_eq "pacman is queried once per deployment" \
    "--dbpath ${case_dir}/old -Q
--dbpath ${case_dir}/new -Q" "${argv}"
}

test_run_db_diff_removes_its_temporary_listings() {
  local case_dir stub_dir listings old_listing new_listing
  case_dir="$(new_case_dir)"
  write_db "${case_dir}/old" "bash 5.2.0"
  write_db "${case_dir}/new" "bash 5.3.0"
  stub_dir="$(install_pacman_stub "${case_dir}")"

  # run_db_diff installs cleanup as an EXIT trap, so the listings it mktemp'd
  # are removed when the shell that called it exits -- here, this subshell.
  # Print the paths from inside so they can be checked from outside.
  listings="$(
    PATH="${stub_dir}:${PATH}"
    run_db_diff "${case_dir}/old" "${case_dir}/new" >/dev/null 2>&1
    printf '%s\n%s\n' "${cleanup_list_old}" "${cleanup_list_new}"
  )"
  old_listing="$(sed -n 1p <<<"${listings}")"
  new_listing="$(sed -n 2p <<<"${listings}")"

  if [[ -z "${old_listing}" || -z "${new_listing}" ]]; then
    check "run_db_diff records both temporary listing paths" 1 "got: ${listings}"
    return
  fi
  check "run_db_diff records both temporary listing paths" 0
  assert_missing "old temporary listing is removed on exit" "${old_listing}"
  assert_missing "new temporary listing is removed on exit" "${new_listing}"
}

test_run_db_diff_rejects_a_file_in_place_of_a_db_dir() {
  local case_dir output status
  case_dir="$(new_case_dir)"
  write_db "${case_dir}/new" "bash 5.3.0"
  : >"${case_dir}/not-a-dir"

  output="$( (run_db_diff "${case_dir}/not-a-dir" "${case_dir}/new") 2>&1 )"
  status=$?

  assert_contains "a plain file is rejected like a missing path" \
    "${output}" "Pacman DB path not found."
  assert_eq "the guard exits non-zero" "1" "${status}"
}

# --- cleanup ---------------------------------------------------------------

test_cleanup_unmounts_and_removes_both_mounts() {
  local case_dir stub_dir umounted
  case_dir="$(new_case_dir)"
  mkdir -p "${case_dir}/mnt-old" "${case_dir}/mnt-new"
  stub_dir="$(install_mount_stubs "${case_dir}" 0)"

  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old="${case_dir}/mnt-old"
    cleanup_mnt_new="${case_dir}/mnt-new"
    cleanup_list_old=""
    cleanup_list_new=""
    cleanup
  )
  umounted="$(read_log "${stub_dir}/umount.log")"

  assert_eq "both mounts are unmounted, previous deployment first" \
    "${case_dir}/mnt-old
${case_dir}/mnt-new" "${umounted}"
  assert_missing "the old mount directory is removed" "${case_dir}/mnt-old"
  assert_missing "the new mount directory is removed" "${case_dir}/mnt-new"
}

test_cleanup_skips_umount_when_not_mounted() {
  local case_dir stub_dir umounted
  case_dir="$(new_case_dir)"
  mkdir -p "${case_dir}/mnt-old" "${case_dir}/mnt-new"
  # Exit 1 from mountpoint: the mount never happened, or already came apart.
  stub_dir="$(install_mount_stubs "${case_dir}" 1)"

  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old="${case_dir}/mnt-old"
    cleanup_mnt_new="${case_dir}/mnt-new"
    cleanup_list_old=""
    cleanup_list_new=""
    cleanup
  )
  umounted="$(read_log "${stub_dir}/umount.log")"

  assert_empty "nothing is unmounted when the paths are not mountpoints" "${umounted}"
  assert_missing "the old directory is still removed" "${case_dir}/mnt-old"
  assert_missing "the new directory is still removed" "${case_dir}/mnt-new"
}

test_cleanup_survives_a_failing_umount() {
  local case_dir stub_dir status
  case_dir="$(new_case_dir)"
  mkdir -p "${case_dir}/mnt-old" "${case_dir}/mnt-new"
  stub_dir="$(install_mount_stubs "${case_dir}" 0 32)"

  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old="${case_dir}/mnt-old"
    cleanup_mnt_new="${case_dir}/mnt-new"
    cleanup_list_old=""
    cleanup_list_new=""
    cleanup
  )
  status=$?

  # cleanup runs as an EXIT trap; a non-zero return from it would overwrite the
  # script's own exit status with the umount failure.
  assert_eq "a failing umount does not fail cleanup" "0" "${status}"
}

test_cleanup_survives_a_non_empty_mount_directory() {
  local case_dir stub_dir status
  case_dir="$(new_case_dir)"
  mkdir -p "${case_dir}/mnt-old" "${case_dir}/mnt-new"
  # rmdir refuses a non-empty directory; cleanup must absorb that too.
  : >"${case_dir}/mnt-old/leftover"
  stub_dir="$(install_mount_stubs "${case_dir}" 1)"

  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old="${case_dir}/mnt-old"
    cleanup_mnt_new="${case_dir}/mnt-new"
    cleanup_list_old=""
    cleanup_list_new=""
    cleanup
  )
  status=$?

  assert_eq "a non-empty mount directory does not fail cleanup" "0" "${status}"
  assert_exists "the non-empty directory is left in place for inspection" \
    "${case_dir}/mnt-old"
}

test_cleanup_removes_the_package_listings() {
  local case_dir stub_dir status
  case_dir="$(new_case_dir)"
  : >"${case_dir}/list-old"
  : >"${case_dir}/list-new"
  stub_dir="$(install_mount_stubs "${case_dir}" 1)"

  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old=""
    cleanup_mnt_new=""
    cleanup_list_old="${case_dir}/list-old"
    cleanup_list_new="${case_dir}/list-new"
    cleanup
  )
  status=$?

  assert_eq "cleanup returns zero" "0" "${status}"
  assert_missing "the old package listing is removed" "${case_dir}/list-old"
  assert_missing "the new package listing is removed" "${case_dir}/list-new"
}

test_cleanup_with_nothing_recorded_is_a_no_op() {
  local case_dir stub_dir status called
  case_dir="$(new_case_dir)"
  stub_dir="$(install_mount_stubs "${case_dir}" 0)"

  # Every cleanup_* variable empty is the state before the first mktemp, which
  # is what the trap sees when the script fails early.
  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old=""
    cleanup_mnt_new=""
    cleanup_list_old=""
    cleanup_list_new=""
    cleanup
  )
  status=$?
  called="$(read_log "${stub_dir}/mountpoint.argv")$(read_log "${stub_dir}/umount.log")"

  assert_eq "cleanup with nothing recorded returns zero" "0" "${status}"
  assert_empty "cleanup with nothing recorded touches no mounts" "${called}"
}

test_cleanup_removes_a_listing_when_only_one_was_created() {
  local case_dir stub_dir status
  case_dir="$(new_case_dir)"
  : >"${case_dir}/list-old"
  stub_dir="$(install_mount_stubs "${case_dir}" 1)"

  # run_db_diff mktemps the old listing first, so a failure between the two
  # leaves exactly this state.
  (
    PATH="${stub_dir}:${PATH}"
    cleanup_mnt_old=""
    cleanup_mnt_new=""
    cleanup_list_old="${case_dir}/list-old"
    cleanup_list_new=""
    cleanup
  )
  status=$?

  assert_eq "a half-created pair does not fail cleanup" "0" "${status}"
  assert_missing "the listing that was created is removed" "${case_dir}/list-old"
}

main() {
  local test_fn
  for test_fn in \
    test_run_db_diff_reports_each_change_kind \
    test_run_db_diff_identical_dbs_are_silent \
    test_run_db_diff_empty_old_db_is_all_additions \
    test_run_db_diff_queries_each_dbpath_once \
    test_run_db_diff_removes_its_temporary_listings \
    test_run_db_diff_rejects_a_file_in_place_of_a_db_dir \
    test_cleanup_unmounts_and_removes_both_mounts \
    test_cleanup_skips_umount_when_not_mounted \
    test_cleanup_survives_a_failing_umount \
    test_cleanup_survives_a_non_empty_mount_directory \
    test_cleanup_removes_the_package_listings \
    test_cleanup_with_nothing_recorded_is_a_no_op \
    test_cleanup_removes_a_listing_when_only_one_was_created; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  printf '\n1..%d\n' "${tests_run}"
  if ((failures > 0)); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

#!/usr/bin/env bash
set -uo pipefail

# Unit tests for the pure helpers in system_files/usr/bin/ostree-pkg-diff.
#
# The script splits into two halves: parsing helpers at the top, then a "real
# program" marker after which everything mounts erofs images, shells out to
# pacman, and re-executes itself under sudo. Sourcing returns at that marker, so
# these tests get the helpers without any of that -- no root, no mounts, no
# loop devices, no pacman, no network.
#
# test_sourcing_does_not_run_the_program below is what keeps that true. If the
# guard is ever removed, sourcing this script as a non-root user would exec
# sudo, so that test runs the source through a stub `sudo` on PATH rather than
# risking a real password prompt in the middle of a test run.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PKG_DIFF="${REPO_ROOT}/system_files/usr/bin/ostree-pkg-diff"

# The path is built at runtime, so shellcheck cannot follow it without -x; the
# source= hint below is for anyone who does run it that way.
# shellcheck source=../system_files/usr/bin/ostree-pkg-diff disable=SC1091
source "${PKG_DIFF}"
# The script sets -e for its own use as a program. Tests deliberately run
# helpers that are expected to fail or produce nothing, so turn it back off
# immediately; leaving it on aborts the run at the first such assertion.
set +e

failures=0
tests_run=0

# Named cleanup_work_dir, not cleanup: the sourced script defines its own
# cleanup() for its mount/tempfile teardown and would clobber a trap handler
# of that name.
cleanup_work_dir() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
WORK_DIR="$(mktemp -d)"
trap cleanup_work_dir EXIT

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

# Write a /proc/cmdline fixture (single space-separated line) and print its path.
write_cmdline() {
  # Separate `local` statements on purpose: bash expands every right-hand side
  # in a single `local` before binding any of the names, so a later one cannot
  # refer to an earlier one -- under `set -u` that is an unbound-variable error.
  local name="$1" content="$2"
  local path="${WORK_DIR}/${name}"
  printf '%s\n' "${content}" >"${path}"
  printf '%s\n' "${path}"
}

# Write a `pacman -Q` listing fixture and print its path. Sorted on the way in
# with the same `sort` the script itself uses, because join only pairs lines
# when both inputs are ordered the same way.
write_list() {
  local name="$1"
  local path="${WORK_DIR}/${name}"
  shift
  if (($# > 0)); then
    printf '%s\n' "$@" | sort >"${path}"
  else
    : >"${path}"
  fi
  printf '%s\n' "${path}"
}

# A representative `ostree admin status` output: booted entry marked with `*`,
# rollback entry marked `(rollback)`, indented detail lines in between.
STATUS_TYPICAL="$(
  cat <<'EOF'
* arch e4f2c1a0b3d5.0
    Version: 20260903.0
    origin: <unknown origin type>
  arch 9a8b7c6d5e4f.1 (rollback)
    Version: 20260902.0
    origin: <unknown origin type>
EOF
)"

# --- karg_value ------------------------------------------------------------

test_karg_value_reads_composefs() {
  local cmdline
  cmdline="$(write_cmdline composefs-cmdline \
    'root=UUID=1234 composefs=abc123def456 rw quiet')"
  assert_eq "composefs= value is extracted" \
    "abc123def456" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_reads_ostree() {
  local cmdline
  cmdline="$(write_cmdline ostree-cmdline \
    'BOOT_IMAGE=/vmlinuz ostree=/ostree/boot.1/arch/abc123/0 rw')"
  assert_eq "ostree= value is extracted" \
    "/ostree/boot.1/arch/abc123/0" "$(karg_value ostree "${cmdline}")"
}

test_karg_value_absent_key_is_empty() {
  local cmdline
  cmdline="$(write_cmdline plain-cmdline 'root=UUID=1234 rw quiet')"
  assert_empty "absent key yields no value" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_does_not_match_suffixed_key() {
  # rd.composefs= must not satisfy a lookup of composefs=; the parse splits on
  # `=` and compares the whole key, and this is what keeps that honest.
  local cmdline
  cmdline="$(write_cmdline suffixed-cmdline 'rd.composefs=nope rw')"
  assert_empty "a longer key ending in the same name does not match" \
    "$(karg_value composefs "${cmdline}")"
}

test_karg_value_bare_flag_has_no_value() {
  local cmdline
  cmdline="$(write_cmdline bare-cmdline 'quiet composefs rw')"
  assert_empty "a bare key with no = yields no value" \
    "$(karg_value composefs "${cmdline}")"
}

test_karg_value_takes_first_occurrence() {
  # Pins existing behaviour rather than endorsing it: the parse stops at the
  # first match, so a duplicated key resolves to the earlier one.
  local cmdline
  cmdline="$(write_cmdline dup-cmdline 'composefs=first rw composefs=second')"
  assert_eq "a repeated key resolves to the first occurrence" \
    "first" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_missing_file_is_empty() {
  assert_empty "an unreadable cmdline file yields no value" \
    "$(karg_value composefs "${WORK_DIR}/does-not-exist")"
}

# --- parse_ostree_karg -----------------------------------------------------

test_parse_ostree_karg_splits_os_and_boot() {
  assert_eq "ostree karg splits into stateroot and deployment id" \
    "arch abc123.0" "$(parse_ostree_karg /ostree/boot.1/arch/abc123/0)"
}

test_parse_ostree_karg_multi_digit_boot_index() {
  assert_eq "multi-digit boot.N is accepted" \
    "arch abc123.2" "$(parse_ostree_karg /ostree/boot.12/arch/abc123/2)"
}

test_parse_ostree_karg_rejects_wrong_prefix() {
  assert_empty "a non-ostree path is rejected" \
    "$(parse_ostree_karg /boot/vmlinuz-linux)"
}

test_parse_ostree_karg_rejects_non_numeric_serial() {
  assert_empty "a non-numeric serial is rejected" \
    "$(parse_ostree_karg /ostree/boot.1/arch/abc123/x)"
}

test_parse_ostree_karg_rejects_extra_segments() {
  assert_empty "a path with extra segments is rejected" \
    "$(parse_ostree_karg /ostree/boot.1/arch/abc123/0/extra)"
}

test_parse_ostree_karg_rejects_empty() {
  assert_empty "an empty karg is rejected" "$(parse_ostree_karg "")"
}

# --- ostree admin status parsing -------------------------------------------

test_status_booted_fields() {
  assert_eq "booted stateroot is read from the * line" \
    "arch" "$(status_booted_os "${STATUS_TYPICAL}")"
  assert_eq "booted deployment id is read from the * line" \
    "e4f2c1a0b3d5.0" "$(status_booted_boot "${STATUS_TYPICAL}")"
}

test_status_booted_when_not_first_entry() {
  local status
  status="$(
    cat <<'EOF'
  arch 9a8b7c6d5e4f.1
    Version: 20260902.0
* arch e4f2c1a0b3d5.0
    Version: 20260903.0
EOF
  )"
  assert_eq "booted stateroot found when * is not the first entry" \
    "arch" "$(status_booted_os "${status}")"
  assert_eq "booted id found when * is not the first entry" \
    "e4f2c1a0b3d5.0" "$(status_booted_boot "${status}")"
}

test_status_booted_absent_marker_is_empty() {
  local status
  status="$(printf '  arch 9a8b7c6d5e4f.1\n    Version: 20260902.0\n')"
  assert_empty "no * line yields no stateroot" "$(status_booted_os "${status}")"
  assert_empty "no * line yields no deployment id" "$(status_booted_boot "${status}")"
}

test_status_previous_prefers_rollback_marker() {
  assert_eq "the (rollback) entry is chosen as previous" \
    "9a8b7c6d5e4f.1" \
    "$(status_previous "${STATUS_TYPICAL}" arch e4f2c1a0b3d5.0)"
}

test_status_previous_prefers_rollback_over_earlier_entry() {
  # The rollback marker wins even when a different non-booted deployment of the
  # same stateroot is listed ahead of it.
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
  arch bbbbbbbb.1
  arch cccccccc.2 (rollback)
EOF
  )"
  assert_eq "marked rollback beats an earlier unmarked entry" \
    "cccccccc.2" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_falls_back_to_first_other_deployment() {
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
    Version: 20260903.0
  arch bbbbbbbb.1
    Version: 20260902.0
EOF
  )"
  assert_eq "unmarked previous deployment is used when no rollback marker" \
    "bbbbbbbb.1" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_ignores_other_stateroots() {
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
  fedora dddddddd.0
  arch bbbbbbbb.1
EOF
  )"
  assert_eq "a different stateroot is not a rollback candidate" \
    "bbbbbbbb.1" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_single_deployment_is_empty() {
  local status
  status="$(printf '* arch aaaaaaaa.0\n    Version: 20260903.0\n')"
  assert_empty "a sole deployment has no previous" \
    "$(status_previous "${status}" arch aaaaaaaa.0)"
}

# --- emit_pkg_diff ---------------------------------------------------------

test_emit_pkg_diff_reports_each_change_kind() {
  local old new expected
  old="$(write_list old-mixed 'bash 5.2' 'coreutils 9.5' 'vim 9.1')"
  new="$(write_list new-mixed 'bash 5.2' 'coreutils 9.6' 'zsh 5.9')"
  expected="$(printf '%s\n' '! coreutils 9.5 -> 9.6' '- vim 9.1' '+ zsh 5.9')"
  assert_eq "upgrade, removal and addition are each reported" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_identical_lists_are_silent() {
  local old new
  old="$(write_list old-same 'bash 5.2' 'coreutils 9.5')"
  new="$(write_list new-same 'bash 5.2' 'coreutils 9.5')"
  assert_empty "identical package sets produce no output" \
    "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_empty_old_list_is_all_additions() {
  local old new expected
  old="$(write_list old-empty)"
  new="$(write_list new-only 'bash 5.2' 'vim 9.1')"
  expected="$(printf '%s\n' '+ bash 5.2' '+ vim 9.1')"
  assert_eq "every package is an addition against an empty old list" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_empty_new_list_is_all_removals() {
  local old new expected
  old="$(write_list old-only 'bash 5.2' 'vim 9.1')"
  new="$(write_list new-empty)"
  expected="$(printf '%s\n' '- bash 5.2' '- vim 9.1')"
  assert_eq "every package is a removal against an empty new list" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_both_empty_is_silent() {
  local old new
  old="$(write_list old-both-empty)"
  new="$(write_list new-both-empty)"
  assert_empty "two empty lists produce no output" \
    "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_downgrade_is_reported() {
  local old new
  old="$(write_list old-downgrade 'linux 6.11')"
  new="$(write_list new-downgrade 'linux 6.10')"
  assert_eq "a version going backwards is still reported as a change" \
    "! linux 6.11 -> 6.10" "$(emit_pkg_diff "${old}" "${new}")"
}

# --- run_db_diff guard -----------------------------------------------------
#
# run_db_diff calls exit on a bad path, so each of these runs it in a subshell.
# Only the guard is exercised; past it the function shells out to pacman.

test_run_db_diff_rejects_missing_old_db() {
  local output status
  output="$( (run_db_diff "${WORK_DIR}/nope" "${WORK_DIR}") 2>&1 )"
  status=$?
  assert_eq "a missing old DB path exits 1" "1" "${status}"
  assert_contains "a missing old DB path is reported" \
    "${output}" "Pacman DB path not found."
}

test_run_db_diff_rejects_missing_new_db() {
  local output status
  output="$( (run_db_diff "${WORK_DIR}" "${WORK_DIR}/nope") 2>&1 )"
  status=$?
  assert_eq "a missing new DB path exits 1" "1" "${status}"
  assert_contains "a missing new DB path is reported" \
    "${output}" "Pacman DB path not found."
}

# --- sourcing guard --------------------------------------------------------

test_sourcing_does_not_run_the_program() {
  # Sourcing must stop at the "real program" marker. A stub sudo on PATH makes
  # a regression here visible as a failed assertion instead of a real sudo
  # password prompt hanging the suite.
  local stub_dir output
  stub_dir="${WORK_DIR}/stub-bin"
  mkdir -p "${stub_dir}"
  printf '#!/usr/bin/env bash\necho SUDO_WAS_CALLED\n' >"${stub_dir}/sudo"
  chmod +x "${stub_dir}/sudo"

  output="$(PATH="${stub_dir}:${PATH}" bash -c \
    'source "$1" && echo SOURCE_RETURNED' _ "${PKG_DIFF}" </dev/null 2>&1)"

  assert_contains "sourcing returns to the caller" "${output}" "SOURCE_RETURNED"
  if [[ "${output}" == *"SUDO_WAS_CALLED"* ]]; then
    check "sourcing does not re-exec under sudo" 1 "got: ${output}"
  else
    check "sourcing does not re-exec under sudo" 0
  fi
}

main() {
  local test_fn
  for test_fn in \
    test_karg_value_reads_composefs \
    test_karg_value_reads_ostree \
    test_karg_value_absent_key_is_empty \
    test_karg_value_does_not_match_suffixed_key \
    test_karg_value_bare_flag_has_no_value \
    test_karg_value_takes_first_occurrence \
    test_karg_value_missing_file_is_empty \
    test_parse_ostree_karg_splits_os_and_boot \
    test_parse_ostree_karg_multi_digit_boot_index \
    test_parse_ostree_karg_rejects_wrong_prefix \
    test_parse_ostree_karg_rejects_non_numeric_serial \
    test_parse_ostree_karg_rejects_extra_segments \
    test_parse_ostree_karg_rejects_empty \
    test_status_booted_fields \
    test_status_booted_when_not_first_entry \
    test_status_booted_absent_marker_is_empty \
    test_status_previous_prefers_rollback_marker \
    test_status_previous_prefers_rollback_over_earlier_entry \
    test_status_previous_falls_back_to_first_other_deployment \
    test_status_previous_ignores_other_stateroots \
    test_status_previous_single_deployment_is_empty \
    test_emit_pkg_diff_reports_each_change_kind \
    test_emit_pkg_diff_identical_lists_are_silent \
    test_emit_pkg_diff_empty_old_list_is_all_additions \
    test_emit_pkg_diff_empty_new_list_is_all_removals \
    test_emit_pkg_diff_both_empty_is_silent \
    test_emit_pkg_diff_downgrade_is_reported \
    test_run_db_diff_rejects_missing_old_db \
    test_run_db_diff_rejects_missing_new_db \
    test_sourcing_does_not_run_the_program; do
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

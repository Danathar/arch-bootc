#!/usr/bin/env bash
set -uo pipefail

# Unit tests for system_files/usr/libexec/arch-bootc-prune-esp.
#
# Every test drives the script through BOOTC_PRUNE_ESP_PATH, which is the
# script's explicit escape hatch and the only way to point it at a fixture
# directory. That is deliberate and mandatory: without it the script discovers
# ESPs from the host's real mount table and would delete real boot artifacts.
# Never add a test that runs the script with BOOTC_PRUNE_ESP_PATH unset.
#
# No root, no mounts, no block devices, and no test framework are required --
# the fixtures are plain directories under a temporary directory.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PRUNE_ESP="${REPO_ROOT}/system_files/usr/libexec/arch-bootc-prune-esp"

failures=0
tests_run=0

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

assert_dir_exists() {
  local desc="$1" path="$2"
  if [[ -d "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "missing directory ${path}"
  fi
}

assert_dir_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "unexpected directory ${path}"
  fi
}

# Print 0 when the file exists, 1 otherwise, for check()'s result argument.
file_exists_result() {
  if [[ -f "$1" ]]; then printf '0'; else printf '1'; fi
}

# Print 0 when the haystack does NOT contain the needle, 1 otherwise.
not_contains_result() {
  if [[ "$1" == *"$2"* ]]; then printf '1'; else printf '0'; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output did not contain '${needle}'"
  fi
}

# Create an ESP fixture. Named directories are created under EFI/Linux with a
# placeholder file inside so they are non-empty, matching a real deployment.
new_esp() {
  local name="$1"
  shift
  local esp="${WORK_DIR}/${name}"
  mkdir -p "${esp}/EFI/Linux" "${esp}/loader/entries"
  local deployment
  for deployment in "$@"; do
    mkdir -p "${esp}/EFI/Linux/${deployment}"
    printf 'vmlinuz\n' >"${esp}/EFI/Linux/${deployment}/vmlinuz"
    printf 'initrd\n' >"${esp}/EFI/Linux/${deployment}/initrd"
  done
  printf '%s\n' "${esp}"
}

# Write a BLS entry referencing a deployment directory.
write_bls_entry() {
  local esp="$1" entry="$2" deployment="$3" line_ending="${4:-lf}"
  local suffix=""
  [[ "${line_ending}" == "crlf" ]] && suffix=$'\r'
  {
    printf 'title Arch Linux\n'
    printf 'linux /EFI/Linux/%s/vmlinuz%s\n' "${deployment}" "${suffix}"
    printf 'initrd /EFI/Linux/%s/initrd%s\n' "${deployment}" "${suffix}"
  } >"${esp}/loader/entries/${entry}.conf"
}

# Run the script against an ESP fixture, capturing stdout+stderr in RUN_OUTPUT
# and the exit status in RUN_STATUS. Both are globals rather than a command
# substitution so the status survives -- a subshell's assignment would not.
RUN_OUTPUT=""
RUN_STATUS=0
run_prune() {
  local esp="$1"
  shift
  local out_file="${WORK_DIR}/.run-output"
  BOOTC_PRUNE_ESP_PATH="${esp}" "${PRUNE_ESP}" "$@" >"${out_file}" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(cat "${out_file}")"
}

# --- argument handling -----------------------------------------------------

test_help_exits_zero() {
  local esp output
  esp="$(new_esp help-esp)"
  run_prune "${esp}" --help
  output="${RUN_OUTPUT}"
  assert_eq "--help exits 0" "0" "${RUN_STATUS}"
  assert_contains "--help prints usage" "${output}" "Usage: arch-bootc-prune-esp"
}

test_short_help_exits_zero() {
  local esp output
  esp="$(new_esp short-help-esp)"
  run_prune "${esp}" -h
  output="${RUN_OUTPUT}"
  assert_eq "-h exits 0" "0" "${RUN_STATUS}"
  assert_contains "-h prints usage" "${output}" "Usage: arch-bootc-prune-esp"
}

test_unknown_argument_exits_two() {
  local esp output
  esp="$(new_esp bad-arg-esp)"
  run_prune "${esp}" --wat
  output="${RUN_OUTPUT}"
  assert_eq "unknown argument exits 2" "2" "${RUN_STATUS}"
  assert_contains "unknown argument prints usage to stderr" "${output}" "Usage: arch-bootc-prune-esp"
}

# --- candidate discovery ---------------------------------------------------

test_no_candidate_when_layout_missing() {
  local esp output
  esp="${WORK_DIR}/not-an-esp"
  mkdir -p "${esp}"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "missing EFI/Linux layout exits 0" "0" "${RUN_STATUS}"
  assert_contains "missing layout reports no ESP found" "${output}" "no mounted ESP with EFI/Linux and loader/entries found"
}

test_no_candidate_when_loader_entries_missing() {
  local esp output
  esp="${WORK_DIR}/half-esp"
  mkdir -p "${esp}/EFI/Linux"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "missing loader/entries exits 0" "0" "${RUN_STATUS}"
  assert_contains "missing loader/entries reports no ESP found" "${output}" "no mounted ESP with EFI/Linux and loader/entries found"
}

test_nonexistent_path_is_not_a_candidate() {
  local output
  run_prune "${WORK_DIR}/does-not-exist"
  output="${RUN_OUTPUT}"
  assert_eq "nonexistent ESP path exits 0" "0" "${RUN_STATUS}"
  assert_contains "nonexistent ESP path reports no ESP found" "${output}" "no mounted ESP with EFI/Linux and loader/entries found"
}

# --- prune behaviour -------------------------------------------------------

test_prunes_unreferenced_keeps_referenced() {
  local esp output
  esp="$(new_esp prune-esp current old)"
  write_bls_entry "${esp}" "current" "current"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "prune run exits 0" "0" "${RUN_STATUS}"
  assert_dir_exists "referenced deployment kept" "${esp}/EFI/Linux/current"
  assert_dir_absent "unreferenced deployment pruned" "${esp}/EFI/Linux/old"
  assert_contains "keeping is logged" "${output}" "keeping EFI/Linux/current"
  assert_contains "pruning is logged" "${output}" "pruning EFI/Linux/old"
}

test_keeps_every_referenced_deployment() {
  local esp
  esp="$(new_esp multi-entry-esp current rollback stale)"
  write_bls_entry "${esp}" "current" "current"
  write_bls_entry "${esp}" "rollback" "rollback"
  run_prune "${esp}"
  assert_eq "multi-entry run exits 0" "0" "${RUN_STATUS}"
  assert_dir_exists "first referenced deployment kept" "${esp}/EFI/Linux/current"
  assert_dir_exists "second referenced deployment kept" "${esp}/EFI/Linux/rollback"
  assert_dir_absent "unreferenced deployment pruned" "${esp}/EFI/Linux/stale"
}

test_refuses_to_prune_with_no_references() {
  local esp output
  esp="$(new_esp no-refs-esp current old)"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "no-reference run exits 0" "0" "${RUN_STATUS}"
  assert_contains "no-reference run refuses to prune" "${output}" "no referenced bootc EFI artifacts found; refusing to prune"
  assert_dir_exists "no-reference run keeps first deployment" "${esp}/EFI/Linux/current"
  assert_dir_exists "no-reference run keeps second deployment" "${esp}/EFI/Linux/old"
}

test_entry_without_efi_linux_paths_is_not_a_reference() {
  local esp output
  esp="$(new_esp foreign-paths-esp current)"
  {
    printf 'title Other distro\n'
    printf 'linux /vmlinuz-linux\n'
    printf 'initrd /initramfs-linux.img\n'
  } >"${esp}/loader/entries/foreign.conf"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "foreign-path run exits 0" "0" "${RUN_STATUS}"
  assert_contains "foreign paths yield no keep set" "${output}" "refusing to prune"
  assert_dir_exists "foreign-path run prunes nothing" "${esp}/EFI/Linux/current"
}

test_crlf_entry_is_parsed() {
  local esp
  esp="$(new_esp crlf-esp current old)"
  write_bls_entry "${esp}" "current" "current" crlf
  run_prune "${esp}"
  assert_eq "CRLF run exits 0" "0" "${RUN_STATUS}"
  assert_dir_exists "CRLF-referenced deployment kept" "${esp}/EFI/Linux/current"
  assert_dir_absent "CRLF run still prunes unreferenced" "${esp}/EFI/Linux/old"
}

test_entry_without_trailing_newline_is_parsed() {
  local esp
  esp="$(new_esp no-eol-esp current old)"
  printf 'title Arch Linux\nlinux /EFI/Linux/current/vmlinuz' \
    >"${esp}/loader/entries/current.conf"
  run_prune "${esp}"
  assert_eq "no-trailing-newline run exits 0" "0" "${RUN_STATUS}"
  assert_dir_exists "last line without newline is honoured" "${esp}/EFI/Linux/current"
  assert_dir_absent "no-trailing-newline run prunes unreferenced" "${esp}/EFI/Linux/old"
}

test_files_under_efi_linux_are_ignored() {
  local esp
  esp="$(new_esp stray-file-esp current old)"
  write_bls_entry "${esp}" "current" "current"
  printf 'stray\n' >"${esp}/EFI/Linux/BOOTX64.EFI"
  run_prune "${esp}"
  assert_eq "stray-file run exits 0" "0" "${RUN_STATUS}"
  check "non-directory entry left alone" \
    "$(file_exists_result "${esp}/EFI/Linux/BOOTX64.EFI")"
  assert_dir_absent "stray-file run still prunes unreferenced" "${esp}/EFI/Linux/old"
}

test_empty_efi_linux_directory_is_a_noop() {
  local esp output
  esp="$(new_esp empty-esp)"
  write_bls_entry "${esp}" "current" "current"
  run_prune "${esp}"
  output="${RUN_OUTPUT}"
  assert_eq "empty EFI/Linux run exits 0" "0" "${RUN_STATUS}"
  check "empty EFI/Linux prunes nothing" \
    "$(not_contains_result "${output}" "pruning")" \
    "unexpected prune in: ${output}"
}

# --- dry run ---------------------------------------------------------------

test_dry_run_deletes_nothing() {
  local esp output
  esp="$(new_esp dry-run-esp current old)"
  write_bls_entry "${esp}" "current" "current"
  run_prune "${esp}" --dry-run
  output="${RUN_OUTPUT}"
  assert_eq "--dry-run exits 0" "0" "${RUN_STATUS}"
  assert_contains "--dry-run reports what it would prune" "${output}" "would prune EFI/Linux/old"
  assert_dir_exists "--dry-run keeps referenced deployment" "${esp}/EFI/Linux/current"
  assert_dir_exists "--dry-run keeps unreferenced deployment" "${esp}/EFI/Linux/old"
}

test_dry_run_still_refuses_without_references() {
  local esp output
  esp="$(new_esp dry-run-no-refs-esp old)"
  run_prune "${esp}" --dry-run
  output="${RUN_OUTPUT}"
  assert_eq "--dry-run without references exits 0" "0" "${RUN_STATUS}"
  assert_contains "--dry-run without references refuses" "${output}" "refusing to prune"
  assert_dir_exists "--dry-run without references keeps everything" "${esp}/EFI/Linux/old"
}

main() {
  local test_fn
  for test_fn in \
    test_help_exits_zero \
    test_short_help_exits_zero \
    test_unknown_argument_exits_two \
    test_no_candidate_when_layout_missing \
    test_no_candidate_when_loader_entries_missing \
    test_nonexistent_path_is_not_a_candidate \
    test_prunes_unreferenced_keeps_referenced \
    test_keeps_every_referenced_deployment \
    test_refuses_to_prune_with_no_references \
    test_entry_without_efi_linux_paths_is_not_a_reference \
    test_crlf_entry_is_parsed \
    test_entry_without_trailing_newline_is_parsed \
    test_files_under_efi_linux_are_ignored \
    test_empty_efi_linux_directory_is_a_noop \
    test_dry_run_deletes_nothing \
    test_dry_run_still_refuses_without_references; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  printf '\n1..%d\n' "${tests_run}"
  if (( failures > 0 )); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

#!/usr/bin/env bash
set -uo pipefail

# Unit tests for system_files/usr/libexec/arch-bootc-prune-esp.
#
# Almost every test drives the script through BOOTC_PRUNE_ESP_PATH, which is
# the script's explicit escape hatch and the only way to point it at a fixture
# directory. That is deliberate and mandatory: without it the script discovers
# ESPs from the host's real mount table and would delete real boot artifacts.
#
# The is_genuine_esp tests are the one exception, and they are only safe
# because they close both halves of that hazard at once. They run the script
# with a PATH containing nothing but a fixture `findmnt`/`lsblk` pair and
# symlinks to the handful of real tools the script needs, so the mount table
# the script sees is entirely written by the test and the host's is never
# consulted; and they always pass --dry-run, so even a stub bug that made a
# host path look genuine could not delete anything. A test that runs the
# script with BOOTC_PRUNE_ESP_PATH unset must keep BOTH of those properties.
#
# No root, no mounts, no block devices, and no test framework are required --
# the fixtures are plain directories under a temporary directory. The stubs
# are what make the block-device-free part possible for discovery: a real ESP
# check needs a real GPT partition, a stubbed one needs a here-doc.

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

# Build the PATH directory a discovery run executes under. It holds symlinks to
# the only real programs the script needs plus whichever stubs the caller asks
# for, and nothing else -- so a tool the caller omits is genuinely invisible to
# the script's `command -v` probes, which is how the "findmnt is not installed"
# branch gets exercised without altering the host.
#
# bash is symlinked because the stubs' `#!/usr/bin/env bash` shebang resolves
# bash through this PATH, and sort/rm because find_esps and prune_esp call
# them. Anything else the script reaches for is a shell builtin.
new_stub_bin() {
  local name="$1"
  shift
  local bin="${WORK_DIR}/${name}-bin"
  mkdir -p "${bin}"
  local tool
  for tool in bash sort rm; do
    ln -sf "$(command -v "${tool}")" "${bin}/${tool}"
  done

  # findmnt is called two ways: with --mountpoint=<path> by is_genuine_esp, to
  # describe one mountpoint, and with -t vfat -o TARGET by find_esps, to list
  # candidates. The stub answers for STUB_ESP only and fails for every other
  # mountpoint, so the well-known /boot/efi, /boot and /efi candidates the
  # script always tries are refused before anything looks at the host.
  local tool_name
  for tool_name in "$@"; do
    case "${tool_name}" in
      findmnt)
        cat >"${bin}/findmnt" <<'STUB'
#!/usr/bin/env bash
mountpoint=""
for arg in "$@"; do
  case "${arg}" in
    --mountpoint=*) mountpoint="${arg#--mountpoint=}" ;;
  esac
done
if [[ -n "${mountpoint}" ]]; then
  [[ "${mountpoint}" == "${STUB_ESP}" ]] || exit 1
  [[ "${STUB_MOUNT_STATUS:-0}" == "0" ]] || exit "${STUB_MOUNT_STATUS}"
  printf '%s\n' "${STUB_MOUNT_INFO}"
  exit 0
fi
printf '%s\n' "${STUB_ESP}"
STUB
        chmod +x "${bin}/findmnt"
        ;;
      lsblk)
        cat >"${bin}/lsblk" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_DEV_STATUS:-0}" == "0" ]] || exit "${STUB_DEV_STATUS}"
printf '%s\n' "${STUB_DEV_INFO}"
STUB
        chmod +x "${bin}/lsblk"
        ;;
      *)
        printf 'test bug: unknown stub %s\n' "${tool_name}" >&2
        exit 1
        ;;
    esac
  done
  printf '%s\n' "${bin}"
}

# Run the script in discovery mode -- BOOTC_PRUNE_ESP_PATH unset -- against the
# stub bin directory. Always --dry-run: see the safety note at the top of this
# file. findmnt reports the fixture as a mounted vfat filesystem; whether the
# script accepts it is exactly what is_genuine_esp decides.
run_discovery() {
  local bin="$1" esp="$2" mount_info="$3" dev_info="$4"
  local mount_status="${5:-0}" dev_status="${6:-0}"
  local out_file="${WORK_DIR}/.run-output"
  env -u BOOTC_PRUNE_ESP_PATH \
    "PATH=${bin}" \
    "STUB_ESP=${esp}" \
    "STUB_MOUNT_INFO=${mount_info}" \
    "STUB_MOUNT_STATUS=${mount_status}" \
    "STUB_DEV_INFO=${dev_info}" \
    "STUB_DEV_STATUS=${dev_status}" \
    "${BASH}" "${PRUNE_ESP}" --dry-run >"${out_file}" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(cat "${out_file}")"
}

# Every is_genuine_esp rejection produces the same "no mounted ESP" line, so on
# its own that line proves nothing -- a fixture the script simply never found
# would say it too. Pairing it with "would prune" being absent, over a fixture
# that test_discovery_control_fixture_is_prunable shows really is prunable,
# pins the refusal on the genuineness check.
assert_refused_by_genuineness_check() {
  local desc="$1" output="$2"
  assert_eq "${desc} exits 0" "0" "${RUN_STATUS}"
  assert_contains "${desc} reports no ESP found" "${output}" \
    "no mounted ESP with EFI/Linux and loader/entries found"
  check "${desc} prunes nothing" "$(not_contains_result "${output}" "would prune")"
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

# --- is_genuine_esp (discovery without BOOTC_PRUNE_ESP_PATH) ---------------
#
# is_genuine_esp is the guard that keeps `rm -rf` off a plugged-in bootable USB
# stick: without it, "any mounted vfat filesystem with EFI/Linux and
# loader/entries" matches rescue media as readily as the real ESP. It fails
# closed, so every one of these cases must end in a refusal. A regression here
# is silent -- the script keeps working on the real ESP either way.

# One fixture for the whole group: a prunable ESP with a referenced deployment
# to keep and an unreferenced one that a run reaching prune_esp would report.
new_discovery_fixture() {
  local esp
  esp="$(new_esp "$1" current old)"
  write_bls_entry "${esp}" current current
  printf '%s\n' "${esp}"
}

test_discovery_control_fixture_is_prunable() {
  local esp output
  esp="$(new_discovery_fixture control-esp)"
  run_prune "${esp}" --dry-run
  output="${RUN_OUTPUT}"
  assert_eq "the discovery fixture exits 0 through the escape hatch" "0" "${RUN_STATUS}"
  assert_contains "the discovery fixture is prunable when the check is bypassed" \
    "${output}" "would prune EFI/Linux/old"
}

test_missing_findmnt_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture no-findmnt-esp)"
  bin="$(new_stub_bin no-findmnt lsblk)"
  run_discovery "${bin}" "${esp}" "" ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a mountpoint with no findmnt to describe it" "${output}"
}

test_missing_lsblk_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture no-lsblk-esp)"
  bin="$(new_stub_bin no-lsblk findmnt)"
  run_discovery "${bin}" "${esp}" 'SOURCE="/dev/nonexistent" FSTYPE="vfat"' ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a mountpoint with no lsblk to describe its device" "${output}"
}

test_findmnt_lookup_failure_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture findmnt-fails-esp)"
  bin="$(new_stub_bin findmnt-fails findmnt lsblk)"
  run_discovery "${bin}" "${esp}" "" "" 1
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a mountpoint findmnt cannot look up" "${output}"
}

test_findmnt_output_without_source_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture no-source-esp)"
  bin="$(new_stub_bin no-source findmnt lsblk)"
  run_discovery "${bin}" "${esp}" 'FSTYPE="vfat"' ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "findmnt output with no SOURCE field" "${output}"
}

test_findmnt_output_without_fstype_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture no-fstype-esp)"
  bin="$(new_stub_bin no-fstype findmnt lsblk)"
  run_discovery "${bin}" "${esp}" 'SOURCE="/dev/nonexistent"' ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "findmnt output with no FSTYPE field" "${output}"
}

test_non_vfat_filesystem_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture ext4-esp)"
  bin="$(new_stub_bin ext4 findmnt lsblk)"
  run_discovery "${bin}" "${esp}" 'SOURCE="/dev/nonexistent" FSTYPE="ext4"' ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a vfat-shaped layout on an ext4 filesystem" "${output}"
}

test_source_that_is_not_a_block_device_is_not_genuine() {
  local esp bin backing output
  esp="$(new_discovery_fixture regular-file-source-esp)"
  bin="$(new_stub_bin regular-file-source findmnt lsblk)"
  # A regular file stands in for the loop/bind/overlay sources the check calls
  # out: vfat and present in the mount table, but with no block device node.
  backing="${WORK_DIR}/backing-file"
  printf 'not a device\n' >"${backing}"
  run_discovery "${bin}" "${esp}" "SOURCE=\"${backing}\" FSTYPE=\"vfat\"" ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a vfat mount whose source is not a block device" "${output}"
}

test_empty_source_is_not_genuine() {
  local esp bin output
  esp="$(new_discovery_fixture empty-source-esp)"
  bin="$(new_stub_bin empty-source findmnt lsblk)"
  run_discovery "${bin}" "${esp}" 'SOURCE="" FSTYPE="vfat"' ""
  output="${RUN_OUTPUT}"
  assert_refused_by_genuineness_check "a vfat mount with an empty source" "${output}"
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
    test_dry_run_still_refuses_without_references \
    test_discovery_control_fixture_is_prunable \
    test_missing_findmnt_is_not_genuine \
    test_missing_lsblk_is_not_genuine \
    test_findmnt_lookup_failure_is_not_genuine \
    test_findmnt_output_without_source_is_not_genuine \
    test_findmnt_output_without_fstype_is_not_genuine \
    test_non_vfat_filesystem_is_not_genuine \
    test_source_that_is_not_a_block_device_is_not_genuine \
    test_empty_source_is_not_genuine; do
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

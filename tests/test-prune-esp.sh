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
# No root, no mounts and no test framework are required -- the fixtures are
# plain directories under a temporary directory. The stubs are what make that
# possible for discovery: a real ESP check needs a real GPT partition, a
# stubbed one needs a here-doc.
#
# One group is the exception to "no block devices". `is_genuine_esp` runs
# `[[ -b "$source" ]]` before it consults lsblk, so the device-class checks
# behind it -- partition type GUID, RM, HOTPLUG, the three that actually reject
# a USB stick -- cannot be reached unless the mount source names a real block
# device node. Those tests borrow whatever node /dev already offers, purely so
# that test passes: the node is never opened, read, written or mounted, and
# every command the script would run against it is a stub. When /dev has no
# block device node at all (a minimal container), the group reports SKIP rather
# than failing, so the suite stays runnable where test-quickstart-baremetal.sh
# is not.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PRUNE_ESP="${REPO_ROOT}/system_files/usr/libexec/arch-bootc-prune-esp"

# GPT partition type GUID for an EFI System Partition. Duplicated from the
# script on purpose: test_esp_parttype_guid_matches_the_script asserts the two
# agree, so a silent edit to the constant fails here instead of quietly making
# every device-class test assert against a GUID nothing rejects.
ESP_PARTTYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

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

# Report a test that could not run here for an environmental reason. Counted in
# the plan so the printed ok/skip lines still add up to 1..N, and reported at
# the end so a run that skipped its way to green cannot look like a full pass.
skip() {
  local desc="$1" reason="$2"
  tests_run=$((tests_run + 1))
  skipped=$((skipped + 1))
  printf 'ok - %s # SKIP %s\n' "${desc}" "${reason}"
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

# --- is_genuine_esp device-class checks (need a block device node) ----------
#
# Everything below `[[ -n "$source" && -b "$source" ]]` -- the lsblk lookup and
# the PARTTYPE/RM/HOTPLUG comparisons -- is unreachable while the mount source
# is a path with no block device node behind it, which is why the group above
# stops there. These borrow a node from /dev to satisfy that one test.

# Print the path of any block device node under /dev, or nothing when the host
# has none. Enumerated rather than guessed: a fixed list would miss a host whose
# only block device is /dev/xvda, /dev/mmcblk0, /dev/nbd0 or simply /dev/sdb.
#
# The node is used as a string. is_genuine_esp's only contact with it is
# `[[ -b ]]`, which stats it, and passing it to lsblk -- which is a stub here
# that prints a here-doc and never looks at its arguments. Nothing in the test
# or the script under test opens, reads, writes, partitions or mounts it, and
# every run is --dry-run.
find_block_device() {
  local candidate
  for candidate in /dev/*; do
    if [[ -b "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}
BLOCK_DEVICE="$(find_block_device || true)"

# Run a device-class case, or skip it when the host has no block device node.
# mount_info is built here rather than by the caller because every case in this
# group needs the same thing from findmnt -- a vfat mount whose source is the
# borrowed node -- and differs only in what lsblk reports back about it.
run_device_class_discovery() {
  local name="$1" dev_info="$2" dev_status="${3:-0}"
  local esp bin
  esp="$(new_discovery_fixture "${name}-esp")"
  bin="$(new_stub_bin "${name}" findmnt lsblk)"
  run_discovery "${bin}" "${esp}" \
    "SOURCE=\"${BLOCK_DEVICE}\" FSTYPE=\"vfat\"" "${dev_info}" 0 "${dev_status}"
}

# Guard for every test in this group: 0 to run, 1 to skip.
have_block_device() {
  [[ -n "${BLOCK_DEVICE}" ]]
}

no_block_device_reason="no block device node found anywhere in /dev"

test_esp_parttype_guid_matches_the_script() {
  local declared
  declared="$(sed -n 's/^ESP_PARTTYPE_GUID="\([^"]*\)".*/\1/p' "${PRUNE_ESP}" | head -n 1)"
  assert_eq "the tests assert against the script's ESP partition type GUID" \
    "${ESP_PARTTYPE_GUID}" "${declared}"
}

test_lsblk_lookup_failure_is_not_genuine() {
  if ! have_block_device; then
    skip "a device lsblk cannot look up is not genuine" "${no_block_device_reason}"
    return
  fi
  run_device_class_discovery lsblk-fails "" 1
  assert_refused_by_genuineness_check "a device lsblk cannot look up" "${RUN_OUTPUT}"
}

test_lsblk_output_without_parttype_is_not_genuine() {
  if ! have_block_device; then
    skip "lsblk output with no PARTTYPE field is not genuine" "${no_block_device_reason}"
    return
  fi
  run_device_class_discovery no-parttype 'RM="0" HOTPLUG="0"'
  assert_refused_by_genuineness_check "lsblk output with no PARTTYPE field" "${RUN_OUTPUT}"
}

test_lsblk_output_without_rm_is_not_genuine() {
  if ! have_block_device; then
    skip "lsblk output with no RM field is not genuine" "${no_block_device_reason}"
    return
  fi
  run_device_class_discovery no-rm "PARTTYPE=\"${ESP_PARTTYPE_GUID}\" HOTPLUG=\"0\""
  assert_refused_by_genuineness_check "lsblk output with no RM field" "${RUN_OUTPUT}"
}

test_lsblk_output_without_hotplug_is_not_genuine() {
  if ! have_block_device; then
    skip "lsblk output with no HOTPLUG field is not genuine" "${no_block_device_reason}"
    return
  fi
  run_device_class_discovery no-hotplug "PARTTYPE=\"${ESP_PARTTYPE_GUID}\" RM=\"0\""
  assert_refused_by_genuineness_check "lsblk output with no HOTPLUG field" "${RUN_OUTPUT}"
}

test_non_esp_partition_type_is_not_genuine() {
  if ! have_block_device; then
    skip "a non-ESP partition type is not genuine" "${no_block_device_reason}"
    return
  fi
  # A Linux filesystem partition GUID: a fixed, non-removable, non-hotplug
  # internal partition that is simply not an ESP.
  run_device_class_discovery non-esp-parttype \
    'PARTTYPE="0fc63daf-8483-4772-8e79-3d69d8477de4" RM="0" HOTPLUG="0"'
  assert_refused_by_genuineness_check "a vfat partition whose type is not the ESP GUID" \
    "${RUN_OUTPUT}"
}

test_removable_device_is_not_genuine() {
  if ! have_block_device; then
    skip "a removable device is not genuine" "${no_block_device_reason}"
    return
  fi
  # The USB stick this whole check exists for: a correctly typed ESP on media
  # the kernel reports as removable.
  run_device_class_discovery removable \
    "PARTTYPE=\"${ESP_PARTTYPE_GUID}\" RM=\"1\" HOTPLUG=\"0\""
  assert_refused_by_genuineness_check "a correctly typed ESP on removable media" \
    "${RUN_OUTPUT}"
}

test_hotplug_device_is_not_genuine() {
  if ! have_block_device; then
    skip "a hotplug device is not genuine" "${no_block_device_reason}"
    return
  fi
  # The same stick seen the other way round: RM=0, but attached to a hotplug
  # bus. Rejected on HOTPLUG alone, which is why the script tests both flags.
  run_device_class_discovery hotplug \
    "PARTTYPE=\"${ESP_PARTTYPE_GUID}\" RM=\"0\" HOTPLUG=\"1\""
  assert_refused_by_genuineness_check "a correctly typed ESP on a hotplug bus" \
    "${RUN_OUTPUT}"
}

test_fixed_internal_esp_is_genuine() {
  if ! have_block_device; then
    skip "a fixed internal ESP is accepted" "${no_block_device_reason}"
    return
  fi
  # The positive control for the whole group. Without it the refusals prove
  # nothing about the comparisons: a fixture the script could never accept for
  # some unrelated reason would refuse every case just as convincingly.
  #
  # The GUID is upper-cased here on purpose. The script lower-cases PARTTYPE
  # before comparing, so accepting this input is what asserts that the
  # lower-casing is still there -- with it removed, every other test in this
  # group still passes.
  run_device_class_discovery genuine \
    "PARTTYPE=\"${ESP_PARTTYPE_GUID^^}\" RM=\"0\" HOTPLUG=\"0\""
  assert_eq "a fixed internal ESP exits 0" "0" "${RUN_STATUS}"
  assert_contains "a fixed internal ESP is discovered and pruned" \
    "${RUN_OUTPUT}" "would prune EFI/Linux/old"
}

# --- the systemd units that actually run this script ------------------------
#
# Everything above proves the script does the right thing when something runs
# it. Nothing proved that anything ever does. The three files below are what
# start it on a real system, and until this group existed no test opened any of
# them:
#
#   arch-bootc-prune-esp.service   ExecStart= plus the ConditionPathExists=
#                                  guard in front of it
#   arch-bootc-prune-esp.timer     the periodic trigger, enabled by a symlink
#                                  the Containerfile creates by hand
#   bootc-fetch-apply-updates.service.d/10-prune-esp.conf
#                                  the drop-in that makes bootc's updater pull
#                                  the prune in and wait for it
#
# The build is not a substitute for these checks. `systemd-analyze verify` runs
# in the image build and in `just lint`, so it needs a container runtime and a
# built image, and neither invocation reaches the drop-in: the Containerfile
# lists units with `find /tmp/shipped-units -maxdepth 1 -type f`, and `-maxdepth
# 1` excludes everything under a `*.service.d/` directory. A drop-in directory
# named for a unit that does not exist is not an error at any point -- not at
# build time, not at boot. It simply never applies.
#
# The failure this group is really aimed at is quieter than that. Move or rename
# the script and `ConditionPathExists=` stops matching, at which point systemd
# skips the unit and reports success: the timer fires on schedule, the journal
# shows no failure, and the ESP fills up anyway. Reading the two paths out of
# the unit and comparing them to the file this test file already drives is the
# only thing here that catches it early.
UNIT_DIR="${REPO_ROOT}/system_files/usr/lib/systemd/system"
PRUNE_SERVICE="${UNIT_DIR}/arch-bootc-prune-esp.service"
PRUNE_TIMER="${UNIT_DIR}/arch-bootc-prune-esp.timer"
FETCH_DROPIN_DIR="${UNIT_DIR}/bootc-fetch-apply-updates.service.d"
FETCH_DROPIN="${FETCH_DROPIN_DIR}/10-prune-esp.conf"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

# Print every value assigned to KEY inside SECTION, one per line.
#
# Hand-rolled rather than shelled out to a systemd tool on purpose: the point of
# this group is to run wherever the rest of the suite runs, including hosts with
# no systemd at all, and `systemd-analyze` would not answer these questions
# anyway -- it validates one unit in isolation, it does not join a unit to the
# file the repository ships or to the symlink the Containerfile writes.
#
# Directives repeat legitimately (ExecStart= in a oneshot service, After=), so
# every match is printed and the caller decides whether more than one is a
# problem.
unit_values() {
  local file="$1" want="$2" key="$3"
  awk -v want="${want}" -v key="${key}" '
    { sub(/\r$/, "") }
    /^[[:space:]]*([#;]|$)/ { next }
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\].*$/, "", section)
      next
    }
    {
      eq = index($0, "=")
      if (eq == 0) next
      k = substr($0, 1, eq - 1)
      v = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (section == want && k == key) print v
    }
  ' "${file}"
}

# Print each section KEY appears in, deduplicated, space separated.
unit_sections_for_key() {
  local file="$1" key="$2"
  awk -v key="${key}" '
    { sub(/\r$/, "") }
    /^[[:space:]]*([#;]|$)/ { next }
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\].*$/, "", section)
      next
    }
    {
      eq = index($0, "=")
      if (eq == 0) next
      k = substr($0, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key && !(section in seen)) { seen[section] = 1; order[++n] = section }
    }
    END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), order[i] }
  ' "${file}"
}

# Strip the `-`, `+`, `!` and `:` prefixes systemd allows on ExecStart= and
# print the resulting command line. A `-` in particular changes the meaning of
# the whole unit -- the prune failing would stop being a failure -- so the
# prefix is removed here and asserted on separately.
execstart_prefix=""
execstart_command() {
  local value="$1"
  execstart_prefix=""
  while [[ "${value}" == [-+!:]* ]]; do
    execstart_prefix+="${value:0:1}"
    value="${value:1}"
  done
  printf '%s' "${value}"
}

# Map an absolute path in the booted image back to the file this repository
# ships at it. `COPY system_files/ /` in the Containerfile is what makes the two
# the same file.
shipped_path_for() {
  printf '%s' "${REPO_ROOT}/system_files$1"
}

test_service_execstart_runs_the_script_this_repo_ships() {
  local values count command
  values="$(unit_values "${PRUNE_SERVICE}" Service ExecStart)"
  count="$(printf '%s\n' "${values}" | grep -c .)"
  assert_eq "the service declares exactly one ExecStart=" "1" "${count}"
  command="$(execstart_command "${values}")"
  assert_eq "ExecStart= carries no prefix that would swallow a prune failure" \
    "" "${execstart_prefix}"
  assert_eq "ExecStart= names the script this test file drives" \
    "${PRUNE_ESP}" "$(shipped_path_for "${command%% *}")"
  check "the path ExecStart= names is executable in the tree" \
    "$([[ -x "$(shipped_path_for "${command%% *}")" ]] && printf 0 || printf 1)" \
    "$(shipped_path_for "${command%% *}") is not executable"
}

test_service_condition_guards_the_path_execstart_uses() {
  local command binary conditions
  command="$(execstart_command "$(unit_values "${PRUNE_SERVICE}" Service ExecStart)")"
  binary="${command%% *}"
  conditions="$(unit_values "${PRUNE_SERVICE}" Unit ConditionPathExists | tr '\n' ' ')"
  # A ConditionPathExists= that has drifted off ExecStart='s binary is the worst
  # of the failure modes available here: systemd treats an unmet condition as
  # success, so the unit is skipped silently on every boot and every timer
  # firing, with nothing red anywhere to notice.
  assert_eq "ConditionPathExists= guards exactly the binary ExecStart= runs" \
    "${binary} " "${conditions}"
}

test_service_execstart_command_line_prunes_a_fixture_esp() {
  local command binary rest esp
  command="$(execstart_command "$(unit_values "${PRUNE_SERVICE}" Service ExecStart)")"
  binary="${command%% *}"
  rest="${command#"${binary}"}"
  esp="$(new_esp unit-execstart current stale)"
  write_bls_entry "${esp}" arch current
  # Unquoted on purpose: these are the words systemd would split the ExecStart=
  # line into, and running the unit's actual argument list is the point. It is
  # empty in the committed tree; adding `--dry-run` to the unit would make the
  # assertions below fail rather than silently turn the prune into a no-op.
  # shellcheck disable=SC2086
  run_prune "${esp}" ${rest}
  assert_eq "the ExecStart= command line exits 0" "0" "${RUN_STATUS}"
  assert_dir_absent "the ExecStart= command line removes the unreferenced deployment" \
    "${esp}/EFI/Linux/stale"
  assert_dir_exists "the ExecStart= command line keeps the referenced deployment" \
    "${esp}/EFI/Linux/current"
}

test_service_is_oneshot_so_before_means_finished() {
  # Type=simple would report the unit started the moment it forks, and
  # `Before=bootc-fetch-apply-updates.service` would then only order the *start*
  # of the prune before the updater -- bootc would be free to stage a new
  # deployment into the ESP while the prune is still deleting from it.
  assert_eq "the service is Type=oneshot" \
    "oneshot" "$(unit_values "${PRUNE_SERVICE}" Service Type)"
}

test_service_orders_itself_before_the_unit_its_dropin_extends() {
  local dropin_unit
  dropin_unit="$(basename "${FETCH_DROPIN_DIR}")"
  dropin_unit="${dropin_unit%.d}"
  # The directory name is the only thing that binds the drop-in to a unit, and
  # nothing else in the tree spells that unit name except the Before= below.
  # Rename either one alone and the two stop describing the same ordering.
  assert_eq "Before= names the unit the drop-in directory extends" \
    "${dropin_unit}" "$(unit_values "${PRUNE_SERVICE}" Unit Before)"
}

test_dropin_pulls_in_and_waits_for_the_prune_service() {
  local service_unit
  service_unit="$(basename "${PRUNE_SERVICE}")"
  check "the drop-in that hooks bootc's updater exists" \
    "$(file_exists_result "${FETCH_DROPIN}")" "missing ${FETCH_DROPIN}"
  assert_eq "the drop-in pulls in the prune service by its shipped filename" \
    "${service_unit}" "$(unit_values "${FETCH_DROPIN}" Unit Wants)"
  # Wants= alone only co-starts the two. Without After= the updater may stage a
  # deployment while the prune is still running.
  assert_eq "the drop-in orders the updater after the prune service" \
    "${service_unit}" "$(unit_values "${FETCH_DROPIN}" Unit After)"
}

test_timer_triggers_the_prune_service() {
  local triggered
  triggered="$(unit_values "${PRUNE_TIMER}" Timer Unit)"
  # With no Unit= the timer triggers the service of the same stem, so the
  # binding is the filename and nothing states it anywhere.
  [[ -n "${triggered}" ]] || triggered="$(basename "${PRUNE_TIMER}" .timer).service"
  assert_eq "the timer triggers the prune service" \
    "$(basename "${PRUNE_SERVICE}")" "${triggered}"
  check "the unit the timer triggers is shipped in the same directory" \
    "$(file_exists_result "${UNIT_DIR}/${triggered}")" \
    "missing ${UNIT_DIR}/${triggered}"
  check "the timer schedules at least one trigger" \
    "$([[ -n "$(unit_values "${PRUNE_TIMER}" Timer OnBootSec)$(unit_values "${PRUNE_TIMER}" Timer OnUnitActiveSec)$(unit_values "${PRUNE_TIMER}" Timer OnCalendar)" ]] && printf 0 || printf 1)" \
    "no OnBootSec=, OnUnitActiveSec= or OnCalendar= in ${PRUNE_TIMER}"
}

test_containerfile_enables_the_timer_where_its_install_section_asks() {
  local line count src dst wanted_by
  line="$(grep -E '^[[:space:]]*ln -sf [^ ]+\.timer ' "${CONTAINERFILE}" \
    | grep -F "$(basename "${PRUNE_TIMER}")")"
  count="$(printf '%s\n' "${line}" | grep -c .)"
  assert_eq "the Containerfile symlinks the prune timer exactly once" "1" "${count}"
  read -r _ _ src dst _ <<<"${line}"
  assert_eq "the symlink source is the timer file this repo ships" \
    "${PRUNE_TIMER}" "$(shipped_path_for "${src}")"
  assert_eq "the symlink keeps the timer's own name" \
    "$(basename "${src}")" "$(basename "${dst}")"
  # This is the join nothing else makes. The dangling-symlink scan in the
  # Containerfile checks that the *source* resolves; it says nothing about the
  # directory the link is placed in. Enable the timer under some other target's
  # .wants and the link still resolves, the build still passes, and the timer
  # is pulled in by a target that may never be reached -- or, with
  # WantedBy= edited instead, `systemctl enable` and this hand-written symlink
  # stop agreeing about where the unit belongs.
  wanted_by="$(unit_values "${PRUNE_TIMER}" Install WantedBy)"
  assert_eq "the timer is enabled under the target its [Install] section names" \
    "/usr/lib/systemd/system/${wanted_by}.wants" "$(dirname "${dst}")"
}

test_unit_directives_sit_in_the_sections_systemd_reads() {
  # A directive under the wrong heading is not a typo systemd forgives: it is
  # either a fatal load error or -- for a key that happens to be valid in the
  # section it landed in -- silently inert. `systemd-analyze verify` would say
  # so, but only in the image build, which needs a container runtime.
  assert_eq "ExecStart= is in [Service]" \
    "Service" "$(unit_sections_for_key "${PRUNE_SERVICE}" ExecStart)"
  assert_eq "ConditionPathExists= is in [Unit]" \
    "Unit" "$(unit_sections_for_key "${PRUNE_SERVICE}" ConditionPathExists)"
  assert_eq "Before= is in [Unit]" \
    "Unit" "$(unit_sections_for_key "${PRUNE_SERVICE}" Before)"
  assert_eq "the timer's WantedBy= is in [Install]" \
    "Install" "$(unit_sections_for_key "${PRUNE_TIMER}" WantedBy)"
  assert_eq "OnUnitActiveSec= is in [Timer]" \
    "Timer" "$(unit_sections_for_key "${PRUNE_TIMER}" OnUnitActiveSec)"
  assert_eq "the drop-in's Wants= is in [Unit]" \
    "Unit" "$(unit_sections_for_key "${FETCH_DROPIN}" Wants)"
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
    test_empty_source_is_not_genuine \
    test_esp_parttype_guid_matches_the_script \
    test_lsblk_lookup_failure_is_not_genuine \
    test_lsblk_output_without_parttype_is_not_genuine \
    test_lsblk_output_without_rm_is_not_genuine \
    test_lsblk_output_without_hotplug_is_not_genuine \
    test_non_esp_partition_type_is_not_genuine \
    test_removable_device_is_not_genuine \
    test_hotplug_device_is_not_genuine \
    test_fixed_internal_esp_is_genuine \
    test_service_execstart_runs_the_script_this_repo_ships \
    test_service_condition_guards_the_path_execstart_uses \
    test_service_execstart_command_line_prunes_a_fixture_esp \
    test_service_is_oneshot_so_before_means_finished \
    test_service_orders_itself_before_the_unit_its_dropin_extends \
    test_dropin_pulls_in_and_waits_for_the_prune_service \
    test_timer_triggers_the_prune_service \
    test_containerfile_enables_the_timer_where_its_install_section_asks \
    test_unit_directives_sit_in_the_sections_systemd_reads; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  printf '\n1..%d\n' "${tests_run}"
  if (( failures > 0 )); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  if (( skipped > 0 )); then
    printf 'all %d assertions passed (%d skipped: no block device node in /dev)\n' \
      "${tests_run}" "${skipped}"
    return 0
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"

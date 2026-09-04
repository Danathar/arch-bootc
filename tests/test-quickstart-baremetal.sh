#!/usr/bin/env bash
set -uo pipefail

# Cover the bare-metal guards in scripts/quickstart.sh -- the four functions
# whose entire job is to refuse an install that would destroy the machine it is
# running on.
#
# These matter more than an ordinary uncovered branch, because a guard that
# stops nothing still exits 0 and still prints a plausible transcript. The
# end-to-end dry run cannot tell a working refusal from a deleted one here: it
# drives the script as a process through the VM path, and
# validate_baremetal_target's first statement is `[ -b ]`, which no PATH stub
# can satisfy and which needs CAP_MKNOD to fake.
#
# So this file sources the script instead -- which the sourcing guard at the
# bottom of quickstart.sh exists to allow -- and calls the functions directly
# with the commands they consult stubbed. Each case runs in its own subshell,
# so the `set -euo pipefail` and EXIT trap that sourcing installs cannot leak
# between cases, and `die`'s `exit 1` ends only that case.
#
# `[ -b ]` is still real. It is answered with a block device that already
# exists on the host, used purely as a token to get past that one line: every
# command the functions run against it is stubbed, and none of these functions
# writes anything under any circumstances. No device is opened, read or
# modified.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
QUICKSTART="${REPO_ROOT}/scripts/quickstart.sh"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() { [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"; }
trap cleanup EXIT

STUB_DIR="${WORK_DIR}/bin"
mkdir -p "${STUB_DIR}"

pass() { printf 'ok - %s\n' "$*"; }
fail() {
  printf 'not ok - %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local description="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then pass "${description}"; else fail "${description}${*:+: $*}"; fi
}
assert_status() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then check "${description}" 0
  else check "${description}" 1 "expected exit ${expected}, got ${actual}"; fi
}
assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then check "${description}" 0
  else check "${description}" 1 "output did not contain '${needle}'"; fi
}
assert_absent() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then check "${description}" 0
  else check "${description}" 1 "output unexpectedly contained '${needle}'"; fi
}

# A real block device, used only to satisfy `[ -b ]`. Every command run against
# it below is stubbed, and none of these functions writes anything.
BLOCK_TOKEN=''
for candidate in /dev/loop0 /dev/loop1 /dev/loop2 /dev/zram0 /dev/sr0 \
  /dev/vda /dev/sda /dev/nvme0n1 /dev/dm-0; do
  if [[ -b "${candidate}" ]]; then
    BLOCK_TOKEN="${candidate}"
    break
  fi
done
if [[ -z "${BLOCK_TOKEN}" ]]; then
  # Deliberately a failure, not a skip. An absent check is not a passed one,
  # and silently dropping the guards this file exists to cover would leave the
  # suite reporting success over nothing.
  fail "a block device is available to satisfy [ -b ] (looked in /dev for loop/zram/sr/vd/sd/nvme/dm)"
  printf '1..%d\n' 1
  exit 1
fi

# One stub for every command these functions consult. Each invocation is
# matched on its actual argument shape, so a case can fail exactly one call and
# leave the others working -- which is what separates "lsblk could not read the
# mounts" from "lsblk could not read the signatures".
cat >"${STUB_DIR}/lsblk" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "${args}" in
  *"-dno TYPE"*)
    [[ -n "${STUB_TYPE_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_TYPE:-disk}" ;;
  *"-nrpo MOUNTPOINTS"*)
    [[ -n "${STUB_MOUNTS_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_MOUNTS-}" ;;
  *"-nrpo NAME,FSTYPE"*)
    [[ -n "${STUB_SIGS_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_SIGS-}" ;;
  *"-srnpo NAME,TYPE"*)
    [[ -n "${STUB_ANCESTORS_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_ANCESTORS-}" ;;
  *"-dnP"*)
    [[ -n "${STUB_IDENTITY_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_IDENTITY-}" ;;
  *)
    printf 'unexpected lsblk invocation: %s\n' "${args}" >&2
    exit 90 ;;
esac
STUB

cat >"${STUB_DIR}/findmnt" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_FINDMNT_FAIL:-}" ]] && exit 1
printf '%s\n' "${STUB_FINDMNT-}"
STUB

cat >"${STUB_DIR}/readlink" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_READLINK_FAIL:-}" ]] && exit 1
printf '%s\n' "${STUB_RESOLVED-$2}"
STUB

chmod +x "${STUB_DIR}"/lsblk "${STUB_DIR}"/findmnt "${STUB_DIR}"/readlink

# Run one function from the sourced script in its own subshell.
# `running_system_disks` is redefined for the validate_baremetal_target cases
# so the disk list under test is stated by the case rather than assembled by
# another function; the real one gets its own cases further down.
run_case() {
  # The inner script is single-quoted on purpose: every expansion in it must be
  # evaluated by the subshell after quickstart.sh has been sourced, not by this
  # one before it.
  # shellcheck disable=SC2016
  OUT="$(
    PATH="${STUB_DIR}:${PATH}" "${BASH}" -c '
      source "$1" 2>/dev/null
      shift
      if [ -n "${STUB_SYSDISKS_FAIL:-}" ]; then
        running_system_disks() { return 1; }
      elif [ -n "${STUB_SYSDISKS+x}" ]; then
        running_system_disks() { printf "%s\n" "${STUB_SYSDISKS}"; }
      fi
      "$@"
    ' _ "${QUICKSTART}" "$@" 2>&1
  )"
  STATUS=$?
}

# ---------------------------------------------------------------------------
# validate_baremetal_target
# ---------------------------------------------------------------------------

not_a_device="${WORK_DIR}/regular-file"
: >"${not_a_device}"
run_case validate_baremetal_target "${not_a_device}"
assert_status "a regular file is refused as a target" 1 "${STATUS}"
assert_contains "the non-block-device refusal names the path" "${OUT}" "is not a block device"

STUB_TYPE_FAIL=1 run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "an unreadable device type is refused" 1 "${STATUS}"
assert_contains "the unreadable type is reported" "${OUT}" "could not determine the device type"

STUB_TYPE=part run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "a partition is refused" 1 "${STATUS}"
assert_contains "the partition refusal names the type" "${OUT}" "is a 'part', not a whole disk"
assert_contains "the partition refusal shows the whole-disk form" "${OUT}" "not /dev/nvme0n1p3"

STUB_SYSDISKS_FAIL=1 run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "an unmappable running system is refused" 1 "${STATUS}"
assert_contains "the unmappable system is reported" "${OUT}" "could not map the running system"

# The refusal this whole function exists for.
STUB_SYSDISKS="${BLOCK_TOKEN}" run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "a disk backing the running system is refused" 1 "${STATUS}"
assert_contains "the self-destruction refusal is explicit" "${OUT}" "backs this running system"
assert_contains "the self-destruction refusal says why it is absolute" "${OUT}" "destroy the machine you are typing on"

# ... and it must not be fooled by a *different* disk being in the list.
STUB_SYSDISKS="/dev/definitely-not-the-target" STUB_MOUNTS="" STUB_SIGS="" \
  run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "a disk that backs nothing is accepted" 0 "${STATUS}"
assert_contains "the accepted disk is reported as not backing the system" "${OUT}" "does not back the running system"
assert_contains "the accepted disk is reported as unmounted" "${OUT}" "has nothing mounted and no active swap"
assert_contains "the accepted disk is reported as signature-free" "${OUT}" "carries no ZFS/LVM/RAID/LUKS signatures"

STUB_SYSDISKS="" STUB_MOUNTS_FAIL=1 run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "an uninspectable mount list is refused" 1 "${STATUS}"
assert_contains "the uninspectable mount list is reported" "${OUT}" "could not inspect mounts below"

STUB_SYSDISKS="" STUB_MOUNTS="/mnt/data" run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "a disk with something mounted is refused" 1 "${STATUS}"
assert_contains "the mounted refusal lists the mountpoint" "${OUT}" "/mnt/data"
assert_contains "the mounted refusal says the disk is in use" "${OUT}" "Refusing to install onto a disk that is in use"

STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS_FAIL=1 run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "uninspectable signatures are refused" 1 "${STATUS}"
assert_contains "the uninspectable signatures are reported" "${OUT}" "could not inspect storage signatures"

# Nothing mounted but the disk is still live -- the case the comment in
# quickstart.sh calls out as looking free while holding data.
for signature in zfs_member LVM2_member linux_raid_member crypto_LUKS bcache; do
  STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="${BLOCK_TOKEN} ${signature}" \
    run_case validate_baremetal_target "${BLOCK_TOKEN}"
  assert_status "a disk carrying ${signature} is refused" 1 "${STATUS}"
  assert_contains "the ${signature} refusal names the signature" "${OUT}" "${signature}"
done

STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="${BLOCK_TOKEN} ext4" \
  run_case validate_baremetal_target "${BLOCK_TOKEN}"
assert_status "an ordinary filesystem is not mistaken for a storage subsystem" 0 "${STATUS}"
assert_absent "a plain ext4 disk is not refused" "${OUT}" "storage-subsystem signatures"

# ---------------------------------------------------------------------------
# running_system_disks
# ---------------------------------------------------------------------------

STUB_FINDMNT="${BLOCK_TOKEN}" STUB_ANCESTORS="${BLOCK_TOKEN} disk" \
  run_case running_system_disks
assert_status "the running system's disks are mapped" 0 "${STATUS}"
assert_contains "the backing disk is reported" "${OUT}" "${BLOCK_TOKEN}"

# Six mountpoints are probed, so the same disk is found repeatedly; the
# function sorts unique, and reporting it six times would be a bug.
STUB_FINDMNT="${BLOCK_TOKEN}" STUB_ANCESTORS="${BLOCK_TOKEN} disk" \
  run_case running_system_disks
occurrences="$(grep -c -- "^${BLOCK_TOKEN}$" <<<"${OUT}")"
if [[ "${occurrences}" == "1" ]]; then
  check "a disk backing several mountpoints is reported once" 0
else
  check "a disk backing several mountpoints is reported once" 1 "reported ${occurrences} times"
fi

# Only physical disks, never the partition or device-mapper layers above them.
STUB_FINDMNT="${BLOCK_TOKEN}" \
  STUB_ANCESTORS="/dev/mapper/root crypt
/dev/fake1 part
${BLOCK_TOKEN} disk" run_case running_system_disks
assert_contains "the physical disk below a dm layer is reported" "${OUT}" "${BLOCK_TOKEN}"
assert_absent "the device-mapper layer is not reported as a disk" "${OUT}" "/dev/mapper/root"
assert_absent "the partition is not reported as a disk" "${OUT}" "/dev/fake1"

STUB_FINDMNT="${BLOCK_TOKEN}" STUB_ANCESTORS_FAIL=1 run_case running_system_disks
assert_status "an unreadable device tree is an error, not an empty list" 1 "${STATUS}"

# A source that is not a block device is skipped rather than treated as a disk.
STUB_FINDMNT="tmpfs" run_case running_system_disks
assert_status "a non-block mount source is skipped" 0 "${STATUS}"
assert_absent "a non-block mount source contributes no disk" "${OUT}" "tmpfs"

# ---------------------------------------------------------------------------
# block_identity / assert_target_identity
# ---------------------------------------------------------------------------

IDENTITY='MAJ:MIN="8:0" SIZE="931.5G" MODEL="FIXTURE" SERIAL="S1" WWN="0x1"'

STUB_IDENTITY="${IDENTITY}" run_case block_identity "${BLOCK_TOKEN}"
assert_status "block_identity reads an identity" 0 "${STATUS}"
assert_contains "block_identity returns the fields it was given" "${OUT}" 'SERIAL="S1"'

STUB_READLINK_FAIL=1 run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "an unresolvable target path is refused" 1 "${STATUS}"
assert_contains "the unresolvable path is reported" "${OUT}" "could not resolve"

# The device was renumbered while the operator was reading the confirmation.
STUB_RESOLVED="/dev/somethingelse" STUB_IDENTITY="${IDENTITY}" \
  run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "a target whose path changed is refused" 1 "${STATUS}"
assert_contains "the changed path refusal shows both paths" "${OUT}" "the target path changed while the installer was waiting"
assert_contains "the changed path refusal is explicit about erasing" "${OUT}" "Refusing to erase a different device"

STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="" \
  run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "an unreadable identity is refused" 1 "${STATUS}"
assert_contains "the unreadable identity is reported" "${OUT}" "could not re-read the identity"

STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY_FAIL=1 \
  run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "a failing identity read is refused" 1 "${STATUS}"
assert_contains "the failing identity read is reported" "${OUT}" "could not re-read the identity"

# Same path, different disk behind it -- the swap this check exists to catch.
STUB_RESOLVED="${BLOCK_TOKEN}" \
  STUB_IDENTITY='MAJ:MIN="8:16" SIZE="500G" MODEL="OTHER" SERIAL="S2" WWN="0x2"' \
  run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "a target whose identity changed is refused" 1 "${STATUS}"
assert_contains "the changed identity refusal is explicit" "${OUT}" "the target device identity changed while the installer was waiting"
assert_contains "the changed identity refusal shows the new identity" "${OUT}" 'SERIAL="S2"'

STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_case assert_target_identity /dev/input "${BLOCK_TOKEN}" "${IDENTITY}"
assert_status "an unchanged target passes final validation" 0 "${STATUS}"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

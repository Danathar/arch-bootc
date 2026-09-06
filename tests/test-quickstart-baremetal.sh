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
# The last section covers `flow_baremetal`, the function that sequences those
# guards. Order is the property under test there and no per-guard case can see
# it: a flow that re-read the target identity before pulling the image, or
# never re-read it, or installed to the path that was typed rather than to the
# one readlink resolved, passes every guard case in this file unchanged. It is
# driven through the same sourcing entry point with --dry-run set, answering
# its prompts on stdin.
#
# `[ -b ]` is still real. It is answered with a block device that already
# exists on the host, used purely as a token to get past that one line: every
# command run against it is stubbed. Nothing here writes to it. The guard
# functions never write anywhere under any circumstances, and `flow_baremetal`
# is only ever run with DRY_RUN=1, where every mutating command is printed
# instead of executed -- with `sudo`, `mount`, `umount` and `mountpoint`
# stubbed to fail loudly, so a dry run that stopped being dry fails a case
# rather than touching the host. No device is opened, read or modified.

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
#
# Found by enumerating /dev rather than by guessing names: a fixed list would
# miss a host whose only block device is /dev/xvda, /dev/mmcblk0, /dev/nbd0 or
# simply /dev/sdb, and would then fail the whole suite while a perfectly usable
# device sat there. `[ -b ]` is a stat, not an open, so nothing here is
# read from or held. The glob is sorted, so the choice is deterministic on a
# given host.
BLOCK_TOKEN=''
for candidate in /dev/*; do
  if [[ -b "${candidate}" ]]; then
    BLOCK_TOKEN="${candidate}"
    break
  fi
done
if [[ -z "${BLOCK_TOKEN}" ]]; then
  # Deliberately a failure, not a skip. An absent check is not a passed one,
  # and silently dropping the guards this file exists to cover would leave the
  # suite reporting success over nothing.
  fail "a block device is available to satisfy [ -b ] (no block device node found anywhere in /dev)"
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
    # A case that sets STUB_IDENTITY_CALLS gets a call-counting identity read,
    # so the second one can answer differently from the first. That is the only
    # way to stage a device swapped out between the confirmation and the
    # install, which is the whole reason the identity is re-read at all.
    if [[ -n "${STUB_IDENTITY_CALLS:-}" ]]; then
      printf 'x' >>"${STUB_IDENTITY_CALLS}"
      if [[ -n "${STUB_IDENTITY_2:-}" && "$(wc -c <"${STUB_IDENTITY_CALLS}")" -ge 2 ]]; then
        printf '%s\n' "${STUB_IDENTITY_2}"
        exit 0
      fi
    fi
    printf '%s\n' "${STUB_IDENTITY-}" ;;
  # The two inventory listings flow_baremetal prints before and during the
  # confirmation. Their content is not under test; being answered without the
  # catch-all firing is.
  *"-d -o NAME,SIZE,TYPE,MODEL"*)
    printf 'NAME SIZE TYPE MODEL\n' ;;
  *"-o NAME,SIZE,TYPE,MOUNTPOINT"*)
    printf 'NAME SIZE TYPE MOUNTPOINT\n' ;;
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

# Every command flow_baremetal would use to change something. None of them may
# run: --dry-run prints mutating commands instead of executing them, and a stub
# that announces itself on stderr turns "the dry run mutated the host" from an
# invisible outcome into a failed assertion. `sudo` is also what need_cmd looks
# for, so stubbing it keeps the flow independent of whether the host has it.
for mutating_command in sudo mount umount mountpoint; do
  cat >"${STUB_DIR}/${mutating_command}" <<STUB
#!/usr/bin/env bash
printf 'STUB EXECUTED: ${mutating_command} %s\n' "\$*" >&2
exit 91
STUB
done

# A fixed, recognizable hash, so a case can assert the password hash never
# reaches the transcript rather than hoping a real hash would have been noticed.
cat >"${STUB_DIR}/openssl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '$6$STUBHASH'
STUB

chmod +x "${STUB_DIR}"/lsblk "${STUB_DIR}"/findmnt "${STUB_DIR}"/readlink \
  "${STUB_DIR}"/sudo "${STUB_DIR}"/mount "${STUB_DIR}"/umount \
  "${STUB_DIR}"/mountpoint "${STUB_DIR}"/openssl

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

# ---------------------------------------------------------------------------
# flow_baremetal
# ---------------------------------------------------------------------------
#
# The guards above are each covered on their own. What is covered here is the
# function that sequences them, because the order is load-bearing and invisible
# to a per-guard test: the pull happens before the final identity re-read, the
# re-read happens before the installer is invoked, and the device that gets
# erased is the one readlink resolved rather than the one that was typed. A
# flow that ran every guard in the wrong order would still pass every case in
# the sections above.
#
# Driven with --dry-run, so the installer command is printed and not run. Every
# command that could change anything is a stub that announces itself and exits
# non-zero, so "the dry run mutated something" fails a case instead of passing
# quietly.

FLOW_HOME="${WORK_DIR}/home"
mkdir -p "${FLOW_HOME}"

# As run_case, plus: --dry-run, a HOME with no SSH key so the optional key
# question does not appear, and stdin left free for the caller to answer the
# prompts with.
run_flow() {
  # shellcheck disable=SC2016
  OUT="$(
    PATH="${STUB_DIR}:${PATH}" HOME="${FLOW_HOME}" "${BASH}" -c '
      source "$1" 2>/dev/null
      shift
      DRY_RUN=1
      running_system_disks() { printf "%s\n" "${STUB_SYSDISKS-}"; }
      "$@"
    ' _ "${QUICKSTART}" "$@" 2>&1
  )"
  STATUS=$?
}

# The answers flow_baremetal asks for, in order: the target device, the image
# source and flavor menus, the registry (blank takes the default), the admin
# username, the password twice, the retyped device path, and the ERASE word.
baremetal_answers() {
  printf '%s\n1\n1\n\ntester\nhunter2\nhunter2\n%s\n%s\n' "$1" "$2" "$3"
}

STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a fully confirmed dry run completes" 0 "${STATUS}"
assert_contains "the dry run says nothing was changed" "${OUT}" "dry run complete"
assert_contains "the installer command is printed" "${OUT}" "bootc install to-disk"
assert_contains "the installer erases the resolved device" "${OUT}" "--wipe"
assert_contains "the installer is told to use the local image copy" "${OUT}" "--pull=never"
assert_contains "the seed step is described rather than performed" "${OUT}" \
  "would discover partition number 3"
assert_absent "no mutating command runs in a dry run" "${OUT}" "STUB EXECUTED"
assert_absent "the password hash never reaches the transcript" "${OUT}" "STUBHASH"

# The path that is erased must be the one readlink resolved. /dev/disk/by-id
# symlinks are the documented way to name a disk, and installing to the alias
# the operator typed rather than to what it points at is how the wrong device
# gets erased between one boot's device numbering and the next.
alias_path="/dev/disk/by-id/fixture-target"
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${alias_path}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a symlinked target is accepted once resolved" 0 "${STATUS}"
assert_contains "the resolution is reported to the operator" "${OUT}" \
  "resolved target: ${alias_path} -> ${BLOCK_TOKEN}"
assert_contains "the installer is pointed at the resolved device" "${OUT}" \
  "bootc install to-disk --composefs-backend ${BLOCK_TOKEN}"

# ... and the confirmation is against the resolved path, not the alias. Typing
# back what you typed in is not a confirmation of what will be erased.
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${alias_path}" "${alias_path}" ERASE)"
assert_status "retyping the alias instead of the resolved path is refused" 1 "${STATUS}"
assert_contains "the mismatch names both spellings" "${OUT}" \
  "'${alias_path}' does not match '${BLOCK_TOKEN}'"
assert_absent "a refused confirmation reaches no installer" "${OUT}" "bootc install to-disk"

STUB_READLINK_FAIL=1 run_flow flow_baremetal \
  <<<"$(baremetal_answers "${alias_path}" "${alias_path}" ERASE)"
assert_status "an unresolvable target path is refused" 1 "${STATUS}"
assert_contains "the unresolvable target is reported" "${OUT}" \
  "could not resolve '${alias_path}' to a block device"

STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a target with no readable identity is refused" 1 "${STATUS}"
assert_contains "the missing identity is reported" "${OUT}" \
  "could not capture a stable identity"
assert_absent "no identity means no installer" "${OUT}" "bootc install to-disk"

# The refusal that matters most, reached through the flow rather than by
# calling the guard: the validation runs before a single question about the
# image is asked, so a self-destructive target never gets as far as collecting
# a password.
STUB_SYSDISKS="${BLOCK_TOKEN}" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a target backing the running system is refused by the flow" 1 "${STATUS}"
assert_contains "the flow reports the self-destruction refusal" "${OUT}" \
  "backs this running system"
assert_absent "the refusal happens before any image question" "${OUT}" "Which image?"
assert_absent "a refused target reaches no installer" "${OUT}" "bootc install to-disk"

STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" erase)"
assert_status "a lowercase erase is not the confirmation" 1 "${STATUS}"
assert_contains "the declined confirmation states nothing changed" "${OUT}" \
  "aborted; nothing was changed."
assert_absent "a declined confirmation reaches no installer" "${OUT}" "bootc install to-disk"

# Closed input is not consent. Everything up to the last prompt is answered and
# the final line is simply absent, which is what a piped or truncated stdin
# looks like from inside the script.
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  run_flow flow_baremetal <<<"$(printf '%s\n1\n1\n\ntester\nhunter2\nhunter2\n%s\n' \
    "${BLOCK_TOKEN}" "${BLOCK_TOKEN}")"
assert_status "closed input at the final prompt is refused" 1 "${STATUS}"
assert_contains "closed input is named as the reason" "${OUT}" "input closed; aborted"
assert_absent "closed input reaches no installer" "${OUT}" "bootc install to-disk"

# The ordering property, stated as an executable claim. The image is pulled
# first because pulling takes minutes and the operator has already walked away;
# the identity is then re-read, and a device that changed underneath the
# confirmation stops the run before the installer is invoked. A flow that
# re-read the identity before the pull, or not at all, still passes every case
# above.
identity_calls="${WORK_DIR}/identity-calls"
: >"${identity_calls}"
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_IDENTITY_CALLS="${identity_calls}" \
  STUB_IDENTITY_2='MAJ:MIN="8:16" SIZE="500G" MODEL="OTHER" SERIAL="S2" WWN="0x2"' \
  run_flow flow_baremetal <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a device swapped after the confirmation is refused" 1 "${STATUS}"
assert_contains "the swap is reported as an identity change" "${OUT}" \
  "the target device identity changed while the installer was waiting"
assert_contains "the image was pulled before the re-read" "${OUT}" \
  "Pulling the selected image"
assert_absent "a swapped device reaches no installer" "${OUT}" "bootc install to-disk"
if [[ "$(wc -c <"${identity_calls}")" == "2" ]]; then
  check "the identity is read once up front and re-read once before installing" 0
else
  check "the identity is read once up front and re-read once before installing" 1 \
    "identity was read $(wc -c <"${identity_calls}") time(s), expected 2"
fi

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

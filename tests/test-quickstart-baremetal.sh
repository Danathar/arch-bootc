#!/usr/bin/env bash
set -uo pipefail

# Cover the parts of scripts/quickstart.sh that only a sourced call can reach:
# the four bare-metal guards whose entire job is to refuse an install that
# would destroy the machine it is running on, the flow that sequences them,
# make_seed_iso's DRY_RUN=0 half, and the EXIT handler.
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
# make_seed_iso and cleanup_task_resources are reached the same way and for the
# same reason -- every other driver of this script runs it with --dry-run, so
# the half of make_seed_iso that writes the admin password hash to a file, and
# every branch of the handler that removes it again, have never executed. Those
# two sections need no block device, so they sit above the check for one: a
# host without a block device node should lose the guard cases and nothing
# else.
#
# `[ -b ]` is still real. It is answered with a block device that already
# exists on the host, used purely as a token to get past that one line: every
# command run against it is stubbed. Nothing here writes to it. The guard
# functions never write anywhere under any circumstances. `flow_baremetal` is
# run with DRY_RUN=1, where every mutating command is printed instead of
# executed -- with `sudo`, `mount`, `umount` and `mountpoint` stubbed to fail
# loudly, so a dry run that stopped being dry fails a case rather than touching
# the host. The one section that runs it with DRY_RUN=0, for the seed step,
# replaces the installer and `sudo` with shell functions first, so `mount`
# there only creates directories under this run's work directory. No device is
# opened, read or modified.

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
assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then check "${description}" 0
  else check "${description}" 1 "expected '${expected}', got '${actual}'"; fi
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
  # The partition table flow_baremetal reads back after the installer ran, to
  # find the root partition it then mounts and seeds.
  *"-nrpo NAME,PARTN"*)
    [[ -n "${STUB_PARTS_FAIL:-}" ]] && exit 1
    printf '%s\n' "${STUB_PARTS-}" ;;
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
for mutating_command in mount umount; do
  cat >"${STUB_DIR}/${mutating_command}" <<STUB
#!/usr/bin/env bash
printf 'STUB EXECUTED: ${mutating_command} %s\n' "\$*" >&2
exit 91
STUB
done

# sudo and mountpoint are also the two commands cleanup_task_resources
# consults, and that section needs them to succeed and to be observable rather
# than to abort. Setting STUB_CALL_LOG switches them into that mode; with it
# unset -- which is every case above -- they behave exactly like the pair in
# the loop.
cat >"${STUB_DIR}/sudo" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_CALL_LOG:-}" ]; then
  printf 'sudo %s\n' "$*" >>"${STUB_CALL_LOG}"
  exit "${STUB_SUDO_RC:-0}"
fi
printf 'STUB EXECUTED: sudo %s\n' "$*" >&2
exit 91
STUB

cat >"${STUB_DIR}/mountpoint" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_CALL_LOG:-}" ]; then
  printf 'mountpoint %s\n' "$*" >>"${STUB_CALL_LOG}"
  exit "${STUB_MOUNTPOINT_RC:-0}"
fi
printf 'STUB EXECUTED: mountpoint %s\n' "$*" >&2
exit 91
STUB

# A fixed, recognizable hash, so a case can assert the password hash never
# reaches the transcript rather than hoping a real hash would have been noticed.
cat >"${STUB_DIR}/openssl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '$6$STUBHASH'
STUB

# The ISO tool make_seed_iso hands the staged cloud-init directory to, stubbed
# under all three names find_iso_tool can pick, so a case chooses the code path
# by setting ISO_TOOL rather than by arranging for a tool to be absent.
#
# It is also the probe, and it has to be: it runs at the only instant the
# staging directory still exists. make_seed_iso removes that directory before
# returning, so a case that looks afterwards can only ever see an absence.
# Recording the directory's mode, each staged file's mode and each staged
# file's content from in here is what makes those properties assertable at all.
#
# `xorriso -as mkisofs` and the genisoimage/mkisofs form both end with the
# staging directory, so the last argument identifies it in either arm.
cat >"${STUB_DIR}/xorriso" <<'STUB'
#!/usr/bin/env bash
probe="${SEED_PROBE}"
printf '%s\n' "$0" >"${probe}/tool"
printf '%s\n' "$*" >"${probe}/argv"

seeddir=''
for seeddir in "$@"; do :; done
printf '%s\n' "${seeddir}" >"${probe}/seeddir"

if [[ -d "${seeddir}" ]]; then
  stat -c '%a' "${seeddir}" >"${probe}/seeddir-mode"
  for staged in meta-data user-data; do
    if [[ -e "${seeddir}/${staged}" ]]; then
      stat -c '%a' "${seeddir}/${staged}" >"${probe}/${staged}-mode"
      cp -- "${seeddir}/${staged}" "${probe}/${staged}"
    fi
  done
fi

# A failing ISO tool is the reason cleanup_task_resources has a seed branch:
# the hash is already on disk at this point and the run is about to end.
[[ -n "${SEED_TOOL_FAIL:-}" ]] && exit 7

output='' previous=''
for argument in "$@"; do
  [[ "${previous}" == "-output" ]] && output="${argument}"
  previous="${argument}"
done
[[ -n "${output}" ]] || { printf 'stub: no -output argument\n' >&2; exit 90; }
# Deliberately world-readable: the 0600 on the finished ISO has to be
# make_seed_iso's own doing, not the umask's and not the stub's.
umask 022
printf 'ISO\n' >"${output}"
STUB
cp -- "${STUB_DIR}/xorriso" "${STUB_DIR}/genisoimage"
cp -- "${STUB_DIR}/xorriso" "${STUB_DIR}/mkisofs"

chmod +x "${STUB_DIR}"/lsblk "${STUB_DIR}"/findmnt "${STUB_DIR}"/readlink \
  "${STUB_DIR}"/sudo "${STUB_DIR}"/mount "${STUB_DIR}"/umount \
  "${STUB_DIR}"/mountpoint "${STUB_DIR}"/openssl \
  "${STUB_DIR}"/xorriso "${STUB_DIR}"/genisoimage "${STUB_DIR}"/mkisofs

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
# make_seed_iso, DRY_RUN=0
# ---------------------------------------------------------------------------
#
# The other half of the function the flow_baremetal cases below reach. Every
# existing driver of quickstart.sh runs it with --dry-run, where make_seed_iso
# prints one sentence about a directory it never creates -- so the only part of
# it that has ever executed is the sentence. The half that runs on a real
# install is the half that writes the admin password hash to a file.
#
# That is where the properties are, and they are all invisible from outside:
# a mutant that widened the staging directory's 0700, or user-data's 0600, or
# left the hash on disk after the ISO was built, produces the same seed ISO and
# the same transcript and exits 0 either way.
#
# Nothing in this section needs the block device the sections below do, so it
# runs on any host -- which is why it sits above that check rather than after
# it. The password hash is the same '$6$STUBHASH' fixture the openssl stub
# emits, so the one string can be looked for in the staged file (where it
# belongs), in the transcript (where it must never appear), and in the work
# directory afterwards (where nothing may keep it).

# shellcheck disable=SC2016  # a literal fixture, not an expansion
FIXTURE_HASH='$6$STUBHASH'
FIXTURE_KEY='ssh-ed25519 AAAAFIXTUREKEY tester@fixture'

# A fresh output directory and probe directory per case, so "the work directory
# holds nothing but the ISO" can be asserted literally rather than by filtering.
seed_case_number=0
new_case() {
  seed_case_number=$((seed_case_number + 1))
  OUT_DIR="${WORK_DIR}/case${seed_case_number}"
  SEED_PROBE="${WORK_DIR}/probe${seed_case_number}"
  mkdir -p "${OUT_DIR}" "${SEED_PROBE}"
  export SEED_PROBE
}
probe_file() { cat -- "${SEED_PROBE}/$1" 2>/dev/null; }

# As run_case, but with DRY_RUN=0. The subshell prints SEED_STAGING_DIR and the
# work directory's contents after the call returns: both are things the
# function is responsible for leaving in a particular state, and neither is
# visible from out here otherwise.
run_seed() {
  # shellcheck disable=SC2016
  OUT="$(
    PATH="${STUB_DIR}:${PATH}" "${BASH}" -c '
      source "$1" 2>/dev/null
      shift
      DRY_RUN=0
      ISO_TOOL="${SEED_ISO_TOOL:-xorriso}"
      VM_HOSTNAME="${SEED_HOSTNAME:-seedhost}"
      outdir="$1"
      make_seed_iso "$@"
      printf "AFTER staging=[%s]\n" "${SEED_STAGING_DIR}"
      printf "AFTER contents=[%s]\n" "$(ls -A -- "${outdir}" | sort | tr "\n" " ")"
    ' _ "${QUICKSTART}" "$@" 2>&1
  )"
  STATUS=$?
}

new_case
iso="${OUT_DIR}/seed.iso"
SEED_HOSTNAME=fixturehost run_seed "${OUT_DIR}" tester "${FIXTURE_HASH}" '' "${iso}"

assert_status "a real seed build succeeds" 0 "${STATUS}"
assert_contains "the seed is reported to the operator" "${OUT}" "cloud-init seed: ${iso}"

# The staging directory goes inside the caller's work directory, not in /tmp.
# flow_vm has already refused a work directory on tmpfs; staging the seed
# somewhere else would put it back on host RAM behind that check's back.
staged_dir="$(probe_file seeddir)"
if [[ "${staged_dir}" == "${OUT_DIR}/.arch-bootc-seed."* ]]; then
  check "the staging directory is created inside the caller's work directory" 0
else
  check "the staging directory is created inside the caller's work directory" 1 \
    "staged in '${staged_dir}'"
fi

assert_equals "the staging directory is private to this invocation" \
  "700" "$(probe_file seeddir-mode)"
assert_equals "user-data is created unreadable to other users" \
  "600" "$(probe_file user-data-mode)"
assert_equals "meta-data is created unreadable to other users" \
  "600" "$(probe_file meta-data-mode)"

user_data="$(probe_file user-data)"
assert_contains "user-data is a cloud-config document" "${user_data}" "#cloud-config"
assert_contains "user-data creates the requested account" "${user_data}" "- name: tester"
assert_contains "user-data pins the first admin to uid 1000" "${user_data}" "uid: 1000"
assert_contains "user-data puts the admin in wheel" "${user_data}" "groups: [wheel]"
# cloud-init locks a password-only account unless told otherwise, which is what
# would leave the operator unable to log in at the console after first boot.
assert_contains "user-data unlocks the password it just set" "${user_data}" "lock_passwd: false"
assert_contains "user-data carries the password hash" "${user_data}" "passwd: '${FIXTURE_HASH}'"
assert_absent "no SSH key is offered when none was collected" "${user_data}" "ssh_authorized_keys"

meta_data="$(probe_file meta-data)"
assert_contains "meta-data names the VM as the hostname" "${meta_data}" "local-hostname: fixturehost"
assert_contains "meta-data identifies the instance" "${meta_data}" "instance-id: arch-bootc-quickstart"

assert_contains "the ISO tool is asked for the cidata label cloud-init looks for" \
  "$(probe_file argv)" "-volid cidata"
assert_contains "xorriso is driven in mkisofs mode" "$(probe_file argv)" "-as mkisofs"

# The hash goes in the file, never in the transcript: `run` prints every
# command it is handed, so a seed built by passing the hash on a command line
# would put it in the operator's scrollback and in any captured log.
assert_absent "the password hash never reaches the seed transcript" "${OUT}" "STUBHASH"

# What is left behind. Both halves matter: the ISO has to survive because it is
# the result, and the staging directory must not because it holds the hash.
assert_contains "the staging directory does not outlive the seed build" \
  "${OUT}" "AFTER contents=[seed.iso ]"
assert_equals "the finished ISO is readable only by its owner" \
  "600" "$(stat -c '%a' -- "${iso}")"
# Cleared so the EXIT handler cannot later remove files from a path this
# invocation has already given up.
assert_contains "the staging path is released once the build is done" \
  "${OUT}" "AFTER staging=[]"

new_case
iso="${OUT_DIR}/seed.iso"
run_seed "${OUT_DIR}" tester "${FIXTURE_HASH}" "${FIXTURE_KEY}" "${iso}"

assert_status "a seed build with an SSH key succeeds" 0 "${STATUS}"
user_data="$(probe_file user-data)"
assert_contains "a collected SSH key opens the authorized-keys block" \
  "${user_data}" "ssh_authorized_keys:"
assert_contains "the collected SSH key is written verbatim" "${user_data}" "- ${FIXTURE_KEY}"
assert_contains "an SSH key does not displace the password hash" \
  "${user_data}" "passwd: '${FIXTURE_HASH}'"

# find_iso_tool accepts genisoimage and mkisofs as well as xorriso, and neither
# understands `-as mkisofs` -- handing it to them is how the seed step fails on
# a host with no xorriso. Only the xorriso case arm has ever run.
for iso_tool in genisoimage mkisofs; do
  new_case
  iso="${OUT_DIR}/seed.iso"
  SEED_ISO_TOOL="${iso_tool}" run_seed "${OUT_DIR}" tester "${FIXTURE_HASH}" '' "${iso}"

  assert_status "a seed build with ${iso_tool} succeeds" 0 "${STATUS}"
  assert_contains "${iso_tool} is the tool that runs" "$(probe_file tool)" "/${iso_tool}"
  assert_contains "${iso_tool} is still asked for the cidata label" \
    "$(probe_file argv)" "-volid cidata"
  assert_absent "${iso_tool} is not handed xorriso's emulation flag" \
    "$(probe_file argv)" "-as"
  assert_contains "${iso_tool} produces a seed that is cleaned up after" \
    "${OUT}" "AFTER contents=[seed.iso ]"
done

# The hash is on disk before the ISO tool is called, so a failure here is the
# case cleanup_task_resources' seed branch exists for. Neither the exit status
# nor the transcript distinguishes a handler that cleans up from one that does
# not.
new_case
iso="${OUT_DIR}/seed.iso"
SEED_TOOL_FAIL=1 run_seed "${OUT_DIR}" tester "${FIXTURE_HASH}" '' "${iso}"

assert_status "a failing ISO tool fails the run" 7 "${STATUS}"
# The hash really was written first, so the two assertions below are about its
# removal rather than about the failure having come too early to leave anything.
assert_contains "the hash had already been staged when the tool failed" \
  "$(probe_file user-data)" "STUBHASH"
assert_equals "a failed seed build leaves nothing behind" "" \
  "$(find "${OUT_DIR}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')"
if grep -rqs -- "STUBHASH" "${OUT_DIR}"; then
  check "no password hash survives a failed seed build" 1 \
    "a file under ${OUT_DIR} still contains the hash"
else
  check "no password hash survives a failed seed build" 0
fi

# ---------------------------------------------------------------------------
# One cloud-config document for both flows
# ---------------------------------------------------------------------------
#
# The VM flow writes the admin account's seed onto an ISO; the bare-metal flow
# writes the same seed straight into the new deployment's /var. The cases above
# check the VM half's document line by line. The bare-metal half writes only on
# a real install, and every flow_baremetal case below except the seed-step
# section at the end is a dry run, so for a long time nothing read what it
# wrote. It used to write its own hand copy of the
# document, and dropping `groups: [wheel]` from that copy, or flipping its
# `lock_passwd`, failed no test anywhere: check-invariants compares
# docs/first-boot.md against every key the script prints, which a second copy
# satisfies on the first copy's behalf.
#
# So both flows print the document through one function, and these cases hold
# that shape: the function's output is what the VM seed contains, each flow
# calls it, and the script prints no second `#cloud-config` of its own.

# Run a few lines against the sourced script without the stubs or DRY_RUN the
# other helpers set up; these cases only read what it defines.
run_sourced() {
  # shellcheck disable=SC2016
  OUT="$("${BASH}" -c 'source "$1" 2>/dev/null; shift; eval "$1"' _ "${QUICKSTART}" "$1" 2>&1)"
  STATUS=$?
}

run_sourced "cloud_config_user_data tester '${FIXTURE_HASH}' '${FIXTURE_KEY}'"
assert_status "the shared cloud-config document can be printed on its own" 0 "${STATUS}"
shared_doc="${OUT}"

new_case
iso="${OUT_DIR}/seed.iso"
run_seed "${OUT_DIR}" tester "${FIXTURE_HASH}" "${FIXTURE_KEY}" "${iso}"
assert_equals "the VM seed's user-data is exactly the shared cloud-config document" \
  "${shared_doc}" "$(probe_file user-data)"

run_sourced 'declare -f make_seed_iso'
# shellcheck disable=SC2016  # the function's source text, not an expansion
assert_contains "make_seed_iso writes user-data from the shared document" \
  "${OUT}" 'cloud_config_user_data "${username}" "${pwhash}" "${sshkey}" > "${seeddir}/user-data"'

run_sourced 'declare -f flow_baremetal'
# shellcheck disable=SC2016  # the function's source text, not an expansion
assert_contains "flow_baremetal seeds the new deployment from the shared document" \
  "${OUT}" 'cloud_config_user_data "${ADMIN_USER}" "${ADMIN_HASH}" "${ADMIN_SSHKEY}" | sudo tee "${deploy}/var/lib/cloud/seed/nocloud/user-data"'
assert_absent "flow_baremetal prints no cloud-config document of its own" "${OUT}" "#cloud-config"

assert_equals "scripts/quickstart.sh prints exactly one cloud-config document" \
  "1" "$(grep -c "printf '#cloud-config" -- "${QUICKSTART}")"

# ---------------------------------------------------------------------------
# cleanup_task_resources
# ---------------------------------------------------------------------------
#
# The EXIT handler. Both of its guards are evaluated on every run of the
# script, so they look covered; every branch that actually does something is
# unreached, because the two directories it removes are only ever set part-way
# through a real install or a real seed build.
#
# Its contract is narrow and easy to break silently: remove exactly the two
# staged files and the two directories this invocation created, warn rather
# than fail when a removal does not work -- it runs while the script is already
# exiting, often for an unrelated reason, and turning a stuck mount into a
# second failure would replace the original one -- and never touch anything
# else.

run_cleanup() {
  # shellcheck disable=SC2016
  OUT="$(
    PATH="${STUB_DIR}:${PATH}" STUB_CALL_LOG="${SEED_PROBE}/calls" "${BASH}" -c '
      source "$1" 2>/dev/null
      BAREMETAL_MOUNT_DIR="${SEED_MOUNT_DIR:-}"
      SEED_STAGING_DIR="${SEED_STAGE_DIR:-}"
      cleanup_task_resources
    ' _ "${QUICKSTART}" 2>&1
  )"
  STATUS=$?
}
cleanup_calls() { cat -- "${SEED_PROBE}/calls" 2>/dev/null; }

new_case
mount_dir="${OUT_DIR}/mnt"
mkdir -p "${mount_dir}"
SEED_MOUNT_DIR="${mount_dir}" run_cleanup
assert_status "the handler succeeds after unmounting a mounted target" 0 "${STATUS}"
assert_contains "the mount state of the target directory is checked" \
  "$(cleanup_calls)" "mountpoint -q -- ${mount_dir}"
assert_contains "a mounted target is unmounted with privilege" \
  "$(cleanup_calls)" "sudo umount -- ${mount_dir}"
if [[ -d "${mount_dir}" ]]; then
  check "the temporary mount directory is removed" 1 "${mount_dir} still exists"
else
  check "the temporary mount directory is removed" 0
fi

new_case
mount_dir="${OUT_DIR}/mnt"
mkdir -p "${mount_dir}"
SEED_MOUNT_DIR="${mount_dir}" STUB_MOUNTPOINT_RC=1 run_cleanup
assert_status "the handler succeeds when the target was never mounted" 0 "${STATUS}"
assert_absent "an unmounted directory is not unmounted again" "$(cleanup_calls)" "umount"
if [[ -d "${mount_dir}" ]]; then
  check "an unmounted temporary directory is still removed" 1 "${mount_dir} still exists"
else
  check "an unmounted temporary directory is still removed" 0
fi

new_case
mount_dir="${OUT_DIR}/mnt"
mkdir -p "${mount_dir}"
SEED_MOUNT_DIR="${mount_dir}" STUB_SUDO_RC=1 run_cleanup
assert_status "a failed unmount does not fail the handler" 0 "${STATUS}"
assert_contains "a failed unmount is reported with the directory to check" \
  "${OUT}" "could not unmount ${mount_dir}"

# A mount directory that will not rmdir: something is still inside it, which is
# exactly when it has to be named rather than silently left or forced away.
new_case
mount_dir="${OUT_DIR}/mnt"
mkdir -p "${mount_dir}"
: >"${mount_dir}/unexpected"
SEED_MOUNT_DIR="${mount_dir}" STUB_MOUNTPOINT_RC=1 run_cleanup
assert_status "an unremovable mount directory does not fail the handler" 0 "${STATUS}"
assert_contains "an unremovable mount directory is named" \
  "${OUT}" "temporary mount directory remains: ${mount_dir}"
if [[ -e "${mount_dir}/unexpected" ]]; then
  check "the handler does not delete unexpected contents to force the removal" 0
else
  check "the handler does not delete unexpected contents to force the removal" 1 \
    "the file inside ${mount_dir} was removed"
fi

new_case
stage_dir="${OUT_DIR}/.arch-bootc-seed.fixture"
mkdir -p "${stage_dir}"
printf 'passwd: %s\n' "${FIXTURE_HASH}" >"${stage_dir}/user-data"
: >"${stage_dir}/meta-data"
SEED_STAGE_DIR="${stage_dir}" run_cleanup
assert_status "the handler succeeds after clearing a staging directory" 0 "${STATUS}"
if [[ -d "${stage_dir}" ]]; then
  check "an abandoned staging directory is removed" 1 "${stage_dir} still exists"
else
  check "an abandoned staging directory is removed" 0
fi
if grep -rqs -- "STUBHASH" "${OUT_DIR}"; then
  check "an abandoned password hash is removed" 1 "the hash is still under ${OUT_DIR}"
else
  check "an abandoned password hash is removed" 0
fi

# A staging directory holding something the handler did not put there. It
# removes its own two files by name and leaves the rest, so the rmdir fails and
# the path is reported instead of the contents being deleted along with them.
new_case
stage_dir="${OUT_DIR}/.arch-bootc-seed.fixture"
mkdir -p "${stage_dir}"
printf 'passwd: %s\n' "${FIXTURE_HASH}" >"${stage_dir}/user-data"
: >"${stage_dir}/unexpected"
SEED_STAGE_DIR="${stage_dir}" run_cleanup
assert_status "an unremovable staging directory does not fail the handler" 0 "${STATUS}"
assert_contains "an unremovable staging directory is named" \
  "${OUT}" "temporary seed directory remains: ${stage_dir}"
if [[ -e "${stage_dir}/user-data" ]]; then
  check "the hash is removed even when the directory cannot be" 1 "user-data survived"
else
  check "the hash is removed even when the directory cannot be" 0
fi
if [[ -e "${stage_dir}/unexpected" ]]; then
  check "the handler removes only the two files it staged" 0
else
  check "the handler removes only the two files it staged" 1 \
    "a file the handler did not stage was removed"
fi

# Neither directory set -- the ordinary case on every successful run, where the
# handler has to do nothing at all rather than act on an empty path.
new_case
run_cleanup
assert_status "the handler succeeds with nothing to clean up" 0 "${STATUS}"
assert_equals "nothing is touched when no directory was staged" "" "$(cleanup_calls)"

# warn_if_selinux_enforcing: an install from an SELinux-enforcing host is
# unverified (the image ships no chcon, which bootc install uses there), so
# main warns before anything is pulled. Driven against a stand-in for
# /sys/fs/selinux/enforce, since the host's own answer is whatever it is.
run_selinux_warning() {
  # shellcheck disable=SC2016
  OUT="$(
    "${BASH}" -c '
      source "$1" 2>/dev/null
      SELINUX_ENFORCE_FILE="$2"
      warn_if_selinux_enforcing
    ' _ "${QUICKSTART}" "$1" 2>&1
  )"
  STATUS=$?
}

new_case
printf '1\n' >"${OUT_DIR}/enforce"
run_selinux_warning "${OUT_DIR}/enforce"
assert_status "an enforcing host is warned, not refused" 0 "${STATUS}"
assert_contains "the warning says to install from a host without SELinux enforcing" "${OUT}" \
  "without SELinux enforcing"
assert_contains "the warning names chcon as the reason" "${OUT}" "chcon"

new_case
printf '0\n' >"${OUT_DIR}/enforce"
run_selinux_warning "${OUT_DIR}/enforce"
assert_status "a permissive host passes" 0 "${STATUS}"
assert_equals "a permissive host is not warned" "" "${OUT}"

new_case
run_selinux_warning "${OUT_DIR}/no-selinux-here"
assert_status "a host without SELinux passes" 0 "${STATUS}"
assert_equals "a host without SELinux is not warned" "" "${OUT}"

if grep -q '^    warn_if_selinux_enforcing$' "${QUICKSTART}"; then
  check "main runs the SELinux check" 0
else
  check "main runs the SELinux check" 1 "warn_if_selinux_enforcing is never called"
fi

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
  printf '1..%d\n' "${tests_run}"
  exit 1
fi

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

# ---------------------------------------------------------------------------
# flow_baremetal, DRY_RUN=0: the seed step
# ---------------------------------------------------------------------------
#
# Every flow_baremetal case above is a dry run, and a dry run prints one
# sentence where a real install seeds the first admin account. The block behind
# that sentence is the only part of the bare-metal path that runs after the
# disk has been erased: it reads the new partition table back, picks partition
# number 3, mounts it, finds the one deployment under /state/deploy, writes
# meta-data and user-data into that deployment's /var at mode 0600, and
# unmounts. Nothing ran any of it. Picking the wrong partition, writing the
# password hash at the default mode, seeding the wrong directory or leaving the
# disk mounted all exit 0 with the same transcript -- the first sign would be a
# machine whose admin account never appears.
#
# So the flow runs here with DRY_RUN=0, and the commands that would act on a
# real disk are replaced inside the subshell rather than on PATH:
#
#   - prepare_image and run only record that they were called. The pull and
#     the installer are not the subject, and run is how the installer command
#     reaches podman.
#   - sudo is a function. `sudo mount` lays out an installed root filesystem
#     (/state/deploy holding the deployments STUB_DEPLOYS names) inside the
#     directory the flow mounts on; `sudo umount` moves that tree out to the
#     case's probe directory, the way unmounting empties a mount point, so the
#     flow's own rmdir works and what it wrote can still be read afterwards.
#     Every other command sudo is given runs for real, inside that tree.
#   - mountpoint answers from the same state, so a refusal after the mount is
#     cleaned up by the real EXIT handler.
#
# `[ -b ]` is real here too, so partition 3 is a symlink to the block device
# token: a different name from the disk, so mounting the disk instead of the
# partition shows, and still a block device. It is never opened: mount is the
# function above, not mount(8).

# The deployment name an install produces: a checksum-like directory.
INSTALL_DEPLOY='0123abcd.0'

install_case_number=0
new_install_case() {
  install_case_number=$((install_case_number + 1))
  INSTALL_PROBE="${WORK_DIR}/install${install_case_number}"
  INSTALL_TMP="${INSTALL_PROBE}/tmp"
  INSTALL_LOG="${INSTALL_PROBE}/calls"
  mkdir -p "${INSTALL_TMP}"
  : >"${INSTALL_LOG}"
  export INSTALL_PROBE INSTALL_LOG
}
install_calls() { cat -- "${INSTALL_LOG}"; }
install_seed_dir() {
  printf '%s\n' "${INSTALL_PROBE}/rootfs/state/deploy/$1/var/lib/cloud/seed/nocloud"
}
# Every file the flow left in the installed tree, relative to its root.
install_written() {
  if [[ -d "${INSTALL_PROBE}/rootfs" ]]; then
    (cd -- "${INSTALL_PROBE}/rootfs" && find . -type f | sort | tr '\n' ' ')
  fi
}

run_install() {
  # shellcheck disable=SC2016
  OUT="$(
    PATH="${STUB_DIR}:${PATH}" HOME="${FLOW_HOME}" TMPDIR="${INSTALL_TMP}" "${BASH}" -c '
      source "$1" 2>/dev/null
      shift
      DRY_RUN=0
      # Wide open on purpose: a seed file left at the default mode would then
      # be readable by everyone, which is what the 0600 cases look for.
      umask 022
      running_system_disks() { printf "%s\n" "${STUB_SYSDISKS-}"; }
      prepare_image() { printf "prepare_image\n" >>"${INSTALL_LOG}"; }
      run() { printf "run %s\n" "$*" >>"${INSTALL_LOG}"; }
      mountpoint() { [ -e "${INSTALL_PROBE}/mounted" ]; }
      sudo() {
        printf "sudo %s\n" "$*" >>"${INSTALL_LOG}"
        local deployment
        case "$1" in
          mount)
            [ -n "${STUB_NO_DEPLOY_DIR:-}" ] || mkdir -p -- "$4/state/deploy"
            # Each deployment holds a tree of its own, as a real one does, so
            # a search that descended into it would find more than one.
            for deployment in ${STUB_DEPLOYS-}; do
              mkdir -p -- "$4/state/deploy/${deployment}/usr"
            done
            printf "%s\n" "$4" >"${INSTALL_PROBE}/mounted" ;;
          umount)
            mkdir -p -- "${INSTALL_PROBE}/rootfs"
            if [ -e "$3/state" ]; then
              mv -- "$3/state" "${INSTALL_PROBE}/rootfs/"
            fi
            rm -f -- "${INSTALL_PROBE}/mounted" ;;
          *) "$@" ;;
        esac
      }
      flow_baremetal
    ' _ "${QUICKSTART}" 2>&1
  )"
  STATUS=$?
}

INSTALL_ROOTPART="${WORK_DIR}/fixture-part3"
ln -s -- "${BLOCK_TOKEN}" "${INSTALL_ROOTPART}"

# A partition table with partition number 3 among others, out of order, so
# taking the first or the last line picks the wrong one, and with a partition
# 13, so matching the number as a substring finds two.
INSTALL_PARTS="/dev/fixture1 1
${INSTALL_ROOTPART} 3
/dev/fixture2 2
/dev/fixture13 13"

run_sourced "cloud_config_user_data tester '${FIXTURE_HASH}' ''"
install_doc="${OUT}"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="${INSTALL_PARTS}" STUB_DEPLOYS="${INSTALL_DEPLOY}" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
assert_status "a confirmed install completes" 0 "${STATUS}"
assert_contains "the install reports the deployment seeded" "${OUT}" \
  "cloud-init seeded into the fresh deployment's /var"
assert_contains "the install names the root partition it found" "${OUT}" \
  "root partition: ${INSTALL_ROOTPART}"
assert_absent "the password hash never reaches the transcript" "${OUT}" "STUBHASH"
mount_line="$(grep -m1 '^sudo mount ' "${INSTALL_LOG}")"
mount_dir="${mount_line##* }"
assert_equals "partition number 3 is the one mounted" \
  "sudo mount -- ${INSTALL_ROOTPART} ${mount_dir}" "${mount_line}"
assert_equals "the image is prepared, then installed, then the new disk mounted" \
  "prepare_image run sudo mount" \
  "$(grep -oE '^(prepare_image|run|sudo mount)' "${INSTALL_LOG}" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "the installer is run against the resolved disk" "$(install_calls)" \
  "bootc install to-disk --composefs-backend ${BLOCK_TOKEN}"
seed_dir="$(install_seed_dir "${INSTALL_DEPLOY}")"
assert_equals "only the deployment's NoCloud seed is written" \
  "./state/deploy/${INSTALL_DEPLOY}/var/lib/cloud/seed/nocloud/meta-data ./state/deploy/${INSTALL_DEPLOY}/var/lib/cloud/seed/nocloud/user-data " \
  "$(install_written)"
assert_equals "the seeded user-data is the shared cloud-config document" \
  "${install_doc}" "$(cat -- "${seed_dir}/user-data" 2>/dev/null)"
assert_equals "the seeded meta-data names the NoCloud instance" \
  "instance-id: arch-bootc-quickstart" "$(cat -- "${seed_dir}/meta-data" 2>/dev/null)"
assert_equals "the seeded user-data, which holds the hash, is 0600" \
  "600" "$(stat -c '%a' -- "${seed_dir}/user-data" 2>/dev/null)"
assert_equals "the seeded meta-data is 0600" \
  "600" "$(stat -c '%a' -- "${seed_dir}/meta-data" 2>/dev/null)"
assert_contains "the mount point is unmounted after seeding" "$(install_calls)" \
  "sudo umount -- ${mount_dir}"
assert_equals "the temporary mount point is removed" "" "$(ls -A -- "${INSTALL_TMP}")"

# Refusals before anything is mounted: the partition table cannot be read, or
# it does not hold exactly one partition number 3, or that partition is not a
# block device. Each must stop before mount, because every later step writes
# to whatever was mounted.
refuse_before_mount() {
  local description="$1" message="$2"
  assert_status "${description} is refused" 1 "${STATUS}"
  assert_contains "${description} is reported" "${OUT}" "${message}"
  assert_absent "${description} mounts nothing" "$(install_calls)" "sudo mount"
}

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS_FAIL=1 STUB_DEPLOYS="${INSTALL_DEPLOY}" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_before_mount "an unreadable new partition table" \
  "could not inspect the new partition table on ${BLOCK_TOKEN}"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="/dev/fixture1 1
/dev/fixture2 2" STUB_DEPLOYS="${INSTALL_DEPLOY}" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_before_mount "a table with no partition number 3" \
  "expected exactly one partition number 3 on ${BLOCK_TOKEN}"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="${INSTALL_PARTS}
/dev/fixture3 3" STUB_DEPLOYS="${INSTALL_DEPLOY}" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_before_mount "a table with two partitions number 3" \
  "expected exactly one partition number 3 on ${BLOCK_TOKEN}"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="/dev/fixture-missing 3" STUB_DEPLOYS="${INSTALL_DEPLOY}" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_before_mount "a partition number 3 that is not a block device" \
  "expected root partition /dev/fixture-missing not found after install"

# Refusals after the mount: the layout under /state/deploy is not the single
# deployment the seed path assumes. Nothing may be written -- guessing which
# deployment boots would seed the wrong one or none -- and the EXIT handler
# must still unmount the disk and remove the mount point.
refuse_after_mount() {
  local description="$1" message="$2"
  assert_status "${description} is refused" 1 "${STATUS}"
  assert_contains "${description} is reported" "${OUT}" "${message}"
  assert_equals "${description} writes no seed" "" "$(install_written)"
  assert_contains "${description} still unmounts the disk" "$(install_calls)" "sudo umount -- "
  assert_equals "${description} still removes the mount point" "" "$(ls -A -- "${INSTALL_TMP}")"
}

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="${INSTALL_PARTS}" STUB_DEPLOYS="" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_after_mount "a root filesystem with no deployment" \
  "expected exactly one deployment under ${INSTALL_ROOTPART}:/state/deploy"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="${INSTALL_PARTS}" STUB_DEPLOYS="${INSTALL_DEPLOY} 4567cdef.0" \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_after_mount "a root filesystem with two deployments" \
  "expected exactly one deployment under ${INSTALL_ROOTPART}:/state/deploy"

new_install_case
STUB_SYSDISKS="" STUB_MOUNTS="" STUB_SIGS="" \
  STUB_RESOLVED="${BLOCK_TOKEN}" STUB_IDENTITY="${IDENTITY}" \
  STUB_PARTS="${INSTALL_PARTS}" STUB_NO_DEPLOY_DIR=1 \
  run_install <<<"$(baremetal_answers "${BLOCK_TOKEN}" "${BLOCK_TOKEN}" ERASE)"
refuse_after_mount "a root filesystem with no /state/deploy" \
  "could not inspect deployments under ${INSTALL_ROOTPART}:/state/deploy"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

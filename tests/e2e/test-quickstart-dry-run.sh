#!/usr/bin/env bash
set -uo pipefail

# Exercise the complete VM path through quickstart in --dry-run mode. Commands
# that would mutate images, files, or libvirt are shadowed with failing stubs;
# the test therefore fails if dry-run ever invokes one instead of only printing
# it. Read-only host probes get deterministic fixture responses.
#
# The second half drives the refusals on that same path. Every guard between
# argument parsing and the final confirmation is supposed to stop the run --
# malformed input, an occupied VM name, an unreadable libvirt connection, a
# RAM-backed output directory, a declined overwrite. A guard that stops nothing
# still exits 0 and still prints a plausible transcript, so each case asserts
# the refusal message, the non-zero status, and that nothing was mutated on the
# way out. All of it runs across the real process boundary, and that is the
# point of this file rather than a limitation of it: these are the paths a user
# reaches by typing at the prompts, so driving the script as a process is what
# makes the evidence mean anything -- argument parsing, the prompt sequence and
# the traps are all in scope. quickstart.sh does have a sourcing guard now, but
# it exists for tests/test-quickstart-baremetal.sh, which needs to call the
# bare-metal guards directly because `[ -b ]` cannot be reached through the
# prompts here.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
QUICKSTART="${REPO_ROOT}/scripts/quickstart.sh"

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
  local desc="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then
    pass "${desc}"
  else
    fail "${desc}${*:+: $*}"
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

assert_lacks() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output unexpectedly contained '${needle}'"
  fi
}

assert_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "unexpected path ${path}"
  fi
}

assert_present() {
  local desc="$1" path="$2"
  if [[ -e "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "missing path ${path}"
  fi
}

# A refusal must exit non-zero. Asserting only the message would pass on a
# guard that prints its complaint and carries on into the install.
assert_refused() {
  local desc="$1" status="$2"
  if [[ "${status}" != "0" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "exited 0"
  fi
}

write_stub() {
  local dir="$1" name="$2" body="$3"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

MUTATION_LOG="${WORK_DIR}/mutations.log"

# Populate a stub directory with the standard fixture behaviour: every mutating
# command fails loudly, and the read-only probes report no pre-existing VM or
# pool and a disk-backed output filesystem. Individual cases overwrite one stub
# afterwards to drive the guard they are about.
make_stubs() {
  local dir="$1" command_name
  mkdir -p "${dir}"
  # These commands must never execute during a dry run. If one does, record it
  # and fail immediately rather than touching the host.
  for command_name in sudo podman truncate qemu-img virt-install xorriso losetup install; do
    # Deliberately expand these variables when the generated stub runs.
    # shellcheck disable=SC2016
    write_stub "${dir}" "${command_name}" \
      'printf "%s\\n" "${0##*/} $*" >>"${QUICKSTART_MUTATION_LOG}"; exit 97'
  done
  write_stub "${dir}" virsh 'exit 0'
  write_stub "${dir}" findmnt 'printf "%s\\n" ext4'
  # Deliberately return a literal fixture hash from the generated stub.
  # shellcheck disable=SC2016
  write_stub "${dir}" openssl 'printf "%s\\n" "\$6\$fixture-hash"'
}

# new_case <slug> -- print a fresh per-case directory holding bin/, home/ and
# out/. Cases never share these, so a stub override or a fixture file left in
# one cannot reach another.
new_case() {
  local dir="${WORK_DIR}/case-$1"
  make_stubs "${dir}/bin"
  mkdir -p "${dir}/home" "${dir}/out"
  printf '%s\n' "${dir}"
}

# run_quickstart <stub-dir> <home-dir> <input> [argument...] -- run the script
# as a process and leave its combined output in QS_OUTPUT and its exit status
# in QS_STATUS. With no arguments it runs --dry-run.
#
# Setting QS_PATH for one call replaces the whole PATH rather than prefixing
# the stub directory to the caller's. Prefixing can only add commands, so it
# cannot drive a guard that fires on an *absent* one: the host's own copy would
# still be found further down the PATH.
run_quickstart() {
  local stub_dir="$1" home_dir="$2" input="$3"
  shift 3
  local -a arguments=("$@")
  ((${#arguments[@]})) || arguments=(--dry-run)
  QS_OUTPUT="$(
    PATH="${QS_PATH:-${stub_dir}:${PATH}}" \
    HOME="${home_dir}" \
    USER="fixtureadmin" \
    QUICKSTART_MUTATION_LOG="${MUTATION_LOG}" \
      "${QUICKSTART}" "${arguments[@]}" <<<"${input}" 2>&1
  )"
  QS_STATUS=$?
}

# vm_input <admin> <vm-name> <disk> <memory> <vcpus> <work-dir> [answer...]
# Answers the published-image KDE VM path: the four leading blanks take the
# defaults for the target, image source, flavor and registry prompts. Trailing
# answers cover the overwrite and Proceed confirmations, which vary by case.
vm_input() {
  local admin="$1" vm="$2" disk="$3" memory="$4" vcpus="$5" work_dir="$6" answer
  shift 6
  printf '\n\n\n\n%s\nfixture-password\nfixture-password\n%s\n%s\n%s\n%s\n%s\n' \
    "${admin}" "${vm}" "${disk}" "${memory}" "${vcpus}" "${work_dir}"
  for answer in "$@"; do
    printf '%s\n' "${answer}"
  done
}

# --------------------------------------------------- the complete VM path ---

happy="$(new_case happy)"
OUTPUT_DIR="${happy}/would-be-output"
run_quickstart "${happy}/bin" "${happy}/home" \
  "$(vm_input fixtureadmin acmm-e2e-vm '' '' '' "${OUTPUT_DIR}" y)"
output="${QS_OUTPUT}"
status="${QS_STATUS}"

check "VM dry run exits zero" "${status}" "${output}"
assert_contains "published KDE image is selected" "${output}" \
  "image: ghcr.io/danathar/arch-bootc-kde:latest"
assert_contains "both libvirt connections are inventoried" "${output}" \
  "VM name 'acmm-e2e-vm' is free on both libvirt connections"
assert_contains "image pull is printed" "${output}" \
  '$ sudo podman pull ghcr.io/danathar/arch-bootc-kde:latest'
assert_contains "disk creation is printed" "${output}" \
  '$ truncate -s 100G'
assert_contains "installer keeps the loopback boundary" "${output}" \
  'bootc install to-disk --composefs-backend --via-loopback'
assert_contains "raw disk conversion is printed" "${output}" \
  '$ qemu-img convert -f raw -O qcow2 -S 4k'
assert_contains "cloud-init ISO creation is printed" "${output}" \
  '$ xorriso -as mkisofs'
assert_contains "VM creation stays on the user connection" "${output}" \
  '$ virt-install --connect qemu:///session'
assert_contains "completion states that nothing changed" "${output}" \
  "dry run complete; VM 'acmm-e2e-vm' was not created and no files were changed"

assert_absent "dry run creates no output directory" "${OUTPUT_DIR}"

# ------------------------------------------------------ argument handling ---

help_case="$(new_case help)"
run_quickstart "${help_case}/bin" "${help_case}/home" '' --help
check "--help exits zero" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "--help prints the usage block" "${QS_OUTPUT}" \
  'Usage: scripts/quickstart.sh [--dry-run] [--help]'
assert_lacks "--help asks nothing" "${QS_OUTPUT}" 'What are we installing to?'

bad_arg="$(new_case bad-arg)"
run_quickstart "${bad_arg}/bin" "${bad_arg}/home" '' --nope
assert_refused "an unknown argument is refused" "${QS_STATUS}"
assert_contains "the unknown argument is named" "${QS_OUTPUT}" \
  'unknown argument: --nope'
assert_contains "usage accompanies the refusal" "${QS_OUTPUT}" \
  'Usage: scripts/quickstart.sh [--dry-run] [--help]'

# ------------------------------------------------------- menus and retries ---

retry="$(new_case retry)"
run_quickstart "${retry}/bin" "${retry}/home" \
  "$(printf '9\n\n\n\n\nfixtureadmin\nfixture-password\nfixture-password\nqs-retry\n\n\n\n%s\ny\n' \
    "${retry}/out")"
check "an out-of-range menu choice is re-prompted, not accepted" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the menu states its valid range" "${QS_OUTPUT}" \
  'enter a number between 1 and 2'

mismatch="$(new_case pw-mismatch)"
run_quickstart "${mismatch}/bin" "${mismatch}/home" \
  "$(printf '\n\n\n\nfixtureadmin\nfirst\nsecond\nfixture-password\nfixture-password\nqs-mismatch\n\n\n\n%s\ny\n' \
    "${mismatch}/out")"
check "a mismatched password is re-prompted, not accepted" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the mismatch is reported" "${QS_OUTPUT}" \
  'they did not match, try again'

# ---------------------------------------------------- image source choices ---

local_image="$(new_case local-image)"
run_quickstart "${local_image}/bin" "${local_image}/home" \
  "$(printf '\n2\n2\nfixtureadmin\nfixture-password\nfixture-password\nqs-local\n\n\n\n%s\ny\n' \
    "${local_image}/out")"
check "the locally built image path completes" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the xfce local tag carries its flavor suffix" "${QS_OUTPUT}" \
  'image: localhost/arch-bootc-xfce:latest'
assert_lacks "a locally built image is never pulled" "${QS_OUTPUT}" \
  'podman pull'

# kde is the flavor the plain `just build-containerfile` recipe produces, so it
# is the one local tag that carries no flavor suffix. Naming it
# `localhost/arch-bootc-kde:latest` by symmetry with the other two would send
# the operator to an image that was never built.
local_kde="$(new_case local-kde)"
run_quickstart "${local_kde}/bin" "${local_kde}/home" \
  "$(printf '\n2\n\nfixtureadmin\nfixture-password\nfixture-password\nqs-local-kde\n\n\n\n%s\ny\n' \
    "${local_kde}/out")"
check "the locally built kde image path completes" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the local kde tag drops the flavor suffix" "${QS_OUTPUT}" \
  'image: localhost/arch-bootc:latest'
assert_lacks "the local kde tag is not built by flavor symmetry" "${QS_OUTPUT}" \
  'localhost/arch-bootc-kde:latest'
assert_lacks "a locally built kde image is never pulled" "${QS_OUTPUT}" \
  'podman pull'

# ------------------------------------------------------- host tool probes ---

# find_iso_tool refuses a host with none of the three seed-ISO builders. The
# refusal is only reachable on a PATH that really lacks all three, so this case
# replaces the PATH outright instead of prefixing the stub directory: the stubs
# still answer every `need_cmd` probe ahead of it, and none of them is executed
# because the script dies before it runs an external command. quickstart's own
# `#!/usr/bin/env bash` resolves through that PATH too, so the interpreter
# running this suite has to be reachable on it.
no_iso="$(new_case no-iso)"
rm -f -- "${no_iso}/bin/xorriso"
for probe in realpath mktemp basename; do
  write_stub "${no_iso}/bin" "${probe}" 'exit 0'
done
ln -sf -- "${BASH}" "${no_iso}/bin/bash"
QS_PATH="${no_iso}/bin" \
  run_quickstart "${no_iso}/bin" "${no_iso}/home" ''
assert_refused "a host with no seed-ISO builder is refused" "${QS_STATUS}"
assert_contains "the three accepted ISO tools are named" "${QS_OUTPUT}" \
  'need one of xorriso, genisoimage or mkisofs'
assert_contains "the refusal says how to install one" "${QS_OUTPUT}" \
  "sudo pacman -S libisoburn"
assert_lacks "the run stops before asking for an image" "${QS_OUTPUT}" \
  'Which image?'

# --------------------------------------------------- admin user validation ---

bad_user="$(new_case bad-user)"
run_quickstart "${bad_user}/bin" "${bad_user}/home" \
  "$(vm_input 'Bad User' qs-bad-user '' '' '' "${bad_user}/out" y)"
assert_refused "an invalid username is refused" "${QS_STATUS}"
assert_contains "the invalid username is named" "${QS_OUTPUT}" \
  "'Bad User' is not a valid Linux username."

long_user="$(new_case long-user)"
run_quickstart "${long_user}/bin" "${long_user}/home" \
  "$(vm_input 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' qs-long-user '' '' '' "${long_user}/out" y)"
assert_refused "a 33-character username is refused" "${QS_STATUS}"
assert_contains "the length limit is stated" "${QS_OUTPUT}" \
  'Linux usernames must be 32 characters or fewer.'

# ------------------------------------------------------- SSH key handling ---

# The seeded key is only offered when one of the two known public-key files
# exists, so each of these cases plants exactly one and answers the extra
# confirmation the offer inserts after the password prompts.
ssh_input() {
  printf '\n\n\n\nfixtureadmin\nfixture-password\nfixture-password\ny\n%s\n\n\n\n%s\ny\n' "$1" "$2"
}

bad_key_type="$(new_case bad-key-type)"
mkdir -p "${bad_key_type}/home/.ssh"
printf 'notakey AAAAC3NzaC1lZDI1NTE5 fixture@example\n' \
  >"${bad_key_type}/home/.ssh/id_ed25519.pub"
run_quickstart "${bad_key_type}/bin" "${bad_key_type}/home" \
  "$(ssh_input qs-bad-key-type "${bad_key_type}/out")"
assert_refused "an unrecognized public-key type is refused" "${QS_STATUS}"
assert_contains "the key type refusal names the file" "${QS_OUTPUT}" \
  "${bad_key_type}/home/.ssh/id_ed25519.pub does not start with a recognized OpenSSH public-key type"

bad_key_blob="$(new_case bad-key-blob)"
mkdir -p "${bad_key_blob}/home/.ssh"
printf 'ssh-ed25519 not;base64;at;all fixture@example\n' \
  >"${bad_key_blob}/home/.ssh/id_ed25519.pub"
run_quickstart "${bad_key_blob}/bin" "${bad_key_blob}/home" \
  "$(ssh_input qs-bad-key-blob "${bad_key_blob}/out")"
assert_refused "a non-base64 key payload is refused" "${QS_STATUS}"
assert_contains "the payload refusal names the file" "${QS_OUTPUT}" \
  "${bad_key_blob}/home/.ssh/id_ed25519.pub does not contain a valid public-key payload"

good_key="$(new_case good-key)"
mkdir -p "${good_key}/home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyMaterial fixture@example\n' \
  >"${good_key}/home/.ssh/id_ed25519.pub"
run_quickstart "${good_key}/bin" "${good_key}/home" \
  "$(ssh_input qs-good-key "${good_key}/out")"
check "a valid ed25519 key is accepted" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the accepted key is reported against the admin user" "${QS_OUTPUT}" \
  'SSH key will be installed for fixtureadmin'

# The RSA file is the fallback, reached only when no ed25519 key exists. A host
# whose only key is `id_rsa.pub` would otherwise get a VM with no key in it and
# nothing said about why.
rsa_key="$(new_case rsa-key)"
mkdir -p "${rsa_key}/home/.ssh"
printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABFixtureKeyMaterial fixture@example\n' \
  >"${rsa_key}/home/.ssh/id_rsa.pub"
run_quickstart "${rsa_key}/bin" "${rsa_key}/home" \
  "$(ssh_input qs-rsa-key "${rsa_key}/out")"
check "an rsa key is found when no ed25519 key exists" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the accepted rsa key is reported against the admin user" "${QS_OUTPUT}" \
  'SSH key will be installed for fixtureadmin'

# Which file the fallback picked is not stated on the accepting path -- the
# prompts themselves are invisible here, because bash prints a `read -p` prompt
# only to a terminal. A rejected key does name its file, so an unusable
# `id_rsa.pub` is what pins the fallback to that exact path rather than to some
# other key the run might have found.
rsa_key_blob="$(new_case rsa-key-blob)"
mkdir -p "${rsa_key_blob}/home/.ssh"
printf 'ssh-rsa not;base64;at;all fixture@example\n' \
  >"${rsa_key_blob}/home/.ssh/id_rsa.pub"
run_quickstart "${rsa_key_blob}/bin" "${rsa_key_blob}/home" \
  "$(ssh_input qs-rsa-key-blob "${rsa_key_blob}/out")"
assert_refused "an unusable rsa key is refused" "${QS_STATUS}"
assert_contains "the refusal names the rsa file the fallback selected" "${QS_OUTPUT}" \
  "${rsa_key_blob}/home/.ssh/id_rsa.pub does not contain a valid public-key payload"

# -------------------------------------------------------- VM name and slot ---

bad_vm_name="$(new_case bad-vm-name)"
run_quickstart "${bad_vm_name}/bin" "${bad_vm_name}/home" \
  "$(vm_input fixtureadmin -leading-hyphen '' '' '' "${bad_vm_name}/out" y)"
assert_refused "an unsafe VM name is refused" "${QS_STATUS}"
assert_contains "the VM name rule is stated" "${QS_OUTPUT}" \
  "'-leading-hyphen' is not a safe single-label VM name/hostname."

taken_vm="$(new_case taken-vm)"
write_stub "${taken_vm}/bin" virsh 'printf "%s\\n" qs-taken'
run_quickstart "${taken_vm}/bin" "${taken_vm}/home" \
  "$(vm_input fixtureadmin qs-taken '' '' '' "${taken_vm}/out" y)"
assert_refused "an already-defined VM name is refused" "${QS_STATUS}"
assert_contains "the occupied connection is named" "${QS_OUTPUT}" \
  "a VM named 'qs-taken' already exists on qemu:///session"
assert_contains "the refusal states it never redefines a VM" "${QS_OUTPUT}" \
  'This script never destroys or redefines an existing VM.'

# An unreadable connection must not be read as an empty one: that is the
# difference between "no VM by that name" and "no answer".
blind_virsh="$(new_case blind-virsh)"
write_stub "${blind_virsh}/bin" virsh 'exit 3'
run_quickstart "${blind_virsh}/bin" "${blind_virsh}/home" \
  "$(vm_input fixtureadmin qs-blind '' '' '' "${blind_virsh}/out" y)"
assert_refused "an unreadable libvirt connection is refused" "${QS_STATUS}"
assert_contains "the unreadable connection is named" "${QS_OUTPUT}" \
  'could not inventory VMs on qemu:///session'
assert_contains "an unreadable connection is not treated as empty" "${QS_OUTPUT}" \
  'Refusing to treat an unreadable connection as empty'

# The pool inventory is a separate `virsh` call from the VM-name one, and it is
# what the run compares against afterwards to name any storage pool
# `virt-install` created as a side effect. An unreadable inventory has to stop
# the run for the same reason an unreadable VM list does: an empty answer and
# no answer are not the same, and treating them alike would report "no new
# pool" about a host that was never asked.
blind_pools="$(new_case blind-pools)"
# Deliberately keep "$*" unexpanded: the generated stub inspects its own
# arguments so only the pool inventory fails, leaving the VM-name lookup that
# runs earlier in the flow answering normally.
# shellcheck disable=SC2016
write_stub "${blind_pools}/bin" virsh 'case "$*" in *pool-list*) exit 4 ;; esac; exit 0'
run_quickstart "${blind_pools}/bin" "${blind_pools}/home" \
  "$(vm_input fixtureadmin qs-blind-pools '' '' '' "${blind_pools}/out" y)"
assert_refused "an unreadable storage pool inventory is refused" "${QS_STATUS}"
assert_contains "the unreadable pool connection is named" "${QS_OUTPUT}" \
  'could not inventory storage pools on qemu:///session'
assert_lacks "no pool report is printed for an inventory that never answered" \
  "${QS_OUTPUT}" 'No new qemu:///session storage pool was detected'

# ------------------------------------------------------ VM sizing validation ---

bad_disk="$(new_case bad-disk)"
run_quickstart "${bad_disk}/bin" "${bad_disk}/home" \
  "$(vm_input fixtureadmin qs-bad-disk 0G '' '' "${bad_disk}/out" y)"
assert_refused "a zero disk size is refused" "${QS_STATUS}"
assert_contains "the disk size rule is stated" "${QS_OUTPUT}" \
  'disk size must be a positive integer with an optional K/M/G/T/P/E suffix'

bad_memory="$(new_case bad-memory)"
run_quickstart "${bad_memory}/bin" "${bad_memory}/home" \
  "$(vm_input fixtureadmin qs-bad-memory '' plenty '' "${bad_memory}/out" y)"
assert_refused "a non-numeric memory size is refused" "${QS_STATUS}"
assert_contains "the memory rule is stated" "${QS_OUTPUT}" \
  'memory must be a positive number of MiB'

bad_vcpus="$(new_case bad-vcpus)"
run_quickstart "${bad_vcpus}/bin" "${bad_vcpus}/home" \
  "$(vm_input fixtureadmin qs-bad-vcpus '' '' 0 "${bad_vcpus}/out" y)"
assert_refused "a zero vCPU count is refused" "${QS_STATUS}"
assert_contains "the vCPU rule is stated" "${QS_OUTPUT}" \
  'vCPUs must be a positive integer'

# ------------------------------------------------------ output directory ---

# A multi-gigabyte qcow2 on tmpfs is host RAM, which is why this check exists
# at all rather than letting the disk image land wherever it was asked to.
ram_dir="$(new_case ram-dir)"
write_stub "${ram_dir}/bin" findmnt 'printf "%s\\n" tmpfs'
ram_output="${ram_dir}/would-be-output"
run_quickstart "${ram_dir}/bin" "${ram_dir}/home" \
  "$(vm_input fixtureadmin qs-ram-dir '' '' '' "${ram_output}" y)"
assert_refused "a RAM-backed output directory is refused" "${QS_STATUS}"
assert_contains "the RAM-backed filesystem is named" "${QS_OUTPUT}" \
  "${ram_output} is on tmpfs (RAM)"
assert_absent "the refused output directory is not created" "${ram_output}"

blind_findmnt="$(new_case blind-findmnt)"
write_stub "${blind_findmnt}/bin" findmnt 'exit 1'
blind_output="${blind_findmnt}/would-be-output"
run_quickstart "${blind_findmnt}/bin" "${blind_findmnt}/home" \
  "$(vm_input fixtureadmin qs-blind-findmnt '' '' '' "${blind_output}" y)"
assert_refused "an undeterminable output filesystem is refused" "${QS_STATUS}"
assert_contains "the undeterminable filesystem is named" "${QS_OUTPUT}" \
  "could not determine the filesystem behind ${blind_output}"
assert_absent "no directory is created for an undeterminable filesystem" "${blind_output}"

# ------------------------------------------------ existing output handling ---

# quickstart resolves the directory it was given before naming the outputs
# inside it, so the expected paths are resolved here too rather than assuming
# the temporary directory contains no symlink.
not_a_file="$(new_case not-a-file)"
not_a_file_raw="$(realpath -m -- "${not_a_file}/out")/qs-not-a-file.raw"
mkdir -p "${not_a_file}/out/qs-not-a-file.raw"
run_quickstart "${not_a_file}/bin" "${not_a_file}/home" \
  "$(vm_input fixtureadmin qs-not-a-file '' '' '' "${not_a_file}/out" y)"
assert_refused "a directory in an output path is refused" "${QS_STATUS}"
assert_contains "the non-file output path is named" "${QS_OUTPUT}" \
  "refusing to replace non-file output path: ${not_a_file_raw}"
assert_present "the directory standing in an output path survives" \
  "${not_a_file}/out/qs-not-a-file.raw"

declined="$(new_case declined-overwrite)"
printf 'pre-existing\n' >"${declined}/out/qs-declined.raw"
run_quickstart "${declined}/bin" "${declined}/home" \
  "$(vm_input fixtureadmin qs-declined '' '' '' "${declined}/out" n)"
assert_refused "a declined overwrite aborts" "${QS_STATUS}"
# Consent is collected before the summary, so declining it has to stop there:
# reaching the summary would mean the answer was read and then ignored.
assert_lacks "a declined overwrite stops before the summary" "${QS_OUTPUT}" \
  'the following existing outputs will be replaced'
assert_contains "the abort states nothing was changed" "${QS_OUTPUT}" \
  'aborted; nothing was changed.'
assert_present "a declined overwrite leaves the existing output in place" \
  "${declined}/out/qs-declined.raw"

# Consent to overwrite is collected early but must not act until the final
# confirmation, so declining that one has to leave the file alone too.
late_abort="$(new_case late-abort)"
printf 'pre-existing\n' >"${late_abort}/out/qs-late-abort.raw"
run_quickstart "${late_abort}/bin" "${late_abort}/home" \
  "$(vm_input fixtureadmin qs-late-abort '' '' '' "${late_abort}/out" y n)"
assert_refused "declining the final confirmation aborts" "${QS_STATUS}"
assert_contains "the summary warns before replacing anything" "${QS_OUTPUT}" \
  'the following existing outputs will be replaced only after final confirmation'
assert_contains "the late abort states nothing was changed" "${QS_OUTPUT}" \
  'aborted; nothing was changed.'
assert_present "an abort after consenting to overwrite still keeps the file" \
  "${late_abort}/out/qs-late-abort.raw"

# The other half of that contract: once both answers are yes, the removal has
# to actually be sequenced -- after the final confirmation, and still only
# printed while the run is dry. Every existing overwrite case ends in a
# refusal, so nothing so far executes the loop that removes the replaced
# outputs at all.
#
# The planted files are the qcow2 and the seed ISO rather than the raw image:
# the run removes the raw one of its own accord after converting it, so a `rm`
# naming that path would pass whether the replacement loop ran or not.
accepted="$(new_case accepted-overwrite)"
accepted_out="$(realpath -m -- "${accepted}/out")"
printf 'pre-existing\n' >"${accepted}/out/qs-accepted.qcow2"
printf 'pre-existing\n' >"${accepted}/out/qs-accepted-seed.iso"
run_quickstart "${accepted}/bin" "${accepted}/home" \
  "$(vm_input fixtureadmin qs-accepted '' '' '' "${accepted}/out" y y y)"
check "consenting to the overwrite and proceeding completes" "${QS_STATUS}" "${QS_OUTPUT}"
assert_contains "the replaced outputs are listed in the summary" "${QS_OUTPUT}" \
  'the following existing outputs will be replaced only after final confirmation'
assert_contains "the replaced qcow2 is removed" "${QS_OUTPUT}" \
  "\$ rm -f -- ${accepted_out}/qs-accepted.qcow2"
assert_contains "every consented output is removed, not just the first" "${QS_OUTPUT}" \
  "\$ rm -f -- ${accepted_out}/qs-accepted-seed.iso"
assert_present "a dry run prints the qcow2 removal instead of performing it" \
  "${accepted}/out/qs-accepted.qcow2"
assert_present "a dry run prints the seed removal instead of performing it" \
  "${accepted}/out/qs-accepted-seed.iso"
# Ordering, not just presence: consent is collected long before the summary, so
# a removal printed ahead of it would mean the run acts on an answer while the
# operator can still abort with everything intact. The summary is the last
# thing printed before the final confirmation, which is itself invisible here
# because bash prints a `read -p` prompt only to a terminal.
assert_contains "the removal is sequenced after the summary" \
  "${QS_OUTPUT%%\$ rm -f --*}" \
  'the following existing outputs will be replaced only after final confirmation'

# ---------------------------------------------------------------------------

# One log across every case above: no dry run, completed or refused, may reach
# a mutating command.
if [[ -s "${MUTATION_LOG}" ]]; then
  check "no dry run executes a mutating command" 1 "$(<"${MUTATION_LOG}")"
else
  check "no dry run executes a mutating command" 0
fi

printf '\n1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'all %d assertions passed\n' "${tests_run}"

#!/usr/bin/env bash
set -uo pipefail

# Exercise the complete VM path through quickstart in --dry-run mode. Commands
# that would mutate images, files, or libvirt are shadowed with failing stubs;
# the test therefore fails if dry-run ever invokes one instead of only printing
# it. Read-only host probes get deterministic fixture responses.

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

assert_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "unexpected path ${path}"
  fi
}

write_stub() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${STUB_DIR}/${name}"
  chmod +x "${STUB_DIR}/${name}"
}

STUB_DIR="${WORK_DIR}/bin"
mkdir -p "${STUB_DIR}"
MUTATION_LOG="${WORK_DIR}/mutations.log"

# These commands must never execute during a dry run. If one does, record it
# and fail immediately rather than touching the host.
for command_name in sudo podman truncate qemu-img virt-install xorriso losetup install; do
  # Deliberately expand these variables when the generated stub runs.
  # shellcheck disable=SC2016
  write_stub "${command_name}" \
    'printf "%s\\n" "${0##*/} $*" >>"${QUICKSTART_MUTATION_LOG}"; exit 97'
done

# Deterministic read-only probes: no pre-existing VM or pool, and the proposed
# output directory sits on a disk-backed filesystem.
write_stub virsh 'exit 0'
write_stub findmnt 'printf "%s\\n" ext4'
# Deliberately return a literal fixture hash from the generated stub.
# shellcheck disable=SC2016
write_stub openssl 'printf "%s\\n" "\$6\$fixture-hash"'

OUTPUT_DIR="${WORK_DIR}/would-be-output"
INPUT="$(printf '\n\n\n\nfixtureadmin\nfixture-password\nfixture-password\nacmm-e2e-vm\n\n\n\n%s\ny\n' "${OUTPUT_DIR}")"

output="$(
  PATH="${STUB_DIR}:${PATH}" \
  HOME="${WORK_DIR}/home" \
  USER="fixtureadmin" \
  QUICKSTART_MUTATION_LOG="${MUTATION_LOG}" \
    "${QUICKSTART}" --dry-run <<<"${INPUT}" 2>&1
)"
status=$?

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

if [[ -s "${MUTATION_LOG}" ]]; then
  check "dry run executes no mutating command" 1 "$(<"${MUTATION_LOG}")"
else
  check "dry run executes no mutating command" 0
fi
assert_absent "dry run creates no output directory" "${OUTPUT_DIR}"

printf '\n1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'all %d assertions passed\n' "${tests_run}"

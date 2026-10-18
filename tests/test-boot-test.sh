#!/usr/bin/env bash
set -uo pipefail

# Exercise scripts/boot-test.sh against stubbed `skopeo`, `podman` and `bcvk`.
#
# The script's job is to boot the image a user would pull and to say plainly
# whether it came up. What is worth testing here is everything around the VM:
# that it boots the digest the tag resolved to rather than the tag, that the
# summary names that digest and its revision label, that the guest's results
# are read back correctly from a terminal session, that a boot is retried only
# when it reported nothing, and that a failed check or a missing one fails the
# run while a failed unit does not.
#
# No VM and no network. The `bcvk` stub does not boot anything: it takes the
# check script the real one would hand the guest, and runs it on this host with
# `systemctl` and `bootc` stubbed, adding the carriage returns a terminal
# session adds. So the script that ships to the guest is executed here too, not
# only read. jq and timeout are real.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/boot-test.sh"
WORKFLOW="${REPO_ROOT}/.github/workflows/boot-test.yml"
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"

failures=0
tests_run=0

if ! WORK_DIR="$(mktemp -d)"; then
  printf 'failed to create temporary work directory\n' >&2
  exit 1
fi
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

STUB_DIR="${WORK_DIR}/bin"
GUEST_BIN="${WORK_DIR}/guest-bin"
NO_BCVK_DIR="${WORK_DIR}/no-bcvk"
RUN_DIR="${WORK_DIR}/run"
LOG="${WORK_DIR}/calls"
mkdir -p "${STUB_DIR}" "${GUEST_BIN}" "${NO_BCVK_DIR}" "${RUN_DIR}"

pass() { printf 'ok - %s\n' "$*"; }
fail() {
  printf 'not ok - %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local description="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then
    pass "${description}"
  else
    fail "${description}${*:+: $*}"
  fi
}
assert_status() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    check "${description}" 0
  else
    check "${description}" 1 "expected exit ${expected}, got ${actual}"
  fi
}
assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${description}" 0
  else
    check "${description}" 1 "output did not contain '${needle}'"
  fi
}
assert_absent() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    check "${description}" 0
  else
    check "${description}" 1 "output unexpectedly contained '${needle}'"
  fi
}
assert_equal() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    check "${description}" 0
  else
    check "${description}" 1 "expected '${expected}', got '${actual}'"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required: the script under test reads the registry reply with jq\n' >&2
  exit 1
fi

DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
REVISION="0123456789abcdef0123456789abcdef01234567"

# --- Stubs ---------------------------------------------------------------------
#
# skopeo answers `inspect` with the JSON in SKOPEO_REPLY, or fails when
# SKOPEO_FAIL is set. podman fails a pull when PODMAN_PULL_FAIL is set. Every
# call is logged to STUB_LOG as `<tool> <args>`.
cat >"${STUB_DIR}/skopeo" <<'STUB'
#!/usr/bin/env bash
printf 'skopeo %s\n' "$*" >>"${STUB_LOG}"
[[ -z "${SKOPEO_FAIL:-}" ]] || { echo "skopeo: manifest unknown" >&2; exit 1; }
printf '%s\n' "${SKOPEO_REPLY}"
STUB

cat >"${STUB_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"${STUB_LOG}"
if [[ "${1:-}" == "pull" && -n "${PODMAN_PULL_FAIL:-}" ]]; then
  echo "podman: pull failed" >&2
  exit 125
fi
exit 0
STUB

# bcvk takes one mode per boot from BCVK_MODES, in order, the last repeating:
#   run      run the check script the real bcvk would hand the guest
#   silent   print nothing and fail, as a boot that never answered SSH
#   timeout  run the check script, then exit 124 as `timeout` does
#   fixture  print BCVK_FIXTURE as the session's output and exit 0
# It records its arguments, and copies the check script it was handed, so a
# case can read exactly what the guest would have run.
cat >"${STUB_DIR}/bcvk" <<'STUB'
#!/usr/bin/env bash
printf 'bcvk %s\n' "$*" >>"${STUB_LOG}"
count_file="${STUB_STATE}/bcvk-count"
count=$(($(cat "${count_file}" 2>/dev/null || echo 0) + 1))
echo "${count}" >"${count_file}"
read -r -a modes <<<"${BCVK_MODES:-run}"
index=$((count - 1))
((index < ${#modes[@]})) || index=$((${#modes[@]} - 1))
mode="${modes[index]}"
bind=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--ro-bind" ]] && bind="${args[i + 1]}"
done
script="${bind%%:*}/checks.sh"
cp -- "${script}" "${STUB_STATE}/checks-${count}.sh" 2>/dev/null || true
run_guest() {
  echo "Warning: Permanently added '[localhost]:2222' (ED25519) to the list of known hosts."
  PATH="${GUEST_BIN}:${PATH}" "${BASH}" "${script}" 2>&1 | sed 's/$/\r/'
}
case "${mode}" in
  run) run_guest ;;
  silent) echo "Error: SSH connection timed out" >&2; exit 1 ;;
  timeout) run_guest; exit 124 ;;
  fixture) printf '%s\n' "${BCVK_FIXTURE}" ;;
esac
STUB

# The guest's systemctl: GUEST_STATE is what is-system-running answers,
# GUEST_INACTIVE the units is-active calls inactive, GUEST_FAILED_UNITS the
# units --failed lists.
cat >"${GUEST_BIN}/systemctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  is-system-running)
    echo "${GUEST_STATE:-running}"
    [[ "${GUEST_STATE:-running}" == "running" ]]
    ;;
  is-active)
    if [[ " ${GUEST_INACTIVE:-} " == *" $2 "* ]]; then
      echo "inactive"
      exit 3
    fi
    echo "active"
    ;;
  --failed)
    for unit in ${GUEST_FAILED_UNITS:-}; do
      printf '%s loaded failed failed %s\n' "${unit}" "A unit"
    done
    ;;
  *) echo "unexpected systemctl $*" >&2; exit 90 ;;
esac
STUB

cat >"${GUEST_BIN}/bootc" <<'STUB'
#!/usr/bin/env bash
[[ -z "${GUEST_NO_BOOTC:-}" ]] || { echo "bootc: command not found"; exit 127; }
echo "${GUEST_BOOTC_VERSION:-bootc 1.10.0}"
STUB

chmod +x "${STUB_DIR}"/* "${GUEST_BIN}"/*
# A PATH with every tool but bcvk, for the missing-tool case.
for tool in skopeo podman; do
  ln -s "${STUB_DIR}/${tool}" "${NO_BCVK_DIR}/${tool}"
done

registry_reply() {
  jq -cn --arg digest "${1:-${DIGEST}}" --arg revision "${2-${REVISION}}" '
    {Name: "ghcr.io/danathar/arch-bootc-kde", Digest: $digest,
     Labels: (if $revision == "" then {} else {"org.opencontainers.image.revision": $revision} end)}'
}

# The stubs' own state for one run: bcvk's boot count, the check script it
# was handed, the step summary. Cleared by each run. Every case is run inside
# $(...), so nothing run_script sets can be read back by the case; this fixed
# path is how the case finds it.
STATE="${WORK_DIR}/state"
# The work directory of the case being asserted on, read by result().
OUT=""
# Run the script. Extra environment for the stubs is given as NAME=value words
# before the script's arguments, ending at --.
run_script() {
  local env_words=()
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    env_words+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  rm -rf -- "${STATE}"
  mkdir -p "${STATE}"
  : >"${LOG}"
  (
    cd -- "${RUN_DIR}" || exit 99
    env PATH="${STUB_DIR}:${PATH}" \
      STUB_LOG="${LOG}" \
      STUB_STATE="${STATE}" \
      GUEST_BIN="${GUEST_BIN}" \
      SKOPEO_REPLY="$(registry_reply)" \
      GITHUB_STEP_SUMMARY="${STATE}/step-summary" \
      "${env_words[@]+"${env_words[@]}"}" \
      "${BASH}" "${SCRIPT}" "$@" 2>&1
  )
}
calls() { grep -E "^$1 " "${LOG}" 2>/dev/null; }
bcvk_count() { calls bcvk | grep -c . || true; }
result() { jq -r "$1" "${OUT}/result.json" 2>/dev/null; }

KDE_ARGS=(--flavor kde --image ghcr.io/danathar/arch-bootc-kde:latest)
BASE_ARGS=(--flavor base --image ghcr.io/danathar/arch-bootc-base:latest)

# --- Arguments -------------------------------------------------------------------

output="$(run_script -- --help)"
assert_status "--help exits 0" 0 "$?"
assert_contains "--help prints the usage" "${output}" "Usage: boot-test.sh --flavor FLAVOR --image REF"

output="$(run_script -- --frobnicate)"
assert_status "an unknown argument is a usage error" 2 "$?"
assert_contains "an unknown argument is named" "${output}" "unknown argument: --frobnicate"

output="$(run_script -- --image ghcr.io/danathar/arch-bootc-kde:latest)"
assert_status "a missing --flavor is a usage error" 2 "$?"
assert_contains "a missing --flavor is named" "${output}" "--flavor is required"

output="$(run_script -- --flavor gnome --image ghcr.io/danathar/arch-bootc-gnome:latest)"
assert_status "a flavor that is not published is a usage error" 2 "$?"
assert_contains "an unknown flavor is named" "${output}" "unknown flavor 'gnome'"

output="$(run_script -- --flavor kde)"
assert_status "a missing --image is a usage error" 2 "$?"
assert_contains "a missing --image is named" "${output}" "--image is required"

output="$(run_script -- --flavor)"
assert_status "an option without its value is a usage error" 2 "$?"
assert_contains "an option without its value is named" "${output}" "--flavor needs a value"

output="$(run_script PATH="${NO_BCVK_DIR}" -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/no-bcvk-out")"
assert_status "a missing bcvk is a setup error" 2 "$?"
assert_contains "the missing tool is named" "${output}" "bcvk is not on PATH"

# --- The registry and the pull ---------------------------------------------------

output="$(run_script SKOPEO_FAIL=1 -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-inspect")"
assert_status "an image that cannot be inspected is a setup error, not a failed boot" 2 "$?"
assert_contains "the image that could not be inspected is named" "${output}" \
  "could not inspect ghcr.io/danathar/arch-bootc-kde:latest"
assert_equal "nothing is pulled or booted when the tag does not resolve" "" "$(calls 'podman pull')$(calls bcvk)"

output="$(run_script SKOPEO_REPLY='{"Digest":"latest"}' -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-digest")"
assert_status "a reply without a sha256 digest is a setup error" 2 "$?"
assert_contains "the bad digest is named" "${output}" "did not resolve to a sha256 digest (got 'latest')"

output="$(run_script PODMAN_PULL_FAIL=1 -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-pull")"
assert_status "a failed pull is a setup error" 2 "$?"
assert_contains "the failed pull names the digest" "${output}" \
  "could not pull ghcr.io/danathar/arch-bootc-kde@${DIGEST}"
assert_equal "nothing is booted when the pull fails" "" "$(calls bcvk)"

# --- A kde boot that passes ------------------------------------------------------

output="$(run_script -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-kde")"
assert_status "a kde boot whose checks all pass exits 0" 0 "$?"
OUT="${WORK_DIR}/w-kde"
assert_equal "the tag is inspected once, through the registry" \
  "skopeo inspect --retry-times 3 docker://ghcr.io/danathar/arch-bootc-kde:latest" "$(calls skopeo)"
assert_equal "the digest the tag resolved to is pulled, not the tag" \
  "podman pull --quiet --retry 3 ghcr.io/danathar/arch-bootc-kde@${DIGEST}" "$(calls 'podman pull')"
bcvk_args="$(calls bcvk)"
assert_equal "one boot is enough when it passes" "1" "$(bcvk_count)"
assert_contains "bcvk boots the digest, not the tag" "${bcvk_args}" \
  " ghcr.io/danathar/arch-bootc-kde@${DIGEST} -- bash /run/virtiofs-mnt-arch-bootc-checks/checks.sh"
assert_contains "bcvk is given the injected units by absolute path" "${bcvk_args}" \
  "--systemd-units ${OUT}/units "
assert_contains "bcvk mounts the check script read-only" "${bcvk_args}" \
  "--ro-bind ${OUT}/checks:arch-bootc-checks "
assert_contains "bcvk keeps the journal and console in the boot's log directory" "${bcvk_args}" \
  "--log-dir journal,console=${OUT}/boot-1/ "
assert_contains "the VM gets the memory and vcpus the script names" "${bcvk_args}" "--memory 4G --vcpus 2"
vm_name="$(sed -nE 's/.* --name ([^ ]+) .*/\1/p' <<<"${bcvk_args}")"
assert_equal "the VM's container is removed by the name it was booted under" \
  "podman rm --force --ignore ${vm_name}" "$(calls 'podman rm')"
assert_contains "the VM is named for the flavor and the attempt" "${vm_name}" "arch-bootc-boot-test-kde-"

assert_equal "result.json records a pass" "true" "$(result '.passed')"
assert_equal "result.json records the booted digest" \
  "ghcr.io/danathar/arch-bootc-kde@${DIGEST}" "$(result '.booted')"
assert_equal "result.json records the revision label" "${REVISION}" "$(result '.revision')"
assert_equal "result.json records the systemd state" "running" "$(result '.report.state')"
assert_equal "result.json records the guest's kernel" "$(uname -r)" "$(result '.report.kernel')"
assert_equal "kde runs every check, the display manager included, in order" \
  "boot:finished service:NetworkManager service:firewalld service:display-manager bootc:version" \
  "$(result '[.report.checks[].name] | join(" ")')"
assert_equal "every check passed" "pass pass pass pass pass" "$(result '[.report.checks[].status] | join(" ")')"
assert_equal "a check keeps the first line its command printed" "bootc 1.10.0" \
  "$(result '.report.checks[] | select(.name == "bootc:version") | .detail')"
assert_equal "the carriage returns a terminal adds are not part of a result" "active" \
  "$(result '.report.checks[] | select(.name == "service:firewalld") | .detail')"

summary="$(cat "${OUT}/summary.md")"
assert_contains "the summary says it passed" "${summary}" \
  "**Passed**: Booted, logged in over SSH, and every check passed."
assert_contains "the summary names the booted digest" "${summary}" \
  "| Booted | \`ghcr.io/danathar/arch-bootc-kde@${DIGEST}\` |"
assert_contains "the summary names the revision, so a reader can check the commit" "${summary}" \
  "| Revision | \`${REVISION}\` |"
assert_contains "the summary has a row per check" "${summary}" \
  "| \`service:display-manager\` | pass | \`active\` |"
assert_absent "a passing summary carries no log tail" "${summary}" "bcvk output (tail)"
assert_contains "the summary is printed" "${output}" "## Boot test: kde"
assert_equal "the summary is appended to the step summary" "${summary}" \
  "$(cat "${STATE}/step-summary")"

# What the guest was handed: the units bcvk injects and the check script.
assert_equal "the roothome unit is linked into default.target" \
  "../arch-bootc-boot-test-roothome.service" \
  "$(readlink "${OUT}/units/system/default.target.wants/arch-bootc-boot-test-roothome.service")"
assert_equal "sshd is linked into default.target" "/usr/lib/systemd/system/sshd.service" \
  "$(readlink "${OUT}/units/system/default.target.wants/sshd.service")"
assert_contains "the roothome unit only acts when /var/roothome is missing" \
  "$(cat "${OUT}/units/system/arch-bootc-boot-test-roothome.service")" "ConditionPathExists=!/var/roothome"
guest="$(cat "${OUT}/checks/checks.sh")"
assert_equal "the script left in the artifact is the one the guest ran" "${guest}" \
  "$(cat "${STATE}/checks-1.sh")"
assert_contains "the guest waits for boot to settle, but not for ever" "${guest}" \
  "timeout 300 systemctl is-system-running --wait"
assert_contains "the guest pages nothing" "${guest}" "export SYSTEMD_PAGER= PAGER=cat"

# --- The workflow passes what the script expects ------------------------------------
#
# The boot step's body is read out of the workflow and checked here rather than
# run: it needs the runner's KVM and network. What can drift is the contract
# between the two -- the flags, the env names, the flavor list.
step_body="$(awk -v want="Boot the image and run the checks" '
  /^      - name: / { current = substr($0, 15); in_run = 0; next }
  current == want && /^        run: \|/ { in_run = 1; next }
  in_run && /^          / { print substr($0, 11); next }
  in_run { in_run = 0 }
' "${WORKFLOW}")"
# shellcheck disable=SC2016 # the step's own shell expansions, matched literally
assert_contains "the workflow's boot step runs this script with the flavor, the image and a work directory" \
  "${step_body}" './scripts/boot-test.sh --flavor "${FLAVOR}" --image "${IMAGE,,}" --work "${WORK}"'
# shellcheck disable=SC2016 # a literal GitHub expression is what is looked for
assert_absent "the boot step's body is plain shell, with nothing interpolated" "${step_body}" '${{'
step_block="$(awk -v want="Boot the image and run the checks" '
  /^      - name: / { grab = (substr($0, 15) == want); next }
  grab && /^      [^ ]/ { grab = 0 }
  grab { print }
' "${WORKFLOW}")"
# shellcheck disable=SC2016 # literal GitHub expressions
assert_contains "the boot step's FLAVOR is the matrix flavor" "${step_block}" \
  'FLAVOR: ${{ matrix.flavor }}'
# shellcheck disable=SC2016 # literal GitHub expressions
assert_contains "the boot step boots the flavor's published :latest" "${step_block}" \
  'IMAGE: ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}-${{ matrix.flavor }}:latest'

publish_flavors="$(awk '/^  build_push:/ { on = 1; next } on && /^  [A-Za-z_]/ { exit } on' "${BUILD_WORKFLOW}" |
  sed -n 's/^[[:space:]]*flavor: \[\(.*\)\]$/\1/p' | tr -d ' ' | tr ',' '\n' | LC_ALL=C sort | tr '\n' ' ')"
matrix_flavors="$(grep -oE "'\[\"[a-z\",]+\]'" "${WORKFLOW}" | tr -d "'[]\"" | tr ',' '\n' | LC_ALL=C sort | tr '\n' ' ')"
choice_flavors="$(awk '/^        options:/ { on = 1; next } on && /^          - / { print $2; next } on { exit }' "${WORKFLOW}" |
  LC_ALL=C sort | tr '\n' ' ')"
check "build.yml's build_push publishes flavors this file can read" \
  "$([[ -n "${publish_flavors// /}" ]] && echo 0 || echo 1)"
assert_equal "the boot test boots every flavor build_push publishes, and no other" \
  "${publish_flavors}" "${matrix_flavors}"
assert_equal "a dispatch can name every published flavor, and no other" \
  "${publish_flavors}" "${choice_flavors}"
assert_contains "the boot test starts after the build workflow, by its name" "$(cat "${WORKFLOW}")" \
  "workflows: [\"$(sed -n 's/^name: //p' "${BUILD_WORKFLOW}")\"]"

# --- base has no display manager to check -------------------------------------------

output="$(run_script -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-base")"
assert_status "a base boot whose checks all pass exits 0" 0 "$?"
OUT="${WORK_DIR}/w-base"
assert_equal "base runs every check but the display manager" \
  "boot:finished service:NetworkManager service:firewalld bootc:version" \
  "$(result '[.report.checks[].name] | join(" ")')"
assert_absent "base's guest script never asks for a display manager" \
  "$(cat "${OUT}/checks/checks.sh")" "display-manager"

# --- Failed units are listed, not judged ---------------------------------------------

output="$(run_script GUEST_STATE=degraded "GUEST_FAILED_UNITS=bootloader-update.service arch-bootc-prune-esp.service" \
  -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-degraded")"
assert_status "a degraded boot with every check passing exits 0" 0 "$?"
OUT="${WORK_DIR}/w-degraded"
assert_equal "a degraded system finished booting" "pass" \
  "$(result '.report.checks[] | select(.name == "boot:finished") | .status')"
assert_equal "result.json lists the failed units" "bootloader-update.service arch-bootc-prune-esp.service" \
  "$(result '.report.failed_units | join(" ")')"
assert_contains "the summary lists the failed units as not judged" "$(cat "${OUT}/summary.md")" \
  "Failed units (not judged): \`bootloader-update.service\`, \`arch-bootc-prune-esp.service\`"

# --- A failed check fails the run, and is not retried ---------------------------------

output="$(run_script GUEST_INACTIVE=firewalld.service -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-firewalld")"
assert_status "an inactive firewalld fails the run" 1 "$?"
OUT="${WORK_DIR}/w-firewalld"
assert_equal "a boot that reported a failed check is not retried" "1" "$(bcvk_count)"
assert_equal "result.json records the failure" "false" "$(result '.passed')"
assert_equal "the summary line names the failed check" \
  "Booted and logged in, but failed checks: service:firewalld." "$(result '.summary')"
assert_contains "the summary row says what the guest saw" "$(cat "${OUT}/summary.md")" \
  "| \`service:firewalld\` | fail | \`inactive\` |"
assert_contains "a failed summary carries the tail of bcvk's output" "$(cat "${OUT}/summary.md")" \
  "<details><summary>bcvk output (tail)</summary>"
assert_contains "the failure is reported on stderr with the digest" "${output}" \
  "boot-test: FAILED for ghcr.io/danathar/arch-bootc-kde@${DIGEST}"

output="$(run_script GUEST_INACTIVE=display-manager.service -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-dm")"
assert_status "kde with no login screen fails the run" 1 "$?"
assert_equal "the display manager is the check named" \
  "Booted and logged in, but failed checks: service:display-manager." \
  "$(OUT="${WORK_DIR}/w-dm" result '.summary')"

output="$(run_script GUEST_STATE=starting -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-starting")"
assert_status "a boot that never settled fails the run" 1 "$?"
assert_equal "an unsettled boot fails boot:finished and names the state" "fail starting" \
  "$(OUT="${WORK_DIR}/w-starting" result '.report.checks[] | select(.name == "boot:finished") | "\(.status) \(.detail)"')"

output="$(run_script GUEST_NO_BOOTC=1 -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-bootc")"
assert_status "an image whose bootc does not run fails" 1 "$?"
assert_equal "bootc:version is the check named" "Booted and logged in, but failed checks: bootc:version." \
  "$(OUT="${WORK_DIR}/w-bootc" result '.summary')"

output="$(run_script "GUEST_BOOTC_VERSION=bootc 1.10.0 | dirty" -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-pipe")"
assert_status "a detail with a pipe in it still passes" 0 "$?"
assert_contains "a pipe in a detail cannot split the summary's table row" \
  "$(cat "${WORK_DIR}/w-pipe/summary.md")" "| \`bootc:version\` | pass | \`bootc 1.10.0 \\| dirty\` |"

# --- A check that never reported ---------------------------------------------------------

fixture="$(printf '%s\n' \
  "ARCH-BOOTC-BOOT-STATE running" \
  "ARCH-BOOTC-BOOT-CHECK boot:finished pass running" \
  "ARCH-BOOTC-BOOT-CHECK service:NetworkManager pass active" \
  "ARCH-BOOTC-BOOT-CHECK service:firewalld pass active" \
  "ARCH-BOOTC-BOOT-DONE")"
output="$(run_script BCVK_MODES=fixture "BCVK_FIXTURE=${fixture}" -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-missing")"
assert_status "a check with no result fails the run" 1 "$?"
assert_equal "the missing check is named" "Booted and logged in, but checks with no result: bootc:version." \
  "$(OUT="${WORK_DIR}/w-missing" result '.summary')"

fixture="$(printf '%s\n' \
  "ARCH-BOOTC-BOOT-CHECK boot:finished fail starting" \
  "ARCH-BOOTC-BOOT-CHECK service:NetworkManager pass active" \
  "ARCH-BOOTC-BOOT-DONE")"
output="$(run_script BCVK_MODES=fixture "BCVK_FIXTURE=${fixture}" -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-both")"
assert_status "a missing and a failed check fail the run" 1 "$?"
assert_equal "both are named" \
  "Booted and logged in, but checks with no result: service:firewalld, bootc:version; failed checks: boot:finished." \
  "$(OUT="${WORK_DIR}/w-both" result '.summary')"
assert_equal "a run with no kernel line says unknown" "| Kernel | \`unknown\` |" \
  "$(grep -F '| Kernel |' "${WORK_DIR}/w-both/summary.md")"

# --- Retries: only a boot that reported nothing ---------------------------------------------

output="$(run_script BCVK_MODES=silent -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-silent")"
assert_status "a VM that never answers fails the run" 1 "$?"
OUT="${WORK_DIR}/w-silent"
assert_equal "a boot that reported nothing is retried once, and only once" "2" "$(bcvk_count)"
assert_equal "result.json counts both boots" "2" "$(result '.attempts')"
assert_equal "the summary says the checks never finished" \
  "The VM never reached the point where the checks finish (no SSH, or the checks hung)." "$(result '.summary')"
assert_contains "the retry is announced" "${output}" "boot 1 reported no check; booting once more"
assert_contains "each boot has its own log" "$(cat "${OUT}/boot-2/bcvk.log")" "SSH connection timed out"
assert_equal "each boot's VM is removed" "2" "$(calls 'podman rm' | grep -c .)"

output="$(run_script "BCVK_MODES=silent run" -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-retry")"
assert_status "a second boot that passes passes the run" 0 "$?"
OUT="${WORK_DIR}/w-retry"
assert_equal "the passing second boot is the one recorded" "2 true" "$(result '"\(.attempts) \(.passed)"')"
assert_contains "the summary says it took two boots" "$(cat "${OUT}/summary.md")" "| Boots | 2 |"

# A boot that reported a check and then hung is the answer: its failed check
# must not be replaced by a second boot that might pass.
output="$(run_script BCVK_MODES=timeout GUEST_INACTIVE=NetworkManager.service \
  -- "${KDE_ARGS[@]}" --work "${WORK_DIR}/w-timeout")"
assert_status "a boot that timed out after reporting fails" 1 "$?"
OUT="${WORK_DIR}/w-timeout"
assert_equal "a boot that reported checks before timing out is not retried" "1" "$(bcvk_count)"
assert_contains "the log says the boot timed out" "$(cat "${OUT}/boot-1/bcvk.log")" "bcvk timed out after 900s"
assert_equal "the failed check from the timed-out boot is kept" "fail" \
  "$(result '.report.checks[] | select(.name == "service:NetworkManager") | .status')"

# --- References ----------------------------------------------------------------------------

output="$(run_script -- --flavor base --image localhost:5000/arch-bootc-base:testing --work "${WORK_DIR}/w-port")"
assert_status "an image behind a registry port boots" 0 "$?"
assert_equal "a registry port is not mistaken for a tag" \
  "localhost:5000/arch-bootc-base@${DIGEST}" "$(OUT="${WORK_DIR}/w-port" result '.booted')"

output="$(run_script -- --flavor base \
  --image "ghcr.io/danathar/arch-bootc-base@sha256:2222222222222222222222222222222222222222222222222222222222222222" \
  --work "${WORK_DIR}/w-bydigest")"
assert_status "an image given by digest boots" 0 "$?"
assert_equal "an image given by digest boots the digest the registry answers with" \
  "ghcr.io/danathar/arch-bootc-base@${DIGEST}" "$(OUT="${WORK_DIR}/w-bydigest" result '.booted')"

output="$(run_script SKOPEO_REPLY="$(registry_reply "${DIGEST}" "")" -- "${BASE_ARGS[@]}" --work "${WORK_DIR}/w-norev")"
assert_status "an image with no revision label still boots" 0 "$?"
assert_contains "a missing revision is reported as unknown, not left blank" \
  "$(cat "${WORK_DIR}/w-norev/summary.md")" "| Revision | \`unknown\` |"

# The default work directory is relative to where the script is run.
output="$(run_script -- "${BASE_ARGS[@]}")"
assert_status "a run with the default work directory passes" 0 "$?"
check "the default work directory is artifacts/boot-test/<flavor>" \
  "$([[ -f "${RUN_DIR}/artifacts/boot-test/base/result.json" ]] && echo 0 || echo 1)"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

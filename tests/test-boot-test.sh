#!/usr/bin/env bash
set -uo pipefail

# Exercise scripts/boot-test.sh against stubbed skopeo, podman and bcvk.
#
# The script's job is a verdict on a boot nobody watches: pass only when the VM
# logged in and every check this flavor expects ran and passed, and retry only a
# boot that reported nothing. What is worth testing is that verdict, the digest
# it boots, and that the check script it hands the guest actually runs.
#
# No network, no VM: skopeo, podman and bcvk are shadowed on PATH. In "guest"
# mode the bcvk stub runs the generated check script itself, against stub
# systemctl and bootc commands, so a quoting mistake in the script the real
# guest would run fails here. In "canned" mode it prints a fixed SSH session,
# for the cases a real guest would only produce by misbehaving.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/boot-test.sh"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT
STUB_DIR="${WORK_DIR}/bin"
GUEST_DIR="${WORK_DIR}/guest"
CALLS="${WORK_DIR}/calls"
CANNED="${WORK_DIR}/canned"
mkdir -p "${STUB_DIR}" "${GUEST_DIR}"

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

DIGEST="sha256:$(printf '%064d' 7 | tr 0 a)"
REVISION="0123456789abcdef0123456789abcdef01234567"

# skopeo answers `inspect --format` with the digest and revision the test set.
cat >"${STUB_DIR}/skopeo" <<'STUB'
#!/usr/bin/env bash
printf 'skopeo %s\n' "$*" >>"${STUB_CALLS}"
if [[ -n "${SKOPEO_FAIL:-}" ]]; then
  echo "manifest unknown" >&2
  exit 1
fi
printf '%s %s\n' "${SKOPEO_DIGEST}" "${SKOPEO_REVISION-}"
STUB

cat >"${STUB_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"${STUB_CALLS}"
if [[ "$1" == "pull" && -n "${PODMAN_PULL_FAIL:-}" ]]; then
  exit 125
fi
STUB

# bcvk: record the call, then either run the guest script the way the guest
# would (bash on the --ro-bind directory) or print the canned session.
cat >"${STUB_DIR}/bcvk" <<'STUB'
#!/usr/bin/env bash
printf 'bcvk %s\n' "$*" >>"${STUB_CALLS}"
if [[ "${BCVK_MODE}" == "canned" ]]; then
  cat "${BCVK_CANNED}"
  exit "${BCVK_EXIT:-0}"
fi
checks_dir=""
while (($# > 0)); do
  case "$1" in
    --ro-bind) checks_dir="${2%%:*}"; shift 2 ;;
    *) shift ;;
  esac
done
# A login shell's terminal query ahead of the first marker, on the same line.
printf '\033[?2004h'
PATH="${GUEST_PATH}:${PATH}" bash "${checks_dir}/checks.sh"
STUB

# The guest's systemctl and bootc. GUEST_INACTIVE names units that are not
# active; GUEST_STATE is what is-system-running reports.
cat >"${GUEST_DIR}/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-system-running)
    echo "${GUEST_STATE:-running}"
    [[ "${GUEST_STATE:-running}" == running ]]
    ;;
  is-active)
    for unit in ${GUEST_INACTIVE:-}; do
      if [[ "${unit}" == "$2" ]]; then
        echo inactive
        exit 3
      fi
    done
    echo active
    ;;
  --failed)
    for unit in ${GUEST_FAILED_UNITS:-}; do
      printf '%s loaded failed failed Some unit\n' "${unit}"
    done
    ;;
esac
STUB
cat >"${GUEST_DIR}/bootc" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${GUEST_BOOTC_BROKEN:-}" ]]; then
  echo "bootc: error while loading shared libraries" >&2
  exit 127
fi
echo "bootc 1.9.0"
STUB
chmod +x "${STUB_DIR}"/* "${GUEST_DIR}"/*

# Run the script. Arguments before `--` are extra environment assignments;
# arguments after it go to the script.
run_boot() {
  local work="${WORK_DIR}/work"
  local -a envs=()
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  rm -rf -- "${work}"
  : >"${CALLS}"
  : >"${WORK_DIR}/step-summary"
  env PATH="${STUB_DIR}:${PATH}" \
    STUB_CALLS="${CALLS}" \
    SKOPEO_DIGEST="${DIGEST}" \
    SKOPEO_REVISION="${REVISION}" \
    BCVK_MODE=guest \
    BCVK_CANNED="${CANNED}" \
    GUEST_PATH="${GUEST_DIR}" \
    GITHUB_STEP_SUMMARY="${WORK_DIR}/step-summary" \
    "${envs[@]}" \
    "${BASH}" "${SCRIPT}" --work "${work}" "$@" 2>&1
}

result() {
  jq -r "$1" "${WORK_DIR}/work/result.json"
}

bcvk_calls() {
  grep -c '^bcvk ' "${CALLS}"
}

KDE=(--image ghcr.io/danathar/arch-bootc-kde:latest --flavor kde)
BASE=(--image ghcr.io/danathar/arch-bootc-base:latest --flavor base)

# --- arguments --------------------------------------------------------------

output="$(run_boot -- --help)"
assert_status "--help exits 0" 0 "$?"
assert_contains "--help explains the exit codes" "${output}" "Exit status:"

output="$(run_boot -- --flavor kde)"
assert_status "a missing --image is a usage error" 2 "$?"
assert_contains "the missing image is named" "${output}" "--image is required"

output="$(run_boot -- --image ghcr.io/danathar/arch-bootc-kde:latest)"
assert_status "a missing --flavor is a usage error" 2 "$?"
assert_contains "the missing flavor is named" "${output}" "--flavor is required"

output="$(run_boot -- --image ghcr.io/danathar/arch-bootc-gnome:latest --flavor gnome)"
assert_status "an unknown flavor is a usage error" 2 "$?"
assert_contains "the unknown flavor is named" "${output}" "got gnome"

output="$(run_boot -- --bogus)"
assert_status "an unknown argument is a usage error" 2 "$?"

# --- resolving and pulling ----------------------------------------------------

output="$(run_boot SKOPEO_FAIL=1 -- "${KDE[@]}")"
assert_status "an image that does not resolve is a setup error" 2 "$?"
assert_equal "nothing boots when the image does not resolve" "0" "$(bcvk_calls)"

output="$(run_boot SKOPEO_DIGEST=latest -- "${KDE[@]}")"
assert_status "an answer that is not a digest is a setup error" 2 "$?"
assert_contains "the bad answer is named" "${output}" "which is not a digest"

output="$(run_boot PODMAN_PULL_FAIL=1 -- "${KDE[@]}")"
assert_status "a failed pull is a setup error" 2 "$?"
assert_equal "nothing boots when the pull failed" "0" "$(bcvk_calls)"

# --- a passing boot -----------------------------------------------------------

output="$(run_boot GUEST_STATE=degraded GUEST_FAILED_UNITS=bootloader-update.service -- "${KDE[@]}")"
assert_status "kde passes when every check passes" 0 "$?"
assert_equal "result.json records the pass" "true" "$(result .passed)"
assert_equal "kde runs the display manager check" \
  "boot:finished unit:NetworkManager unit:firewalld unit:display-manager bootc:version" \
  "$(result '[.report.checks[].name] | join(" ")')"
assert_equal "the tag is replaced by the digest it resolved to" \
  "ghcr.io/danathar/arch-bootc-kde@${DIGEST}" "$(result .booted)"
assert_contains "bcvk boots the digest, not the tag" \
  "$(grep '^bcvk ' "${CALLS}")" " ghcr.io/danathar/arch-bootc-kde@${DIGEST} -- "
assert_contains "the digest is what is pulled" \
  "$(grep '^podman pull' "${CALLS}")" "ghcr.io/danathar/arch-bootc-kde@${DIGEST}"
assert_equal "the revision label is recorded" "${REVISION}" "$(result .revision)"
assert_equal "degraded counts as a finished boot" "pass degraded" \
  "$(result '.report.checks[] | select(.name == "boot:finished") | "\(.status) \(.detail)"')"
assert_equal "failed units are recorded" "bootloader-update.service" "$(result '.report.failed_units | join(" ")')"
# shellcheck disable=SC2016 # the backticks are the summary's own markup
assert_contains "failed units are listed as not judged" "${output}" 'Failed units (not judged): `bootloader-update.service`'
assert_equal "the kernel is read back from the guest" "$(uname -r)" "$(result .report.kernel)"
assert_equal "one boot is enough when it reports" "1" "$(bcvk_calls)"
assert_contains "the VM container is removed after the boot" \
  "$(grep '^podman rm' "${CALLS}")" "--force --ignore arch-bootc-boot-test-"
assert_contains "the summary reaches the job summary" "$(cat "${WORK_DIR}/step-summary")" "## Boot test: kde"
# bcvk installs the directory as-is, so a unit without its wants link is a unit
# that never runs, and then the login it exists for fails on a real VM.
for unit in arch-bootc-roothome.service arch-bootc-root-unexpire.service; do
  check "${unit} is injected and wanted by default.target" \
    "$([[ -f "${WORK_DIR}/work/units/system/default.target.wants/${unit}" ]] && echo 0 || echo 1)"
done
assert_contains "bcvk is handed the units directory by absolute path" \
  "$(grep '^bcvk ' "${CALLS}")" "--systemd-units ${WORK_DIR}/work/units "

output="$(run_boot -- "${BASE[@]}")"
assert_status "base passes without a display manager check" 0 "$?"
assert_absent "base does not check a display manager" \
  "$(result '[.report.checks[].name] | join(" ")')" "display-manager"

# Untagged, so the only colon is the registry's port: a script that stripped
# from the last colon of the whole reference would cut the port off.
output="$(run_boot -- --image localhost:5000/arch-bootc-base --flavor base)"
assert_status "a registry with a port boots" 0 "$?"
assert_equal "a registry port is not taken for a tag" \
  "localhost:5000/arch-bootc-base@${DIGEST}" "$(result .booted)"

output="$(run_boot -- --image localhost:5000/arch-bootc-base@sha256:0000 --flavor base)"
assert_equal "an image given by digest boots the digest it resolves to" \
  "localhost:5000/arch-bootc-base@${DIGEST}" "$(result .booted)"

output="$(run_boot SKOPEO_REVISION= -- "${BASE[@]}")"
assert_equal "a missing revision label is recorded as unknown" "unknown" "$(result .revision)"

# --- failing checks -----------------------------------------------------------

output="$(run_boot GUEST_INACTIVE=firewalld.service -- "${BASE[@]}")"
assert_status "an inactive firewalld fails the boot test" 1 "$?"
assert_equal "result.json records the failure" "false" "$(result .passed)"
assert_contains "the failed check is named" "$(result .summary)" "failed checks: unit:firewalld"
assert_equal "the check's own output is kept as its detail" "inactive" \
  "$(result '.report.checks[] | select(.name == "unit:firewalld") | .detail')"
assert_equal "a boot whose checks ran is not retried" "1" "$(bcvk_calls)"

output="$(run_boot GUEST_INACTIVE=display-manager.service -- "${KDE[@]}")"
assert_status "kde without a running display manager fails" 1 "$?"
assert_contains "the display manager is named" "$(result .summary)" "unit:display-manager"

output="$(run_boot GUEST_STATE=starting -- "${BASE[@]}")"
assert_status "a boot that never finished starting fails" 1 "$?"
assert_contains "the unfinished boot is named" "$(result .summary)" "boot:finished"

output="$(run_boot GUEST_STATE=maintenance -- "${BASE[@]}")"
assert_status "a boot that dropped to maintenance fails" 1 "$?"

output="$(run_boot GUEST_BOOTC_BROKEN=1 -- "${BASE[@]}")"
assert_status "a bootc that does not run fails" 1 "$?"
assert_contains "bootc's error is kept as the detail" \
  "$(result '.report.checks[] | select(.name == "bootc:version") | .detail')" "shared libraries"

# A kde session that never reports its display manager check: the check list
# is the flavor's, not whatever the guest happened to print.
printf '%s\n' \
  "ARCH-BOOTC-BOOT-STATE running" \
  "ARCH-BOOTC-BOOT-CHECK boot:finished pass running" \
  "ARCH-BOOTC-BOOT-CHECK unit:NetworkManager pass active" \
  "ARCH-BOOTC-BOOT-CHECK unit:firewalld pass active" \
  "ARCH-BOOTC-BOOT-CHECK bootc:version pass bootc 1.9.0" \
  "ARCH-BOOTC-BOOT-DONE" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned -- "${KDE[@]}")"
assert_status "a missing check fails even when every reported one passed" 1 "$?"
assert_contains "the missing check is named" "$(result .summary)" "checks with no result: unit:display-manager"

# A failed check, then a hang before DONE. The boot reported, so it is the
# answer: a second boot could pass and hide the failure.
printf '%s\n' \
  "ARCH-BOOTC-BOOT-STATE running" \
  "ARCH-BOOTC-BOOT-CHECK boot:finished pass running" \
  "ARCH-BOOTC-BOOT-CHECK unit:NetworkManager fail inactive" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned BCVK_EXIT=255 -- "${BASE[@]}")"
assert_status "a failed check cut off before DONE fails" 1 "$?"
assert_equal "a failed check cut off before DONE is not retried" "1" "$(bcvk_calls)"
assert_contains "the cut-off boot is reported as unfinished" "$(result .summary)" "never reached the point"

# Nothing from the guest at all: the one case a second boot is for.
printf '%s\n' "Error: SSH connection timed out after 240s" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned BCVK_EXIT=1 -- "${BASE[@]}")"
assert_status "a boot that never reported fails" 1 "$?"
assert_equal "a boot that never reported is retried once" "2" "$(bcvk_calls)"
assert_equal "both boots are counted" "2" "$(result .attempts)"
assert_equal "every boot's VM container is removed" "2" "$(grep -c '^podman rm' "${CALLS}")"
assert_contains "the failure shows bcvk's own output" "${output}" "SSH connection timed out"
assert_contains "the error line names the booted digest" "${output}" "error: boot test failed for ghcr.io/danathar/arch-bootc-base@${DIGEST}"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

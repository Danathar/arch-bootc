#!/usr/bin/env bash
set -uo pipefail

# Execute nightly-compliance.yml's bootc-pin shell against controlled git
# ls-remote replies. This is the supply-chain decision the job exists to make:
# annotated tags have a tag-object row and a peeled-commit row, and only the
# latter may be compared with BOOTC_COMMIT. Running the workflow body itself
# keeps the test attached to what Actions executes rather than to a second copy
# of the awk selection that could drift while both remained internally green.
#
# No network: `git` is shadowed on PATH, answers from a fixture file, and
# records its argv. The Containerfile is also a fixture in a temporary working
# directory, so these cases neither inspect the live bootc tag nor modify the
# repository's real pin.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/nightly-compliance.yml"

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

RUN_DIR="${WORK_DIR}/run"
STUB_DIR="${WORK_DIR}/bin"
REFS_FIXTURE="${WORK_DIR}/refs"
GIT_ARGS="${WORK_DIR}/git-args"
mkdir -p "${RUN_DIR}" "${STUB_DIR}"

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
assert_extracted() {
  local description="$1" value="$2"
  if [[ -n "${value}" ]]; then
    check "${description}" 0
  else
    check "${description}" 1 \
      "nothing was extracted; the job or step was renamed, moved, or reindented"
  fi
}

# Print the `run:` block of the named step of the named job, dedented to
# column 0. Qualifying the step by job matters because workflow step names are
# not globally unique. Refusing an empty result below makes a rename or layout
# change fail instead of turning every behavioral case into a test of nothing.
workflow_step_run() {
  local workflow="$1" job="$2" step="$3"
  awk -v want_job="${job}" -v want="${step}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_run = 0
    }
    /^      - name: / { current = substr($0, 15); in_run = 0; next }
    current_job == want_job && current == want && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 == "") { print ""; next }
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      in_run = 0
    }
  ' "${workflow}"
}

BOOTC_PIN_JOB="bootc-pin"
BOOTC_PIN_STEP="Re-resolve BOOTC_VERSION against upstream"
bootc_pin_run="$(workflow_step_run "${WORKFLOW}" "${BOOTC_PIN_JOB}" "${BOOTC_PIN_STEP}")"
assert_extracted "the bootc-pin step's body is still where this test expects it" \
  "${bootc_pin_run}"

# A GitHub expression is expanded by Actions before the shell sees the body.
# This harness intentionally does no expression evaluation, so fail if one is
# introduced instead of executing shell with different semantics from CI.
# shellcheck disable=SC2016
assert_absent "the bootc-pin step's body is plain shell" "${bootc_pin_run}" '${{'

cat >"${STUB_DIR}/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${GIT_STUB_ARGS}"
if [[ "${1:-}" != "ls-remote" || "${2:-}" != "--tags" ]]; then
  printf 'unexpected git invocation: %s\n' "$*" >&2
  exit 90
fi
cat "${GIT_STUB_REFS}"
STUB
chmod +x "${STUB_DIR}/git"

VERSION="v1.2.3"
TAG_OBJECT="1111111111111111111111111111111111111111"
PEELED_COMMIT="2222222222222222222222222222222222222222"
OTHER_COMMIT="3333333333333333333333333333333333333333"

write_pin() {
  local version="$1" commit="$2"
  printf 'ARG BOOTC_VERSION=%s\nARG BOOTC_COMMIT=%s\n' \
    "${version}" "${commit}" >"${RUN_DIR}/Containerfile"
}

write_annotated_refs() {
  local plain="$1" peeled="$2" order="${3:-plain-first}"
  if [[ "${order}" == "plain-first" ]]; then
    printf '%s\trefs/tags/%s\n%s\trefs/tags/%s^{}\n' \
      "${plain}" "${VERSION}" "${peeled}" "${VERSION}" >"${REFS_FIXTURE}"
  else
    printf '%s\trefs/tags/%s^{}\n%s\trefs/tags/%s\n' \
      "${peeled}" "${VERSION}" "${plain}" "${VERSION}" >"${REFS_FIXTURE}"
  fi
}

run_bootc_pin() {
  : >"${GIT_ARGS}"
  (
    cd -- "${RUN_DIR}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      GIT_STUB_REFS="${REFS_FIXTURE}" \
      GIT_STUB_ARGS="${GIT_ARGS}" \
      "${BASH}" --noprofile --norc -c "${bootc_pin_run}"
  )
}

# The normal annotated-tag reply. The plain row is deliberately a different
# object from the pin: comparing it would reject an intact tag.
write_pin "${VERSION}" "${PEELED_COMMIT}"
write_annotated_refs "${TAG_OBJECT}" "${PEELED_COMMIT}"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "an annotated tag whose peeled commit matches exits 0" 0 "${status}"
assert_contains "an intact annotated tag reports the successful pin" "${output}" \
  "bootc pin intact: ${VERSION} still resolves to ${PEELED_COMMIT}"

printf -v expected_git_args '%s\n' \
  "ls-remote" \
  "--tags" \
  "https://github.com/bootc-dev/bootc.git" \
  "refs/tags/${VERSION}" \
  "refs/tags/${VERSION}^{}"
assert_equal "git is asked for both the plain and peeled upstream refs" \
  "${expected_git_args%$'\n'}" "$(cat "${GIT_ARGS}")"

# Git does not promise the test's preferred row order. If the awk accidentally
# made its decision from the last or first row rather than the ^{} suffix, one
# of these two annotated-tag cases would disagree with the other.
write_annotated_refs "${TAG_OBJECT}" "${PEELED_COMMIT}" peeled-first
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a reversed annotated-tag reply still exits 0" 0 "${status}"
assert_contains "row order does not change the peeled commit" "${output}" \
  "upstream: ${VERSION} -> ${PEELED_COMMIT}"

# This is the discriminating supply-chain case: the plain tag object still
# equals the configured pin, while the commit it now peels to does not. Letting
# the plain row win would report the exact upstream re-point as intact.
write_pin "${VERSION}" "${TAG_OBJECT}"
write_annotated_refs "${TAG_OBJECT}" "${OTHER_COMMIT}"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a moved peel fails even when the plain row still matches" 1 "${status}"
assert_contains "a moved peel is identified as a supply-chain event" "${output}" \
  "now resolves to ${OTHER_COMMIT}, but this image is pinned to ${TAG_OBJECT}"
assert_absent "a moved peel is never reported intact" "${output}" "bootc pin intact"

# A lightweight tag has no ^{} row. The documented fallback to the one plain
# row must remain accepted or the gate would reject valid lightweight tags.
write_pin "${VERSION}" "${PEELED_COMMIT}"
printf '%s\trefs/tags/%s\n' "${PEELED_COMMIT}" "${VERSION}" >"${REFS_FIXTURE}"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a matching lightweight tag exits 0" 0 "${status}"
assert_contains "a matching lightweight tag reports the successful pin" "${output}" \
  "bootc pin intact: ${VERSION} still resolves to ${PEELED_COMMIT}"

# An empty successful ls-remote response means the tag vanished. It must not
# flow through awk as an empty resolved commit and look like an intact pin.
: >"${REFS_FIXTURE}"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a deleted upstream tag exits 1" 1 "${status}"
assert_contains "a deleted upstream tag names the missing version" "${output}" \
  "tag ${VERSION} no longer exists upstream"

# Either half of the two-value pin missing is a malformed Containerfile. Both
# cases also assert git was never reached: the job must fail at the local input
# boundary instead of asking upstream a question built from an empty version.
printf 'ARG BOOTC_COMMIT=%s\n' "${PEELED_COMMIT}" >"${RUN_DIR}/Containerfile"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a missing BOOTC_VERSION exits 1" 1 "${status}"
assert_contains "a missing BOOTC_VERSION reports the malformed pin" "${output}" \
  "could not read BOOTC_VERSION/BOOTC_COMMIT"
assert_equal "a missing BOOTC_VERSION makes no upstream request" "" "$(cat "${GIT_ARGS}")"

printf 'ARG BOOTC_VERSION=%s\n' "${VERSION}" >"${RUN_DIR}/Containerfile"
output="$(run_bootc_pin 2>&1)"
status=$?
assert_status "a missing BOOTC_COMMIT exits 1" 1 "${status}"
assert_contains "a missing BOOTC_COMMIT reports the malformed pin" "${output}" \
  "could not read BOOTC_VERSION/BOOTC_COMMIT"
assert_equal "a missing BOOTC_COMMIT makes no upstream request" "" "$(cat "${GIT_ARGS}")"

# --- signatures: the published image still verifies against cosign.pub ------
#
# The other half of this workflow. bootc-pin asks whether the source pin still
# means what it meant; `signatures` asks whether the images already published
# from this repository still verify against the key this repository ships.
# Nothing executed its shell: it is five lines, and every one of them is a
# decision that fails silently when it is wrong.
#
# The registry half in particular. GHCR rejects an uppercase path, so the body
# lowercases the whole reference before handing it to cosign; the fixtures
# below therefore use a mixed-case owner and repository name, which is what
# `github.repository_owner` and `github.event.repository.name` actually carry.
# A body that stopped lowercasing would still pass against an already-lowercase
# reference while asking the registry about an image that does not exist.
#
# `cosign` is shadowed on PATH the same way `git` is above, records its argv,
# and asserts the key path it is handed resolves from the working directory the
# job runs in. No network, no registry, no real signature.

SIGNATURES_JOB="signatures"
SIGNATURES_STEP="Verify the published image against cosign.pub"
signatures_run="$(workflow_step_run "${WORKFLOW}" "${SIGNATURES_JOB}" "${SIGNATURES_STEP}")"
assert_extracted "the signatures step's body is still where this test expects it" \
  "${signatures_run}"
# shellcheck disable=SC2016
assert_absent "the signatures step's body is plain shell" "${signatures_run}" '${{'

# Print every line of the named job, dedented not at all: used below for the
# job-level assertions (matrix, action inputs, credentials) that decide as much
# about this check as the body does.
workflow_job_block() {
  local workflow="$1" job="$2"
  awk -v want="${job}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      in_block = (substr($0, 3, length($0) - 3) == want)
      next
    }
    in_block { print }
  ' "${workflow}"
}

# Print the value of one key from the named step's `env:` block, unexpanded.
# What a step hands its command through the environment decides as much as the
# body does, and here the environment is where the image reference is built.
workflow_step_env() {
  local workflow="$1" job="$2" step="$3" key="$4"
  awk -v want_job="${job}" -v want="${step}" -v key="${key}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_env = 0
    }
    /^      - name: / { current = substr($0, 15); in_env = 0; next }
    current_job == want_job && current == want && /^        env:$/ { in_env = 1; next }
    in_env && substr($0, 1, 10) != "          " { in_env = 0 }
    in_env && $0 ~ ("^          " key ": ") { print substr($0, length(key) + 13); exit }
  ' "${workflow}"
}

# Print the key names of the named step's `env:` block, one per line.
workflow_step_env_keys() {
  local workflow="$1" job="$2" step="$3"
  awk -v want_job="${job}" -v want="${step}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_env = 0
    }
    /^      - name: / { current = substr($0, 15); in_env = 0; next }
    current_job == want_job && current == want && /^        env:$/ { in_env = 1; next }
    in_env {
      if (substr($0, 1, 10) != "          ") { in_env = 0; next }
      line = substr($0, 11)
      sub(/:.*$/, "", line)
      print line
    }
  ' "${workflow}"
}

signatures_block="$(workflow_job_block "${WORKFLOW}" "${SIGNATURES_JOB}")"
assert_extracted "the signatures job is still where this test expects it" \
  "${signatures_block}"

# The reference is composed entirely in `env:`. Pinning it here is the only
# place the composition is checked at all: a wrong owner, a dropped flavor
# suffix or a tag other than the published one turns this nightly gate into a
# check that some other image is signed.
# shellcheck disable=SC2016
assert_equal "the verified reference is the published per-flavor image at its published tag" \
  'ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}-${{ matrix.flavor }}:latest' \
  "$(workflow_step_env "${WORKFLOW}" "${SIGNATURES_JOB}" "${SIGNATURES_STEP}" IMAGE)"

# "Deliberately unauthenticated" is the property the job's comment claims and
# the reason a pass means anything: it proves the signature verifies for anyone
# pulling the image, not merely that CI can verify its own artifact with its
# own token. That property is invisible in the body -- it is the absence of a
# login step and of credentials in the environment, so it is asserted as an
# absence and would otherwise be undone by a one-line addition.
assert_equal "the verify step is handed exactly one variable" "IMAGE" \
  "$(workflow_step_env_keys "${WORKFLOW}" "${SIGNATURES_JOB}" "${SIGNATURES_STEP}")"
assert_absent "the signatures job holds no repository secret" \
  "${signatures_block}" 'secrets.'
assert_absent "the signatures job is never given the workflow token" \
  "${signatures_block}" 'github.token'
assert_absent "the signatures job never logs in to a registry" \
  "${signatures_block}" 'docker/login-action'

# Every flavor build.yml publishes has to be a flavor this job verifies. A
# flavor added to the build matrix and not to this one publishes nightly and is
# checked by nobody, which is the same silence as never signing it.
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
signatures_flavors="$(printf '%s\n' "${signatures_block}" | sed -n 's/^ *flavor: //p')"
build_flavors="$(workflow_job_block "${BUILD_WORKFLOW}" build_push | sed -n 's/^ *flavor: //p')"
assert_extracted "build.yml still declares a flavor matrix" "${build_flavors}"
assert_equal "every published flavor is verified nightly" \
  "${build_flavors}" "${signatures_flavors}"

# The signing side and the verifying side must stay on one cosign major: v3
# writes a new bundle format that pre-v3 clients cannot see, which is why
# build.yml's sign step passes --new-bundle-format=false. Both pins are
# written as literals on purpose so renovate's custom manager can match them,
# and a literal is exactly what silently drifts.
signatures_cosign="$(printf '%s\n' "${signatures_block}" | sed -n 's/^ *cosign-release: //p')"
build_cosign="$(workflow_job_block "${BUILD_WORKFLOW}" build_push | sed -n 's/^ *cosign-release: //p')"
assert_extracted "the signatures job still pins a cosign release" "${signatures_cosign}"
# shellcheck disable=SC2016
assert_absent "the cosign pin is a literal renovate can match" "${signatures_cosign}" '${{'
assert_equal "verification uses the same cosign release the build signs with" \
  "${build_cosign}" "${signatures_cosign}"

COSIGN_ARGS="${WORK_DIR}/cosign-args"
COSIGN_ENV="${WORK_DIR}/cosign-env"
cat >"${STUB_DIR}/cosign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${STUB_ARGS_FILE}"
# Record whether anything resembling a registry credential reached the process.
env | sed -n 's/^\(REGISTRY_[A-Z_]*\|GITHUB_TOKEN\|GH_TOKEN\|COSIGN_[A-Z_]*\)=.*/\1/p' \
  >"${STUB_ENV_FILE}"

key=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--key" ]]; then
    j=$((i + 1))
    key="${!j:-}"
  fi
done
if [[ -z "${key}" || ! -f "${key}" ]]; then
  printf 'cosign was given no readable key: %s\n' "${key}" >&2
  exit 91
fi
exit "${STUB_EXIT_CODE:-0}"
STUB
chmod +x "${STUB_DIR}/cosign"

# The job checks out the repository and runs from its root, so the body's
# relative `cosign.pub` is resolved here from the real checkout rather than
# from a fixture that would accept any path at all.
run_signatures() {
  local image="$1" exit_code="${2:-0}"
  : >"${COSIGN_ARGS}"
  : >"${COSIGN_ENV}"
  (
    cd -- "${REPO_ROOT}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      STUB_ARGS_FILE="${COSIGN_ARGS}" \
      STUB_ENV_FILE="${COSIGN_ENV}" \
      STUB_EXIT_CODE="${exit_code}" \
      IMAGE="${image}" \
      "${BASH}" --noprofile --norc -c "${signatures_run}"
  )
}

# The mixed-case reference Actions actually produces for this repository.
MIXED_IMAGE="ghcr.io/Danathar/Arch-BootC-base:latest"
LOWER_IMAGE="ghcr.io/danathar/arch-bootc-base:latest"

output="$(run_signatures "${MIXED_IMAGE}" 0 2>&1)"
status=$?
assert_status "a verifying signature exits 0" 0 "${status}"
printf -v expected_cosign_args '%s\n' "verify" "--key" "cosign.pub" "${LOWER_IMAGE}"
assert_equal "cosign is asked to verify the lowercased reference against the checked-out key" \
  "${expected_cosign_args%$'\n'}" "$(cat "${COSIGN_ARGS}")"
assert_contains "the step names the reference it verified" "${output}" \
  "verifying ${LOWER_IMAGE}"
assert_absent "the uppercase reference never reaches the log" "${output}" "Arch-BootC"
assert_equal "cosign is given no credential of any kind" "" "$(cat "${COSIGN_ENV}")"

# cosign.pub is the file the Containerfile installs as the keyPath the
# in-image policy names, so the path in this body is not free to move
# independently. The stub refuses an unreadable key, so a moved or renamed key
# surfaces here as exit 91 rather than as a nightly failure nobody can
# reproduce.
assert_status "the key the body names exists in the checkout" 0 \
  "$([[ -f "${REPO_ROOT}/cosign.pub" ]] && printf 0 || printf 1)"

# An unsigned or wrongly-signed published image is the entire point of the job.
# `set -euo pipefail` is what turns cosign's non-zero exit into a red run; a
# trailing `|| true`, or a pipeline that swallowed the status, would report a
# compromised image as a healthy night.
output="$(run_signatures "${MIXED_IMAGE}" 1 2>&1)"
status=$?
assert_status "an image cosign rejects fails the step" 1 "${status}"

# Losing the `env:` wiring must not degrade into verifying an empty reference.
# `set -u` is what makes that loud, and it is one word away from not being set.
output="$(
  cd -- "${REPO_ROOT}" || exit 99
  PATH="${STUB_DIR}:${PATH}" \
    STUB_ARGS_FILE="${COSIGN_ARGS}" \
    STUB_ENV_FILE="${COSIGN_ENV}" \
    env -u IMAGE "${BASH}" --noprofile --norc -c "${signatures_run}" 2>&1
)"
status=$?
assert_status "an unset IMAGE fails instead of verifying an empty reference" 1 "${status}"
assert_absent "an unset IMAGE never reaches cosign" "${output}" "verifying"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

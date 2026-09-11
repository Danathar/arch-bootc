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
#
# The file also covers the `signatures` job, and then the two steps of
# build.yml that produce what `signatures` verifies -- `Push To GHCR` and
# `Sign container image`. Those two live here rather than in a file of their
# own because a signature is one property split across two workflows: the pins
# and formats the sign step chooses are only correct relative to what this
# job's verify step can still read, and the assertions tying the two together
# were already here before either body was executed.

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

# --- the producing side: build.yml pushes and signs what this job verifies --
#
# The `signatures` cases above are only as meaningful as the signature they
# find. Two steps in build.yml's build_push job put it there -- `Push To GHCR`
# publishes the tags, and `Sign container image` signs the digest that push
# reported -- and neither body was executed by any test: the assertions above
# read build.yml only for its cosign pin and its flavor matrix.
#
# The two are tested together because the seam between them is the failure this
# section exists to catch. Push writes `digest=` to GITHUB_OUTPUT; sign reads it
# back as `${{ steps.push.outputs.digest }}`. A rename on either side of that
# name resolves to the empty string in the expression, with no error anywhere,
# and the sign step is then handed an image reference with nothing after its
# `@`. So the name is asserted on both sides statically, and the bodies are
# executed against stubs that behave the way the real tools behave when the
# seam is broken.
#
# No network and no registry: `skopeo`, `sleep` and `cosign` are shadowed on
# PATH, record their arguments, and answer from fixtures.

PUSH_STEP="Push To GHCR"
SIGN_STEP="Sign container image"

push_run="$(workflow_step_run "${BUILD_WORKFLOW}" build_push "${PUSH_STEP}")"
assert_extracted "the push step's body is still where this test expects it" \
  "${push_run}"
# shellcheck disable=SC2016
assert_absent "the push step's body is plain shell" "${push_run}" '${{'

sign_run="$(workflow_step_run "${BUILD_WORKFLOW}" build_push "${SIGN_STEP}")"
assert_extracted "the sign step's body is still where this test expects it" \
  "${sign_run}"
# shellcheck disable=SC2016
assert_absent "the sign step's body is plain shell" "${sign_run}" '${{'

# Print one step-level key (`id:`, `if:`) of the named step, unexpanded. The
# step's own `id:` is half of the output seam and lives here rather than in the
# body or the `env:` block.
workflow_step_field() {
  local workflow="$1" job="$2" step="$3" key="$4"
  awk -v want_job="${job}" -v want="${step}" -v key="${key}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
    }
    /^      - name: / { current = substr($0, 15); next }
    current_job == want_job && current == want && $0 ~ ("^        " key ": ") {
      print substr($0, length(key) + 11)
      exit
    }
  ' "${workflow}"
}

# The static half of the seam: the id the expression names, and the expression
# itself. Either one edited alone still parses, still runs, and signs nothing.
assert_equal "the push step still declares the id the sign step's expression reads" \
  "push" "$(workflow_step_field "${BUILD_WORKFLOW}" build_push "${PUSH_STEP}" id)"
# shellcheck disable=SC2016
assert_equal "the sign step is handed the digest the push step reported" \
  '${{ steps.push.outputs.digest }}' \
  "$(workflow_step_env "${BUILD_WORKFLOW}" build_push "${SIGN_STEP}" PUSH_DIGEST)"

# --- the credential both of those steps read --------------------------------
#
# Neither body above takes a credential as an argument. Both resolve one out of
# ${HOME}/.docker/config.json: the push step names that path explicitly with
# --dest-authfile, and `cosign sign` finds the same file through buildah's and
# skopeo's documented resolution order. One step writes it -- `Log in to GHCR
# for the build cache and image signing`, 170 lines earlier in the same job --
# and no test executed that body, so the fixture the push cases used was a
# second, hand-written copy of the file format with nothing tying it to the
# step that produces the real one.
#
# That gap is invisible from either side. A login step that keyed its entry on
# the full image path instead of the registry host, wrote its JSON somewhere
# else, or let base64 wrap its field would leave this file green and turn every
# publish into an anonymous push -- which GHCR reports as a 401 forty minutes
# into a build, reading like a registry outage rather than a workflow edit.
#
# So the body is executed here, and the file it produces *is* the fixture the
# push cases below consume.

LOGIN_STEP="Log in to GHCR for the build cache and image signing"

login_run="$(workflow_step_run "${BUILD_WORKFLOW}" build_push "${LOGIN_STEP}")"
assert_extracted "the login step's body is still where this test expects it" \
  "${login_run}"
# shellcheck disable=SC2016
assert_absent "the login step's body is plain shell" "${login_run}" '${{'

# The credential arrives through `env:` and the body never names a secret, so
# what the step is handed is as much of the decision as what it does with it.
# shellcheck disable=SC2016
assert_equal "the login step is handed the actor GHCR will authenticate" \
  '${{ github.actor }}' \
  "$(workflow_step_env "${BUILD_WORKFLOW}" build_push "${LOGIN_STEP}" REGISTRY_USER)"
# shellcheck disable=SC2016
assert_equal "the login step is handed this run's own token as the password" \
  '${{ github.token }}' \
  "$(workflow_step_env "${BUILD_WORKFLOW}" build_push "${LOGIN_STEP}" REGISTRY_PASSWORD)"
assert_equal "the credential reaches the body through those two variables and no others" \
  "$(printf '%s\n' REGISTRY_USER REGISTRY_PASSWORD)" \
  "$(workflow_step_env_keys "${BUILD_WORKFLOW}" build_push "${LOGIN_STEP}")"

# The step is skipped for pull requests from forks, where GitHub downgrades the
# token to read-only regardless of the `packages: write` permission the job
# asks for. Widening this condition would hand a fork's PR a credential that
# cannot authenticate; narrowing it would skip the login on runs that publish.
# Both the push and sign steps run under a strictly narrower condition (not a
# pull request at all), so this one holds whenever they do.
assert_equal "the login step is skipped only for pull requests from forks" \
  "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository" \
  "$(workflow_step_field "${BUILD_WORKFLOW}" build_push "${LOGIN_STEP}" if)"

# Print the step names of the named job, in the order Actions runs them.
workflow_step_names() {
  local workflow="$1" job="$2"
  workflow_job_block "${workflow}" "${job}" | sed -n 's/^      - name: //p'
}

build_push_steps="$(workflow_step_names "${BUILD_WORKFLOW}" build_push)"
assert_extracted "build_push's step list is still where this test expects it" \
  "${build_push_steps}"

step_index() {
  local want="$1" index=0 name
  while IFS= read -r name; do
    index=$((index + 1))
    if [[ "${name}" == "${want}" ]]; then
      printf '%s' "${index}"
      return 0
    fi
  done <<<"${build_push_steps}"
  printf '0'
}

# Step order is the whole of this file's correctness: a credential written after
# its readers is a credential nobody used. Moving the login step down the list
# is a one-line edit that leaves the workflow valid, leaves every body
# unchanged, and silently anonymizes the cache pull, the push and the signature.
assert_before() {
  local description="$1" earlier="$2" later="$3" a b
  a="$(step_index "${earlier}")"
  b="$(step_index "${later}")"
  if ((a > 0 && b > 0 && a < b)); then
    check "${description}" 0
  else
    check "${description}" 1 "step position ${a} is not before step position ${b}"
  fi
}
assert_before "the credential is written before the build that caches through it" \
  "${LOGIN_STEP}" "Build Image"
assert_before "the credential is written before the push that reads it" \
  "${LOGIN_STEP}" "${PUSH_STEP}"
assert_before "the credential is written before the signature pushed with it" \
  "${LOGIN_STEP}" "${SIGN_STEP}"

LOGIN_DIR="${WORK_DIR}/login"
mkdir -p "${LOGIN_DIR}"

LOGIN_REGISTRY="ghcr.io/danathar"
LOGIN_USER="octocat"
# Not a real credential: distinctive enough for the assertions below to look
# for, and deliberately not named with a prefix the body greps for.
LOGIN_SECRET="ghs-login-fixture-not-a-real-token"

# The umask is an argument because one case needs a hostile one: see below.
run_login() {
  local home="$1" registry="$2" user="$3" secret="$4" mask="${5:-022}"
  (
    umask "${mask}"
    HOME="${home}" \
      IMAGE_REGISTRY="${registry}" \
      REGISTRY_USER="${user}" \
      REGISTRY_PASSWORD="${secret}" \
      "${BASH}" --noprofile --norc -c "${login_run}"
  )
}

# Parse the produced file into the two decisions it encodes: which registry the
# entry is keyed on, and what credential it carries. The pattern covers the
# whole document, so a stray field, a missing brace or a second line fails here
# rather than being tolerated the way a substring search would tolerate it --
# and a container tool handed a malformed auth file does not fall back to
# asking, it falls back to anonymous.
login_auth_host=""
login_auth_blob=""
parse_auth_file() {
  local file="$1" contents
  login_auth_host=""
  login_auth_blob=""
  [[ -f "${file}" ]] || return 1
  contents="$(cat -- "${file}")"
  [[ "${contents}" =~ ^\{\"auths\":\{\"([^\"]+)\":\{\"auth\":\"([^\"]+)\"\}\}\}$ ]] || return 1
  login_auth_host="${BASH_REMATCH[1]}"
  login_auth_blob="${BASH_REMATCH[2]}"
}

login_home="${LOGIN_DIR}/clean"
mkdir -p "${login_home}"
LOGIN_FILE="${login_home}/.docker/config.json"
output="$(run_login "${login_home}" "${LOGIN_REGISTRY}" "${LOGIN_USER}" "${LOGIN_SECRET}" 2>&1)"
status=$?
assert_status "writing the credential file exits 0" 0 "${status}"

# The step creates the directory itself; the fixture above deliberately does
# not, because a login step that assumed ~/.docker already existed would fail
# on a fresh runner and only there.
parse_auth_file "${LOGIN_FILE}"
assert_status "the step writes one whole containers-auth.json document at the path its readers open" \
  0 "$?"
assert_equal "the entry is keyed on the registry host, not on the full image path" \
  "ghcr.io" "${login_auth_host}"
assert_equal "the entry carries the actor and token GHCR will check" \
  "${LOGIN_USER}:${LOGIN_SECRET}" \
  "$(printf '%s' "${login_auth_blob}" | base64 -d)"

# 0600 is the entire reason the push step reads a file instead of passing
# --dest-creds: it narrows a token that /proc/<pid>/cmdline would otherwise
# expose to every uid on the runner down to the uid that wrote it.
assert_equal "the credential file is readable only by the uid that wrote it" \
  "600" "$(stat -c %a -- "${LOGIN_FILE}")"
assert_absent "the token is stored encoded, never in the clear" \
  "$(cat -- "${LOGIN_FILE}")" "${LOGIN_SECRET}"
# These runs are public, so the log is the other route a credential can escape
# by. The step has nothing to report and must report nothing.
assert_equal "the login step prints nothing" "" "${output}"

# base64 wraps its output at 76 columns unless told not to. A GITHUB_TOKEN plus
# an actor name is comfortably past that, so a dropped -w0 embeds a newline in
# the middle of the JSON string -- unparseable, and only on real-length
# credentials, never on a short test value.
long_secret="ghs-"
while ((${#long_secret} < 200)); do
  long_secret+="0123456789"
done
long_home="${LOGIN_DIR}/long-token"
mkdir -p "${long_home}"
run_login "${long_home}" "${LOGIN_REGISTRY}" "${LOGIN_USER}" "${long_secret}" >/dev/null 2>&1
parse_auth_file "${long_home}/.docker/config.json"
assert_status "a full-length token still produces one parseable document" 0 "$?"
assert_equal "a full-length token is encoded without line breaks" \
  "${LOGIN_USER}:${long_secret}" \
  "$(printf '%s' "${login_auth_blob}" | base64 -d)"
assert_equal "the document is a single line" "1" \
  "$(wc -l <"${long_home}/.docker/config.json" | tr -d ' ')"

# The credential is data, not format. `printf '%s:%s' "$user" "$pass"` is safe
# for any value; `printf "${user}:${pass}"` is not, and the difference only
# shows up when a token happens to contain a percent or a backslash -- at which
# point the encoded credential is silently wrong and the push is silently
# anonymous.
# shellcheck disable=SC2016 # the point of the value is that nothing expands it
odd_secret='100%s of \n "value" $HOME'
odd_home="${LOGIN_DIR}/odd-token"
mkdir -p "${odd_home}"
run_login "${odd_home}" "${LOGIN_REGISTRY}" "${LOGIN_USER}" "${odd_secret}" >/dev/null 2>&1
parse_auth_file "${odd_home}/.docker/config.json"
assert_status "a token holding format characters still produces one parseable document" \
  0 "$?"
assert_equal "a token holding format characters is encoded verbatim" \
  "${LOGIN_USER}:${odd_secret}" \
  "$(printf '%s' "${login_auth_blob}" | base64 -d)"

# A rerun on a warm runner, and the case that proves the chmod is doing work:
# under a permissive umask a file created without it stays world-readable, so
# dropping the chmod would pass under the default umask and leak here. The
# stale content also has to be replaced rather than appended to -- `>>` would
# leave a document no consumer can parse.
loose_home="${LOGIN_DIR}/loose"
mkdir -p "${loose_home}/.docker"
printf 'stale content from an earlier run\n' >"${loose_home}/.docker/config.json"
chmod 644 "${loose_home}/.docker/config.json"
run_login "${loose_home}" "${LOGIN_REGISTRY}" "${LOGIN_USER}" "${LOGIN_SECRET}" 000 >/dev/null 2>&1
parse_auth_file "${loose_home}/.docker/config.json"
assert_status "an existing credential file is replaced, not appended to" 0 "$?"
assert_equal "the credential is not world-readable even under a permissive umask" \
  "600" "$(stat -c %a -- "${loose_home}/.docker/config.json")"
assert_absent "no content from the previous run survives" \
  "$(cat -- "${loose_home}/.docker/config.json")" "stale content"

# `set -euo pipefail` decides what a missing input does. Failing here is the
# only acceptable outcome: a file holding `octocat:` or an empty auths entry
# would satisfy the push step's readability check and then push anonymously,
# and the first report of that would be a 401 from GHCR at the end of the build.
for missing in REGISTRY_PASSWORD IMAGE_REGISTRY; do
  missing_home="${LOGIN_DIR}/missing-${missing}"
  mkdir -p "${missing_home}"
  output="$(
    HOME="${missing_home}" \
      IMAGE_REGISTRY="${LOGIN_REGISTRY}" \
      REGISTRY_USER="${LOGIN_USER}" \
      REGISTRY_PASSWORD="${LOGIN_SECRET}" \
      env -u "${missing}" "${BASH}" --noprofile --norc -c "${login_run}" 2>&1
  )"
  status=$?
  assert_status "an unset ${missing} fails the step" 1 "${status}"
  if [[ ! -e "${missing_home}/.docker/config.json" ]]; then
    check "an unset ${missing} leaves no half-written credential behind" 0
  else
    check "an unset ${missing} leaves no half-written credential behind" 1 \
      "wrote $(cat -- "${missing_home}/.docker/config.json")"
  fi
done

# --- the step that produces the layout the push step reads -----------------
#
# The push cases below take `CHUNKAH_OCI_DIR` as a fixture. Nothing produces
# it: the directory is invented here, handed to the body, and every assertion
# downstream is true of a path this test made up. The step that really creates
# it -- `Rechunk image with chunkah` -- runs immediately before the push in the
# same job, writes that variable into GITHUB_ENV, and was executed by no test.
#
# That is the same output-seam failure the push/sign pair above exists to
# catch, one step earlier and with no error anywhere along it. `GITHUB_ENV` is
# a name written on one side and read on the other; rename it, move the write
# under a condition the push does not share, or fail out of the step before the
# write, and the push step is handed an unset variable. What follows is a
# 40-minute build that ends with skopeo reading `oci::name:chunked`, or -- if
# a stale layout from a previous run survived in RUNNER_TEMP -- a publish of
# yesterday's image under today's tags.
#
# So the body is executed here, and the OCI directory the push cases consume is
# the one this step reports rather than a hand-written path.
#
# No container runtime and no network: `buildah`, `podman`, `skopeo` and `df`
# are shadowed on PATH, record their argv, and answer from fixtures.

RECHUNK_STEP="Rechunk image with chunkah"

rechunk_run_raw="$(workflow_step_run "${BUILD_WORKFLOW}" build_push "${RECHUNK_STEP}")"
assert_extracted "the rechunk step's body is still where this test expects it" \
  "${rechunk_run_raw}"

# Unlike every other body in this file, this one is not plain shell: the work
# directory is flavor-scoped and the matrix value is pasted in as text. The
# step's own comment explains why every *other* expansion there travels through
# `env:` -- a `${{ }}` inside a `run:` block is substituted before the shell
# sees it, so a value carrying a quote or a semicolon would execute as code.
# What makes this one safe is that `matrix.flavor` can only ever be one of the
# literals in the job's own matrix. Pinning the exact set of expressions is
# therefore a security assertion, not a bookkeeping one: an expression added
# here that reads a tag, a branch, a title or any other externally supplied
# value is a shell injection into a job holding `packages: write`.
# shellcheck disable=SC2016 # the literal expression, not its expansion
flavor_expr='${{ matrix.flavor }}'
# shellcheck disable=SC2016 # ditto: this is the pattern that finds them
rechunk_expressions="$(printf '%s\n' "${rechunk_run_raw}" | grep -o '\${{[^}]*}}' | sort -u)"
assert_equal "the matrix flavor is the only expression pasted into the rechunk body" \
  "${flavor_expr}" "${rechunk_expressions}"

RECHUNK_FLAVOR="kde"
assert_contains "the flavor these cases substitute is one build.yml actually builds" \
  "${build_flavors}" "${RECHUNK_FLAVOR}"
rechunk_run="${rechunk_run_raw//"${flavor_expr}"/${RECHUNK_FLAVOR}}"
# shellcheck disable=SC2016
assert_absent "substituting the flavor leaves plain shell behind" "${rechunk_run}" '${{'

# The tags arrive the same way they reach the push step, and by the same route
# for the same reason. They are the only input the step takes from an
# expression, and the first of them names the image chunkah reads.
# shellcheck disable=SC2016
assert_equal "the rechunk step is handed the tags the metadata action computed" \
  '${{ steps.metadata.outputs.tags }}' \
  "$(workflow_step_env "${BUILD_WORKFLOW}" build_push "${RECHUNK_STEP}" METADATA_TAGS)"
assert_equal "the tags reach the body through that variable and no others" \
  "METADATA_TAGS" \
  "$(workflow_step_env_keys "${BUILD_WORKFLOW}" build_push "${RECHUNK_STEP}")"

# The static half of the seam. `CHUNKAH_OCI_DIR` is set by this step alone, so
# the push step runs on exactly the runs this one did. A condition that let the
# push run without the rechunk -- a PR build, a branch build -- would reach
# skopeo with the variable unset. Asserting the two conditions are the same
# string is stronger than asserting either one: they have to move together.
assert_equal "the rechunk runs on exactly the runs that push" \
  "$(workflow_step_field "${BUILD_WORKFLOW}" build_push "${PUSH_STEP}" if)" \
  "$(workflow_step_field "${BUILD_WORKFLOW}" build_push "${RECHUNK_STEP}" if)"
assert_extracted "the rechunk step still carries a condition at all" \
  "$(workflow_step_field "${BUILD_WORKFLOW}" build_push "${RECHUNK_STEP}" if)"
assert_before "the layout is produced before the push that reads it" \
  "${RECHUNK_STEP}" "${PUSH_STEP}"
assert_before "the credential is written before the cache pulls this step prune around" \
  "${LOGIN_STEP}" "${RECHUNK_STEP}"

RECHUNK_DIR="${WORK_DIR}/rechunk"
RECHUNK_STUBS="${RECHUNK_DIR}/bin"
RECHUNK_RUNNER_TEMP="${RECHUNK_DIR}/runner-temp"
RECHUNK_CALL_LOG="${RECHUNK_DIR}/calls"
RECHUNK_ENV_FILE="${RECHUNK_DIR}/github-env"
RECHUNK_CONFIG_SEEN="${RECHUNK_DIR}/chunkah-config"
RECHUNK_INSPECT_JSON="${RECHUNK_DIR}/inspect.json"
RECHUNK_MANIFEST_JSON="${RECHUNK_DIR}/manifest.json"
mkdir -p "${RECHUNK_STUBS}" "${RECHUNK_RUNNER_TEMP}"

RECHUNK_IMAGE_NAME="arch-bootc-base"
RECHUNK_CHUNKAH_IMAGE="quay.io/coreos/chunkah:v0.6.0"

# Stands in for the source image's config. chunkah rebuilds the rechunked
# image's config from this string, so it is the carrier for the labels and the
# entrypoint that make the result bootable -- an image that arrives without
# them pushes and signs exactly like a good one.
printf '%s\n' '[{"Config":{"Labels":{"containers.bootc":"1"}}}]' \
  >"${RECHUNK_INSPECT_JSON}"
printf '%s\n' '{"layers":[{"size":1},{"size":2},{"size":3}]}' \
  >"${RECHUNK_MANIFEST_JSON}"

cat >"${RECHUNK_STUBS}/podman" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

printf '%s %s\n' "$(basename -- "$0")" "$*" >>"${RECHUNK_CALL_LOG}"

case "${1:-}" in
  inspect)
    if [[ "${RECHUNK_PODMAN_INSPECT_EXIT:-0}" != 0 ]]; then
      printf 'no such object\n' >&2
      exit "${RECHUNK_PODMAN_INSPECT_EXIT}"
    fi
    cat -- "${RECHUNK_INSPECT_JSON}"
    ;;
  pull | rmi | image) ;;
  run)
    # Recorded from the environment rather than from argv: `-e NAME` passes no
    # value, so an unexported variable reaches the container empty and chunkah
    # is the only thing that would notice.
    printf '%s' "${CHUNKAH_CONFIG_STR-}" >"${RECHUNK_CONFIG_SEEN}"
    out=""
    for arg in "$@"; do
      case "${arg}" in
        --mount=type=bind,src=*,dst=/out)
          out="${arg#--mount=type=bind,src=}"
          out="${out%,dst=/out}"
          ;;
      esac
    done
    if [[ -z "${out}" ]]; then
      printf 'chunkah was given no output bind mount\n' >&2
      exit 93
    fi
    if [[ "${RECHUNK_PODMAN_RUN_EXIT:-0}" != 0 ]]; then
      printf 'simulated chunkah failure\n' >&2
      exit "${RECHUNK_PODMAN_RUN_EXIT}"
    fi
    mkdir -p "${out}/oci"
    ;;
  *)
    printf 'unexpected podman subcommand: %s\n' "${1:-}" >&2
    exit 91
    ;;
esac
STUB
chmod +x "${RECHUNK_STUBS}/podman"

# A fresh runner has no build containers and no dangling layers, and `buildah
# rm --all` reports that as a failure. Every call site tolerates it; the
# tolerated exit code is configurable so a case below can prove that.
cat >"${RECHUNK_STUBS}/buildah" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s %s\n' "$(basename -- "$0")" "$*" >>"${RECHUNK_CALL_LOG}"
exit "${RECHUNK_BUILDAH_EXIT:-0}"
STUB
chmod +x "${RECHUNK_STUBS}/buildah"

cat >"${RECHUNK_STUBS}/skopeo" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s %s\n' "$(basename -- "$0")" "$*" >>"${RECHUNK_CALL_LOG}"
cat -- "${RECHUNK_MANIFEST_JSON}"
STUB
chmod +x "${RECHUNK_STUBS}/skopeo"

# Recorded, not run: the real output is four screens of runner filesystems and
# says nothing this test can assert on.
cat >"${RECHUNK_STUBS}/df" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s %s\n' "$(basename -- "$0")" "$*" >>"${RECHUNK_CALL_LOG}"
STUB
chmod +x "${RECHUNK_STUBS}/df"

run_rechunk() {
  local body="$1" tags="$2"
  : >"${RECHUNK_CALL_LOG}"
  : >"${RECHUNK_ENV_FILE}"
  : >"${RECHUNK_CONFIG_SEEN}"
  (
    PATH="${RECHUNK_STUBS}:${PATH}" \
      RECHUNK_CALL_LOG="${RECHUNK_CALL_LOG}" \
      RECHUNK_CONFIG_SEEN="${RECHUNK_CONFIG_SEEN}" \
      RECHUNK_INSPECT_JSON="${RECHUNK_INSPECT_JSON}" \
      RECHUNK_MANIFEST_JSON="${RECHUNK_MANIFEST_JSON}" \
      RECHUNK_BUILDAH_EXIT="${RECHUNK_BUILDAH_EXIT:-0}" \
      RECHUNK_PODMAN_RUN_EXIT="${RECHUNK_PODMAN_RUN_EXIT:-0}" \
      RECHUNK_PODMAN_INSPECT_EXIT="${RECHUNK_PODMAN_INSPECT_EXIT:-0}" \
      IMAGE_NAME="${RECHUNK_IMAGE_NAME}" \
      CHUNKAH_IMAGE="${RECHUNK_CHUNKAH_IMAGE}" \
      RUNNER_TEMP="${RECHUNK_RUNNER_TEMP}" \
      GITHUB_ENV="${RECHUNK_ENV_FILE}" \
      METADATA_TAGS="${tags}" \
      "${BASH}" --noprofile --norc -c "${body}"
  )
}

# Line number of the first recorded call matching the pattern, or 0.
call_index() {
  local pattern="$1" index
  index="$(grep -n -m 1 -- "${pattern}" "${RECHUNK_CALL_LOG}" | cut -d: -f1)"
  printf '%s' "${index:-0}"
}
assert_call_order() {
  local description="$1" earlier="$2" later="$3" a b
  a="$(call_index "${earlier}")"
  b="$(call_index "${later}")"
  if ((a > 0 && b > 0 && a < b)); then
    check "${description}" 0
  else
    check "${description}" 1 "call position ${a} is not before call position ${b}"
  fi
}

# The stale layout this run has to overwrite. A rechunk that reused it would
# publish a previous build's rootfs under this build's tags and this build's
# signature, and nothing downstream can tell the difference: the digest push
# reports is the digest of whatever was in the directory.
RECHUNK_WORK_DIR="${RECHUNK_RUNNER_TEMP}/chunkah-${RECHUNK_FLAVOR}"
mkdir -p "${RECHUNK_WORK_DIR}/oci"
printf 'from an earlier run\n' >"${RECHUNK_WORK_DIR}/oci/index.json"

RECHUNK_TAGS="latest 20260910"
output="$(run_rechunk "${rechunk_run}" "${RECHUNK_TAGS}" 2>&1)"
status=$?
assert_status "a clean rechunk exits 0" 0 "${status}"

# The output half of the seam, executed. The name has to be the one the push
# body reads, and the value has to be the directory chunkah actually wrote to.
assert_equal "the rechunked layout is reported under the name the push step reads" \
  "CHUNKAH_OCI_DIR=${RECHUNK_WORK_DIR}/oci" "$(cat "${RECHUNK_ENV_FILE}")"
rechunk_oci_dir="$(sed -n 's/^CHUNKAH_OCI_DIR=//p' <"${RECHUNK_ENV_FILE}")"
assert_extracted "the reported layout directory has a value" "${rechunk_oci_dir}"
if [[ -d "${rechunk_oci_dir}" ]]; then
  check "the reported directory is the one chunkah wrote" 0
else
  check "the reported directory is the one chunkah wrote" 1 \
    "${rechunk_oci_dir} does not exist"
fi
assert_contains "the push body reads the variable this step exports" \
  "${push_run}" 'CHUNKAH_OCI_DIR'
assert_absent "no file from the previous run survives into the published layout" \
  "$(cat -- "${rechunk_oci_dir}/index.json" 2>/dev/null || true)" "from an earlier run"

# `sep-tags: " "` makes METADATA_TAGS one space-separated string, and only the
# first tag names an image that exists in local storage at this point -- they
# all point at the same build, so any of them would do, but the whole string is
# not a reference. `awk '{print $1}'` is what reduces it to one; a quoted
# expansion or a `$NF` here asks podman for an image nothing built.
assert_equal "the source image is the first metadata tag, not the whole tag list" \
  "podman inspect ${RECHUNK_IMAGE_NAME}:latest" \
  "$(grep '^podman inspect ' "${RECHUNK_CALL_LOG}")"

# Whole argv. Every flag is load-bearing and none of them fails locally:
# without --compressed the layout is uncompressed blobs that push far slower
# and blow the runner's disk; without --output the result lands in
# containers-storage, which is the copy this step exists to avoid; a changed
# --max-layers silently reshapes every future incremental pull.
printf -v expected_chunkah_call '%s' \
  "podman run --rm" \
  " --mount=type=image,src=${RECHUNK_IMAGE_NAME}:latest,dst=/chunkah" \
  " --mount=type=bind,src=${RECHUNK_WORK_DIR},dst=/out" \
  " -e CHUNKAH_CONFIG_STR" \
  " ${RECHUNK_CHUNKAH_IMAGE}" \
  " build -v --max-layers 96 --compressed" \
  " --output oci:/out/oci" \
  " -t ${RECHUNK_IMAGE_NAME}:chunked"
assert_equal "chunkah reads the source rootfs and writes the OCI layout directly to disk" \
  "${expected_chunkah_call}" "$(grep '^podman run ' "${RECHUNK_CALL_LOG}")"

# `-e NAME` forwards a variable by name and passes nothing at all if it is not
# exported. chunkah then rebuilds the image config from an empty string, and
# the result pushes, signs and verifies exactly like a correct image while
# having lost the labels that make it bootable.
assert_equal "the source image config reaches chunkah through the exported variable" \
  "$(cat -- "${RECHUNK_INSPECT_JSON}")" "$(cat -- "${RECHUNK_CONFIG_SEEN}")"

# Ordering is the whole of this step's disk budget. The prune has to happen
# before chunkah runs -- that is the space chunkah writes into -- and the
# source images have to survive until it has read them.
assert_call_order "the local intermediates are dropped before chunkah runs" \
  '^buildah prune -f$' '^podman run '
assert_call_order "the source image survives until chunkah has read it" \
  '^podman run ' "^podman rmi ${RECHUNK_IMAGE_NAME}:latest\$"
assert_call_order "the layout is measured after it is written" \
  '^podman run ' '^skopeo inspect '

# Unquoted on purpose, as in the push step: every tag points at the same build
# and each one is a separate entry in local storage, so a quoted expansion
# removes nothing and leaves the full uncompressed image on disk for the push.
printf -v expected_rmi_calls '%s\n' \
  "podman rmi ${RECHUNK_IMAGE_NAME}:latest" \
  "podman rmi ${RECHUNK_IMAGE_NAME}:20260910" \
  "podman rmi ${RECHUNK_CHUNKAH_IMAGE}"
assert_equal "every metadata tag and the chunkah image are removed before the push" \
  "${expected_rmi_calls%$'\n'}" "$(grep '^podman rmi ' "${RECHUNK_CALL_LOG}")"

assert_contains "the layer count of the produced layout is reported" \
  "${output}" "Rechunked layer count: 3"
# The rechunk is the longest step in the job and its log is the only place the
# per-package layer split is visible. An unfolded group buries the rest of the
# job's output under chunkah's.
assert_contains "chunkah's output is folded into a log group" "${output}" \
  "::group::Rechunking ${RECHUNK_IMAGE_NAME}:latest"
assert_contains "the log group is closed" "${output}" "::endgroup::"

# Three flavors build in parallel from one workflow and each writes an OCI
# layout of its own. The flavor in the path is what keeps them apart; drop it
# and two matrix legs sharing a runner temp overwrite each other's layout
# between the rechunk and the push, which publishes one flavor's rootfs under
# another flavor's tags.
other_flavor="base"
assert_contains "the second flavor these cases use is one build.yml builds" \
  "${build_flavors}" "${other_flavor}"
other_run="${rechunk_run_raw//"${flavor_expr}"/${other_flavor}}"
run_rechunk "${other_run}" "${RECHUNK_TAGS}" >/dev/null 2>&1
assert_status "a second flavor's rechunk exits 0" 0 "$?"
assert_equal "each flavor reports a layout directory of its own" \
  "CHUNKAH_OCI_DIR=${RECHUNK_RUNNER_TEMP}/chunkah-${other_flavor}/oci" \
  "$(cat "${RECHUNK_ENV_FILE}")"

# A warm runner has containers and layers to drop; a cold one does not, and
# `buildah rm --all` exits nonzero when there is nothing to remove. Under
# `set -e` that is a failed publish on the first build after a runner image
# update, which is why all four cleanup calls are tolerated.
(RECHUNK_BUILDAH_EXIT=1 run_rechunk "${rechunk_run}" "${RECHUNK_TAGS}") >/dev/null 2>&1
assert_status "a cleanup that finds nothing to remove does not fail the step" 0 "$?"
assert_contains "the rechunk still runs after a no-op cleanup" \
  "$(cat "${RECHUNK_CALL_LOG}")" "podman run --rm"

# The failure that must not be silent. chunkah exiting nonzero with the
# variable already reported would hand the push step a directory holding
# nothing, or holding the previous run's layout, and the first report of it
# would be whoever pulled the image.
output="$(RECHUNK_PODMAN_RUN_EXIT=1 run_rechunk "${rechunk_run}" "${RECHUNK_TAGS}" 2>&1)"
status=$?
assert_status "a failed rechunk fails the step" 1 "${status}"
assert_equal "a failed rechunk reports no layout directory" "" \
  "$(cat "${RECHUNK_ENV_FILE}")"

# Same property one command earlier. An unreadable source image makes
# CHUNKAH_CONFIG_STR empty, and an empty config is not an error to chunkah --
# it is an image with no labels and no entrypoint.
output="$(RECHUNK_PODMAN_INSPECT_EXIT=1 run_rechunk "${rechunk_run}" "${RECHUNK_TAGS}" 2>&1)"
status=$?
assert_status "an unreadable source image fails the step" 1 "${status}"
assert_absent "an unreadable source image is never rechunked" \
  "$(cat "${RECHUNK_CALL_LOG}")" "podman run --rm"
assert_equal "an unreadable source image reports no layout directory" "" \
  "$(cat "${RECHUNK_ENV_FILE}")"

# `set -u` decides what a missing input does. Without it the source reference
# is `:` plus whatever awk made of an empty string, and the step would go on to
# report a layout directory for an image it never read.
: >"${RECHUNK_CALL_LOG}"
: >"${RECHUNK_ENV_FILE}"
output="$(
  PATH="${RECHUNK_STUBS}:${PATH}" \
    RECHUNK_CALL_LOG="${RECHUNK_CALL_LOG}" \
    RECHUNK_CONFIG_SEEN="${RECHUNK_CONFIG_SEEN}" \
    RECHUNK_INSPECT_JSON="${RECHUNK_INSPECT_JSON}" \
    RECHUNK_MANIFEST_JSON="${RECHUNK_MANIFEST_JSON}" \
    IMAGE_NAME="${RECHUNK_IMAGE_NAME}" \
    CHUNKAH_IMAGE="${RECHUNK_CHUNKAH_IMAGE}" \
    RUNNER_TEMP="${RECHUNK_RUNNER_TEMP}" \
    GITHUB_ENV="${RECHUNK_ENV_FILE}" \
    env -u METADATA_TAGS "${BASH}" --noprofile --norc -c "${rechunk_run}" 2>&1
)"
status=$?
assert_status "an unset tag list fails the step" 1 "${status}"
assert_equal "an unset tag list reports no layout directory" "" \
  "$(cat "${RECHUNK_ENV_FILE}")"

# Restore the clean run's state for the push cases below, which consume the
# directory this step reported rather than a path of their own invention.
run_rechunk "${rechunk_run}" "${RECHUNK_TAGS}" >/dev/null 2>&1
assert_status "the rechunk that feeds the push cases below exits 0" 0 "$?"
rechunk_oci_dir="$(sed -n 's/^CHUNKAH_OCI_DIR=//p' <"${RECHUNK_ENV_FILE}")"
assert_extracted "the push cases below have a real layout directory to read" \
  "${rechunk_oci_dir}"

PUSH_DIR="${WORK_DIR}/push"
PUSH_STUBS="${PUSH_DIR}/bin"
PUSH_RUNNER_TEMP="${PUSH_DIR}/runner-temp"
SKOPEO_CALL_LOG="${PUSH_DIR}/skopeo-calls"
SKOPEO_ATTEMPT_FILE="${PUSH_DIR}/skopeo-attempts"
SLEEP_LOG="${PUSH_DIR}/sleeps"
PUSH_OUTPUT="${PUSH_DIR}/github-output"
mkdir -p "${PUSH_STUBS}" "${PUSH_RUNNER_TEMP}"

PUSH_REGISTRY="ghcr.io/danathar"
# The same image name and the same layout directory the rechunk step above
# produced, rather than values invented here: the reference the push step
# builds has to be one the step before it actually wrote.
PUSH_IMAGE_NAME="${RECHUNK_IMAGE_NAME}"
PUSH_OCI_DIR="${rechunk_oci_dir}"
PUSHED_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
# Not a real credential: the value only has to be distinctive enough that the
# leak assertions below can look for it. The variable is deliberately not named
# with any prefix the body or the stubs grep for.
PUSH_ACTOR="octocat"
PUSH_SECRET="ghs-fixture-not-a-real-token"

# The body reads the credential out of ${HOME}/.docker/config.json rather than
# taking it as an argument, so the fixture has to provide one: a private HOME
# holding the file the login step writes, with the secret inside it. It is
# reachable to the body exactly the way the real one is, and to the assertions
# below as a value that must not turn up in skopeo's argv.
#
# Produced by executing the login step rather than by hand. A hand-written copy
# would keep passing after the real step stopped writing anything the push step
# can use, which is the one failure these cases exist to catch.
PUSH_HOME="${PUSH_DIR}/home"
PUSH_AUTH_FILE="${PUSH_HOME}/.docker/config.json"
mkdir -p "${PUSH_HOME}"
run_login "${PUSH_HOME}" "${PUSH_REGISTRY}" "${PUSH_ACTOR}" "${PUSH_SECRET}" >/dev/null 2>&1
parse_auth_file "${PUSH_AUTH_FILE}"
assert_status "the login step supplies the credential file the push step reads" 0 "$?"
# Without this the leak assertions further down are vacuous: a fixture that did
# not actually contain the secret would pass every "never reaches argv" check
# by containing nothing at all.
assert_equal "the supplied credential is the one the leak assertions search for" \
  "${PUSH_ACTOR}:${PUSH_SECRET}" \
  "$(printf '%s' "${login_auth_blob}" | base64 -d)"

# skopeo succeeds by writing the digest file the body reads, and fails the
# first SKOPEO_FAIL_FIRST attempts of the process so the backoff loop can be
# driven from the outside. The attempt counter is per-process, not per-tag.
cat >"${PUSH_STUBS}/skopeo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${SKOPEO_CALL_LOG}"

attempt=$(($(cat "${SKOPEO_ATTEMPT_FILE}") + 1))
printf '%s' "${attempt}" >"${SKOPEO_ATTEMPT_FILE}"

if ((attempt <= ${SKOPEO_FAIL_FIRST:-0})); then
  printf 'simulated GHCR secondary rate limit\n' >&2
  exit 1
fi

digestfile=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--digestfile" ]]; then
    j=$((i + 1))
    digestfile="${!j:-}"
  fi
done
if [[ -z "${digestfile}" ]]; then
  printf 'skopeo copy was not asked for a digest file\n' >&2
  exit 92
fi
printf '%s' "${SKOPEO_DIGEST}" >"${digestfile}"
STUB
chmod +x "${PUSH_STUBS}/skopeo"

# The delays are 60, 120 and 240 seconds. A test that let them elapse would
# take seven minutes to reach one assertion, so `sleep` records instead.
cat >"${PUSH_STUBS}/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-}" >>"${SLEEP_LOG}"
STUB
chmod +x "${PUSH_STUBS}/sleep"

run_push() {
  local tags="$1" fail_first="${2:-0}"
  : >"${SKOPEO_CALL_LOG}"
  : >"${SLEEP_LOG}"
  : >"${PUSH_OUTPUT}"
  printf '0' >"${SKOPEO_ATTEMPT_FILE}"
  rm -f -- "${PUSH_RUNNER_TEMP}/push-digest"
  (
    PATH="${PUSH_STUBS}:${PATH}" \
      SKOPEO_CALL_LOG="${SKOPEO_CALL_LOG}" \
      SKOPEO_ATTEMPT_FILE="${SKOPEO_ATTEMPT_FILE}" \
      SKOPEO_FAIL_FIRST="${fail_first}" \
      SKOPEO_DIGEST="${PUSHED_DIGEST}" \
      SLEEP_LOG="${SLEEP_LOG}" \
      IMAGE_REGISTRY="${PUSH_REGISTRY}" \
      IMAGE_NAME="${PUSH_IMAGE_NAME}" \
      CHUNKAH_OCI_DIR="${PUSH_OCI_DIR}" \
      RUNNER_TEMP="${PUSH_RUNNER_TEMP}" \
      GITHUB_OUTPUT="${PUSH_OUTPUT}" \
      HOME="${PUSH_HOME}" \
      METADATA_TAGS="${tags}" \
      "${BASH}" --noprofile --norc -c "${push_run}"
  )
}

# The metadata action emits its tags newline- or space-separated in one string,
# and the body expands it unquoted on purpose. Two tags therefore have to
# become two pushes: a quoted expansion would ask the registry for a single tag
# with a space in it, which GHCR rejects only at the end of a 40-minute build.
output="$(run_push "latest 20260910" 2>&1)"
status=$?
assert_status "a clean push of two tags exits 0" 0 "${status}"
printf -v expected_push_calls '%s\n' \
  "copy --retry-times 3 --dest-authfile ${PUSH_AUTH_FILE} --digestfile ${PUSH_RUNNER_TEMP}/push-digest oci:${PUSH_OCI_DIR}:${PUSH_IMAGE_NAME}:chunked docker://${PUSH_REGISTRY}/${PUSH_IMAGE_NAME}:latest" \
  "copy --retry-times 3 --dest-authfile ${PUSH_AUTH_FILE} --digestfile ${PUSH_RUNNER_TEMP}/push-digest oci:${PUSH_OCI_DIR}:${PUSH_IMAGE_NAME}:chunked docker://${PUSH_REGISTRY}/${PUSH_IMAGE_NAME}:20260910"
assert_equal "every metadata tag is pushed from the rechunked OCI layout" \
  "${expected_push_calls%$'\n'}" "$(cat "${SKOPEO_CALL_LOG}")"
assert_equal "a clean push never sleeps" "" "$(cat "${SLEEP_LOG}")"

# The whole-argv assertion above already pins the flag, but it would still pass
# if a future edit added the credential back alongside the auth file. This is
# the property stated on its own: /proc/<pid>/cmdline is mode 0444, so a token
# on this command line is readable by every uid on the runner for as long as
# the push runs. It reached skopeo through a 0600 file instead, and the whole
# recorded command line is searched for it.
assert_absent "the registry password never reaches skopeo's command line" \
  "$(cat "${SKOPEO_CALL_LOG}")" "${PUSH_SECRET}"
assert_absent "the auth file is named rather than its contents inlined" \
  "$(cat "${SKOPEO_CALL_LOG}")" "--dest-creds"

# The two steps joined, live. A containers-auth.json entry authenticates for
# exactly the host it is keyed on, and each step derives that host separately:
# the login step strips the path off IMAGE_REGISTRY, the push step keeps the
# whole value as the destination. If those ever disagree -- a login step keyed
# on `ghcr.io/danathar`, a registry variable that grows another path segment --
# skopeo finds no matching entry and pushes anonymously with the credential
# sitting right there on disk.
push_destination="$(sed -n 's|.*docker://||p' <"${SKOPEO_CALL_LOG}" | head -n 1)"
assert_extracted "the recorded push has a registry destination" "${push_destination}"
parse_auth_file "${PUSH_AUTH_FILE}"
assert_equal "the credential is keyed on the host the push is addressed to" \
  "${login_auth_host}" "${push_destination%%/*}"

# The output half of the seam, executed. The key has to be `digest`, and the
# value has to be what skopeo reported rather than a tag or an empty line.
assert_equal "the pushed digest is reported on the step output named in the expression" \
  "digest=${PUSHED_DIGEST}" "$(cat "${PUSH_OUTPUT}")"

# Argv is no longer a route, so the log is the remaining one: it is readable by
# anyone who can read the run, and these runs are public.
assert_absent "the registry password is never printed" "${output}" "${PUSH_SECRET}"

# The auth file is now load-bearing, and the login step that writes it is 170
# lines away under an `if:` of its own. If it is ever renamed, moved after this
# step, or changed to a different path, this step has to say so by name --
# otherwise skopeo would fall through to an anonymous push and the failure
# would first appear as a registry 401 forty minutes into a build, which reads
# like a GHCR problem rather than a workflow edit.
missing_home="${PUSH_DIR}/home-without-auth"
mkdir -p "${missing_home}"
: >"${SKOPEO_CALL_LOG}"
output="$(
  PATH="${PUSH_STUBS}:${PATH}" \
    SKOPEO_CALL_LOG="${SKOPEO_CALL_LOG}" \
    SKOPEO_ATTEMPT_FILE="${SKOPEO_ATTEMPT_FILE}" \
    SKOPEO_DIGEST="${PUSHED_DIGEST}" \
    SLEEP_LOG="${SLEEP_LOG}" \
    IMAGE_REGISTRY="${PUSH_REGISTRY}" \
    IMAGE_NAME="${PUSH_IMAGE_NAME}" \
    CHUNKAH_OCI_DIR="${PUSH_OCI_DIR}" \
    RUNNER_TEMP="${PUSH_RUNNER_TEMP}" \
    GITHUB_OUTPUT="${PUSH_OUTPUT}" \
    HOME="${missing_home}" \
    METADATA_TAGS="latest" \
    "${BASH}" --noprofile --norc -c "${push_run}" 2>&1
)"
status=$?
assert_status "a missing auth file fails the step" 1 "${status}"
assert_contains "the missing auth file is named" "${output}" \
  "${missing_home}/.docker/config.json"
assert_equal "no anonymous push is attempted without the auth file" "" \
  "$(cat "${SKOPEO_CALL_LOG}")"

# GHCR's secondary rate limit is the reason the loop exists. The delays must be
# taken in ascending order: an index off by one would sleep 240 seconds first,
# or skip the short first wait that recovers most of these failures.
output="$(run_push "latest" 2 2>&1)"
status=$?
assert_status "a push that succeeds on the third attempt exits 0" 0 "${status}"
assert_equal "a retried push is attempted until it succeeds" "3" \
  "$(wc -l <"${SKOPEO_CALL_LOG}" | tr -d ' ')"
printf -v expected_sleeps '%s\n' 60 120
assert_equal "the backoff waits 60 then 120 seconds" \
  "${expected_sleeps%$'\n'}" "$(cat "${SLEEP_LOG}")"
assert_equal "a push that eventually succeeded still reports its digest" \
  "digest=${PUSHED_DIGEST}" "$(cat "${PUSH_OUTPUT}")"

# The loop has to give up. It also has to give up *before* writing an output:
# reporting a digest for an image that was never published would hand the sign
# step below a reference to nothing, and the failure would first be visible to
# whoever pulled the image.
output="$(run_push "latest" 99 2>&1)"
status=$?
assert_status "a push that never succeeds fails the step" 1 "${status}"
assert_equal "the push is attempted exactly four times" "4" \
  "$(wc -l <"${SKOPEO_CALL_LOG}" | tr -d ' ')"
printf -v expected_sleeps '%s\n' 60 120 240
assert_equal "every configured delay is used before giving up" \
  "${expected_sleeps%$'\n'}" "$(cat "${SLEEP_LOG}")"
assert_absent "a failed push reports no digest" "$(cat "${PUSH_OUTPUT}")" "digest="
assert_absent "the registry password is never printed on failure" \
  "${output}" "${PUSH_SECRET}"

SIGN_DIR="${WORK_DIR}/sign"
SIGN_STUBS="${SIGN_DIR}/bin"
SIGN_ARGS="${SIGN_DIR}/cosign-args"
SIGN_KEY_SEEN="${SIGN_DIR}/cosign-key"
mkdir -p "${SIGN_STUBS}"

# A second cosign stub rather than the verify one above: this step signs with
# `--key env://`, so a stub that insists on a readable key *file* would reject
# the correct invocation. What it does insist on is a resolvable reference,
# because that is what real cosign does with `image@` and nothing after it, and
# an empty digest is the exact outcome of a broken output seam.
cat >"${SIGN_STUBS}/cosign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${SIGN_ARGS_FILE}"
printf '%s' "${COSIGN_PRIVATE_KEY:-}" >"${SIGN_KEY_FILE}"

ref="${!#}"
if [[ "${ref}" != *"@sha256:"?* ]]; then
  printf 'invalid reference: %s\n' "${ref}" >&2
  exit 1
fi
exit "${SIGN_EXIT_CODE:-0}"
STUB
chmod +x "${SIGN_STUBS}/cosign"

# Multi-line, because the real value is a PEM block and the assertion below is
# what would catch it arriving flattened or truncated. No trailing newline: the
# comparison reads it back through a command substitution, which strips one.
SIGNING_KEY=$'-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nfixture'

run_sign() {
  local digest="$1" exit_code="${2:-0}"
  : >"${SIGN_ARGS}"
  : >"${SIGN_KEY_SEEN}"
  (
    PATH="${SIGN_STUBS}:${PATH}" \
      SIGN_ARGS_FILE="${SIGN_ARGS}" \
      SIGN_KEY_FILE="${SIGN_KEY_SEEN}" \
      SIGN_EXIT_CODE="${exit_code}" \
      IMAGE_REGISTRY="${PUSH_REGISTRY}" \
      IMAGE_NAME="${PUSH_IMAGE_NAME}" \
      COSIGN_PRIVATE_KEY="${SIGNING_KEY}" \
      PUSH_DIGEST="${digest}" \
      "${BASH}" --noprofile --norc -c "${sign_run}"
  )
}

# Asserted as whole argv rather than by substring. Both compatibility flags are
# load-bearing and neither has any local effect: dropping one produces a
# signature stored as an OCI 1.1 referrer, which the `signatures` job above --
# and every pre-v3 client verifying this image -- cannot see. The run stays
# green on both sides until someone with an older cosign tries to verify.
output="$(run_sign "${PUSHED_DIGEST}" 2>&1)"
status=$?
assert_status "signing a pushed digest exits 0" 0 "${status}"
printf -v expected_sign_args '%s\n' \
  "sign" "-y" "--key" "env://COSIGN_PRIVATE_KEY" \
  "--new-bundle-format=false" "--use-signing-config=false" \
  "${PUSH_REGISTRY}/${PUSH_IMAGE_NAME}@${PUSHED_DIGEST}"
assert_equal "cosign signs the pushed digest in the v2 bundle format older clients can verify" \
  "${expected_sign_args%$'\n'}" "$(cat "${SIGN_ARGS}")"

# The key travels in the environment and must arrive intact -- `--key env://`
# names the variable, so a rename or a truncating rewrite is a signing failure
# rather than a wrong signature -- and must not travel through the log.
assert_equal "the signing key reaches cosign through the environment" \
  "${SIGNING_KEY}" "$(cat "${SIGN_KEY_SEEN}")"
assert_absent "the signing key is never printed" "${output}" "fixture"

# The seam, executed from the sign side. Actions expands a renamed or missing
# step output to the empty string, so this is what a broken seam looks like
# from inside the step: it must fail, and it must not quietly fall back to
# signing a mutable tag, which would leave `:latest` signed at whatever it
# happens to point at later.
output="$(run_sign "" 2>&1)"
status=$?
assert_status "an empty digest fails instead of signing" 1 "${status}"
assert_absent "an empty digest never becomes a tag reference" \
  "$(cat "${SIGN_ARGS}")" "${PUSH_IMAGE_NAME}:"

output="$(
  PATH="${SIGN_STUBS}:${PATH}" \
    SIGN_ARGS_FILE="${SIGN_ARGS}" \
    SIGN_KEY_FILE="${SIGN_KEY_SEEN}" \
    IMAGE_REGISTRY="${PUSH_REGISTRY}" \
    IMAGE_NAME="${PUSH_IMAGE_NAME}" \
    COSIGN_PRIVATE_KEY="${SIGNING_KEY}" \
    env -u PUSH_DIGEST "${BASH}" --noprofile --norc -c "${sign_run}" 2>&1
)"
status=$?
assert_status "an unset digest fails instead of signing" 1 "${status}"
assert_absent "an unset digest never reaches cosign" "${output}" "invalid reference"

# `set -euo pipefail` is what makes a refused signature a red run. Without it
# the job would end green having signed nothing, and the nightly `signatures`
# job would be the first thing to notice -- a day later, if at all.
output="$(run_sign "${PUSHED_DIGEST}" 1 2>&1)"
status=$?
assert_status "a cosign failure fails the step" 1 "${status}"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

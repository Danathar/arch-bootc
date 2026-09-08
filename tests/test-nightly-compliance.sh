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

WORK_DIR="$(mktemp -d)"
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

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

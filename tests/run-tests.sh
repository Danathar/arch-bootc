#!/usr/bin/env bash
set -euo pipefail

# Run every tests/test-*.sh and tests/e2e/test-*.sh in sequence and report a
# per-file pass/fail summary.
#
# The tests are plain bash: no framework, no root, no container runtime, no
# network. Each test file must exit non-zero when any of its assertions fail.
#
# A test file may report an individual case as `ok - <desc> # SKIP <reason>`
# when the host cannot offer what the case needs -- no block device node in
# /dev, no unprivileged user namespace. Those lines are collected here and
# reported together at the end, because a skip printed a few hundred lines up
# in a job log is indistinguishable from a pass to anyone reading the summary.
# Set ARCH_BOOTC_NO_SKIPS to a non-empty value and a skip becomes a failure:
# that is the mode CI runs in, where every environmental prerequisite is
# supposed to be present, so a skip means coverage quietly stopped happening
# rather than that the host is modest. See docs/ci-cd.md.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
OUTPUT_FILE="${WORK_DIR}/test-output"

cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

shopt -s nullglob
test_files=("${SCRIPT_DIR}"/test-*.sh "${SCRIPT_DIR}"/e2e/test-*.sh)

if (( ${#test_files[@]} == 0 )); then
  echo "error: no test files found in ${SCRIPT_DIR}" >&2
  exit 1
fi

failed=()
skips=()
for test_file in "${test_files[@]}"; do
  relative_test="${test_file#"${SCRIPT_DIR}/"}"
  echo "==> ${relative_test}"
  # "${BASH}" rather than a bare `bash` so the whole suite runs under one
  # interpreter -- see the note in check-coverage.sh about why the reported
  # Bash version has to be the one that actually produced the trace.
  #
  # Piped through `tee` rather than captured whole: the log still streams line
  # by line as the file runs, and the copy on disk is what the skip tally
  # below reads. `set -o pipefail` is in force and `tee` does not fail here,
  # so the pipeline's status is still the test file's own.
  if "${BASH}" "${test_file}" | tee "${OUTPUT_FILE}"; then
    echo "--> PASS ${relative_test}"
  else
    echo "--> FAIL ${relative_test}" >&2
    failed+=("${relative_test}")
  fi
  while IFS= read -r skip_line; do
    skips+=("${relative_test}: ${skip_line#ok - }")
  done < <(grep -E '^ok - .+ # SKIP ' "${OUTPUT_FILE}" || true)
  echo
done

if (( ${#skips[@]} > 0 )); then
  printf '%d test(s) were skipped for environmental reasons:\n' "${#skips[@]}" >&2
  printf '  %s\n' "${skips[@]}" >&2
fi

if (( ${#failed[@]} > 0 )); then
  printf 'FAILED: %s\n' "${failed[*]}" >&2
  exit 1
fi

if (( ${#skips[@]} > 0 )) && [[ -n "${ARCH_BOOTC_NO_SKIPS:-}" ]]; then
  printf 'error: ARCH_BOOTC_NO_SKIPS is set, so %d skipped test(s) fail this run.\n' \
    "${#skips[@]}" >&2
  echo "Give those tests the environment they ask for, or clear" >&2
  echo "ARCH_BOOTC_NO_SKIPS to accept a partial run -- do not delete the skip." >&2
  exit 1
fi

printf 'All %d test file(s) passed.\n' "${#test_files[@]}"

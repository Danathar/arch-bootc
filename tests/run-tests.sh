#!/usr/bin/env bash
set -euo pipefail

# Run every tests/test-*.sh in sequence and report a per-file pass/fail summary.
#
# The tests are plain bash: no framework, no root, no container runtime, no
# network. Each test file must exit non-zero when any of its assertions fail.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
test_files=("${SCRIPT_DIR}"/test-*.sh)

if (( ${#test_files[@]} == 0 )); then
  echo "error: no test files found in ${SCRIPT_DIR}" >&2
  exit 1
fi

failed=()
for test_file in "${test_files[@]}"; do
  echo "==> ${test_file##*/}"
  if bash "${test_file}"; then
    echo "--> PASS ${test_file##*/}"
  else
    echo "--> FAIL ${test_file##*/}" >&2
    failed+=("${test_file##*/}")
  fi
  echo
done

if (( ${#failed[@]} > 0 )); then
  printf 'FAILED: %s\n' "${failed[*]}" >&2
  exit 1
fi

printf 'All %d test file(s) passed.\n' "${#test_files[@]}"

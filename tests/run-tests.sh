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
MANIFEST="${SCRIPT_DIR}/test-manifest"
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

# What the glob found has to match tests/test-manifest before anything runs.
#
# This command is allow-listed without a prompt in .claude/settings.json, and up
# to here it executed whatever the glob returned. That made one write into
# tests/ enough to run anything the same file's `deny` and `ask` entries exist
# to gate -- the `podman`/`buildah` prune and remove set, the `virsh ...
# destroy`/`undefine`/`pool-*`/`vol-wipe` set, `git reset --hard`, `git clean`,
# `git push --force`, `sudo`, `gh pr merge` -- with no prompt, using a command
# the same file marks safe. Those entries are the mechanical half of the rule
# AGENTS.md states in prose: every existing container, image, VM, pool, block
# device and untracked file is user data.
#
# It does not make the runner a sandbox and is not claimed to: whoever can write
# a test file can write a line here too. What it removes is the silent case.
# Adding to what an allow-listed command executes is now an edit to a committed
# list -- visible in `git diff`, and gated by tests/check-invariants.sh -- rather
# than a file appearing in a directory nothing reads.
#
# The comparison is text against text, and the *glob's* results are what run
# below. No path is ever read out of the manifest and executed, so a line in it
# cannot become a command no matter what it says.
if [[ ! -f "${MANIFEST}" ]]; then
  echo "error: ${MANIFEST} is missing, so there is nothing to check the" >&2
  echo "discovered test files against. Restore it rather than deleting the check." >&2
  exit 1
fi

discovered=()
for test_file in "${test_files[@]}"; do
  discovered+=("${test_file#"${SCRIPT_DIR}/"}")
done

listed=()
while IFS= read -r manifest_line; do
  manifest_line="${manifest_line%%#*}"
  manifest_line="${manifest_line#"${manifest_line%%[![:space:]]*}"}"
  manifest_line="${manifest_line%"${manifest_line##*[![:space:]]}"}"
  [[ -n "${manifest_line}" ]] || continue
  listed+=("${manifest_line}")
done <"${MANIFEST}"

printf '%s\n' "${discovered[@]}" | LC_ALL=C sort >"${WORK_DIR}/discovered"
printf '%s\n' "${listed[@]+"${listed[@]}"}" | LC_ALL=C sort >"${WORK_DIR}/listed"

if [[ "$(cat "${WORK_DIR}/discovered")" != "$(cat "${WORK_DIR}/listed")" ]]; then
  echo "error: the test files in ${SCRIPT_DIR} do not match ${MANIFEST}:" >&2
  grep -vxF -f "${WORK_DIR}/listed" "${WORK_DIR}/discovered" |
    sed 's/^/  unlisted: /' >&2 || true
  grep -vxF -f "${WORK_DIR}/discovered" "${WORK_DIR}/listed" |
    sed 's/^/  missing:  /' >&2 || true
  echo "Read an unlisted file before adding it: this runner executes it, and" >&2
  echo "running this runner needs no confirmation. Remove a stale line instead" >&2
  echo "of restoring a file that was deleted on purpose." >&2
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

#!/usr/bin/env bash
set -uo pipefail

# Exercise scripts/pr-review-state.sh against a stubbed `gh`. The point of the
# script is the distinction a flat comment list cannot make -- resolved vs
# unresolved, and outdated vs current -- so the cases below are built around
# fixtures that differ only in those fields.
#
# No network: `gh` is shadowed on PATH and replies from a fixture file. jq is
# real, because the script's flattening logic is most of what is worth testing
# and stubbing jq would test nothing.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/pr-review-state.sh"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

STUB_DIR="${WORK_DIR}/bin"
FIXTURE="${WORK_DIR}/response.json"
mkdir -p "${STUB_DIR}"

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

# `gh api graphql` prints whatever the current fixture holds; the other two
# subcommands the script may reach for answer deterministically. Anything else
# is a bug in the script, so the stub fails loudly rather than silently
# returning nothing.
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "api graphql")
    if [[ -n "${GH_STUB_FAIL:-}" ]]; then
      printf 'HTTP 502: Bad gateway\n' >&2
      exit 1
    fi
    cat "${GH_STUB_FIXTURE}"
    ;;
  "repo view") printf 'Danathar/arch-bootc\n' ;;
  "pr view") printf '%s\n' "${GH_STUB_CURRENT_PR:-77}" ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"

# Build a GraphQL response. Threads and checks are passed in as JSON arrays so
# each case states only what it is actually testing.
write_fixture() {
  local threads="$1" checks="$2" rollup="${3:-SUCCESS}"
  cat >"${FIXTURE}" <<JSON
{"data":{"repository":{"pullRequest":{
  "number": 77,
  "title": "a change under review",
  "isDraft": false,
  "headRefOid": "abcdef0123456789abcdef0123456789abcdef01",
  "reviewThreads": {"nodes": ${threads}},
  "commits": {"nodes": [{"commit": {"statusCheckRollup":
    $(if [[ "${rollup}" == "null" ]]; then printf 'null'; else printf '{"state": "%s", "contexts": {"nodes": %s}}' "${rollup}" "${checks}"; fi)
  }}]}
}}}}
JSON
}

thread() { # resolved outdated path line originalLine author body
  printf '{"isResolved":%s,"isOutdated":%s,"path":"%s","line":%s,"originalLine":%s,"comments":{"nodes":[{"author":{"login":"%s"},"body":"%s","url":"https://example.invalid/1"}]}}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

check_run() { # name conclusion
  printf '{"__typename":"CheckRun","name":"%s","conclusion":"%s","status":"COMPLETED","detailsUrl":"https://example.invalid/run"}' "$1" "$2"
}

run_script() {
  PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" "${BASH}" "${SCRIPT}" "$@" 2>&1
}

# --- argument handling ----------------------------------------------------

output="$(run_script --help)"
assert_status "--help exits 0" 0 "$?"
assert_contains "--help explains the exit codes" "${output}" "Exit status:"

output="$(run_script --not-a-flag 77)"
assert_status "an unknown option is a usage error" 2 "$?"
assert_contains "an unknown option names itself" "${output}" "unknown option --not-a-flag"

output="$(run_script not-a-number)"
assert_status "a non-numeric pull request number is a usage error" 2 "$?"
assert_contains "a non-numeric number is reported" "${output}" "must be numeric"

output="$(run_script 12 34)"
assert_status "two pull request numbers is a usage error" 2 "$?"

output="$(run_script --repo)"
assert_status "--repo without a value is a usage error" 2 "$?"

# --- clean pull request ---------------------------------------------------

write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'fixed already')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS), $(check_run 'Build and push image (base)' SUCCESS)]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a resolved thread and green checks exit 0" 0 "$?"
assert_contains "a clean pull request says nothing is outstanding" "${output}" "(none outstanding)"
assert_contains "the head SHA is reported" "${output}" "abcdef0123456789abcdef0123456789abcdef01"
assert_contains "the outstanding line counts zero unresolved" "${output}" "Outstanding: 0 unresolved thread(s), 0 failing check(s)"

# --- an unresolved thread -------------------------------------------------

write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled'), $(thread false false 'Justfile' 42 42 'critic' 'this is still wrong')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "an unresolved thread exits 1" 1 "$?"
assert_contains "the unresolved thread is located" "${output}" "Justfile:42"
assert_contains "the unresolved thread names its author" "${output}" "by critic"
assert_contains "the unresolved thread shows an excerpt" "${output}" "this is still wrong"
assert_absent "the resolved thread is not reported as outstanding" "${output}" "Containerfile:10"
assert_contains "resolved threads still count toward the total" "${output}" "2 total, 1 unresolved"

# --- an outdated thread falls back to originalLine ------------------------

write_fixture \
  "[$(thread false true 'Containerfile' null 118 'critic' 'written against an older push')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "an unresolved outdated thread still exits 1" 1 "$?"
assert_contains "an outdated thread is marked" "${output}" "[outdated]"
assert_contains "an outdated thread reports the line it was written against" "${output}" "Containerfile:118"

# --- a failing check ------------------------------------------------------

write_fixture \
  "[]" \
  "[$(check_run 'Shell tests and coverage' FAILURE), $(check_run 'Lint shell scripts' SUCCESS)]" \
  FAILURE

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a failing check exits 1 even with no threads" 1 "$?"
assert_contains "the failing check is listed" "${output}" "FAILURE"
assert_contains "the failing check is counted" "${output}" "1 failing check(s)"

# --- a pull request nothing ran on ----------------------------------------

write_fixture "[]" "[]" null

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "no threads and no checks exits 0" 0 "$?"
assert_contains "an empty check list is called a skip, not a pass" "${output}" "that is a skip, not a pass"

# --- machine-readable output ----------------------------------------------

write_fixture \
  "[$(thread false false 'Justfile' 42 42 'critic' 'still wrong')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"

output="$(run_script --json --repo Danathar/arch-bootc 77)"
assert_status "--json still exits 1 when something is outstanding" 1 "$?"
if printf '%s' "${output}" | jq -e '.unresolved | length == 1' >/dev/null 2>&1; then
  check "--json emits parseable JSON with an unresolved list" 0
else
  check "--json emits parseable JSON with an unresolved list" 1 "got: ${output}"
fi

# --- inferring the pull request from the current branch -------------------

write_fixture "[]" "[$(check_run 'Shell tests and coverage' SUCCESS)]"
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_CURRENT_PR=77 \
  "${BASH}" "${SCRIPT}" 2>&1)"
assert_status "the pull request number is inferred when omitted" 0 "$?"
assert_contains "the inferred pull request is reported" "${output}" "PR #77"

# --- API failure ----------------------------------------------------------

output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_FAIL=1 \
  "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "a failed GraphQL query is an error, not an empty report" 2 "$?"
assert_contains "the API failure is surfaced" "${output}" "GraphQL query failed"

# --- gh missing entirely --------------------------------------------------

BARE_DIR="${WORK_DIR}/bare"
mkdir -p "${BARE_DIR}"
ln -sf "$(command -v jq)" "${BARE_DIR}/jq"
output="$(PATH="${BARE_DIR}" "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "a missing gh is a clear error" 2 "$?"
assert_contains "the missing gh error points somewhere useful" "${output}" "cli.github.com"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

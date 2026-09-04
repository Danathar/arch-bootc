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
    # Serve the second page once a non-empty cursor is passed, so pagination
    # is exercised the way the API actually drives it rather than by counting
    # calls.
    cursor=""
    for arg in "$@"; do
      [[ "${arg}" == cursor=* ]] && cursor="${arg#cursor=}"
    done
    # A server that keeps handing back a fresh cursor forever. The counter file
    # names each page, so every reply advances and the only thing that can stop
    # the script is its own page bound.
    if [[ -n "${GH_STUB_ENDLESS:-}" ]]; then
      pages_served=$(($(cat "${GH_STUB_ENDLESS}" 2>/dev/null || printf 0) + 1))
      printf '%s' "${pages_served}" >"${GH_STUB_ENDLESS}"
      sed "s/@CURSOR@/PAGE${pages_served}/" "${GH_STUB_FIXTURE}"
      exit 0
    fi
    # Fail only on a paginating call, so the first page still succeeds and the
    # error can only come from the pagination loop.
    if [[ -n "${cursor}" && -n "${GH_STUB_FAIL_PAGE2:-}" ]]; then
      printf 'HTTP 502: Bad gateway\n' >&2
      exit 1
    fi
    if [[ -n "${cursor}" && -n "${GH_STUB_FIXTURE2:-}" ]]; then
      cat "${GH_STUB_FIXTURE2}"
    else
      cat "${GH_STUB_FIXTURE}"
    fi
    ;;
  "repo view")
    if [[ -n "${GH_STUB_REPO_FAIL:-}" ]]; then
      printf 'no git remote found for the current directory\n' >&2
      exit 1
    fi
    printf 'Danathar/arch-bootc\n'
    ;;
  "pr view")
    if [[ -n "${GH_STUB_PR_FAIL:-}" ]]; then
      printf 'no pull requests found for branch\n' >&2
      exit 1
    fi
    printf '%s\n' "${GH_STUB_CURRENT_PR:-77}"
    ;;
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
  local threads="$1" checks="$2" rollup="${3:-SUCCESS}" page_info="${4:-}" target="${5:-${FIXTURE}}"
  [[ -z "${page_info}" ]] && page_info='{"hasNextPage": false, "endCursor": null}'
  cat >"${target}" <<JSON
{"data":{"repository":{"pullRequest":{
  "number": 77,
  "title": "a change under review",
  "isDraft": false,
  "headRefOid": "abcdef0123456789abcdef0123456789abcdef01",
  "reviewThreads": {"pageInfo": ${page_info}, "nodes": ${threads}},
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

# A check that has not finished reports a null `conclusion`; its state is in
# `status` instead, which is why the script reads `.conclusion // .status`.
running_check_run() { # name status
  printf '{"__typename":"CheckRun","name":"%s","conclusion":null,"status":"%s","detailsUrl":"https://example.invalid/run"}' "$1" "$2"
}

# The other half of the rollup union. Classic commit statuses -- what an
# external service posts to the statuses API -- carry `context`/`state`/
# `targetUrl` under different names than a CheckRun does.
status_context() { # context state
  printf '{"__typename":"StatusContext","context":"%s","state":"%s","targetUrl":"https://example.invalid/status"}' "$1" "$2"
}

run_script() {
  PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" "${BASH}" "${SCRIPT}" "$@" 2>&1
}

# --- argument handling ----------------------------------------------------

output="$(run_script --help)"
assert_status "--help exits 0" 0 "$?"
assert_contains "--help explains the exit codes" "${output}" "Exit status:"

output="$(run_script -h)"
assert_status "-h exits 0" 0 "$?"
assert_contains "-h prints the same usage as --help" "${output}" "Usage: pr-review-state.sh"

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

# --- every state the gate counts as failing -------------------------------
#
# `FAILURE` above is the obvious one. The other four are in the filter because
# each is a way for a check to stop without having passed, and the one that
# matters most here is `CANCELLED`: a cancelled run is not a run that said
# nothing, it is a run that did not finish, and treating it as neutral would
# let a gate report "nothing outstanding" for a commit nothing verified.

for failing_state in TIMED_OUT CANCELLED ERROR ACTION_REQUIRED; do
  write_fixture "[]" "[$(check_run 'Shell tests and coverage' "${failing_state}")]" FAILURE
  output="$(run_script --repo Danathar/arch-bootc 77)"
  assert_status "${failing_state} is counted as failing" 1 "$?"
  # The report's state column is 14 characters wide, so the one state longer
  # than that is matched by its visible prefix rather than its full name.
  assert_contains "${failing_state} is reported in the check list" "${output}" "${failing_state:0:14}"
  assert_contains "${failing_state} reaches the outstanding line" "${output}" "1 failing check(s)"
done

# The truncation above is a property of the human-readable column only. Anything
# consuming the exit code and `--json` has to see the state GitHub actually
# reported, or a caller matching on it would never match ACTION_REQUIRED.
write_fixture "[]" "[$(check_run 'Shell tests and coverage' ACTION_REQUIRED)]" FAILURE
output="$(run_script --json --repo Danathar/arch-bootc 77)"
assert_status "--json exits 1 for a check needing action" 1 "$?"
if printf '%s' "${output}" | jq -e '.failing[0].state == "ACTION_REQUIRED"' >/dev/null 2>&1; then
  check "--json reports the untruncated check state" 0
else
  check "--json reports the untruncated check state" 1 "got: ${output}"
fi

# --- a check still running is not a failure -------------------------------
#
# The complement of the block above, and the more surprising half: the script
# reports pending checks but does not fail on them, so an exit 0 can still be a
# pull request nothing has finished checking. Asserting it here means the
# distinction is a decision rather than an accident of the filter order.

write_fixture \
  "[]" \
  "[$(running_check_run 'Shell tests and coverage' IN_PROGRESS), $(check_run 'Lint shell scripts' SUCCESS)]" \
  PENDING

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a check still running does not fail the gate" 0 "$?"
assert_contains "a running check falls back to its status when conclusion is null" "${output}" "IN_PROGRESS"
assert_contains "a running check is counted as still running" "${output}" "0 failing check(s), 1 still running"

write_fixture \
  "[]" \
  "[$(running_check_run 'Shell tests and coverage' QUEUED), $(running_check_run 'Build and push image (base)' WAITING)]" \
  PENDING

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "queued and waiting checks do not fail the gate" 0 "$?"
assert_contains "queued and waiting checks are both counted as running" "${output}" "2 still running"

# --- classic commit statuses ----------------------------------------------
#
# The rollup is a union and the script has a branch per member. Only CheckRun
# was exercised, so nothing showed that a StatusContext -- what an external
# service posts to the statuses API -- is read from its own field names rather
# than silently reported as a nameless check in an unknown state.

write_fixture \
  "[]" \
  "[$(status_context 'ci/external-signer' FAILURE), $(status_context 'ci/mirror' SUCCESS)]" \
  FAILURE

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a failing commit status fails the gate like a check run" 1 "$?"
assert_contains "a commit status is named by its context" "${output}" "ci/external-signer"
assert_contains "a passing commit status is listed too" "${output}" "ci/mirror"
assert_contains "a failing commit status is counted" "${output}" "1 failing check(s)"

output="$(run_script --json --repo Danathar/arch-bootc 77)"
assert_status "--json still exits 1 for a failing commit status" 1 "$?"
if printf '%s' "${output}" | jq -e '.checks[0] | .name == "ci/external-signer" and .state == "FAILURE"' >/dev/null 2>&1; then
  check "a commit status keeps its context and state in --json" 0
else
  check "a commit status keeps its context and state in --json" 1 "got: ${output}"
fi

# --- the check rollup is not paginated ------------------------------------
#
# Review threads page; the rollup does not. At exactly 100 contexts the list
# may have been cut off, and the script says so rather than reporting a
# truncated list as the whole picture.

many_checks="$(check_run 'context-1' SUCCESS)"
for i in $(seq 2 100); do
  many_checks="${many_checks}, $(check_run "context-${i}" SUCCESS)"
done
write_fixture "[]" "[${many_checks}]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a full rollup still exits 0 when everything passed" 0 "$?"
assert_contains "a rollup at the cap warns that it may be truncated" "${output}" "may be truncated"

# 99 is the discriminating case: one fewer context cannot have been cut off,
# so the warning has to be absent or it means nothing when it appears.
many_checks="$(check_run 'context-1' SUCCESS)"
for i in $(seq 2 99); do
  many_checks="${many_checks}, $(check_run "context-${i}" SUCCESS)"
done
write_fixture "[]" "[${many_checks}]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a rollup below the cap exits 0" 0 "$?"
assert_absent "a rollup below the cap does not warn" "${output}" "may be truncated"

# --- threads missing the fields the report prints -------------------------
#
# A thread on a file that no longer exists reports a null `path`, and a comment
# from a deleted account reports a null `author`. Both reach the report through
# a fallback; without a case for them a `//` that stopped working would show up
# as `null` in a reviewer-facing line rather than as a test failure.

write_fixture \
  '[{"isResolved":false,"isOutdated":false,"path":null,"line":null,"originalLine":null,"comments":{"nodes":[{"author":null,"body":"who wrote this","url":null}]}}]' \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "a thread with no path still fails the gate" 1 "$?"
assert_contains "a thread with no path says so" "${output}" "(no file)"
assert_contains "a thread with no author is attributed to unknown" "${output}" "by unknown"

# --- a pull request nothing ran on ----------------------------------------

write_fixture "[]" "[]" null

output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "no threads and no checks exits 0" 0 "$?"
assert_contains "an empty check list is called a skip, not a pass" "${output}" "that is a skip, not a pass"

# --- pagination -----------------------------------------------------------
#
# The failure this guards against is the worst one the script can have: a
# clean-looking exit 0 that simply did not look at the thread that mattered.
# Page one holds only resolved threads, so a script that stops there reports
# nothing outstanding.

FIXTURE2="${WORK_DIR}/response-page2.json"
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]" \
  SUCCESS \
  '{"hasNextPage": true, "endCursor": "CURSOR1"}'
write_fixture \
  "[$(thread false false 'packages-base.txt' 7 7 'critic' 'this one is on page two')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]" \
  SUCCESS \
  '{"hasNextPage": false, "endCursor": null}' \
  "${FIXTURE2}"

output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_FIXTURE2="${FIXTURE2}" \
  "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "an unresolved thread on page two still exits 1" 1 "$?"
assert_contains "the second page's thread is reported" "${output}" "packages-base.txt:7"
assert_contains "threads from both pages are counted" "${output}" "2 total, 1 unresolved"

# Page one's contents on their own are clean, which is what makes the two
# assertions above discriminating rather than incidental: a script that
# stopped at the first page would report this pull request as having nothing
# outstanding.
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"
output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "page one's contents alone exit 0" 0 "$?"
assert_contains "page one's contents alone report nothing outstanding" "${output}" "(none outstanding)"

# A server that never advances its cursor must fail rather than spin. This is
# the shape a replaying cache or a buggy intermediary produces, and the script
# is meant to run unattended.
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]" \
  SUCCESS \
  '{"hasNextPage": true, "endCursor": "STUCK"}'
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_FIXTURE2="${FIXTURE}" \
  timeout 30 "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "a non-advancing cursor is an error, not an infinite loop" 2 "$?"
assert_contains "the stuck cursor is named" "${output}" "did not advance past cursor STUCK"

# A cursor that advances every time defeats the stuck-cursor check above, so
# the page bound is the only thing left to stop it. This is the other half of
# "run unattended in CI": the loop has to terminate against a server that is
# behaving correctly by its own lights and simply never finishes.
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]" \
  SUCCESS \
  '{"hasNextPage": true, "endCursor": "@CURSOR@"}'
PAGE_COUNTER="${WORK_DIR}/endless-pages"
: >"${PAGE_COUNTER}"
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_ENDLESS="${PAGE_COUNTER}" \
  timeout 60 "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "endless pagination stops at the page bound" 2 "$?"
assert_contains "the page bound names itself" "${output}" "did not finish paginating after 10 pages"
if [[ "$(cat "${PAGE_COUNTER}")" -le 12 ]]; then
  check "the page bound stops after a bounded number of requests" 0
else
  check "the page bound stops after a bounded number of requests" 1 \
    "served $(cat "${PAGE_COUNTER}") pages"
fi

# A failure on page two is not the same as a failure on page one: the first
# query already succeeded, so the script is holding a partial thread list. It
# has to report the error rather than summarise what it happened to collect.
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]" \
  SUCCESS \
  '{"hasNextPage": true, "endCursor": "CURSOR1"}'
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_FAIL_PAGE2=1 \
  timeout 30 "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "a failure while paginating is an error, not a partial report" 2 "$?"
assert_contains "the paginating failure says which loop it came from" "${output}" \
  "GraphQL query failed while paginating review threads"
assert_absent "a partial thread list is not summarised" "${output}" "Outstanding:"

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

# Both lookups the no-argument form depends on can fail, and each has to say
# which one did. Reporting on the wrong pull request would be worse than
# refusing, so neither may fall through to a guess.
write_fixture "[]" "[$(check_run 'Shell tests and coverage' SUCCESS)]"
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_PR_FAIL=1 \
  "${BASH}" "${SCRIPT}" 2>&1)"
assert_status "no pull request for the current branch is a usage error" 2 "$?"
assert_contains "the branch lookup failure explains itself" "${output}" \
  "no pull request number given and none found for the current branch"

output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_REPO_FAIL=1 \
  "${BASH}" "${SCRIPT}" 77 2>&1)"
assert_status "an undeterminable repository is a usage error" 2 "$?"
assert_contains "the repository failure points at the flag that fixes it" "${output}" \
  "pass --repo OWNER/REPO"

# --repo makes both lookups unnecessary, which is the property that lets this
# run outside a checkout at all.
output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_REPO_FAIL=1 GH_STUB_PR_FAIL=1 \
  "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "--repo with a number needs neither lookup" 0 "$?"
assert_contains "--repo with a number still reports the pull request" "${output}" "PR #77"

# --- API failure ----------------------------------------------------------

output="$(PATH="${STUB_DIR}:${PATH}" GH_STUB_FIXTURE="${FIXTURE}" GH_STUB_FAIL=1 \
  "${BASH}" "${SCRIPT}" --repo Danathar/arch-bootc 77 2>&1)"
assert_status "a failed GraphQL query is an error, not an empty report" 2 "$?"
assert_contains "the API failure is surfaced" "${output}" "GraphQL query failed"

# A query that succeeds can still return something the flattening step cannot
# read -- a schema change, or a proxy substituting its own body. The distinction
# from the case above is that `gh` exited 0, so nothing but the parse guard is
# left to notice.
cat >"${FIXTURE}" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number": 77,
  "title": "a change under review",
  "isDraft": false,
  "headRefOid": "abcdef0123456789abcdef0123456789abcdef01",
  "reviewThreads": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": ["not a thread object"]},
  "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"nodes": []}}}}]}
}}}}
JSON
output="$(run_script --repo Danathar/arch-bootc 77)"
assert_status "an unreadable response is an error, not a clean report" 2 "$?"
assert_contains "the parse failure is surfaced" "${output}" "could not parse the GraphQL response"
assert_absent "an unreadable response produces no summary" "${output}" "Outstanding:"

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

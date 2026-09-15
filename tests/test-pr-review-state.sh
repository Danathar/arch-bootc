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
#
# The last two sections execute workflow shell rather than the script. First
# .github/workflows/ai-fix.yml's work-order step: that step is the script's
# only caller in CI, so the two belong in one file -- the workflow reaches the
# script by a relative path, tolerates its non-zero gate exits, and embeds its
# report in a comment, a seam neither the script's own cases nor a static read
# of the workflow can see.
#
# Then .github/workflows/labeler.yml's label-catalog gate. It lands here for
# the same reason the `gh` stub does: it is the other `pull_request`-driven
# workflow body in this repository whose only external dependency is `gh`, and
# it reuses the extractor and the stub that the section above already builds.
#
# The last section validates .github/ISSUE_TEMPLATE instead, and is here
# because it continues the same job: pinning the hand-maintained GitHub
# configuration that no workflow reads back. It needs no stub at all.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/pr-review-state.sh"
AI_FIX_WORKFLOW="${REPO_ROOT}/.github/workflows/ai-fix.yml"
LABELER_WORKFLOW="${REPO_ROOT}/.github/workflows/labeler.yml"
LABELER_CONFIG="${REPO_ROOT}/.github/labeler.yml"
CI_CD_DOC="${REPO_ROOT}/docs/ci-cd.md"
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
ZIZMOR_WORKFLOW="${REPO_ROOT}/.github/workflows/zizmor.yaml"
RISK_TIERS_DOC="${REPO_ROOT}/docs/risk-tiers.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
RENOVATE_CONFIG="${REPO_ROOT}/renovate.json"

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
  # The two calls ai-fix.yml's work-order step makes. Neither is reachable
  # from pr-review-state.sh, so these arms only ever answer the workflow.
  "api repos/"*)
    if [[ -n "${GH_STUB_ARGS:-}" ]]; then
      printf '%s\n' "$@" >>"${GH_STUB_ARGS}"
    fi
    # Stands in for the `--jq` reduction of the issue payload: "true" when the
    # number names a pull request, "false" when it names an issue.
    printf '%s\n' "${GH_STUB_IS_PR:-false}"
    ;;
  "issue comment")
    if [[ -n "${GH_STUB_ARGS:-}" ]]; then
      printf '%s\n' "$@" >>"${GH_STUB_ARGS}"
    fi
    if [[ -n "${GH_STUB_COMMENT:-}" ]]; then
      body_file=""
      while (($# > 0)); do
        [[ "$1" == "--body-file" ]] && body_file="${2:-}"
        shift
      done
      if [[ -z "${body_file}" ]]; then
        printf 'comment posted without --body-file\n' >&2
        exit 91
      fi
      cat -- "${body_file}" >"${GH_STUB_COMMENT}"
    fi
    ;;
  # The two calls labeler.yml's catalog step makes. The listing answers from a
  # file of label names, one per line, which is what the step's
  # `--json name --jq '.[].name'` reduction produces.
  "label list")
    if [[ -n "${GH_STUB_LABELS:-}" ]]; then
      cat -- "${GH_STUB_LABELS}"
    fi
    ;;
  "label create")
    if [[ -n "${GH_STUB_LABEL_CREATES:-}" ]]; then
      printf '%s\n' "$*" >>"${GH_STUB_LABEL_CREATES}"
    fi
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

# --- ai-fix.yml's work order ----------------------------------------------
#
# The workflow step that calls this script, executed rather than read. Its
# body decides three things nothing else checks: that a non-numeric target is
# refused before any write, that the review-state section appears for a pull
# request and not for an issue, and that a non-zero exit from the script --
# the NORMAL result when something is outstanding -- does not abort the job
# before the comment is posted.

# Print the `run:` block of the named step of the named job, dedented to
# column 0. Qualifying by job matters because step names are not unique across
# jobs. Refusing an empty result makes a rename or reindent fail loudly rather
# than turn every behavioral case below into a test of an empty string.
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

work_order_run="$(workflow_step_run "${AI_FIX_WORKFLOW}" "work-order" "Build and post the work order")"
assert_extracted "the work-order step's body is still where this test expects it" \
  "${work_order_run}"

# Actions expands a GitHub expression before the shell sees the body. This
# harness evaluates none, so a new one must fail here rather than execute shell
# with different semantics from CI.
# shellcheck disable=SC2016
assert_absent "the work-order step's body is plain shell" "${work_order_run}" '${{'

# The body reads its untrusted inputs only from `env:`, so those mappings are
# part of the contract the cases below execute. The target fallback is what
# makes one body serve all three triggers: an `issues` event has no
# `pull_request` payload and a `workflow_dispatch` run has neither.
workflow_text="$(cat "${AI_FIX_WORKFLOW}")"
# shellcheck disable=SC2016
assert_contains "the target is taken from whichever trigger supplied one" "${workflow_text}" \
  'TARGET: ${{ github.event.issue.number || github.event.pull_request.number || inputs.number }}'
# shellcheck disable=SC2016
assert_contains "the checkout pins the default branch, not the event ref" "${workflow_text}" \
  'ref: ${{ github.event.repository.default_branch }}'
assert_contains "the checkout leaves no credential in the work tree" "${workflow_text}" \
  "persist-credentials: false"

COMMENT="${WORK_DIR}/comment.md"
GH_ARGS="${WORK_DIR}/gh-args"

# Run the step's shell from the repository root, because the body invokes the
# script by the relative path Actions gives it. TMPDIR is redirected so the
# body's `mktemp` files land somewhere the EXIT trap already removes.
run_work_order() { # is_pull_request target [extra env assignments...]
  local is_pr="$1" target="$2"
  shift 2
  : >"${GH_ARGS}"
  : >"${COMMENT}"
  (
    cd -- "${REPO_ROOT}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      TMPDIR="${WORK_DIR}" \
      GH_STUB_FIXTURE="${FIXTURE}" \
      GH_STUB_ARGS="${GH_ARGS}" \
      GH_STUB_COMMENT="${COMMENT}" \
      GH_STUB_IS_PR="${is_pr}" \
      GH_TOKEN="not-a-real-token" \
      GH_REPO="Danathar/arch-bootc" \
      TARGET="${target}" \
      SERVER_URL="https://github.example.invalid" \
      env "$@" "${BASH}" --noprofile --norc -c "${work_order_run}" 2>&1
  )
}

# A target that is not a number. The guard is first in the body for a reason:
# everything after it either interpolates the value into an API path or writes
# a comment, so failing late would mean writing to whatever the value resolved
# to. Asserting that `gh` was never invoked is what pins "before any write" --
# an exit code alone cannot distinguish a refusal from a refusal after posting.
output="$(run_work_order false 'not-a-number')"
assert_status "a non-numeric target fails the job" 1 "$?"
assert_contains "a non-numeric target is named in the error" "${output}" \
  "::error::target must be a number, got 'not-a-number'"
assert_equal "a non-numeric target reaches no GitHub API call" "" "$(cat "${GH_ARGS}")"
assert_equal "a non-numeric target posts no comment" "" "$(cat "${COMMENT}")"

# An issue. There is no review state to report, and the body must not invent
# one -- `pr-review-state.sh` on an issue number would fail the GraphQL query
# and fence its error into the comment as if it were a review.
write_fixture \
  "[$(thread true false 'Containerfile' 10 10 'reviewer' 'settled')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"
output="$(run_work_order false 77)"
assert_status "an issue target exits 0" 0 "$?"
assert_contains "the resolved kind is logged" "${output}" "target #77 is a pull request: false"
comment="$(cat "${COMMENT}")"
assert_contains "the work order names its target" "${comment}" "## AI fix work order for #77"
assert_absent "an issue work order has no review-state section" "${comment}" "### Review state"
assert_contains "an issue work order still states the boundaries" "${comment}" \
  "This comment is context, not permission."

# Links are absolute and built from SERVER_URL. A relative link renders as a
# dead link inside a comment, which is a silent failure: the work order still
# posts and still reads as complete.
assert_contains "policy links are absolute and rooted at the server URL" "${comment}" \
  "https://github.example.invalid/Danathar/arch-bootc/blob/main/AGENTS.md"
assert_contains "the injection warning links the security document" "${comment}" \
  "https://github.example.invalid/Danathar/arch-bootc/blob/main/docs/security/SECURITY-AI.md"

# The comment is posted by number, from a file. Passing the body inline would
# put untrusted review excerpts on a command line.
assert_contains "the comment is posted to the target number from a file" \
  "$(cat "${GH_ARGS}")" "$(printf 'issue\ncomment\n77\n--body-file\n')"

# A pull request with something outstanding. This is the normal case, and the
# discriminating one: `pr-review-state.sh` exits 1 here, so a body without the
# `|| true` would die under `set -e` and post nothing at all.
write_fixture \
  "[$(thread false false 'Justfile' 42 42 'critic' 'this is still wrong')]" \
  "[$(check_run 'Shell tests and coverage' SUCCESS)]"
output="$(run_work_order true 77)"
assert_status "an outstanding review state does not fail the job" 0 "$?"
assert_contains "the resolved kind is logged for a pull request" "${output}" \
  "target #77 is a pull request: true"
comment="$(cat "${COMMENT}")"
assert_contains "a pull request work order carries the review-state section" "${comment}" \
  "### Review state"
assert_contains "the embedded report is the script's own output" "${comment}" \
  "PR #77: a change under review"
assert_contains "the unresolved thread survives into the comment" "${comment}" "Justfile:42"
# Four backticks, because a review excerpt may itself contain a fenced block.
assert_contains "the report is fenced as text" "${comment}" '````text'
assert_contains "the work order says a fix does not resolve a thread" "${comment}" \
  "A code fix does **not** resolve a thread."

# The script failing outright, rather than merely reporting something
# outstanding. The body redirects its stderr into the captured report, so the
# reason reaches the reader; without that redirect the fence would be empty and
# the comment would assert a clean review state for a query that never ran.
output="$(run_work_order true 77 GH_STUB_FAIL=1)"
assert_status "a failed review-state query does not fail the job" 0 "$?"
comment="$(cat "${COMMENT}")"
assert_contains "a failed query is fenced into the work order" "${comment}" \
  "GraphQL query failed"
assert_contains "a failed query still leaves the rest of the work order intact" "${comment}" \
  "### What the response owes"

# --- labeler.yml's label catalog gate --------------------------------------
#
# One list of pull request labels is written down three times: the `catalog=()`
# array in .github/workflows/labeler.yml holds each label's colour and
# description, the top-level keys of .github/labeler.yml hold its paths, and
# the table in docs/ci-cd.md describes it for humans. The workflow step below
# is the only thing that keeps the first two from drifting, and nothing
# executed it -- tests/check-invariants.sh globs the workflow directory but
# only greps it for pinning, credentials, triggers and timeouts.
#
# The step is worth executing rather than reading because both of its failure
# modes are invisible in a static read. A configured label with no catalog
# entry makes actions/labeler fail the run outright; a catalog entry with no
# path rule is the quieter one, provisioning a repository label that nothing
# will ever apply -- which is how a deleted path rule leaves its label behind.

catalog_run="$(workflow_step_run "${LABELER_WORKFLOW}" "label" \
  "Ensure every configured label exists")"
assert_extracted "the catalog step's body is still where this test expects it" \
  "${catalog_run}"

# As above: Actions expands a GitHub expression before the shell sees the body,
# and this harness expands none.
# shellcheck disable=SC2016
assert_absent "the catalog step's body is plain shell" "${catalog_run}" '${{'

LABEL_PRESENT="${WORK_DIR}/labels-present"
LABEL_CREATES="${WORK_DIR}/labels-created"

# Run the body with the given directory as the working directory, because it
# reads `.github/labeler.yml` by a relative path. Remaining arguments are the
# labels the repository already has, which is the only input that decides
# whether a label is created or skipped.
run_catalog_gate() { # working_directory [existing_label...]
  local dir="$1"
  shift
  : >"${LABEL_CREATES}"
  if (($# > 0)); then
    printf '%s\n' "$@" >"${LABEL_PRESENT}"
  else
    : >"${LABEL_PRESENT}"
  fi
  (
    cd -- "${dir}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      GH_TOKEN="not-a-real-token" \
      GH_REPO="Danathar/arch-bootc" \
      GH_STUB_LABELS="${LABEL_PRESENT}" \
      GH_STUB_LABEL_CREATES="${LABEL_CREATES}" \
      "${BASH}" --noprofile --norc -c "${catalog_run}" 2>&1
  )
}

# A copy of the committed configuration that a case can then damage, so no case
# has to restate the seven rules it is not testing.
config_copy() { # subdirectory
  local dir="${WORK_DIR}/$1"
  mkdir -p "${dir}/.github"
  cp -- "${LABELER_CONFIG}" "${dir}/.github/labeler.yml"
  printf '%s\n' "${dir}"
}

ALL_LABELS=(
  documentation
  area/image
  area/ci
  area/tests
  area/scripts
  area/security-model
  area/agent-policy
)

# The committed tree. This is the case that turns the gate into a test of the
# repository rather than of the gate: any future edit that adds a path rule
# without a catalog entry, or retires a rule and leaves its catalog entry
# behind, fails here.
output="$(run_catalog_gate "${REPO_ROOT}" "${ALL_LABELS[@]}")"
assert_status "the committed catalog and configuration agree" 0 "$?"
assert_absent "an agreeing pair reports no drift" "${output}" "::error"
assert_equal "an agreeing pair creates nothing" "" "$(cat "${LABEL_CREATES}")"
assert_contains "an existing label is left alone, not edited" "${output}" \
  "label already exists, leaving it alone: area/security-model"

# A fresh repository. Every label is created, with the colour and description
# the catalog names -- the catalog is the source of truth for both, so a create
# that dropped either would silently make the workflow's table decorative.
output="$(run_catalog_gate "${REPO_ROOT}")"
assert_status "provisioning every missing label succeeds" 0 "$?"
creates="$(cat "${LABEL_CREATES}")"
assert_equal "one create per catalog entry" 7 "$(printf '%s\n' "${creates}" | grep -c .)"
assert_contains "a created label carries its catalog colour and description" \
  "${creates}" \
  "label create area/security-model --color b60205 --description Signing key, signature policy, or registry configuration"
assert_contains "the plain documentation label is provisioned too" "${creates}" \
  "label create documentation --color 0075ca --description"

# A half-provisioned repository, which is the state the workflow actually meets
# after a new label is added to both lists. The labels that exist must not be
# touched: `documentation` predates the workflow and keeps whatever colour a
# human gave it, and re-creating it would fail the step.
output="$(run_catalog_gate "${REPO_ROOT}" documentation area/image)"
assert_status "a partially provisioned repository succeeds" 0 "$?"
creates="$(cat "${LABEL_CREATES}")"
assert_equal "only the missing labels are created" 5 "$(printf '%s\n' "${creates}" | grep -c .)"
assert_absent "an existing label is never re-created" "${creates}" "label create documentation "
assert_absent "an existing label is never re-created" "${creates}" "label create area/image "

# Drift, direction one: a path rule whose label has no catalog entry. The label
# used here is `quality`, which is also the label this repository reserves for
# "approved by an owner for auto-merge on green CI" -- with sync-labels on, a
# path rule naming it would let a pull request award itself that approval by
# touching a path. The gate refuses it because it is uncatalogued, and the
# refusal must come before any label is created.
dir="$(config_copy drift-configured)"
cat >>"${dir}/.github/labeler.yml" <<'EXTRA'

quality:
  - changed-files:
      - any-glob-to-any-file:
          - "tests/**"
EXTRA
output="$(run_catalog_gate "${dir}" "${ALL_LABELS[@]}")"
assert_status "a configured label with no catalog entry fails the job" 1 "$?"
assert_contains "the annotation points at the configuration file" "${output}" \
  "::error file=.github/labeler.yml::label quality is configured but has no catalog entry in .github/workflows/labeler.yml"
assert_equal "drift is detected before any label is created" "" "$(cat "${LABEL_CREATES}")"

# Drift, direction two: a catalog entry whose path rule was deleted. Only the
# key is removed, so the failure is exactly the missing rule and not a second
# malformed one.
dir="$(config_copy drift-catalogued)"
sed -i '/^area\/scripts:$/d' "${dir}/.github/labeler.yml"
output="$(run_catalog_gate "${dir}" "${ALL_LABELS[@]}")"
assert_status "a catalog entry with no path rule fails the job" 1 "$?"
assert_contains "the annotation points at the workflow file" "${output}" \
  "::error file=.github/workflows/labeler.yml::label area/scripts has a catalog entry but no path rule in .github/labeler.yml"
assert_absent "the surviving rules are not reported as drift" "${output}" \
  "label area/tests has a catalog entry"
assert_equal "drift is detected before any label is created" "" "$(cat "${LABEL_CREATES}")"

# The configured set is read by a `sed` that only matches a key at column 0, so
# reindenting the configuration -- or nesting it under a new top-level key --
# reads as "no labels are configured". That must fail loudly. It is the one
# failure mode that could otherwise pass as success: a gate that found nothing
# to check has nothing to complain about.
dir="$(config_copy indented)"
sed -i 's/^\([A-Za-z]\)/  \1/' "${dir}/.github/labeler.yml"
output="$(run_catalog_gate "${dir}" "${ALL_LABELS[@]}")"
assert_status "a reindented configuration fails the job" 1 "$?"
assert_contains "a reindented configuration is reported as missing rules" "${output}" \
  "label documentation has a catalog entry but no path rule"
assert_equal "no label is created from an unreadable configuration" "" \
  "$(cat "${LABEL_CREATES}")"

# The joins the body cannot make. It checks the catalog against the
# configuration; these check the configuration against the rules docs/ci-cd.md
# states about it, which together pin all three copies of the list.
configured_labels="$(sed -nE 's/^([A-Za-z][A-Za-z0-9._/-]*):[[:space:]]*$/\1/p' "${LABELER_CONFIG}")"
assert_equal "the configuration names seven labels" 7 \
  "$(printf '%s\n' "${configured_labels}" | grep -c .)"

# "A label that means someone approved something must never be reachable from a
# file path" (docs/ci-cd.md). `hold` and `needs-human` are here for the same
# reason: sync-labels removes a label whose paths stop supporting it, so a path
# rule naming one of these would also let a push clear it.
for reserved in quality testing ci security hold needs-human; do
  assert_absent "no path rule can award the ${reserved} label" \
    $'\n'"${configured_labels}"$'\n' $'\n'"${reserved}"$'\n'
done

unprefixed=""
while IFS= read -r name; do
  [[ -z "${name}" ]] && continue
  [[ "${name}" == "documentation" || "${name}" == area/* ]] && continue
  unprefixed+="${name} "
done <<<"${configured_labels}"
assert_equal "every path label is documentation or lives under area/" "" "${unprefixed}"

# docs/ci-cd.md's table is the third copy of the list and the only one no
# workflow reads, so it is the one that rots first.
doc_section="$(awk '
  /^## Pull request labels$/ { inside = 1; next }
  inside && /^## / { inside = 0 }
  inside
' "${CI_CD_DOC}")"
assert_extracted "the pull request labels section is still in docs/ci-cd.md" \
  "${doc_section}"
# shellcheck disable=SC2016
doc_labels="$(printf '%s\n' "${doc_section}" | sed -nE 's/^\| `([^`]+)` \|.*/\1/p')"
assert_equal "docs/ci-cd.md's table names exactly the configured labels" \
  "$(printf '%s\n' "${configured_labels}" | LC_ALL=C sort)" \
  "$(printf '%s\n' "${doc_labels}" | LC_ALL=C sort)"

# --- the issue forms in .github/ISSUE_TEMPLATE ------------------------------
#
# Nothing in tests/ opens these files. They matter for two reasons a static
# read does not surface.
#
# First, GitHub drops a malformed form from the "New issue" chooser silently:
# no error, no annotation, no failed check -- the form simply stops being
# offered, and because `blank_issues_enabled: false` below removes the plain
# text box too, what is left is the contact link. A form that has lost its
# `description`, gained a duplicate `id`, or quoted a `required:` boolean is
# invalid in exactly that way, and every gate this repository runs would stay
# green through it.
#
# Second, the flavor list is written down five times: twice as a matrix in
# .github/workflows/build.yml, once as the `AS <flavor>` build stages in the
# Containerfile those matrices target, and once in each form's dropdown. The
# first three fail loudly when they disagree -- buildah cannot build a stage
# that does not exist. The dropdowns are the copy that rots without a symptom:
# a fourth flavor would ship for months while every bug report about it had to
# be filed as "Not flavor-specific".
#
# The parser below is deliberately strict about the shape it accepts and
# reports any line it did not understand, because the alternative failure is
# the one that passes as success: a grep-shaped reader that finds nothing in a
# reindented file has nothing to complain about.

ISSUE_TEMPLATE_DIR="${REPO_ROOT}/.github/ISSUE_TEMPLATE"
ISSUE_TEMPLATE_CONFIG="${ISSUE_TEMPLATE_DIR}/config.yml"
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

# Flatten one issue form into tab-separated records, one per meaningful value:
#
#   top<TAB>name<TAB>Bug report
#   label<TAB><TAB>bug
#   3<TAB>type<TAB>dropdown
#   3<TAB>id<TAB>flavor
#   3<TAB>option<TAB>base
#   3<TAB>validations.required<TAB>true
#
# where the first field is the 1-based index of the body item the record
# belongs to. A line that does not fit the grammar becomes an `unknown` record
# rather than being skipped.
issue_form_dump() { # file
  awk '
    function emit(kind, value) { printf "%d\t%s\t%s\n", item, kind, value }
    function unknown() { printf "unknown\tline %d\t%s\n", NR, $0 }
    # Swallow a block scalar: every following line indented past its key.
    block > 0 {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^ */)
      if (RLENGTH > block) next
      block = 0
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ || /^---$/ { next }
    /^[A-Za-z_]/ {
      key = $0; sub(/:.*/, "", key)
      value = $0; sub(/^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/, "", value)
      in_labels = 0; in_body = 0; in_options = 0
      if (key == "body") { in_body = 1; next }
      if (key == "labels" && value == "") { in_labels = 1; next }
      printf "top\t%s\t%s\n", key, value
      next
    }
    in_labels && /^  - [^ ]/ { value = $0; sub(/^  - /, "", value); printf "label\t\t%s\n", value; next }
    !in_body { unknown(); next }
    /^  - type: [a-z]+$/ {
      item++; itemtype = $0; sub(/^  - type: /, "", itemtype)
      emit("type", itemtype); scope = "item"; in_options = 0
      next
    }
    /^    [a-z_]+:/ {
      key = $0; sub(/^    /, "", key); sub(/:.*/, "", key)
      value = $0; sub(/^    [a-z_]+:[[:space:]]*/, "", value)
      in_options = 0
      if (key == "attributes") { scope = "attributes"; next }
      if (key == "validations") { scope = "validations"; next }
      emit(key, value)
      next
    }
    /^      [a-z_]+:/ {
      key = $0; sub(/^      /, "", key); sub(/:.*/, "", key)
      value = $0; sub(/^      [a-z_]+:[[:space:]]*/, "", value)
      in_options = 0
      if (key == "options" && value == "") { in_options = 1; next }
      if (value == "|" || value == ">") { block = 6; emit(scope "." key, "<block>"); next }
      emit(scope "." key, value)
      next
    }
    in_options && /^        - [^ ]/ { value = $0; sub(/^        - /, "", value); emit("option", value); next }
    in_options && /^          [a-z_]+:/ {
      key = $0; sub(/^          /, "", key); sub(/:.*/, "", key)
      value = $0; sub(/^          [a-z_]+:[[:space:]]*/, "", value)
      emit("option-" key, value)
      next
    }
    { unknown() }
  ' "$1"
}

# The records of one kind, values only, in file order.
dump_values() { # dump kind
  printf '%s\n' "$1" | awk -F'\t' -v kind="$2" '$2 == kind { print $3 }'
}

# The records of one kind, as "<item index><TAB><value>", so a value can be
# joined back to the body item it came from.
dump_pairs() { # dump kind
  printf '%s\n' "$1" | awk -F'\t' -v kind="$2" '$2 == kind { print $1 "\t" $3 }'
}

# One checkbox item's options as "<required><TAB><label text>". A checkbox
# option carries its own `required:`, so the flag has to be paired with the
# option it followed rather than with the item -- an item holding one required
# box and one optional one is the normal case, not an edge one.
checkbox_options() { # dump item-index
  printf '%s\n' "$1" | awk -F'\t' -v i="$2" '
    function flush() { if (seen) print required "\t" label }
    $1 != i { next }
    $2 == "option" { flush(); seen = 1; label = $3; sub(/^label: /, "", label); required = "false"; next }
    $2 == "option-required" { required = $3; next }
    END { flush() }
  '
}

# The one flavor list the build actually uses. Both matrices and the
# Containerfile stages have to agree for any image to exist at all, so this is
# the copy the forms are measured against rather than a fourth hand-written
# list here.
matrix_flavors="$(sed -nE 's/^[[:space:]]*flavor: \[(.*)\][[:space:]]*$/\1/p' "${BUILD_WORKFLOW}" |
  tr -d ' ' | tr ',' '\n')"
assert_extracted "build.yml still declares a flavor matrix" "${matrix_flavors}"
assert_equal "both jobs run the same three flavors" \
  $'base\nkde\nxfce\nbase\nkde\nxfce' "${matrix_flavors}"
FLAVORS="$(printf '%s\n' "${matrix_flavors}" | LC_ALL=C sort -u)"
assert_equal "the matrix flavors are the Containerfile's build stages" \
  "${FLAVORS}" \
  "$(sed -nE 's/^FROM base-core AS ([A-Za-z0-9_-]+)$/\1/p' "${CONTAINERFILE}" | LC_ALL=C sort -u)"

# Discovered by glob, not listed here: a form added later is validated by
# every case below without anyone remembering to add it.
shopt -s nullglob
issue_forms=("${ISSUE_TEMPLATE_DIR}"/*.yml "${ISSUE_TEMPLATE_DIR}"/*.yaml)
shopt -u nullglob
forms=()
for form in "${issue_forms[@]}"; do
  [[ "${form}" == "${ISSUE_TEMPLATE_CONFIG}" ]] && continue
  forms+=("${form}")
done
assert_extracted "the issue template directory still holds forms" "${forms[*]:-}"

# A Markdown template in this directory would be offered by the chooser and
# skipped by every case below, so the two must be the same set of files.
assert_equal "every issue template is a form this test validates" \
  "$((${#forms[@]} + 1))" \
  "$(find "${ISSUE_TEMPLATE_DIR}" -type f | grep -c .)"

# GitHub's own list. A `type:` outside it makes the form invalid, and the
# parser's item grammar only recognises these shapes.
FORM_TYPES=" markdown input textarea dropdown checkboxes "

flavor_dropdowns=0
required_credential_checkboxes=0
for form in "${forms[@]}"; do
  name="${form#"${ISSUE_TEMPLATE_DIR}/"}"
  dump="$(issue_form_dump "${form}")"
  assert_extracted "${name} parses to something" "${dump}"
  assert_absent "${name} has no line the form grammar does not accept" \
    "${dump}" $'unknown\t'

  # Both are mandatory: GitHub will not offer a form that is missing either.
  assert_equal "${name} names itself for the chooser" 1 \
    "$(dump_values "${dump}" name | grep -c .)"
  assert_equal "${name} describes itself for the chooser" 1 \
    "$(dump_values "${dump}" description | grep -c .)"

  # A form that applies no label files an issue nothing can route.
  form_labels="$(printf '%s\n' "${dump}" | awk -F'\t' '$1 == "label" { print $3 }')"
  assert_extracted "${name} applies at least one label" "${form_labels}"

  # The same rule docs/ci-cd.md states for path labels, for the same reason:
  # these labels mean "an owner approved this for auto-merge on green CI", and
  # an issue form hands its label to whoever opens the issue.
  for reserved in quality testing ci security hold needs-human; do
    assert_absent "${name} cannot award the ${reserved} label" \
      $'\n'"${form_labels}"$'\n' $'\n'"${reserved}"$'\n'
  done

  # `title:` seeds the issue title, and both forms use it to carry a kind
  # prefix a human scanning the tracker can sort on.
  title="$(dump_values "${dump}" title)"
  assert_equal "${name} seeds a bracketed title prefix" 1 \
    "$(printf '%s\n' "${title}" | grep -cE '^"\[[a-z]+\] "$')"

  types="$(dump_values "${dump}" type)"
  assert_extracted "${name} has body items" "${types}"
  unknown_types=""
  while IFS= read -r itemtype; do
    [[ -z "${itemtype}" ]] && continue
    [[ "${FORM_TYPES}" == *" ${itemtype} "* ]] || unknown_types+="${itemtype} "
  done <<<"${types}"
  assert_equal "${name} uses only the body item types GitHub accepts" "" \
    "${unknown_types}"

  # Every input needs an `id` (it names the section in the filed issue), no
  # `markdown` block may have one, and a repeated id invalidates the form.
  ids="$(dump_values "${dump}" id)"
  id_items="$(dump_pairs "${dump}" id | cut -f1 | LC_ALL=C sort)"
  input_items="$(printf '%s\n' "${dump}" |
    awk -F'\t' '$2 == "type" && $3 != "markdown" { print $1 }' | LC_ALL=C sort)"
  assert_equal "${name} gives every input an id and no markdown block one" \
    "${input_items}" "${id_items}"
  assert_equal "${name} uses each id once" \
    "$(printf '%s\n' "${ids}" | grep -c .)" \
    "$(printf '%s\n' "${ids}" | LC_ALL=C sort -u | grep -c .)"
  markdown_items="$(printf '%s\n' "${dump}" |
    awk -F'\t' '$2 == "type" && $3 == "markdown" { print $1 }')"
  while IFS= read -r markdown_item; do
    [[ -z "${markdown_item}" ]] && continue
    assert_absent "${name} item ${markdown_item} is markdown, so it has no validations" \
      "$(printf '%s\n' "${dump}" | awk -F'\t' -v i="${markdown_item}" '$1 == i')" \
      "validations."
  done <<<"${markdown_items}"

  # `required: "true"` is a string, and GitHub rejects the form rather than
  # reading it as the boolean it looks like.
  bad_booleans=""
  while IFS= read -r value; do
    [[ -z "${value}" ]] && continue
    [[ "${value}" == "true" || "${value}" == "false" ]] || bad_booleans+="${value} "
  done < <(printf '%s\n' "${dump}" |
    awk -F'\t' '$2 == "validations.required" || $2 == "option-required" { print $3 }')
  assert_equal "${name} writes every required flag as a bare boolean" "" \
    "${bad_booleans}"

  # A dropdown with fewer than two options is a question with one answer, and
  # a checkboxes item with no `label:` renders as an empty box.
  while IFS= read -r pair; do
    [[ -z "${pair}" ]] && continue
    index="${pair%%$'\t'*}"
    itemtype="${pair#*$'\t'}"
    options="$(printf '%s\n' "${dump}" |
      awk -F'\t' -v i="${index}" '$1 == i && $2 == "option" { print $3 }')"
    case "${itemtype}" in
      dropdown)
        option_count="$(printf '%s\n' "${options}" | grep -c .)"
        if ((option_count < 2)); then
          check "${name} dropdown ${index} offers a choice" 1 \
            "only ${option_count} option(s)"
        else
          check "${name} dropdown ${index} offers a choice" 0
        fi
        # The join this section exists for. A dropdown that mentions any build
        # flavor must offer all of them, plus exactly one escape hatch for the
        # reports that are not about an image -- and the escape hatch has to be
        # last, so the flavors read as the list they are.
        offered="$(printf '%s\n' "${options}" | LC_ALL=C sort)"
        if [[ -n "$(comm -12 <(printf '%s\n' "${offered}") <(printf '%s\n' "${FLAVORS}"))" ]]; then
          flavor_dropdowns=$((flavor_dropdowns + 1))
          assert_equal "${name} dropdown ${index} offers every build flavor" \
            "${FLAVORS}" \
            "$(comm -12 <(printf '%s\n' "${offered}") <(printf '%s\n' "${FLAVORS}"))"
          assert_equal "${name} dropdown ${index} adds one non-flavor answer" \
            "$(($(printf '%s\n' "${FLAVORS}" | grep -c .) + 1))" \
            "${option_count}"
          assert_equal "${name} dropdown ${index} keeps the non-flavor answer last" \
            "" \
            "$(comm -12 <(printf '%s\n' "${options}" | tail -n1) <(printf '%s\n' "${FLAVORS}"))"
        fi
        ;;
      checkboxes)
        unlabelled=""
        while IFS= read -r option; do
          [[ -z "${option}" ]] && continue
          [[ "${option}" == label:* ]] || unlabelled+="${option} "
        done <<<"${options}"
        assert_equal "${name} checkboxes ${index} labels every box" "" "${unlabelled}"
        ;;
    esac
  done < <(dump_pairs "${dump}" type)

  # This repository ships a signing key and its policy, and asks reporters for
  # image digests and command output. The redaction checkbox is the one prompt
  # standing between that and a pasted credential, so it stays required.
  while IFS= read -r index; do
    [[ -z "${index}" ]] && continue
    while IFS=$'\t' read -r required label; do
      [[ "${label}" == *credentials* ]] || continue
      [[ "${required}" == "true" ]] || continue
      required_credential_checkboxes=$((required_credential_checkboxes + 1))
    done < <(checkbox_options "${dump}" "${index}")
  done <<<"$(printf '%s\n' "${dump}" | awk -F'\t' '$2 == "type" && $3 == "checkboxes" { print $1 }')"
done

assert_equal "every form offering flavors is joined to the build matrix" \
  "${#forms[@]}" "${flavor_dropdowns}"
assert_equal "a required credential-redaction checkbox survives somewhere" 1 \
  "${required_credential_checkboxes}"

# `blank_issues_enabled: false` is what makes all of the above load-bearing:
# with the plain text box removed, a form that GitHub refuses to render leaves
# a reporter with the contact link and no way to open an issue at all.
config_dump="$(grep -vE '^[[:space:]]*(#|$)' "${ISSUE_TEMPLATE_CONFIG}")"
assert_extracted "the chooser configuration is readable" "${config_dump}"
assert_contains "blank issues stay disabled" "${config_dump}" "blank_issues_enabled: false"
contact_links="$(grep -cE '^  - name: ' "${ISSUE_TEMPLATE_CONFIG}")"
for key in name url about; do
  assert_equal "every contact link carries ${key}" "${contact_links}" \
    "$(grep -cE "^ +-? *${key}: " "${ISSUE_TEMPLATE_CONFIG}")"
done
assert_equal "every contact link is https" "${contact_links}" \
  "$(grep -cE '^ +url: https://' "${ISSUE_TEMPLATE_CONFIG}")"

# --- docs/risk-tiers.md against the tree it describes ------------------------
#
# Same job again, one step further out. docs/risk-tiers.md decides how much
# evidence a change owes before it merges, and it decides it by restating
# things the tree already holds mechanically: build.yml's `paths-ignore`, the
# zizmor trigger, a list of repository paths per tier, the literal strings of
# the T3 security controls, and renovate.json's automerge scope. Nothing
# opened the file -- run-tests.sh globs tests/test-*.sh and none of them read
# docs/, and check-coverage.sh counts traced lines in shipped shell and can
# never see Markdown.
#
# It lands in this file rather than a new tests/test-*.sh for the reason the
# rest of this section exists: a new file would have to be added by hand to
# both ShellCheck lists, one of which lives in build.yml itself.
#
# The page's own argument is why the drift matters more than it would for
# ordinary prose: "CI cannot tell these tiers apart, which is the whole reason
# the table has a last column." The table is the control. Edit build.yml's
# paths-ignore and the T0 section goes on promising that nothing runs; move a
# T3 artifact and the T3 list goes on naming the old path. Neither turns
# anything red.

# GitHub path-filter globbing, which is neither shell globbing nor a regex:
# `**` crosses `/`, a single `*` does not, `?` is one non-slash character, and
# a leading `**/` matches zero segments as well as many.
#
# That last rule is load-bearing rather than pedantic. The T0 section claims
# "`*.md` anywhere" is skipped, and the only ignore glob that could cover
# README.md at the repository root is `**/*.md` with `**` matching nothing. If
# GitHub did not read it that way, editing README.md alone would trigger the
# full build and the T0 claim would be false for the four Markdown files in
# the root. The case table below fixes the semantics this file assumes; the
# assertions after it are only worth as much as that table.
glob_to_ere() { # glob
  local glob="$1" out="" index=0 char
  while ((index < ${#glob})); do
    char="${glob:index:1}"
    case "${char}" in
      '*')
        if [[ "${glob:index:3}" == '**/' ]]; then
          out+='(.*/)?'
          index=$((index + 3))
          continue
        fi
        if [[ "${glob:index:2}" == '**' ]]; then
          out+='.*'
          index=$((index + 2))
          continue
        fi
        out+='[^/]*'
        ;;
      '?') out+='[^/]' ;;
      # Escape everything that is not plainly safe in an ERE rather than
      # listing the metacharacters, so a character nobody thought of is
      # escaped instead of being handed to the regex engine.
      *)
        if [[ "${char}" == [A-Za-z0-9/_-] ]]; then
          out+="${char}"
        else
          out+="\\${char}"
        fi
        ;;
    esac
    index=$((index + 1))
  done
  printf '^%s$' "${out}"
}

glob_matches() { # glob path
  local pattern
  pattern="$(glob_to_ere "$1")"
  [[ "$2" =~ ${pattern} ]]
}

matcher_failures=0
while IFS='|' read -r case_glob case_path case_want; do
  [[ -z "${case_glob}" ]] && continue
  if glob_matches "${case_glob}" "${case_path}"; then
    case_got=yes
  else
    case_got=no
  fi
  [[ "${case_got}" == "${case_want}" ]] ||
    matcher_failures=$((matcher_failures + 1))
done <<'GLOB_CASES'
**/*.md|README.md|yes
**/*.md|docs/risk-tiers.md|yes
**/*.md|docs/reflections/README.md|yes
**/*.md|.github/pull_request_template.md|yes
**/*.md|Containerfile|no
**/*.md|docs/notes.md.bak|no
**/*.md|mdfile|no
docs/**|docs/ci-cd.md|yes
docs/**|docs/reflections/README.md|yes
docs/**|docs|no
docs/**|docs-extra/x.md|no
docs/**|mydocs/x.md|no
.github/workflows/**|.github/workflows/build.yml|yes
.github/workflows/**|.github/workflows/nested/build.yml|yes
.github/workflows/**|.github/workflows|no
.github/workflows/**|.github/labeler.yml|no
docs/*|docs/ci-cd.md|yes
docs/*|docs/reflections/README.md|no
docs/?.md|docs/a.md|yes
docs/?.md|docs/ab.md|no
cosign.pub|cosign.pub|yes
cosign.pub|cosignXpub|no
packages-*.txt|packages-kde.txt|yes
packages-*.txt|packages-kde.txt.bak|no
GLOB_CASES
assert_equal "the path-filter matcher answers its own case table" 0 \
  "${matcher_failures}"

# `on.<event>.<key>` as a list, from a workflow whose `on:` block is written in
# the block style both of this repository's path-filtered workflows use. An
# empty result means the block moved or was reindented, which every caller
# below checks rather than quietly asserting over nothing.
workflow_event_filter() { # workflow event key
  awk -v want_event="$2" -v want_key="$3" '
    /^on:$/ { in_on = 1; next }
    in_on && /^[A-Za-z_]/ { in_on = 0 }
    in_on && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      event = substr($0, 3, length($0) - 3)
      in_key = 0
      next
    }
    in_on && /^    [A-Za-z_][A-Za-z0-9_-]*:$/ {
      key = substr($0, 5, length($0) - 5)
      in_key = (event == want_event && key == want_key)
      next
    }
    in_key && /^      - / {
      value = substr($0, 9)
      gsub(/^["'"'"']|["'"'"']$/, "", value)
      print value
      next
    }
    in_key && !/^      / { in_key = 0 }
  ' "$1"
}

doc_section() { # heading_regex
  awk -v want="$1" '
    $0 ~ want { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside
  ' "${RISK_TIERS_DOC}"
}

sorted() { printf '%s\n' "$1" | LC_ALL=C sort; }

# The two workflows, first. Both events must carry the same filter: a filter
# added to `pull_request` and forgotten on `push` would skip the build on main
# for a change the pull request built, which is the drift the doc cannot see.
BUILD_IGNORE_GLOBS="$(workflow_event_filter "${BUILD_WORKFLOW}" pull_request paths-ignore)"
assert_extracted "build.yml's pull_request paths-ignore is still readable" \
  "${BUILD_IGNORE_GLOBS}"
assert_equal "build.yml ignores exactly the two documentation globs" \
  "$(printf '%s\n' '**/*.md' 'docs/**')" \
  "$(sorted "${BUILD_IGNORE_GLOBS}")"
assert_equal "build.yml's push and pull_request filters agree" \
  "${BUILD_IGNORE_GLOBS}" \
  "$(workflow_event_filter "${BUILD_WORKFLOW}" push paths-ignore)"

ZIZMOR_GLOBS="$(workflow_event_filter "${ZIZMOR_WORKFLOW}" pull_request paths)"
assert_extracted "zizmor.yaml's pull_request paths is still readable" "${ZIZMOR_GLOBS}"
assert_equal "zizmor triggers only on the workflow directory" \
  ".github/workflows/**" "${ZIZMOR_GLOBS}"
assert_equal "zizmor.yaml's push and pull_request filters agree" \
  "${ZIZMOR_GLOBS}" \
  "$(workflow_event_filter "${ZIZMOR_WORKFLOW}" push paths)"

# Then the doc's inline copy of both, so the page and the workflow fail
# together. The T0 section quotes the build filter as a YAML flow sequence and
# names the zizmor trigger in the next clause.
T0_SECTION="$(doc_section '^## T0 — ')"
assert_extracted "the T0 section is still in docs/risk-tiers.md" "${T0_SECTION}"

# The backticks below are Markdown code fences being matched literally, not
# command substitution -- as in the docs/ci-cd.md read above.
# shellcheck disable=SC2016
doc_ignore_globs="$(printf '%s\n' "${T0_SECTION}" |
  grep -oE '`paths-ignore: \[[^]]*\]`' |
  sed -E 's/^`paths-ignore: \[//; s/\]`$//' |
  tr ',' '\n' |
  sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
assert_extracted "the T0 section still quotes the build filter" "${doc_ignore_globs}"
assert_equal "the doc's quoted filter is build.yml's filter" \
  "$(sorted "${BUILD_IGNORE_GLOBS}")" "$(sorted "${doc_ignore_globs}")"
# shellcheck disable=SC2016
assert_contains "the T0 section still names the zizmor trigger" \
  "${T0_SECTION}" '`.github/workflows/**`'

# With both filters pinned, the tiering claims computed from them can be
# checked against the committed file set. These are the statements that stop
# being true when someone adds a file, without anything else changing.
matches_any_ignore_glob() { # path
  local glob
  while IFS= read -r glob; do
    [[ -z "${glob}" ]] && continue
    glob_matches "${glob}" "$1" && return 0
  done <<<"${BUILD_IGNORE_GLOBS}"
  return 1
}

# "What runs: nothing." Every file the T0 section claims as documentation has
# to match an ignore glob, or a T0 pull request touching it gets the full
# three-flavor build the page promises it will not.
t0_unmatched=""
t0_checked=0
while IFS= read -r tracked_path; do
  [[ -z "${tracked_path}" ]] && continue
  t0_checked=$((t0_checked + 1))
  matches_any_ignore_glob "${tracked_path}" || t0_unmatched+="${tracked_path} "
done < <(git -C "${REPO_ROOT}" ls-files |
  grep -E '^(docs/|\.github/prompts/|\.github/pull_request_template\.md$|[^/]+\.md$)')
check "the T0 file set is non-empty" "$((t0_checked > 0 ? 0 : 1))" \
  "git ls-files matched nothing, so the loop below asserted over no files"
assert_equal "every file the T0 section tiers as documentation is ignored by build.yml" \
  "" "${t0_unmatched}"

# And the carve-out paragraph, which is the same computation with the opposite
# expected answer: the issue forms are YAML, so they match neither glob and
# their edits run the full build. A `.github/ISSUE_TEMPLATE/bug.md` would make
# the paragraph false without touching the doc.
issue_form_matched=""
issue_forms_checked=0
while IFS= read -r tracked_path; do
  [[ -z "${tracked_path}" ]] && continue
  issue_forms_checked=$((issue_forms_checked + 1))
  matches_any_ignore_glob "${tracked_path}" && issue_form_matched+="${tracked_path} "
done < <(git -C "${REPO_ROOT}" ls-files | grep -E '^\.github/ISSUE_TEMPLATE/')
check "the issue-form file set is non-empty" "$((issue_forms_checked > 0 ? 0 : 1))" \
  "git ls-files matched no issue forms"
assert_equal "no issue form is ignored by build.yml, as the carve-out says" \
  "" "${issue_form_matched}"

# The tier table and the four sections are two copies of the same four ids and
# titles, and a rename lands in one of them.
table_tiers="$(sed -nE 's/^\| \*\*(T[0-9])\*\* ([^|]*[^| ])[[:space:]]*\|.*/\1\t\2/p' \
  "${RISK_TIERS_DOC}")"
heading_tiers="$(sed -nE 's/^## (T[0-9]) — (.*)$/\1\t\2/p' "${RISK_TIERS_DOC}")"
assert_equal "the tier table still has four rows" 4 \
  "$(printf '%s\n' "${table_tiers}" | grep -c .)"
assert_equal "the tier table and the tier headings agree on every id and title" \
  "${table_tiers}" "${heading_tiers}"

# Every repository path the tier sections name, derived rather than listed: a
# backticked token that contains a `/` and does not start with one. That rule
# is narrow on purpose. It takes in the globs and the nested paths, and leaves
# out the in-image absolute paths (`/etc/pam.d/su`), the commands
# (`bootc upgrade`), and the bare names (`Containerfile`, `BOOTC_VERSION`) --
# the last of which the load-bearing list below covers instead.
tier_sections="$(awk '
  /^## T[0-9] — / { inside = 1 }
  inside && /^## What automation/ { inside = 0 }
  inside
' "${RISK_TIERS_DOC}")"
assert_extracted "the four tier sections are still readable" "${tier_sections}"

TRACKED_PATHS="$(git -C "${REPO_ROOT}" ls-files)"

glob_matches_a_tracked_path() { # glob
  local tracked_path
  while IFS= read -r tracked_path; do
    [[ -z "${tracked_path}" ]] && continue
    glob_matches "$1" "${tracked_path}" && return 0
  done <<<"${TRACKED_PATHS}"
  return 1
}

# A trailing `/` is the doc's shorthand for a directory, which no committed
# path equals; match what is inside it instead.
as_path_glob() { # token
  case "$1" in
    */) printf '%s**' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

missing_paths=""
named_paths_checked=0
# The backticks in the `grep` feeding this loop are Markdown code fences
# matched literally; the directive has to sit in front of the whole loop
# rather than beside the `done` line that carries them.
# shellcheck disable=SC2016
while IFS= read -r token; do
  [[ -z "${token}" ]] && continue
  [[ "${token}" == /* ]] && continue
  [[ "${token}" == */* ]] || continue
  [[ "${token}" == *" "* ]] && continue
  named_paths_checked=$((named_paths_checked + 1))
  glob_matches_a_tracked_path "$(as_path_glob "${token}")" ||
    missing_paths+="${token} "
done < <(printf '%s\n' "${tier_sections}" | grep -oE '`[^`]+`' | tr -d '`' | sort -u)
check "the tier sections name some repository paths" \
  "$((named_paths_checked > 0 ? 0 : 1))" "no backticked path was recognised"
assert_equal "every repository path the tier sections name still exists" \
  "" "${missing_paths}"

# The other direction. The check above passes if a line is deleted, because a
# path the doc stopped naming is a path it cannot name wrongly. These are the
# artifacts whose tier is the reason the page exists, so losing the line that
# tiers them has to fail too.
LOAD_BEARING_PATHS=(
  .coverage-thresholds.json
  .editorconfig
  .shellcheckrc
  .github/labeler.yml
  .github/pull_request_template.md
  Containerfile
  Justfile
  cosign.pub
  renovate.json
  system_files/etc/containers/policy.json
  system_files/etc/containers/registries.d/
)
unnamed_paths=""
absent_paths=""
for load_bearing in "${LOAD_BEARING_PATHS[@]}"; do
  [[ "${tier_sections}" == *"\`${load_bearing}\`"* ]] ||
    unnamed_paths+="${load_bearing} "
  glob_matches_a_tracked_path "$(as_path_glob "${load_bearing}")" ||
    absent_paths+="${load_bearing} "
done
assert_equal "every load-bearing path is still tiered by name" "" "${unnamed_paths}"
assert_equal "every load-bearing path is still committed" "" "${absent_paths}"

# T3's security controls are quoted as literal strings, and all six live in the
# Containerfile. The page's claim about them -- that the four root-login
# controls "are only safe together" -- is unreadable if the strings drift, and
# a reader checking the doc against the image would find nothing.
T3_SECTION="$(doc_section '^## T3 — ')"
assert_extracted "the T3 section is still in docs/risk-tiers.md" "${T3_SECTION}"
T3_CONTROLS=(
  "PermitRootLogin prohibit-password"
  "pam_wheel.so use_uid"
  "passwd --expire"
  "PACMAN_CACHE_BUST"
  "BOOTC_VERSION"
  "BOOTC_COMMIT"
)
# `grep -wF`, not a substring test: `PACMAN_CACHE_BUST` is a prefix of
# `PACMAN_CACHE_BUSTER`, so a plain `case`/`grep -F` would keep passing through
# exactly the rename this is here to catch. `-w` anchors both ends of the match
# on a non-word character, which every one of these phrases has around it in
# both files.
undocumented_controls=""
unbuilt_controls=""
for control in "${T3_CONTROLS[@]}"; do
  printf '%s\n' "${T3_SECTION}" | grep -qwF -- "${control}" ||
    undocumented_controls+="[${control}] "
  grep -qwF -- "${control}" "${CONTAINERFILE}" || unbuilt_controls+="[${control}] "
done
assert_equal "the T3 section still names every security control" \
  "" "${undocumented_controls}"
assert_equal "every control the T3 section names is still in the Containerfile" \
  "" "${unbuilt_controls}"

# renovate.json is the one place the tiering is enforced rather than described,
# which is what the automation table says about it.
#
# Only the doc side is asserted here. That the carve-out exists at all, and
# that it is ordered after the blanket rule it is an exception to, are already
# invariants in tests/check-invariants.sh ("a major bootc bump never
# automerges", "the bootc exception is the last automerge rule that applies to
# it") -- restating them would be a second copy of a check that is already
# stricter than the one this file would write. What nothing covered is the
# join: check-invariants.sh never opens docs/risk-tiers.md, so the table could
# describe an automerge scope renovate.json stopped having.
automerge_types="$(jq -r '
  [ .packageRules[] | select(.automerge == true) | .matchUpdateTypes ]
  | if length == 1 then .[0] | join("/") else "found \(length) automerging rules" end
' "${RENOVATE_CONFIG}")"
assert_extracted "renovate.json still has one general automerge rule" "${automerge_types}"
assert_equal "the automation table lists the update types renovate.json automerges" \
  "${automerge_types}" \
  "$(sed -nE 's/^\| Renovate automerge \| On for ([a-zA-Z/]+) updates.*/\1/p' \
    "${RISK_TIERS_DOC}")"
# shellcheck disable=SC2016
assert_contains "the automation table still names the carve-out" \
  "$(grep -E '^\| Renovate carve-out \|' "${RISK_TIERS_DOC}")" \
  'Major `bootc-dev/bootc` bumps never automerge'

# --- .github's agent instructions against the policy they delegate to -------
#
# Three hand-written files tell a coding agent, or a human opening a pull
# request, what this repository will not accept: `.github/copilot-instructions.md`,
# `.github/pull_request_template.md`, and the prompt files under
# `.github/prompts/`. None of them was opened by anything. `git grep` for
# either of the first two across tests/ finds only the *path strings* the
# risk-tiers section above tiers; nothing reads their contents, and
# check-coverage.sh counts traced lines in shipped shell, so Markdown is
# outside what it can ever see.
#
# The claims are checkable because none of them is prose about intent. Every
# one is a pointer: at an AGENTS.md section, at a `just` recipe, at a control
# that exists in the Containerfile, at the set of build flavors. Each pointer
# can dangle without anything turning red -- rename the `lint` recipe and
# copilot-instructions.md goes on forbidding a command that no longer exists,
# move a safeguard and the template goes on asking for an attestation about
# nothing.
#
# Only the join is asserted here. That the security controls themselves are
# present and active in the Containerfile is already tests/check-invariants.sh's
# job, and it checks it more strictly than this file would -- it strips comment
# lines first, so the *explanation* of a deleted control cannot satisfy it.
# What nothing covered is that `.github/` still names what that file guards.

COPILOT_INSTRUCTIONS="${REPO_ROOT}/.github/copilot-instructions.md"
PR_TEMPLATE="${REPO_ROOT}/.github/pull_request_template.md"
PROMPTS_DIR="${REPO_ROOT}/.github/prompts"
AGENTS_DOC="${REPO_ROOT}/AGENTS.md"
JUSTFILE="${REPO_ROOT}/Justfile"

# Like doc_section() above, but for any file and any heading depth: the body
# ends at the next heading of the same level or shallower. AGENTS.md's
# load-bearing sections are a mix of `##` and `###`, and a `###`-scoped
# extractor that stopped only at `##` would swallow the sibling subsections
# after it and make a "the section still says X" assertion pass on text that
# belongs to a different section.
md_section() { # file heading_regex
  awk -v want="$2" '
    !inside && $0 ~ want {
      inside = 1
      match($0, /^#+/)
      level = RLENGTH
      next
    }
    inside && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) inside = 0
    }
    inside
  ' "$1"
}

# These files are hard-wrapped prose, so a phrase this section looks for is as
# likely to straddle a line break as not -- `container signature policy` is
# split across lines 11 and 12 of copilot-instructions.md today. Matching the
# raw text would make each assertion depend on where the wrap happens to fall,
# which is both fragile and the wrong thing to assert: a reflow is not drift.
# Every run of whitespace collapses to one space first, so what is matched is
# the sentence rather than its layout.
flatten() { # text
  printf '%s' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

COPILOT_TEXT="$(flatten "$(cat "${COPILOT_INSTRUCTIONS}")")"
assert_extracted ".github/copilot-instructions.md is still readable" "${COPILOT_TEXT}"
# shellcheck disable=SC2016
assert_contains "copilot-instructions.md still delegates to AGENTS.md" \
  "${COPILOT_TEXT}" '`AGENTS.md`'

# The delegation is not a bare pointer: the file enumerates what it expects to
# find in AGENTS.md, and a reader who follows it looks for those things by
# name. Both directions are checked, so deleting the promise passes no more
# quietly than deleting the section it promises. The headings are matched
# anchored and whole, because `## Consent standard` and a hypothetical
# `## Consent standard (deprecated)` are not the same section.
DELEGATED_TOPICS=(
  "consent gates|^## Consent standard$"
  "image and VM safety|^## Container, image, and virtual machine safety$"
  "security invariants|^### Do not weaken the image's security model$"
  "validation requirements|^## Validation expectations$"
  "completion reporting|^## Completion and cleanup$"
)
unpromised_topics=""
unwritten_sections=""
for entry in "${DELEGATED_TOPICS[@]}"; do
  topic="${entry%%|*}"
  heading="${entry#*|}"
  [[ "${COPILOT_TEXT}" == *"${topic}"* ]] || unpromised_topics+="[${topic}] "
  grep -qE -- "${heading}" "${AGENTS_DOC}" || unwritten_sections+="[${heading}] "
done
assert_equal "copilot-instructions.md still names every AGENTS.md topic it delegates" \
  "" "${unpromised_topics}"
assert_equal "every topic copilot-instructions.md delegates is still a section of AGENTS.md" \
  "" "${unwritten_sections}"

# The four safeguards it forbids weakening, each joined to the thing in the
# tree that implements it. A rename on either side leaves the instruction
# addressed to nobody: an agent told never to weaken the "daily pacman cache
# bust" cannot find it if the build argument is now called something else.
#
# `grep -qwF` rather than a substring test, for the reason the T3 loop above
# gives: `PACMAN_CACHE_BUST` is a prefix of `PACMAN_CACHE_BUSTER`, and a
# substring match would survive exactly the rename this is here to catch.
#
# And it reads the Containerfile with its full-line comments stripped, for the
# reason tests/check-invariants.sh gives at length: every one of these controls
# is described in a rationale comment using the same words as the instruction
# that implements it, so a grep over the raw file is satisfied by the
# *explanation* of a control that has been rewritten. Rewriting `passwd
# --expire root` as `passwd -e root` leaves the comment above it untouched and
# was the one mutation this loop let through before the strip.
CONTAINERFILE_ACTIVE="$(grep -v '^[[:space:]]*#' "${CONTAINERFILE}")"
SAFEGUARD_ANCHORS=(
  "default-root-password safeguards|Containerfile|passwd --expire"
  "container signature policy|Containerfile|/etc/pki/containers/arch-bootc.pub"
  "daily pacman cache bust|Containerfile|PACMAN_CACHE_BUST"
  "systemd enablement layout|Containerfile|/usr/lib/systemd/system/multi-user.target.wants"
)
unguarded_safeguards=""
dangling_anchors=""
for entry in "${SAFEGUARD_ANCHORS[@]}"; do
  safeguard="${entry%%|*}"
  rest="${entry#*|}"
  anchor="${rest#*|}"
  [[ "${COPILOT_TEXT}" == *"${safeguard}"* ]] || unguarded_safeguards+="[${safeguard}] "
  printf '%s\n' "${CONTAINERFILE_ACTIVE}" | grep -qwF -- "${anchor}" ||
    dangling_anchors+="[${anchor}] "
done
assert_equal "copilot-instructions.md still names every safeguard it forbids weakening" \
  "" "${unguarded_safeguards}"
assert_equal "every safeguard copilot-instructions.md names is still built into the image" \
  "" "${dangling_anchors}"

# `cosign.pub` is the other half of the signature policy -- the repository-root
# key that the COPY above installs -- and the policy file that requires a valid
# signature for this namespace. Neither is a Containerfile literal, so they are
# checked as committed paths.
for required in cosign.pub system_files/etc/containers/policy.json; do
  check "${required} is still committed, so the signature policy resolves" \
    "$([[ -f "${REPO_ROOT}/${required}" ]] && echo 0 || echo 1)" \
    "${required} is missing"
done

# The three actions copilot-instructions.md says not to run unauthorized. The
# first is a `just` recipe by name; the other two are consent gates in
# AGENTS.md's numbered list, which is what "the authorization required by
# `AGENTS.md`" resolves to.
# shellcheck disable=SC2016
assert_contains "copilot-instructions.md still gates \`just lint\`" \
  "${COPILOT_TEXT}" '`just lint`'
assert_equal "the Justfile still has the lint recipe copilot-instructions.md gates" \
  "lint" "$(sed -nE 's/^(lint):.*/\1/p' "${JUSTFILE}")"
VALIDATION_SECTION="$(flatten "$(md_section "${AGENTS_DOC}" '^## Validation expectations$')")"
assert_extracted "AGENTS.md's validation section is still readable" "${VALIDATION_SECTION}"
assert_contains "AGENTS.md's validation section still prescribes \`just lint\`" \
  "${VALIDATION_SECTION}" "just lint"

CONSENT_SECTION="$(flatten "$(md_section "${AGENTS_DOC}" '^## Consent standard$')")"
assert_extracted "AGENTS.md's consent section is still readable" "${CONSENT_SECTION}"
for gate in "Run a local image build." \
  "Install an image to a disk file, create a virtual machine, or boot one."; do
  assert_contains "AGENTS.md still gates: ${gate}" "${CONSENT_SECTION}" "${gate}"
done

# "Preserve the explanatory comments in `Containerfile`" is the one instruction
# whose subject cannot be pinned to a single string, because it is about all of
# them. The floor below is a collapse detector rather than a style rule: the
# file is over half comments today, and the failure mode the instruction exists
# to prevent is a rewrite that strips the rationale wholesale while the build
# stays green.
containerfile_comments="$(grep -c '^[[:space:]]*#' "${CONTAINERFILE}")"
check "the Containerfile still carries its explanatory comments" \
  "$((containerfile_comments >= 200 ? 0 : 1))" \
  "only ${containerfile_comments} comment lines remain"
assert_extracted "AGENTS.md still explains why those comments are load-bearing" \
  "$(md_section "${AGENTS_DOC}" '^### The comments are part of the product$')"

# --- the pull request template -----------------------------------------------
#
# Same class of claim, aimed at a human instead. The template is the only place
# a contributor is asked to attest to anything, and GitHub renders it into
# every new pull request body without validating a word of it.

PR_TEMPLATE_TEXT="$(flatten "$(cat "${PR_TEMPLATE}")")"
assert_extracted ".github/pull_request_template.md is still readable" "${PR_TEMPLATE_TEXT}"

# Every box ships unchecked. A `- [x]` committed into the template is an
# attestation nobody made, pre-ticked in every pull request from then on, and
# it is invisible in the rendered diff of a body nobody re-reads.
template_boxes="$(grep -cE '^[[:space:]]*- \[[ xX]\] ' "${PR_TEMPLATE}")"
check "the template still asks for checkbox attestations" \
  "$((template_boxes > 0 ? 0 : 1))" "no checkboxes were found"
assert_equal "no checkbox ships pre-ticked" \
  "" "$(grep -nE '^[[:space:]]*- \[[^ ]\] ' "${PR_TEMPLATE}")"

# The instructional comments are HTML comments, which GitHub hides. An
# unbalanced one does not error: it swallows the rest of the template, or
# spills the instructions into the visible body. Either way the author sees
# something other than the form.
template_opens="$(grep -o '<!--' "${PR_TEMPLATE}" | wc -l)"
template_closes="$(grep -o -- '-->' "${PR_TEMPLATE}" | wc -l)"
assert_equal "every HTML comment in the template is closed" \
  "${template_opens}" "${template_closes}"

# The template's attestations, joined to what they are about.
# shellcheck disable=SC2016
assert_contains "the template still asks for \`git diff --check\`" \
  "${PR_TEMPLATE_TEXT}" '`git diff --check`'
assert_contains "AGENTS.md still prescribes the command the template asks about" \
  "${VALIDATION_SECTION}" "git diff --check"
assert_contains "the template still asks about the root-login safeguards" \
  "${PR_TEMPLATE_TEXT}" "root-login safeguards"
assert_contains "the template still asks about the signature policy" \
  "${PR_TEMPLATE_TEXT}" "image signature policy"
# shellcheck disable=SC2016
assert_contains "the template still asks about the Containerfile rationale comments" \
  "${PR_TEMPLATE_TEXT}" '`Containerfile` rationale comments'

# "Every affected flavor was validated" is only an answerable question while
# the flavors are a fixed, discoverable set. They are defined in three places
# that nothing joined: the per-flavor package lists, build.yml's matrices, and
# the AGENTS.md section that says a flavor's evidence does not transfer. A
# fourth flavor added to the matrix and not to the package lists -- or the
# reverse -- makes the attestation ambiguous rather than false, which is worse.
assert_contains "the template still asks for per-flavor evidence" \
  "${PR_TEMPLATE_TEXT}" "Every affected flavor was validated"
package_list_flavors="$(git -C "${REPO_ROOT}" ls-files 'packages-*.txt' |
  sed -E 's#^packages-(.*)\.txt$#\1#' | LC_ALL=C sort | tr '\n' ' ')"
assert_equal "the per-flavor package lists still define three flavors" \
  "base kde xfce " "${package_list_flavors}"
# Every `flavor:` matrix in build.yml, normalised and deduplicated. Collecting
# all of them rather than one job's is deliberate: the publish job and the
# package-retention job each declare their own, and a flavor added to one and
# not the other publishes images nobody prunes.
build_matrix_flavors="$(grep -oE 'flavor: \[[^]]*\]' "${BUILD_WORKFLOW}" |
  sed -E 's/^flavor: \[//; s/\]$//' | tr ',' '\n' |
  sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_extracted "build.yml still declares a flavor matrix" "${build_matrix_flavors}"
assert_equal "build.yml's flavor matrices are the package lists' flavors" \
  "${package_list_flavors}" "${build_matrix_flavors}"
FLAVOR_SECTION="$(md_section "${AGENTS_DOC}" '^### Flavors are separate paths$')"
assert_extracted "AGENTS.md still explains why flavor evidence does not transfer" \
  "${FLAVOR_SECTION}"
unnamed_flavors=""
for flavor in ${package_list_flavors}; do
  printf '%s\n' "${FLAVOR_SECTION}" | grep -qwF -- "${flavor}" ||
    unnamed_flavors+="${flavor} "
done
assert_equal "AGENTS.md's flavor section still names every flavor that is built" \
  "" "${unnamed_flavors}"

# --- .github/prompts ---------------------------------------------------------
#
# A prompt file is only a prompt file if its name ends `.prompt.md` and it
# opens with YAML front matter carrying a `description`. Get either wrong and
# the editor does not report an error -- the prompt simply never appears in the
# picker, which is indistinguishable from nobody having reached for it.

shopt -s nullglob
prompt_files=("${PROMPTS_DIR}"/*)
shopt -u nullglob
check ".github/prompts still holds at least one prompt" \
  "$(( ${#prompt_files[@]} > 0 ? 0 : 1 ))" "the directory is empty"

misnamed_prompts=""
undescribed_prompts=""
undelegated_prompts=""
for prompt_file in "${prompt_files[@]}"; do
  prompt_name="$(basename -- "${prompt_file}")"
  [[ "${prompt_name}" == *.prompt.md ]] || misnamed_prompts+="${prompt_name} "
  # Front matter is the first `---` line and everything up to the next one, and
  # it only counts when the first `---` is line 1: a blank line above it and
  # the block is body text that renders as a horizontal rule.
  front_matter="$(awk 'NR == 1 && $0 != "---" { exit } NR == 1 { next } /^---$/ { exit } { print }' \
    "${prompt_file}")"
  [[ -n "$(printf '%s\n' "${front_matter}" | sed -nE 's/^description:[[:space:]]*(.+)$/\1/p')" ]] ||
    undescribed_prompts+="${prompt_name} "
  grep -qwF -- "AGENTS.md" "${prompt_file}" || undelegated_prompts+="${prompt_name} "
done
assert_equal "every file in .github/prompts is named <name>.prompt.md" \
  "" "${misnamed_prompts}"
assert_equal "every prompt opens with front matter carrying a description" \
  "" "${undescribed_prompts}"
assert_equal "every prompt still delegates to AGENTS.md" "" "${undelegated_prompts}"

# The triage prompt's first step is AGENTS.md's preflight by name, and its last
# is the repository's stop-before-external-action rule. Both are sections of
# AGENTS.md, so the prompt is a pointer into it in the same way
# copilot-instructions.md is.
TRIAGE_PROMPT="$(flatten "$(cat "${PROMPTS_DIR}/triage-repository-issue.prompt.md")")"
assert_extracted "the triage prompt is still readable" "${TRIAGE_PROMPT}"
assert_contains "the triage prompt still opens with the mandatory preflight" \
  "${TRIAGE_PROMPT}" "mandatory preflight"
assert_extracted "AGENTS.md still has the preflight the triage prompt invokes" \
  "$(md_section "${AGENTS_DOC}" '^## Mandatory preflight$')"


printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

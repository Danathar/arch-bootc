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

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

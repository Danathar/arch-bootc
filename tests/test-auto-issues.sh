#!/usr/bin/env bash
set -uo pipefail

# Execute auto-issues.yml's "File or close issues for scheduled runs" step
# against a `gh` stub that serves staged JSON, with the real jq. The step
# decides, per watched workflow (every scheduled one, and the boot test, which
# a build starts rather than a clock), whether to open an issue, comment on
# the open one, close it, or do nothing; every one of those is a GitHub write,
# and a wrong decision is either a silent red run or a flood of duplicate
# issues. Running the body Actions executes keeps the test attached to that
# decision rather than to a second copy of it.
#
# No network: `gh` is shadowed on PATH, answers from files in a temporary
# directory, and records its argv and every body it is handed. The step runs in
# an empty working directory so it cannot read or write the real checkout.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/auto-issues.yml"

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
FIXTURES="${WORK_DIR}/fixtures"
BODIES="${WORK_DIR}/bodies"
GH_LOG="${WORK_DIR}/gh-log"
mkdir -p "${RUN_DIR}" "${STUB_DIR}" "${FIXTURES}" "${BODIES}"

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

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required: the step under test reads every reply with jq\n' >&2
  exit 1
fi

# Print the `run:` block of the named step of the named job, dedented to
# column 0. Refusing an empty result below makes a rename or layout change fail
# instead of turning every behavioral case into a test of nothing.
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

step_run="$(workflow_step_run "${WORKFLOW}" "file-issues" "File or close issues for scheduled runs")"
if [[ -n "${step_run}" ]]; then
  check "the step's body is still where this test expects it" 0
else
  check "the step's body is still where this test expects it" 1 \
    "nothing was extracted; the job or step was renamed, moved, or reindented"
fi

# A GitHub expression is expanded by Actions before the shell sees the body.
# This harness does no expression evaluation, so fail if one is introduced
# instead of executing shell with different semantics from CI.
# shellcheck disable=SC2016
assert_absent "the step's body is plain shell" "${step_run}" '${{'

# Replies: runs-<workflow>.json for `run list` (an empty array when absent),
# issues.json for `issue list`, view-<n>.json for `issue view`. Writes are
# logged, and each body handed over with --body-file is kept as
# bodies/<n>-<verb>, numbered in call order. GH_STUB_FAIL names one
# "<noun> <verb>" pair that fails instead of answering.
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${GH_STUB_LOG}"
args=("$@")
workflow="" body_file=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --workflow) workflow="${args[i + 1]}" ;;
    --body-file) body_file="${args[i + 1]}" ;;
  esac
done
keep_body() {
  local n
  n="$(find "${GH_STUB_BODIES}" -type f | wc -l)"
  cp -- "${body_file}" "${GH_STUB_BODIES}/$((n + 1))-$1"
}
[[ "${1:-} ${2:-}" != "${GH_STUB_FAIL:-}" ]] || exit 1
case "${1:-} ${2:-}" in
  "run list") cat "${GH_STUB_FIXTURES}/runs-${workflow}.json" 2>/dev/null || printf '[]\n' ;;
  "issue list") cat "${GH_STUB_FIXTURES}/issues.json" 2>/dev/null || printf '[]\n' ;;
  "issue view") cat "${GH_STUB_FIXTURES}/view-${3}.json" ;;
  "issue create") keep_body create ;;
  "issue comment") keep_body comment ;;
  "issue close") ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"

BOT="app/github-actions"
BUILD_MARKER="<!-- auto-issues:build.yml -->"
NIGHTLY_MARKER="<!-- auto-issues:nightly-compliance.yml -->"
BOOT_MARKER="<!-- auto-issues:boot-test.yml -->"

# An ISO 8601 UTC timestamp the given number of hours before now, the shape
# the Actions API gives createdAt.
hours_ago() { date -u -d "@$(($(date -u +%s) - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }

# Stage the newest completed scheduled run of one workflow: id, conclusion,
# hours since it started.
stage_run() {
  local workflow="$1" id="$2" conclusion="$3" age="$4"
  jq -n --argjson id "${id}" --arg c "${conclusion}" --arg at "$(hours_ago "${age}")" '
    [{databaseId: $id, conclusion: $c, createdAt: $at,
      url: "https://example.test/actions/runs/\($id)",
      headSha: "0123456789abcdef0123456789abcdef01234567"}]' \
    >"${FIXTURES}/runs-${workflow}.json"
}
# Stage several completed runs of one workflow, newest first, each given as
# id:conclusion:hours-ago -- the order `gh run list` returns them in.
stage_runs() {
  local workflow="$1" entry id conclusion age
  shift
  for entry in "$@"; do
    IFS=: read -r id conclusion age <<<"${entry}"
    jq -n --argjson id "${id}" --arg c "${conclusion}" --arg at "$(hours_ago "${age}")" '
      {databaseId: $id, conclusion: $c, createdAt: $at,
       url: "https://example.test/actions/runs/\($id)",
       headSha: "0123456789abcdef0123456789abcdef01234567"}'
  done | jq -s '.' >"${FIXTURES}/runs-${workflow}.json"
}
# One open issue of the `issue list` reply.
issue_entry() {
  jq -n --argjson n "$1" --arg login "$2" --arg body "$3" \
    '{number: $n, author: {login: $login, is_bot: ($login | startswith("app/"))}, body: $body}'
}
stage_issues() { jq -s '.' >"${FIXTURES}/issues.json"; }
# The start time stage_run wrote, read back so a clock tick between staging and
# asserting cannot make a case fail.
staged_start() { jq -r '.[0].createdAt' "${FIXTURES}/runs-$1.json"; }
# The `issue view` reply: body, then any number of comment bodies.
stage_view() {
  local n="$1" body="$2"
  shift 2
  jq -n --arg body "${body}" '{body: $body, comments: ($ARGS.positional | map({author: {login: "github-actions"}, body: .}))}' \
    --args "$@" >"${FIXTURES}/view-${n}.json"
}
reset_fixtures() { rm -f -- "${FIXTURES}"/* "${BODIES}"/*; }

run_step() {
  : >"${GH_LOG}"
  # The step has no `shell:` key, so Actions runs it as `bash -e {0}`: errexit
  # comes from the runner, pipefail only from the step's own `set` line.
  (
    cd -- "${RUN_DIR}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      GH_STUB_FIXTURES="${FIXTURES}" \
      GH_STUB_BODIES="${BODIES}" \
      GH_STUB_LOG="${GH_LOG}" \
      GH_TOKEN="test-token" \
      REPO="Danathar/arch-bootc" \
      "${BASH}" --noprofile --norc -e -c "${step_run}"
  )
}
writes() { grep -E '^issue (create|comment|close)' "${GH_LOG}"; }
body_of() { cat "${BODIES}"/*-"$1" 2>/dev/null; }

# --- Both green, nothing open ------------------------------------------------
reset_fixtures
stage_run build.yml 101 success 3
stage_run nightly-compliance.yml 201 success 8
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_status "two green scheduled runs exit 0" 0 "$?"
assert_equal "two green scheduled runs write nothing" "" "$(writes)"
assert_equal "each workflow's newest completed unattended run on main is what is read" \
  "run list --repo Danathar/arch-bootc --workflow build.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow nightly-compliance.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow agent-audit.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow boot-test.yml --all --branch main --event workflow_run --status completed --limit 20 --json databaseId,conclusion,url,createdAt,headSha" \
  "$(grep '^run list' "${GH_LOG}")"

# Every scheduled workflow but this one is read, and the boot test, whose
# unattended runs a build starts rather than a clock. A new scheduled workflow,
# or one dropped from the loop, fails here instead of going red unseen.
watched="$(sed -nE 's/^for workflow in (.*); do$/\1/p' <<<"${step_run}" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
scheduled="$(cd -- "${REPO_ROOT}/.github/workflows" && { grep -lE '^  schedule:' -- *.y*ml; echo boot-test.yml; } |
  grep -vx 'auto-issues.yml' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_equal "the step reads every scheduled workflow except auto-issues.yml, and boot-test.yml" \
  "${scheduled}" "${watched}"
# The boot test is read by its workflow_run runs because that is how it starts.
# Given a schedule of its own, or a different trigger, the event the step asks
# for would name runs that do not exist and nothing would ever be filed.
check "boot-test.yml starts on workflow_run and has no schedule of its own" \
  "$(grep -qE '^  workflow_run:' "${REPO_ROOT}/.github/workflows/boot-test.yml" &&
    ! grep -qE '^  schedule:' "${REPO_ROOT}/.github/workflows/boot-test.yml" && echo 0 || echo 1)"

# An issue tells the reader where to look: `See docs/ci-cd.md, section "X"`.
# Each X must still be a heading there, or the pointer leads nowhere.
pointers="$(grep -oE 'See docs/ci-cd\.md, section \\"[^\\]+\\"' <<<"${step_run}" |
  sed -E 's/.*section \\"(.*)\\"$/\1/')"
assert_equal "the step points at a docs/ci-cd.md section for nightly-compliance.yml, agent-audit.yml and boot-test.yml" \
  "3" "$(grep -c . <<<"${pointers}")"
while IFS= read -r section; do
  [[ -n "${section}" ]] || continue
  check "docs/ci-cd.md has the section \"${section}\" an issue points at" \
    "$(grep -qxF "## ${section}" "${REPO_ROOT}/docs/ci-cd.md" && echo 0 || echo 1)"
done <<<"${pointers}"

# --- A failed build opens one issue ------------------------------------------
reset_fixtures
stage_run build.yml 102 failure 2
stage_run nightly-compliance.yml 202 success 7
stage_issues </dev/null
output="$(run_step 2>&1)"
assert_status "a failed run is reported, and the step still exits 0" 0 "$?"
assert_equal "a failed build opens exactly one issue, with a title a reader understands" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the daily image build failed on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
body="$(body_of create)"
assert_contains "the issue says how the run ended" "${body}" "ended with \`failure\`."
assert_contains "the issue links the run" "${body}" "- Run: https://example.test/actions/runs/102"
assert_contains "the issue names the commit" "${body}" "- Commit: 0123456789abcdef0123456789abcdef01234567"
assert_contains "the issue says what a failed build means for installed systems" "${body}" \
  "installed systems get no updates until a scheduled build succeeds again"
assert_contains "the issue carries the marker that finds it again" "${body}" "${BUILD_MARKER}"
assert_contains "the issue records which run it reported" "${body}" "<!-- auto-issues-run:102:failed -->"
assert_contains "the log names the decision" "${output}" "build.yml: newest completed scheduled run 102 (failure) -> failed; open issue: none"

for conclusion in timed_out startup_failure; do
  reset_fixtures
  stage_run nightly-compliance.yml 203 "${conclusion}" 1
  stage_issues </dev/null
  run_step >/dev/null 2>&1
  assert_equal "a ${conclusion} run is a failure too" \
    "issue create --repo Danathar/arch-bootc --title Scheduled run of the nightly compliance checks failed on main --body-file" \
    "$(writes | sed -E 's/ [^ ]+$//')"
done

# --- An open issue gets a comment, not a second issue -------------------------
#
# A person's issue that quotes the marker is listed first and must not be the
# one the job writes on: the author is part of the match.
reset_fixtures
stage_run build.yml 103 failure 2
stage_issues < <(
  issue_entry 40 "Danathar" "Copied from the bot: ${BUILD_MARKER}"
  issue_entry 41 "${BOT}" $'Earlier failure.\n'"${NIGHTLY_MARKER}"
  issue_entry 42 "${BOT}" $'Earlier failure.\n<!-- auto-issues-run:99:failed -->\n'"${BUILD_MARKER}"
)
stage_view 42 $'Earlier failure.\n<!-- auto-issues-run:99:failed -->\n'"${BUILD_MARKER}"
run_step >/dev/null 2>&1
assert_status "commenting on an open issue exits 0" 0 "$?"
assert_equal "a new failed run comments on the job's own open issue for that workflow" \
  "issue comment 42 --repo Danathar/arch-bootc --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
body="$(body_of comment)"
assert_contains "the comment links the new run" "${body}" "https://example.test/actions/runs/103"
assert_contains "the comment records the new run" "${body}" "<!-- auto-issues-run:103:failed -->"
assert_absent "a comment does not repeat the issue's marker" "${body}" "${BUILD_MARKER}"

# The same run seen again -- a second dispatch the same day -- says nothing.
stage_view 42 "${BUILD_MARKER}" "older comment" $'Newer comment.\n<!-- auto-issues-run:103:failed -->'
run_step >/dev/null 2>&1
assert_equal "a run the open issue already mentions is not mentioned again" "" "$(writes)"

# --- A green run closes the issue; a cancelled one does not -------------------
reset_fixtures
stage_run build.yml 104 success 2
stage_issues < <(issue_entry 42 "${BOT}" "${BUILD_MARKER}")
run_step >/dev/null 2>&1
assert_equal "a green run closes the job's open issue with a comment linking that run" \
  "issue close 42 --repo Danathar/arch-bootc --reason completed --comment The scheduled run of the daily image build on \`main\` succeeded again: https://example.test/actions/runs/104 (started $(staged_start build.yml), commit 0123456789abcdef0123456789abcdef01234567). Closing; a new issue is opened if it fails again." \
  "$(writes)"

stage_run build.yml 105 cancelled 2
run_step >/dev/null 2>&1
assert_status "a cancelled run with an issue open exits 0" 0 "$?"
assert_equal "a cancelled run neither comments nor closes" "" "$(writes)"

# --- A schedule that stopped ---------------------------------------------------
#
# The newest run is green but two days old: the workflow stopped running, and
# that is an issue even though nothing failed.
reset_fixtures
stage_run build.yml 106 success 49
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a newest run older than 48 hours opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the daily image build has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the issue says when the last run started" "$(body_of create)" \
  "started at $(staged_start build.yml), more than 48 hours ago"
assert_contains "the stopped issue names the daily cadence" "$(body_of create)" \
  "more than 48 hours ago. It runs daily, so the schedule has stopped"
# The build's failure impact says "this run" did not refresh the images. A
# stale run may well have been green, so that sentence must not follow it.
assert_absent "the stopped issue does not carry the failure impact" "$(body_of create)" \
  "The published images were not refreshed by this run"

# The limit is inclusive: a run exactly 48 hours old is already stale.
reset_fixtures
stage_run build.yml 106 success 48
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a newest run exactly 48 hours old opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the daily image build has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"

stage_run build.yml 106 success 47
stage_issues < <(issue_entry 44 "${BOT}" "${BUILD_MARKER}")
run_step >/dev/null 2>&1
assert_equal "a green run 47 hours old is still current" \
  "issue close" "$(writes | cut -d' ' -f1,2)"

# The failure already reported, and the same run still the newest two days on:
# the issue is told the schedule stopped, once.
reset_fixtures
stage_run build.yml 107 failure 50
stage_issues < <(issue_entry 43 "${BOT}" $'<!-- auto-issues-run:107:failed -->\n'"${BUILD_MARKER}")
stage_view 43 $'<!-- auto-issues-run:107:failed -->\n'"${BUILD_MARKER}"
run_step >/dev/null 2>&1
assert_equal "a reported failure that is still the newest run two days on gets a 'stopped' comment" \
  "issue comment 43 --repo Danathar/arch-bootc --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the comment records the new state" "$(body_of comment)" "<!-- auto-issues-run:107:stale -->"

# --- The monthly agent audit ------------------------------------------------
#
# It runs on the 1st, so a green run three weeks old is current, and only a
# run older than 33 days means the schedule stopped.
reset_fixtures
stage_run agent-audit.yml 301 failure 9
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a failed agent audit opens exactly one issue, named for the audit" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the monthly agent audit failed on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the issue says what a failed audit means, and where to read about it" "$(body_of create)" \
  "An agent pull request merged in the audited window has no \`— hive:\` signature line, or one of its commits has no \`Signed-off-by\` trailer, or the audit refused its window. The run summary lists each finding. See docs/ci-cd.md, section \"Agent audit trail\"."
assert_contains "the issue carries the audit's own marker" "$(body_of create)" \
  "<!-- auto-issues:agent-audit.yml -->"

reset_fixtures
stage_run agent-audit.yml 302 success $((32 * 24))
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a green agent audit 32 days old is still current" "" "$(writes)"

stage_run agent-audit.yml 302 success $((34 * 24))
run_step >/dev/null 2>&1
assert_equal "a newest agent audit older than 33 days opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the monthly agent audit has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the stopped issue names the monthly cadence" "$(body_of create)" \
  "more than 33 days ago. It runs monthly, so the schedule has stopped"

# The 33-day limit is exact and inclusive, as the daily one is: one hour short
# is current, the hour itself is stale.
reset_fixtures
stage_run agent-audit.yml 303 success $((33 * 24 - 1))
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a green agent audit one hour short of 33 days is still current" "" "$(writes)"

stage_run agent-audit.yml 303 success $((33 * 24))
run_step >/dev/null 2>&1
assert_equal "a newest agent audit exactly 33 days old opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the monthly agent audit has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"

# --- The boot test ------------------------------------------------------------
#
# Read by its workflow_run runs, newest first, passing over the runs a pull
# request's build started: their job is skipped and they check nothing.
reset_fixtures
stage_runs boot-test.yml 403:skipped:1 402:skipped:2 401:failure:3 400:success:20
stage_issues </dev/null
output="$(run_step 2>&1)"
assert_status "a failed boot test is reported, and the step still exits 0" 0 "$?"
assert_equal "a failed boot test behind skipped runs opens exactly one issue, named for the boot test" \
  "issue create --repo Danathar/arch-bootc --title Run of the boot test failed on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
body="$(body_of create)"
assert_contains "the boot test issue links the failed run, not a skipped one" "${body}" \
  "- Run: https://example.test/actions/runs/401"
assert_contains "the boot test issue says how the run ended" "${body}" \
  "The newest run of the boot test on \`main\` ended with \`failure\`."
assert_contains "the boot test issue says what a red boot means, and where to read about it" "${body}" \
  "did not boot in a VM, or booted and failed a check"
assert_contains "the boot test issue points at its docs/ci-cd.md section" "${body}" \
  "See docs/ci-cd.md, section \"Boot test\"."
assert_contains "the boot test issue is closed by a later run, not a scheduled one" "${body}" \
  "This issue is closed automatically when a later run succeeds."
assert_contains "the boot test issue carries its own marker" "${body}" "${BOOT_MARKER}"
assert_contains "the log names the boot test decision" "${output}" \
  "boot-test.yml: newest completed run 401 (failure) -> failed; open issue: none"

reset_fixtures
stage_runs boot-test.yml 405:skipped:1 404:success:2
stage_issues < <(issue_entry 46 "${BOT}" "${BOOT_MARKER}")
run_step >/dev/null 2>&1
assert_equal "a green boot test behind a skipped run closes its open issue" \
  "issue close 46 --repo Danathar/arch-bootc --reason completed --comment The run of the boot test on \`main\` succeeded again: https://example.test/actions/runs/404 (started $(jq -r '.[1].createdAt' "${FIXTURES}/runs-boot-test.yml.json"), commit 0123456789abcdef0123456789abcdef01234567). Closing; a new issue is opened if it fails again." \
  "$(writes)"

reset_fixtures
stage_runs boot-test.yml 406:skipped:1 407:skipped:2
stage_issues < <(issue_entry 47 "${BOT}" "${BOOT_MARKER}")
run_step >/dev/null 2>&1
assert_equal "only skipped boot test runs neither comment nor close" "" "$(writes)"

reset_fixtures
stage_runs boot-test.yml 408:success:49
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a newest boot test older than 48 hours opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Run of the boot test has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the stopped boot test issue says what starts it" "$(body_of create)" \
  "more than 48 hours ago. It runs after every daily build, so the schedule has stopped"

# --- No scheduled run at all, and an API failure ------------------------------
reset_fixtures
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_status "no scheduled run yet exits 0" 0 "$?"
assert_equal "no scheduled run yet (a new fork) files nothing" "" "$(writes)"

# A failed read must fail the step. The issue list matters most: read as empty,
# it would open a duplicate of the issue already open.
for read_call in "run list" "issue list"; do
  reset_fixtures
  stage_run build.yml 108 failure 2
  stage_issues < <(issue_entry 45 "${BOT}" "${BUILD_MARKER}")
  GH_STUB_FAIL="${read_call}" run_step >/dev/null 2>&1
  status=$?
  check "a failed '${read_call}' fails the step instead of passing as 'nothing to report'" \
    "$([[ "${status}" != 0 ]] && echo 0 || echo 1)" "exit ${status}"
  assert_equal "a failed '${read_call}' writes nothing" "" "$(writes)"
done

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

#!/usr/bin/env bash
set -uo pipefail

# Execute auto-issues.yml's "File or close issues for scheduled runs" step
# against a `gh` stub that serves staged JSON, with the real jq. The step
# decides, per watched scheduled workflow, whether to open an issue, comment on
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
# issues.json for `issue list` (closed-issues.json with `--state closed`),
# view-<n>.json for `issue view`. Writes are
# logged, and each body handed over with --body-file is kept as
# bodies/<n>-<verb>, numbered in call order. GH_STUB_FAIL names one
# "<noun> <verb>" pair that fails instead of answering.
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${GH_STUB_LOG}"
args=("$@")
workflow="" body_file="" state=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --workflow) workflow="${args[i + 1]}" ;;
    --state) state="${args[i + 1]}" ;;
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
  "issue list")
    if [[ "${state}" == "closed" ]]; then
      cat "${GH_STUB_FIXTURES}/closed-issues.json" 2>/dev/null || printf '[]\n'
    else
      cat "${GH_STUB_FIXTURES}/issues.json" 2>/dev/null || printf '[]\n'
    fi
    ;;
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
assert_equal "each workflow's newest completed scheduled run on main is what is read" \
  "run list --repo Danathar/arch-bootc --workflow build.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow nightly-compliance.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow agent-audit.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha
run list --repo Danathar/arch-bootc --workflow boot-test.yml --all --branch main --event schedule --status completed --limit 1 --json databaseId,conclusion,url,createdAt,headSha" \
  "$(grep '^run list' "${GH_LOG}")"

# Every scheduled workflow but this one is read. A new scheduled workflow, or
# one dropped from the loop, fails here instead of going red unseen.
watched="$(sed -nE 's/^for workflow in (.*); do$/\1/p' <<<"${step_run}" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
scheduled="$(cd -- "${REPO_ROOT}/.github/workflows" && grep -lE '^  schedule:' -- *.y*ml | grep -vx 'auto-issues.yml' | LC_ALL=C sort | tr '\n' ' ')"
assert_equal "the step reads every scheduled workflow except auto-issues.yml" \
  "${scheduled}" "${watched}"

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

# --- A run already on a closed issue is not filed again ----------------------
#
# The issue for a failure that cannot be fixed (an agent audit finding, say)
# is closed while that run is still the newest. The next day must not open a
# fresh issue for the same run; a newer run, or the same run gone stale, must.
closed_entry() {
  jq -n --argjson n "$1" --arg login "$2" --arg body "$3" '
    {number: $n, author: {login: $login, is_bot: ($login | startswith("app/"))}, body: $body,
     comments: ($ARGS.positional | map({author: {login: (.[0:index(":")])}, body: .[index(":") + 1:]}))}' \
    --args "${@:4}"
}
stage_closed() { jq -s '.' >"${FIXTURES}/closed-issues.json"; }

reset_fixtures
stage_run agent-audit.yml 304 failure 24
stage_issues </dev/null
stage_closed < <(
  closed_entry 50 "${BOT}" $'Audit failed.\n<!-- auto-issues-run:304:failed -->\n'"<!-- auto-issues:agent-audit.yml -->"
)
output="$(run_step 2>&1)"
assert_status "a run already on a closed issue exits 0" 0 "$?"
assert_equal "a run a closed issue already reported opens no new issue" "" "$(writes)"
assert_contains "the log names the closed issue that reported it" "${output}" \
  "closed #50 already reported run 304 (failed); not filing it again"
assert_contains "closed issues are read with their comments" "$(grep '^issue list' "${GH_LOG}")" \
  "issue list --repo Danathar/arch-bootc --state closed --limit 1000 --json number,author,body,comments"

# Reported in a comment of the closed issue, not its body: still reported.
stage_closed < <(
  closed_entry 50 "${BOT}" $'<!-- auto-issues-run:290:failed -->\n'"<!-- auto-issues:agent-audit.yml -->" \
    $'github-actions:Again.\n<!-- auto-issues-run:304:failed -->'
)
run_step >/dev/null 2>&1
assert_equal "a run a closed issue's comment already reported opens no new issue" "" "$(writes)"

# A newer run fails: that is news, and gets a new issue.
stage_run agent-audit.yml 305 failure 2
run_step >/dev/null 2>&1
assert_equal "a newer failed run than the closed issue reported opens a new issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the monthly agent audit failed on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"

# The same run, now past the monthly limit: the schedule stopped, which is news.
reset_fixtures
stage_run agent-audit.yml 304 failure $((34 * 24))
stage_issues </dev/null
stage_closed < <(
  closed_entry 50 "${BOT}" $'<!-- auto-issues-run:304:failed -->\n'"<!-- auto-issues:agent-audit.yml -->"
)
run_step >/dev/null 2>&1
assert_equal "the reported run gone stale opens a 'stopped running' issue" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the monthly agent audit has stopped running on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"

# Only the bot's own words count: a person's closed issue quoting both markers,
# or a person's comment on the bot's issue, does not silence a failure. Nor
# does the same run on another workflow's closed issue.
for case_name in "a person's closed issue" "a person's comment" "another workflow's issue"; do
  reset_fixtures
  stage_run agent-audit.yml 306 failure 2
  stage_issues </dev/null
  case "${case_name}" in
    "a person's closed issue")
      stage_closed < <(closed_entry 51 "Danathar" $'<!-- auto-issues-run:306:failed -->\n<!-- auto-issues:agent-audit.yml -->') ;;
    "a person's comment")
      stage_closed < <(closed_entry 52 "${BOT}" "<!-- auto-issues:agent-audit.yml -->" \
        $'Danathar:Quoting <!-- auto-issues-run:306:failed -->') ;;
    "another workflow's issue")
      stage_closed < <(closed_entry 53 "${BOT}" $'<!-- auto-issues-run:306:failed -->\n'"${BUILD_MARKER}") ;;
  esac
  run_step >/dev/null 2>&1
  assert_equal "${case_name} carrying the run does not stop a new issue" \
    "issue create" "$(writes | cut -d' ' -f1,2)"
done

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

# --- A failed boot test opens one issue that says what failed ----------------
reset_fixtures
stage_run boot-test.yml 401 failure 2
stage_issues </dev/null
run_step >/dev/null 2>&1
assert_equal "a failed boot test opens exactly one issue, named for the boot test" \
  "issue create --repo Danathar/arch-bootc --title Scheduled run of the boot test failed on main --body-file" \
  "$(writes | sed -E 's/ [^ ]+$//')"
assert_contains "the issue says what a failed boot test means, and where to read about it" "$(body_of create)" \
  "A published flavor did not boot in a VM, or booted with a check failing; that is the image users pull now. The run summary names the flavor and the check. See docs/ci-cd.md, section \"Boot test\"."

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

# --- What docs/ci-cd.md says about this job ----------------------------------
# The cases above run the step. These read the page's section and compare what
# it states to the step, the workflow file and the permissions policy, so a
# change to one of them cannot leave the page describing a job that no longer
# exists. The sentences that only repeat a case above (a run already reported,
# a close on success) are not read again here.
CICD_DOC="${REPO_ROOT}/docs/ci-cd.md"
POLICY="${REPO_ROOT}/.github/policies/workflow-permissions.json"
doc_section="$(awk '/^## / { on = ($0 == "## Auto issues for failed scheduled runs"); next } on' "${CICD_DOC}")"
check "docs/ci-cd.md still has the section on this job" \
  "$([[ -n "${doc_section}" ]] && echo 0 || echo 1)"
# One line: the page wraps its sentences wherever the width falls.
doc_text="$(tr -s ' \n' ' ' <<<"${doc_section}")"
sorted_words() { tr -s ' \n' '\n' | grep . | LC_ALL=C sort | tr '\n' ' '; }
# The backticked words of the text on stdin.
# shellcheck disable=SC2016 # the backticks are what grep matches
backticked() { grep -oE '`[^`]+`' | tr -d '`'; }

# A workflow's daily schedule as minutes after midnight, nothing when its cron
# is not daily.
daily_start() {
  sed -nE 's/^ *- cron: "([0-9]+) ([0-9]+) \* \* \*".*/\2 \1/p' "$1" |
    while read -r hour minute; do printf '%d\n' "$((10#${hour} * 60 + 10#${minute}))"; done
}
# The latest a run can take: every job's cap added up as if none ran alongside
# another, leaving out the jobs a schedule never starts. GitHub's own cap is 360
# minutes for a job that sets none.
run_cap() {
  awk '
    function close_job() { if (open && !pr_only) total += cap ? cap : 360 }
    /^jobs:$/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z_][A-Za-z0-9_-]*:$/ { close_job(); open = 1; cap = 0; pr_only = 0; next }
    /^    timeout-minutes: / { cap = $2 }
    /^    if: github\.event_name == .pull_request.$/ { pr_only = 1 }
    END { close_job(); print total + 0 }
  ' "$1"
}

own_start="$(daily_start "${WORKFLOW}")"
own_time="$(printf '%02d:%02d' "$((own_start / 60))" "$((own_start % 60))")"
assert_contains "the page gives the job's schedule and its manual trigger" "${doc_text}" \
  "It runs daily at ${own_time} UTC, after the daily workflows have finished, and on \`workflow_dispatch\`."
check "the job can still be started by hand, as the page says" \
  "$(grep -qx '  workflow_dispatch:' "${WORKFLOW}" && echo 0 || echo 1)"

daily_read=0
for workflow in ${watched}; do
  start="$(daily_start "${REPO_ROOT}/.github/workflows/${workflow}")"
  [[ -n "${start}" ]] || continue
  daily_read=$((daily_read + 1))
  cap="$(run_cap "${REPO_ROOT}/.github/workflows/${workflow}")"
  check "${workflow} has finished by the time this job starts, as the page says" \
    "$(((start + cap) <= own_start ? 0 : 1))" "starts at minute ${start}, may take ${cap}, this job starts at minute ${own_start}"
done
assert_equal "three of the workflows read here run daily" "3" "${daily_read}"

doc_watched="$(sed -E 's/.*each on its own: (.*) The audit is included.*/\1/' <<<"${doc_text}" | backticked | sorted_words)"
assert_equal "the page lists the workflows the step reads" "${watched}" "${doc_watched}"

# The decision table, row by row: each row is found by what it says the job
# does, and what it says decides it is compared to the step.
doc_row() { grep -F -- "| $1 |" <<<"${doc_section}"; }
assert_equal "the page's decision table has five rows" "5" \
  "$(grep -E '^\| ' <<<"${doc_section}" | grep -cvE '^\| (Newest run|---) ')"
step_conclusions() {
  sed -nE "s/^ *([a-z_ |]+)\) state=\"$1\" ;;\$/\1/p" <<<"${step_run}" | tr -d ' ' | tr '|' ' ' | sorted_words
}
assert_equal "the conclusions the page says open an issue are the ones the step treats as failed" \
  "$(step_conclusions failed)" \
  "$(doc_row 'Opens an issue, or comments on the one already open' | backticked | sorted_words)"
assert_equal "the conclusion the page says closes the issue is the one the step treats as passed" \
  "$(step_conclusions passed)" \
  "$(doc_row 'Closes the open issue, if any, with a comment linking the run' | backticked | sorted_words)"

stale_row="$(doc_row 'Opens or comments the same way: the schedule stopped running')"
stale_hours="$(sed -nE 's/^\| Started more than ([0-9]+) hours ago .*/\1/p' <<<"${stale_row}")"
stale_days="$(sed -nE 's/.*\(([0-9]+) days for the monthly .*/\1/p' <<<"${stale_row}")"
stale_monthly="$(backticked <<<"${stale_row}")"
assert_contains "the page's daily limit is the step's, in hours" "${step_run}" "max_age_hours=${stale_hours:-none}"
assert_contains "the page's daily limit is the step's, in the issue's words" "${step_run}" "max_age_text=\"${stale_hours:-none} hours\""
assert_contains "the page's monthly limit is the step's, in hours" "${step_run}" "max_age_hours=\$((${stale_days:-none} * 24))"
assert_contains "the page's monthly limit is the step's, in the issue's words" "${step_run}" "max_age_text=\"${stale_days:-none} days\""
assert_equal "the workflow the page calls monthly is the one the step gives the monthly limit" \
  "$(awk '/^ *[a-z-]+\.yml\)$/ { arm = $1; sub(/\)$/, "", arm) } /^ *cadence="monthly"$/ { print arm }' <<<"${step_run}")" \
  "${stale_monthly}"

# A conclusion the page says changes nothing, on a workflow with an issue open.
ignored="$(doc_row 'Nothing; a cancelled run says nothing about the image' | backticked)"
reset_fixtures
stage_run build.yml 110 "${ignored:-none}" 2
stage_issues < <(issue_entry 46 "${BOT}" "${BUILD_MARKER}")
run_step >/dev/null 2>&1
assert_equal "the page names 'cancelled' as what the job leaves alone" "cancelled" "${ignored}"
assert_equal "the conclusion the page says changes nothing writes nothing" "" "$(writes)"
check "the page's row for a workflow with no scheduled run is still there" \
  "$(grep -qxF '| No scheduled run at all | Nothing; a fork that just enabled Actions has none yet |' <<<"${doc_section}" && echo 0 || echo 1)"

# How the job finds its issue.
assert_contains "the marker the page quotes is the one an issue is found by" "${doc_text}" \
  "hidden marker in its body (\`${BUILD_MARKER}\`)"
assert_contains "the author the page names is the bot's, without the prefix a list reply has" "${doc_text}" \
  "**and** by its author, \`${BOT#app/}\`,"

# The token. tests/check-invariants.sh compares the policy file to the workflow;
# here the page is compared to both.
doc_perms="$(sed -E "s/.*The job's token is (.*), declared on the job .*/\1/" <<<"${doc_text}" | backticked | LC_ALL=C sort)"
job_perms="$(awk '/^    permissions:$/ { on = 1; next } on && /^      [a-z-]+: / { sub(/^ +/, ""); print; next }
  on && !/^ *#/ { on = 0 }' "${WORKFLOW}" | LC_ALL=C sort)"
policy_perms="$(jq -r '.workflows["auto-issues.yml"].jobs["file-issues"] | to_entries[] | "\(.key): \(.value)"' "${POLICY}" | LC_ALL=C sort)"
check "the page names at least one permission" "$([[ -n "${doc_perms}" ]] && echo 0 || echo 1)"
assert_equal "the token the page gives is the one the job declares" "${job_perms}" "${doc_perms}"
assert_equal "the token the page gives is the one the policy file allows" "${policy_perms}" "${doc_perms}"
assert_contains "the page names the policy file" "${doc_text}" \
  "declared on the job and written down in \`.github/policies/workflow-permissions.json\`"
assert_equal "the token is declared on the job, so the file has no top-level block" "" \
  "$(grep -E '^permissions:' "${WORKFLOW}")"

assert_contains "the page says the job checks out nothing and runs no action" "${doc_text}" \
  "It checks nothing out and runs no action."
assert_equal "the workflow has no checkout and no action" "" \
  "$(grep -E '^[[:space:]]*(- )?uses:' "${WORKFLOW}")"

# What reaches an issue. The fields read from the Actions API are the five the
# page lists, so a field that carries someone's words (a commit title, say)
# cannot be added without the page saying so.
doc_fields="$(sed -nE 's/.*comes from the Actions API \(([^)]*)\).*/\1/p' <<<"${doc_text}" | sed -E \
  -e 's/run id/databaseId/' -e 's/URL/url/' -e 's/start time/createdAt/' -e 's/commit/headSha/' -e 's/,//g' | sorted_words)"
step_fields="$(tr -s ' \n' ' ' <<<"${step_run}" | sed -nE 's/.*gh run list [^)]*--json ([A-Za-z,]+).*/\1/p' | tr ',' ' ' | sorted_words)"
check "the step asks the Actions API for named fields" "$([[ -n "${step_fields}" ]] && echo 0 || echo 1)"
assert_equal "the fields the page lists are the ones the step reads" "${step_fields}" "${doc_fields}"

# And nothing a person wrote is copied: not the open issue's text, not its
# comments, not the run's title.
OUTSIDER="text-an-outsider-typed"
reset_fixtures
stage_run build.yml 111 failure 2
jq --arg t "${OUTSIDER}" '.[0].displayTitle = $t' "${FIXTURES}/runs-build.yml.json" >"${FIXTURES}/titled.json"
mv -- "${FIXTURES}/titled.json" "${FIXTURES}/runs-build.yml.json"
stage_issues < <(issue_entry 47 "${BOT}" "${BUILD_MARKER} ${OUTSIDER}")
stage_view 47 "${BUILD_MARKER} ${OUTSIDER}" "${OUTSIDER}"
run_step >/dev/null 2>&1
check "the comment this case expects was written" "$([[ -n "$(body_of comment)" ]] && echo 0 || echo 1)"
assert_absent "nothing an outsider typed reaches the issue, as the page says" "$(body_of comment)" "${OUTSIDER}"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

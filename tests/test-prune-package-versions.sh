#!/usr/bin/env bash
set -uo pipefail

# Exercise scripts/prune-package-versions.sh against a stubbed `gh`.
#
# The script decides which published container versions stop existing, so what
# is worth testing is not that it can call an API but that it picks exactly the
# right set: the newest N survive, everything older goes, and a version tagged
# `latest` is never in the second group. Every case below is built to be
# discriminating -- where a rule protects something, there is a paired case
# with the protection removed showing the same version being pruned, so a rule
# that quietly stopped working could not pass here.
#
# No network: `gh` is shadowed on PATH and answers from fixtures, and it
# records every DELETE it is asked for so the assertions can name ids rather
# than count calls. jq is real, because the selection logic is the thing under
# test and stubbing jq would test nothing.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/prune-package-versions.sh"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT
STUB_DIR="${WORK_DIR}/bin"
VERSIONS="${WORK_DIR}/versions.ndjson"
DELETED="${WORK_DIR}/deleted"
REQUESTED="${WORK_DIR}/requested"
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

# The stub answers the three calls the script can make and records what it was
# asked for. Anything else is a bug in the script rather than a gap in the
# fixture, so it exits loudly instead of returning nothing.
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
args=("$@")
if [[ "${args[0]:-}" != "api" ]]; then
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 90
fi

method="GET"
path=""
i=1
while ((i < ${#args[@]})); do
  case "${args[i]}" in
    --method)
      i=$((i + 1))
      method="${args[i]}"
      ;;
    --jq)
      i=$((i + 1))
      ;;
    --paginate) ;;
    -*) ;;
    *)
      [[ -z "${path}" ]] && path="${args[i]}"
      ;;
  esac
  i=$((i + 1))
done

printf '%s %s\n' "${method}" "${path}" >>"${GH_STUB_REQUESTED}"

if [[ "${method}" == "DELETE" ]]; then
  version_id="${path##*/}"
  for doomed in ${GH_STUB_FAIL_IDS:-}; do
    if [[ "${doomed}" == "${version_id}" ]]; then
      printf 'HTTP 403: Forbidden (%s)\n' "${path}" >&2
      exit 1
    fi
  done
  printf '%s\n' "${version_id}" >>"${GH_STUB_DELETED}"
  exit 0
fi

if [[ "${path}" != *"/packages/"* ]]; then
  if [[ -n "${GH_STUB_OWNER_TYPE_FAIL:-}" ]]; then
    printf 'HTTP 404: Not Found (%s)\n' "${path}" >&2
    exit 1
  fi
  printf '%s\n' "${GH_STUB_OWNER_TYPE:-User}"
  exit 0
fi

if [[ -n "${GH_STUB_LIST_FAIL:-}" ]]; then
  printf 'HTTP 502: Bad gateway\n' >&2
  exit 1
fi
cat "${GH_STUB_VERSIONS}"
STUB
chmod +x "${STUB_DIR}/gh"

# fixture helpers follow
make_version() {
  jq -cn --argjson id "$1" --arg created "$2" --args \
    '{id: $id, name: ("sha256:" + ($id | tostring)), created_at: $created,
      metadata: {container: {tags: $ARGS.positional}}}' "${@:3}"
}

# Install a fixture and reset what the stub recorded. Versions are written in
# the order the arguments arrive, deliberately not newest-first, so a script
# that trusted the incoming order instead of sorting would fail these cases.
write_versions() {
  : >"${VERSIONS}"
  : >"${DELETED}"
  : >"${REQUESTED}"
  local entry
  for entry in "$@"; do
    printf '%s\n' "${entry}" >>"${VERSIONS}"
  done
}

run_script() {
  PATH="${STUB_DIR}:${PATH}" \
    GH_STUB_VERSIONS="${VERSIONS}" \
    GH_STUB_DELETED="${DELETED}" \
    GH_STUB_REQUESTED="${REQUESTED}" \
    "${BASH}" "${SCRIPT}" "$@" 2>&1
}

# The ids the stub was asked to remove, sorted so an assertion names a set
# rather than an order the script never promised.
pruned_ids() {
  sort -n "${DELETED}" | tr '\n' ' ' | sed -e 's/ $//'
}

requested_paths() {
  tr '\n' '|' <"${REQUESTED}"
}

# Five versions, oldest to newest, listed out of order. Only the newest
# carries `latest`, which is what the repository actually publishes: the tag
# is repointed at the new version on every push.
default_fixture() {
  write_versions \
    "$(make_version 3 2026-01-03T00:00:00Z 20260103)" \
    "$(make_version 5 2026-01-05T00:00:00Z latest latest.20260105 20260105)" \
    "$(make_version 1 2026-01-01T00:00:00Z 20260101)" \
    "$(make_version 4 2026-01-04T00:00:00Z 20260104)" \
    "$(make_version 2 2026-01-02T00:00:00Z 20260102)"
}

BASE_ARGS=(--owner Danathar --owner-type user --package arch-bootc-base)

# --- argument handling ----------------------------------------------------

default_fixture

output="$(run_script --help)"
assert_status "--help exits 0" 0 "$?"
assert_contains "--help explains the exit codes" "${output}" "Exit status:"

output="$(run_script -h)"
assert_status "-h exits 0" 0 "$?"
assert_contains "-h prints the same usage as --help" "${output}" "Usage: prune-package-versions.sh"

output="$(run_script --not-a-flag)"
assert_status "an unknown argument is a usage error" 2 "$?"
assert_contains "an unknown argument names itself" "${output}" "unknown argument --not-a-flag"

output="$(run_script --owner Danathar --min-versions-to-keep 2)"
assert_status "a missing --package is a usage error" 2 "$?"
assert_contains "the missing package is named" "${output}" "--package is required"

output="$(run_script "${BASE_ARGS[@]}")"
assert_status "a missing --min-versions-to-keep is a usage error" 2 "$?"
assert_contains "the missing retention floor is named" "${output}" "--min-versions-to-keep is required"

output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep)"
assert_status "--min-versions-to-keep without a value is a usage error" 2 "$?"

output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep thirty)"
assert_status "a non-numeric retention floor is a usage error" 2 "$?"
assert_contains "a non-numeric floor is reported" "${output}" "must be a non-negative integer"

# A floor of 0 means "keep nothing", which would take out the version `latest`
# points at and break `bootc upgrade` on every installed system. It is the one
# argument value that can do unbounded damage, and an empty variable expanding
# to 0 reaches it far more easily than a person typing it, so it is refused
# rather than obeyed.
default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 0)"
assert_status "a retention floor of 0 is refused" 2 "$?"
assert_contains "the refusal says why" "${output}" "at least 1"
assert_equal "a refused floor removes nothing" "" "$(pruned_ids)"

# --- the retention rule ---------------------------------------------------

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 2)"
assert_status "a package over its floor exits 0" 0 "$?"
assert_equal "everything below the newest two is removed" "1 2 3" "$(pruned_ids)"
assert_contains "the summary counts what went" "${output}" "removed 3 of 3 version(s)"

# The assertion above is the one that shows the script sorts rather than
# trusting the order the API replied in: the fixture lists id 5 second and id 2
# last, so a script that kept "the last two it was handed" would have removed
# 1, 3 and 4 and left the newest version gone.

# The boundary in both directions. A floor equal to the version count must
# remove nothing, and one below it must remove exactly one -- an off-by-one in
# the slice would show up as one of these two and not the other.
default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 5)"
assert_status "a floor equal to the version count exits 0" 0 "$?"
assert_contains "a package inside its floor says so" "${output}" "nothing to prune"
assert_equal "a package inside its floor loses nothing" "" "$(pruned_ids)"

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 4)"
assert_status "a floor one below the count exits 0" 0 "$?"
assert_equal "exactly the oldest version goes" "1" "$(pruned_ids)"

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 99)"
assert_status "a floor above the version count exits 0" 0 "$?"
assert_equal "a floor above the count leaves everything" "" "$(pruned_ids)"

# --- the latest guard -----------------------------------------------------
#
# The retention rule alone is meant to keep `latest` safe, because `latest` is
# repointed at the newest version on every publish. This is the case where that
# stopped being true: `latest` is on the *oldest* version, so the rule would
# take it. The pair below is what makes the guard meaningful rather than
# decorative -- the same fixture with the tag moved elsewhere loses that exact
# version.

write_versions \
  "$(make_version 1 2026-01-01T00:00:00Z latest 20260101)" \
  "$(make_version 2 2026-01-02T00:00:00Z 20260102)" \
  "$(make_version 3 2026-01-03T00:00:00Z 20260103)"
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 1)"
assert_status "a stranded latest still exits 0" 0 "$?"
assert_equal "the version tagged latest survives" "2" "$(pruned_ids)"
assert_contains "the stranded latest is reported, not hidden" "${output}" "KEEPING 1"
assert_contains "the summary counts what the guard held back" "${output}" "1 kept by the latest guard"

write_versions \
  "$(make_version 1 2026-01-01T00:00:00Z 20260101)" \
  "$(make_version 2 2026-01-02T00:00:00Z 20260102)" \
  "$(make_version 3 2026-01-03T00:00:00Z latest 20260103)"
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 1)"
assert_status "the same shape without the tag exits 0" 0 "$?"
assert_equal "without the tag that version is removed like any other" "1 2" "$(pruned_ids)"
assert_absent "nothing is held back when no candidate is tagged latest" "${output}" "KEEPING"

# --- untagged versions ----------------------------------------------------
#
# Cosign publishes a signature as its own version, and an overwritten tag
# leaves the version behind untagged. Both must still be reachable by the
# retention rule, or the package fills up with things nothing can name.

write_versions \
  "$(make_version 1 2026-01-01T00:00:00Z)" \
  "$(make_version 2 2026-01-02T00:00:00Z sha256-abc.sig)" \
  "$(make_version 3 2026-01-03T00:00:00Z latest)"
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 1)"
assert_status "untagged and signature versions exit 0" 0 "$?"
assert_equal "an untagged version and a signature are both removable" "1 2" "$(pruned_ids)"
assert_contains "an untagged version is labelled in the log" "${output}" "(untagged)"

# --- dry run --------------------------------------------------------------

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 2 --dry-run)"
assert_status "a dry run exits 0" 0 "$?"
assert_equal "a dry run removes nothing at all" "" "$(pruned_ids)"
assert_contains "a dry run names the first version it would remove" "${output}" "would remove 1"
assert_contains "a dry run counts the candidates" "${output}" "3 of 3 candidate version(s) would go"

# --- owner scope ----------------------------------------------------------
#
# A user-owned and an organization-owned package sit under different REST
# paths, and the wrong one is a 404 -- which, uncaught, would read as "this
# package has no versions" and prune nothing forever while reporting success.

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 4)"
assert_status "a user-owned package exits 0" 0 "$?"
assert_contains "a user-owned package is read from /users" "$(requested_paths)" "users/Danathar/packages/container/arch-bootc-base/versions"

default_fixture
output="$(run_script --owner Danathar --owner-type organization --package arch-bootc-base --min-versions-to-keep 4)"
assert_status "an organization-owned package exits 0" 0 "$?"
assert_contains "an organization-owned package is read from /orgs" "$(requested_paths)" "orgs/Danathar/packages/container/arch-bootc-base/versions"

default_fixture
output="$(run_script --owner Danathar --package arch-bootc-base --min-versions-to-keep 4)"
assert_status "an omitted owner type is looked up" 0 "$?"
assert_contains "the owner type lookup happens before the version list" "$(requested_paths)" "GET users/Danathar|"

default_fixture
output="$(run_script --owner Danathar --owner-type wombat --package arch-bootc-base --min-versions-to-keep 4)"
assert_status "an unrecognised owner type is an error" 2 "$?"
assert_contains "the unrecognised owner type is named" "${output}" "unknown owner type wombat"
assert_equal "an unrecognised owner type removes nothing" "" "$(pruned_ids)"

# --- the package type -----------------------------------------------------
#
# --package-type supplies the segment between the owner scope and the package
# name in every path this script builds, and it is what the summary reports.
#
# A path that names nothing is already caught: gh exits non-zero on a 404 and
# the list call turns that into exit 2, which the "failed version listing" case
# below pins. The danger is a path that names something ELSE. An ignored
# --package-type leaves the `container` default in place, so
# `--package-type npm --package foo` prunes the CONTAINER package foo where one
# exists -- deleting versions nobody asked to delete, and reporting success
# while doing it.
#
# So the flag is asserted in both directions, paired the way the rest of this
# file pairs its guards. A case that only looked for the requested type would
# still pass against a script that ignored the flag and left `container` in the
# path, because `container` is what the default already puts there.

default_fixture
output="$(run_script "${BASE_ARGS[@]}" --package-type npm --min-versions-to-keep 4)"
assert_status "a non-default package type exits 0" 0 "$?"
assert_contains "the version list is read from the type that was asked for" \
  "$(requested_paths)" "users/Danathar/packages/npm/arch-bootc-base/versions"
assert_absent "the container default is not left in the path" \
  "$(requested_paths)" "/packages/container/"
# The whole rendered line, not just the "(npm)" fragment: the summary is what an
# operator reads to confirm WHICH package the job just pruned, so the owner, the
# package, the type and the count are asserted together. (Taken from the hive
# quality agent's #200, which had the stronger form of this assertion.)
assert_contains "the summary names the type it pruned" "${output}" \
  "Danathar/arch-bootc-base (npm) has 5 version(s)"

# The delete path is built from the same string as the list path, and it is the
# half with consequences: whatever type the list call reached is the type whose
# versions get removed, so an ignored flag deletes from the wrong package rather
# than merely reading from it.
assert_contains "the removal is issued against the same type" \
  "$(requested_paths)" "DELETE users/Danathar/packages/npm/arch-bootc-base/versions/1"
assert_equal "the oldest version is still the one that goes" "1" "$(pruned_ids)"

# The other half of the pair: with the flag absent the default has to be
# `container`, in the path and in the summary both.
default_fixture
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 4)"
assert_status "an omitted package type exits 0" 0 "$?"
assert_contains "an omitted type defaults to container in the path" \
  "$(requested_paths)" "users/Danathar/packages/container/arch-bootc-base/versions"
assert_contains "an omitted type is reported as container" "${output}" "(container)"

# --- where the owner comes from -------------------------------------------
#
# --owner is optional only because the workflow runs with
# GITHUB_REPOSITORY_OWNER set. Two things therefore have to hold, and neither is
# reachable from a case that passes --owner: the fallback has to be consulted
# when the flag is absent, and the guard has to refuse when neither is there.
#
# The guard is the one to be careful with. Without it an unset variable builds
# `users//packages/container/...`; against real GitHub that 404s and the list
# call exits 2, so the guard is not the thing standing between a typo and a
# deletion -- it is what turns a confusing 404 naming an empty owner into
# "pass --owner OWNER" at the point the mistake was made. Asserting that the
# stub was never reached at all is how that distinction is pinned: the run has
# to stop BEFORE the request, not merely fail at it.

# run_script with GITHUB_REPOSITORY_OWNER forced to a known state. An empty
# first argument REMOVES it from the environment rather than setting it empty:
# the guard is about the variable being unset, and CI is the one environment
# where it is always set -- a case that merely declined to set it would quietly
# stop testing the guard the moment it ran there.
run_script_owner_env() {
  local owner_env="$1"
  shift
  local -a with_env=(env)
  if [[ -z "${owner_env}" ]]; then
    with_env+=(-u GITHUB_REPOSITORY_OWNER)
  else
    with_env+=("GITHUB_REPOSITORY_OWNER=${owner_env}")
  fi
  PATH="${STUB_DIR}:${PATH}" \
    GH_STUB_VERSIONS="${VERSIONS}" \
    GH_STUB_DELETED="${DELETED}" \
    GH_STUB_REQUESTED="${REQUESTED}" \
    "${with_env[@]}" "${BASH}" "${SCRIPT}" "$@" 2>&1
}

default_fixture
output="$(run_script_owner_env "" --owner-type user --package arch-bootc-base --min-versions-to-keep 2)"
assert_status "no --owner and no GITHUB_REPOSITORY_OWNER is a usage error" 2 "$?"
assert_contains "the refusal names the variable it looked for" "${output}" "GITHUB_REPOSITORY_OWNER is unset"
assert_equal "an ownerless run makes no API call at all" "" "$(requested_paths)"
assert_equal "an ownerless run removes nothing" "" "$(pruned_ids)"

# The paired case: the same command with the variable set has to work, so the
# guard cannot be satisfied by a script that stopped consulting the environment
# altogether.
default_fixture
output="$(run_script_owner_env env-owner --owner-type user --package arch-bootc-base --min-versions-to-keep 4)"
assert_status "GITHUB_REPOSITORY_OWNER supplies the owner when --owner is absent" 0 "$?"
assert_contains "the environment owner reaches the path" \
  "$(requested_paths)" "users/env-owner/packages/container/arch-bootc-base/versions"
assert_contains "the environment owner reaches the summary" "${output}" "env-owner/arch-bootc-base"

# And --owner still wins when both are present, which is the precedence the
# workflow depends on to prune a package owned by anyone other than the account
# running the job.
default_fixture
output="$(run_script_owner_env env-owner "${BASE_ARGS[@]}" --min-versions-to-keep 4)"
assert_status "--owner alongside the variable exits 0" 0 "$?"
assert_contains "--owner wins over the environment" \
  "$(requested_paths)" "users/Danathar/packages/container/arch-bootc-base/versions"
assert_absent "the environment owner is not consulted when --owner is given" \
  "$(requested_paths)" "env-owner"

# --- API failures ---------------------------------------------------------
#
# Each of these is a way for the job to end up believing the package is empty.
# An empty package is indistinguishable from a healthy one to the retention
# rule -- it simply has nothing to do -- so every one of them has to be an
# error rather than a quiet success.

stub_env() {
  PATH="${STUB_DIR}:${PATH}" \
    GH_STUB_VERSIONS="${VERSIONS}" \
    GH_STUB_DELETED="${DELETED}" \
    GH_STUB_REQUESTED="${REQUESTED}" \
    "$@"
}

default_fixture
output="$(GH_STUB_OWNER_TYPE_FAIL=1 stub_env "${BASH}" "${SCRIPT}" \
  --owner Danathar --package arch-bootc-base --min-versions-to-keep 2 2>&1)"
assert_status "a failed owner-type lookup is an error" 2 "$?"
assert_contains "the owner-type failure explains itself" "${output}" "could not tell whether Danathar is a user or an organization"

default_fixture
output="$(GH_STUB_LIST_FAIL=1 stub_env "${BASH}" "${SCRIPT}" \
  "${BASE_ARGS[@]}" --min-versions-to-keep 2 2>&1)"
assert_status "a failed version listing is an error, not an empty package" 2 "$?"
assert_contains "the listing failure is surfaced" "${output}" "could not list versions of arch-bootc-base"
assert_equal "a failed listing removes nothing" "" "$(pruned_ids)"

# gh exits 0 here, so the parse guard is the only thing left to notice. A
# schema change or a proxy substituting its own body lands exactly here.
write_versions "not a version object"
output="$(run_script "${BASE_ARGS[@]}" --min-versions-to-keep 2)"
assert_status "an unreadable version list is an error" 2 "$?"
assert_contains "the parse failure is surfaced" "${output}" "could not parse the version list"
assert_equal "an unreadable list removes nothing" "" "$(pruned_ids)"

# A failed removal must be loud and must not stop the ones after it: the usual
# cause is the package's Admin-role grant having been dropped, which otherwise
# shows up as a job that quietly stopped pruning months ago.
default_fixture
output="$(GH_STUB_FAIL_IDS="2" stub_env "${BASH}" "${SCRIPT}" \
  "${BASE_ARGS[@]}" --min-versions-to-keep 2 2>&1)"
assert_status "a failed removal exits 1" 1 "$?"
assert_contains "the failure names the version it could not touch" "${output}" "FAILED on 2"
assert_equal "the other versions are still processed" "1 3" "$(pruned_ids)"
assert_contains "the summary counts the failure" "${output}" "1 failure(s)"

# --- ties in the creation timestamp ---------------------------------------
#
# Two versions created in the same second have no natural order, so the
# boundary between kept and pruned would wander between runs. Running the same
# fixture twice is what makes that visible; a single run passes either way.

tie_fixture() {
  write_versions \
    "$(make_version 7 2026-01-02T00:00:00Z 20260102b)" \
    "$(make_version 4 2026-01-02T00:00:00Z 20260102a)" \
    "$(make_version 1 2026-01-01T00:00:00Z 20260101)"
}

tie_fixture
run_script "${BASE_ARGS[@]}" --min-versions-to-keep 1 >/dev/null
first_run="$(pruned_ids)"
tie_fixture
run_script "${BASE_ARGS[@]}" --min-versions-to-keep 1 >/dev/null
second_run="$(pruned_ids)"
assert_equal "a tie in created_at resolves the same way every run" "${first_run}" "${second_run}"
assert_equal "the tie is broken toward the higher id" "1 4" "${first_run}"

# --- missing tools --------------------------------------------------------

BARE_DIR="${WORK_DIR}/bare"
mkdir -p "${BARE_DIR}"
ln -sf "$(command -v jq)" "${BARE_DIR}/jq"
output="$(PATH="${BARE_DIR}" "${BASH}" "${SCRIPT}" "${BASE_ARGS[@]}" --min-versions-to-keep 2 2>&1)"
assert_status "a missing gh is a clear error" 2 "$?"
assert_contains "the missing gh error points somewhere useful" "${output}" "cli.github.com"

output="$(PATH="${STUB_DIR}" "${BASH}" "${SCRIPT}" "${BASE_ARGS[@]}" --min-versions-to-keep 2 2>&1)"
assert_status "a missing jq is a clear error" 2 "$?"
assert_contains "the missing jq error points somewhere useful" "${output}" "jqlang.github.io"

# --- the workflow step that drives this script ----------------------------
#
# Everything above proves the script deletes the right versions when it is
# called with the right arguments. Nothing above proves CI calls it with those
# arguments, and the only caller is `build.yml`'s `cleanup_packages` job: two
# `run:` bodies that no test executed. A prune job that names the wrong package
# is not a loud failure -- `gh` 404s, the script turns that into "could not
# list versions", and the job fails in a way that reads like the missing Admin
# grant documented in docs/ci-cd.md. A prune job that passes the wrong
# retention is worse: it succeeds, and removes versions nobody asked to remove.
#
# So the bodies are lifted out of the workflow and run here, against the same
# stubbed `gh` the cases above use, with the real script in between. The lift
# is by step name and refuses to proceed on an empty extraction, so renaming or
# reindenting a step fails these cases rather than silently covering nothing.
#
# The step bodies are also asserted to contain no `${{ }}` expression. A body
# that grows one stops being runnable as plain shell, and this file has to be
# taught how to resolve it rather than quietly testing something the runner
# would never execute.
#
# The tests live in this file because the ShellCheck lists in build.yml and the
# Justfile name every shell file explicitly, so a new test file is a workflow
# edit as well; tests/check-invariants.sh asserts both lists. The subject is
# the same either way: which versions of which package stop existing.
#
# These cases add nothing to the coverage floors. The workflow reaches the
# script by a relative path, so xtrace records those lines under
# `./scripts/...` and tests/check-coverage.sh only counts lines whose recorded
# path is under the repository root. The floor for the script is unchanged
# because the lines it counts were already reached by the cases above.

BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
PRUNE_JOB="cleanup_packages"
PREPARE_STEP="Prepare environment"
# Single-quoted: the step name carries a workflow expression verbatim.
# shellcheck disable=SC2016
DELETE_STEP='Delete old ${{ matrix.flavor }} package versions'

# Print the `run:` block of the named step of the named job, dedented to
# column 0. Jobs sit at two columns, steps at six, `run: |` at eight and its
# body at ten, which is the layout the whole file uses; anything shallower ends
# the block. The job has to be named because step names repeat across jobs:
# `build_push` has a `Prepare environment` step of its own, and matching on the
# step name alone silently concatenates both bodies.
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

# Print one key from the named step's `env:` block, unexpanded. What a step
# hands its command through the environment decides as much as the body does.
workflow_step_env() {
  local workflow="$1" job="$2" step="$3" key="$4"
  awk -v want_job="${job}" -v want="${step}" -v key="${key}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
      in_env = 0
    }
    /^      - name: / { current = substr($0, 15); in_env = 0; next }
    current_job == want_job && current == want && /^        env:$/ { in_env = 1; next }
    in_env && substr($0, 1, 10) != "          " { in_env = 0 }
    in_env && $0 ~ ("^          " key ": ") { print substr($0, length(key) + 13); exit }
  ' "${workflow}"
}

assert_extracted() {
  local description="$1" value="$2"
  if [[ -n "${value}" ]]; then
    check "${description}" 0
  else
    check "${description}" 1 "nothing was extracted; the step was renamed, moved or reindented"
  fi
}

prepare_run="$(workflow_step_run "${BUILD_WORKFLOW}" "${PRUNE_JOB}" "${PREPARE_STEP}")"
assert_extracted "the prepare step's body is still where this file looks for it" "${prepare_run}"
# shellcheck disable=SC2016
assert_absent "the prepare step's body is plain shell" "${prepare_run}" '${{'

delete_run="$(workflow_step_run "${BUILD_WORKFLOW}" "${PRUNE_JOB}" "${DELETE_STEP}")"
assert_extracted "the prune step's body is still where this file looks for it" "${delete_run}"
# shellcheck disable=SC2016
assert_absent "the prune step's body is plain shell" "${delete_run}" '${{'

# The package name is composed in the step's environment, not in its body, so
# it is pinned where it is written. `env.IMAGE_NAME` is what the prepare step
# below produces, which is what ties the two steps together.
# shellcheck disable=SC2016
assert_equal "the pruned package is the lowercased image name plus the flavor" \
  '${{ env.IMAGE_NAME }}-${{ matrix.flavor }}' \
  "$(workflow_step_env "${BUILD_WORKFLOW}" "${PRUNE_JOB}" "${DELETE_STEP}" PACKAGE_NAME)"

# `Arch-BootC` rather than the repository's real spelling: GHCR package names
# are lowercase, so a body that stopped lowercasing would still pass against an
# already-lowercase name while pointing the prune at a package that 404s.
GITHUB_ENV_FILE="${WORK_DIR}/github-env"
: >"${GITHUB_ENV_FILE}"
output="$(REPO_NAME="Arch-BootC" GITHUB_ENV="${GITHUB_ENV_FILE}" "${BASH}" -c "${prepare_run}" 2>&1)"
assert_status "the prepare step exits 0" 0 "$?"
assert_equal "the prepare step lowercases the repository name into IMAGE_NAME" \
  "IMAGE_NAME=arch-bootc" "$(cat "${GITHUB_ENV_FILE}")"

# 31 versions against the retention floor the workflow passes: exactly one
# version is outside it, so a changed or dropped `--min-versions-to-keep 30`
# cannot pass here. The newest carries `latest`, as every published package
# does.
workflow_fixture() {
  local -a entries=()
  local id
  for ((id = 1; id <= 31; id++)); do
    if ((id == 31)); then
      entries+=("$(make_version "${id}" "$(printf '2026-01-01T00:%02d:00Z' "${id}")" latest)")
    else
      entries+=("$(make_version "${id}" "$(printf '2026-01-01T00:%02d:00Z' "${id}")")")
    fi
  done
  write_versions "${entries[@]}"
}

# The workflow runs the step from the checkout root and reaches the script by a
# relative path, so the body is run from there too rather than from wherever
# this file happened to be invoked.
run_prune_step() {
  local owner="$1" owner_type="$2" package="$3"
  (
    cd -- "${REPO_ROOT}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      GH_STUB_VERSIONS="${VERSIONS}" \
      GH_STUB_DELETED="${DELETED}" \
      GH_STUB_REQUESTED="${REQUESTED}" \
      GH_TOKEN=stub-token \
      OWNER="${owner}" \
      OWNER_TYPE="${owner_type}" \
      PACKAGE_NAME="${package}" \
      "${BASH}" -c "${delete_run}" 2>&1
  )
}

# Composed the way the workflow composes it, from what the prepare step just
# wrote plus the matrix flavor, so the two steps are exercised as one seam.
image_name="$(sed -n 's/^IMAGE_NAME=//p' "${GITHUB_ENV_FILE}")"

workflow_fixture
output="$(run_prune_step Danathar User "${image_name}-kde")"
assert_status "the prune step exits 0 for a user-owned package" 0 "$?"
assert_contains "the step prunes the flavor's package under the user scope" \
  "$(requested_paths)" "GET users/Danathar/packages/container/arch-bootc-kde/versions?per_page=100"
assert_contains "the step keeps the newest 30 versions" \
  "${output}" "has 31 version(s); keeping the newest 30"
assert_equal "only the version outside the retention floor is removed" "1" "$(pruned_ids)"

# `--owner-type` is forwarded from the event payload rather than left to the
# script's own lookup. Dropping the flag is not a visible failure -- the script
# resolves the type itself and reaches the same path -- so the discriminating
# assertion is the absence of that extra call.
assert_absent "the owner type comes from the event, not an extra API call" \
  "$(requested_paths)" "GET users/Danathar|"

# The same step against an organization-owned package. The REST path differs by
# owner scope and a wrong scope is a 404, which this script reports as a failed
# listing rather than an empty package.
workflow_fixture
output="$(run_prune_step Danathar Organization "${image_name}-xfce")"
assert_status "the prune step exits 0 for an organization-owned package" 0 "$?"
assert_contains "an organization-owned package is pruned under the org scope" \
  "$(requested_paths)" "GET orgs/Danathar/packages/container/arch-bootc-xfce/versions?per_page=100"
assert_equal "the retention floor is the same under the org scope" "1" "$(pruned_ids)"

# A package already inside its retention budget: the step must not delete
# anything, and must still exit 0 so the job does not fail on a quiet day.
write_versions \
  "$(make_version 1 2026-01-01T00:01:00Z)" \
  "$(make_version 2 2026-01-01T00:02:00Z latest)"
output="$(run_prune_step Danathar User "${image_name}-base")"
assert_status "a package within the retention floor exits 0" 0 "$?"
assert_contains "a package within the retention floor prunes nothing" "${output}" "nothing to prune"
assert_equal "no version is removed" "" "$(pruned_ids)"

# --- the other half of the seam: the name the build job publishes ---------
#
# Everything above proves the prune job removes the right versions of whatever
# package it is pointed at. Which package that is gets decided in two
# `Prepare environment` steps, one per job, and only `cleanup_packages`' was
# run here. `build_push`'s body composes the published name -- lowercased image
# name plus the matrix flavor -- and `cleanup_packages`' body says in a comment
# to "keep this in sync with the build job's own IMAGE_NAME handling above".
# Nothing checked that sync. The two bodies could drift apart with both jobs
# still green: the build would publish under one name and the prune would run
# against another, which `gh` answers with a 404 that this script reports as
# "could not list versions" -- indistinguishable from the missing Admin grant
# documented in docs/ci-cd.md, while the real packages keep growing forever.
#
# So the build job's body is executed here too, against the same mixed-case
# repository name, and the two sides are compared. The comparison is the point;
# the per-flavor assertions are there so a failure names which side moved.

BUILD_JOB="build_push"
build_prepare_run="$(workflow_step_run "${BUILD_WORKFLOW}" "${BUILD_JOB}" "${PREPARE_STEP}")"
assert_extracted "the build job's prepare body is still where this file looks for it" \
  "${build_prepare_run}"

# Unlike the prune job's body, this one is not plain shell: it pastes the
# matrix flavor in as text. Pinning the exact set of expressions is what keeps
# the substitution below honest -- a body that grew a second expression would
# otherwise be run here with that expression left unresolved, proving something
# about a string the runner never executes.
# The literals below are workflow expressions, so they must stay unexpanded.
# shellcheck disable=SC2016
flavor_expr='${{ matrix.flavor }}'
# shellcheck disable=SC2016
build_prepare_expressions="$(printf '%s\n' "${build_prepare_run}" | grep -o '\${{[^}]*}}' | sort -u)"
assert_equal "the matrix flavor is the only expression pasted into the build job's prepare body" \
  "${flavor_expr}" "${build_prepare_expressions}"

# Print every line of the named job, so the matrix can be read from the job
# that declares it rather than from the first `flavor:` in the file --
# cleanup_packages declares one of its own.
workflow_job_block() {
  local workflow="$1" job="$2"
  awk -v want="${job}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      in_job = (substr($0, 3, length($0) - 3) == want)
    }
    in_job { print }
  ' "${workflow}"
}

build_flavors="$(workflow_job_block "${BUILD_WORKFLOW}" "${BUILD_JOB}" |
  sed -n 's/^ *flavor: \[\(.*\)\]$/\1/p' | tr ',' ' ')"
assert_extracted "the build job still declares a flavor matrix" "${build_flavors}"
read -ra build_flavor_list <<<"${build_flavors}"

# The name the prune job is aimed at is composed in the step's environment from
# what its own prepare body wrote, so it is resolved the way Actions resolves
# it: the `env.IMAGE_NAME` this file already captured, plus the matrix flavor.
package_template="$(workflow_step_env "${BUILD_WORKFLOW}" "${PRUNE_JOB}" "${DELETE_STEP}" PACKAGE_NAME)"
# shellcheck disable=SC2016
image_name_expr='${{ env.IMAGE_NAME }}'

BUILD_ENV_FILE="${WORK_DIR}/build-github-env"
cache_images=""
published_refs=""
first_built_name=""
for flavor in "${build_flavor_list[@]}"; do
  : >"${BUILD_ENV_FILE}"
  # `Arch-BootC` and a mixed-case registry owner for the same reason the prune
  # body is given one above: both sides lowercase, and against an
  # already-lowercase name a side that stopped lowercasing would still agree
  # with the other one.
  IMAGE_REGISTRY="ghcr.io/Danathar" IMAGE_NAME="Arch-BootC" GITHUB_ENV="${BUILD_ENV_FILE}" \
    "${BASH}" -c "${build_prepare_run//"${flavor_expr}"/${flavor}}" >/dev/null 2>&1
  assert_status "the build job's prepare step exits 0 for ${flavor}" 0 "$?"

  built_registry="$(sed -n 's/^IMAGE_REGISTRY=//p' "${BUILD_ENV_FILE}")"
  built_name="$(sed -n 's/^IMAGE_NAME=//p' "${BUILD_ENV_FILE}")"
  built_cache="$(sed -n 's/^CACHE_IMAGE=//p' "${BUILD_ENV_FILE}")"

  assert_equal "the build job publishes the lowercased name plus the ${flavor} flavor" \
    "arch-bootc-${flavor}" "${built_name}"
  assert_equal "the registry the ${flavor} build pushes to is lowercased" \
    "ghcr.io/danathar" "${built_registry}"

  # The seam itself: what one job publishes is what the other job prunes.
  pruned_package="${package_template//"${image_name_expr}"/${image_name}}"
  pruned_package="${pruned_package//"${flavor_expr}"/${flavor}}"
  # shellcheck disable=SC2016
  assert_absent "the pruned ${flavor} package name resolves to plain text" "${pruned_package}" '${{'
  assert_equal "the package the prune job removes versions from is the one the build job published (${flavor})" \
    "${built_name}" "${pruned_package}"

  cache_images="${cache_images}${built_cache}"$'\n'
  published_refs="${published_refs}${built_registry}/${built_name}"$'\n'
  [[ -n "${first_built_name}" ]] || first_built_name="${built_name}"
done

# Every later step in the job reads this body's output through `env.`, so an
# added or renamed variable here is a variable nothing reads, and a dropped one
# is an empty image reference. Three, by these names, is the contract.
assert_equal "the build job's prepare step writes exactly the variables its later steps read" \
  "IMAGE_REGISTRY IMAGE_NAME CACHE_IMAGE" \
  "$(cut -d= -f1 "${BUILD_ENV_FILE}" | tr '\n' ' ' | sed 's/ $//')"

# One shared cache repository for all three flavors is the documented intent of
# the body's own comment. Per-flavor cache repos would still build, just with
# each flavor's cache missing the other two's base-core layers.
assert_equal "every flavor shares one layer-cache repository" \
  "ghcr.io/danathar/buildcache" "$(printf '%s' "${cache_images}" | sort -u | tr -d '\n')"

# And that repository must not be one of the shipped images: the cache push is
# unconditional on publish runs, so a CACHE_IMAGE that collided with a
# published reference would overwrite a shipped image with cache blobs.
if printf '%s' "${published_refs}" | grep -qxF "ghcr.io/danathar/buildcache"; then
  check "the layer-cache repository is not one of the published images" 1 \
    "CACHE_IMAGE resolves to a reference this job also publishes"
else
  check "the layer-cache repository is not one of the published images" 0
fi

# The readers, pinned where they are written. The variables above are only
# load-bearing because these steps name them; a renamed variable on either side
# is silent otherwise.
build_workflow_text="$(cat "${BUILD_WORKFLOW}")"
# shellcheck disable=SC2016
assert_contains "a buildah step pulls from the cache repository this body writes" \
  "${build_workflow_text}" '--cache-from ${{ env.CACHE_IMAGE }}'
# shellcheck disable=SC2016
assert_contains "a buildah step pushes to the cache repository this body writes" \
  "${build_workflow_text}" '--cache-to ${{ env.CACHE_IMAGE }}'
# shellcheck disable=SC2016
assert_contains "the image buildah builds is the name this body writes" \
  "${build_workflow_text}" 'image: ${{ env.IMAGE_NAME }}'

# End to end, with nothing invented in between: the name the build body
# produced is handed to the prune body, which reaches the real script, which
# asks for that package over the stubbed REST API.
workflow_fixture
output="$(run_prune_step Danathar User "${first_built_name}")"
assert_status "the prune step exits 0 against the name the build job publishes" 0 "$?"
assert_contains "the pruned REST path names the package the build job publishes" \
  "$(requested_paths)" \
  "GET users/Danathar/packages/container/${first_built_name}/versions?per_page=100"
assert_equal "the retention floor still holds for the published package" "1" "$(pruned_ids)"

# --- the other derived value the build job computes: the cache bust --------
#
# `Prepare environment` above decides *what* is published. `Get current date`
# decides *how fresh what is published is*, and no test ran its body. It writes
# two step outputs:
#
#   date -> org.opencontainers.image.created, the ArtifactHub timestamp
#   ymd  -> PACMAN_CACHE_BUST, the Containerfile build-arg whose only job is to
#           change once per calendar day so the remote buildah layer cache
#           misses from the package-install step onward
#
# Both failure directions are silent. A `ymd` that stopped changing daily --
# coarser granularity, a dropped `-u` at the wrong hour, a renamed output that
# Actions expands to the empty string -- leaves the cache-bust line constant,
# so every build reuses a cached `pacman -Syu` against Arch's live repositories
# and the image ships a package set nobody chose, on a green run. A `ymd` that
# changed more often than daily is the opposite and just as quiet: every run
# misses the cache and rebuilds from the package install down. A malformed
# `date` leaves the published image carrying a creation timestamp ArtifactHub
# cannot read, which nothing in this repository would ever notice.
#
# So the body is executed here, and both of its outputs are joined to the
# expressions that read them. The runtime cases drive it through a `date` stub
# on PATH that answers from a fixed epoch, because the properties worth
# asserting -- same UTC day gives the same bust, one second later the next day
# gives a different one -- cannot be observed against the real clock.

DATE_STEP="Get current date"
date_run="$(workflow_step_run "${BUILD_WORKFLOW}" "${BUILD_JOB}" "${DATE_STEP}")"
assert_extracted "the date step's body is still where this file looks for it" "${date_run}"
# shellcheck disable=SC2016
assert_absent "the date step's body is plain shell" "${date_run}" '${{'

# Print one scalar key declared directly on the named step, such as `id:`.
# The expressions that read this step name it by id, not by step name, so a
# renamed id breaks every reader while the step itself still looks right.
workflow_step_key() {
  local workflow="$1" job="$2" step="$3" key="$4"
  awk -v want_job="${job}" -v want="${step}" -v key="${key}" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ {
      current_job = substr($0, 3, length($0) - 3)
    }
    /^      - name: / { current = substr($0, 15); next }
    current_job == want_job && current == want && $0 ~ ("^        " key ": ") {
      print substr($0, length(key) + 11); exit
    }
  ' "${workflow}"
}

assert_equal "the date step still declares the id its readers name" \
  "date" "$(workflow_step_key "${BUILD_WORKFLOW}" "${BUILD_JOB}" "${DATE_STEP}" id)"

# --- the body, run against a fixed clock -----------------------------------

DATE_STUB_DIR="${WORK_DIR}/date-stubs"
DATE_ARGS="${WORK_DIR}/date-args"
DATE_OUTPUT_FILE="${WORK_DIR}/date-github-output"
mkdir -p "${DATE_STUB_DIR}"

# Resolved before the stub dir goes on PATH, so the stub can reach the real
# program without recursing into itself.
REAL_DATE="$(command -v date)"

# The stub records the whole argv and then hands it to the real `date`
# unchanged, with the instant pinned. Passing the arguments through rather than
# reimplementing them is what keeps a dropped `-u` or a changed format string
# observable in the output as well as in the recording.
cat >"${DATE_STUB_DIR}/date" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${DATE_ARGS_FILE}"
exec ${REAL_DATE} "\$@" --date "@\${FAKE_EPOCH}"
EOF
chmod +x "${DATE_STUB_DIR}/date"

# Runs the step body at the given epoch, in the given TZ, and leaves its
# outputs in DATE_OUTPUT_FILE.
run_date_step() {
  local epoch="$1" tz="${2:-UTC}"
  : >"${DATE_OUTPUT_FILE}"
  : >"${DATE_ARGS}"
  PATH="${DATE_STUB_DIR}:${PATH}" \
    DATE_ARGS_FILE="${DATE_ARGS}" \
    FAKE_EPOCH="${epoch}" \
    TZ="${tz}" \
    GITHUB_OUTPUT="${DATE_OUTPUT_FILE}" \
    "${BASH}" -c "${date_run}" 2>&1
}

date_output() { sed -n "s/^$1=//p" "${DATE_OUTPUT_FILE}"; }

# 2026-01-01T23:59:59Z. One second before a UTC day boundary, which is where
# every interesting property of this body lives.
NEW_YEARS_EVE=1767311999

output="$(run_date_step "${NEW_YEARS_EVE}")"
assert_status "the date step exits 0" 0 "$?"
assert_equal "the date step prints nothing to the log" "" "${output}"

# Exactly two outputs, by these names: the expressions below read them by name,
# so an added output is one nothing reads and a renamed one is an empty string
# pasted into a label and a build-arg.
assert_equal "the date step writes exactly the outputs its readers name" \
  "date ymd" \
  "$(cut -d= -f1 "${DATE_OUTPUT_FILE}" | tr '\n' ' ' | sed 's/ $//')"

# `-u` on both calls, and the two format strings. The ArtifactHub form the
# body's own comment cites is `%Y-%m-%dT%H:%M:%SZ`; the literal `Z` is only
# truthful because of `-u`.
assert_equal "both timestamps are asked of UTC in the documented formats" \
  "-u +%Y-%m-%dT%H:%M:%SZ
-u +%Y%m%d" \
  "$(cat "${DATE_ARGS}")"

assert_equal "the created timestamp is the ArtifactHub form at that instant" \
  "2026-01-01T23:59:59Z" "$(date_output date)"
assert_equal "the cache bust is that instant's UTC day" \
  "20260101" "$(date_output ymd)"

# The two outputs are read by different consumers and computed by separate
# `date` calls, so nothing but this makes them describe the same day.
assert_equal "the cache bust is the day part of the created timestamp" \
  "$(date_output ymd)" "$(date_output date | cut -dT -f1 | tr -d -)"

# A runner in a non-UTC zone must not change what is built. `XXX-14` is a
# POSIX TZ 14 hours ahead of UTC, so at the instant above the local date is
# already 2026-01-02: a body that dropped `-u` would bust the cache a day early
# and stamp a creation time that never happened in UTC.
run_date_step "${NEW_YEARS_EVE}" "XXX-14" >/dev/null
assert_equal "a runner ahead of UTC still busts on the UTC day" \
  "20260101" "$(date_output ymd)"
assert_equal "a runner ahead of UTC still stamps a UTC creation time" \
  "2026-01-01T23:59:59Z" "$(date_output date)"

# Granularity, from both sides. These are the two ways the bust stops being
# worth passing at all, and neither shows up as a failed run.
run_date_step "$((NEW_YEARS_EVE - 86398))" >/dev/null
assert_equal "an earlier instant on the same UTC day busts identically" \
  "20260101" "$(date_output ymd)"

run_date_step "$((NEW_YEARS_EVE + 1))" >/dev/null
assert_equal "the first instant of the next UTC day busts differently" \
  "20260102" "$(date_output ymd)"

# --- the readers, joined to what the body writes ---------------------------
#
# Everything above proves the body computes two correct values. What makes them
# load-bearing is the set of expressions that read them, and Actions expands a
# reference to a missing step output to the empty string rather than failing.

date_readers="$(grep -o 'steps\.date\.outputs\.[A-Za-z0-9_-]*' "${BUILD_WORKFLOW}" |
  sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_equal "every output this body writes is read, and nothing reads an output it does not write" \
  "date ymd" "${date_readers}"

# shellcheck disable=SC2016
assert_contains "the created label is the timestamp this body computed" \
  "${build_workflow_text}" \
  'org.opencontainers.image.created=${{ steps.date.outputs.date }}'

# Both buildah invocations, not one. `Populate build cache` re-runs the same
# build to push cache blobs and is expected to hit the local layer cache the
# build above just filled; handed a different cache bust it would instead
# rebuild everything from the package install down, and then push that as the
# cache the next run pulls.
# shellcheck disable=SC2016
cache_bust_arg='PACMAN_CACHE_BUST=${{ steps.date.outputs.ymd }}'
assert_equal "both buildah steps pass the same cache bust" \
  "2" "$(grep -cF "            ${cache_bust_arg}" "${BUILD_WORKFLOW}")"

buildah_steps="$(grep -c '^        uses: redhat-actions/buildah-build@' "${BUILD_WORKFLOW}")"
assert_equal "the two steps that pass it are every buildah build in the job" \
  "${buildah_steps}" "2"

# And the far end: a build-arg buildah is handed for an ARG the Containerfile
# never declares is discarded, which is exactly the silent no-bust outcome.
# shellcheck disable=SC2016
cache_bust_name="$(printf '%s' "${cache_bust_arg}" | cut -d= -f1)"
assert_status "the Containerfile declares the build-arg this body feeds" 0 \
  "$(
    grep -qE "^ARG ${cache_bust_name}=" "${REPO_ROOT}/Containerfile"
    printf '%s' "$?"
  )"
printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

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
# Getting it wrong is not an error: the list call 404s, a 404 on the version
# list is indistinguishable from a package that has no versions, and the job
# reports success having removed nothing.
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
assert_contains "the summary names the type it pruned" "${output}" "(npm)"

# The delete path is built from the same string as the list path, and it is the
# half with consequences: a DELETE against the wrong type is another 404 the
# script would report as a removal that did not happen.
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
# The guard is the one to be careful with. Without it an unset variable does not
# stop the run -- it builds `users//packages/container/...` and then issues a
# DELETE under that empty owner for every version past the retention floor. So
# what is asserted is not only the status and the message but that the stub was
# never reached at all.

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

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

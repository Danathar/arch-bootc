#!/usr/bin/env bash
set -uo pipefail

# Tune the per-script coverage floors in .coverage-thresholds.json against what
# the suite actually reaches, following the policy in
# .github/auto-qa-tuning.json.
#
# The problem this solves is small and real. Floors are calibrated by hand, and
# the calibration rule is not obvious: traced-line counts are Bash-version
# sensitive, so a floor has to be the LOWEST count across every supported
# interpreter, not the one the machine in front of you happens to produce. That
# rule lived only in prose, which means it held only as long as everyone
# remembered it. Here it is mechanical: pass each interpreter with --bash and
# the minimum is what gets written.
#
# Raising is automatic; lowering never is. The asymmetry is the point. The
# evidence for raising a floor is complete -- the suite demonstrably reached
# that many lines. The evidence for lowering one is an absence, and a lost test
# and a Bash-version trace difference look identical from the count alone. Only
# assertion totals distinguish them, so lowering stays a human decision with a
# stated reason.
#
# This is run by a person. It writes one local file and never commits, pushes,
# or opens anything -- a bot that adjusted the quality gate on its own schedule
# would be automating precisely the decision the gate exists to force.

usage() {
  cat <<'USAGE'
Usage: tune-coverage.sh [--apply] [--bash PATH]...

Compare the coverage floors against what the suite reaches, and report which
could be raised. With --apply, raise them in place.

  --apply        Rewrite .coverage-thresholds.json. Raises only, never lowers.
                 Refused unless every Bash version in the policy's
                 supportedBash list has been observed.
  --bash PATH    An interpreter to observe under. Repeatable. Defaults to the
                 one running this script. The floor written is the MINIMUM
                 across all of them.

Exit status: 0 floors are correct or were raised, 1 a floor is above what the
suite reaches (a regression, or a floor calibrated on the wrong interpreter),
2 usage or environment error.
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd -- "${REPO_ROOT}" || exit 2

POLICY=".github/auto-qa-tuning.json"
THRESHOLDS=".coverage-thresholds.json"
REPORT_COMMAND="./tests/check-coverage.sh"

apply=0
interpreters=()

while (($# > 0)); do
  case "$1" in
    --apply)
      apply=1
      shift
      ;;
    --bash)
      if (($# < 2)); then
        echo "error: --bash needs a path" >&2
        exit 2
      fi
      interpreters+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ((${#interpreters[@]} == 0)); then
  interpreters=("${BASH}")
fi

for file in "${POLICY}" "${THRESHOLDS}"; do
  if [[ ! -f "${file}" ]]; then
    printf 'error: %s is missing\n' "${file}" >&2
    exit 2
  fi
done

# Read the two policy knobs that change behavior. Everything else in the policy
# file is rationale, which belongs there rather than only in a commit message.
read_policy_number() {
  local key="$1" fallback="$2" value
  value="$(sed -nE "s/^[[:space:]]*\"${key}\":[[:space:]]*([0-9]+),?[[:space:]]*$/\1/p" "${POLICY}" | head -1)"
  printf '%s' "${value:-${fallback}}"
}

headroom="$(read_policy_number headroom 0)"
min_observations="$(read_policy_number minObservations 1)"

# The supported Bash versions, as major.minor. --apply is refused unless every
# one of them has been observed -- see the check after the observation loop.
supported_bash=()
while IFS= read -r supported; do
  [[ -n "${supported}" ]] && supported_bash+=("${supported}")
done < <(
  sed -nE 's/.*"supportedBash":[[:space:]]*\[([^]]*)\].*/\1/p' "${POLICY}" |
    tr ',' '\n' | sed -nE 's/.*"([0-9]+\.[0-9]+)".*/\1/p'
)

if ! grep -q '"direction": "raise-only"' "${POLICY}"; then
  echo "error: this script only implements the raise-only policy" >&2
  exit 2
fi

declare -A observed=()
observed_versions=()
observations=0

for interpreter in "${interpreters[@]}"; do
  if [[ ! -x "${interpreter}" ]]; then
    printf 'error: %s is not executable\n' "${interpreter}" >&2
    exit 2
  fi
  # Single-quoted on purpose: BASH_VERSION must be expanded by the interpreter
  # being observed, not by this one.
  # shellcheck disable=SC2016
  version="$("${interpreter}" -c 'echo "${BASH_VERSION}"')"
  observed_versions+=("${version%%.*}.$(cut -d. -f2 <<<"${version}")")
  printf '==> observing under bash %s (%s)\n' "${version}" "${interpreter}"

  # check-coverage.sh exits non-zero when a floor fails, which is a result to
  # read rather than an error to abort on -- a floor being too high is exactly
  # one of the cases this script exists to report.
  report="$(BASH="${interpreter}" "${interpreter}" "${REPORT_COMMAND}" 2>&1)"

  found=0
  # IFS=' ' and not IFS=, because the sed above emits "path count" as two
  # space-separated fields; an empty IFS would put the whole line in the first
  # variable and leave the count empty, which reads as "not observed".
  while IFS=' ' read -r source_path count; do
    [[ -n "${source_path}" ]] || continue
    found=$((found + 1))
    current="${observed[${source_path}]:-}"
    if [[ -z "${current}" ]] || ((count < current)); then
      observed["${source_path}"]="${count}"
    fi
  done < <(
    printf '%s\n' "${report}" |
      sed -nE 's/^coverage: (PASS|FAIL) ([^[:space:]]+)[[:space:]]+([0-9]+)\/[0-9]+ lines.*/\2 \3/p'
  )

  if ((found == 0)); then
    printf 'error: no coverage lines parsed from %s under %s\n' "${REPORT_COMMAND}" "${interpreter}" >&2
    printf '%s\n' "${report}" >&2
    exit 2
  fi
  observations=$((observations + 1))
done

if ((observations < min_observations)); then
  printf 'error: policy requires %d observation(s), got %d\n' "${min_observations}" "${observations}" >&2
  exit 2
fi

# Writing a floor from a single interpreter is the exact mistake this script
# exists to prevent. Bash 5.2 reaches 44 lines of ostree-pkg-diff where 5.3
# reaches 43; raising the floor to 44 from a 5.2 host alone would leave every
# 5.3 environment failing a gate that nothing is actually wrong with.
#
# So --apply is refused unless every supported version has been observed.
# Reporting is not gated the same way -- it changes nothing, and being able to
# see where the floors stand from whatever interpreter is to hand is useful.
if ((apply)) && ((${#supported_bash[@]} > 0)); then
  missing=()
  for supported in "${supported_bash[@]}"; do
    seen=0
    for actual in "${observed_versions[@]}"; do
      [[ "${actual}" == "${supported}" ]] && seen=1
    done
    ((seen)) || missing+=("${supported}")
  done
  if ((${#missing[@]} > 0)); then
    printf 'error: --apply needs an observation from every supported Bash version.\n' >&2
    printf '       missing: %s\n' "${missing[*]}" >&2
    printf '       observed: %s\n' "${observed_versions[*]}" >&2
    printf '       Pass each with --bash, or run without --apply to report only.\n' >&2
    printf '       Floors are the lowest count across supported versions; writing one\n' >&2
    printf '       from a single interpreter is what this rule exists to prevent.\n' >&2
    exit 2
  fi
fi

printf '\ncoverage floors, minimum across %d observation(s), headroom %d:\n\n' \
  "${observations}" "${headroom}"

raises=()
regressions=0

while IFS=' ' read -r source_path floor; do
  [[ -n "${source_path}" ]] || continue
  reached="${observed[${source_path}]:-}"
  if [[ -z "${reached}" ]]; then
    printf '  %-50s floor %3d  NOT OBSERVED\n' "${source_path}" "${floor}" >&2
    regressions=$((regressions + 1))
    continue
  fi

  target=$((reached - headroom))
  ((target < 0)) && target=0

  if ((reached < floor)); then
    printf '  %-50s floor %3d  reached %3d  BELOW FLOOR\n' "${source_path}" "${floor}" "${reached}" >&2
    regressions=$((regressions + 1))
  elif ((target > floor)); then
    printf '  %-50s floor %3d  reached %3d  can raise to %d\n' "${source_path}" "${floor}" "${reached}" "${target}"
    raises+=("${source_path} ${target}")
  else
    printf '  %-50s floor %3d  reached %3d  at floor\n' "${source_path}" "${floor}" "${reached}"
  fi
done < <(
  sed -nE 's/^[[:space:]]*"([^"]+)":[[:space:]]*([0-9]+),?$/\1 \2/p' "${THRESHOLDS}"
)

echo

if ((regressions > 0)); then
  cat >&2 <<'EXPLAIN'
A floor above what the suite reaches is not something this script will "fix".
Two different things produce it and the count alone cannot tell them apart: a
test stopped exercising the code, or this interpreter traces it differently
from the one the floor was set on. Compare the `1..N` assertion totals between
environments first -- a lower total is unambiguously a lost test. See
docs/ci-cd.md.
EXPLAIN
  exit 1
fi

if ((${#raises[@]} == 0)); then
  echo "nothing to tune: every floor is already at what the suite reaches."
  exit 0
fi

if ((apply == 0)); then
  printf '%d floor(s) could be raised. Re-run with --apply to write them.\n' "${#raises[@]}"
  exit 0
fi

for raise in "${raises[@]}"; do
  source_path="${raise%% *}"
  target="${raise##* }"
  # Rewrite the one line in place. The thresholds file is one key per line by
  # convention, and editing it textually keeps its formatting and comments
  # exactly as they were rather than round-tripping through a JSON printer.
  escaped_path="${source_path//\//\\/}"
  sed -i -E "s/^([[:space:]]*\"${escaped_path}\":[[:space:]]*)[0-9]+(,?)$/\1${target}\2/" "${THRESHOLDS}"
  printf 'raised %s to %s\n' "${source_path}" "${target}"
done

printf '\n%s updated. Review the diff and say in the commit what added the coverage.\n' "${THRESHOLDS}"

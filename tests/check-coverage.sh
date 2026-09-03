#!/usr/bin/env bash
set -euo pipefail

# Gate on the minimum number of unique production lines reached by the shell
# suite. Bash xtrace provides the source file and line number without adding a
# framework or executing anything beyond the tests themselves. Thresholds are
# deliberately per script: one well-tested helper cannot hide a regression that
# stops another shipped script from being exercised at all.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
THRESHOLDS="${REPO_ROOT}/.coverage-thresholds.json"
WORK_DIR="$(mktemp -d)"
TRACE_FILE="${WORK_DIR}/bash.trace"
TRACE_ENV="${WORK_DIR}/trace-env.sh"

cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

cat >"${TRACE_ENV}" <<'EOF'
if [[ -n "${ARCH_BOOTC_COVERAGE_TRACE:-}" ]]; then
  exec 9>>"${ARCH_BOOTC_COVERAGE_TRACE}"
  BASH_XTRACEFD=9
  export PS4='+${BASH_SOURCE[0]:-$0}:${LINENO}:'
  set -x
fi
EOF

ARCH_BOOTC_COVERAGE_TRACE="${TRACE_FILE}" \
BASH_ENV="${TRACE_ENV}" \
  bash "${SCRIPT_DIR}/run-tests.sh"

# Traced-line counts vary slightly by Bash version for identical code (see the
# threshold note in docs/ci-cd.md), so record which Bash produced this report.
# Without it, a one-line miss looks like a coverage regression rather than the
# environment difference it usually is.
printf 'coverage: traced with bash %s on %s\n' "${BASH_VERSION}" "$(uname -s)"

declare -A covered_lines=()
while IFS=: read -r source_path line_number _; do
  source_path="${source_path#+}"
  while [[ "${source_path}" == +* ]]; do
    source_path="${source_path#+}"
  done
  [[ "${source_path}" == "${REPO_ROOT}/"* ]] || continue
  source_path="${source_path#"${REPO_ROOT}/"}"
  [[ "${line_number}" =~ ^[0-9]+$ ]] || continue
  covered_lines["${source_path}:${line_number}"]=1
done <"${TRACE_FILE}"

failures=0
thresholds_seen=0
while IFS=' ' read -r source_path minimum; do
  [[ -n "${source_path}" ]] || continue
  thresholds_seen=$((thresholds_seen + 1))
  if [[ ! -f "${REPO_ROOT}/${source_path}" ]]; then
    printf 'coverage: FAIL %-55s source file is missing\n' "${source_path}" >&2
    failures=$((failures + 1))
    continue
  fi

  covered=0
  for key in "${!covered_lines[@]}"; do
    [[ "${key}" == "${source_path}:"* ]] && covered=$((covered + 1))
  done

  total="$({
    sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${REPO_ROOT}/${source_path}"
  } | wc -l)"
  percent=$((covered * 100 / total))
  if ((covered < minimum)); then
    printf 'coverage: FAIL %-55s %3d/%3d lines (%2d%%), minimum %d traced lines\n' \
      "${source_path}" "${covered}" "${total}" "${percent}" "${minimum}" >&2
    failures=$((failures + 1))
  else
    printf 'coverage: PASS %-55s %3d/%3d lines (%2d%%), minimum %d traced lines\n' \
      "${source_path}" "${covered}" "${total}" "${percent}" "${minimum}"
  fi
done < <(
  sed -nE 's/^[[:space:]]*"([^"]+)":[[:space:]]*([0-9]+),?$/\1 \2/p' "${THRESHOLDS}"
)

if ((thresholds_seen == 0)); then
  echo "coverage: no thresholds found in ${THRESHOLDS}" >&2
  exit 1
fi

# Keep the manifest complete as the image grows. Sourced snippets without a
# shebang are linted elsewhere; every executable Bash entry point shipped from
# these directories must have its own floor here.
production_roots=(
  "${REPO_ROOT}/scripts"
  "${REPO_ROOT}/system_files/usr/bin"
  "${REPO_ROOT}/system_files/usr/libexec"
)
while IFS= read -r -d '' production_path; do
  IFS= read -r first_line <"${production_path}" || true
  [[ "${first_line}" == '#!'*bash* ]] || continue
  relative_path="${production_path#"${REPO_ROOT}/"}"
  if ! grep -Fq "\"${relative_path}\":" "${THRESHOLDS}"; then
    printf 'coverage: FAIL %-55s no threshold is configured\n' "${relative_path}" >&2
    failures=$((failures + 1))
  fi
done < <(find "${production_roots[@]}" -type f -print0 | sort -z)

if ((failures > 0)); then
  printf 'coverage: %d threshold(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'coverage: all %d per-script thresholds passed\n' "${thresholds_seen}"

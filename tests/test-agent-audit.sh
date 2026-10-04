#!/usr/bin/env bash
set -uo pipefail

# Execute agent-audit.yml's "Audit merged agent pull requests" step against a
# `gh` stub that serves staged JSON, with the real jq. The step is a read-only
# check of the record an agent pull request is supposed to leave -- a `— hive:`
# signature line and a Signed-off-by trailer on every commit -- and what it
# decides is all in one jq program that nothing else reads. Running the body
# Actions executes keeps the test attached to that program rather than to a
# second copy that could drift while both stayed green.
#
# No network: `gh` is shadowed on PATH, answers from files in a temporary
# directory, and records its argv. The step runs in an empty working directory
# so it cannot read or write the real checkout.
#
# The file also joins the step's T3 path list to docs/risk-tiers.md's T3
# section in both directions, and to the tree: a path the document names that
# the step does not report fails here, and so does a path the step reports that
# the document no longer names or the tree no longer holds.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/agent-audit.yml"
TIERS_DOC="${REPO_ROOT}/docs/risk-tiers.md"

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
GH_LOG="${WORK_DIR}/gh-log"
SUMMARY="${WORK_DIR}/summary.md"
mkdir -p "${RUN_DIR}" "${STUB_DIR}" "${FIXTURES}"

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

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required: the step under test is a jq program\n' >&2
  exit 1
fi

# Print the `run:` block of the named step of the named job, dedented to
# column 0. Qualifying the step by job matters because workflow step names are
# not globally unique. Refusing an empty result below makes a rename or layout
# change fail instead of turning every behavioral case into a test of nothing.
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

AUDIT_JOB="audit"
AUDIT_STEP="Audit merged agent pull requests"
audit_run="$(workflow_step_run "${WORKFLOW}" "${AUDIT_JOB}" "${AUDIT_STEP}")"
assert_extracted "the audit step's body is still where this test expects it" "${audit_run}"

# A GitHub expression is expanded by Actions before the shell sees the body.
# This harness does no expression evaluation, so fail if one is introduced
# instead of executing shell with different semantics from CI.
# shellcheck disable=SC2016
assert_absent "the audit step's body is plain shell" "${audit_run}" '${{'

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${GH_STUB_LOG}"
case "${1:-} ${2:-}" in
  "pr list") cat "${GH_STUB_FIXTURES}/list.json" ;;
  "pr view") cat "${GH_STUB_FIXTURES}/view-${3}.json" ;;
  "api repos/"*) cat "${GH_STUB_FIXTURES}/parents-${2##*/}" 2>/dev/null || printf '1\n' ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"

HIVE_APP="app/danathar-atomic-hive"
SIG_LINE='— hive: agent=quality backend=claude model=claude-opus-5-5 effort=medium claude=2.1.284'
SIGNED='Signed-off-by: Danathar <Danathar@users.noreply.github.com>'
NO_FILES='[]'

# One entry of the `gh pr list` array.
pr_entry() {
  local number="$1" login="$2" body="$3" merged_by="${4:-Danathar}"
  jq -n --argjson n "${number}" --arg login "${login}" --arg body "${body}" --arg by "${merged_by}" '
    {number: $n, title: "PR \($n)", url: "https://example.test/pull/\($n)",
     author: {login: $login, is_bot: ($login | startswith("app/"))},
     mergedAt: "2026-09-20T12:00:00Z", mergedBy: {login: $by}, body: $body}'
}

# One commit of a `gh pr view` reply: oid, headline, body.
commit_entry() {
  jq -n --arg oid "$1" --arg head "$2" --arg body "$3" \
    '{oid: $oid, messageHeadline: $head, messageBody: $body}'
}

# Stage the list and the per-pull-request replies. Arguments: the JSON array
# for list.json, then number=commits-json=files-json triples through view_pr.
stage_list() { printf '%s\n' "$1" >"${FIXTURES}/list.json"; }
view_pr() {
  jq -n --argjson n "$1" --argjson commits "$2" --argjson files "$3" --argjson changed "${4:-null}" \
    '{number: $n, commits: $commits, files: $files, changedFiles: ($changed // ($files | length))}' >"${FIXTURES}/view-$1.json"
}
reset_fixtures() { rm -f -- "${FIXTURES}"/*; }

run_audit() {
  local since="$1"
  : >"${GH_LOG}"
  : >"${SUMMARY}"
  # The step has no `shell:` key, so Actions runs it as `bash -e {0}`: errexit
  # comes from the runner, pipefail only from the step's own `set` line. The
  # harness passes what the runner passes and no more, so nothing here passes
  # because the harness set an option the step does not.
  (
    cd -- "${RUN_DIR}" || exit 99
    rm -f -- ./*.json
    PATH="${STUB_DIR}:${PATH}" \
      GH_STUB_FIXTURES="${FIXTURES}" \
      GH_STUB_LOG="${GH_LOG}" \
      GH_TOKEN="test-token" \
      REPO="Danathar/arch-bootc" \
      SINCE="${since}" \
      GITHUB_STEP_SUMMARY="${SUMMARY}" \
      "${BASH}" --noprofile --norc -e -c "${audit_run}"
  )
}

one_commit() { jq -n --argjson c "$(commit_entry "$1" "$2" "$3")" '[$c]'; }

# --- The clean window --------------------------------------------------------
#
# Five merged pull requests, only three of them agent-written: the Hive app's
# (signed commits), an omp-style run under the maintainer's own login that
# carries the signature line, and a Hive-app one with a merge commit that has
# no trailer. A Renovate pull request is a bot too, and a human one has no
# signature; neither may be audited.
reset_fixtures
stage_list "$(jq -s '.' < <(
  pr_entry 101 "${HIVE_APP}" $'Does a thing.\n\n'"${SIG_LINE}"
  pr_entry 102 "Danathar" $'An omp run.\n\n— hive: backend=omp model=anthropic/claude-fable-5-1 effort=high'
  pr_entry 103 "${HIVE_APP}" $'Merges main in.\n\n'"${SIG_LINE}"
  pr_entry 104 "app/renovate" "Update a pin."
  pr_entry 105 "Danathar" "A human change."
))"
view_pr 101 "$(one_commit aaaaaaa1111 "fix: a" $'body\n\n'"${SIGNED}")" '[{"path": "docs/quality.md"}]'
view_pr 102 "$(jq -s '.' < <(
  commit_entry bbbbbbb2222 "feat: b" $'x\n\n'"${SIGNED}"
  commit_entry bbbbbbb3333 "feat: c" "${SIGNED}"
))" '[{"path": "scripts/quickstart.sh"}, {"path": "README.md"}]'
view_pr 103 "$(jq -s '.' < <(
  commit_entry ccccccc4444 "fix: d" "${SIGNED}"
  commit_entry ccccccc5555 "Merge remote-tracking branch 'origin/main' into x" ""
))" '[{"path": "Containerfile"}]'
printf '2\n' >"${FIXTURES}/parents-ccccccc5555"

output="$(run_audit "2026-09-01" 2>&1)"
status=$?
summary="$(cat "${SUMMARY}")"
assert_status "a window where every agent pull request left its record exits 0" 0 "${status}"
assert_contains "the summary counts the agent pull requests against the window" \
  "${summary}" "3 of the 5 pull requests merged in the window were written by an agent."
assert_contains "the Hive-app pull request is listed with its backend, model and agent" \
  "${summary}" "| [#101](https://example.test/pull/101) PR 101 | 2026-09-20 | ${HIVE_APP} | Danathar | claude / claude-opus-5-5 (quality) | 1 | all | none |"
assert_contains "a signature without an agent key still reports backend and model" \
  "${summary}" "| Danathar | Danathar | omp / anthropic/claude-fable-5-1 (no agent) | 2 | all | \`scripts/quickstart.sh\` |"
assert_contains "a merge commit with no trailer is exempt and the row says all signed" \
  "${summary}" "| 2 | 1 of 2 (merges exempt) | \`Containerfile\` (T3 by content) |"
assert_absent "Renovate's pull request is not audited" "${summary}" "#104"
assert_absent "a human pull request is not audited" "${summary}" "#105"
assert_contains "a clean window says so, and that the one merge without a trailer was exempt" "${summary}" \
  "Every Hive-app pull request carries its signature line and every non-merge commit its Signed-off-by trailer. 1 merge commit(s) without a trailer were exempt."
assert_contains "the summary is also printed to the job log" "${output}" "### Agent audit trail: pull requests merged since 2026-09-01"
assert_equal "only the three agent pull requests are fetched in detail" \
  "pr view 101 --repo Danathar/arch-bootc --json number,commits,files,changedFiles
pr view 102 --repo Danathar/arch-bootc --json number,commits,files,changedFiles
pr view 103 --repo Danathar/arch-bootc --json number,commits,files,changedFiles" \
  "$(grep '^pr view' "${GH_LOG}")"
assert_equal "the list is a merged-state search from the window's start, capped at 500, for this repository" \
  "pr list --repo Danathar/arch-bootc --state merged --limit 500 --search merged:>=2026-09-01 --json number,title,author,mergedAt,mergedBy,body,url" \
  "$(grep '^pr list' "${GH_LOG}")"

# --- The signature line ------------------------------------------------------
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 201 "${HIVE_APP}" "No signature here."))"
view_pr 201 "$(one_commit ddddddd1111 "fix: e" "${SIGNED}")" "${NO_FILES}"
output="$(run_audit "2026-09-01" 2>&1)"
status=$?
summary="$(cat "${SUMMARY}")"
assert_status "a Hive-app pull request with no signature line fails the run" 1 "${status}"
# shellcheck disable=SC2016  # the backticks are the report's own markup
assert_contains "the finding names the pull request and the missing line" "${summary}" \
  '- #201: opened by the Hive app with no `— hive:` signature line'
assert_contains "the row says the signature is missing rather than blank" "${summary}" "**no signature**"
assert_contains "the failure is annotated for the job log" "${output}" \
  "::error::1 agent pull request(s) merged since 2026-09-01 left an incomplete record"

# A signature line that is not at the start of a line is not the signature: a
# quoted mention of the format must not make a Hive-app pull request look
# signed, and must not make a human one look agent-written.
reset_fixtures
# shellcheck disable=SC2016  # literal backticks in a fixture body
stage_list "$(jq -s '.' < <(
  pr_entry 211 "${HIVE_APP}" 'The format is `— hive: backend=x`, quoted.'
  pr_entry 212 "Danathar" 'See the line "x — hive: backend=y" in the docs.'
))"
view_pr 211 "$(one_commit eeeeeee1111 "fix: f" "${SIGNED}")" "${NO_FILES}"
output="$(run_audit "2026-09-01" 2>&1)"
status=$?
summary="$(cat "${SUMMARY}")"
assert_status "a quoted signature mention does not count as a signature" 1 "${status}"
assert_contains "the Hive-app pull request quoting it is still a finding" "${summary}" "#211: opened by the Hive app with no"
assert_absent "a human pull request quoting it is not audited" "${summary}" "#212"

# --- Signed-off-by -----------------------------------------------------------
reset_fixtures
stage_list "$(jq -s '.' < <(
  pr_entry 301 "${HIVE_APP}" $'One.\n\n'"${SIG_LINE}"
  pr_entry 302 "Danathar" $'Two.\n\n'"${SIG_LINE}"
))"
view_pr 301 "$(jq -s '.' < <(
  commit_entry fffffff1111 "fix: g" "${SIGNED}"
  commit_entry fffffff2222 "fix: h" "no trailer in this one"
))" "${NO_FILES}"
view_pr 302 "$(jq -s '.' < <(
  commit_entry 1111111aaaa "fix: i" "nothing"
  commit_entry 2222222bbbb "fix: j" "The footer should read Signed-off-by: someone, but this line is prose"
  commit_entry 3333333cccc "fix: k" "${SIGNED}"
))" "${NO_FILES}"
output="$(run_audit "2026-09-01" 2>&1)"
status=$?
summary="$(cat "${SUMMARY}")"
assert_status "a commit with no Signed-off-by trailer fails the run" 1 "${status}"
assert_contains "one unsigned commit is named by its short oid, singular" "${summary}" \
  "- #301: commit fffffff carries no Signed-off-by trailer"
assert_contains "two unsigned commits are named together, plural" "${summary}" \
  "- #302: commits 1111111, 2222222 carry no Signed-off-by trailer"
assert_contains "the row counts the signed commits" "${summary}" "| 2 | **1 of 2** |"
assert_contains "the row counts the signed commits of three" "${summary}" "| 3 | **1 of 3** |"
assert_contains "two findings are counted in the annotation" "${output}" \
  "::error::2 agent pull request(s) merged since 2026-09-01 left an incomplete record"

# A trailer on the last line of a body with no trailing newline counts, and so
# does one after other trailers.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 311 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 311 "$(one_commit 4444444dddd "fix: l" $'Co-authored-by: A <a@example.test>\nSigned-off-by: B <b@example.test>')" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a trailer after another trailer counts as signed off" 0 "$?"

# --- The T3 column, joined to docs/risk-tiers.md and the tree ----------------
#
# The step's own list is read out of the workflow, then held to the T3 section
# of the document in both directions.
step_array() {
  awk -v name="$1" '
    $0 ~ "def " name ": \\[" { in_def = 1 }
    in_def { print }
    in_def && /\]/ { exit }
  ' <<<"${audit_run}" | grep -oE '"[^"]+"' | tr -d '"'
}
mapfile -t t3_listed < <(step_array t3paths)
mapfile -t t3_content < <(step_array t3content)
assert_extracted "the step's T3 path list was read" "${t3_listed[*]:-}"
assert_extracted "the step's T3-by-content list was read" "${t3_content[*]:-}"

t3_section="$(awk '/^## T3 — /{ inside = 1; next } inside && /^## /{ exit } inside' "${TIERS_DOC}")"
assert_extracted "the T3 section of docs/risk-tiers.md was read" "${t3_section}"

normalize_doc_path() {
  local token="$1"
  token="${token%\*\*}"
  printf '%s' "${token}"
}

# Document -> step: every backticked token in the T3 section that is a path in
# the tree must be in one of the step's lists.
# shellcheck disable=SC2016  # the backticks are the page's own markup, matched literally
doc_token_re='`[^`]+`'
doc_paths=""
while IFS= read -r token; do
  token="${token//\`/}"
  [[ -n "${token}" && "${token}" != /* && "${token}" != *" "* ]] || continue
  normalized="$(normalize_doc_path "${token}")"
  [[ -e "${REPO_ROOT}/${normalized}" ]] || continue
  doc_paths+="${normalized}"$'\n'
  found=""
  for listed in "${t3_listed[@]}" "${t3_content[@]}"; do
    [[ "${listed}" == "${normalized}" ]] && found="yes"
    # A listed directory covers every path under it.
    [[ "${listed}" == */ && "${normalized}" == "${listed}"* ]] && found="yes"
  done
  if [[ -n "${found}" ]]; then
    check "the step reports the T3 path the document names: ${normalized}" 0
  else
    check "the step reports the T3 path the document names: ${normalized}" 1 \
      "docs/risk-tiers.md names it in T3 and agent-audit.yml's t3paths does not list it"
  fi
done < <(grep -oE "${doc_token_re}" <<<"${t3_section}")
assert_extracted "the T3 section names at least one path that exists in the tree" "${doc_paths}"

# Step -> document and tree: every listed path is named in the T3 section and
# exists, so a path dropped from the document or renamed in the tree is caught.
for listed in "${t3_listed[@]}"; do
  if grep -qxF -- "${listed}" <<<"${doc_paths}"; then
    check "the T3 section still names what the step reports: ${listed}" 0
  else
    check "the T3 section still names what the step reports: ${listed}" 1 \
      "no backticked \`${listed}\` (or \`${listed}**\`) naming an existing path in docs/risk-tiers.md's T3 section"
  fi
done
for listed in "${t3_content[@]}"; do
  if [[ -e "${REPO_ROOT}/${listed}" ]]; then
    check "the T3-by-content file exists in the tree: ${listed}" 0
  else
    check "the T3-by-content file exists in the tree: ${listed}" 1 "no such path"
  fi
  if grep -qxF -- "${listed}" <<<"${doc_paths}"; then
    check "the T3 section names the T3-by-content file: ${listed}" 0
  else
    check "the T3 section names the T3-by-content file: ${listed}" 1 \
      "no backticked \`${listed}\` in docs/risk-tiers.md's T3 section"
  fi
done

# Behaviour: one pull request touching every listed path (a prefix gets a file
# under it), one touching look-alikes. The first must report every path, the
# second none -- a prefix that matched by substring, or an exact path that
# matched by prefix, would fail the second.
files_json="$(
  for listed in "${t3_listed[@]}"; do
    if [[ "${listed}" == */ ]]; then
      printf '%s\n' "${listed}probe.txt"
    else
      printf '%s\n' "${listed}"
    fi
  done | jq -R '{path: .}' | jq -s '.'
)"
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 401 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 401 "$(one_commit 5555555eeee "fix: m" "${SIGNED}")" "${files_json}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a pull request touching T3 paths is reported, not failed" 0 "$?"
summary="$(cat "${SUMMARY}")"
for listed in "${t3_listed[@]}"; do
  expected="${listed}"
  [[ "${listed}" == */ ]] && expected="${listed}probe.txt"
  assert_contains "the row names the touched T3 path ${expected}" "${summary}" "\`${expected}\`"
done

reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 411 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 411 "$(one_commit 6666666ffff "docs: n" "${SIGNED}")" '[
  {"path": "README.md"},
  {"path": "docs/risk-tiers.md"},
  {"path": "tests/test-agent-audit.sh"},
  {"path": ".github/workflows/agent-audit.yml"},
  {"path": "cosign.pub.bak"},
  {"path": "scripts/quickstart.sh.orig"},
  {"path": ".claude/settings.json.bak"},
  {"path": ".github/rulesets-old/main.json"},
  {"path": "system_files/etc/containers/other.conf"},
  {"path": "x/.claude/hooks/gate.sh"}
]'
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a pull request touching look-alike paths exits 0" 0 "$?"
assert_contains "no look-alike path is reported as T3" "$(cat "${SUMMARY}")" "| 1 | all | none |"

# The documented boot/service-enablement layout, mapped to the files this tree
# really holds under it: every one is reported, and neighbours are not.
t3_section_flat="$(tr '\n' ' ' <<<"${t3_section}" | tr -s '[:space:]' ' ')"
# shellcheck disable=SC2016  # the backticks are the page's own markup, matched literally
assert_contains "docs/risk-tiers.md still names the service-enablement layout" \
  "${t3_section_flat}" '`/usr/lib/systemd/system/<target>.wants/`'
mapfile -t wants_real < <(cd "${REPO_ROOT}" && find system_files/usr/lib/systemd/system -path '*.wants/*' | LC_ALL=C sort)
assert_extracted "the tree holds files under a systemd .wants/ directory" "${wants_real[*]:-}"
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 421 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 421 "$(one_commit 8888888aaaa "fix: p" "${SIGNED}")" "$(printf '%s\n' "${wants_real[@]}" | jq -R '{path: .}' | jq -s '.')"
run_audit "2026-09-01" >/dev/null 2>&1
for wants_file in "${wants_real[@]}"; do
  assert_contains "a real service-enablement path is reported as T3: ${wants_file}" "$(cat "${SUMMARY}")" "\`${wants_file}\`"
done
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 422 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 422 "$(one_commit 9999999aaaa "fix: q" "${SIGNED}")" '[
  {"path": "system_files/usr/lib/systemd/system/example.service"},
  {"path": "system_files/usr/lib/systemd/system/x.wants.bak/y"},
  {"path": "system_files/usr/lib/systemd/system/a/b.wants/c"},
  {"path": "x/system_files/usr/lib/systemd/system/m.target.wants/n"},
  {"path": "system_files/usr/lib/systemd/system/multi-userxwants/r"}
]'
run_audit "2026-09-01" >/dev/null 2>&1
assert_contains "systemd paths outside a .wants/ directory are not T3" "$(cat "${SUMMARY}")" "| 1 | all | none |"

# --- Merge commits and partial reads -----------------------------------------
# A commit is a merge when it has more than one parent, whatever its headline
# says: a person's "Merge the two helpers" or "Merge cleanup into main" with no
# trailer is a finding, and a merge headlined "Update the thing" is exempt.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 431 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 431 "$(jq -s '.' < <(
  commit_entry aaaaaaa6666 "Merge the two helpers" "no trailer"
  commit_entry bbbbbbb7777 "Merge cleanup into main" ""
  commit_entry ccccccc8888 "Update the thing" ""
  commit_entry fffffff1111 "ok" "${SIGNED}"
))" "${NO_FILES}"
printf '2\n' >"${FIXTURES}/parents-ccccccc8888"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "unsigned commits headlined 'Merge ...' with one parent fail the run" 1 "$?"
summary="$(cat "${SUMMARY}")"
assert_contains "both are named and the two-parent commit is not" "${summary}" \
  "- #431: commits aaaaaaa, bbbbbbb carry no Signed-off-by trailer"
assert_contains "the signed column counts real trailers across every commit" "${summary}" "| 4 | **1 of 4** |"
assert_equal "parents are asked only for the commits that lack a trailer" \
  "api repos/Danathar/arch-bootc/commits/aaaaaaa6666 --jq .parents | length
api repos/Danathar/arch-bootc/commits/bbbbbbb7777 --jq .parents | length
api repos/Danathar/arch-bootc/commits/ccccccc8888 --jq .parents | length" \
  "$(grep '^api' "${GH_LOG}")"

# A pull request holding more than the API returns is refused, not read as clean.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 441 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 441 "$(one_commit 1010101aaaa "fix: r" "${SIGNED}")" '[{"path": "a"}]' 150
output="$(run_audit "2026-09-01" 2>&1)"
assert_status "a pull request with more files than were listed is refused" 2 "$?"
assert_contains "the refusal names the pull request" "${output}" "::error::#441 list fewer commits or files"
assert_equal "a refused pull request writes nothing to the summary" "" "$(cat "${SUMMARY}")"
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 451 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 451 "$(jq -n --argjson c "$(commit_entry 2020202aaaa "fix: s" "${SIGNED}")" '[range(100) | $c]')" "${NO_FILES}"
output="$(run_audit "2026-09-01" 2>&1)"
assert_status "a pull request with 100 commits (the API's ceiling) is refused" 2 "$?"
view_pr 451 "$(jq -n --argjson c "$(commit_entry 2020202aaaa "fix: s" "${SIGNED}")" '[range(99) | $c]')" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a pull request with 99 commits is audited" 0 "$?"

# --- Refusals ----------------------------------------------------------------
reset_fixtures
stage_list "$(jq -n '[range(500) | {number: ., title: "t", url: "u", author: {login: "x"}, mergedAt: "2026-09-20T12:00:00Z", mergedBy: {login: "y"}, body: ""}]')"
output="$(run_audit "2026-01-01" 2>&1)"
status=$?
assert_status "a window that fills the 500 cap is refused" 2 "${status}"
assert_contains "the refusal names the cap and the window" "${output}" \
  "::error::500 pull requests merged since 2026-01-01 reached the 500 cap; audit a narrower window"
assert_equal "a refused window fetches no pull request in detail" "" "$(grep -c '^pr view' "${GH_LOG}" | grep -v '^0$' || true)"
assert_equal "a refused window writes nothing to the summary" "" "$(cat "${SUMMARY}")"

# One under the cap is audited, so the refusal is the cap and not a smaller number.
stage_list "$(jq -n '[range(499) | {number: ., title: "t", url: "u", author: {login: "x"}, mergedAt: "2026-09-20T12:00:00Z", mergedBy: {login: "y"}, body: ""}]')"
run_audit "2026-01-01" >/dev/null 2>&1
assert_status "499 merged pull requests is audited, not refused" 0 "$?"
assert_contains "the audit counts all 499" "$(cat "${SUMMARY}")" "0 of the 499 pull requests"

# shellcheck disable=SC2016  # a literal command substitution, which must not run
for bad in "yesterday" "2026-9-1" "2026-09-01T00:00:00Z" "2026-09-01 --state open" '$(id)' "2026-13-45" "2026-02-30" "2026-00-10"; do
  output="$(run_audit "${bad}" 2>&1)"
  status=$?
  assert_status "a malformed since '${bad}' is refused" 2 "${status}"
  assert_contains "the refusal for '${bad}' says what a date looks like" "${output}" "since must be"
  assert_equal "a malformed since '${bad}' reaches no API call" "" "$(cat "${GH_LOG}")"
done

# The shape is checked before the date is: a word is refused as not a date at
# all, not as an impossible one.
output="$(run_audit "yesterday" 2>&1)"
assert_contains "a word since is refused by its shape" "${output}" "::error::since must be YYYY-MM-DD, got 'yesterday'"

# A blank since is the last 31 days, computed by the step itself.
reset_fixtures
stage_list '[]'
output="$(run_audit "" 2>&1)"
status=$?
assert_status "a blank since audits the default window" 0 "${status}"
assert_contains "the default window starts 31 days ago" "$(grep '^pr list' "${GH_LOG}")" \
  "--search merged:>=$(date -u -d '31 days ago' +%F) "
assert_contains "an empty window reports no agent pull requests" "$(cat "${SUMMARY}")" \
  "0 of the 0 pull requests merged in the window were written by an agent."
assert_absent "an empty window prints no table" "$(cat "${SUMMARY}")" "| PR |"

# A pipe in a title is escaped so it cannot split the table row.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 501 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}" | jq '.title = "a | b"'))"
view_pr 501 "$(one_commit 7777777aaaa "fix: o" "${SIGNED}")" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_contains "a pipe in a title does not split the row" "$(cat "${SUMMARY}")" 'a \| b'

# A pull request whose detail cannot be fetched fails the run instead of being
# reported as clean with no commits.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 601 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
output="$(run_audit "2026-09-01" 2>&1)"
status=$?
if [[ "${status}" != "0" ]]; then
  check "an unreadable pull request fails the run instead of auditing nothing" 0
else
  check "an unreadable pull request fails the run instead of auditing nothing" 1 "exit 0"
fi
assert_equal "an unreadable pull request leaves no summary" "" "$(cat "${SUMMARY}")"

# --- Near misses in the record ---------------------------------------------
#
# A body that is nothing but the signature line is agent-written: the line
# starts the body, so there is no newline before it.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 701 "Danathar" "${SIG_LINE}"))"
view_pr 701 "$(one_commit 7070707aaaa "fix: t" "${SIGNED}")" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a body that is only the signature line is audited and clean" 0 "$?"
summary="$(cat "${SUMMARY}")"
assert_contains "a body that is only the signature line counts as agent-written" "${summary}" \
  "1 of the 1 pull requests merged in the window were written by an agent."
assert_contains "its row reads the signature" "${summary}" "| [#701](https://example.test/pull/701) PR 701 |"
assert_contains "a clean window with no merge commit says so" "${summary}" \
  "Every Hive-app pull request carries its signature line and every non-merge commit its Signed-off-by trailer."
assert_absent "a clean window with no merge commit counts no exempt merge" "${summary}" "merge commit(s)"

# A key is a whole word: `subagent=` and `submodel=` are not `agent=` and
# `model=`, even when they come first. A signature missing a key says so, and
# a pipe in a key's value is escaped like a pipe in a title.
reset_fixtures
stage_list "$(jq -s '.' < <(
  pr_entry 711 "${HIVE_APP}" $'x\n\n— hive: subagent=wrong submodel=wrong backend=claude model=right agent=quality'
  pr_entry 712 "${HIVE_APP}" $'x\n\n— hive: agent=solo'
  pr_entry 713 "${HIVE_APP}" $'x\n\n— hive: backend=a|b model=m agent=q'
))"
view_pr 711 "$(one_commit 7171717aaaa "fix: u" "${SIGNED}")" "${NO_FILES}"
view_pr 712 "$(one_commit 7272727aaaa "fix: v" "${SIGNED}")" "${NO_FILES}"
view_pr 713 "$(one_commit 7373737aaaa "fix: w" "${SIGNED}")" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
summary="$(cat "${SUMMARY}")"
assert_contains "a key is not read out of a longer key that ends in it" "${summary}" "| claude / right (quality) |"
assert_contains "a signature with no backend or model says which are missing" "${summary}" "| ? / no model (solo) |"
assert_contains "a pipe in a signature value does not split the row" "${summary}" '| a\|b / m (q) |'

# A pull request GitHub reports with no merger still gets a row that says so.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 721 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}" | jq '.mergedBy = null'))"
view_pr 721 "$(one_commit 7474747aaaa "fix: x" "${SIGNED}")" "${NO_FILES}"
run_audit "2026-09-01" >/dev/null 2>&1
assert_contains "a missing merger is reported as unknown" "$(cat "${SUMMARY}")" "| ${HIVE_APP} | unknown |"

# Several T3 paths in one row are listed apart, each with its own label.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 731 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 731 "$(one_commit 7575757aaaa "fix: y" "${SIGNED}")" '[{"path": "cosign.pub"}, {"path": "Containerfile"}]'
run_audit "2026-09-01" >/dev/null 2>&1
# shellcheck disable=SC2016  # the backticks are the report's own markup
assert_contains "two touched T3 paths are separated by a comma" "$(cat "${SUMMARY}")" \
  '| `cosign.pub`, `Containerfile` (T3 by content) |'

# Every partial pull request is named, not only the first.
reset_fixtures
stage_list "$(jq -s '.' < <(
  pr_entry 741 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"
  pr_entry 742 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"
))"
view_pr 741 "$(one_commit 7676767aaaa "fix: z" "${SIGNED}")" '[{"path": "a"}]' 150
view_pr 742 "$(one_commit 7777777bbbb "fix: z" "${SIGNED}")" '[{"path": "a"}]' 120
output="$(run_audit "2026-09-01" 2>&1)"
assert_status "two partial pull requests are refused" 2 "$?"
assert_contains "the refusal names both" "${output}" "::error::#741,#742 list fewer commits or files"

# A merge commit whose message mentions Signed-off-by in prose has no trailer,
# so its parents are read and it is exempt like any other merge.
reset_fixtures
stage_list "$(jq -s '.' < <(pr_entry 751 "${HIVE_APP}" $'x\n\n'"${SIG_LINE}"))"
view_pr 751 "$(jq -s '.' < <(
  commit_entry 7878787aaaa "fix: a" "${SIGNED}"
  commit_entry 7979797aaaa "Update the branch" "Every commit here needs Signed-off-by: lines except this merge"
))" "${NO_FILES}"
printf '2\n' >"${FIXTURES}/parents-7979797aaaa"
run_audit "2026-09-01" >/dev/null 2>&1
assert_status "a merge that mentions the trailer in prose is exempt" 0 "$?"
assert_contains "the row counts it as an exempt merge" "$(cat "${SUMMARY}")" "| 2 | 1 of 2 (merges exempt) |"
assert_equal "its parents are read" \
  "api repos/Danathar/arch-bootc/commits/7979797aaaa --jq .parents | length" \
  "$(grep '^api' "${GH_LOG}")"

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"

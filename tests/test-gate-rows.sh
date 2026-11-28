#!/usr/bin/env bash
set -uo pipefail

# Run .claude/hooks/gate-git-diff.sh, the PreToolUse hook on Bash that
# .claude/settings.json registers, against the rows that need only a command
# and a verdict: the settings-environment spellings and the fleet's shared
# refusal corpus.
#
# These rows lived in tests/test-gate-git-diff.sh, which takes minutes because
# it also builds fixture repositories, proves each exposure against real git
# and rewrites the hook rule by rule. This file runs in seconds, so
# tests/mutation-check.sh can run it once for every edit of a changed hook
# line. Before the split the hook was left out of that check, and a refusal
# whose test asserted nothing went unnoticed (#722).
#
# Both files run under run-tests.sh, so check-coverage.sh traces both, and the
# hook's floor in .coverage-thresholds.json is reached from the two together.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd -- "${REPO_ROOT}" || exit 1

CLAUDE_SETTINGS=".claude/settings.json"

checks_run=0
failures=0

group() {
  printf '\n# %s\n' "$1"
}

pass() {
  checks_run=$((checks_run + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  checks_run=$((checks_run + 1))
  failures=$((failures + 1))
  printf 'not ok - %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '  # %s\n' "$2" >&2
  # Under tests/mutation-check.sh one failure catches the edit, and the rest
  # of the rows would only spend its budget.
  [[ -n "${MUTATION_CHECK:-}" ]] && exit 1
  return 0
}

assert_equal() {
  local description="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${description}"
  else
    fail "${description}" "expected '${expected}', found '${actual}'"
  fi
}

group "The settings environment (.claude/hooks/gate-git-diff.sh, run against what it refuses and what it permits)"

settings_readable=0
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is available to read ${CLAUDE_SETTINGS}" \
    "jq is not on PATH, so the hook could not be extracted and nothing below ran"
elif ! jq -e 'type == "object"' "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
  fail "${CLAUDE_SETTINGS} parses as a JSON object" "jq could not parse ${CLAUDE_SETTINGS}"
else
  pass "${CLAUDE_SETTINGS} parses as a JSON object"
  settings_readable=1
fi

if ((settings_readable)); then
  bash_hooks=()
  while IFS= read -r hook_command; do
    [[ -n "${hook_command}" ]] && bash_hooks+=("${hook_command}")
  done < <(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.type == "command") | .command' "${CLAUDE_SETTINGS}")

  if ((${#bash_hooks[@]} > 0)); then
    pass "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash"
  else
    fail "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash" \
      "nothing is handed the command string, so every row below is unprompted"
  fi

  # Runs every Bash PreToolUse hook against PAYLOAD on stdin, the way Claude
  # Code invokes them, with CLAUDE_PROJECT_DIR set to the absolute checkout
  # path so check-coverage.sh counts the traced lines. Exit status 2 is a
  # refusal; the highest status seen and the text the agent would be shown are
  # kept. See tests/test-gate-git-diff.sh for the longer account.
  hook_status=0
  hook_stderr=""
  run_bash_hooks() {
    local payload="$1"
    local hook err rc
    hook_status=0
    hook_stderr=""
    for hook in "${bash_hooks[@]+"${bash_hooks[@]}"}"; do
      err="$(printf '%s' "${payload}" | CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash -c "${hook}" 2>&1 >/dev/null)"
      rc=$?
      ((rc > hook_status)) && hook_status="${rc}"
      [[ -n "${err}" ]] && hook_stderr+="${err} "
    done
    return 0
  }

  # Exit 2 alone cannot tell the hook's refusals apart, so a refusal is
  # asserted by the text that names its reason.
  assert_hook_refuses_naming() {
    local description="$1" command="$2" wanted="$3"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${payload}"
    if ((hook_status == 2)) && [[ "${hook_stderr}" == *"${wanted}"* ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted exit 2 naming '${wanted}'"
    fi
  }

  assert_hook_permits() {
    local description="$1" command="$2"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${payload}"
    if ((hook_status == 0)) && [[ -z "${hook_stderr}" ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted a silent exit 0"
    fi
  }

  # The settings pass at the end of the hook: the spellings the shared corpus
  # has no row for. Dropping any one of the branches they reach leaves every
  # corpus row passing.
  # shellcheck disable=SC2016 # the expansions are spellings handed to the hook, not run here
  for settings_command in \
    ': $[ GIT_CONFIG_COUNT = 0 ]; git log -p' \
    '! unset GIT_CONFIG_COUNT; git log -p' \
    '((i=1,(j=2),(k=3),PATH=4)); git log -1' \
    '/bin/env -i git log -p' \
    '/usr/bin/env -i git log -p' \
    'HOME+=p; git log -p' \
    'HOME[0]=p; git log -p' \
    'builtin export -n GIT_CONFIG_COUNT; git log -p' \
    'builtin read -r HOME < f; git log -1' \
    'command -p unset GIT_CONFIG_COUNT; git log -p' \
    'command read -r HOME < f; git log -1' \
    'declare -n r=GIT_CONFIG_COUNT; r=0; git log -p' \
    'declare HOME=x; git log -p' \
    'declare PATH+=x; git log -p' \
    'declare PATH[0]=x; git log -p' \
    'declare XDG_CONFIG_HOME=x; git log -p' \
    'echo "$(( GIT_CONFIG_COUNT = 0 ))"; git log -p' \
    'env --argv0=x -u GIT_CONFIG_COUNT git log -p' \
    'env --c /tmp -i git log -p' \
    'env --i git log -p' \
    'env --split '"'"'-i ls'"'"'' \
    'env --u=GIT_CONFIG_COUNT git log -p' \
    'env --unset FOO -i git log -p' \
    'env -uGIT_CONFIG_COUNT git log -p' \
    'env GIT_CONFIG_COUNT=0 make' \
    'eval '"'"'unset GIT_CONFIG_COUNT'"'"'; git log -p' \
    'eval unset GIT_CONFIG_COUNT; git log -p' \
    'export -fn GIT_CONFIG_COUNT; git log -p' \
    'flock /tmp/l env -i git log -p' \
    'getopts x PATH; git log -1' \
    'for i in 1; do HOME=p; git log -1; done' \
    'if HOME=p; then git log -1; fi' \
    'if false; then true; elif HOME=p; then git log -1; fi' \
    'if false; then true; else HOME=p; git log -1; fi' \
    'if true; then HOME=p; git log -1; fi' \
    'let '"'"'i = HOME = 1'"'"'; git log -1' \
    'printf -v PATH[0] x; git log -p' \
    'printf -vGIT_CONFIG_COUNT 0; git log -p' \
    'read -raGIT_CONFIG_COUNT < f; git log -p' \
    'readarray -t PATH < f; git log -1' \
    'select GIT_CONFIG_COUNT in 0; do git log -p; done' \
    'time HOME=p; git log -1' \
    'timeout 5s unset GIT_CONFIG_COUNT' \
    'until ! HOME=p; do git log -1; done' \
    'wait -p GIT_CONFIG_COUNT; git log -p' \
    'watch declare +x GIT_CONFIG_COUNT' \
    'watch exec -c git log -p' \
    'watch export -n GIT_CONFIG_COUNT' \
    'watch local +x GIT_CONFIG_COUNT' \
    'watch readonly GIT_CONFIG_COUNT=0' \
    'watch typeset +x GIT_CONFIG_COUNT' \
    'while HOME=p; do git log -1; done' \
    '{ HOME=p; }; git log -1'; do
    assert_hook_refuses_naming "the hook refuses taking or overwriting git's settings environment: ${settings_command}" \
      "${settings_command}" 'settings environment'
  done
  assert_hook_refuses_naming "the hook refuses the joined spelling of --shallow-file" \
    'git --shallow-file=.env log -1' '--shallow-file'
  # A name that only looks like a guarded one, a command that only prints or
  # matches the words, and a wrapper option that changes nothing stay unprompted.
  for settings_command in \
    '(( MYPATH = 1 )); git log -1' \
    '(( PATHS = 1 )); git log -1' \
    '(( i = (1) )); echo HOME; git log -1' \
    'MYPATH=x; git log -1' \
    'declare +x FOO; git log -1' \
    'declare -n r=FOO; git log -1' \
    'declare -p GIT_CONFIG_COUNT; git log -1' \
    'declare MYPATH=x; git log -1' \
    'echo env -u GIT_CONFIG_COUNT; git log -1' \
    'eval '"'"'echo hi'"'"'; git log -1' \
    'getopts x FOO; git log -1' \
    'echo git ls-files; env -v FOO=1 ls' \
    'egrep unset GIT_CONFIG_COUNT; git log -1' \
    'env --argv0 name git log -1' \
    'env -Ci ls' \
    'env -u FOO ls --ignore-environment' \
    'fgrep unset GIT_CONFIG_COUNT; git log -1' \
    'git grep unset GIT_CONFIG_COUNT' \
    'grep -n unset GIT_CONFIG_COUNT; git log -1' \
    'let HOMES=1; git log -1' \
    'let MYPATH=1; git log -1' \
    'let PATHS=1; git log -1' \
    'read -r MYPATH < f; git log -1' \
    'read -r PATHS < f; git log -1' \
    'wait -p FOO; git log -1'; do
    assert_hook_permits "a command that leaves git's settings environment alone is unprompted: ${settings_command}" \
      "${settings_command}"
  done
  # env -C starts the command it runs in another directory, the wrapper's
  # spelling of `cd DIR &&` and `git -C DIR`: every operand check resolves
  # against the checkout, so `env -C /tmp git diff -- x .env` printed
  # /tmp/.env. Every spelling GNU env reads as -C is refused in front of git
  # or an allow-listed command, wherever it points.
  for chdir_command in \
    'env -C /tmp git diff -- x .env' \
    'env -C/tmp git diff -- x .env' \
    'env --chdir=/tmp git diff -- x .env' \
    'env --chdir /tmp git diff -- x .env' \
    'env --ch=/tmp git log -1' \
    'env --c /tmp git log -1' \
    'env -0C /tmp git log -1' \
    'env -vC /tmp git log -1' \
    'env -C . git log -1' \
    'timeout 5 env -C /tmp git diff -- x .env' \
    'git status; env -C /tmp git log -p -1' \
    'env -C /tmp bash -n tests/run-tests.sh' \
    'env -C /tmp shellcheck tests/run-tests.sh'; do
    assert_hook_refuses_naming "the hook refuses env -C in front of git or an allow-listed command: ${chdir_command}" \
      "${chdir_command}" 'env -C / --chdir'
  done
  # env -C in front of a command nothing here covers, a -u whose value is the
  # letter C, and the words as data are left alone.
  for chdir_command in \
    'env -C /tmp ls' \
    'env -uC git log -1' \
    'echo env -C /tmp; git log -1' \
    'git log --grep=chdir -1'; do
    assert_hook_permits "an env option that moves nothing this gate covers is unprompted: ${chdir_command}" \
      "${chdir_command}"
  done
fi

group "The fleet's shared refusal corpus (tests/fixtures/gate-refusal-corpus.json)"

# Six repositories each carry their own copy of this gate, in bash and Python,
# so a bypass fixed in one says nothing about the other five
# (Danathar/atomic-image-builder#609). tests/fixtures/gate-refusal-corpus.json
# is the one table they share: each row is a command, the verdict every gate
# has to reach, and the command prefixes the row depends on. The rows this
# repository's allow list reaches run through the registered hook here, so a
# bypass found anywhere is one new row, and every repository that allows the
# command fails until its gate refuses it.
#
# The canonical copy lives in Danathar/atomic-image-builder, whose
# docs/gate-refusal-corpus.md documents the row format. The copy here is
# pinned by SHA-256: change a row there, then copy the file here and update the
# pin. Exit 2, or a "deny" decision on stdout, is a refusal; exit 0 with no
# decision is an allow.

CORPUS="tests/fixtures/gate-refusal-corpus.json"
CORPUS_SHA256="9a4bb59d04da75d1a1a06ecb95c186eff82a977da6a8bb9dc3baa7cb2a9c723f"

# Allow rows this gate refuses on purpose. The corpus says these commands may
# be allowed; this gate is stricter and refuses them anyway. Each id here is
# expected to be REFUSED. The list is checked both ways below: a listed row the
# gate now allows fails, and so does an id that is not an allow row the gate
# reaches, so an entry cannot go stale.
#
#   config-removal-allow-env-split-other-u  `env -S -u FOO git log -1`: the gate
#       refuses every `env -S` / `--split-string`, because the split string is a
#       command its word scans never see.
CORPUS_OVER_REFUSED=(
  config-removal-allow-env-split-other-u
)

# corpus_over_refused ID: true when ID is on the list above.
corpus_over_refused() {
  local want="$1" listed
  for listed in "${CORPUS_OVER_REFUSED[@]}"; do
    [[ "${listed}" == "${want}" ]] && return 0
  done
  return 1
}

# The command prefix each wildcard Bash(...) allow rule covers, one per line.
# The fleet spells a prefix rule three ways (`git diff:*`, `git diff *`,
# `git diff*`); all three cover `git diff`. A rule with no wildcard allows one
# exact command and covers no prefix.
corpus_allow_prefixes() {
  jq -r '
    .permissions.allow // [] | .[]
    | select(startswith("Bash(") and endswith(")"))
    | .[5:-1]
    | if endswith(":*") then .[:-2]
      elif endswith(" *") then .[:-2]
      elif endswith("*") then .[:-1]
      else empty end
  '
}

# corpus_covered PREFIX PREFIXES: a prefix rule covers PREFIX at a word boundary.
corpus_covered() {
  local prefix="$1" rule
  while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    if [[ "${prefix}" == "${rule}" || "${prefix}" == "${rule} "* ]]; then
      return 0
    fi
  done <<<"$2"
  return 1
}

if ((settings_readable)) && [[ -f "${CORPUS}" ]]; then
  if command -v sha256sum >/dev/null 2>&1; then
    shared_digest="$(sha256sum "${CORPUS}" | cut -d' ' -f1)"
  else
    shared_digest="$(shasum -a 256 "${CORPUS}" | cut -d' ' -f1)"
  fi
  assert_equal "the corpus copy matches the pinned canonical file" \
    "${shared_digest}" "${CORPUS_SHA256}"
  assert_equal "the corpus schema version is one this file reads" \
    "$(jq -r '.schema' "${CORPUS}")" "1"
  shared_bad_rows="$(jq -r '
    .rows[]
    | select(
        ((keys - ["wraps"]) != ["class", "command", "id", "requires", "verdict", "why"])
        or ((.verdict == "refuse" or .verdict == "allow") | not)
        or ((.requires | length) == 0)
        or any(.requires[]; . != (. | gsub("^\\s+|\\s+$"; "")))
        or ((.command | gsub("\\s"; "")) == "")
        or ((.why | gsub("\\s"; "")) == "")
      )
    | .id
  ' "${CORPUS}")"
  assert_equal "every corpus row has exactly the documented fields" "${shared_bad_rows}" ""
  # `wraps` (optional) names a wrapper no allow rule covers, such as `flock`
  # in `flock /tmp/l git diff ...`. It is the command's first word, and never
  # the first word of a prefix the row requires, or the row would run only
  # where the wrapper itself is allowed. A row without it is read as before.
  shared_bad_wraps="$(jq -r '
    .rows[]
    | select(has("wraps"))
    | .wraps as $w
    | select(
        ($w | type) != "string"
        or ($w | test("^\\S+$") | not)
        or (.command | startswith($w + " ") | not)
        or any(.requires[]; split(" ")[0] == $w)
      )
    | .id
  ' "${CORPUS}")"
  assert_equal "every wrapped corpus row starts with the wrapper it names" "${shared_bad_wraps}" ""
  assert_equal "the corpus has wrapped rows for the check above to read" \
    "$(jq -r '[.rows[] | select(has("wraps"))] | length > 0' "${CORPUS}")" "true"
  assert_equal "corpus row ids are unique" \
    "$(jq -r '[.rows[].id] | unique | length' "${CORPUS}")" \
    "$(jq -r '.rows | length' "${CORPUS}")"
  # Refusals alone would pass a gate that refuses everything.
  assert_equal "the corpus holds both verdicts" \
    "$(jq -r '[.rows[].verdict] | unique | join(" ")' "${CORPUS}")" "allow refuse"

  for shared_rule in 'Bash(git diff:*)' 'Bash(git diff *)' 'Bash(git diff*)'; do
    if corpus_covered "git diff" \
      "$(jq -n --arg r "${shared_rule}" '{permissions: {allow: [$r]}}' | corpus_allow_prefixes)"; then
      pass "${shared_rule} covers the git diff prefix"
    else
      fail "${shared_rule} covers the git diff prefix"
    fi
  done
  if corpus_covered "ruff check" \
    "$(jq -n '{permissions: {allow: ["Bash(ruff check)"]}}' | corpus_allow_prefixes)"; then
    fail "an exact allow rule covers no prefix"
  else
    pass "an exact allow rule covers no prefix"
  fi
  shared_prefixes="$(jq -n '{permissions: {allow: ["Bash(gh pr:*)"]}}' | corpus_allow_prefixes)"
  if corpus_covered "gh pr view" "${shared_prefixes}" &&
    ! corpus_covered "gh prx view" "${shared_prefixes}"; then
    pass "a prefix rule covers only at a word boundary"
  else
    fail "a prefix rule covers only at a word boundary"
  fi

  shared_prefixes="$(corpus_allow_prefixes <"${CLAUDE_SETTINGS}")"
  shared_hook="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command][0] // empty' \
    "${CLAUDE_SETTINGS}")"
  # The rows run in a scratch repository with two commits and a copy of
  # .claude/, not in this checkout. CI checks this repository out at depth 1,
  # where `HEAD~1` names no commit, so the gate reads `git diff HEAD~1 HEAD`
  # as two plain-file operands and refuses it -- correctly for that checkout,
  # but it fails the allow-diff-range row, whose verdict assumes the history
  # an agent's working clone has.
  shared_project="$(mktemp -d)"
  cp -R "${REPO_ROOT}/.claude" "${shared_project}/.claude"
  (
    cd "${shared_project}" || exit 1
    git init -q . &&
      git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m first &&
      git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m second
  ) </dev/null >/dev/null 2>&1
  assert_equal "the scratch repository for the corpus has a HEAD~1" \
    "$(git -C "${shared_project}" rev-list --count HEAD 2>/dev/null)" "2"
  shared_applied=0
  shared_over_refused_seen=''
  while IFS= read -r shared_row; do
    shared_id="$(jq -r '.id' <<<"${shared_row}")"
    shared_verdict="$(jq -r '.verdict' <<<"${shared_row}")"
    shared_row_command="$(jq -r '.command' <<<"${shared_row}")"
    shared_reachable=1
    while IFS= read -r shared_prefix; do
      corpus_covered "${shared_prefix}" "${shared_prefixes}" || shared_reachable=0
    done < <(jq -r '.requires[]' <<<"${shared_row}")
    ((shared_reachable)) || continue
    shared_applied=$((shared_applied + 1))

    shared_err_file="$(mktemp)"
    shared_stdout="$(jq -cn --arg c "${shared_row_command}" '{tool_name: "Bash", tool_input: {command: $c}}' |
      CLAUDE_PROJECT_DIR="${shared_project}" bash -c "${shared_hook}" 2>"${shared_err_file}")"
    shared_status=$?
    shared_stderr="$(cat "${shared_err_file}")"
    rm -f "${shared_err_file}"
    if ((shared_status != 0 && shared_status != 2)); then
      fail "corpus row ${shared_id}: the hook exits 0 or 2" \
        "exit ${shared_status}: ${shared_stderr:0:120}"
      continue
    fi
    if ((shared_status == 2)) || [[ "${shared_stdout}" == *'"deny"'* ]]; then
      shared_got="refuse"
    else
      shared_got="allow"
    fi
    if corpus_over_refused "${shared_id}"; then
      shared_over_refused_seen+="${shared_id} "
      assert_equal "corpus row ${shared_id}: allow in the corpus, refused here on purpose: ${shared_row_command}" \
        "${shared_verdict} ${shared_got}" "allow refuse"
    else
      assert_equal "corpus row ${shared_id}: ${shared_verdict} ${shared_row_command}" \
        "${shared_got}" "${shared_verdict}"
    fi
  done < <(jq -c '.rows[]' "${CORPUS}")
  rm -rf "${shared_project}"

  # Every listed id must have been run above, or it sits on the list checking
  # nothing (a row the corpus renamed or dropped, or one the allow list stopped
  # reaching).
  for shared_id in "${CORPUS_OVER_REFUSED[@]}"; do
    if [[ " ${shared_over_refused_seen}" == *" ${shared_id} "* ]]; then
      pass "over-refused corpus row ${shared_id} was run"
    else
      fail "over-refused corpus row ${shared_id} was run" \
        "no reachable corpus row has this id; remove it from CORPUS_OVER_REFUSED"
    fi
  done

  # If the allow list stopped covering `git diff`, every row would be skipped
  # and the checks above would pass on nothing.
  if ((shared_applied >= 20)); then
    pass "enough corpus rows apply here to mean something (${shared_applied})"
  else
    fail "enough corpus rows apply here to mean something" "only ${shared_applied} apply"
  fi
else
  fail "${CORPUS} is present and ${CLAUDE_SETTINGS} was readable" \
    "the shared corpus did not run"
fi

printf '1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${checks_run}"

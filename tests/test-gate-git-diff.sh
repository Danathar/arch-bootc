#!/usr/bin/env bash
set -uo pipefail

# Run .claude/hooks/gate-git-diff.sh, the PreToolUse hook on Bash that
# .claude/settings.json registers, against the commands it exists to refuse
# and the ordinary commands it has to leave unprompted.
#
# The hook is extracted from settings.json with jq and *run*, not grepped. A
# hook asserted by grep is a hook asserted by its own comment: the string can
# be present and the hook still never refuse anything. It is also run with jq
# off PATH, since a gate that reads its input with a tool it does not check for
# is a gate that disappears on any host that lacks it. Every exposure the hook
# closes is demonstrated first, in a temporary directory of this file's own:
# git printing a plain file, git writing a file through --output=FILE, bash
# rebuilding both out of a brace. And each rule of the hook is mutation-tested
# at the end -- one line rewritten into a temporary copy, and a corpus row that
# then stops being refused -- so a rule that no row holds is reported rather
# than assumed.
#
# This file used to be a group of tests/check-invariants.sh. It lives here
# because it is not a static check: it runs git against mktemp fixtures,
# initialises throwaway repositories, writes a fixture directory into the
# checkout, and takes about two minutes, against the few seconds the rest of
# that script needs to read the tree. run-tests.sh is what runs the behavioral
# suites, and check-coverage.sh traces what run-tests.sh executes, so the hook
# has a coverage floor in .coverage-thresholds.json only from here. The static
# half stayed behind: check-invariants.sh still pins the settings.json entries
# the hook's rationale depends on and that the hook file exists and is
# executable.
#
# What the hook is for, so the rows below read as a whole rather than a list:
#
# .claude/settings.json denies the Read tool this repository's secret-shaped
# paths -- `Read(./cosign.key)`, `Read(./.env)`, `Read(./**/*.pem)`,
# `Read(./**/id_ed25519)` -- and allows, with no prompt, `Bash(git diff*)`.
#
# `git diff <a> <b>` in its two-path mode compares the operands as plain files
# rather than as repository content. It works on untracked files, on gitignored
# files, and on paths outside the checkout entirely, and it prints their
# contents as `+` lines. The two halves are not the same tool: the deny rules
# gate the Read tool and have nothing to say about what an allowed Bash command
# then opens, so they are not weakened here -- they are simply never consulted.
# `cat ./cosign.key` would prompt; the diff form would not.
#
# No permission pattern closes that, because patterns match by command prefix
# and flags may appear in any order: `Bash(git diff --no-index*)` matches one
# spelling and misses `git diff --stat --no-index ...` and
# `git --no-pager diff --no-index ...`, and a rule that looks like a control
# while gating one argument ordering is worse than no rule. A `PreToolUse` hook
# is handed the whole command, so it can look at the invocation rather than at
# a prefix of it.
#
# Two ways a hook that merely searched the command string for `--no-index`
# still let the read through, both asserted below because both were once true
# of the hook in this repository:
#
#   * The mode needs no flag. Git enters it on its own when two operands are
#     given and either one is not repository content, so
#     `git diff /dev/null ./cosign.key` prints the file with `--no-index`
#     nowhere in the command.
#   * The shell rewrites the command before git sees it. `--no-'index'` and
#     `--no-\index` reach git as `--no-index` while a substring test on the
#     spelling that was typed finds neither.
#   * `--` does not end the mode. Git's own scan consumes a leading `--` and
#     applies the two-operand test to what follows, so
#     `git diff -- /dev/null ./cosign.key` prints the file too. Only an operand
#     before the `--` stops that scan (`git diff HEAD -- path` is safe).
#   * A lone `-` is an operand, not a flag: git reads it as stdin and counts it
#     toward the same two-operand test, so `git diff /etc/shadow -` prints the
#     file. Skipping every dash-prefixed word -- correct for `--stat` and `-U0`,
#     which git would reject if they were not flags -- left the count one short
#     of the refusal. `git diff ../<checkout>/cosign.key -` reaches a denied
#     path inside this repository by the same route, because git's
#     inside-the-repo test works on the spelling and a `..` that climbs out and
#     back in reads as outside.
#
# So the hook resolves the operands instead: two operands where any one of them
# is not a revision is the plain-file form, which is what separates
# `git diff main feature` from `git diff /dev/null ./cosign.key`. After a bare
# `--`, where no word can be a revision, it applies git's own test: two or more
# words with any one outside the working tree.
#
# What this cannot see: a command that builds its arguments at runtime
# (`git diff $x $y`), one that leaves the repository first, and anything a
# command reads once it has started. This re-gates the one pre-approved command
# that reaches past the deny list; it is not a sandbox.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# Every path below is spelled relative to the checkout, the way the agent
# would type it and the way the hook resolves it, so run from there.
cd -- "${REPO_ROOT}" || exit 1

JUSTFILE="Justfile"
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

group "Read boundary on allowed Bash (.claude/hooks/gate-git-diff.sh, run against what it refuses and what it permits)"

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
  # First, that the exposure is real rather than asserted. If this ever stops
  # printing the fixture, the rest of the group is about nothing.
  no_index_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${no_index_dir}/fake.key"
  no_index_output="$(git diff --no-index -- /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  # And again with no flag at all, which is the form the first version of this
  # hook missed. Run from inside the checkout, the way the agent would.
  implicit_output="$(git diff /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  # And behind a bare `--`, which a version of the hook read as the start of
  # repository pathspecs and stopped inspecting.
  dashdash_output="$(git diff -- /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  # And with the second operand written as `-`, which git reads as stdin and
  # counts like any other operand. stdin is closed here so the fixture cannot
  # block; the file's own lines are what git prints, on the `-` side of the
  # comparison rather than the `+` side.
  stdin_operand_output="$(git diff "${no_index_dir}/fake.key" - 2>/dev/null </dev/null)"
  # Use only synthetic contents, including for paths inside this checkout.
  # Git treats a spelling that climbs out and returns by name as outside;
  # realpath -m -s erases that distinction. Keep both operands in the checkout
  # so an already-outside operand cannot accidentally make the hook test pass.
  path_fixture_dir="$(mktemp -d "${REPO_ROOT}/tests/.git-diff-paths.XXXXXX")"
  path_fixture="${path_fixture_dir#"${REPO_ROOT}/"}"
  checkout_name="$(basename -- "$(git rev-parse --show-toplevel)")"
  printf 'SYNTHETIC-PATH-FIXTURE\n' >"${path_fixture_dir}/fake.key"
  : >"${path_fixture_dir}/empty"
  mkdir "${path_fixture_dir}/inside"
  ln -s "${no_index_dir}" "${path_fixture_dir}/outside"
  ln -s inside "${path_fixture_dir}/inside-link"
  ln -s "${path_fixture_dir}" "${no_index_dir}/back-inside"
  reentry_path="../${checkout_name}/${path_fixture}"
  reentry_output="$(git diff -- "${reentry_path}/fake.key" "${reentry_path}/empty" 2>/dev/null)"
  reentry_stdin_output="$(git diff -- "${reentry_path}/fake.key" - 2>/dev/null </dev/null)"
  inside_stdin_output="$(git diff -- "${path_fixture}/fake.key" - 2>/dev/null </dev/null)"
  if grep -q '^-SYNTHETIC-PATH-FIXTURE$' <<<"${reentry_output}"; then
    pass "git diff behind -- prints an inside file spelled as a climb out and back in"
  else
    fail "git diff behind -- prints an inside file spelled as a climb out and back in" \
      "this git no longer treats the re-entry spelling as outside; re-derive the lexical check"
  fi
  if grep -q '^-SYNTHETIC-PATH-FIXTURE$' <<<"${reentry_stdin_output}"; then
    pass "git diff behind -- prints the re-entry file against stdin too"
  else
    fail "git diff behind -- prints the re-entry file against stdin too" \
      "the re-entry path plus stdin did not print the synthetic contents"
  fi
  assert_equal "an inside spelling against stdin does not print the untracked fixture" \
    "${inside_stdin_output}" ""
  if grep -q '^+SECRET-LINE-1$' <<<"${no_index_output}"; then
    pass "git diff --no-index prints the contents of a plain file outside the index"
  else
    fail "git diff --no-index prints the contents of a plain file outside the index" \
      "this git no longer reads the path that way; re-derive what the hook below is for"
  fi

  if grep -q '^+SECRET-LINE-1$' <<<"${implicit_output}"; then
    pass "git diff prints the same contents with no --no-index flag present"
  else
    fail "git diff prints the same contents with no --no-index flag present" \
      "this git no longer enters the mode implicitly; re-derive the operand check in the hook"
  fi

  if grep -q '^+SECRET-LINE-1$' <<<"${dashdash_output}"; then
    pass "git diff prints the same contents with the two paths behind a bare --"
  else
    fail "git diff prints the same contents with the two paths behind a bare --" \
      "this git no longer enters the mode behind --; re-derive the after-dashdash check in the hook"
  fi

  if grep -q '^-SECRET-LINE-1$' <<<"${stdin_operand_output}"; then
    pass "git diff prints the same contents when the second operand is the stdin dash"
  else
    fail "git diff prints the same contents when the second operand is the stdin dash" \
      "this git no longer counts a lone - as an operand; re-derive why the operand scan stops skipping it"
  fi

  # The same again for the *write* primitive in the same command family, which
  # is a separate exposure and not a variation on the one above. `--output=FILE`
  # sends the diff to the path it names instead of to stdout, so an allowed,
  # unprompted call overwrites any file this uid can reach -- `cosign.pub`, the
  # signature trust anchor copied into the image, `.claude/settings.json`, the
  # hook itself. Everything is written inside a temporary directory of this
  # fixture's own; nothing in the checkout is touched.
  output_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${output_dir}/fake.key"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-diff"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-log"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-show"
  git diff --output="${output_dir}/victim-diff" -- /dev/null "${output_dir}/fake.key" >/dev/null 2>&1

  # git log and git show are run against a repository this fixture builds
  # rather than against this checkout, and the difference is not fastidiousness:
  # CI checks out a single grafted *merge* commit, and git refuses `--output`
  # for a combined diff -- git 2.39 only after truncating the file it named,
  # git 2.55 before opening it. Which of those a host does is not the property
  # under test. One ordinary commit is, and it is also the shape the issue
  # describes: author a commit, then write its diff over the target, so the `+`
  # lines carry what the caller chose.
  payload_repo="${output_dir}/repo"
  git -c init.defaultBranch=main init --quiet "${payload_repo}" >/dev/null 2>&1
  printf 'PAYLOAD-LINE-1\n' >"${payload_repo}/committed"
  git -C "${payload_repo}" add committed >/dev/null 2>&1
  git -C "${payload_repo}" -c user.name=invariants \
    -c user.email=invariants@example.invalid -c commit.gpgsign=false \
    commit --quiet -m fixture >/dev/null 2>&1
  # No `diff` anywhere in this one: git log carries the same flag, and the
  # operand scan in the hook only ever tracked the diff subcommand.
  git -C "${payload_repo}" log -p --output="${output_dir}/victim-log" -1 >/dev/null 2>&1
  # And git show, which the issue reports as not writing at all. It does: it
  # rejects the flag only for a combined diff, and writes an ordinary commit's
  # diff in full -- which is why "git show rejects --output" is not a reason to
  # leave it ungated.
  git -C "${payload_repo}" show --output="${output_dir}/victim-show" HEAD >/dev/null 2>&1

  output_diff_written="$(cat "${output_dir}/victim-diff" 2>/dev/null)"
  output_log_written="$(cat "${output_dir}/victim-log" 2>/dev/null)"
  output_show_written="$(cat "${output_dir}/victim-show" 2>/dev/null)"
  rm -rf "${output_dir}"

  if grep -q '^+SECRET-LINE-1$' <<<"${output_diff_written}"; then
    pass "git diff --output=FILE writes content the caller chose over the file it names"
  else
    fail "git diff --output=FILE writes content the caller chose over the file it names" \
      "this git no longer redirects the diff to that path; re-derive the --output refusal in the hook"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${output_log_written}"; then
    pass "git log --output=FILE writes a committed payload over the file it names, with no git diff in the command"
  else
    fail "git log --output=FILE writes a committed payload over the file it names, with no git diff in the command" \
      "the file does not hold the commit's + lines; re-derive why the refusal covers the whole git invocation"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${output_show_written}"; then
    pass "git show --output=FILE writes a committed payload over the file it names"
  else
    fail "git show --output=FILE writes a committed payload over the file it names" \
      "this git no longer accepts --output for an ordinary commit; re-derive the git show case"
  fi

  # Brace expansion, which rebuilds both exposures above out of four
  # characters. Bash expands braces before it splits words, so one word in a
  # scan that reads the typed string is several words to git: the operand count
  # stays at one while git receives two, and a flag name split down the middle
  # matches nothing while git receives it whole. Neither needs a variable or a
  # subshell, so neither is one of the runtime-built arguments the hook says it
  # cannot see. Demonstrated rather than described, in a temporary directory of
  # this fixture's own.
  brace_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${brace_dir}/fake.key"
  printf 'ORIGINAL-CONTENT\n' >"${brace_dir}/victim-brace"

  brace_repo="${brace_dir}/repo"
  git -c init.defaultBranch=main init --quiet "${brace_repo}" >/dev/null 2>&1
  printf 'PAYLOAD-LINE-1\n' >"${brace_repo}/committed"
  git -C "${brace_repo}" add committed >/dev/null 2>&1
  git -C "${brace_repo}" -c user.name=invariants \
    -c user.email=invariants@example.invalid -c commit.gpgsign=false \
    commit --quiet -m fixture >/dev/null 2>&1

  # The braces are literal to this script -- they sit inside double quotes --
  # and are expanded by the inner shell, which is the point being shown.
  # </dev/null so a host where the brace stops expanding cannot leave the run
  # waiting on the stdin operand.
  brace_read="$(bash -c "git diff {/dev/null,${brace_dir}/fake.key}" 2>/dev/null </dev/null)"
  bash -c "git -C '${brace_repo}' log -p --outpu{t,t}=${brace_dir}/victim-brace -1" \
    >/dev/null 2>&1 </dev/null
  brace_written="$(cat "${brace_dir}/victim-brace" 2>/dev/null)"
  rm -rf "${brace_dir}"

  if grep -q '^+SECRET-LINE-1$' <<<"${brace_read}"; then
    pass "one braced word reaches git as the two operands of the plain-file read"
  else
    fail "one braced word reaches git as the two operands of the plain-file read" \
      "this shell no longer expands the brace into two operands; re-derive the brace refusal in the hook"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${brace_written}"; then
    pass "a brace split through --outpu{t,t}= reaches git as --output and writes the file it names"
  else
    fail "a brace split through --outpu{t,t}= reaches git as --output and writes the file it names" \
      "the file does not hold the commit's + lines; re-derive why a split flag name still reaches git"
  fi

  bash_hooks=()
  while IFS= read -r hook_command; do
    [[ -n "${hook_command}" ]] && bash_hooks+=("${hook_command}")
  done < <(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.type == "command") | .command' "${CLAUDE_SETTINGS}")

  if ((${#bash_hooks[@]} > 0)); then
    pass "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash"
  else
    fail "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash" \
      "nothing is handed the command string, so every flag ordering above is unprompted"
  fi

  # Runs every Bash PreToolUse hook against PAYLOAD on stdin, the way Claude
  # Code invokes them. Exit status 2 is what Claude Code reads as "refuse this
  # call and show stderr to the agent", so a refusal is the highest status seen
  # plus the text the agent would be shown.
  #
  # CLAUDE_PROJECT_DIR is set the way Claude Code sets it, to the project
  # root. The settings entry spells the hook as
  # "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/gate-git-diff.sh", and the
  # fallback `.` is the same directory here -- but check-coverage.sh counts a
  # traced line only when BASH_SOURCE starts with the absolute checkout path,
  # so the relative spelling would leave every line of the hook untraced and
  # its floor in .coverage-thresholds.json unreachable.
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

  assert_hook_refuses() {
    local description="$1" command="$2"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${payload}"
    if ((hook_status == 2)) && [[ -n "${hook_stderr}" ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted exit 2 and an explanation"
    fi
  }

  # Exit 2 alone cannot tell this hook's two refusals apart, and the space form
  # `git diff --output /tmp/x HEAD~1 HEAD` was already refused before there was
  # a rule for it -- by accident, because the operand scan counted the path as
  # a second unresolved operand. Asserting which refusal fired is what
  # separates "refused for the stated reason" from "refused today, and
  # permitted the moment that accident stops holding".
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

  assert_hook_payload_permits() {
    local description="$1" payload="$2"
    run_bash_hooks "${payload}"
    if ((hook_status == 0)) && [[ -z "${hook_stderr}" ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted a silent exit 0"
    fi
  }

  assert_hook_permits() {
    local description="$1" command="$2"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    assert_hook_payload_permits "${description}" "${payload}"
  }

  # The spelling the allow rule admits today, plus the orderings a prefix deny
  # would miss.
  assert_hook_refuses "the hook refuses git diff --no-index against ./cosign.key" \
    'git diff --no-index -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flag after another flag" \
    'git diff --stat --no-index -- /dev/null ./.env'
  assert_hook_refuses "the hook refuses the flag behind a git-level option" \
    'git --no-pager diff --no-index -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flag reached outside the checkout" \
    'git diff --no-color --no-index -- /dev/null /home/someone/.ssh/id_ed25519'

  # The flagless form. Git enters the same mode on its own, so a gate that only
  # matched the flag string left the disclosure route exactly as it found it.
  assert_hook_refuses "the hook refuses the two-path form with no flag at all" \
    'git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flagless form reached outside the checkout" \
    'git diff /dev/null /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses two bare operands that are not revisions" \
    'git diff cosign.key .env'
  assert_hook_refuses "the hook refuses the flagless form behind another command" \
    'ls -l && git diff /dev/null ./cosign.key'

  # The same mode behind a bare `--`. Git consumes a leading `--` and applies
  # its two-operand test to the words after it, so treating them as pathspecs
  # that never open a plain file let this exact form through once.
  assert_hook_refuses "the hook refuses the two-path form behind a bare --" \
    'git diff -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the -- form after another flag" \
    'git diff --stat -- /dev/null ./.env'
  assert_hook_refuses "the hook refuses the -- form reached outside the checkout" \
    'git diff -- /dev/null /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses the -- form with one operand inside the checkout" \
    'git diff -- ./AGENTS.md /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses the -- form that climbs out of the checkout" \
    'git diff -- ../outside ./cosign.key'

  # #297: classify the spelling before normalizing it, then also resolve
  # symlinks. The symlink and bare-stdin refusals are conservative: Git 2.55
  # keeps the inside spellings as pathspecs, but we require both containment
  # checks to agree rather than depend on that treatment.
  assert_hook_refuses "the hook refuses two re-entry paths behind --" \
    "git diff -- ../${checkout_name}/cosign.key ../${checkout_name}/AGENTS.md"
  assert_hook_refuses "the hook refuses a re-entry path against stdin behind --" \
    "git diff -- ../${checkout_name}/cosign.key -"
  assert_hook_refuses "the hook refuses re-entry starting inside tests behind --" \
    "git diff -- ./tests/../../${checkout_name}/cosign.key -"
  assert_hook_refuses "the hook refuses the demonstrated synthetic re-entry comparison" \
    "git diff -- ${reentry_path}/fake.key ${reentry_path}/empty"
  assert_hook_refuses "the hook counts stdin as outside even with an inside first operand" \
    'git diff -- ./AGENTS.md -'
  assert_hook_refuses "the hook counts stdin as outside in the first position too" \
    'git diff -- - ./AGENTS.md'
  assert_hook_refuses "the hook refuses a leading symlink directory pointing outside" \
    "git diff -- ${path_fixture}/outside/fake.key ${path_fixture}/empty"
  assert_hook_refuses "the hook refuses an outside spelling that resolves back inside" \
    "git diff -- ${no_index_dir}/back-inside/fake.key ${path_fixture}/empty"
  assert_hook_permits "a directory symlink staying inside the checkout is still unprompted" \
    "git diff -- ${path_fixture}/inside-link ./AGENTS.md"
  assert_hook_permits "a nonexistent inside path still works as a repository pathspec" \
    "git diff -- ${path_fixture}/missing ./AGENTS.md"
  assert_hook_permits "two dots within a filename are not a parent component" \
    'git diff -- ./file..name ./AGENTS.md'
  rm -rf -- "${path_fixture_dir}" "${no_index_dir}"

  # The stdin operand. `-` is the one word git diff counts as an operand and an
  # option scan drops, so these forms reached the plain-file mode with the
  # operand count stuck at one. The last of them is the same route back into a
  # path the deny rules name: git's inside-the-repo test reads the spelling, so
  # a `..` that leaves the checkout and returns to it counts as outside.
  assert_hook_refuses "the hook refuses the stdin dash as the second operand" \
    'git diff /etc/shadow -'
  assert_hook_refuses "the hook refuses the stdin dash reached outside the checkout" \
    'git diff /home/someone/.ssh/id_ed25519 -'
  assert_hook_refuses "the hook refuses the stdin dash after another flag" \
    'git diff --stat /etc/shadow -'
  assert_hook_refuses "the hook refuses the stdin dash as the first operand" \
    'git diff - /etc/shadow'
  assert_hook_refuses "the hook refuses the stdin dash behind an unspaced &&" \
    'ls&&git diff /etc/shadow -'
  assert_hook_refuses "the hook refuses a denied path spelled as a climb out of the checkout" \
    'git diff ../elsewhere/cosign.key -'

  # Brace expansion. Asserted by message rather than by exit status, because
  # several of these spellings are refused for an unrelated reason today -- the
  # operand scan counts the unbraced words on either side -- and that accident
  # stops holding the moment the braced word is the whole comparison.
  assert_hook_refuses_naming "the hook refuses two operands folded into one braced word" \
    'git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses the braced two-operand form behind a bare --" \
    'git diff -- {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace inside one operand of a comparison" \
    'git diff /dev/nul{l,l} ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses the braced form behind an unspaced &&" \
    'ls&&git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --no-index" \
    'git diff --no-inde{x,x} -- /dev/null ./cosign.key' 'expands braces'
  # The write half, which needs no operand arithmetic at all: a brace anywhere
  # in the flag name hands git --output whole.
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git log" \
    'git log -p --outpu{t,t}=cosign.pub -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git show" \
    'git show --outpu{t,t}=/tmp/written HEAD' 'expands braces'
  # #313: the brace scope ends where bash ends the command. The first version
  # of this rule latched on the word `git` and held to the end of the string,
  # so a jq filter or awk program in a *later* command of the same string was
  # refused as though git would receive it -- `git log -1 && jq '{a:1}'` was
  # blocked outright. A brace is git's only between a `git` word and the next
  # unquoted `;`, `&`, `|`, `(`, `)`, newline or backtick; the scope reopens
  # at the next `git` word, so a second git command in the string is held to
  # the same rule and one that is piped into is not excused by the command in
  # front of it.
  assert_hook_permits "a brace in a later non-git command of the same string is unprompted (#313)" \
    'git status --short && awk "{print}" packages-base.txt'
  assert_hook_permits "a jq filter after a git call is unprompted (#313)" \
    "git log -1 && jq '{a:1}'"
  assert_hook_permits "an awk program piped from git diff is unprompted" \
    "git diff HEAD | awk '{print \$1}'"
  assert_hook_permits "a jq filter piped from a reflog diff is unprompted" \
    "git diff HEAD@{1} | jq '{a,b}'"
  assert_hook_permits "a brace in the command piped into git is unprompted" \
    "jq '{a,b}' < f | git diff --stat"
  assert_hook_refuses_naming "the hook refuses a brace in a second git command after ;" \
    'git log -1; git diff {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command that is piped into" \
    'echo x | git diff {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command on a second line" \
    $'git log -1\ngit diff {a,b}' 'expands braces'
  # shellcheck disable=SC2016 # the literal backticks are the command string
  # handed to the hook, not anything this script expands.
  assert_hook_refuses_naming "the hook refuses a brace in a git command inside backticks" \
    'git log -1 `git diff {a,b}`' 'expands braces'
  # And the refusal is scoped to git invocations, so a brace in a command
  # string that never calls git is untouched. These are the ordinary shapes --
  # an awk program, a jq filter -- that a whole-string brace refusal would
  # have broken.
  assert_hook_permits "an awk program in braces is still unprompted" \
    'awk "{print}" packages-base.txt'
  assert_hook_permits "a jq object filter in braces is still unprompted" \
    'jq "{forkProcessing: .forkProcessing}" renovate.json'
  assert_hook_permits "a brace expansion outside a git call is still unprompted" \
    'ls packages-{base,kde}.txt'

  # #312: bash expands a brace only when a comma or a `..` range sits inside
  # it. Every other brace is a literal, and git's own `@{...}` revision syntax
  # -- `HEAD@{1}`, `main@{upstream}`, `@{-1}`, `@{2.days.ago}` -- is spelled
  # with exactly that literal form, so refusing every brace blocked the
  # ordinary diff against the previous commit for no gain. One operand each,
  # so nothing here depends on the reflog this checkout happens to have; the
  # last case pins that a `{` which never closes is a literal too.
  assert_hook_permits "git diff against @{upstream} is unprompted (#312)" \
    'git diff @{upstream}'
  assert_hook_permits "git log of a reflog entry is unprompted (#312)" \
    'git log HEAD@{2}'
  assert_hook_permits "git diff HEAD@{1} with a pathspec is unprompted" \
    'git diff HEAD@{1} -- AGENTS.md'
  assert_hook_permits "git log main@{upstream} is unprompted" \
    'git log main@{upstream} -1'
  assert_hook_permits "git rev-parse @{-1} is unprompted" \
    'git rev-parse @{-1}'
  assert_hook_permits "git log @{2.days.ago} is unprompted" \
    'git log @{2.days.ago} -1'
  assert_hook_permits "an unclosed brace in a git word is a literal and unprompted" \
    'git log HEAD@{1 -1'
  # The line is drawn where bash draws it, and errs toward refusing: `@{1,2}`
  # reads as revision syntax and is two words to bash; `{x..x}` is a
  # one-element sequence that rebuilds a flag; a comma nested one level down
  # still expands; `${VAR}` is a runtime-built argument; bash pairs a `{` with
  # the last `}` it can, so `{a},b}` expands and a depth counter that closed
  # at the first `}` never saw the comma; a quoted `;` inside the brace is
  # part of the word bash expands, while a split on the quote-stripped string
  # cut the word in two before the brace test saw it. A `..` between two
  # reflog entries has the refused shape and is refused although bash would
  # leave it alone; the message names the spelling to use instead.
  assert_hook_refuses_naming "the hook refuses @{1,2}, which bash expands" \
    'git diff HEAD@{1,2}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a one-element range that rebuilds --no-index" \
    'git diff --no-inde{x..x} /dev/null ./AGENTS.md' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a nested brace expansion" \
    'git diff {{/dev/null,./cosign.key}}' 'expands braces'
  # shellcheck disable=SC2016 # the literal ${SECRET} is the point
  assert_hook_refuses_naming "the hook refuses \${VAR} inside a git invocation" \
    'git diff ${SECRET} HEAD' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace closed at its last }" \
    'git diff {a},b} /dev/null ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git log via {}" \
    'git log {--format=%h},--output=cosign.pub} -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a quoted operator inside a brace" \
    "git diff {/tmp/reference';',./cosign.key}" 'expands braces'
  assert_hook_refuses_naming "the hook refuses a quoted space inside a brace" \
    "git log -p --outpu{t,'t '}=cosign.pub -1" 'expands braces'
  assert_hook_refuses_naming "the hook refuses .. between two reflog entries and names HEAD~2..HEAD~1" \
    'git log HEAD@{2}..HEAD@{1}' 'HEAD~2..HEAD~1'

  # The brace rule against bash itself rather than against a label. Each
  # corpus word is handed to bash verbatim, as an agent would type it, and
  # bash says whether it becomes more than one word; every word bash expands
  # must be refused, and every word of the literal set must be allowed. A word
  # in neither class is held only to the first rule, so an over-refusal there
  # is not a failure. The counts keep the check from going vacuous if the
  # corpus shrinks or bash reads it differently. `OPERANDS` is set so that
  # `${OPERANDS}` splits into two words the way a runtime-built argument would.
  literal_brace_words=(
    'HEAD@{1}'
    'main@{upstream}'
    '@{-1}'
    '@{2.days.ago}'
    'HEAD@{1'
  )
  # shellcheck disable=SC2016 # every word here is a spelling handed to bash
  # verbatim; ${OPERANDS} and '{print $1}' are meant to reach it unexpanded.
  brace_corpus=(
    "${literal_brace_words[@]}"
    'HEAD@{2}..HEAD@{1}'
    '{a,b}'
    '{1..3}'
    'x{1..3}y'
    'a{,b}'
    '{{a,b}}'
    '--no-inde{x,x}'
    '--outpu{t,t}=FILE'
    'HEAD@{1,2}'
    '{--src-prefix=x},--no-index}'
    '{a},b}'
    "{/tmp/reference';',./cosign.key}"
    '{a",",b}'
    '{a\,b,c}'
    '"{a,b}"'
    "'{a,b}'"
    '{a,b'
    '{a,b}}'
    '{{a,b}'
    '${OPERANDS}'
    '--output={a,b}'
    '--output=x{,}'
    "'{print \$1}'"
    "'{a:1}'"
    "'{a: .x, b: .y}'"
  )
  bash_expands() {
    local expanded
    expanded="$(OPERANDS='/dev/null ./cosign.key' bash --norc --noprofile -c 'printf "%s\0" '"$1" 2>/dev/null | tr -cd '\0' | wc -c)" || return 1
    ((expanded > 1))
  }
  corpus_expanding=0
  corpus_refused=1
  corpus_failed=''
  for corpus_word in "${brace_corpus[@]}"; do
    bash_expands "${corpus_word}" || continue
    corpus_expanding=$((corpus_expanding + 1))
    corpus_payload="$(jq -nc --arg c "git diff ${corpus_word}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 2)) || [[ "${hook_stderr}" != *'expands braces'* ]]; then
      corpus_refused=0
      corpus_failed+="${corpus_word} (exit ${hook_status}) "
    fi
  done
  if ((${#brace_corpus[@]} >= 25 && corpus_expanding >= 15)); then
    pass "the brace corpus is large enough to mean something (${#brace_corpus[@]} words, ${corpus_expanding} that bash expands)"
  else
    fail "the brace corpus is large enough to mean something (${#brace_corpus[@]} words, ${corpus_expanding} that bash expands)" \
      "wanted at least 25 words of which bash expands at least 15; the check has gone vacuous"
  fi
  if ((corpus_refused)); then
    pass "every corpus word bash expands is refused inside a git invocation"
  else
    fail "every corpus word bash expands is refused inside a git invocation" \
      "bash expands these into more than one word and the hook let them through: ${corpus_failed}"
  fi
  literal_allowed=1
  literal_failed=''
  for literal_word in "${literal_brace_words[@]}"; do
    if bash_expands "${literal_word}"; then
      literal_allowed=0
      literal_failed+="${literal_word} (bash expands it) "
      continue
    fi
    corpus_payload="$(jq -nc --arg c "git log ${literal_word} -1" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 0)) || [[ -n "${hook_stderr}" ]]; then
      literal_allowed=0
      literal_failed+="${literal_word} (exit ${hook_status}) "
    fi
  done
  if ((literal_allowed)); then
    pass "every literal-brace word bash leaves alone is unprompted inside a git invocation"
  else
    fail "every literal-brace word bash leaves alone is unprompted inside a git invocation" \
      "${literal_failed}"
  fi

  # An unquoted leading `~` is $HOME to bash and a literal `~` to the gate,
  # which `realpath -m -s` resolved to `<checkout>/~/...`, an inside path. So
  # `git diff -- ~/.aws/credentials ~/.bashrc` counted two operands, found
  # both inside the working tree, and exited 0, and bash then handed git two
  # files from the home directory, which it printed as a plain-file diff. The
  # ShellCheck operand scan below already refuses that word; the git scope now
  # does the same. Shown first, against a throwaway HOME of this fixture's
  # own -- never the real $HOME.
  git_tilde_home="$(mktemp -d)"
  mkdir -p "${git_tilde_home}/.aws"
  printf 'SYNTHETIC_GIT_TILDE_SECRET=synthetic-value-4\n' >"${git_tilde_home}/.aws/credentials"
  printf 'export FIXTURE=1\n' >"${git_tilde_home}/.bashrc"
  git_tilde_output="$(HOME="${git_tilde_home}" bash --norc --noprofile -c 'git diff -- ~/.aws/credentials ~/.bashrc' 2>&1 </dev/null || true)"
  rm -rf "${git_tilde_home}"
  if grep -q '^-SYNTHETIC_GIT_TILDE_SECRET=synthetic-value-4$' <<<"${git_tilde_output}"; then
    pass "git diff -- ~/path ~/path prints the files under \$HOME, which is not the literal ~ the gate resolves"
  else
    fail "git diff -- ~/path ~/path prints the files under \$HOME, which is not the literal ~ the gate resolves" \
      "the synthetic line did not appear; re-derive why an unquoted leading ~ is refused in a git invocation"
  fi
  for tilde_command in \
    'git diff -- ~/.aws/credentials ~/.bashrc' \
    'git diff ~/.bashrc ~/.aws/credentials' \
    'git diff -- ~ ~/.bashrc' \
    'git diff -- ~root/.bashrc ./cosign.pub' \
    'git log -p -- ~/.ssh/config' \
    'git show HEAD -- ~/.ssh/config' \
    'git diff HEAD -- ~/.bashrc' \
    'git status; git diff -- ~/.aws/credentials ~/.bashrc' \
    'echo x | git diff -- ~/.aws/credentials ~/.bashrc'; do
    assert_hook_refuses_naming "the hook refuses an unquoted leading ~ in a git invocation: ${tilde_command}" \
      "${tilde_command}" 'unquoted leading ~'
  done
  for tilde_command in \
    'git diff HEAD@{1}' \
    'git diff HEAD~1' \
    "git diff -- 'lit~eral'" \
    "git diff -- '~/x'" \
    'git diff -- "~/x"' \
    'git diff -- \~/x' \
    'git diff HEAD -- x~' \
    'git show HEAD:~/x' \
    'ls ~/.bashrc; git diff HEAD' \
    'echo x > out; git diff HEAD'; do
    assert_hook_permits "a quoted, escaped or non-leading ~ is the literal word and is unprompted: ${tilde_command}" \
      "${tilde_command}"
  done
  # The containment test never resolves a leading `~` inside the tree, quoted
  # or not, so two quoted tildes after a `--` are refused as the plain-file
  # form although bash would hand git two literal paths: the stricter
  # direction, taken on purpose (review on zfs-kinoite-complex#220).
  assert_hook_refuses_naming "two quoted tildes after -- are refused as the plain-file form" \
    "git diff -- '~/x' '~/y'" 'plain files'
  # The tilde rule against bash itself, the way the brace corpus is checked:
  # every word bash rewrites must be refused, every word of the literal set
  # must be allowed, and a word in neither class is held only to the first
  # rule. Each word is handed to bash verbatim under a HOME that does not
  # exist, which changes nothing about whether bash expands it.
  literal_tilde_words=(
    "'~/x'"
    '"~/x"'
    '\~/x'
    'HEAD~1'
    'HEAD~2..HEAD~1'
    'lit~eral'
    'x~'
  )
  # shellcheck disable=SC2088 # the quoted tildes are corpus words, not paths this fixture opens
  tilde_corpus=(
    "${literal_tilde_words[@]}"
    '~'
    '~/.aws/credentials'
    '~/.bashrc'
    '~root/.bashrc'
    '~/'
  )
  bash_rewrites() {
    local typed stripped
    typed="$(HOME=/nonexistent-home bash --norc --noprofile -c 'printf "%s" '"$1" 2>/dev/null)" || return 1
    stripped="${1//[\'\"\\]/}"
    [[ "${typed}" != "${stripped}" ]]
  }
  tilde_rewritten=0
  tilde_refused=1
  tilde_failed=''
  for corpus_word in "${tilde_corpus[@]}"; do
    bash_rewrites "${corpus_word}" || continue
    tilde_rewritten=$((tilde_rewritten + 1))
    corpus_payload="$(jq -nc --arg c "git diff -- ${corpus_word} ./cosign.pub" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 2)) || [[ "${hook_stderr}" != *'unquoted leading ~'* ]]; then
      tilde_refused=0
      tilde_failed+="${corpus_word} (exit ${hook_status}) "
    fi
  done
  if ((tilde_rewritten >= 4)); then
    pass "the tilde corpus is large enough to mean something (${#tilde_corpus[@]} words, ${tilde_rewritten} that bash rewrites)"
  else
    fail "the tilde corpus is large enough to mean something (${#tilde_corpus[@]} words, ${tilde_rewritten} that bash rewrites)" \
      "wanted at least 4 words bash rewrites; the check has gone vacuous"
  fi
  if ((tilde_refused)); then
    pass "every corpus word bash tilde-expands is refused inside a git invocation"
  else
    fail "every corpus word bash tilde-expands is refused inside a git invocation" \
      "bash rewrites these and the hook let them through: ${tilde_failed}"
  fi
  tilde_literal_allowed=1
  tilde_literal_failed=''
  for literal_word in "${literal_tilde_words[@]}"; do
    if bash_rewrites "${literal_word}"; then
      tilde_literal_allowed=0
      tilde_literal_failed+="${literal_word} (bash rewrites it) "
      continue
    fi
    corpus_payload="$(jq -nc --arg c "git log -1 -- ${literal_word}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 0)) || [[ -n "${hook_stderr}" ]]; then
      tilde_literal_allowed=0
      tilde_literal_failed+="${literal_word} (exit ${hook_status}) "
    fi
  done
  if ((tilde_literal_allowed)); then
    pass "every literal-tilde word bash leaves alone is unprompted inside a git invocation"
  else
    fail "every literal-tilde word bash leaves alone is unprompted inside a git invocation" \
      "${tilde_literal_failed}"
  fi

  # #316: a quoted operator inside a git diff flag must not end the command.
  # The first split stripped quotes and then cut the string at every operator
  # character, so `--src-prefix='x|'` ended the git invocation as far as the
  # operand scan was concerned, the count reset at the `|`, and `/dev/null
  # ./cosign.key` were never counted -- while bash handed git the ordinary
  # two-operand plain-file read. Demonstrated first, in a temporary directory
  # of this fixture's own: git really prints the file beside that flag.
  quoted_op_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${quoted_op_dir}/fake.key"
  quoted_op_read="$(bash --norc --noprofile -c "git diff --src-prefix='x|' /dev/null ${quoted_op_dir}/fake.key" 2>/dev/null </dev/null)"
  if grep -q '^+SECRET-LINE-1$' <<<"${quoted_op_read}"; then
    pass "git diff prints a plain file beside a flag carrying a quoted operator"
  else
    fail "git diff prints a plain file beside a flag carrying a quoted operator" \
      "this git no longer enters the plain-file mode behind --src-prefix='x|'; re-derive the quote-aware split"
  fi
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted pipe in a flag (#316)" \
    "git diff --src-prefix='x|' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted semicolon in a flag (#316)" \
    "git diff --src-prefix='x;' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted regex pipe (#316)" \
    "git diff --word-diff-regex='.|.' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a double-quoted operator" \
    'git diff --src-prefix="x&" /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a backslash-escaped operator" \
    'git diff --src-prefix=x\| /dev/null ./cosign.key' 'plain files'
  # Inside double quotes a backslash escapes the quote after it, so `"x\"|"`
  # is one word whose `|` is still quoted, and bash hands git the two operands
  # after it. A scan that closed the quotes at `\"` cut the command at that
  # `|` and never counted them: the same read as #316, spelled so that none
  # of the rows above reaches the escape.
  assert_hook_refuses_naming "the hook refuses the plain-file read behind an escaped quote and an operator inside double quotes" \
    'git diff --src-prefix="x\"|" /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses --output after a quoted pipe in an earlier flag" \
    "git log --grep='a|b' --output=cosign.pub -1" '--output=FILE'
  # The unquoted spelling of the same string is two commands to bash -- `git
  # log --grep=a` piped into `b --output=...` -- and the --output latch still
  # holds to the end of the string, so it stays refused.
  assert_hook_refuses_naming "the hook still refuses --output after an unquoted pipe" \
    'git log --grep=a|b --output=cosign.pub -1' '--output=FILE'
  assert_hook_permits "a quoted operator in an ordinary one-operand diff flag is unprompted" \
    "git diff --src-prefix='x|' HEAD"
  assert_hook_permits "a quoted regex in git log --grep is unprompted" \
    "git log --grep='fix|feat' --oneline -5"

  # A redirection is not a separator, and its descriptor and target are the
  # shell's words rather than git's. A split that counted every unquoted `&`
  # as a separator closed the brace scope at the `&` of `2>&1`, and counted
  # the `2` and `1` of it as diff operands, refusing every `git diff ... 2>&1`
  # while letting `git diff 2>&1 /dev/null ./cosign.key` through with neither
  # operand counted. `>&`, `<&`, `&>`, `&>>` and `>|` are redirections; `|&`
  # is a pipe and still ends the command.
  assert_hook_permits "git diff HEAD 2>&1 is unprompted" 'git diff HEAD 2>&1'
  assert_hook_permits "git diff HEAD@{1} 2>&1 piped into jq is unprompted" \
    "git diff HEAD@{1} 2>&1 | jq '{a,b}'"
  assert_hook_permits "git diff HEAD |& jq is unprompted" "git diff HEAD |& jq '{a,b}'"
  assert_hook_permits "an input redirection on git diff is unprompted" 'git diff HEAD </dev/null'
  assert_hook_permits "a spaced input redirection on git diff is unprompted" 'git diff HEAD < /dev/null'
  assert_hook_permits "git diff --stat with 2>&1 piped into head is unprompted" \
    'git diff --stat HEAD -- AGENTS.md 2>&1 | head'
  assert_hook_refuses_naming "the hook refuses the plain-file read with 2>&1 before the operands" \
    'git diff 2>&1 /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read with 2>&1 after the operands" \
    'git diff /dev/null ./cosign.key 2>&1' 'plain files'
  assert_hook_refuses_naming "the hook refuses a brace behind 2>&1 on git log" \
    'git log 2>&1 --outpu{t,t}=cosign.pub -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind &>" \
    'git diff &>/dev/null {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind <&0" \
    'git diff <&0 {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind >| in the same command" \
    'git log -1 >| out --outpu{t,t}=cosign.pub' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command behind |&" \
    'git log -1 |& git diff {a,b}' 'expands braces'

  # The shell's own spelling of the write primitive: `git diff HEAD
  # >cosign.pub` truncates the file before git starts. The split above learned
  # to skip a redirection's target so `2>&1` is not two operands -- and with
  # that, the target of `>` was skipped too and the command passed. Shown
  # first, in a temporary directory: the redirection really empties the file.
  redirect_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${redirect_dir}/victim"
  bash --norc --noprofile -c "git diff HEAD HEAD >${redirect_dir}/victim" >/dev/null 2>&1 </dev/null
  redirect_written="$(cat "${redirect_dir}/victim" 2>/dev/null)"
  rm -rf "${redirect_dir}"
  if [[ "${redirect_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "an output redirection on git diff truncates the file it names before git runs"
  else
    fail "an output redirection on git diff truncates the file it names before git runs" \
      "the file kept its contents; re-derive why the redirection refusal exists"
  fi
  for redirect_command in \
    'git diff HEAD >cosign.pub' \
    'git diff HEAD > cosign.pub' \
    'git log -1 >> out' \
    'git diff 2>err' \
    'git diff &>/dev/null' \
    'git diff &>>/dev/null' \
    'git show HEAD >| x' \
    'git diff HEAD > .claude/settings.json' \
    'git diff HEAD > .claude/hooks/gate-git-diff.sh' \
    'git diff HEAD >&cosign.pub' \
    'git diff HEAD >& cosign.pub' \
    'git diff HEAD <>cosign.pub' \
    'git diff HEAD 2>&1 >cosign.pub' \
    'git log -1; git diff HEAD >cosign.pub' \
    'echo x | git diff HEAD >cosign.pub' \
    'git diff HEAD 2>&1 | jq . ; git log -1 >out'; do
    assert_hook_refuses_naming "the hook refuses an output redirection inside a git invocation: ${redirect_command}" \
      "${redirect_command}" 'output redirection'
  done
  for redirect_command in \
    'git diff HEAD >&2' \
    'git diff HEAD 1>&2' \
    'git diff HEAD >&-' \
    'git diff HEAD 2>&-' \
    'git diff HEAD <&0' \
    "git diff HEAD <<<''" \
    'echo x > out; git diff HEAD' \
    'echo x >> out && git diff HEAD' \
    'git diff HEAD | jq . > out'; do
    assert_hook_permits "a descriptor, input or other-command redirection is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # Bash lets a redirection precede the command name, and the two spellings
  # are the same command: `>cosign.pub git diff HEAD` truncates the file
  # exactly as `git diff HEAD >cosign.pub` does. A scope that opened at the
  # `git` word had not yet seen the target, so `git status; >cosign.pub git
  # diff HEAD` -- allowed on its `git status` prefix -- went through (review
  # on #317). Shown first: the prefix form really truncates the file.
  prefix_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${prefix_dir}/victim"
  bash --norc --noprofile -c "git status --short >/dev/null; >${prefix_dir}/victim git diff HEAD HEAD" >/dev/null 2>&1 </dev/null
  prefix_written="$(cat "${prefix_dir}/victim" 2>/dev/null)"
  rm -rf "${prefix_dir}"
  if [[ "${prefix_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a redirection written before the git word truncates the file it names"
  else
    fail "a redirection written before the git word truncates the file it names" \
      "the file kept its contents; re-derive why prefix redirections are carried to the command name"
  fi
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    '>cosign.pub git diff HEAD' \
    'git status; >cosign.pub git diff HEAD' \
    '2>err git log -1' \
    '>> out git show HEAD' \
    'FOO=bar >out git diff HEAD' \
    'git status; >cosign.pub /usr/bin/git diff HEAD' \
    'git status; {fd}>cosign.pub git diff HEAD' \
    'git diff HEAD {fd}>cosign.pub' \
    'git status; >$(printf cosign.pub) git diff HEAD' \
    '>$(printf cosign.pub) git diff HEAD'; do
    assert_hook_refuses_naming "the hook refuses a redirection written before the git word: ${redirect_command}" \
      "${redirect_command}" 'output redirection'
  done
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    '</dev/null git diff HEAD' \
    '2>&1 git diff HEAD' \
    '>&2 git diff HEAD' \
    '>out echo x; git diff HEAD' \
    '>out cat f | git diff --stat' \
    'git status; >out printf %s git' \
    '>out echo git; git diff HEAD' \
    '>$(printf out) echo x; git diff HEAD' \
    '{fd}>out echo x; git diff HEAD' \
    'x=$(date); git diff HEAD' \
    'echo $(date) *.sh; git status' \
    'echo $(git log -1) | git diff HEAD'; do
    assert_hook_permits "a prefix redirection that writes no path, or belongs to another command, is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # An expanding brace means the words here are not the words git would
  # receive, so its message comes first; the redirection is refused once the
  # brace is gone.
  assert_hook_refuses_naming "a brace wins over a redirection refusal" \
    'git diff HEAD >cosign.{pub,key}' 'expands braces'

  # The write primitive is not git's alone. Six other allow rows end in `*`
  # -- "this command with any arguments" -- and a shell output redirection
  # is part of the string that rule matches, so `shellcheck
  # tests/run-tests.sh >cosign.pub` truncated the trust anchor before a line
  # was linted and `podman images >.claude/settings.json` overwrote the file
  # holding these rules, neither prompted (zfs-kinoite-complex#224, the same
  # hook). Shown first, against a stand-in in a temporary directory: bash
  # opens the target before the command runs, so the file is emptied even
  # when the command then fails. `bash -n` is used because it is always
  # present; shellcheck may not be.
  gated_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'bash -n ./no-such-script.sh >victim' >/dev/null 2>&1 </dev/null)
  gated_written="$(cat "${gated_dir}/victim" 2>/dev/null)"
  # And the flag form: `-n` reads a script without running it, and a later
  # `+n` on the same command line turns that back off, so the linter's allow
  # rule runs whatever follows.
  noexec_ran="$(bash --norc --noprofile -c "bash -n +n -c 'printf RAN-UNDER-BASH-N'" 2>/dev/null </dev/null)"
  # And the glob form (review on aurora-zfs-simple#211): beside a file named
  # `+n`, `?n` reaches bash as `+n`.
  touch "${gated_dir}/+n"
  glob_ran="$(cd "${gated_dir}" && bash --norc --noprofile -c "bash -n ?n -c 'printf RAN-VIA-GLOB'" 2>/dev/null </dev/null)"
  # And a process substitution as the redirection's target: bash connects the
  # command's output to a command of its own, which writes wherever it likes
  # (review on #322).
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim2"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T > >(cat >victim2); wait' >/dev/null 2>&1 </dev/null)
  subst_written="$(cat "${gated_dir}/victim2" 2>/dev/null)"
  # A process substitution as an ordinary argument runs its body as part of
  # the approved string, and the body is held to no rule; and a wrapper's
  # option before the name (`command -p bash -n +n ...`) is still that
  # command (review on #322).
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim3"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T >(cat >victim3); wait' >/dev/null 2>&1 </dev/null)
  arg_subst_written="$(cat "${gated_dir}/victim3" 2>/dev/null)"
  wrapper_ran="$(bash --norc --noprofile -c "command -p bash -n +n -c 'printf RAN-BEHIND-WRAPPER'" 2>/dev/null </dev/null)"
  time_ran="$(bash --norc --noprofile -c "time -p bash -n +n -c 'printf RAN-BEHIND-TIME'" 2>/dev/null </dev/null)"
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim4"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T $(printf x >victim4)' >/dev/null 2>&1 </dev/null)
  cmd_subst_written="$(cat "${gated_dir}/victim4" 2>/dev/null)"
  rm -rf "${gated_dir}"
  if [[ "${gated_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "an output redirection on an allow-listed non-git command truncates the file it names"
  else
    fail "an output redirection on an allow-listed non-git command truncates the file it names" \
      "the file kept its contents; re-derive why the gated-prefix refusal exists"
  fi
  if [[ "${noexec_ran}" == "RAN-UNDER-BASH-N" ]]; then
    pass "bash -n +n -c COMMAND runs the command the -n was meant to keep from running"
  else
    fail "bash -n +n -c COMMAND runs the command the -n was meant to keep from running" \
      "got '${noexec_ran}'; re-derive why the +n refusal exists"
  fi
  if [[ "${glob_ran}" == "RAN-VIA-GLOB" ]]; then
    pass "bash -n ?n -c COMMAND runs the command when a file named +n exists"
  else
    fail "bash -n ?n -c COMMAND runs the command when a file named +n exists" \
      "got '${glob_ran}'; re-derive why the glob refusal exists"
  fi
  if [[ "${subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a redirection onto a process substitution writes the file the substitution names"
  else
    fail "a redirection onto a process substitution writes the file the substitution names" \
      "the file kept its contents; re-derive why a substitution after a redirection is its target"
  fi
  if [[ "${arg_subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a process substitution argument writes the file its body names"
  else
    fail "a process substitution argument writes the file its body names" \
      "the file kept its contents; re-derive why a substitution in a gated command is refused"
  fi
  if [[ "${wrapper_ran}" == "RAN-BEHIND-WRAPPER" ]]; then
    pass "command -p bash -n +n -c COMMAND runs the command behind the wrapper's option"
  else
    fail "command -p bash -n +n -c COMMAND runs the command behind the wrapper's option" \
      "got '${wrapper_ran}'; re-derive why the prefix restarts at a later candidate name"
  fi
  if [[ "${time_ran}" == "RAN-BEHIND-TIME" ]]; then
    pass "time -p bash -n +n -c COMMAND runs the command behind time's option"
  else
    fail "time -p bash -n +n -c COMMAND runs the command behind time's option" \
      "got '${time_ran}'; re-derive why the name scan steps over time's -p"
  fi
  if [[ "${cmd_subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a command substitution argument writes the file its body names"
  else
    fail "a command substitution argument writes the file its body names" \
      "the file kept its contents; re-derive why a substitution in a gated command is refused"
  fi
  # A here-document with an unquoted delimiter is expanded before the
  # command runs, so a substitution on a body line runs under the prefix
  # (review on #322).
  heredoc_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${heredoc_dir}/victim5"
  (cd "${heredoc_dir}" && bash --norc --noprofile -c $'df -T <<EOF\n$(printf x >victim5)\nEOF' >/dev/null 2>&1 </dev/null)
  heredoc_written="$(cat "${heredoc_dir}/victim5" 2>/dev/null)"
  rm -rf "${heredoc_dir}"
  if [[ "${heredoc_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a substitution on the body line of an unquoted heredoc writes the file it names"
  else
    fail "a substitution on the body line of an unquoted heredoc writes the file it names" \
      "the file kept its contents; re-derive why an unquoted heredoc on a gated command is refused"
  fi
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for heredoc_command in \
    $'df -T <<EOF\necho $(printf x >cosign.pub)\nEOF' \
    $'podman images <<EOF\nplain text\nEOF' \
    $'bash -n <<-EOF\n\tx\nEOF' \
    $'git status; findmnt <<EOF\nx\nEOF'; do
    assert_hook_refuses_naming "the hook refuses an unquoted here-document on an allow-listed command: ${heredoc_command//$'\n'/ | }" \
      "${heredoc_command}" 'Quote the delimiter'
  done
  # An assignment before the name is an environment the command runs
  # under, and for these commands that changes what runs or where it goes
  # (review on sensi#244, the Python twin of this hook). Git was exempt until
  # issue #329, on the reading that a git invocation is decided by the operand
  # scan; that scan reads words, and an assignment is not one. Shown first in
  # a temporary repository: `GIT_EXTERNAL_DIFF` names a program git runs once
  # per changed path, so an allow-listed `git diff` string runs it unprompted.
  gitenv_dir="$(mktemp -d)"
  (
    cd "${gitenv_dir}" || exit 0
    printf '#!/bin/sh\nprintf RAN-AS-EXTERNAL-DIFF >"%s/ran"\n' "${gitenv_dir}" >prog
    chmod +x prog
    git init -q . >/dev/null 2>&1 || exit 0
    git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m first >/dev/null 2>&1
    printf 'one\n' >tracked
    git add tracked >/dev/null 2>&1
    git -c user.email=t@example.invalid -c user.name=t commit -q -m second >/dev/null 2>&1
    GIT_EXTERNAL_DIFF="${gitenv_dir}/prog" git diff HEAD~1 >/dev/null 2>&1
  ) </dev/null
  gitenv_ran="$(cat "${gitenv_dir}/ran" 2>/dev/null)"
  rm -rf "${gitenv_dir}"
  if [[ "${gitenv_ran}" == "RAN-AS-EXTERNAL-DIFF" ]]; then
    pass "GIT_EXTERNAL_DIFF=prog git diff runs prog, so an assignment before git is code execution"
  else
    fail "GIT_EXTERNAL_DIFF=prog git diff runs prog, so an assignment before git is code execution" \
      "got '${gitenv_ran}'; re-derive why an assignment before git is refused"
  fi
  for assigned_command in \
    'LD_PRELOAD=x.so shellcheck tests/run-tests.sh' \
    'BASH_ENV=f bash -n tests/run-tests.sh' \
    'CONTAINERS_CONF=f podman ps' \
    'FOO=1 df -T' \
    'git status; FOO=1 findmnt' \
    'GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1' \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=/tmp/prog git diff HEAD~1' \
    'PATH=/tmp/bin git diff HEAD~1' \
    'FOO=bar git diff HEAD' \
    'PAGER=cat git log -1' \
    'GIT_DIR=/tmp/other git ls-files' \
    'env FOO=bar git diff HEAD' \
    'git status; FOO=1 git log -1'; do
    assert_hook_refuses_naming "the hook refuses an assignment before an allow-listed command: ${assigned_command}" \
      "${assigned_command}" 'assignment before'
  done
  for assigned_command in \
    'FOO=1 echo x; podman images' \
    'FOO=1 echo x; git diff HEAD' \
    'echo FOO=bar; git status' \
    'x=1; podman images'; do
    assert_hook_permits "an assignment on another command of the string is unprompted: ${assigned_command}" \
      "${assigned_command}"
  done
  # shellcheck disable=SC2016 # the substitution is a spelling handed to the hook, not run here
  for heredoc_command in \
    $'bash -n <<\'EOF\'\necho hi\nEOF' \
    $'bash -n <<"EOF"\necho $(id)\nEOF' \
    $'cat <<EOF\nplain\nEOF; podman images' \
    'podman images <in'; do
    assert_hook_permits "a quoted here-document, or one on another command, is unprompted: ${heredoc_command//$'\n'/ | }" \
      "${heredoc_command}"
  done
  # shellcheck disable=SC2016 # the substitution is a spelling handed to the hook, not run here
  for subst_command in \
    'df -T >(cat >cosign.pub)' \
    '>(cat >cosign.pub) df -T' \
    'podman ps <(true)' \
    'bash -n <(printf x >written)' \
    'bash -n >(cat) tests/run-tests.sh' \
    'git status; findmnt -J >(tee cosign.pub)' \
    'echo $(podman images >(cat >cosign.pub))' \
    'df -T $(touch cosign.pub)' \
    'podman images `printf x >cosign.pub`' \
    'findmnt $(pwd) >cosign.pub' \
    'df -T < <(printf x >cosign.pub)' \
    'podman images <"$(printf x >cosign.pub)"' \
    'df -T <<<"$(printf x >cosign.pub)"' \
    'podman images <`printf in`' \
    'shellcheck tests/run-tests.sh <"$(printf x >cosign.pub)"' \
    'shellcheck tests/run-tests.sh < <(printf x >cosign.pub)' \
    'df -T "$(printf x >cosign.pub)"' \
    'podman images $X' \
    'findmnt "$FLAGS"' \
    "podman images 'a \$b'"; do
    assert_hook_refuses_naming "the hook refuses a substitution in an allow-listed command: ${subst_command}" \
      "${subst_command}" 'substitution'
  done
  # The list of gated commands lives in the hook; this is what keeps it from
  # drifting. The commands are derived from the settings file rather than
  # restated, so an allow rule added there with a trailing `*` fails here
  # until the hook lists it. The git rows are the scan above's; the exact
  # rows (`just test`, the virsh inventories) carry no `*`, so a redirection
  # makes the string match no row and Claude Code prompts.
  gated_rows=0
  while IFS= read -r gated_prefix; do
    [[ -n "${gated_prefix}" ]] || continue
    [[ "${gated_prefix}" == "git "* ]] && continue
    gated_rows=$((gated_rows + 1))
    assert_hook_refuses_naming "every allow rule with arguments is refused a writing redirection: ${gated_prefix} >cosign.pub" \
      "${gated_prefix} >cosign.pub" 'allow-listed command'
  done < <(jq -r '.permissions.allow[]? | select(startswith("Bash(") and endswith("*)")) | .[5:-2] | sub(" $"; "")' "${CLAUDE_SETTINGS}")
  if ((gated_rows >= 6)); then
    pass "the settings file still carries the allow rows the gated-prefix scan covers (${gated_rows})"
  else
    fail "the settings file still carries the allow rows the gated-prefix scan covers" \
      "found ${gated_rows} Bash(...*) rows other than git's; expected at least 6"
  fi
  # The same rows behind the two wrappers this hook once read wrongly. Claude
  # Code 2.1.267 strips `noglob` before it matches a row, so `noglob podman
  # ps >out` is the redirection above with one more word in front; and it
  # matches `xargs <row>` against every row that ends in `*`, so `xargs git
  # diff` runs unprompted with operands read from standard input that no
  # scan here can see. Derived from the settings file for the reason the loop
  # above is, and git's rows included, since both reach them too.
  wrapped_rows=0
  while IFS= read -r gated_prefix; do
    [[ -n "${gated_prefix}" ]] || continue
    wrapped_rows=$((wrapped_rows + 1))
    assert_hook_refuses_naming "every allow rule with arguments is refused a writing redirection behind noglob: noglob ${gated_prefix} >out" \
      "noglob ${gated_prefix} >out" 'output redirection'
    assert_hook_refuses_naming "every allow rule with arguments is refused behind xargs: xargs ${gated_prefix}" \
      "xargs ${gated_prefix}" 'xargs adds the words'
  done < <(jq -r '.permissions.allow[]? | select(startswith("Bash(") and endswith("*)")) | .[5:-2] | sub(" $"; "")' "${CLAUDE_SETTINGS}")
  if ((wrapped_rows > gated_rows)); then
    pass "the noglob and xargs rows reach git's allow rows as well as the others (${wrapped_rows})"
  else
    fail "the noglob and xargs rows reach git's allow rows as well as the others" \
      "found ${wrapped_rows} Bash(...*) rows in all against ${gated_rows} without git's"
  fi
  # Every operator that opens a path, in every position bash accepts it: after
  # the command, before its name, after an assignment or `time`, carried
  # across a `$(...)` in the same command, and on the longer last word the
  # `df -T*` row also matches.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    'shellcheck tests/run-tests.sh >cosign.pub' \
    'shellcheck tests/run-tests.sh >> out' \
    'shellcheck tests/run-tests.sh 2>.claude/settings.json' \
    'shellcheck >| cosign.pub' \
    'bash -n tests/run-tests.sh &>cosign.pub' \
    'bash -n tests/run-tests.sh &>>cosign.pub' \
    'podman images >&cosign.pub' \
    'podman ps -a <>cosign.pub' \
    'podman ps {fd}>cosign.pub' \
    'findmnt -J >/dev/null' \
    'df -T >cosign.pub' \
    'df -Th > .claude/hooks/gate-git-diff.sh' \
    'podman images 2>&1 >cosign.pub' \
    '>cosign.pub shellcheck tests/run-tests.sh' \
    'git status; >cosign.pub podman images' \
    'FOO=bar shellcheck tests/run-tests.sh >cosign.pub' \
    'FOO=bar >cosign.pub shellcheck tests/run-tests.sh' \
    'time shellcheck tests/run-tests.sh >cosign.pub' \
    'command podman images >cosign.pub' \
    'echo $(podman images >cosign.pub)' \
    'ls | podman images >cosign.pub' \
    'shellcheck tests/run-tests.sh 2>&1 | tee x; df -T >out' \
    'df -T > >(cat >cosign.pub)' \
    'podman images >>(tee cosign.pub)' \
    'shellcheck tests/run-tests.sh 2> >(cat >cosign.pub)' \
    'shellcheck tests/run-tests.sh >cosign.pub # a comment after the write' \
    "shellcheck tests/run-tests.sh '#' >cosign.pub" \
    'command -p shellcheck tests/run-tests.sh >cosign.pub'; do
    assert_hook_refuses_naming "the hook refuses an output redirection inside an allow-listed command: ${redirect_command}" \
      "${redirect_command}" 'allow-listed command'
  done
  # The refusal is the operator that opens a path for writing. A pipe, a
  # descriptor form and an input redirection open none.
  for redirect_command in \
    'shellcheck tests/run-tests.sh 2>&1 | tail -5' \
    'podman images | grep arch-bootc' \
    'findmnt -T / -o TARGET,SOURCE' \
    'shellcheck tests/run-tests.sh <tests/run-tests.sh' \
    'podman ps >&2' \
    'df -T 2>&-' \
    'bash -n tests/run-tests.sh </dev/null' \
    'shellcheck -x tests/run-tests.sh' \
    'bash -n tests/run-tests.sh' \
    'df -Th'; do
    assert_hook_permits "reading the output of an allow-listed command is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # podman's --cpu-profile/--memory-profile write the same way a `>` on a
  # gated command does, but by an option: persistent globals podman accepts
  # after the subcommand the `podman images*`/`podman ps*` row matches, so
  # `podman images --cpu-profile cosign.pub` dumps a pprof profile over the
  # trust anchor with the allow row seeing only its prefix
  # (aurora-zfs-simple#257, atomic-image-builder#474). Both flags, both
  # spellings, behind a wrapper and after a `;`.
  for profiled in \
    'podman images --cpu-profile cosign.pub' \
    'podman images --cpu-profile=cosign.pub' \
    'podman ps --cpu-profile .claude/settings.json' \
    'podman ps -a --memory-profile cosign.pub' \
    'podman images --memory-profile=.claude/hooks/gate-git-diff.sh' \
    'timeout 5 podman images --cpu-profile cosign.pub' \
    'git status; podman images --cpu-profile cosign.pub'; do
    assert_hook_refuses_naming "a podman profile flag that writes a file is refused: ${profiled}" \
      "${profiled}" 'profile'
  done
  # A word bash rebuilds before podman runs can become either option after the
  # literal comparison has read it: a brace with no precondition, and a glob
  # once a file named like the option exists in the working directory, so
  # `--cpu-profil*` beside a file `--cpu-profile=cosign.pub` overwrote
  # cosign.pub with a profile when run for real (aurora-zfs-simple#262).
  for rebuilt in \
    'podman images --cpu-pro{f..f}ile cosign.pub' \
    'podman images --{cpu,memory}-profile cosign.pub' \
    'podman ps --cpu-profile{,}=cosign.pub' \
    'podman images --cpu-profil*' \
    'podman ps [-]-memory-profile=cosign.pub' \
    'podman images ?-cpu-profile=cosign.pub' \
    'podman images *' \
    'podman images ~/x' \
    'podman images @(--cpu-profile=cosign.pub)' \
    'podman ps +(--memory-profile=cosign.pub)' \
    'podman images fedora!(x)' \
    "podman images ''@(--cpu-profile=cosign.pub)" \
    'podman images ""@(--cpu-profile=cosign.pub)' \
    'git status; podman images --cpu-pro{f..f}ile cosign.pub'; do
    assert_hook_refuses_naming "a podman word bash rewrites is refused: ${rebuilt}" \
      "${rebuilt}" 'bash rewrites this word of a podman invocation'
  done
  # A literal flag ahead of a rewritten word is refused for the flag: the
  # message names the write, not the rewrite.
  assert_hook_refuses_naming "a literal profile flag beside a glob is refused for the flag" \
    'podman images --cpu-profile cosign.pub *' 'podman --cpu-profile FILE'
  # The same podman verbs without the flag, a quoted pattern, a Go template
  # brace, and the flag words outside a podman command stay unprompted.
  for ok in \
    'podman ps' \
    'podman images --format json' \
    'podman images --format {{.Id}}' \
    'podman ps -a --no-trunc' \
    "podman images 'fedora*'" \
    "podman inspect --format '{{.Id}},{{.Name}}' foo" \
    'podman inspect --format "{{.Id}},{{.Name}}" foo' \
    'podman images --cpu-pro"{f..f}"ile x' \
    'podman images \{a,b\}' \
    "podman images '@'(x)" \
    'echo podman images --cpu-profile x' \
    'git log --grep=cpu-profile -1'; do
    assert_hook_permits "a podman verb with no profile flag, or the flag outside a podman command, is left alone: ${ok}" \
      "${ok}"
  done
  # The hook re-gates what the permission rules wave through. A command no
  # allow rule covers prompts on its own, and a redirection on another
  # command of the same string is that command's own. The brace group and
  # the subshell below are decided by Claude Code itself: it asks before it
  # runs any command that contains one, whatever the allow rows say
  # ("Contains compound_statement", "Contains subshell"; 2.1.273 and
  # 2.1.280), so the hook does not restate that. The check after the
  # unreachable rows below fails if an allow row that could reach one is
  # added.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    'echo x >cosign.pub' \
    'cat tests/run-tests.sh >cosign.pub' \
    'df -h >cosign.pub' \
    'just test >cosign.pub' \
    'echo x >out; shellcheck tests/run-tests.sh' \
    'shellcheck tests/run-tests.sh | tee out' \
    '>out echo x; podman images' \
    'bash -n tests/run-tests.sh; { bash -n missing.sh; } >cosign.pub' \
    '(shellcheck tests/run-tests.sh) >cosign.pub' \
    'echo x > >(cat >cosign.pub)' \
    'cat < <(podman images)' \
    'cat <(podman images)' \
    'command -v shellcheck' \
    'time -p ls' \
    'x=$(podman images); echo $x' \
    'echo $(podman images)' \
    'podman images --format "{{.ID}}"' \
    'findmnt -J -o TARGET,SOURCE' \
    'shellcheck tests/run-tests.sh # output > file' \
    'bash -n tests/run-tests.sh # +n' \
    'git diff HEAD # > cosign.pub'; do
    assert_hook_permits "a redirection on a command no allow rule covers is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # The flag that undoes `bash -n`. `+n` and `+o noexec` turn execution back
  # on for the rest of the command line, so a word beginning with `+` in a
  # `bash -n` invocation is refused, along with the spellings bash rebuilds
  # -- a brace, a `$` or a backtick -- since `{+,+}n` reaches bash as `+n`.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for noexec_command in \
    "bash -n +n -c 'cat ./cosign.key'" \
    'bash -n +o noexec tests/run-tests.sh' \
    'bash -n tests/run-tests.sh +n' \
    "bash -n +nv -c 'id'" \
    'bash -n "+n" -c id' \
    'git status; bash -n +n -c id' \
    'git status; command -p bash -n +n -c id' \
    'command -- bash -n +n -c id' \
    'git status; time -p bash -n +n -c id' \
    'bash -n {+,+}n -c id' \
    'bash -n $X tests/run-tests.sh' \
    'bash -n $(printf +n) -c id' \
    'bash -n `printf +n` -c id' \
    'bash -n --norc {+,+}n -c id' \
    'bash -n ?n -c id' \
    'bash -n [+]n -c id' \
    'bash -n tests/*.sh'; do
    assert_hook_refuses_naming "the hook refuses a + word or an expansion in a bash -n invocation: ${noexec_command}" \
      "${noexec_command}" '+n'
  done
  # shellcheck disable=SC2016 # the $x is a spelling handed to the hook, not expanded here
  for noexec_command in \
    'bash -n tests/run-tests.sh' \
    'bash -n scripts/quickstart.sh tests/run-tests.sh' \
    'bash -n -- tests/run-tests.sh' \
    "bash -n '?n'" \
    'bash +n -c id' \
    'echo $x; bash -n tests/run-tests.sh'; do
    assert_hook_permits "a syntax check, and a bash no allow rule covers, are unprompted: ${noexec_command}" \
      "${noexec_command}"
  done

  # What `bash -n` prints (issue #345). `-n` stops bash running a script,
  # not reading it out: `bash -n -v ./cosign.key` printed the key, because
  # `-v` prints every line bash reads, and the hook let it through. So the
  # options that print or copy what bash reads are refused in a `bash -n`
  # invocation, read the way bash reads its own (`-nv` is `-n -v`; `-no
  # verbose` hands `verbose` to the `-o`), and the script it opens -- an
  # operand, or stdin when none is named -- is held to the shellcheck operand
  # test, since bash prints the line a syntax error stands on. A login shell
  # reached from outside bash's own words -- `exec -l`, or a zeroth argument
  # that begins with `-` (review on aurora-zfs-simple#237) -- reads the same
  # startup files `-l` does, and is refused with it.
  #
  # Each row is run twice: by real bash, in a throwaway checkout holding a
  # synthetic key, `.env` and script under a throwaway HOME, and through the
  # hook. The first column is what bash was *seen* to do -- `prints` when a
  # marker from one of those files reached the output or HOME's history
  # file, `quiet` otherwise -- so a row cannot claim a leak bash does not
  # have, and a `prints` row the hook allows fails. A `quiet` row that is
  # refused is refused on purpose, with the reason beside it.
  bash_n_work="$(mktemp -d)"
  mkdir -p "${bash_n_work}/checkout/tests"
  # The PEM marker is passed as an argument, so this file carries no copy of
  # it for a scan for private keys to find.
  printf -- '-----BEGIN ENCRYPTED SIGSTORE %s-----\nNOT-A-REAL-KEY-BASH-N-42\n-----END ENCRYPTED SIGSTORE %s-----\n' \
    'PRIVATE KEY' 'PRIVATE KEY' >"${bash_n_work}/checkout/cosign.key"
  printf 'API_TOKEN=NOT-A-REAL-TOKEN-BASH-N-42\nDB_PASSWORD=NOT-A-REAL-PASSWORD-BASH-N-42(x\n' \
    >"${bash_n_work}/checkout/.env"
  cp "${bash_n_work}/checkout/.env" "${bash_n_work}/outside.env"
  # shellcheck disable=SC2016 # the $"..." is the script's own text
  printf 'X=NOT-A-REAL-SCRIPT-LINE-BASH-N-42\ny=$"NOT-A-REAL-STRING-BASH-N-42"\n' \
    >"${bash_n_work}/checkout/tests/run-tests.sh"
  # Runs `$1` in the throwaway checkout, with a fresh HOME whose startup
  # files a login or interactive shell reads, and an environment of PATH
  # alone so no HISTFILE or HISTSIZE of the host's decides where history goes.
  bash_n_prints() {
    local out
    rm -rf "${bash_n_work:?}/home"
    mkdir -p "${bash_n_work}/home"
    printf 'PROFILE=NOT-A-REAL-PROFILE-BASH-N-42(x\n' >"${bash_n_work}/home/.bash_profile"
    printf 'RC=NOT-A-REAL-RC-BASH-N-42(x\n' >"${bash_n_work}/home/.bashrc"
    out="$(cd "${bash_n_work}/checkout" && env -i HOME="${bash_n_work}/home" PATH="${PATH}" \
      bash --norc --noprofile -c "$1" 2>&1 </dev/null)"
    [[ -f "${bash_n_work}/home/.bash_history" ]] && out+="$(cat "${bash_n_work}/home/.bash_history")"
    [[ "${out}" == *NOT-A-REAL* ]]
  }
  bash_n_rows=()
  bash_n_row() { bash_n_rows+=("$1"$'\t'"$2"$'\t'"$3"); }
  # The four spellings the issue reproduced, and the option spellings around them.
  bash_n_row prints refuse 'bash -n -v ./cosign.key'
  bash_n_row prints refuse 'bash -nv ./cosign.key'
  bash_n_row prints refuse 'bash -n -o verbose ./cosign.key'
  bash_n_row prints refuse 'bash -n -v - < .env'
  bash_n_row prints refuse 'bash -n -v tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -no verbose tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -oo noexec verbose tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -O extglob -o verbose tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -D tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -o history tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -i tests/run-tests.sh'
  bash_n_row prints refuse 'bash -n -l tests/run-tests.sh'
  bash_n_row prints refuse 'command -p bash -n -v tests/run-tests.sh'
  bash_n_row prints refuse 'echo x; bash -nv tests/run-tests.sh'
  bash_n_row prints refuse 'exec -l bash -n tests/run-tests.sh'
  bash_n_row prints refuse 'exec -a -bash bash -n tests/run-tests.sh'
  # The file bash opens: an operand, or stdin when no operand is named.
  bash_n_row prints refuse 'bash -n .env'
  bash_n_row prints refuse 'bash -n ./.env'
  bash_n_row prints refuse 'bash -n ../outside.env'
  bash_n_row prints refuse "bash -n ${bash_n_work}/outside.env"
  bash_n_row prints refuse 'bash -n - < .env'
  bash_n_row prints refuse 'bash -n < .env'
  bash_n_row prints refuse '< .env bash -n'
  bash_n_row prints refuse 'bash -n -s < ./.env'
  # Refused though bash prints nothing here. -x traces what runs, and under
  # -n nothing does; a key parses cleanly, and is refused by name, as a
  # ShellCheck operand is; bash rejects a `--word` after -n and exits, and
  # this one names a refused letter; and with a script named, stdin is not
  # read, but the test on a bare `<` is the one shellcheck's stdin is held to.
  bash_n_row quiet refuse 'bash -n -x tests/run-tests.sh'
  bash_n_row quiet refuse 'bash -n -o xtrace tests/run-tests.sh'
  bash_n_row quiet refuse 'bash -n ./cosign.key'
  bash_n_row quiet refuse 'bash -n --verbose .env'
  bash_n_row quiet refuse 'bash -n tests/run-tests.sh < .env'
  # The syntax checks this repository runs, and the option spellings bash
  # reads as something other than a refused option: `-` and `--` end the
  # options, so a `-v` after them is a file name; a `-v` after the script is
  # its first argument; `-O` and `-o` take the next word as their value.
  bash_n_row quiet allow 'bash -n tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n -- tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n - tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n -O extglob tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n -o posix tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n - < tests/run-tests.sh'
  bash_n_row quiet allow 'bash -n tests/run-tests.sh < /dev/null'
  bash_n_row quiet allow 'bash -n -- -v'
  bash_n_row quiet allow 'bash -n tests/run-tests.sh -v'
  bash_n_row quiet allow "bash -n -c 'x=1'"
  bash_n_row quiet allow 'exec bash -n tests/run-tests.sh'
  bash_n_prints_rows=0
  bash_n_allow_rows=0
  for bash_n_entry in "${bash_n_rows[@]}"; do
    IFS=$'\t' read -r bash_n_seen bash_n_want bash_n_command <<<"${bash_n_entry}"
    if bash_n_prints "${bash_n_command}"; then
      bash_n_real=prints
    else
      bash_n_real=quiet
    fi
    if [[ "${bash_n_real}" == "${bash_n_seen}" ]]; then
      pass "real bash ${bash_n_seen}: ${bash_n_command}"
    else
      fail "real bash ${bash_n_seen}: ${bash_n_command}" \
        "bash was seen to be ${bash_n_real}; the row's first column is wrong"
    fi
    if [[ "${bash_n_real}" == prints ]]; then
      ((bash_n_prints_rows++))
      if [[ "${bash_n_want}" == refuse ]]; then
        pass "and a row that prints is a refuse row: ${bash_n_command}"
      else
        fail "and a row that prints is a refuse row: ${bash_n_command}" \
          "bash prints a marker for this spelling, and the row allows it"
      fi
    fi
    if [[ "${bash_n_want}" == refuse ]]; then
      assert_hook_refuses_naming "the hook refuses: ${bash_n_command}" "${bash_n_command}" 'bash -n'
    else
      ((bash_n_allow_rows++))
      assert_hook_permits "the hook allows: ${bash_n_command}" "${bash_n_command}"
    fi
  done
  rm -rf "${bash_n_work}"
  if ((bash_n_prints_rows >= 20 && bash_n_allow_rows >= 10)); then
    pass "the bash -n table carries its rows (${bash_n_prints_rows} print, ${bash_n_allow_rows} allow)"
  else
    fail "the bash -n table carries its rows" \
      "found ${bash_n_prints_rows} rows that print and ${bash_n_allow_rows} allow rows; a shrunken table passes vacuously"
  fi

  # A `(` behind an unquoted `<` or `>` is a process substitution, not a
  # subshell: it hands git a /dev/fd path as an operand the scan never
  # counted, and the first split reset the operand count at its `(` instead.
  # It is refused in a git invocation and left alone in any other command.
  assert_hook_refuses_naming "the hook refuses a process substitution as a git diff operand" \
    'git diff <(true) ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a process substitution behind --" \
    'git diff -- ./cosign.key <(true)' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command inside a process substitution" \
    'cat <(git diff {a,b})' 'expands braces'
  assert_hook_permits "a process substitution in a later non-git command is unprompted" \
    'git log -1; cat <(true)'
  assert_hook_permits "git inside a process substitution of another command is unprompted" \
    'cat <(git log -1)'
  assert_hook_permits "two git process substitutions handed to diff are unprompted" \
    'diff <(git log -1) <(git log -2)'

  # `$` and a backtick rebuild both refusals by another route: `$(...)` and
  # `` `...` `` supply operands the scan never counted, `$'\x74'` is the
  # letter t so `--outpu$'\x74'=FILE` reaches git as --output=FILE, and `$x`
  # is a runtime-built argument. Shown first: bash replaces the substitution
  # before git runs, and git prints the file beside it.
  subst_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${subst_dir}/fake.key"
  subst_read="$(bash --norc --noprofile -c "git diff \$(echo /dev/null) ${subst_dir}/fake.key" 2>/dev/null </dev/null)"
  if grep -q '^+SECRET-LINE-1$' <<<"${subst_read}"; then
    pass "git diff prints a plain file beside a substituted operand"
  else
    fail "git diff prints a plain file beside a substituted operand" \
      "bash no longer substitutes the operand before git runs; re-derive the \$ refusal"
  fi
  # shellcheck disable=SC2016 # the literal $(...), $x and backticks are the
  # command strings handed to the hook, not anything this script expands.
  for expand_command in \
    'git diff $(echo /dev/null) ./cosign.key' \
    "git diff \$(printf '/dev/null ./cosign.key')" \
    "git diff \`printf '/dev/null ./cosign.key'\`" \
    'git diff `echo /dev/null` ./cosign.key' \
    "git log -p --outpu\$'\\x74'=cosign.pub -1" \
    "git log --outpu\$'\\x74'=FILE" \
    'git diff $OPERANDS' \
    'git diff -- $x $y' \
    'git log -1 && git diff $(echo /dev/null) ./cosign.key' \
    "git log --grep='a|b' --outpu\$'\\x74'=cosign.pub -1" \
    "git log --grep='a|b' \`printf -- --output=cosign.pub\` -1"; do
    assert_hook_refuses_naming "the hook refuses a \$ or backtick in a git word: ${expand_command}" \
      "${expand_command}" 'before git sees the words'
  done
  # The `$` half is scoped like the brace rule, to the command that starts at
  # a `git` word: an awk or jq program in a string that never invokes git, or
  # in a command before or after it, is somebody else's argument.
  # shellcheck disable=SC2016 # literal $(date) and backticks are the point
  for expand_command in \
    "awk '{print \$1}' README.md" \
    "jq '.[\$x]' renovate.json" \
    'echo `date`' \
    'x=$(date); ls' \
    "jq '.[\$x]' f | git diff --stat" \
    "git diff HEAD | awk '{print \$1}'"; do
    assert_hook_permits "a \$ or backtick outside a git invocation is unprompted: ${expand_command}" \
      "${expand_command}"
  done

  # The word that names a command must be literal. Every scope in the hook
  # opens at a literal `git` word, and the allow rule matched the string on
  # its literal `git status` prefix: `$G` is not the word `git`, so after
  # `git status;` nothing reopened, the hook exited 0, and bash ran the
  # plain-file read. So is a brace bash would expand or a glob in that
  # position -- `{,git}`, `g?t`, `/usr/bin/g[i]t` all reach git -- and after
  # a wrapper that runs its arguments (`command`, `env`, `timeout`, ...) every
  # remaining word of the command is held to the test. `[` and `[[` are
  # commands, not globs. Shown first: `$G diff` really prints the file.
  name_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${name_dir}/fake.key"
  name_read="$(bash --norc --noprofile -c "git status --short >/dev/null; G=git; \$G diff /dev/null ${name_dir}/fake.key" 2>/dev/null </dev/null)"
  rm -rf "${name_dir}"
  if grep -q '^+SECRET-LINE-1$' <<<"${name_read}"; then
    pass "a git invocation named through a variable really runs the plain-file read"
  else
    fail "a git invocation named through a variable really runs the plain-file read" \
      "bash no longer runs \$G as git; re-derive the literal-command-name rule"
  fi
  # shellcheck disable=SC2016 # literal $G and $(printf git) are the point
  for name_command in \
    'git status; G=git; $G diff /dev/null ./cosign.key' \
    'git status; $(printf git) diff /dev/null ./cosign.key' \
    'git status; `echo git` diff x' \
    '`echo git` diff x' \
    '$G diff /dev/null ./cosign.key' \
    'G=git $G diff /dev/null ./cosign.key' \
    'git status && "$(printf git)" diff x' \
    'git status; { $G diff x; }' \
    'git status; exec $G diff x' \
    'git status; env G=git $G diff x' \
    'git status; time $G diff x' \
    'git status | $G diff x' \
    'git status; {,git} diff /dev/null ./cosign.key' \
    'git status; g?t diff /dev/null ./cosign.key' \
    'git status; gi* diff /dev/null ./cosign.key' \
    'git status; /usr/bin/g[i]t diff /dev/null ./cosign.key' \
    'shellcheck --version; G=git; command -- $G diff /dev/null ./cosign.key' \
    'git status; env -u X $G diff /dev/null ./cosign.key' \
    'git status; timeout -s KILL 5 $G diff x'; do
    assert_hook_refuses_naming "the hook refuses a command name that is not literal: ${name_command}" \
      "${name_command}" 'Spell every command name literally'
  done
  # `env -S` is not an option but an interpreter: it splits its quoted string
  # into a command this scan never sees as words. Any -S after env, clustered
  # or long, is refused; the other env options are not.
  for name_command in \
    "git status; env -S 'git diff /dev/null ./cosign.key'" \
    "env -iS 'git diff /dev/null ./cosign.key'" \
    "git status; env --split-string='git diff x'" \
    "git status; env --split-string 'git diff x'" \
    "git status; env -u X -S 'git diff x'"; do
    assert_hook_refuses_naming "the hook refuses env -S: ${name_command}" \
      "${name_command}" 'env -S'
  done
  # `env -i PATH=$PATH git diff HEAD` used to stand in this list, on the
  # reading that an assignment in front of a literal name is not a
  # command-name problem. It is not, and it is an environment problem: the
  # corpus group below holds it as a refused row, because `env -i
  # GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD` is the same shape with a
  # variable that runs a program (issue #333).
  # `xargs -I{} git diff {} < list` stood here too, on the reading that
  # xargs is one more wrapper to step over. It is not: xargs adds operands
  # from standard input that the string never holds, and the allow row
  # matches `xargs git diff*` as readily as `git diff*`, so the corpus below
  # holds it as a refused row.
  # shellcheck disable=SC2016 # literal $x, $HOME and backticks are the point
  for name_command in \
    'git status; git diff HEAD@{1}' \
    'X=$(date); git diff HEAD' \
    'echo $HOME; git diff HEAD' \
    'echo `date`; git diff HEAD' \
    'if [ -n "$x" ]; then git diff HEAD; fi' \
    '[[ -n "$x" ]] && git diff HEAD' \
    'git status; [ -f cosign.pub ]' \
    'for f in $(ls); do echo $f; done' \
    'ls > out; git status' \
    'env -u X git diff HEAD' \
    'timeout 60 git diff HEAD' \
    'git status; timeout -s KILL 5 git diff HEAD' \
    'command -v shellcheck' \
    "find . -name '*.sh'"; do
    assert_hook_permits "a literal command name is unprompted: ${name_command}" \
      "${name_command}"
  done
  # A literal path to git is git: `/usr/bin/git diff /dev/null ./cosign.key`
  # needs no expansion and opened no scope, because every scan compared the
  # word to `git`. A literal name whose last component is git is rewritten
  # to git before any scan runs, so each refusal reaches it.
  assert_hook_refuses_naming "the hook refuses the plain-file read through /usr/bin/git after git status" \
    'git status; /usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through /usr/bin/git" \
    '/usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through ~/bin/git" \
    'git status; ~/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through command /usr/bin/git" \
    'git status; command /usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses --output through /usr/bin/git" \
    '/usr/bin/git log -1 --output=cosign.pub' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses an output redirection through /usr/bin/git" \
    'git status; /usr/bin/git diff HEAD >cosign.pub' 'output redirection'
  assert_hook_refuses_naming "the hook refuses a brace through /usr/bin/git" \
    '/usr/bin/git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_permits "an ordinary diff through /usr/bin/git is unprompted" '/usr/bin/git diff HEAD'
  assert_hook_permits "an ordinary log through /usr/bin/git is unprompted" '/usr/bin/git log --oneline -5'
  rm -rf -- "${quoted_op_dir}" "${subst_dir}"

  # Spellings the shell rewrites before git sees them. Each of these reaches
  # git as --no-index while the literal string is absent from the command.
  assert_hook_refuses "the hook refuses a quoted spelling of the flag" \
    "git diff --no-'index' -- /dev/null ./cosign.key"
  assert_hook_refuses "the hook refuses a backslash spelling of the flag" \
    'git diff --no-\index -- /dev/null ./cosign.key'

  # The write half of the same family. `--output=FILE` is a destination, not a
  # filter, and the fixtures above show what it does to the file it names. The
  # refusal is asserted by its message rather than by exit status alone,
  # because the operand scan refuses some of these spellings for an unrelated
  # reason that would stop holding if it were ever rewritten.
  assert_hook_refuses_naming "the hook refuses git diff --output=FILE" \
    'git diff --output=/tmp/written HEAD~1 HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses the space form of --output" \
    'git diff --output /tmp/written HEAD~1 HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind a git-level option" \
    'git --no-pager diff --output=/tmp/written' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output after another diff flag" \
    'git diff --stat --output=/tmp/written' '--output=FILE'
  # git log is outside the operand scan entirely -- it tracks the diff
  # subcommand and nothing else -- so these two are the reason the refusal sits
  # ahead of it and covers the whole git invocation.
  assert_hook_refuses_naming "the hook refuses --output on git log" \
    'git log -p --output=/tmp/written -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses the space form on git log" \
    'git log -p --output /tmp/written -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output on git show" \
    'git show --output=/tmp/written HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind another command" \
    'ls -l && git log -p --output=/tmp/written -1' '--output=FILE'
  # The shell rewrites this one exactly as it rewrites --no-'index'.
  assert_hook_refuses_naming "the hook refuses a requoted spelling of --output" \
    "git diff --out'put'=/tmp/written" '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output written to the trust anchor" \
    'git log -p --output=cosign.pub -1' '--output=FILE'

  # A two-token git global option used to make the operand scan lose track of
  # git altogether: the directory word was read as the subcommand, `seen_git`
  # was cleared, and the scan below never started. Nothing auto-approves these
  # spellings today -- no allow rule matches them, so they prompt -- but a gate
  # whose coverage rests on an allow rule's exact prefix is one allow-list edit
  # from silence.
  assert_hook_refuses "the hook refuses the plain-file form reached through git -C" \
    'git -C / diff /dev/null etc/shadow'
  assert_hook_refuses "the hook refuses the plain-file form reached through --git-dir" \
    'git --git-dir /tmp/elsewhere/.git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form reached through --work-tree" \
    'git --work-tree /tmp/elsewhere diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form behind git -c" \
    'git -c core.pager=cat diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form behind --namespace" \
    'git --namespace ns diff /dev/null ./cosign.key'
  # `-C` and `-c` are no longer stepped over: each reaches a primitive of its
  # own from in front of the subcommand, so the refusal that fires first is
  # the global-option one rather than `--output`'s. The corpus group below
  # holds why (issue #333).
  assert_hook_refuses_naming "the hook refuses --output reached through git -C" \
    'git -C /tmp diff --output=/tmp/written' 'git global option'

  # Shell operators need no whitespace around them, and this scan splits on
  # whitespace. `git log -1 && (git log -p --output=cosign.pub -1)` tokenizes
  # as `(git`, which is not the word `git`: the second command was not
  # recognized as a git invocation at all, so every test above stayed switched
  # off for it and the hook exited 0 while the trust anchor was overwritten.
  assert_hook_refuses_naming "the hook refuses --output inside an attached subshell" \
    'git log -1 && (git log -p --output=cosign.pub -1)' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output where the subshell opens the command" \
    '(git log -p --output=cosign.pub -1)' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind an unspaced &&" \
    'ls&&git log -p --output=cosign.pub -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind an unspaced ;" \
    'ls;git log -p --output=cosign.pub -1' '--output=FILE'
  # shellcheck disable=SC2016 # the literal $( is the point: this is the
  # command string the hook is handed, not one this script expands.
  assert_hook_refuses_naming "the hook refuses --output inside a command substitution" \
    'echo $(git log -p --output=cosign.pub -1)' '--output=FILE'
  # And an operator sitting inside an argument must not end the git invocation
  # either, which is why the git latch is not cleared at a command boundary:
  # the pipe here would otherwise hand the write primitive back unwatched.
  assert_hook_refuses_naming "the hook refuses --output after an operator inside an argument" \
    'git log --grep=a|b --output=cosign.pub -1' '--output=FILE'
  # The read half had the same hole, with no flag and an ordinary path.
  assert_hook_refuses "the hook refuses the plain-file form behind an unspaced &&" \
    'ls&&git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form inside an attached subshell" \
    '(git diff /dev/null ./cosign.key)'
  assert_hook_refuses "the hook refuses the plain-file form behind a bare -- and an unspaced ;" \
    'ls;git diff -- /dev/null ./cosign.key'

  # And has not quietly traded the allow rule back for a prompt: the ordinary
  # reads this repository does all day must stay silent.
  assert_hook_permits "an ordinary git diff is still unprompted" 'git diff'
  assert_hook_permits "git diff --stat is still unprompted" 'git diff --stat'
  assert_hook_permits "a scoped diff against history is still unprompted" \
    'git diff HEAD~1 -- system_files/'
  assert_hook_permits "git status --short is still unprompted" 'git status --short'
  # Two operands are the plain-file form unless both resolve as revisions, so
  # the check is against the repository, not against the shape of the word. A
  # name that is not a revision here is treated as a path and refused, which is
  # the conservative side of that call.
  # HEAD twice rather than HEAD~1 or a branch name: CI checks out at depth 1,
  # where neither of those resolves, and the point of the assertion is that two
  # revisions are permitted, not which two.
  assert_hook_permits "a two-revision diff is still unprompted" 'git diff HEAD HEAD'
  assert_hook_permits "a diff of one tracked path is still unprompted" 'git diff ./AGENTS.md'
  assert_hook_permits "a pathspec after -- is still unprompted" 'git diff -- ./cosign.key'
  # Two pathspecs inside the working tree are an ordinary diff: git's own
  # test only enters the plain-file mode when one of them lies outside it.
  assert_hook_permits "two pathspecs after -- inside the checkout are still unprompted" \
    'git diff -- ./AGENTS.md ./tests/'
  assert_hook_permits "a revision before -- keeps later pathspecs unprompted" \
    'git diff HEAD -- ./AGENTS.md ./tests/'
  assert_hook_permits "the word diff outside a git call is not a git diff" \
    'grep diff a.txt b.txt'
  # Reading history is the whole point of the two commands the write refusal
  # now also covers, so both must stay silent.
  assert_hook_permits "an ordinary git log -p is still unprompted" 'git log -p -1'
  assert_hook_permits "git show of a revision is still unprompted" 'git show HEAD'
  # --output-indicator-* changes the character in column one, not where the
  # output goes. It is not the write primitive and a gate that cannot tell the
  # two apart would be refusing ordinary formatting.
  assert_hook_permits "git diff --output-indicator-new is still unprompted" \
    'git diff --output-indicator-new=%'
  assert_hook_permits "git log --output-indicator-old is still unprompted" \
    'git log --output-indicator-old=- -1'
  # The refusal is scoped to git invocations. --output is an ordinary flag on
  # other tools, and this hook is not a general write gate -- a command like
  # this one is not on the allow list and prompts on its own account.
  assert_hook_permits "--output on a command that is not git is still unprompted" \
    'sort --output=/tmp/sorted packages-base.txt'
  # Splitting on operator characters must not cost the chained reads this
  # repository does all day: a command boundary restarts the operand scan.
  assert_hook_permits "chained ordinary git reads are still unprompted" \
    'git status && git log --oneline -5'
  assert_hook_permits "an ordinary git read inside a subshell is still unprompted" \
    '(git log -p -1)'
  # Two-token git global options, now that the scan follows them: an ordinary
  # diff behind one that only renames or relocates what git reports is still
  # an ordinary diff. `-C` and `-c` are not in that set any more -- each loads
  # a program or moves git out of the checkout, so both are refused, which the
  # corpus group below records as a decision rather than as an accident.
  assert_hook_permits "a two-revision diff behind --namespace is still unprompted" \
    'git --namespace ns diff HEAD HEAD'
  assert_hook_permits "git --work-tree ... diff --stat is still unprompted" \
    'git --work-tree . diff --stat'

  # --- The other allow-listed command that opens a file it is pointed at ----
  #
  # `Bash(shellcheck *)` is allowed with no prompt as well, and ShellCheck
  # prints the *source line* above every diagnostic it reports. So it prints
  # back whatever it is aimed at: `shellcheck ./.env` echoes every unexported
  # `NAME=value` line of a file `Read(./.env)` refuses, values included, and a
  # PEM-shaped file gives up its `-----BEGIN/END-----` lines and its trailing
  # base64 line. It is a lossy read rather than `cat`, and for the `.env` shape
  # the deny rules name the loss is nothing that matters. The shape of the
  # problem is the same as the git case above: those rules gate the *Read*
  # tool, this is Bash, and nothing consulted them.
  #
  # No permission pattern closes it either -- patterns match by prefix, so
  # `Bash(shellcheck tests/*)` still matches
  # `shellcheck tests/run-tests.sh /home/me/.aws/credentials` -- so the hook
  # checks the operands: inside the working tree, and not one of the
  # secret-shaped names.
  #
  # Demonstrated before it is asserted, for the same reason the fixtures above
  # are. ShellCheck is a declared dependency of this repository (`just lint`
  # hard-errors without it, and the `ubuntu-26.04` runner ships 0.11.0), so its
  # absence is a failure here rather than a silent skip: the alternative is
  # this section going green on a host where the exposure was never reproduced.
  shellcheck_dir="$(mktemp -d)"
  printf '# synthetic fixture\nSYNTHETIC_SECRET=synthetic-value-1\n' \
    >"${shellcheck_dir}/fake.env"
  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck prints the contents of the file it is pointed at" \
      "shellcheck is not on PATH, so the exposure the refusals below exist for could not be reproduced"
  else
    shellcheck_output="$(shellcheck "${shellcheck_dir}/fake.env" 2>&1 || true)"
    if grep -q '^SYNTHETIC_SECRET=synthetic-value-1$' <<<"${shellcheck_output}"; then
      pass "shellcheck prints the contents of the file it is pointed at"
    else
      fail "shellcheck prints the contents of the file it is pointed at" \
        "this shellcheck no longer echoes the source line; re-derive what the refusals below are for"
    fi
  fi
  rm -rf "${shellcheck_dir}"

  # The paths the deny rules name, inside the checkout.
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at ./.env" \
    'shellcheck ./.env' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at ./cosign.key" \
    'shellcheck ./cosign.key' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at a .pem inside the tree" \
    'shellcheck system_files/etc/pki/anything.pem' 'shellcheck prints the source line'
  # And anything outside it, which is where the interesting material usually
  # is: an agent's own credentials rather than the repository's.
  assert_hook_refuses_naming "the hook refuses shellcheck pointed outside the checkout" \
    'shellcheck /etc/shadow' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at a home-directory key" \
    'shellcheck /home/someone/.ssh/id_ed25519' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses the climb-out-and-back-in spelling" \
    "shellcheck ../${checkout_name}/.env" 'shellcheck prints the source line'
  # A flag before the operand must not hide it, and a flag that takes a value
  # must not swallow it: `--shell bash /etc/shadow` is two words of option and
  # one operand.
  assert_hook_refuses_naming "a flag before the operand does not hide it" \
    'shellcheck -S style -o all /etc/shadow' 'shellcheck prints the source line'
  assert_hook_refuses_naming "a value-taking flag does not swallow the operand after its value" \
    'shellcheck --shell bash /etc/shadow' 'shellcheck prints the source line'
  # `-C`'s argument is optional and must be attached, so shellcheck reads
  # `-C always` as the flag plus a file named `always`. The gate reads it the
  # same way, which is why the operand after it is still checked.
  assert_hook_refuses_naming "an optional-argument flag does not swallow the operand" \
    'shellcheck -C always /etc/shadow' 'shellcheck prints the source line'
  # The word need not start the command: an operator boundary in front of
  # it changes nothing, and an environment assignment in front of it is
  # refused for itself first (see the gated-prefix scan), so the read
  # behind it never runs either way.
  assert_hook_refuses_naming "the hook refuses a shellcheck read behind another command" \
    'ls -l && shellcheck ./.env' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses a shellcheck read behind an env assignment" \
    'FOO=bar shellcheck ./.env' 'assignment before'

  # Bash rewrites some words before shellcheck sees them, and the gate reads
  # the words as typed. Two of those rewrites turned a checked operand into a
  # different file (review on aurora-zfs-simple#207, the same gate):
  #   * a leading unquoted `~` is $HOME to bash, and a literal `~` to the
  #     gate -- which `realpath -m -s` resolved to `<checkout>/~/...`, an
  #     inside path, so `shellcheck ~/.aws/credentials` passed. (The
  #     `~/.ssh/id_ed25519` case above was refused only by its basename.)
  #   * an unquoted `*`, `?` or `[` is a glob bash expands into files the
  #     gate never saw: `shellcheck .env*` is one word here, and the .env to
  #     bash.
  # Both shown first, against a throwaway HOME and a synthetic file in a
  # temporary directory of this fixture's own -- never the real $HOME.
  tilde_home="$(mktemp -d)"
  mkdir -p "${tilde_home}/.aws"
  printf 'SYNTHETIC_TILDE_SECRET=synthetic-value-2\n' >"${tilde_home}/.aws/credentials"
  tilde_output="$(HOME="${tilde_home}" bash --norc --noprofile -c 'shellcheck ~/.aws/credentials' 2>&1 </dev/null || true)"
  rm -rf "${tilde_home}"
  if grep -q '^SYNTHETIC_TILDE_SECRET=synthetic-value-2$' <<<"${tilde_output}"; then
    pass "shellcheck ~/path reads the file under \$HOME, which is not the literal ~ the gate resolves"
  else
    fail "shellcheck ~/path reads the file under \$HOME, which is not the literal ~ the gate resolves" \
      "the synthetic line did not appear; re-derive why an unquoted leading ~ is refused"
  fi
  glob_dir="$(mktemp -d)"
  printf 'SYNTHETIC_GLOB_SECRET=synthetic-value-3\n' >"${glob_dir}/.env"
  glob_output="$(cd "${glob_dir}" && bash --norc --noprofile -c 'shellcheck .env*' 2>&1 </dev/null || true)"
  rm -rf "${glob_dir}"
  if grep -q '^SYNTHETIC_GLOB_SECRET=synthetic-value-3$' <<<"${glob_output}"; then
    pass "shellcheck .env* reads the file the glob expands to, which the gate never saw as a word"
  else
    fail "shellcheck .env* reads the file the glob expands to, which the gate never saw as a word" \
      "the synthetic line did not appear; re-derive why an unquoted glob is refused"
  fi
  for rewrite_command in \
    'shellcheck ~/.aws/credentials' \
    'shellcheck ~' \
    'shellcheck ~someone/.bashrc' \
    'shellcheck .env*' \
    'shellcheck cosign.ke?' \
    'shellcheck .en[v]' \
    'shellcheck ./.*' \
    'shellcheck tests/*.sh' \
    'shellcheck -S style tests/run-tests.sh ~/.netrc' \
    'git log -1 && shellcheck ~/.aws/credentials'; do
    assert_hook_refuses_naming "the hook refuses a tilde or glob in a shellcheck operand: ${rewrite_command}" \
      "${rewrite_command}" 'bash rewrites this word'
  done
  # Brace expansion, command substitution and a process substitution are the
  # same rewrite they were for git: one word to a gate reading the typed
  # string, other files to shellcheck. The backtick closes the scope it would
  # be refused in, so it is held on the whole-string latch the git rule uses.
  # shellcheck disable=SC2016 # literal $(...), $F and backticks are the point
  for rewrite_command in \
    'shellcheck {tests/run-tests.sh,/etc/shadow}' \
    'shellcheck $(echo /etc/shadow)' \
    'shellcheck `echo /etc/shadow`' \
    'shellcheck $F' \
    'shellcheck <(cat /etc/shadow)'; do
    assert_hook_refuses_naming "the hook refuses an expansion in a shellcheck operand: ${rewrite_command}" \
      "${rewrite_command}" 'bash rewrites this word'
  done
  # ShellCheck reads file operands out of SHELLCHECK_OPTS as well, so the
  # assignment is refused wherever it stands, including in a command of its
  # own: the Bash tool's shell persists between calls.
  for rewrite_command in \
    'SHELLCHECK_OPTS=/etc/shadow shellcheck tests/run-tests.sh' \
    'export SHELLCHECK_OPTS=/etc/shadow; shellcheck tests/run-tests.sh' \
    'export SHELLCHECK_OPTS=/etc/shadow' \
    'env SHELLCHECK_OPTS=-x shellcheck tests/run-tests.sh'; do
    assert_hook_refuses_naming "the hook refuses a SHELLCHECK_OPTS assignment: ${rewrite_command}" \
      "${rewrite_command}" 'SHELLCHECK_OPTS='
  done

  # The operand scan reads the words after `shellcheck`, and an input
  # redirection puts the path somewhere it never looks. ShellCheck reads
  # standard input when its operand is `-`, so `shellcheck - < .env` prints the
  # file back exactly as `shellcheck ./.env` did, with the scan seeing only the
  # `-` (issue #323). Shown first, against a synthetic file in a temporary
  # directory of this fixture's own, for the reason the operand exposure above
  # is shown: the refusals below are worth nothing if the read they name has
  # stopped happening.
  stdin_dir="$(mktemp -d)"
  printf '# synthetic fixture\nSYNTHETIC_STDIN_SECRET=synthetic-value-4\n' \
    >"${stdin_dir}/fake.env"
  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck prints the contents of the file it is handed on standard input" \
      "shellcheck is not on PATH, so the exposure the refusals below exist for could not be reproduced"
  else
    stdin_output="$(shellcheck - <"${stdin_dir}/fake.env" 2>&1 || true)"
    if grep -q '^SYNTHETIC_STDIN_SECRET=synthetic-value-4$' <<<"${stdin_output}"; then
      pass "shellcheck prints the contents of the file it is handed on standard input"
    else
      fail "shellcheck prints the contents of the file it is handed on standard input" \
        "the synthetic line did not appear; re-derive why the target of a < is checked"
    fi
  fi
  rm -rf "${stdin_dir}"
  # The target is held to the operand test itself: inside the checkout, none of
  # the deny shapes, and spelled out. The descriptor form, the attached
  # operator and the form written before the command name are the same
  # redirection to bash, so they are the same refusal here.
  for stdin_command in \
    'shellcheck - < .env' \
    'shellcheck -s bash - <./cosign.key' \
    'shellcheck - 0< system_files/etc/pki/anything.pem' \
    'shellcheck - < /etc/shadow' \
    'shellcheck - < /home/someone/.ssh/id_ed25519' \
    "shellcheck - < ../${checkout_name}/.env" \
    'shellcheck - < ~/.aws/credentials' \
    'shellcheck - < {tests/run-tests.sh,.env}' \
    'shellcheck - < .env*' \
    '< .env shellcheck -' \
    'git log -1 && shellcheck - < .env' \
    'command -p shellcheck - < .env'; do
    assert_hook_refuses_naming "the hook refuses a shellcheck read through an input redirection: ${stdin_command}" \
      "${stdin_command}" 'shellcheck reads standard input'
  done
  # And nothing else about a `<` changes. A script inside the checkout is the
  # ordinary way to lint from stdin, `/dev/null` prints nothing back, `<<<` is
  # content and `<<` a delimiter rather than a path, and the other gated
  # commands do not read a file from stdin at all.
  for stdin_command in \
    'shellcheck - < tests/run-tests.sh' \
    'shellcheck -s bash - <scripts/quickstart.sh' \
    'shellcheck - < /dev/null' \
    'shellcheck tests/run-tests.sh </dev/null' \
    "shellcheck - <<< 'echo hi'" \
    'df -T < .env' \
    'cat < .env'; do
    assert_hook_permits "an ordinary input redirection is still unprompted: ${stdin_command}" \
      "${stdin_command}"
  done
  # Git reads standard input as well. Under --stdin, git log, git show and
  # git diff take revisions from it and name the first line that is not one
  # in their error, so `git log --stdin <.env` printed the first line of the
  # file while the gate passed every input redirection on a git invocation.
  # Shown first against a synthetic file, for the same reason as above.
  git_stdin_dir="$(mktemp -d)"
  printf 'SYNTHETIC_GIT_STDIN_SECRET=synthetic-value-5\nSECOND=2\n' \
    >"${git_stdin_dir}/fake.env"
  git_stdin_output="$(git log --stdin <"${git_stdin_dir}/fake.env" 2>&1 || true)"
  if grep -q 'SYNTHETIC_GIT_STDIN_SECRET=synthetic-value-5' <<<"${git_stdin_output}"; then
    pass "git log --stdin prints the first line of the file it is handed on standard input"
  else
    fail "git log --stdin prints the first line of the file it is handed on standard input" \
      "the synthetic line did not appear; re-derive why the target of a < on git is checked"
  fi
  rm -rf "${git_stdin_dir}"
  for stdin_command in \
    'git log --stdin <.env' \
    'git show --stdin < ./cosign.key' \
    'git diff --stdin 0<.env.local' \
    'git log --stdin < /etc/shadow' \
    'git log --stdin < ~/.netrc' \
    'git log --stdin < .en?' \
    '<.env git log --stdin' \
    'timeout 5 git log --stdin <.env' \
    'git status; git log --stdin <.env'; do
    assert_hook_refuses_naming "the hook refuses a git read through an input redirection: ${stdin_command}" \
      "${stdin_command}" 'take revisions from standard input'
  done
  # A revision list inside the checkout is how --stdin is meant to be used,
  # and a `git` word that is not the command's name is not a git invocation.
  for stdin_command in \
    'git log --stdin <revs.txt' \
    'git log --stdin </dev/null' \
    'grep git <.env' \
    'git log -1 && cat <.env'; do
    assert_hook_permits "an ordinary input redirection near git is still unprompted: ${stdin_command}" \
      "${stdin_command}"
  done
  # A quoted or escaped glob character is the literal word bash would pass,
  # and a `~` that does not lead the word is a character in a filename.
  for rewrite_command in \
    "shellcheck 'tests/*.sh'" \
    'shellcheck "tests/*.sh"' \
    'shellcheck tests/\*.sh' \
    'shellcheck tests/run-tests.sh~' \
    "shellcheck 'tests/run-tests.sh'"; do
    assert_hook_permits "a quoted glob or a non-leading ~ in a shellcheck operand is unprompted: ${rewrite_command}" \
      "${rewrite_command}"
  done
  # An rc file is not on the skip list, so its path is checked like any other.
  assert_hook_refuses_naming "the hook refuses an rc file outside the tree" \
    'shellcheck --rcfile /home/someone/.shellcheckrc tests/run-tests.sh' \
    'shellcheck prints the source line'

  # None of that may cost the repository its own lint runs.
  assert_hook_permits "linting a tracked script is still unprompted" \
    'shellcheck tests/run-tests.sh'
  assert_hook_permits "linting several tracked scripts at once is still unprompted" \
    'shellcheck ./scripts/quickstart.sh scripts/pr-review-state.sh'
  assert_hook_permits "the attached --shell= spelling is still unprompted" \
    'shellcheck --shell=bash system_files/etc/profile.d/homebrew.sh'
  assert_hook_permits "the space --shell spelling is still unprompted" \
    'shellcheck --shell bash system_files/etc/profile.d/homebrew.sh'
  assert_hook_permits "severity and optional-check flags are still unprompted" \
    'shellcheck -S style -o all tests/check-invariants.sh'
  assert_hook_permits "source-path and external sources are still unprompted" \
    'shellcheck -x -P SCRIPTDIR scripts/quickstart.sh'
  assert_hook_permits "reading a script from stdin is still unprompted" \
    'shellcheck -'
  assert_hook_permits "a script that does not exist yet is still unprompted" \
    'shellcheck tests/test-not-written-yet.sh'
  assert_hook_permits "the word shellcheck outside a shellcheck call is not one" \
    'grep -n shellcheck Justfile'

  # The join that matters most: this repository's own lint recipe must not be
  # refused by this repository's own gate. Read the invocations out of the
  # Justfile rather than restating them, because a restated command list is a
  # second copy with the same drift problem the rest of this file avoids.
  justfile_lint_commands=0
  while IFS= read -r justfile_lint_command; do
    justfile_lint_commands=$((justfile_lint_commands + 1))
    assert_hook_permits \
      "Justfile lint invocation ${justfile_lint_commands} is still unprompted" \
      "${justfile_lint_command}"
  done < <(sed -n 's/^[[:space:]]*\(shellcheck [^#]*\)$/\1/p' "${JUSTFILE}")
  if ((justfile_lint_commands >= 2)); then
    pass "the Justfile lint recipe's shellcheck invocations were found and checked"
  else
    fail "the Justfile lint recipe's shellcheck invocations were found and checked" \
      "found ${justfile_lint_commands}; the recipe has two, so the extraction above stopped matching and those assertions checked nothing"
  fi

  # PreToolUse fires for every Bash call, so a payload shaped differently from
  # the expected one must not block the session.
  assert_hook_payload_permits "an empty payload does not block the session" '{}'
  assert_hook_payload_permits "a payload with no command does not block the session" \
    '{"tool_input":{}}'
  assert_hook_payload_permits "an empty command does not block the session" \
    '{"tool_input":{"command":""}}'
  # Fail closed on a host that cannot inspect the payload. These hooks run
  # wherever a contributor runs Claude Code, not only on the jq-equipped CI
  # runner, and AGENTS.md requires that a control of this kind fail closed
  # rather than wave the call through when a dependency is missing.
  no_jq_dir="$(mktemp -d)"
  for no_jq_tool in bash env git cat; do
    no_jq_path="$(command -v "${no_jq_tool}" 2>/dev/null)" || continue
    ln -sf "${no_jq_path}" "${no_jq_dir}/${no_jq_tool}"
  done

  no_jq_status=0
  no_jq_stderr=""
  for hook_command in "${bash_hooks[@]+"${bash_hooks[@]}"}"; do
    no_jq_payload="$(jq -nc '{tool_name: "Bash", tool_input: {command: "git diff --no-index -- /dev/null ./cosign.key"}}')"
    no_jq_err="$(printf '%s' "${no_jq_payload}" | CLAUDE_PROJECT_DIR="${REPO_ROOT}" PATH="${no_jq_dir}" bash -c "${hook_command}" 2>&1 >/dev/null)"
    no_jq_rc=$?
    ((no_jq_rc > no_jq_status)) && no_jq_status="${no_jq_rc}"
    [[ -n "${no_jq_err}" ]] && no_jq_stderr+="${no_jq_err} "
  done
  rm -rf "${no_jq_dir}"

  if ((no_jq_status == 2)) && [[ -n "${no_jq_stderr}" ]]; then
    pass "the hook refuses rather than passing the call through when jq is missing"
  else
    fail "the hook refuses rather than passing the call through when jq is missing" \
      "exit ${no_jq_status} with stderr '${no_jq_stderr:-<none>}'; a missing dependency silently disables the gate"
  fi

  # A malformed payload is the same case: the hook cannot tell what the call
  # does, so it must not decide that it is safe.
  run_bash_hooks 'not json at all'
  if ((hook_status == 2)) && [[ -n "${hook_stderr}" ]]; then
    pass "the hook refuses a payload it cannot parse"
  else
    fail "the hook refuses a payload it cannot parse" \
      "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; an unparseable payload passed uninspected"
  fi

  # -------------------------------------------------------------------------
  group "The corpus of ways a command reaches a tool past an allow rule (#333)"

  # Everything above grew one spelling at a time: an issue named a shape, a
  # branch closed that shape, and the next issue found the next spelling. Six
  # of the thirteen follow-up commits this lane pushed across six repositories
  # between 2026-09-20 and 2026-09-22 were that shape. Issue #333 names the
  # whole corpus once instead, and this group holds it as *data*: one row per
  # shape, one loop driving them, so a spelling found in a sibling repository
  # is a line here rather than a new test.
  #
  # Five families, which are the issue's own:
  #
  #   1. an environment assignment reaching the tool, in every spelling that
  #      puts a variable there -- `NAME=`, `NAME+=`, through `env`, and the
  #      `export` family, which bash applies to every *later* command so the
  #      gated command carries no assignment at all;
  #   2. a redirection, whose target is the shell's word and not the
  #      command's;
  #   3. a word bash rewrites before the tool sees it -- a brace, a leading
  #      `~`, a glob, a substitution;
  #   4. the word that names the command, which an expansion, a brace, a glob
  #      or a wrapper can spell differently while reaching the same tool;
  #   5. an option that loads a program or writes a path, per tool.
  #
  # The allowed rows are held as tightly as the refused ones on purpose. A
  # gate that refuses ordinary work gets switched off, and "not decided" and
  # "decided to allow" look identical from the outside unless the allowed row
  # is written down with the reason it reaches nothing.
  corpus_shape=()
  corpus_decision=()
  corpus_message=()
  corpus_why=()
  corpus_command=()
  # shape, decision, a substring of the refusal (empty when allowed), why, command
  corpus_row() {
    corpus_shape+=("$1")
    corpus_decision+=("$2")
    corpus_message+=("$3")
    corpus_why+=("$4")
    corpus_command+=("$5")
  }

  # The rows quote shell spellings as literal text -- a `$`, a backtick or a
  # `${VAR}` in a command is exactly what must reach the hook unexpanded -- so
  # the table is a function with one directive rather than eighteen.
  # shellcheck disable=SC2016
  corpus_table() {
  # --- 1. an environment assignment reaching the tool ----------------------
  #
  # None of these appear inside the string an allow rule matches, and each
  # puts a variable in the command's environment. The refusal is every
  # variable rather than a named list: the list would have to track git's
  # whole environment surface and then ShellCheck's and then the loader's, and
  # the name it forgets is the hole.
  corpus_row environment refused 'assignment before an allow-listed command' \
    'GIT_EXTERNAL_DIFF names a program git runs once per changed path; demonstrated below' \
    'GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'appending to an unset variable creates it, so += is not a narrower case of =' \
    'GIT_EXTERNAL_DIFF+=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'points git at another repository and index; two assignments, one command' \
    'GIT_DIR=/tmp/x GIT_INDEX_FILE=/tmp/i git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'env puts it there without bash reading an assignment at all' \
    'env GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    "a wrapper's own option must not be read as the command's name" \
    'env -i GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    "timeout's own -s value must not be read as the command's name either" \
    'timeout -s TERM 60 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    "timeout's mandatory DURATION operand, which carries no dash, must not be read as the name" \
    'timeout 60 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    "nice's own -n value must not be read as the command's name" \
    'nice -n 5 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    "stdbuf's own -o value must not be read as the command's name" \
    'stdbuf -o L GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'env sets it although bash alone would read the quoted word as a command name' \
    "env 'GIT_EXTERNAL_DIFF'=/tmp/evil git diff HEAD"
  corpus_row environment refused 'env -S' \
    'env -S splits a quoted string into a command this gate never sees as words' \
    "env -S 'GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'"
  corpus_row environment refused 'env -S' \
    'the long spelling of the same interpreter' \
    "env --split-string='GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'"
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'bash applies an export to every later command, so the gated command carries no assignment' \
    'export GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'the append operator, in the export spelling' \
    'export GIT_EXTERNAL_DIFF+=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'declare -x exports; what decides is the -x, not the name of the builtin' \
    'declare -x GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'typeset is declare under another name' \
    'typeset -x GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'bash rejects readonly -x outright, and other shells do not; listing it costs nothing' \
    'readonly -x GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'allexport turns an assignment that is its own command into an export' \
    'set -a; GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    'the long spelling of set -a' \
    'set -o allexport; GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment refused 'an export in a string that also runs an allow-listed command' \
    "nothing gated follows the export, and the next Bash call's git diff still runs it: the tool's shell outlives one call, which is why the rule is not ordered" \
    'git status --short; export GIT_EXTERNAL_DIFF=/tmp/evil'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'a newline is a command separator, so the second command is reached like any other' \
    'git log -1
GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'the loader reaches every one of these commands, not only the ones with variables of their own' \
    'LD_PRELOAD=/tmp/evil.so shellcheck tests/run-tests.sh'
  corpus_row environment refused 'assignment before an allow-listed command' \
    'names a file for the inner bash to read before it parses anything' \
    'BASH_ENV=/tmp/x bash -n tests/run-tests.sh'
  corpus_row environment refused 'assignment before an allow-listed command' \
    're-points podman at another configuration' \
    'CONTAINERS_CONF=/tmp/x podman images'
  corpus_row environment refused 'SHELLCHECK_OPTS=' \
    'ShellCheck reads file operands out of its options too, and that message names the operand' \
    'env SHELLCHECK_OPTS=/etc/shadow shellcheck tests/run-tests.sh'
  corpus_row environment allowed '' \
    'an assignment that is its own command sets a shell variable, not an environment one, so it reaches no child; set -a is the spelling that changes that, and it is a row above' \
    'X=$(date); git diff HEAD'
  corpus_row environment allowed '' \
    'a bare declare exports nothing (verified against bash 5.2), so it reaches no child' \
    'declare GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment allowed '' \
    'readonly without -x exports nothing either; refusing it would refuse a reach that is not there' \
    'readonly GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  corpus_row environment allowed '' \
    'the option that matters is -a; the rest of set changes nothing a child can see' \
    'set -e; git diff HEAD'
  corpus_row environment allowed '' \
    'a string that runs nothing this gate covers matches no allow rule and prompts on its own' \
    'export FOO=bar'
  corpus_row environment allowed '' \
    'the assignment reaches echo, which no allow rule covers and which opens nothing' \
    'FOO=bar echo hi'
  corpus_row environment allowed '' \
    "-p lists what is already exported and adds nothing a later command inherits" \
    'git status; export -p'
  corpus_row environment allowed '' \
    "-n unexports rather than exports; a name after it is being removed, not added" \
    'export -n GIT_EXTERNAL_DIFF; git diff HEAD'

  # --- 2. redirection ------------------------------------------------------
  #
  # Output opens a path for writing before the command runs. Input hands the
  # tool a file, which matters for the one allow-listed command that prints
  # back what it reads.
  corpus_row redirection refused 'output redirection' \
    'truncates the trust anchor before git starts' \
    'git diff HEAD >cosign.pub'
  corpus_row redirection refused 'output redirection' \
    'bash lets the redirection precede the name; it is the same command' \
    '>cosign.pub git diff HEAD'
  corpus_row redirection refused 'output redirection' \
    'read-write opens the path and creates it' \
    'git diff HEAD <>cosign.pub'
  corpus_row redirection refused 'output redirection' \
    'the noclobber form writes wherever plain > would' \
    'git show HEAD >| .claude/settings.json'
  corpus_row redirection refused 'output redirection' \
    'an allow row ending in * matches a command prefix while the redirection is the rest of the string' \
    'shellcheck tests/run-tests.sh >cosign.pub'
  corpus_row redirection refused 'output redirection' \
    "a wrapper's own option must not be read as the name, or the gated prefix starts a word early and matches no allow row" \
    'git status; env -i podman images >cosign.pub'
  corpus_row redirection refused 'shellcheck reads standard input' \
    'ShellCheck echoes the source line of what it is given on stdin, and the operand scan sees only the -' \
    'shellcheck - < .env'
  corpus_row redirection refused 'shellcheck reads standard input' \
    'the same, written before the name, which bash attaches to the same simple command' \
    '< .env shellcheck -'
  corpus_row redirection refused 'take revisions from standard input' \
    'git log --stdin names the first line that is not a revision in its error, so the redirection target is read back' \
    'git log --stdin <.env'
  corpus_row redirection refused 'take revisions from standard input' \
    'the same, written before the name, which bash attaches to the same simple command' \
    '<./cosign.key git show --stdin'
  corpus_row redirection refused 'prints the line a syntax error stands on' \
    'bash -n reads its script from stdin when no file is named, and prints the line a syntax error stands on' \
    'bash -n - < .env'
  corpus_row redirection refused '--no-index mode' \
    "the stdin operand is how a file reaches git's plain-file mode; it counts as an operand" \
    'git diff /etc/shadow -'
  corpus_row redirection allowed '' \
    'a descriptor form names no path, and a pipe opens none' \
    'git diff HEAD 2>&1 | tail -5'
  corpus_row redirection allowed '' \
    'an input redirection opens nothing for writing, and git diff prints no stdin back' \
    'git diff HEAD </dev/null'
  corpus_row redirection allowed '' \
    'nothing is printed back from /dev/null, and </dev/null is how a session says "no stdin"' \
    'shellcheck tests/run-tests.sh </dev/null'
  corpus_row redirection allowed '' \
    "a redirection on another command of the string is that command's own" \
    'echo x >out; git diff HEAD'

  # --- 3. a word bash rewrites before the tool sees it ---------------------
  corpus_row rewriting refused 'expands braces' \
    'one word here, two operands at git' \
    'git diff {/dev/null,./cosign.key}'
  corpus_row rewriting refused 'unquoted leading ~' \
    'an unquoted leading ~ is $HOME to bash and a directory inside the checkout to a scan' \
    'git diff -- ~/.aws/credentials ~/.bashrc'
  corpus_row rewriting refused 'expands a glob' \
    'a glob is one word here and however many files match at git; two of them is the plain-file read, demonstrated below' \
    'git diff ./cosign.*'
  corpus_row rewriting refused 'expands a glob' \
    'the deny rows name paths inside the checkout, so "a glob cannot leave the working directory" is no reason to expand it and check the result' \
    'git diff /home/nonexistent-user/.ssh/*'
  corpus_row rewriting refused 'expands a glob' \
    '? and [ expand as readily as *' \
    'git log --oneline -1 -- ./cosign.?ub'
  corpus_row rewriting refused 'expands ANSI-C quotes and substitutions' \
    'a substitution supplies operands the scan never counted' \
    'git diff $(echo /dev/null) ./cosign.key'
  corpus_row rewriting refused 'expands braces' \
    'process substitution hands git a /dev/fd path as an operand' \
    'git diff <(true) ./cosign.key'
  corpus_row rewriting refused 'bash rewrites this word before shellcheck sees it' \
    'one word here and the file to bash' \
    'shellcheck .env*'
  corpus_row rewriting allowed '' \
    "a quoted glob is a literal to bash and git's own pathspec, matched against repository content rather than against the filesystem" \
    "git diff -- '*.md'"
  corpus_row rewriting allowed '' \
    "a brace with no comma or .. inside it is a literal to bash, and this is git's revision syntax" \
    'git diff HEAD@{1}'
  corpus_row rewriting allowed '' \
    'a backslash inside double quotes escapes the quote after it, so the * is still quoted and a literal to bash' \
    'shellcheck "tests/run-tests\"*.sh"'
  corpus_row rewriting allowed '' \
    "the rewriting rules are scoped to the words of a git invocation; this program is awk's" \
    'git diff HEAD | awk '"'"'{print $1}'"'"''
  corpus_row rewriting allowed '' \
    'a glob in another command of the string is not a word git receives' \
    'ls *.md; git status'

  # --- 4. the word that names the command ----------------------------------
  corpus_row 'command name' refused 'Spell every command name literally' \
    'no scope opens at $G, and bash runs the plain-file read' \
    'git status; G=git; $G diff /dev/null ./cosign.key'
  corpus_row 'command name' refused 'Spell every command name literally' \
    'bash drops the empty word of {,git} and runs git' \
    'git status; {,git} diff /dev/null ./cosign.key'
  corpus_row 'command name' refused 'Spell every command name literally' \
    'pathname expansion resolves the name too' \
    'git status; g?t diff /dev/null ./cosign.key'
  corpus_row 'command name' refused '--no-index mode' \
    'a literal path to git needs no expansion at all and is read as git' \
    'git status; /usr/bin/git diff /dev/null ./cosign.key'
  corpus_row 'command name' refused '--no-index mode' \
    'a wrapper runs its arguments; the name is looked for at every word after it' \
    'git status; command git diff /dev/null ./cosign.key'
  corpus_row 'command name' refused '--no-index mode' \
    'the same, with an option of the wrapper in between' \
    'git status; nice -n 5 git diff /dev/null ./cosign.key'
  corpus_row 'command name' refused 'shellcheck prints the source line' \
    'a wrapper reaches the other allow-listed command that opens what it is pointed at' \
    'git status; env -i shellcheck ./.env'
  corpus_row 'command name' allowed '' \
    'reading a path as git is what makes the refusals reach it; the ordinary command still runs' \
    '/usr/bin/git diff HEAD'
  corpus_row 'command name' allowed '' \
    'a wrapper is not itself a reach: the name behind it is held to the literal test and this one is literal' \
    'timeout 60 git diff HEAD'
  corpus_row 'command name' allowed '' \
    'the wrapper option that removes a variable adds nothing to the environment' \
    'env -u X git diff HEAD'
  # Two wrappers the permission layer sees past, which this hook read wrongly.
  # `noglob` was missing from the wrapper list, so it was read as the name
  # and the command behind it was never reached. `xargs` was stepped over,
  # which is not enough: it appends operands read from standard input (or
  # from the file -a names) that the string never holds, and Claude Code
  # matches `xargs <row>` against every allow row ending in `*`. The first
  # xargs row is demonstrated below.
  corpus_row 'command name' refused 'xargs adds the words' \
    'xargs hands git both operands of the plain-file read from its standard input, and nothing after git diff is there to count' \
    "printf '%s\n' /dev/null ./cosign.key | xargs git diff"
  corpus_row 'command name' refused 'xargs adds the words' \
    'the operands come from a file the redirection names, which is not an operand either' \
    'xargs git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    "xargs's own -a reads the operands from a file with no redirection at all" \
    'xargs -a list.txt git diff'
  corpus_row 'command name' refused 'xargs adds the words' \
    'xargs is refused wherever it stands in the wrapper chain, not only as the first word' \
    'timeout 5 xargs git diff'
  corpus_row 'command name' refused 'xargs adds the words' \
    'the replace string puts each line where {} stands; this row was once listed as permitted' \
    'xargs -I{} git diff {} < list'
  corpus_row 'command name' refused 'xargs adds the words' \
    'the other allow-listed command that prints what it is pointed at, fed the path on stdin' \
    "printf '%s\n' ./.env | xargs shellcheck"
  corpus_row 'command name' refused 'output redirection' \
    "noglob is a wrapper Claude Code steps over; read as the name, it hid the allow-listed podman ps behind it" \
    'noglob podman ps >out'
  corpus_row 'command name' refused 'output redirection' \
    'the same with the redirection written before the name, which is carried to a git that noglob no longer hides' \
    '>cosign.pub noglob git diff HEAD'
  corpus_row 'command name' allowed '' \
    'xargs in front of a command no allow rule covers matches no allow row and prompts on its own' \
    'git diff --name-only | xargs echo'
  corpus_row 'command name' allowed '' \
    'xargs as a word of git is a pattern, not a wrapper' \
    'git log --grep=xargs -1'
  corpus_row 'command name' allowed '' \
    'the same xargs, feeding a command that opens only what git listed and matches no allow row' \
    'git ls-files | xargs wc -l'
  corpus_row 'command name' allowed '' \
    'noglob is stepped over like the other wrappers, and the diff behind it is an ordinary one' \
    'noglob git diff HEAD'
  # A wrapper spelled as a path is found by its last component, cut at `/`
  # and at `\` as Claude Code's matcher cuts it. Compared on the whole word,
  # `/usr/bin/xargs` was read as the name, so the command behind it reached
  # no scan (review on zfs-kinoite-complex#235). Only `/usr/bin/NAME` and
  # `/bin/NAME` are stepped over; any other path runs a file of the
  # caller's choosing while the matcher steps over it, and is refused
  # (review on atomic-image-builder#438). The match runs after the
  # literal-name test, so a path built at runtime is still refused as a name.
  corpus_row 'command name' refused 'xargs adds the words' \
    'read as the name, /usr/bin/xargs hid the git behind it from every scan while bash ran xargs all the same' \
    'git status; /usr/bin/xargs git diff'
  corpus_row 'command name' refused 'output redirection' \
    'the same for every wrapper: the gated prefix starts at the word the wrapper runs' \
    '/usr/bin/timeout 5 shellcheck tests/run-tests.sh >out'
  corpus_row 'command name' refused 'output redirection' \
    'noglob by path is noglob' \
    '/usr/bin/noglob podman ps >out'
  corpus_row 'command name' refused 'assignment before an allow-listed command' \
    'env by path puts the variable in git'"'"'s environment exactly as env does' \
    '/usr/bin/env GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  corpus_row 'command name' refused 'env -S' \
    'env by path still splits its quoted string into a command this gate never sees as words' \
    "/usr/bin/env -S 'git diff /dev/null ./cosign.key'"
  corpus_row 'command name' refused 'Spell every command name literally' \
    'a wrapper is matched by path only once the word is literal; $D/env runs whatever $D holds' \
    'git status; $D/env git diff HEAD'
  corpus_row 'command name' allowed '' \
    'a literal path to a wrapper is stepped over like the wrapper, and the diff behind it is an ordinary one' \
    '/usr/bin/timeout 60 git diff HEAD'
  corpus_row 'command name' refused 'wrapper written as a path' \
    'the matcher steps over it as nohup, and bash runs whatever file ./shim/nohup is' \
    './shim/nohup git diff HEAD'
  corpus_row 'command name' refused 'wrapper written as a path' \
    'a file named shim\nohup to bash, and nohup to a matcher that also cuts at a backslash' \
    "'./shim\nohup' git diff HEAD"
  corpus_row 'command name' refused 'wrapper written as a path' \
    'the same in front of an allow-listed command other than git' \
    '/tmp/timeout 5 shellcheck tests/run-tests.sh'
  corpus_row 'command name' refused 'output redirection' \
    'an external time by path is a wrapper like the others, not a name: the redirection is shellcheck'"'"'s (review on #339)' \
    '/usr/bin/time shellcheck tests/run-tests.sh >cosign.pub'
  corpus_row 'command name' refused 'bash -n' \
    'the same with time'"'"'s own -p in front of the linter it runs' \
    '/usr/bin/time -p bash -n +n -c x'
  # The step-over is decided on the word as typed (review on sensi#259). An
  # unquoted backslash is removed by bash and kept by the matcher, which cuts
  # the text at it: `/usr/bin\timeout` is `/usr/bintimeout` to bash, not
  # found, and the redirection target is already truncated by then.
  corpus_row 'command name' refused 'wrapper written as a path' \
    'bash runs /usr/bintimeout, which is not found after the target is truncated, while the matcher steps over timeout' \
    '/usr/bin\timeout 5 podman ps >out'
  corpus_row 'command name' refused 'wrapper written as a path' \
    'the same with no directory at all' \
    'x\nohup podman ps >out'
  corpus_row 'command name' refused 'wrapper written as a path' \
    "a quoted backslash stays in the name bash looks up on PATH, and the matcher still cuts at it" \
    "'\\nohup' git diff HEAD"
  # The command xargs runs is the first word after xargs's own options, read
  # the way GNU findutils and uutils read them, and the words after it are
  # its arguments; an option the two read differently, or one neither has,
  # leaves every later word a possible name (review on
  # aurora-zfs-simple#224).
  corpus_row 'command name' refused 'xargs adds the words' \
    "an xargs option's value in the next word is the option's, and git is the command after it" \
    'xargs -n 1 git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    "the same for a long option's value" \
    'xargs --max-args 1 git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    "-- ends xargs's options" \
    'xargs -- git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    "an option's value spelled as a keyword is still the value, not a keyword" \
    'xargs -I if git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    'xargs running a wrapper: the wrapper is not the command, the git behind it is' \
    'xargs timeout 5 git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    'GNU findutils and uutils read --max-lines with a separate value differently, so every later word may be the name' \
    'xargs --max-lines 1 git diff <list.txt'
  corpus_row 'command name' refused 'xargs adds the words' \
    'an option neither implementation has leaves every later word a possible name' \
    'xargs -J % git diff <list.txt'
  corpus_row 'command name' allowed '' \
    'xargs runs grep, and git is its pattern; grep matches no allow row and prompts on its own' \
    'git ls-files | xargs grep -l git'
  corpus_row 'command name' allowed '' \
    'xargs runs rg, and shellcheck is its argument' \
    'git ls-files | xargs rg shellcheck'
  corpus_row 'command name' allowed '' \
    "an xargs option's attached value is part of the option word" \
    'git ls-files | xargs -n1 rg shellcheck'
  corpus_row 'command name' allowed '' \
    'a cluster of xargs flags that take no value is read letter by letter, and rg is the command after it' \
    'git ls-files -z | xargs -0r rg shellcheck'
  corpus_row 'command name' allowed '' \
    'a long xargs flag that takes no value is stepped over, and rg is the command after it' \
    'git ls-files -z | xargs --null rg shellcheck'
  corpus_row 'command name' allowed '' \
    "-e's end-of-file string attached to the flag is read the same way by both implementations" \
    'git ls-files | xargs -eEOF grep -l git'
  corpus_row 'command name' refused 'xargs adds the words' \
    'GNU findutils and uutils read a bare -e differently, so every later word may be the name' \
    'git ls-files | xargs -e grep -l git'

  # --- 5. an option that loads or writes -----------------------------------
  corpus_row options refused 'git global option' \
    'the config spelling of GIT_EXTERNAL_DIFF: it runs that program once per changed path, demonstrated below' \
    'git status; git -c diff.external=/tmp/evil diff HEAD'
  corpus_row options refused 'git global option' \
    'git takes the value attached to the option as readily as after it' \
    'git status; git -ccore.sshCommand=/tmp/evil diff HEAD'
  corpus_row options refused 'git global option' \
    'names an environment variable to take the config value from' \
    'git status; git --config-env=core.pager=EV diff HEAD'
  corpus_row options refused 'git global option' \
    'moves git to another directory, so the containment test answers about a directory git has already left' \
    'git status; git -C /home/nonexistent-user diff -- .netrc .profile'
  corpus_row options refused 'git global option' \
    'the value form of GIT_EXEC_PATH, which the environment rule refuses in every other spelling' \
    'git status; git --exec-path=/tmp diff HEAD'
  corpus_row options refused '--output=FILE' \
    'writes the diff to a path instead of stdout, in every subcommand that generates one' \
    'git log -p --output=cosign.pub -1'
  corpus_row options refused 'bash -n' \
    '+n turns noexec back off, so the linter runs what it was asked to parse' \
    'bash -n +n -c "cat ./cosign.key"'
  corpus_row options refused 'print or copy what it reads' \
    '-v prints every line bash reads, and -n does not stop it' \
    'bash -n -v tests/run-tests.sh'
  corpus_row options refused 'print or copy what it reads' \
    'bash reads -nv as -n -v, and the string begins with the characters of the allow row' \
    'bash -nv tests/run-tests.sh'
  corpus_row options refused 'print or copy what it reads' \
    'the long spelling of -v' \
    'bash -n -o verbose tests/run-tests.sh'
  corpus_row options refused 'print or copy what it reads' \
    'an o inside a cluster takes the next word as its value, as bash reads it' \
    'bash -n -no verbose tests/run-tests.sh'
  corpus_row options refused 'prints the line a syntax error stands on' \
    'a bash -n operand is held to the shellcheck operand test' \
    'bash -n .env'
  corpus_row options allowed '' \
    '-O takes a value, and no shopt name prints what bash reads' \
    'bash -n -O extglob tests/run-tests.sh'
  corpus_row options refused 'print or copy what it reads' \
    'exec -l puts a dash in front of the zeroth argument, which makes bash a login shell that reads ~/.bash_profile' \
    'exec -l bash -n tests/run-tests.sh'
  corpus_row options refused 'print or copy what it reads' \
    'env --argv0 can set the same dash' \
    'env --argv0=-bash bash -n tests/run-tests.sh'
  corpus_row options refused 'shellcheck prints the source line' \
    'a value-taking option must be stepped over so the operand after it is still reached' \
    'shellcheck -f gcc ./.env'
  corpus_row options refused 'shellcheck prints the source line' \
    '--rcfile is deliberately not stepped over, so its path is checked like any other operand' \
    'shellcheck --rcfile /etc/shadow tests/run-tests.sh'
  corpus_row options refused 'git difftool' \
    'the subcommand spelling of the external diff program, which Bash(git diff*) matches on its prefix and which needs neither an assignment nor a config option' \
    'git difftool --no-prompt --extcmd=/tmp/evil HEAD~1 HEAD'
  corpus_row options refused 'git difftool' \
    'the one-letter spelling of the same option, with the prompt suppressed by -y' \
    'git difftool -y -x /tmp/evil HEAD'
  corpus_row options allowed '' \
    'only the subcommand is refused, so the word in a pattern or a path is still an ordinary argument' \
    'git log --grep=difftool -1'
  corpus_row options allowed '' \
    "-c after the subcommand is git's combined-diff flag, not the config option" \
    'git show -c HEAD'
  corpus_row options allowed '' \
    '--namespace, --super-prefix, --attr-source, --git-dir and --work-tree rename or relocate what git reports rather than loading a program, so they are stepped over and the subcommand behind them is still found' \
    'git --namespace x diff -- cosign.pub LICENSE'
  corpus_row options allowed '' \
    'changes the marker character rather than the destination' \
    'git log --output-indicator-new=% -1'
  corpus_row options allowed '' \
    'linting this repository own scripts is what the allow row exists for' \
    'shellcheck tests/run-tests.sh tests/check-invariants.sh'
  }
  corpus_table

  # Every row decides the way it says it does. This is the one loop the issue
  # asks for: a new shape is a `corpus_row` line, not a new assertion.
  for ((corpus_i = 0; corpus_i < ${#corpus_command[@]}; corpus_i++)); do
    if [[ "${corpus_decision[corpus_i]}" == refused ]]; then
      assert_hook_refuses_naming \
        "corpus (${corpus_shape[corpus_i]}): ${corpus_command[corpus_i]}" \
        "${corpus_command[corpus_i]}" "${corpus_message[corpus_i]}"
    else
      assert_hook_permits \
        "corpus (${corpus_shape[corpus_i]}), allowed because ${corpus_why[corpus_i]}: ${corpus_command[corpus_i]}" \
        "${corpus_command[corpus_i]}"
    fi
  done

  # The table itself, so that it cannot quietly become a list of refusals or
  # lose a family: an absent row and a passing row are the same colour on a
  # dashboard.
  corpus_table_ok=1
  corpus_table_why=''
  for corpus_family in environment redirection rewriting 'command name' options; do
    corpus_rows=0
    corpus_refusals=0
    corpus_permits=0
    for ((corpus_i = 0; corpus_i < ${#corpus_command[@]}; corpus_i++)); do
      [[ "${corpus_shape[corpus_i]}" == "${corpus_family}" ]] || continue
      ((corpus_rows++))
      if [[ "${corpus_decision[corpus_i]}" == refused ]]; then
        ((corpus_refusals++))
      else
        ((corpus_permits++))
      fi
    done
    if ((corpus_rows < 4 || corpus_refusals == 0 || corpus_permits == 0)); then
      corpus_table_ok=0
      corpus_table_why+="${corpus_family} has ${corpus_rows} row(s), ${corpus_refusals} refused, ${corpus_permits} allowed; "
    fi
  done
  for ((corpus_i = 0; corpus_i < ${#corpus_command[@]}; corpus_i++)); do
    [[ -n "${corpus_why[corpus_i]}" ]] ||
      { corpus_table_ok=0; corpus_table_why+="a row without a reason records no decision: ${corpus_command[corpus_i]}; "; }
    if [[ "${corpus_decision[corpus_i]}" == refused ]]; then
      [[ -n "${corpus_message[corpus_i]}" ]] ||
        { corpus_table_ok=0; corpus_table_why+="a refused row that names no message cannot tell the refusals apart: ${corpus_command[corpus_i]}; "; }
    else
      [[ -z "${corpus_message[corpus_i]}" ]] ||
        { corpus_table_ok=0; corpus_table_why+="an allowed row carries a refusal message: ${corpus_command[corpus_i]}; "; }
    fi
  done
  if ((corpus_table_ok)); then
    pass "the corpus covers all five families with both decisions in each (${#corpus_command[@]} rows)"
  else
    fail "the corpus covers all five families with both decisions in each (${#corpus_command[@]} rows)" \
      "${corpus_table_why}"
  fi

  # Shapes of the corpus that no allow rule in this repository reaches.
  # "Not reachable" is a decision like any other, and left as a comment it
  # rots the first time somebody adds an allow row -- so each one is checked
  # against the settings file rather than asserted in prose. Each entry is a
  # command prefix that would have to become allow-listed for the shape to
  # matter here.
  unreachable_probe=()
  unreachable_why=()
  unreachable_row() {
    unreachable_probe+=("$1")
    unreachable_why+=("$2")
  }
  unreachable_row 'python3' \
    "python's -c and -m, PYTHONPATH, PYTHONSTARTUP: no python interpreter is on the allow list, so any python invocation prompts"
  unreachable_row 'pytest' \
    "pytest's -p, -W, --pdbcls and --doctest-modules, and PYTEST_ADDOPTS: this repository's tests are plain bash and no pytest row exists"
  unreachable_row 'cosign' \
    "cosign --output-file truncates the path it names before verifying anything; cosign is not allow-listed here, so it prompts"
  unreachable_row 'git fetch' \
    "git's --upload-pack and --receive-pack are options of fetch, clone and push, none of which is allow-listed. Listed so an allow row for one is not a hole nobody noticed"
  unreachable_row 'podman build' \
    "podman's --volume, --privileged and the rest: podman build and podman run are in ask, never allow, so a human reads the whole command"
  unreachable_row 'gh' \
    'GH_HOST and GH_TOKEN send the token elsewhere; no gh row is on the allow list here'

  mapfile -t allow_bash_prefixes < <(
    jq -r '.permissions.allow[]? | select(startswith("Bash(")) | ltrimstr("Bash(") | rtrimstr(")") | rtrimstr("*")' \
      "${CLAUDE_SETTINGS}"
  )
  if ((${#allow_bash_prefixes[@]} > 0)); then
    pass "${CLAUDE_SETTINGS} still has Bash allow rules to check the unreachable shapes against"
  else
    fail "${CLAUDE_SETTINGS} still has Bash allow rules to check the unreachable shapes against" \
      "no Bash(...) allow row parsed, so the unreachable rows below are asserted against nothing"
  fi
  for ((corpus_i = 0; corpus_i < ${#unreachable_probe[@]}; corpus_i++)); do
    unreachable_hit=''
    for allow_prefix in "${allow_bash_prefixes[@]+"${allow_bash_prefixes[@]}"}"; do
      [[ -z "${allow_prefix}" ]] && continue
      if [[ "${unreachable_probe[corpus_i]}" == "${allow_prefix}"* ||
        "${allow_prefix}" == "${unreachable_probe[corpus_i]}"* ]]; then
        unreachable_hit+="${allow_prefix} "
      fi
    done
    if [[ -z "${unreachable_hit}" ]]; then
      pass "the shape recorded as not reachable here is still not reachable: ${unreachable_probe[corpus_i]}"
    else
      fail "the shape recorded as not reachable here is still not reachable: ${unreachable_probe[corpus_i]}" \
        "an allow rule now covers it (${unreachable_hit}), so the recorded decision is stale: ${unreachable_why[corpus_i]}"
    fi
  done

  # A redirection written after a subshell, a brace group or a keyword
  # compound command:
  # `(git diff HEAD) >cosign.pub` and `{ git log --stdin; } <cosign.key`
  # write and read the same files as the refused `git diff HEAD >cosign.pub`
  # and `git log --stdin <cosign.key`, but the redirection stands outside the
  # git command, and the hook does not charge it to git (issue #355). It does
  # not need to while nothing here reaches those strings: Claude Code asks
  # before it runs any command that contains a subshell or a brace group,
  # whatever the allow rows say about the command inside ("Contains
  # subshell", "Contains compound_statement"). Checked on 2.1.273 and 2.1.280
  # with `Bash(git diff:*)` and `Bash(git log:*)` allowed, in the default and
  # acceptEdits modes, and in both the `:*` and the ` *` spelling used here;
  # the `if`, `for`, `while` and function forms were asked the same way
  # ("Contains if_statement" and so on). The one way such a string ran with
  # no prompt was a row that names the grouped string itself
  # (`Bash({ git diff HEAD; } >out3.txt)` ran exactly that string), or a row
  # that allows everything (`Bash`, `Bash(*)`). A wildcard row whose fixed
  # part opens a compound (`Bash(if true:*)`) matches such a string the same
  # way. This fails if a row like that is added.
  #
  # What counts: a row naming a compound command has a parenthesis or a brace
  # in it, or, for the keyword forms (`if ...; then ...; fi >f`), what ends
  # each part: a `;`, a newline or a lone `&` (`if true & then ... & fi >f` is
  # the same `if`). The `&` in `&&`, `2>&1`, `&>` and `|&` ends nothing, so it
  # is taken out first (aurora-zfs-simple#241). A row with a `*` counts when
  # the text in front of the `*` is empty or could begin a compound:
  # `Bash(*)`, `Bash(if *)`, `Bash(i*)`, `Bash(time:*)`. Each row is printed
  # as JSON so one with a newline in it stays one row.
  # shellcheck disable=SC2016 # the $ names are jq variables, not shell ones
  grouped_filter='
    def reaches_a_group:
      ["if", "for", "while", "until", "case", "select", "function", "coproc", "time", "!"] as $openers
      | (gsub("&&|[<>|]&|&>"; "") | test("[(){};&\n]"))
        or (gsub("\\s"; "") == "")
        or (contains("*") and (
          (if endswith(":*") and (.[:-2] | contains("*") | not) then .[:-2] + " " else split("*")[0] end) as $head
          | [$head | splits("\\s+") | select(. != "")] as $words
          | ($words | length) == 0
            or (($words | length) == 1 and ($head | test("\\s$") | not)
                and any($openers[]; startswith($words[0])))
            or ($words[0] as $first | any($openers[]; . == $first))
        ));
    .permissions.allow[]?
    | select(. == "Bash" or (startswith("Bash(") and (ltrimstr("Bash(") | rtrimstr(")") | reaches_a_group)))
    | @json
  '
  grouped_rows="$(jq -r "${grouped_filter}" "${CLAUDE_SETTINGS}")"
  if [[ -z "${grouped_rows}" ]]; then
    pass "no allow rule reaches a redirection written after a compound command"
  else
    fail "no allow rule reaches a redirection written after a compound command" \
      "${grouped_rows//$'\n'/ } can let a command that contains a subshell, a brace group or an if/for/while compound run with no prompt, and the hook does not charge a redirection written after the group to the command inside it. Teach the hook that before adding the row."
  fi
  # The settings file has no row of the first list, so the check above passes
  # whatever the filter looks for. These rows hold the filter to its job.
  grouped_reaching='[
    "Bash",
    "Bash()",
    "Bash(*)",
    "Bash(:*)",
    "Bash({ git diff HEAD; } >out)",
    "Bash((git diff HEAD) >out)",
    "Bash(if true; then git diff HEAD; fi >out)",
    "Bash(for f in a; do git diff HEAD; done >out)",
    "Bash(while false; do :; done >out)",
    "Bash(if true\nthen git diff HEAD\nfi >out)",
    "Bash(if true & then git diff HEAD & fi >out)",
    "Bash(if *)",
    "Bash(if:*)",
    "Bash(if true:*)",
    "Bash(for f in a:*)",
    "Bash(while *)",
    "Bash(i*)",
    "Bash(time *)",
    "Bash(! *)"
  ]'
  grouped_plain='[
    "Bash(git diff:*)",
    "Bash(git diff *)",
    "Bash(git status*)",
    "Bash(git diff HEAD >out)",
    "Bash(git diff HEAD 2>&1)",
    "Bash(git status && git diff HEAD)",
    "Bash(git diff HEAD &>out)",
    "Bash(git diff HEAD |& cat)",
    "Bash(ruff check)",
    "Bash(t:*)",
    "Bash(ifconfig:*)",
    "Read(*)"
  ]'
  grouped_picked="$(jq -n --argjson reaching "${grouped_reaching}" --argjson plain "${grouped_plain}" \
    '{permissions: {allow: ($reaching + $plain)}}' | jq -r "${grouped_filter}")"
  grouped_expected="$(jq -r '.[] | @json' <<<"${grouped_reaching}")"
  if [[ "${grouped_picked}" == "${grouped_expected}" ]]; then
    pass "the grouped-row filter picks every row that reaches a group and no plain row"
  else
    fail "the grouped-row filter picks every row that reaches a group and no plain row" \
      "expected ${grouped_expected//$'\n'/ } but it picked ${grouped_picked//$'\n'/ }"
  fi

  # The reaches the new rules exist for, run rather than reasoned about. A
  # refusal asserted against a described exposure is a refusal that outlives
  # the exposure; these build a throwaway repository and show git executing a
  # program named by an environment variable, by a config option, and printing
  # two files a single globbed word expanded to.
  corpus_repo="$(mktemp -d)"
  git -c init.defaultBranch=main init --quiet "${corpus_repo}/repo" >/dev/null 2>&1
  printf 'one\n' >"${corpus_repo}/repo/tracked"
  git -C "${corpus_repo}/repo" add tracked >/dev/null 2>&1
  git -C "${corpus_repo}/repo" -c user.name=invariants \
    -c user.email=invariants@example.invalid commit -q -m first >/dev/null 2>&1
  printf 'two\n' >"${corpus_repo}/repo/tracked"
  printf '#!/bin/sh\necho EXTERNAL-DIFF-RAN\n' >"${corpus_repo}/external-diff"
  chmod +x "${corpus_repo}/external-diff"
  mkdir -p "${corpus_repo}/secrets"
  printf 'STAND-IN-NOT-A-SECRET\n' >"${corpus_repo}/secrets/id_rsa"
  printf 'public\n' >"${corpus_repo}/secrets/id_rsa.pub"

  corpus_env_out="$(cd "${corpus_repo}/repo" &&
    GIT_EXTERNAL_DIFF="${corpus_repo}/external-diff" git diff HEAD 2>/dev/null)"
  corpus_export_out="$(cd "${corpus_repo}/repo" && bash --norc --noprofile -c \
    "export GIT_EXTERNAL_DIFF='${corpus_repo}/external-diff'; git diff HEAD" 2>/dev/null)"
  corpus_config_out="$(cd "${corpus_repo}/repo" &&
    git -c "diff.external=${corpus_repo}/external-diff" diff HEAD 2>/dev/null)"
  # The third spelling, and the one the allow row reaches without an
  # assignment or a config option anywhere in the command: git difftool takes
  # the program as an ordinary argument. --no-prompt is what makes it run
  # unattended; stdin is closed so a host where it still asks cannot hang the
  # suite.
  corpus_difftool_out="$(cd "${corpus_repo}/repo" &&
    git difftool --no-prompt --extcmd="${corpus_repo}/external-diff" HEAD 2>/dev/null </dev/null)"
  corpus_glob_out="$(cd "${corpus_repo}/repo" && bash --norc --noprofile -c \
    "git diff '${corpus_repo}'/secrets/*" 2>/dev/null)"
  # xargs, which hands git operands the string never holds: the corpus row's
  # own spelling, run against a stand-in cosign.pub in the throwaway
  # checkout, prints that file as a plain-file diff with no path after
  # `git diff`. And noglob, which bash does not have: bash opens the
  # redirection's target before it finds no command to run, so the file is
  # emptied all the same.
  printf 'STAND-IN-XARGS-OPERAND\n' >"${corpus_repo}/repo/cosign.pub"
  corpus_xargs_out="$(cd "${corpus_repo}/repo" && bash --norc --noprofile -c \
    "printf '%s\n' /dev/null ./cosign.pub | xargs git diff" 2>/dev/null </dev/null)"
  printf 'ORIGINAL-CONTENT\n' >"${corpus_repo}/victim"
  (cd "${corpus_repo}" && bash --norc --noprofile -c 'noglob podman ps >victim' >/dev/null 2>&1 </dev/null)
  corpus_noglob_written="$(cat "${corpus_repo}/victim" 2>/dev/null)"
  rm -rf "${corpus_repo}"

  for corpus_demo in "an assignment in front of git:${corpus_env_out}" \
    "an export in an earlier command:${corpus_export_out}" \
    "git -c diff.external:${corpus_config_out}" \
    "git difftool --extcmd:${corpus_difftool_out}"; do
    if [[ "${corpus_demo#*:}" == *EXTERNAL-DIFF-RAN* ]]; then
      pass "git really runs a program named this way, so the refusal is not about nothing: ${corpus_demo%%:*}"
    else
      fail "git really runs a program named this way, so the refusal is not about nothing: ${corpus_demo%%:*}" \
        "git printed no sign of the external driver; the rule may be more than is needed"
    fi
  done
  if [[ "${corpus_glob_out}" == *STAND-IN-NOT-A-SECRET* ]]; then
    pass "bash really turns one globbed word into the two operands git prints as a plain-file diff"
  else
    fail "bash really turns one globbed word into the two operands git prints as a plain-file diff" \
      "git printed nothing for the expanded glob; the glob rule may be more than is needed"
  fi
  if grep -q '^+STAND-IN-XARGS-OPERAND$' <<<"${corpus_xargs_out}"; then
    pass "xargs really hands git the plain-file operands from standard input, so git diff prints a file the string never names"
  else
    fail "xargs really hands git the plain-file operands from standard input, so git diff prints a file the string never names" \
      "git printed no line of the stand-in file; re-derive why xargs in front of git is refused"
  fi
  if [[ "${corpus_noglob_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "bash opens the target of a redirection behind noglob before it finds no noglob to run"
  else
    fail "bash opens the target of a redirection behind noglob before it finds no noglob to run" \
      "the file kept its contents; re-derive why a redirection behind noglob is refused"
  fi

  # Mutation check, which the issue asks for directly: disabling each rule
  # this pass added must stop at least one row of the corpus being refused. A
  # rule whose absence nothing notices is a rule this suite does not hold.
  # Each entry is the line that carries the rule, what to replace it with, and
  # the row that must go quiet.
  mutation_label=()
  mutation_before=()
  mutation_after=()
  mutation_witness=()
  mutation_row() {
    mutation_label+=("$1")
    mutation_before+=("$2")
    mutation_after+=("$3")
    mutation_witness+=("$4")
  }
  # Each `before` is a line of the hook, quoted as it is written there, so the
  # same directive applies here.
  # shellcheck disable=SC2016
  mutation_table() {
  mutation_row 'the leading-assignment refusal on a git invocation' \
    '((cmd_git && cmd_assign)) && refuse "${GATED_ENV_MSG}"' \
    '((cmd_git && cmd_assign)) && true' \
    'GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  mutation_row 'reading a literal git word anywhere in the command, not only as the name' \
    '[[ "${words[idx]}" == git ]] && cmd_git=1' \
    '[[ "${words[idx]}" == not-a-command-name ]] && cmd_git=1' \
    'GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  mutation_row 'the += operator of an assignment' \
    '=~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=' \
    '=~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?=' \
    'GIT_EXTERNAL_DIFF+=/tmp/evil git diff HEAD'
  mutation_row 'reading an assignment with its quotes removed' \
    'if ((cmd_named == 0)) && [[ "${words[idx]}" =~ ^([A-Za-z_]' \
    'if ((cmd_named == 0)) && [[ "${raw_words[idx]}" =~ ^([A-Za-z_]' \
    "env 'GIT_EXTERNAL_DIFF'=/tmp/evil git diff HEAD"
  mutation_row "the search for a name past a wrapper's own options" \
    'if ((after_wrapper)) && [[ "${word}" == -* ]]; then' \
    'if ((after_wrapper)) && [[ "${word}" == -*-not-this-one ]]; then' \
    'env -i GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  mutation_row 'the export latch over the whole string' \
    '((saw_gated && saw_export)) && refuse "${GATED_EXPORT_MSG}"' \
    '((saw_gated && saw_export)) && true' \
    'export GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  mutation_row 'the -x option of declare, typeset, local and readonly' \
    '    declare | typeset | local | readonly)' \
    '    not-a-command-name)' \
    'declare -x GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  mutation_row 'set -a, which exports every assignment made after it' \
    '[[ "${words[idx]}" == -*a* || "${words[idx]}" == allexport ]] && saw_export=1' \
    'true' \
    'set -a; GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD'
  mutation_row 'the glob refusal inside a git invocation' \
    'refuse "${GLOB_MSG}"' \
    ':' \
    'git diff ./cosign.*'
  mutation_row 'the git global options that load a program or relocate git' \
    'refuse "${GIT_GLOBAL_MSG}"' \
    ':' \
    'git status; git -c diff.external=/tmp/evil diff HEAD'
  mutation_row 'the difftool subcommand refusal' \
    '  difftool | mergetool)' \
    '  not-a-git-subcommand)' \
    'git difftool -x /tmp/evil HEAD'
  mutation_row "consuming a wrapper option's own value word (timeout -s, nice -n, stdbuf -o, env -u)" \
    'wrapper_option_takes_value "${wrapper_name}" "${word}" && wrapper_value_pending=1' \
    'false && wrapper_value_pending=1' \
    'timeout -s TERM 60 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  mutation_row "consuming timeout's own mandatory DURATION operand" \
    '[[ "${wrapper_name}" == timeout ]] && wrapper_positional_pending=1' \
    'false && wrapper_positional_pending=1' \
    'timeout 60 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD'
  mutation_row 'the xargs refusal in front of git or an allow-listed command' \
    '((cmd_xargs && (cmd_gated || cmd_git_name))) && refuse "${XARGS_MSG}"' \
    '((cmd_xargs && (cmd_gated || cmd_git_name))) && true' \
    "printf '%s\n' /dev/null ./cosign.key | xargs git diff"
  mutation_row 'the input-redirection refusal on a git invocation' \
    '((cmd_git_name && cmd_read)) && refuse "${GIT_STDIN_MSG}"' \
    '((cmd_git_name && cmd_read)) && true' \
    'git log --stdin <.env'
  mutation_row 'noglob in the wrapper list' \
    'nohup | noglob | nice' \
    'nohup | nice' \
    'noglob podman ps >out'
  mutation_row 'a literal path to a wrapper read as that wrapper' \
    'is_wrapper "${wrapper_spelling##*[/\\]}" && wrapper_base="${wrapper_spelling##*[/\\]}"' \
    'is_wrapper "${wrapper_spelling}" && wrapper_base="${wrapper_spelling}"' \
    'git status; /usr/bin/xargs git diff'
  mutation_row 'refusing a wrapper written as a path other than /usr/bin or /bin' \
    '*) refuse "${WRAPPER_PATH_MSG}" ;;' \
    '*) ;;' \
    './shim/nohup git diff HEAD'
  mutation_row 'reading the next word as the value of an xargs option' \
    '((i + 1 < ${#cluster})) || xargs_optarg=1' \
    '((i + 1 < ${#cluster})) || xargs_optarg=0' \
    'xargs -n 1 git diff <list.txt'
  mutation_row 'every later word a possible name after an xargs option this does not read' \
    'xargs_state=0 # not an option this reads' \
    'continue # not an option this reads' \
    'xargs -J % git diff <list.txt'
  mutation_row 'time by path read as a wrapper' \
    'stdbuf | sudo | doas | time) return 0 ;;' \
    'stdbuf | sudo | doas) return 0 ;;' \
    '/usr/bin/time shellcheck tests/run-tests.sh >cosign.pub'
  mutation_row 'stepping over a wrapper only as typed, not as bash reads it' \
    '    case "${raw_word}" in' \
    '    case "${word}" in' \
    "'\\nohup' git diff HEAD"
  mutation_row 'refusing the bash options that print what bash -n reads' \
    '[[ "${words[idx]}" == -*[vxilD]* ]] && refuse "${BASH_ECHO_MSG}"' \
    ':' \
    'bash -n -v tests/run-tests.sh'
  mutation_row 'a -nv first word completing the bash -n prefix' \
    '((cmd_bash)) && [[ "${cmd_prefix}" == '"'"'bash -n'"'"'?* ]] && cmd_gated=1' \
    ':' \
    'bash -nv tests/run-tests.sh'
  mutation_row 'refusing the -o names that print or copy what bash reads' \
    'verbose | xtrace | history) refuse' \
    'verbose | xtrace | history) :' \
    'bash -n -o verbose tests/run-tests.sh'
  mutation_row 'handing each o in a cluster the next word as its value' \
    'bash_optvals+="${words[idx]//[!oO]/}"' \
    ':' \
    'bash -n -no verbose tests/run-tests.sh'
  mutation_row 'holding a bash -n operand to the shellcheck operand test' \
    'if ! path_inside_worktree "${words[idx]}" || denied_read_shape "${words[idx]}"; then' \
    'if false; then' \
    'bash -n .env'
  mutation_row "holding a file on bash -n's stdin to the same test" \
    '((cmd_gated && cmd_read && cmd_bash))' \
    '((0))' \
    'bash -n - < .env'
  mutation_row 'refusing a login shell set up by exec -l or a dashed zeroth argument' \
    '((${argv0_words[idx]:-0})) && ((cmd_gated == 0)) && cmd_argv0=1' \
    ':' \
    'exec -l bash -n tests/run-tests.sh'
  }
  mutation_table

  mutation_source="$(cat .claude/hooks/gate-git-diff.sh)"
  mutation_dir="$(mktemp -d)"
  for ((corpus_i = 0; corpus_i < ${#mutation_label[@]}; corpus_i++)); do
    # The line must still be there, spelled the way it is here: a mutation
    # that names nothing silently stops testing anything.
    mutation_count=0
    mutation_rest="${mutation_source}"
    while [[ "${mutation_rest}" == *"${mutation_before[corpus_i]}"* ]]; do
      ((mutation_count++))
      mutation_rest="${mutation_rest#*"${mutation_before[corpus_i]}"}"
    done
    if ((mutation_count != 1)); then
      fail "the mutation for ${mutation_label[corpus_i]} names exactly one line of the hook" \
        "it matched ${mutation_count} times, so disabling that rule no longer proves anything"
      continue
    fi
    pass "the mutation for ${mutation_label[corpus_i]} names exactly one line of the hook"
    printf '%s\n' "${mutation_source//"${mutation_before[corpus_i]}"/"${mutation_after[corpus_i]}"}" \
      >"${mutation_dir}/gate.sh"
    mutation_payload="$(jq -nc --arg c "${mutation_witness[corpus_i]}" \
      '{tool_name: "Bash", tool_input: {command: $c}}')"
    mutation_stderr="$(printf '%s' "${mutation_payload}" |
      CLAUDE_PROJECT_DIR="${PWD}" bash "${mutation_dir}/gate.sh" 2>&1 >/dev/null)"
    mutation_status=$?
    if ((mutation_status == 0)); then
      pass "disabling ${mutation_label[corpus_i]} stops a corpus row being refused"
    else
      fail "disabling ${mutation_label[corpus_i]} stops a corpus row being refused" \
        "the hook still refused '${mutation_witness[corpus_i]}' with that rule gone (exit ${mutation_status}: ${mutation_stderr:0:120}); the row does not hold the rule"
    fi
  done
  rm -rf "${mutation_dir}"

fi

printf '1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'All %d assertion(s) passed.\n' "${checks_run}"

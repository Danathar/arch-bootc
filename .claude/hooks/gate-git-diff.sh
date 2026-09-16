#!/usr/bin/env bash
# PreToolUse gate on the Bash tool.
#
# .claude/settings.json denies the Read tool this repository's secret-shaped
# paths and allows `Bash(git diff*)` with no prompt. Those are different tools:
# a deny rule on Read says nothing about what an allowed Bash command opens.
# `git diff` in its two-path mode compares operands as plain files rather than
# as repository content, so it prints any file this uid can read -- untracked,
# gitignored, or outside the checkout entirely -- and never consults the deny
# list. `cat ./cosign.key` prompts; the diff form did not.
#
# Two things this gate must get right, both learned from the first version of
# it failing them:
#
#   1. The mode has no required flag. `git diff /dev/null ./cosign.key` prints
#      the file with no `--no-index` anywhere in the command, because git
#      enters that mode on its own when two operands are given and either one
#      is not repository content. Matching the flag string alone missed this
#      entirely.
#   2. The shell rewrites the command before git sees it. `--no-'index'` and
#      `--no-\index` both reach git as `--no-index` while a substring test on
#      the typed spelling finds neither.
#
#   3. `--` does not end the mode either. `git diff -- /dev/null ./cosign.key`
#      prints the file: git's own scan (builtin/diff.c, cmd_diff) consumes a
#      leading `--` and then applies the same two-operand test to whatever
#      follows it. Only an operand *before* the `--` stops that scan, which is
#      why `git diff HEAD -- path` can never be a plain-file read but
#      `git diff -- a b` can. A version of this gate treated everything after
#      `--` as a repository pathspec and let the first form through.
#
# So this looks at the operands git would actually receive, and refuses the
# two-operand form unless every operand resolves as a revision -- which is what
# separates `git diff main feature` from `git diff /dev/null ./cosign.key`.
# After a bare `--` no word can be a revision, so there the test is git's own:
# two or more words where any one lies outside the working tree.
#
# What it still cannot see, stated rather than implied: a command that builds
# its arguments at runtime (`git diff $x $y`, `sh -c ...`), one that changes
# directory out of the repository first, and anything a command reads once it
# has started. This re-gates the one pre-approved command that reaches past the
# deny list; it is not a sandbox.

set -uo pipefail

refuse() {
  printf '%s\n' "$1" >&2
  exit 2
}

DIFF_MSG='blocked: this git diff would compare paths as plain files (git'"'"'s --no-index mode, which needs no flag once two operands are given), so it prints any file on disk -- cosign.key, a .env, a private key outside this repository -- past the Read(...) deny rules in .claude/settings.json. Describe such a file with ls -l or wc -c instead.'

# Fail closed. This gate stands in front of the one pre-approved command that
# can read a denied path, so a missing dependency must not quietly disable it:
# AGENTS.md requires that setup of this kind fail closed.
command -v jq >/dev/null 2>&1 ||
  refuse 'blocked: this PreToolUse hook needs jq to inspect the command and jq is not on PATH. It gates the one pre-approved command that can read a denied path, so it refuses rather than letting calls through uninspected. Install jq.'

payload="$(cat)"
command_string="$(printf '%s' "${payload}" | jq -r '.tool_input.command // empty')" ||
  refuse 'blocked: this PreToolUse hook could not parse the tool payload as JSON, so it cannot tell whether the call reads a denied path. It refuses rather than letting the call through uninspected.'

[[ -n "${command_string}" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

# Match the word git receives, not the spelling typed: the shell removes
# quoting and backslashes on the way.
normalized="${command_string//[\'\"\\]/}"
normalized="${normalized//$'\n'/ }"
normalized="${normalized//$'\t'/ }"

case "${normalized}" in
*--no-index*) refuse "${DIFF_MSG}" ;;
esac

read -r -a words <<<"${normalized}"

# Git's path_inside_repo, approximately: the operand, made absolute and with
# its `..` components folded, lies at or under the working tree. Anything this
# cannot decide -- no working tree here, no realpath on the host -- counts as
# outside, so the gate refuses rather than guesses.
path_inside_worktree() {
  local candidate toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  candidate="$(realpath -m -s -- "$1" 2>/dev/null)" || return 1
  [[ "${candidate}" == "${toplevel}" || "${candidate}" == "${toplevel}"/* ]]
}

seen_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0

for word in "${words[@]+"${words[@]}"}"; do
  case "${word}" in
  ';' | '&&' | '||' | '|' | '&' | '(' | ')')
    seen_git=0
    in_diff=0
    continue
    ;;
  esac

  if ((in_diff)); then
    if [[ "${word}" == "--" ]]; then
      if ((operands > 0)); then
        # A revision or path already stopped git's scan, so what follows is
        # a pathspec resolved against the repository, never a plain file.
        seen_git=0
        in_diff=0
      else
        # Nothing preceded the `--`: git consumes it and applies the
        # two-operand test to the words after it. Count those instead.
        after_dashdash=1
      fi
      continue
    fi
    if ((after_dashdash)); then
      # Git does not parse options here: `-x` after `--` is a path named -x.
      ((operands++))
      path_inside_worktree "${word}" || unresolved=1
      if ((operands >= 2 && unresolved)); then
        refuse "${DIFF_MSG}"
      fi
      continue
    fi
    [[ "${word}" == -* ]] && continue
    ((operands++))
    git rev-parse --verify --quiet "${word}^{commit}" >/dev/null 2>&1 || unresolved=1
    if ((operands >= 2 && unresolved)); then
      refuse "${DIFF_MSG}"
    fi
    continue
  fi

  if ((seen_git)); then
    # git-level options such as --no-pager sit between `git` and the subcommand.
    [[ "${word}" == -* ]] && continue
    if [[ "${word}" == "diff" ]]; then
      in_diff=1
      operands=0
      unresolved=0
      after_dashdash=0
      continue
    fi
    seen_git=0
  fi

  [[ "${word}" == "git" ]] && seen_git=1
done

exit 0

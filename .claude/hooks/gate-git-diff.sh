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
#   4. Reading is only half of it. The same diff-generating family has a
#      *write* primitive: `--output=FILE` sends the diff git would have printed
#      to a path instead of stdout, so an allow-listed, unprompted call
#      overwrites any file this uid can reach -- `cosign.pub`, which is the
#      signature trust anchor copied into the image, `.claude/settings.json`,
#      this hook, `~/.ssh/authorized_keys`. The deny rules are no help: they
#      gate the *Read* tool and say nothing about what an allowed Bash command
#      writes. The operand scan below could not see it either, because it skips
#      every dash-prefixed word, and it stops tracking git at the subcommand --
#      `git log -p --output=FILE` and `git show --output=FILE` are allow-listed
#      too and were never inspected at all. `git show` refuses the flag only
#      for a *combined* diff -- a merge commit, and on git 2.39 only after
#      truncating the file it named -- and writes an ordinary commit's diff in
#      full, so "git show rejects --output" is not a reason to leave it out.
#
#      The content is diff-framed rather than byte-clean, which matters less
#      than it sounds: the `+` lines carry whatever the caller committed, and
#      for a trust anchor or a config file corruption alone is the event.
#      Nothing legitimate needs it -- diff, log and show print to stdout, which
#      the agent already reads -- so the refusal is the whole git invocation,
#      not one subcommand. `--output-indicator-new` and its siblings change the
#      marker character rather than the destination and stay permitted.
#
# So this looks at the operands git would actually receive, and refuses the
# two-operand form unless every operand resolves as a revision -- which is what
# separates `git diff main feature` from `git diff /dev/null ./cosign.key`.
# After a bare `--` no word can be a revision, so there the test is git's own:
# two or more words where any one lies outside the working tree. The write
# primitive needs none of that machinery: `--output` anywhere in a git
# invocation is refused outright.
#
# What it still cannot see, stated rather than implied: a command that builds
# its arguments at runtime (`git diff $x $y`, `sh -c ...`), one that changes
# directory out of the repository first, and anything a command reads or writes
# once it has started. This re-gates the pre-approved commands that reach past
# the deny list; it is not a sandbox.

set -uo pipefail

refuse() {
  printf '%s\n' "$1" >&2
  exit 2
}

DIFF_MSG='blocked: this git diff would compare paths as plain files (git'"'"'s --no-index mode, which needs no flag once two operands are given), so it prints any file on disk -- cosign.key, a .env, a private key outside this repository -- past the Read(...) deny rules in .claude/settings.json. Describe such a file with ls -l or wc -c instead.'

OUT_MSG='blocked: git --output=FILE (and the space form) writes this diff or log to the path it names instead of stdout, overwriting any file this uid can reach -- cosign.pub, .claude/settings.json, this hook, ~/.ssh/authorized_keys -- with no Read(...) or Write(...) deny rule in its way. git diff, git log and git show print to stdout; read that instead. --output-indicator-* is a different flag and is unaffected.'

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

# Shell operators need no whitespace around them, and this scan splits on
# whitespace alone. `git log -1 && (git log -p --output=cosign.pub -1)`
# tokenizes as `(git`, which is not the word `git`, so the second command was
# never recognized as a git invocation and every test below stayed switched off
# for it -- the hook exited 0 while the trust anchor was overwritten. The read
# half had the same hole: `ls&&git diff /dev/null ./cosign.key`. Give each
# operator character whitespace of its own, so a command written hard against
# one is still a command here.
for operator_char in '(' ')' ';' '&' '|' '`'; do
  normalized="${normalized//"${operator_char}"/ ${operator_char} }"
done

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
in_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0
skip_git_option_value=0

for word in "${words[@]+"${words[@]}"}"; do
  case "${word}" in
  ';' | '&&' | '||' | '|' | '&' | '(' | ')' | '`')
    # The operand scan starts over at each command boundary. `in_git` does not:
    # it latches for the rest of the command string. Splitting on operator
    # characters above means one sitting inside an argument -- `git log
    # --grep=a|b --output=cosign.pub -1` -- would otherwise end the git
    # invocation as far as this scan is concerned and hand the write primitive
    # back unwatched. The cost is refusing a `--output` that belongs to some
    # later non-git command in the same string; the alternative is a bypass
    # spelled with one pipe.
    seen_git=0
    in_diff=0
    skip_git_option_value=0
    continue
    ;;
  esac

  # Scoped to the git invocation as a whole, and checked before anything
  # below skips a dash-prefixed word: the write primitive belongs to the
  # diff-generation machinery rather than to one subcommand, so `git log -p
  # --output=FILE` and `git show --output=FILE` reach it without the word
  # `diff` appearing anywhere. `--output=x` and a bare `--output` (the space
  # form, whose path is the next word) are the two spellings; the pattern is
  # anchored so `--output-indicator-new=%` does not match it.
  #
  # This is deliberately wider than the allow list: a `git commit -m` whose
  # message happens to contain the word --output is refused too. That costs a
  # rephrased commit message; the alternative is a list of which git
  # subcommands accept the flag, and the subcommand this hook forgot is the
  # hole.
  if ((in_git)); then
    case "${word}" in
    --output | --output=*) refuse "${OUT_MSG}" ;;
    esac
  fi

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
    if ((skip_git_option_value)); then
      # The value half of a two-token git global option. Without this the
      # directory or setting is read as the subcommand, git is forgotten, and
      # the operand scan never starts at all: `git -C / diff /dev/null
      # etc/shadow` went through uninspected. No allow rule matches that
      # spelling today, so it prompts -- but a gate whose coverage depends on
      # an allow rule's exact prefix is one allow-list edit from silence.
      skip_git_option_value=0
      continue
    fi
    case "${word}" in
    -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env | --attr-source)
      skip_git_option_value=1
      continue
      ;;
    esac
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

  if [[ "${word}" == "git" ]]; then
    seen_git=1
    in_git=1
  fi
done

exit 0
